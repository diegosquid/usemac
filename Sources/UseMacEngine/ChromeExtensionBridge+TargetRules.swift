import Foundation
import UseMacProtocol

/// The user's site rules (TargetRules) on the daemon side of the bridge, so they hold with any extension version:
/// a command is checked against the tab it would run on before it is sent, every result against its page's URL
/// before anything is written or handed back, and stream frames of blocked pages are dropped.
extension ChromeExtensionBridge {
    /// How long the tab lookup before a command may take (capped by the bridge's base timeout). The extension
    /// answers it in milliseconds.
    static let targetRulesLookupTimeoutSeconds: TimeInterval = 2.0

    /// Lookup failures where the command itself could not be sent either, so its own error is the answer.
    static let targetRulesUnreachableCodes: Set<String> = ["EXTENSION_NOT_CONNECTED", "EXTENSION_NOT_PAIRED"]

    static func targetBlockedResponse(_ message: String, tabId: Int? = nil, profileName: String? = nil) -> BridgeResponse {
        BridgeResponse(
            ok: false,
            tabId: tabId,
            profileName: profileName,
            error: RPCErrorPayload(code: TargetRules.errorCode, message: message)
        )
    }

    static func targetReadOnlyResponse(_ message: String, tabId: Int? = nil, profileName: String? = nil) -> BridgeResponse {
        BridgeResponse(
            ok: false,
            tabId: tabId,
            profileName: profileName,
            error: RPCErrorPayload(code: "POLICY_BLOCKED", message: message, hint: TargetRules.stopHint)
        )
    }

