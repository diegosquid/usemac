import ApplicationServices
import Foundation
import UseMacProtocol

/// Site-rule preflight for native requests on Chromium windows.
public enum NativeBrowserSiteRules {
    public struct ProbeResult: Equatable, Sendable {
        public var axURL: String?
        public var bridgeURL: String?
        public var bridgeAmbiguous: Bool
        public var bridgeAvailable: Bool
        public var bridgeFailureReason: String?

        public init(
            axURL: String? = nil,
            bridgeURL: String? = nil,
            bridgeAmbiguous: Bool = false,
            bridgeAvailable: Bool = false,
            bridgeFailureReason: String? = nil
        ) {
            self.axURL = axURL
            self.bridgeURL = bridgeURL
            self.bridgeAmbiguous = bridgeAmbiguous
            self.bridgeAvailable = bridgeAvailable
            self.bridgeFailureReason = bridgeFailureReason
        }
    }

    public struct BridgeMatch: Equatable, Sendable {
        public var url: String?
        public var ambiguous: Bool
        /// True when any candidate active tab that could belong to this window is on a blocked site.
        public var blockedCandidateFound: Bool
    }

    /// True for Chromium-family desktop browsers, including the Chrome release channels.
    public static func isChromiumApp(bundleId: String?, name: String?) -> Bool {
        if let bundleId = nonempty(bundleId)?.lowercased() {
            let prefixes = [
                "com.google.chrome", "org.chromium.chromium", "com.brave.browser",
                "com.microsoft.edgemac", "company.thebrowser.browser", "com.operasoftware.opera"
            ]
            return prefixes.contains(where: bundleId.hasPrefix)
        }
        guard let name = nonempty(name)?.lowercased() else { return false }
        return name == "arc" || ["chrome", "chromium", "brave", "microsoft edge", "opera"].contains(where: name.contains)
    }

    /// True when `url` is a browser-restricted page that extensions cannot script (chrome://, Web Store, etc.).
    public static func isRestrictedBrowserURL(_ url: String?) -> Bool {
        guard let text = nonempty(url), let parsed = URL(string: text, encodingInvalidCharacters: false) else {
            return false
        }
        let path = parsed.path.lowercased()
        switch parsed.scheme?.lowercased() {
        case "chrome", "chrome-extension", "chrome-untrusted", "edge", "brave", "arc", "opera", "devtools", "view-source":
            return true
        case "about":
            // Foundation exposes no path for opaque about: URLs.
            let page = text.dropFirst("about:".count).prefix { $0 != "?" && $0 != "#" }.lowercased()
            return page != "blank" && page != "srcdoc"
        default:
            break
        }
        switch parsed.host?.lowercased() {
        case "chromewebstore.google.com", "addons.opera.com":
            return true
        case "chrome.google.com":
            return path == "/webstore" || path.hasPrefix("/webstore/")
        case "microsoftedge.microsoft.com":
            return path == "/addons" || path.hasPrefix("/addons/")
        default:
            return false
        }
    }

    /// Matches the window title against active tabs returned by the extension.
    public static func matchActiveTab(windowTitle: String?, tabs: [BrowserTabInfo], rules: TargetRules) -> BridgeMatch {
        let activeTabs = tabs.filter(\.active)
        let matches: [BrowserTabInfo]
        if let windowTitle = nonempty(windowTitle) {
            let title = pageTitle(from: windowTitle)
            matches = activeTabs.filter { tab in
                guard let tabTitle = nonempty(tab.title)?.lowercased() else { return false }
                return title == tabTitle || isTruncatedTitle(title, of: tabTitle) || isTruncatedTitle(tabTitle, of: title)
            }
        } else {
            matches = []
        }

        guard let first = matches.first else {
            return BridgeMatch(url: nil, ambiguous: !activeTabs.isEmpty, blockedCandidateFound: false)
        }
        let ambiguous = matches.contains { $0.url != first.url }
        return BridgeMatch(
            url: ambiguous || nonempty(first.url) == nil ? nil : first.url,
            ambiguous: ambiguous,
            blockedCandidateFound: matches.contains { rules.blocksURL($0.url) }
        )
    }

    /// Returns a refusal when the window's site is blocked or cannot be confirmed.
    public static func evaluate(rules: TargetRules, probe: ProbeResult, blockedCandidateFound: Bool = false) -> String? {
        guard rules.hasSiteRules else { return nil }
        if rules.blocksBrowser { return TargetRules.blockedBrowserMessage }

        let axURL = validURL(probe.axURL)
        let bridgeURL = validURL(probe.bridgeURL)
        if rules.blocksURL(axURL) || rules.blocksURL(bridgeURL) || blockedCandidateFound {
            return TargetRules.blockedSiteMessage(host: nil)
        }
        if axURL != nil || (bridgeURL != nil && !probe.bridgeAmbiguous) { return nil }

        let reason: String
        if probe.bridgeAmbiguous {
            reason = "multiple Chrome windows matched the window title"
        } else if let failure = probe.bridgeFailureReason, !failure.isEmpty {
            reason = failure
        } else if !probe.bridgeAvailable {
            reason = "the window's active URL could not be read via Accessibility and the Chrome extension is not connected"
        } else {
            reason = "the window's active tab URL is not known yet"
        }
        return TargetRules.unconfirmedSiteMessage(reason: reason)
    }

