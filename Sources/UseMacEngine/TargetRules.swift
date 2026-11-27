import AppKit
import Foundation
import UseMacProtocol

/// The user's app and site rules (Settings → App and site rules): apps, by bundle ID, and sites, by host pattern,
/// that agents can use, must ask before acting on, can only read, or may never touch. Blocked targets fail with
/// TARGET_BLOCKED, the live preview never streams them, and `list_apps` / `browser_tabs` leave them out.
///
/// Only the user edits the rules, in UseMac's Settings. No socket, MCP or CLI method changes them.
public struct TargetRules: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Everything except the denied apps and sites.
        case deny
        /// Only the allowed apps and sites. Denied ones stay blocked as well.
        case allow
    }

    public enum AccessPolicy: String, Codable, CaseIterable, Sendable {
        case allow
        case ask
        case readOnly
        case block

        /// The more restrictive policy across all targets a request can reach.
        func combined(with other: Self) -> Self {
            if self == .block || other == .block { return .block }
            if self == .readOnly || other == .readOnly { return .readOnly }
            if self == .ask || other == .ask { return .ask }
            return .allow
        }
    }

    public var mode: Mode
    /// Bundle IDs. A trailing `*` matches any bundle ID that starts with the rest (`com.1password.*`).
    public var deniedApps: [String]
    /// Host patterns: `example.com` matches the host and its subdomains, `.example.com` only that host, and
    /// `host:port` only that port.
    public var deniedSites: [String]
    public var allowedApps: [String]
    public var allowedSites: [String]
    public var askApps: [String]
    public var askSites: [String]
    public var readOnlyApps: [String]
    public var readOnlySites: [String]

    public init(
        mode: Mode = .deny,
        deniedApps: [String] = [],
        deniedSites: [String] = [],
        allowedApps: [String] = [],
        allowedSites: [String] = [],
        askApps: [String] = [],
        askSites: [String] = [],
        readOnlyApps: [String] = [],
        readOnlySites: [String] = []
    ) {
        self.mode = mode
        self.deniedApps = deniedApps
        self.deniedSites = deniedSites
        self.allowedApps = allowedApps
        self.allowedSites = allowedSites
        self.askApps = askApps
        self.askSites = askSites
        self.readOnlyApps = readOnlyApps
        self.readOnlySites = readOnlySites
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try values.decode(Mode.self, forKey: .mode),
            deniedApps: try values.decode([String].self, forKey: .deniedApps),
            deniedSites: try values.decode([String].self, forKey: .deniedSites),
            allowedApps: try values.decode([String].self, forKey: .allowedApps),
            allowedSites: try values.decode([String].self, forKey: .allowedSites),
            askApps: try values.decodeIfPresent([String].self, forKey: .askApps) ?? [],
            askSites: try values.decodeIfPresent([String].self, forKey: .askSites) ?? [],
            readOnlyApps: try values.decodeIfPresent([String].self, forKey: .readOnlyApps) ?? [],
            readOnlySites: try values.decodeIfPresent([String].self, forKey: .readOnlySites) ?? []
        )
    }

    // MARK: - Defaults

    /// Password managers and Keychain Access. Bundle IDs checked against the apps' Info.plist (Apple's on macOS 15)
    /// or the vendors' published IDs.
    public static let defaultDeniedApps: [String] = [
        "com.apple.keychainaccess",   // Keychain Access
        "com.apple.Passwords",        // Passwords (macOS 15)
        "com.1password.*",            // 1Password 8 (com.1password.1password)
        "com.agilebits.onepassword*", // 1Password 7 and older (com.agilebits.onepassword7, …-osx)
        "com.bitwarden.desktop",      // Bitwarden
        "org.keepassxc.keepassxc",    // KeePassXC
        "com.dashlane.*"              // Dashlane (com.dashlane.Dashlane)
    ]

    /// Password managers' web vaults.
    public static let defaultDeniedSites: [String] = [
        "passwords.google.com",
        "1password.com",
        "1password.eu",
        "1password.ca",
        "vault.bitwarden.com",
        "vault.bitwarden.eu",
        "app.dashlane.com"
    ]

    public static let defaults = TargetRules(
        mode: .deny,
        deniedApps: defaultDeniedApps,
        deniedSites: defaultDeniedSites
    )

    /// Names to show for the default patterns, which do not name one installed app.
    public static let knownAppNames: [String: String] = [
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.passwords": "Passwords",
        "com.1password.*": "1Password",
        "com.agilebits.onepassword*": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.dashlane.*": "Dashlane"
    ]

    /// Chrome's bundle ID. Denying Chrome as an app also blocks the browser tools.
    public static let chromeBundleId = "com.google.Chrome"

    // MARK: - Messages

    public static let errorCode = "TARGET_BLOCKED"
    static let stopHint = "Stop and tell the user: only they can change the rules, in UseMac Settings → General → App and site rules."

    public static func blockedAppMessage(_ appName: String?) -> String {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (name?.isEmpty == false) ? name! : "This app"
        return "\(subject) is blocked by the user's UseMac rules, so nothing ran. \(stopHint)"
    }

    /// `afterResult`: the command ran and its page ended up on a blocked site, so its result was withheld.
    public static func blockedSiteMessage(host: String?, afterResult: Bool = false) -> String {
        let subject = host.map { "This site (\($0))" } ?? "This tab's site"
        let outcome = afterResult ? "so UseMac withheld the result" : "so nothing ran"
        return "\(subject) is blocked by the user's UseMac rules, \(outcome). \(stopHint)"
    }

    public static func readOnlyAppMessage(_ appName: String?) -> String {
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (name?.isEmpty == false) ? name! : "This app"
        return "\(subject) is set to Read-only in the user's UseMac rules, so mutating actions are blocked (observe and screenshot still work). \(stopHint)"
    }

    public static func readOnlySiteMessage(host: String?) -> String {
        let subject = host.map { "This site (\($0))" } ?? "This tab's site"
        return "\(subject) is set to Read-only in the user's UseMac rules, so mutating browser actions are blocked (observe, extract and screenshot still work). \(stopHint)"
    }

    /// The site rules could not be checked for the tab a command would run on, so it was refused.
    public static func unconfirmedSiteMessage(reason: String) -> String {
        "UseMac couldn't confirm this tab's site against the user's rules (\(reason)), so nothing ran. Retry once; if it fails again, stop and tell the user."
    }

    public static let blockedBrowserMessage = "Google Chrome is blocked by the user's UseMac rules, so nothing ran. \(stopHint)"

    // MARK: - Decisions

    /// True when automation may not touch the app with this bundle ID. In allow mode an app without a bundle ID
    /// is blocked, since it cannot be on the allow list.
    public func blocksApp(bundleId: String?) -> Bool {
        let id = (bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, deniedApps.contains(where: { Self.appPattern($0, matches: id) }) {
            return true
        }
        guard mode == .allow else { return false }
        return id.isEmpty || !(allowedApps + readOnlyApps + askApps).contains { Self.appPattern($0, matches: id) }
    }

    /// True when Chrome itself is denied, which blocks every browser tool. Allow mode does not need Chrome listed:
    /// the site rules decide there.
    public var blocksBrowser: Bool {
        deniedApps.contains(where: { Self.appPattern($0, matches: Self.chromeBundleId) })
    }

    /// True when automation may not touch a page at `url`. An empty URL (unknown) and about:blank are never
    /// blocked. In allow mode a page that is not on an allowed site, or has no host at all, is blocked.
    public func blocksURL(_ url: String?) -> Bool {
        let raw = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.lowercased() != "about:blank" else { return false }
        let site = Self.site(ofURL: raw)
        if let site, deniedSites.contains(where: { Self.sitePattern($0, matches: site) }) {
            return true
        }
        guard mode == .allow else { return false }
        guard let site else { return true }
        return !(allowedSites + readOnlySites + askSites).contains { Self.sitePattern($0, matches: site) }
    }

    public func effectiveAppPolicy(bundleId: String?) -> AccessPolicy {
        if blocksApp(bundleId: bundleId) { return .block }
        let id = (bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .allow }
        if readOnlyApps.contains(where: { Self.appPattern($0, matches: id) }) { return .readOnly }
        if askApps.contains(where: { Self.appPattern($0, matches: id) }) { return .ask }
        return .allow
    }

    public func effectiveSitePolicy(url: String?) -> AccessPolicy {
        if blocksURL(url) { return .block }
        guard let site = Self.site(ofURL: (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .allow
        }
        if readOnlySites.contains(where: { Self.sitePattern($0, matches: site) }) { return .readOnly }
        if askSites.contains(where: { Self.sitePattern($0, matches: site) }) { return .ask }
        return .allow
    }

    /// True when some page could be blocked, so a browser command has to look up its tab's URL first.
    public var hasSiteRules: Bool {
        mode == .allow || !deniedSites.isEmpty || blocksBrowser
    }

    /// True when a mutating request must know its site's policy before it runs.
    public var hasGovernedSiteRules: Bool {
        hasSiteRules || !readOnlySites.isEmpty || !askSites.isEmpty
    }

    /// The host shown in a refusal, or nil for a URL without one.
    public static func host(ofURL url: String?) -> String? {
        site(ofURL: (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines))?.host
    }

    // MARK: - Matching

    /// Case-insensitive bundle ID match; a trailing `*` matches the prefix before it.
    public static func appPattern(_ pattern: String, matches bundleId: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = bundleId.lowercased()
        guard !p.isEmpty else { return false }
        if p.hasSuffix("*") {
            let prefix = String(p.dropLast())
            return !prefix.isEmpty && id.hasPrefix(prefix)
        }
        return id == p
    }

    struct Site: Equatable {
        let host: String
        let port: Int?
    }

    struct SitePattern: Equatable {
        let host: String
        let port: Int?
        /// `.example.com`: only that host, not its subdomains.
        let exactHost: Bool
    }

    static func sitePattern(_ pattern: String, matches site: Site) -> Bool {
        guard let p = parseSitePattern(pattern) else { return false }
        if let port = p.port, port != site.port { return false }
        if p.exactHost { return site.host == p.host }
        return site.host == p.host || site.host.hasSuffix("." + p.host)
    }

    /// Host and effective port of an absolute URL (Chrome's tab URLs, a normalized browser_open URL).
    static func site(ofURL raw: String) -> Site? {
        let isBlob = raw.prefix(5).lowercased() == "blob:"
        let address = isBlob ? String(raw.dropFirst(5)) : raw
        if isBlob {
            let prefix = address.prefix(8).lowercased()
            guard ["http://", "https://", "ws://", "wss://"].contains(where: prefix.hasPrefix) else { return nil }
        }
        guard let url = URL(string: address), let rawHost = url.host, let host = normalizedHost(rawHost) else {
            return nil
        }
        var port = url.port
        if port == nil {
            switch url.scheme?.lowercased() {
            case "http", "ws": port = 80
            case "https", "wss": port = 443
            default: port = nil
            }
        }
        return Site(host: host, port: port)
    }

    /// Public download URLs never contain credentials, query strings, or fragments.
    /// Blob URLs reveal only the web origin, not the object identifier.
    static func sanitizeDownloadURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBlob = trimmed.prefix(5).lowercased() == "blob:"
        let address = isBlob ? String(trimmed.dropFirst(5)) : trimmed
        let prefix = address.prefix(8).lowercased()
        guard prefix.hasPrefix("http://") || prefix.hasPrefix("https://"),
              var components = URLComponents(string: address),
              let host = components.host, normalizedHost(host) != nil else { return nil }

        components.scheme = components.scheme?.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if isBlob {
            components.path = ""
            return components.string.map { "blob:" + $0 }
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string
    }

    static func parseSitePattern(_ raw: String) -> SitePattern? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
        }
        // Drop any path, query or fragment someone pasted with the host.
        if let cut = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        var exactHost = false
        if text.hasPrefix("*.") {
            text.removeFirst(2)
        } else if text.hasPrefix(".") {
            exactHost = true
            text.removeFirst()
        }

        var hostPart = text
        var port: Int?
        if text.hasPrefix("[") {
            // [::1] or [::1]:8080
            guard let close = text.firstIndex(of: "]") else { return nil }
            hostPart = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let value = Int(rest.dropFirst()), (1...65535).contains(value) else { return nil }
                port = value
            } else if !rest.isEmpty {
                return nil
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            hostPart = String(text[..<colon])
            guard let value = Int(text[text.index(after: colon)...]), (1...65535).contains(value) else { return nil }
            port = value
        }
        guard let host = normalizedHost(hostPart) else { return nil }
        return SitePattern(host: host, port: port, exactHost: exactHost)
    }

    private static func normalizedHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "*" }) else {
            return nil
        }
        return host
    }

    // MARK: - Normalizing what the user types

    /// The stored form of a site the user typed or pasted (`https://Bank.com/login` → `bank.com`), or nil when
    /// it is not a host pattern.
    public static func normalizedSitePattern(_ raw: String) -> String? {
        guard let p = parseSitePattern(raw) else { return nil }
        let host = p.host.contains(":") ? "[\(p.host)]" : p.host
        return (p.exactHost ? "." : "") + host + (p.port.map { ":\($0)" } ?? "")
    }

    /// The stored form of a bundle ID pattern, or nil when it is not one.
    public static func normalizedAppPattern(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        let body = text.hasSuffix("*") ? String(text.dropLast()) : text
        guard !body.isEmpty, !body.contains("*") else { return nil }
        return text
    }

    /// Drops blanks, invalid entries and duplicates (case-insensitive), keeping the first spelling.
    public func normalized() -> TargetRules {
        func clean(_ items: [String], _ normalize: (String) -> String?) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for item in items {
                guard let value = normalize(item), seen.insert(value.lowercased()).inserted else { continue }
                out.append(value)
            }
            return out
        }
        return TargetRules(
            mode: mode,
            deniedApps: clean(deniedApps, Self.normalizedAppPattern),
            deniedSites: clean(deniedSites, Self.normalizedSitePattern),
            allowedApps: clean(allowedApps, Self.normalizedAppPattern),
            allowedSites: clean(allowedSites, Self.normalizedSitePattern),
            askApps: clean(askApps, Self.normalizedAppPattern),
            askSites: clean(askSites, Self.normalizedSitePattern),
            readOnlyApps: clean(readOnlyApps, Self.normalizedAppPattern),
            readOnlySites: clean(readOnlySites, Self.normalizedSitePattern)
        )
    }

    // MARK: - Filters for listings

    /// `list_apps` without the apps automation may not touch.
    public func visibleApps(_ apps: [AppDescriptor]) -> [AppDescriptor] {
        apps.filter { !blocksApp(bundleId: $0.bundleId) }
    }

    /// `browser_tabs` without the tabs on blocked sites.
    public func visibleTabs(_ tabs: [BrowserTabInfo]) -> [BrowserTabInfo] {
        tabs.filter { !blocksURL($0.url) }
    }
}

