import Foundation
import SystemConfiguration
import UseMacProtocol

/// Problem reports (`report_prepare`): an agent asks UseMac for a draft about a failed task, UseMac shows it to the
/// user in a review window, and only the user opens it as a GitHub issue. This file holds the pure parts: what a
/// draft contains, the second redaction pass, and the issue link.
public enum ProblemReport {
    /// UseMac's GitHub repository, where reports become issues. `scripts/release-dmg.sh` publishes releases there too.
    public static let githubRepository = "diegosquid/usemac"
    /// The app's review window, as agents are told to point the user to it.
    public static let reviewWindowTitle = "Review problem report"
    /// A draft lists at most this many audit entries: the most recent ones.
    public static let maxEntries = 40
    /// Without a task, a draft covers this much recent activity.
    public static let recentMinutes = 30
    /// Each audit summary is cut to this length.
    public static let maxEntrySummaryLength = 160
    /// The method name, left out of the activity a draft lists (a report never reports itself).
    static let ownMethod = RPCMethod.reportPrepare.rawValue
}

/// What a draft covers.
public enum ProblemReportScope: Equatable, Sendable {
    /// The audit entries of this task.
    case task(String)
    /// The audit entries of the last `minutes`, any task.
    case recent(minutes: Int)

    public var taskId: String? {
        if case .task(let id) = self { return id }
        return nil
    }
}

/// An error code a request answered with, kept in memory so a draft can list the task's codes (audit entries don't
/// carry them).
public struct ProblemReportFailure: Equatable, Sendable {
    public var timestampMs: Int64
    public var taskId: String?
    public var method: String
    /// The `act` or `browser_act` step that failed, when the code came from a step.
    public var step: String?
    public var code: String

    public init(timestampMs: Int64, taskId: String?, method: String, step: String? = nil, code: String) {
        self.timestampMs = timestampMs
        self.taskId = taskId
        self.method = method
        self.step = step
        self.code = code
    }

    /// The codes in a response: the request's own, and each failed step's.
    static func notes(in response: RPCResponse, method: RPCMethod, taskId: String?, now: Date = Date()) -> [ProblemReportFailure] {
        guard method != .reportPrepare else { return [] }
        let timestampMs = Int64(now.timeIntervalSince1970 * 1000)
        var notes: [ProblemReportFailure] = []
        if !response.ok, let code = response.error?.code, !code.isEmpty {
            notes.append(ProblemReportFailure(timestampMs: timestampMs, taskId: taskId, method: method.rawValue, code: code))
        }
        for step in response.actionResult?.stepResults ?? [] where !step.success {
            guard let code = step.errorCode, !code.isEmpty else { continue }
            notes.append(ProblemReportFailure(timestampMs: timestampMs, taskId: taskId, method: method.rawValue, step: step.action.rawValue, code: code))
        }
        return notes
    }
}