    /// Checks the destination URL (if given) and the tab a command would use. Reads still work on Read-only
    /// sites. `checksTab` false is for commands that do not act on an existing tab, such as opening a new tab.
    func targetRulesPreflight(
        profile: String?, tabId: Int?, url: String? = nil, checksTab: Bool = true, isMutating: Bool = false
    ) async -> BridgeResponse? {
        let rules = TargetRulesStore.shared.rules
        if rules.blocksBrowser {
            return Self.targetBlockedResponse(TargetRules.blockedBrowserMessage)
        }
        if let url, rules.blocksURL(url) {
            return Self.targetBlockedResponse(TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: url)))
        }
        if isMutating, rules.effectiveSitePolicy(url: url) == .readOnly {
            return Self.targetReadOnlyResponse(TargetRules.readOnlySiteMessage(host: TargetRules.host(ofURL: url)))
        }
        guard checksTab, rules.hasSiteRules || (isMutating && !rules.readOnlySites.isEmpty) else { return nil }

        let tab = await lookupRulesTab(profile: profile, tabId: tabId, requiresTab: false)
        if let failure = tab.failure { return failure }
        switch rules.effectiveSitePolicy(url: tab.url) {
        case .block:
            return Self.targetBlockedResponse(TargetRules.blockedSiteMessage(host: nil), tabId: tab.tabId, profileName: tab.profile)
        case .readOnly where isMutating:
            return Self.targetReadOnlyResponse(
                TargetRules.readOnlySiteMessage(host: TargetRules.host(ofURL: tab.url)),
                tabId: tab.tabId,
                profileName: tab.profile
            )
        default:
            return nil
        }
    }

    /// Resolves the tab and any navigation destinations a mutating command could reach. Unknown tab URLs
    /// fail closed when site rules apply. The caller can use the resolved tab ID and profile to keep the
    /// command on the tab it checked rather than resolving a default tab again after approval.
    public func resolveGovernedTabSitePolicy(
        profile: String?, tabId: Int?, candidateURLs: [String] = []
    ) async -> (policy: TargetRules.AccessPolicy, host: String?, resolvedTabId: Int?, resolvedProfile: String?, failure: BridgeResponse?) {
        let result = await governedSiteDecision(profile: profile, tabId: tabId, candidateURLs: candidateURLs, checksTab: true)
        return (result.policy, result.site?.host, result.tabId, result.profile, result.failure)
    }

    struct GovernedSiteDecision {
        var policy: TargetRules.AccessPolicy = .allow
        var site: TargetRules.Site?
        var tabId: Int?
        var profile: String?
        var failure: BridgeResponse?
    }

    // An explicit new-tab open has no current tab to look up; it checks its URL and inline destinations.
    func governedSiteDecision(
        profile: String?, tabId: Int?, candidateURLs: [String], checksTab: Bool
    ) async -> GovernedSiteDecision {
        let rules = TargetRulesStore.shared.rules
        var result = GovernedSiteDecision(tabId: tabId, profile: profile)
        guard rules.hasGovernedSiteRules else { return result }
        if rules.blocksBrowser {
            result.policy = .block
            result.failure = Self.targetBlockedResponse(TargetRules.blockedBrowserMessage, tabId: tabId, profileName: profile)
            return result
        }

        func consider(_ url: String) {
            let policy = rules.effectiveSitePolicy(url: url)
            let combined = result.policy.combined(with: policy)
            guard combined != result.policy else { return }
            result.policy = combined
            result.site = TargetRules.site(ofURL: url.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        for url in candidateURLs { consider(url) }
        let candidateBlocked = result.policy == .block
        if checksTab, !candidateBlocked {
            let tab = await lookupRulesTab(profile: profile, tabId: tabId, requiresTab: true)
            result.tabId = tab.tabId
            result.profile = tab.profile
            result.failure = tab.failure
            if let url = tab.url { consider(url) }
        } else if !candidateBlocked,
                  !candidateURLs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            result.failure = Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: "the destination address is not known yet"),
                tabId: tabId,
                profileName: profile
            )
        }
        if result.policy == .block {
            result.failure = Self.targetBlockedResponse(
                TargetRules.blockedSiteMessage(host: candidateBlocked ? result.site?.host : nil),
                tabId: result.tabId,
                profileName: result.profile
            )
        }
        return result
    }

    private func lookupRulesTab(
        profile: String?, tabId: Int?, requiresTab: Bool
    ) async -> (url: String?, tabId: Int?, profile: String?, failure: BridgeResponse?) {
        // The extension's live URL events avoid an all-tabs round trip for an explicit tab.
        if let tabId, let cached = liveCachedTabURL(profileQuery: profile, tabId: tabId) {
            if let url = Self.confirmedTabURL(cached.url, requiresTab: requiresTab) {
                return (url, tabId, cached.profileName, nil)
            }
        }

        let timeout = min(Self.targetRulesLookupTimeoutSeconds, max(0.05, baseCommandTimeoutSeconds))
        let listing = await unfilteredTabs(profile: profile, timeoutSeconds: timeout)
        guard listing.ok else {
            if let code = listing.error?.code, Self.targetRulesUnreachableCodes.contains(code) {
                return (nil, tabId, listing.profileName ?? profile, listing)
            }
            let reason = listing.error?.code == "EXTENSION_TIMEOUT" ? "the tab lookup timed out" : "the tab lookup failed"
            return (nil, tabId, listing.profileName ?? profile, Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: reason), tabId: tabId
            ))
        }
        let resolvedProfile = listing.profileName ?? profile
        guard let tabs = listing.tabs else {
            return (nil, tabId, resolvedProfile, Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: "Chrome did not list its tabs"), tabId: tabId
            ))
        }
        guard let target = Self.commandTargetTab(requested: tabId, lastTabId: listing.tabId, in: tabs) else {
            // Reads preserve the extension's own error if their requested or fallback tab does not exist.
            let failure = requiresTab ? Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: "Chrome did not find the target tab"),
                tabId: tabId, profileName: resolvedProfile
            ) : nil
            return (nil, tabId, resolvedProfile, failure)
        }
        guard let url = Self.confirmedTabURL(target.url, requiresTab: requiresTab) else {
            return (nil, target.tabId, resolvedProfile, Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: "the tab's address is not known yet"),
                tabId: target.tabId, profileName: resolvedProfile
            ))
        }
        return (url, target.tabId, resolvedProfile, nil)
    }

    private static func confirmedTabURL(_ raw: String, requiresTab: Bool) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard requiresTab else { return text }
        guard let url = URL(string: text, encodingInvalidCharacters: false), let scheme = url.scheme else { return nil }
        if ["http", "https", "ws", "wss"].contains(scheme.lowercased()), TargetRules.host(ofURL: text) == nil {
            return nil
        }
        return text
    }

    /// vision_query reads a Chrome tab when it names one, or names no app while Chrome is connected
    /// (UseMacEngineService.resolveVisionInputImage): the same check as a screenshot of that tab. Only a
    /// TARGET_BLOCKED answer is returned; with Chrome unreachable, vision falls back as before.
    func targetRulesVisionPreflight(_ params: VisionQueryParams) async -> BridgeResponse? {
        let explicitImage = !(params.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let readsTab = params.profile != nil || params.tabId != nil || params.selector != nil || params.elementId != nil
            || (params.app == nil && !connectedProfiles().isEmpty)
        guard !explicitImage, readsTab,
              let refusal = await targetRulesPreflight(profile: params.profile, tabId: params.tabId),
              refusal.error?.code == TargetRules.errorCode else {
            return nil
        }
        return refusal
    }

    /// The tab the extension runs a command on (Extension/background.js, resolveTargetTab): the requested tab,
    /// else the last tab it used, else the UseMac group's active tab, else its last tab.
    static func commandTargetTab(requested: Int?, lastTabId: Int?, in tabs: [BrowserTabInfo]) -> BrowserTabInfo? {
        if let requested {
            return tabs.first { $0.tabId == requested }
        }
        if let lastTabId, let last = tabs.first(where: { $0.tabId == lastTabId }) {
            return last
        }
        let usemacTabs = tabs.filter { $0.usemac == true }
        return usemacTabs.first(where: { $0.active }) ?? usemacTabs.last
    }

    /// The refusal that replaces a result whose page is on a blocked site, or nil to pass it on.
    static func targetRulesResultRefusal(url: String?, tabId: Int?, profileName: String?, rules: TargetRules) -> BridgeResponse? {
        if rules.blocksBrowser {
            return targetBlockedResponse(TargetRules.blockedBrowserMessage, tabId: tabId, profileName: profileName)
        }
        guard rules.blocksURL(url) else { return nil }
        return targetBlockedResponse(TargetRules.blockedSiteMessage(host: nil, afterResult: true), tabId: tabId, profileName: profileName)
    }

    /// A download may cross sites between its initiating page, original URL and final URL.
    static func targetRulesPermitDownload(urls: [String?], rules: TargetRules) -> Bool {
        guard rules.hasSiteRules else { return true }
        guard !urls.contains(where: rules.blocksURL) else { return false }
        return rules.mode != .allow || urls.contains { TargetRules.sanitizeDownloadURL($0) != nil }
    }

    /// True when a stream frame (or cached frame) shows a page the rules block.
    static func targetRulesBlockFrame(url: String?) -> Bool {
        let rules = TargetRulesStore.shared.rules
        return rules.blocksBrowser || rules.blocksURL(url)
    }

    /// A tab list without the tabs on blocked sites (TARGET_BLOCKED when Chrome itself is denied).
    static func hidingBlockedTabs(_ response: BridgeResponse) -> BridgeResponse {
        let rules = TargetRulesStore.shared.rules
        if rules.blocksBrowser {
            return targetBlockedResponse(TargetRules.blockedBrowserMessage, profileName: response.profileName)
        }
        guard let tabs = response.tabs else { return response }
        let visible = rules.visibleTabs(tabs)
        guard visible.count != tabs.count else { return response }
        return BridgeResponse(
            ok: response.ok,
            tabId: response.tabId,
            profileName: response.profileName,
            url: response.url,
            title: response.title,
            tabs: visible,
            extractResult: response.extractResult,
            screenshot: response.screenshot,
            snapshot: response.snapshot,
            actionResult: response.actionResult,
            error: response.error,
            windowId: response.windowId,
            restricted: response.restricted,
            closedTabs: response.closedTabs,
            keptTabs: response.keptTabs
        )
    }
}
