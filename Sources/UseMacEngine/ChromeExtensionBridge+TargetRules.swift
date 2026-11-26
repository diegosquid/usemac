import Foundation
import UseMacProtocol

/// The user's site rules (TargetRules) on the daemon side of the bridge, so they hold with any extension version:
/// a command is checked against the tab it would run on before it is sent, every result against its page's URL
/// before anything is written or handed back, and stream frames of blocked pages are dropped.
extension ChromeExtensionBridge {
    /// How long the tab lookup before a command may take (capped by the bridge's base timeout). The extension
    /// answers it in milliseconds.
    static let targetRulesLookupTimeoutSeconds: UInt64 = 2

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

    /// TARGET_BLOCKED before anything is sent, or nil to send the command. Blocked when Chrome itself is denied,
    /// when `url` (a page to open) is on a blocked site, or when the tab the command would run on is.
    /// `checksTab` false skips the tab lookup (a command that opens a new tab).
    ///
    /// With site rules this fails closed: when the lookup times out or fails, or the tab's URL is not known yet,
    /// the command is refused too, since checking the result's URL afterwards is too late for an act. Without any
    /// site rule there is no lookup at all.
    func targetRulesPreflight(profile: String?, tabId: Int?, url: String? = nil, checksTab: Bool = true) async -> BridgeResponse? {
        let rules = TargetRulesStore.shared.rules
        if rules.blocksBrowser {
            return Self.targetBlockedResponse(TargetRules.blockedBrowserMessage)
        }
        if let url, rules.blocksURL(url) {
            return Self.targetBlockedResponse(TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: url)))
        }
        guard checksTab, rules.hasSiteRules else { return nil }

        let timeout = min(Self.targetRulesLookupTimeoutSeconds, max(1, baseCommandTimeoutSeconds))
        let listing = await unfilteredTabs(profile: profile, timeoutSeconds: timeout)
        guard listing.ok else {
            if let code = listing.error?.code, Self.targetRulesUnreachableCodes.contains(code) {
                return listing
            }
            let reason = listing.error?.code == "EXTENSION_TIMEOUT" ? "the tab lookup timed out" : "the tab lookup failed"
            return Self.targetBlockedResponse(TargetRules.unconfirmedSiteMessage(reason: reason), tabId: tabId)
        }
        guard let tabs = listing.tabs else {
            return Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: "Chrome did not list its tabs"),
                tabId: tabId
            )
        }
        // No such tab, or no UseMac tab to fall back to: the extension refuses the command on its own.
        guard let target = Self.commandTargetTab(requested: tabId, lastTabId: listing.tabId, in: tabs) else {
            return nil
        }
        if target.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.targetBlockedResponse(
                TargetRules.unconfirmedSiteMessage(reason: "the tab's address is not known yet"),
                tabId: target.tabId,
                profileName: listing.profileName
            )
        }
        guard rules.blocksURL(target.url) else { return nil }
        return Self.targetBlockedResponse(
            TargetRules.blockedSiteMessage(host: nil),
            tabId: target.tabId,
            profileName: listing.profileName
        )
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
    static func targetRulesResultRefusal(url: String?, tabId: Int?, profileName: String?) -> BridgeResponse? {
        let rules = TargetRulesStore.shared.rules
        if rules.blocksBrowser {
            return targetBlockedResponse(TargetRules.blockedBrowserMessage, tabId: tabId, profileName: profileName)
        }
        guard rules.blocksURL(url) else { return nil }
        return targetBlockedResponse(TargetRules.blockedSiteMessage(host: nil, afterResult: true), tabId: tabId, profileName: profileName)
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