/// The Mac and UseMac setup a draft describes. Never the user's name, Chrome profile names or emails.
public struct ProblemReportEnvironment: Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var macOSVersion: String
    public var architecture: String
    public var executionMode: String
    public var killSwitchTripped: Bool
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool
    /// One line per kind of connected Chrome extension, e.g. `0.6.0 from UseMac.app (2 profiles)`. Empty: none connected.
    public var chromeExtensions: [String]

    public init(
        appVersion: String,
        appBuild: String,
        macOSVersion: String,
        architecture: String,
        executionMode: String,
        killSwitchTripped: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        chromeExtensions: [String]
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.executionMode = executionMode
        self.killSwitchTripped = killSwitchTripped
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.chromeExtensions = chromeExtensions
    }

    /// This Mac, from the daemon's status and the running app's Info.plist.
    public static func current(status: DaemonStatus, bundle: Bundle = .main) -> ProblemReportEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return ProblemReportEnvironment(
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? status.version,
            appBuild: (info["CFBundleVersion"] as? String) ?? UseMacDefaults.buildNumber,
            macOSVersion: osVersion.hasPrefix("Version ") ? String(osVersion.dropFirst("Version ".count)) : osVersion,
            architecture: architecture,
            executionMode: status.policy.rawValue,
            killSwitchTripped: status.killSwitchTripped,
            accessibilityGranted: status.permissions.accessibilityGranted,
            screenRecordingGranted: status.permissions.screenRecordingGranted,
            chromeExtensions: extensionLines(status.browserProfiles)
        )
    }

    /// The connected extensions without the profiles' names or emails: version, where Chrome loads it from, and
    /// whether it is older than the app's copy. Identical lines are counted once.
    static func extensionLines(_ profiles: [BrowserProfileStatus]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for profile in profiles {
            var line = profile.extensionVersion.isEmpty ? "unknown version" : profile.extensionVersion
            switch profile.extensionSource {
            case "app": line += " from UseMac.app"
            case "web_store": line += " from the Chrome Web Store"
            case "other_folder": line += " unpacked from another folder"
            default: break
            }
            if profile.extensionOutdated == true {
                line += ", outdated" + (profile.bundledExtensionVersion.map { " (the app ships \($0))" } ?? "")
            }
            if counts[line] == nil { order.append(line) }
            counts[line, default: 0] += 1
        }
        return order.map { line in
            let count = counts[line] ?? 1
            return count > 1 ? "\(line) (\(count) profiles)" : line
        }
    }
}

/// A report draft as the review window shows it, before the user edits it.
public struct ProblemReportDraft: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var taskId: String?
    public var entryCount: Int
    /// Most frequent first.
    public var errorCodes: [String]

    public init(id: String, title: String, body: String, taskId: String?, entryCount: Int, errorCodes: [String]) {
        self.id = id
        self.title = title
        self.body = body
        self.taskId = taskId
        self.entryCount = entryCount
        self.errorCodes = errorCodes
    }
}

// MARK: - Composing

public enum ProblemReportComposer {
    /// Builds the draft and runs the second redaction pass over all of it (title and body, the agent's text included).
    /// - Parameters:
    ///   - entries: the scope's audit entries, newest first (as `audit_log` returns them). Already redacted once by
    ///     `AuditRedactor`.
    ///   - chromeProfileNames: connected profile names, which audit entries use as the app name; the draft says
    ///     "Chrome" instead.
    public static func compose(
        id: String = UUID().uuidString,
        summary: String,
        title: String?,
        scope: ProblemReportScope,
        entries newestFirst: [AuditEntry],
        failures: [ProblemReportFailure],
        environment: ProblemReportEnvironment,
        chromeProfileNames: Set<String> = [],
        redactor: ProblemReportRedactor = .forCurrentUser()
    ) -> ProblemReportDraft {
        let relevant = newestFirst.filter { $0.method != ProblemReport.ownMethod }
        let shown = Array(relevant.prefix(ProblemReport.maxEntries).reversed())
        let codes = codeCounts(failures)

        var body = "### What happened\n\n\(summary)\n\n"
        body += "### Environment\n\n" + environmentLines(environment).map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        body += "### Error codes\n\n"
        if codes.isEmpty {
            body += "None recorded. UseMac keeps error codes only since it last started.\n\n"
        } else {
            body += codes.map { "- `\($0.code)` in \($0.place) (\($0.count)×)" }.joined(separator: "\n") + "\n\n"
        }
        body += "### Activity\n\n" + scopeLine(scope, shown: shown.count, total: relevant.count) + "\n"
        if !shown.isEmpty {
            body += "\n```text\n" + activityLines(shown, chromeProfileNames: chromeProfileNames).joined(separator: "\n") + "\n```\n"
        }
        body += "\n---\nPrepared by UseMac (`report_prepare`) from its local audit log and checked by the user before opening this issue. "
            + "Typed text, emails, tokens and keys, the home folder, URL query strings and long numbers were removed. No screenshots.\n"

        let rawTitle = title ?? defaultTitle(from: summary)
        var orderedCodes: [String] = []
        for entry in codes where !orderedCodes.contains(entry.code) {
            orderedCodes.append(entry.code)
        }
        return ProblemReportDraft(
            id: id,
            title: redactor.redact(rawTitle),
            body: redactor.redact(body),
            taskId: scope.taskId,
            entryCount: shown.count,
            errorCodes: orderedCodes
        )
    }