/// The rules UseMac enforces. The app replaces them at launch with the sealed ones (SafetySettingsStore) and saves
/// changes through `persistHandler`, so they are never written unsealed. Only UseMac's Settings call `update`.
public final class TargetRulesStore: @unchecked Sendable {
    public static let shared = TargetRulesStore()

    /// Posted on the main queue after `update`.
    public static let didChangeNotification = Notification.Name("app.usemac.targetRulesDidChange")

    enum Keys {
        static let mode = "usemac.rules.mode"
        static let deniedApps = "usemac.rules.deniedApps"
        static let deniedSites = "usemac.rules.deniedSites"
        static let allowedApps = "usemac.rules.allowedApps"
        static let allowedSites = "usemac.rules.allowedSites"
        static let askApps = "usemac.rules.askApps"
        static let askSites = "usemac.rules.askSites"
        static let readOnlyApps = "usemac.rules.readOnlyApps"
        static let readOnlySites = "usemac.rules.readOnlySites"
    }

    private let lock = NSLock()
    private var _rules: TargetRules
    private var _persistHandler: ((TargetRules) -> Void)?

    /// Saves rules for `update(_:persist: true)`. The app sets it to `SafetySettingsStore.saveRules`; without it
    /// (tests, the CLI's own engine) nothing is saved.
    public var persistHandler: ((TargetRules) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _persistHandler }
        set { lock.lock(); _persistHandler = newValue; lock.unlock() }
    }

    /// `defaults` nil keeps the rules in memory only (tests). A list that was never saved uses the defaults.
    public init(defaults: UserDefaults? = .standard) {
        self._rules = defaults.map(Self.load(from:)) ?? .defaults
    }

    public var rules: TargetRules {
        lock.lock()
        defer { lock.unlock() }
        return _rules
    }

    /// Replaces the rules. Called from UseMac's Settings only; nothing on the socket reaches it.
    public func update(_ rules: TargetRules, persist: Bool = true) {
        let cleaned = rules.normalized()
        lock.lock()
        _rules = cleaned
        let handler = _persistHandler
        lock.unlock()
        if persist {
            handler?(cleaned)
        }
        let post = { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    static func load(from defaults: UserDefaults) -> TargetRules {
        let base = TargetRules.defaults
        let mode = defaults.string(forKey: Keys.mode).flatMap(TargetRules.Mode.init(rawValue:)) ?? base.mode
        return TargetRules(
            mode: mode,
            deniedApps: defaults.stringArray(forKey: Keys.deniedApps) ?? base.deniedApps,
            deniedSites: defaults.stringArray(forKey: Keys.deniedSites) ?? base.deniedSites,
            allowedApps: defaults.stringArray(forKey: Keys.allowedApps) ?? base.allowedApps,
            allowedSites: defaults.stringArray(forKey: Keys.allowedSites) ?? base.allowedSites,
            askApps: defaults.stringArray(forKey: Keys.askApps) ?? [],
            askSites: defaults.stringArray(forKey: Keys.askSites) ?? [],
            readOnlyApps: defaults.stringArray(forKey: Keys.readOnlyApps) ?? [],
            readOnlySites: defaults.stringArray(forKey: Keys.readOnlySites) ?? []
        ).normalized()
    }

    // MARK: - Checks used by the guards

    public func blocksApp(bundleId: String?) -> Bool {
        rules.blocksApp(bundleId: bundleId)
    }

    /// True when the process belongs to a blocked app. Processes without an app (no NSRunningApplication) are
    /// not apps the rules can name, so they are never blocked here.
    public func blocksProcess(pid: pid_t) -> Bool {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return rules.blocksApp(bundleId: app.bundleIdentifier)
    }

    public func blocksURL(_ url: String?) -> Bool {
        rules.blocksURL(url)
    }

    /// The TARGET_BLOCKED message when the rules block `app`, else nil.
    public func blockedMessage(for app: AppDescriptor?) -> String? {
        guard let app, rules.blocksApp(bundleId: app.bundleId) else { return nil }
        return TargetRules.blockedAppMessage(app.name)
    }

    /// The TARGET_BLOCKED message for the first of `queries` that names a running app the rules block, else nil.
    public func blockedMessage(forQueries queries: [String?], in monitor: WorkspaceMonitor) -> String? {
        for query in queries {
            if let message = blockedMessage(for: monitor.namedApp(query)) {
                return message
            }
        }
        return nil
    }

    public func readOnlyMessage(for app: AppDescriptor?) -> String? {
        guard let app, rules.effectiveAppPolicy(bundleId: app.bundleId) == .readOnly else { return nil }
        return TargetRules.readOnlyAppMessage(app.name)
    }

    public func readOnlyMessage(forQueries queries: [String?], in monitor: WorkspaceMonitor) -> String? {
        for query in queries {
            if let message = readOnlyMessage(for: monitor.namedApp(query)) {
                return message
            }
        }
        return nil
    }

    public func requiresAsk(for app: AppDescriptor?) -> Bool {
        guard let app else { return false }
        return rules.effectiveAppPolicy(bundleId: app.bundleId) == .ask
    }
}