    /// Reads the active document URL from the window's accessibility tree, not from browser chrome text.
    public static func axWebAreaURL(pid: pid_t, windowTitle: String? = nil) -> String? {
        guard pid > 0 else { return nil }
        let window = WindowResolver.focusedWindow(pid: pid)?.element
            ?? nonempty(windowTitle).flatMap { WindowResolver.window(pid: pid, titleContains: $0) }
        guard let window else { return nil }

        let maxNodes = 80
        let maxDepth = 10
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var next = 0
        var foundWebArea = false

        while next < queue.count {
            let (element, depth) = queue[next]
            next += 1
            AXUIElementSetMessagingTimeout(element, 0.35)
            if attribute(kAXRoleAttribute, of: element) as? String == "AXWebArea" {
                foundWebArea = true
                if let url = documentURL(kAXURLAttribute, of: element) ?? documentURL(kAXDocumentAttribute, of: element) {
                    return url
                }
                // A frame inside the web area is not the active tab's document.
                continue
            }

            guard depth < maxDepth, queue.count < maxNodes,
                  let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else { continue }
            let count = maxNodes - queue.count
            queue.append(contentsOf: children.prefix(count).map { ($0, depth + 1) })
        }

        return foundWebArea ? nil : documentURL(kAXDocumentAttribute, of: window)
    }

    /// Checks the selected Chromium app before a native request can read or act on it.
    public static func blockedMessage(
        for app: AppDescriptor,
        rules: TargetRules = TargetRulesStore.shared.rules,
        chromeBridge: ChromeExtensionBridge? = nil
    ) async -> String? {
        guard isChromiumApp(bundleId: app.bundleId, name: app.name), rules.hasSiteRules else { return nil }
        if rules.blocksBrowser { return TargetRules.blockedBrowserMessage }

        let axURL = axWebAreaURL(pid: app.pid, windowTitle: app.windowTitle)
        var probe = ProbeResult(axURL: axURL)
        guard axURL == nil, let chromeBridge else { return evaluate(rules: rules, probe: probe) }

        let profiles = chromeBridge.connectedProfiles()
        guard !profiles.isEmpty else { return evaluate(rules: rules, probe: probe) }
        probe.bridgeAvailable = true

        guard Set(profiles.map { $0.profileName.lowercased() }).count == profiles.count else {
            probe.bridgeFailureReason = "multiple Chrome profiles share the same name"
            return evaluate(rules: rules, probe: probe)
        }
        let profileQueries: [String?] = profiles.count == 1 ? [nil] : profiles.map { $0.profileName }

        var tabs: [BrowserTabInfo] = []
        for profile in profileQueries {
            let listing = await chromeBridge.unfilteredTabs(
                profile: profile,
                timeoutSeconds: ChromeExtensionBridge.targetRulesLookupTimeoutSeconds
            )
            if !listing.ok {
                probe.bridgeFailureReason = "the tab lookup failed"
            } else if let profileTabs = listing.tabs {
                tabs.append(contentsOf: profileTabs)
            } else {
                probe.bridgeFailureReason = "Chrome did not list its tabs"
            }
        }

        let match = matchActiveTab(windowTitle: app.windowTitle, tabs: tabs, rules: rules)
        // A partial list can identify a blocked candidate but cannot confirm a unique allowed tab.
        if probe.bridgeFailureReason == nil { probe.bridgeURL = match.url }
        probe.bridgeAmbiguous = match.ambiguous
        return evaluate(rules: rules, probe: probe, blockedCandidateFound: match.blockedCandidateFound)
    }

    private static func nonempty(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func pageTitle(from windowTitle: String) -> String {
        // The greedy first group preserves browser names occurring in the page title itself.
        let browserSuffix = #"^(.+)\s+[-—–]\s+(?:Google Chrome(?: (?:Beta|Canary|Dev))?|Chromium|Brave(?: Browser)?|Microsoft Edge(?: (?:Beta|Canary|Dev))?|Arc|Opera(?: GX)?)(?:\s+[-—–]\s+.+)?$"#
        return windowTitle.replacingOccurrences(of: browserSuffix, with: "$1", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isTruncatedTitle(_ title: String, of fullTitle: String) -> Bool {
        guard let ellipsis = ["…", "..."].first(where: title.hasSuffix),
              let prefix = nonempty(String(title.dropLast(ellipsis.count))) else { return false }
        return fullTitle.hasPrefix(prefix)
    }

    private static func validURL(_ raw: String?) -> String? {
        guard let text = nonempty(raw), let url = URL(string: text, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased() else { return nil }
        let address = text.dropFirst(scheme.count + 1)
        switch scheme {
        case "http", "https", "ws", "wss", "chrome", "chrome-extension", "chrome-untrusted", "edge", "brave", "arc", "opera", "devtools":
            guard address.hasPrefix("//"), url.host?.isEmpty == false else { return nil }
        case "file":
            guard address.hasPrefix("//"), url.path.hasPrefix("/") else { return nil }
        case "about":
            guard !address.isEmpty else { return nil }
        case "blob":
            let hasOpaqueOrigin = address.hasPrefix("null/") && address.count > "null/".count
            let hasFileOrigin = address.hasPrefix("file:///") && address.count > "file:///".count
            guard hasOpaqueOrigin || hasFileOrigin || TargetRules.host(ofURL: text) != nil else { return nil }
        default:
            return nil
        }
        return text
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func documentURL(_ name: String, of element: AXUIElement) -> String? {
        let value = attribute(name, of: element)
        if let url = value as? URL { return validURL(url.absoluteString) }
        return validURL(value as? String)
    }
}