    /// The first line of the summary, cut at a word to about 80 characters.
    static func defaultTitle(from summary: String) -> String {
        let firstLine = summary.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? summary
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.count > 80 else { return line }
        let cut = line.prefix(80)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func environmentLines(_ env: ProblemReportEnvironment) -> [String] {
        let granted = { (ok: Bool) in ok ? "granted" : "not granted" }
        return [
            "UseMac \(env.appVersion) (build \(env.appBuild))",
            "macOS \(env.macOSVersion), \(env.architecture)",
            "Execution mode: `\(env.executionMode)`" + (env.killSwitchTripped ? ", Kill Switch on" : ""),
            "Permissions: Accessibility \(granted(env.accessibilityGranted)), Screen Recording \(granted(env.screenRecordingGranted))",
            "Chrome extension: " + (env.chromeExtensions.isEmpty ? "not connected" : env.chromeExtensions.joined(separator: "; "))
        ]
    }

    static func scopeLine(_ scope: ProblemReportScope, shown: Int, total: Int) -> String {
        let what: String
        switch scope {
        case .task(let id):
            what = "Task `\(id)`"
        case .recent(let minutes):
            what = "No task named, so this is the last \(minutes) minutes of activity"
        }
        if total == 0 {
            return "\(what): no audit entries."
        }
        let count = shown == total
            ? "\(total) audit entr\(total == 1 ? "y" : "ies")"
            : "the last \(shown) of \(total) audit entries"
        return "\(what): \(count), oldest first. Typed text appears only as its length."
    }

    /// `+0:03.2  FAILED  1.4 s   act         TextEdit  Executed 1 step(s): failed · click`
    static func activityLines(_ oldestFirst: [AuditEntry], chromeProfileNames: Set<String>) -> [String] {
        guard let start = oldestFirst.first?.timestampMs else { return [] }
        let methodWidth = min(24, oldestFirst.map(\.method.count).max() ?? 0)
        let apps = oldestFirst.map { appLabel($0.targetApp, chromeProfileNames: chromeProfileNames) }
        let appWidth = min(24, apps.map(\.count).max() ?? 0)
        return zip(oldestFirst, apps).map { entry, app in
            let offset = offsetLabel(ms: entry.timestampMs - start)
            let result = entry.success ? "ok    " : "FAILED"
            let latency = latencyLabel(entry.latencyMs).padding(toLength: 7, withPad: " ", startingAt: 0)
            let method = entry.method.padding(toLength: methodWidth, withPad: " ", startingAt: 0)
            let appColumn = String(app.prefix(appWidth)).padding(toLength: appWidth, withPad: " ", startingAt: 0)
            return "\(offset)  \(result)  \(latency)  \(method)  \(appColumn)  \(oneLine(entry.summary))"
                .trimmingCharacters(in: .whitespaces)
        }
    }

    static func appLabel(_ app: String?, chromeProfileNames: Set<String>) -> String {
        guard let app, !app.isEmpty else { return "-" }
        if chromeProfileNames.contains(app) || app.hasPrefix("Chrome (") { return "Chrome" }
        return app
    }

    static func offsetLabel(ms: Int64) -> String {
        let seconds = Double(max(0, ms)) / 1000
        if seconds >= 3600 {
            let total = Int(seconds)
            return String(format: "+%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        let minutes = Int(seconds / 60)
        return String(format: "+%d:%04.1f", minutes, seconds - Double(minutes * 60))
    }

    /// Kept to at most four digits, so a latency never reads as a long number to redact.
    static func latencyLabel(_ ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "-" }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.1f s", ms / 1000)
    }

    /// The summary on one line, cut to `maxEntrySummaryLength`, with nothing that could end the code block.
    static func oneLine(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "```", with: "'''")
        return flat.count > ProblemReport.maxEntrySummaryLength
            ? String(flat.prefix(ProblemReport.maxEntrySummaryLength)) + "…"
            : flat
    }

    struct CodeCount: Equatable {
        var code: String
        var place: String
        var count: Int
    }

    /// One line per code and place (`act › click`), most frequent first, then in the order they first happened.
    static func codeCounts(_ failures: [ProblemReportFailure]) -> [CodeCount] {
        var counts: [CodeCount] = []
        for failure in failures.sorted(by: { $0.timestampMs < $1.timestampMs }) {
            let place = failure.step.map { "\(failure.method) › \($0)" } ?? failure.method
            if let index = counts.firstIndex(where: { $0.code == failure.code && $0.place == place }) {
                counts[index].count += 1
            } else {
                counts.append(CodeCount(code: failure.code, place: place, count: 1))
            }
        }
        return counts.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
    }
}

// MARK: - Second redaction pass

/// Removes what a report must not carry, over the whole draft: private keys, the home folder (→ `~`) and other users'
/// folders, URL credentials, query strings and fragments, emails, bearer tokens and `password=`-style values, known
/// API key and token formats, long id-like strings, long digit runs, IPv4 addresses, quoted window titles, Chrome
/// profile names in `Chrome (…)`, and the user's full name, account name and computer name.
///
/// It is a safety net, not a guarantee: the review window is where the user checks what is left.
public struct ProblemReportRedactor: Sendable {
    public struct Identity: Equatable, Sendable {
        public var text: String
        public var placeholder: String

