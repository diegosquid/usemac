import Foundation
import UseMacProtocol

/// The user's site rules (TargetRules) on the daemon side of the bridge, so they hold with any extension version:
/// a command is checked against the tab it would run on before it is sent, every result against its page's URL
/// before anything is written or handed back, and stream frames of blocked pages are dropped.
extension ChromeExtensionBridge {
    /// How long the tab lookup before a command may take. The extension answers it in milliseconds; when it does
    /// not, the command goes ahead and only the result check applies.
    static let targetRulesLookupTimeoutSeconds: UInt64 = 2

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
        guard listing.ok, let tabs = listing.tabs,
              let target = Self.commandTargetTab(requested: tabId, lastTabId: listing.tabId, in: tabs),
              rules.blocksURL(target.url) else {
            return nil
        }
        return Self.targetBlockedResponse(
            TargetRules.blockedSiteMessage(host: nil),
            tabId: target.tabId,
            profileName: listing.profileName
        )
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
        return targetBlockedResponse(TargetRules.blockedSiteMessage(host: nil), tabId: tabId, profileName: profileName)
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