        public init(_ text: String, placeholder: String) {
            self.text = text
            self.placeholder = placeholder
        }
    }

    public var homeDirectory: String?
    /// Names to replace wherever they appear as a whole word, case-insensitively.
    public var identities: [Identity]

    public init(homeDirectory: String?, identities: [Identity] = []) {
        self.homeDirectory = homeDirectory
        self.identities = identities
    }

    /// This user's home folder, full name, account name and this Mac's name.
    public static func forCurrentUser() -> ProblemReportRedactor {
        var identities: [Identity] = []
        // Not Host.current(), which can wait on the network to resolve names.
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            identities.append(Identity(computer, placeholder: "[computer name]"))
        }
        identities.append(Identity(NSFullUserName(), placeholder: "[name]"))
        identities.append(Identity(NSUserName(), placeholder: "[user]"))
        return ProblemReportRedactor(homeDirectory: NSHomeDirectory(), identities: identities)
    }

    public func redact(_ text: String) -> String {
        var out = text
        out = Self.replace(Self.privateKey, in: out, with: "[private key]")
        if let home = homeDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !home.isEmpty,
           let pattern = try? NSRegularExpression(pattern: "/" + NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9._\-])"#) {
            out = Self.replace(pattern, in: out, with: "~")
        }
        out = Self.replace(Self.otherHome, in: out, with: "/Users/[user]")
        out = Self.replaceMatches(Self.url, in: out, transform: Self.redactURL)
        out = Self.replace(Self.email, in: out, with: "[email]")
        out = Self.replace(Self.bearer, in: out, with: "$1 [secret]")
        out = Self.replace(Self.keyValue, in: out, with: "$1$2[secret]")
        out = Self.replace(Self.knownToken, in: out, with: "[secret]")
        out = Self.replaceMatches(Self.longToken, in: out) { match in
            let hasLetter = match.contains { $0.isLetter }
            let hasDigit = match.contains { $0.isNumber }
            return hasLetter && hasDigit ? "[token]" : match
        }
        out = Self.replaceMatches(Self.ipv4, in: out) { match in
            match == "127.0.0.1" || match == "0.0.0.0" ? match : "[ip]"
        }
        out = Self.replace(Self.longNumber, in: out, with: "[number]")
        out = Self.replace(Self.windowTitle, in: out, with: "window \"[title]\"")
        out = Self.replace(Self.chromeProfile, in: out, with: "Chrome")
        for identity in identities {
            let name = identity.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Short names (an account called "dev") would hit ordinary words.
            guard name.count >= 4,
                  let pattern = try? NSRegularExpression(
                    pattern: #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![A-Za-z0-9])"#,
                    options: [.caseInsensitive]
                  ) else { continue }
            out = Self.replace(pattern, in: out, with: NSRegularExpression.escapedTemplate(for: identity.placeholder))
        }
        return out
    }

    /// `scheme://host/path` without credentials; the query and fragment become a placeholder. Trailing punctuation
    /// from the sentence around the URL stays outside it.
    static func redactURL(_ raw: String) -> String {
        var url = raw
        var trailing = ""
        while let last = url.last, ".,;:!?".contains(last) {
            trailing = String(last) + trailing
            url.removeLast()
        }
        guard let schemeEnd = url.range(of: "://") else { return raw }
        let rest = url[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = String(rest[..<authorityEnd])
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        var path = String(rest[authorityEnd...])
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query]) + "?[query removed]"
        } else if let fragment = path.firstIndex(of: "#") {
            path = String(path[..<fragment]) + "#[fragment removed]"
        }
        return String(url[..<schemeEnd.upperBound]) + authority + path + trailing
    }

    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a typo here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let privateKey = regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#)
    private static let otherHome = regex(#"/Users/(?!Shared(?![^/\s]))[^/\s"'<>:]+"#)
    private static let url = regex(#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>()\[\]{}`]+"#)
    private static let email = regex(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let bearer = regex(#"\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=\-]{8,}"#, [.caseInsensitive])
    private static let keyValue = regex(
        #"\b(password|passwd|passcode|pwd|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|client[_\-]?secret|auth[_\-]?token|cookie|session[_\-]?id|otp)\b(["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;"']+)"#,
        [.caseInsensitive]
    )
    private static let knownToken = regex(
        #"\b(?:sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,}|umk_[A-Za-z0-9_\-]{8,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})"#
    )
    private static let longToken = regex(#"(?<![A-Za-z0-9_\-+=])[A-Za-z0-9_\-+=]{24,}(?![A-Za-z0-9_\-+=])"#)
    private static let ipv4 = regex(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#)
    private static let longNumber = regex(#"(?<![\w\-])\+?\d(?:[ \-]?\d){5,}(?![\w])(?!\s?bytes)"#)
    private static let windowTitle = regex(#"window "[^"]*""#)
    private static let chromeProfile = regex(#"Chrome \([^()\n]{1,80}\)"#)

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func replaceMatches(_ regex: NSRegularExpression, in text: String, transform: (String) -> String) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: transform(String(out[range])))
        }
        return out
    }
}

// MARK: - Issue link

/// The `issues/new` link the review window opens. GitHub prefills the issue from `title` and `body`; the user
/// submits it there.
public enum ProblemReportIssueLink {
    /// GitHub refuses longer links. Past this, the body goes to the clipboard and the link carries a note instead.
    public static let maxURLLength = 8000
    public static let clipboardNote = "The full report is on your clipboard. Paste it here in place of this line, and check it once more before you submit."

    public struct Link: Equatable, Sendable {
        public var url: URL
        /// The body didn't fit: copy it to the clipboard before opening `url`.
        public var bodyOnClipboard: Bool
    }

    public static func make(
        title: String,
        body: String,
        repository: String = ProblemReport.githubRepository,
        maxLength: Int = maxURLLength
    ) -> Link {
        let base = "https://github.com/\(repository)/issues/new"
        let full = base + "?title=" + encode(title) + "&body=" + encode(body)
        if full.count <= maxLength, let url = URL(string: full) {
            return Link(url: url, bodyOnClipboard: false)
        }
        var shortTitle = title
        var short = base + "?title=" + encode(shortTitle) + "&body=" + encode(clipboardNote)
        while short.count > maxLength, !shortTitle.isEmpty {
            shortTitle = String(shortTitle.dropLast(max(1, shortTitle.count / 4)))
            short = base + "?title=" + encode(shortTitle) + "&body=" + encode(clipboardNote)
        }
        return Link(url: URL(string: short) ?? URL(string: base)!, bodyOnClipboard: true)
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters, so `+`, `&` and `#` in the text survive.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
