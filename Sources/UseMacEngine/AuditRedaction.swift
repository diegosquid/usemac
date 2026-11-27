import Foundation
import UseMacProtocol

/// The request being handled, so an audit entry can name its task and scrub what the request typed without every
/// call site passing the request along. Set by `UseMacEngineService.handle(_:)`.
enum AuditRequestContext {
    @TaskLocal static var request: RPCRequest?
}

extension RPCRequest {
    /// The task id and tab a request names, to tie its audit entry to a running task (`TaskTabRegistry.resolve`).
    var auditTaskHint: (taskId: String?, tabId: Int?) {
        // The envelope or params taskId (`namedTaskId`), or the id a task_start is about to give its task.
        (namedTaskId ?? taskStart?.taskId, namedTabId)
    }

    /// Text this request carries that the audit log must not copy: typed and set values, skill params, and page scripts.
    var auditSecrets: [String] {
        let steps = (act?.steps ?? [])
            + (browserAct?.steps ?? [])
            + (browserOpen?.steps ?? [])
            + (skillSave?.steps ?? [])
        var secrets = steps
            .filter { $0.action == .type || $0.action == .setValue }
            .compactMap(\.text)
        for step in steps where step.action == .fillForm {
            secrets.append(contentsOf: (step.fields ?? []).compactMap(\.value))
        }
        if let skillParams = skillRun?.params {
            secrets.append(contentsOf: skillParams.values)
        }
        if let expression = browserExtract?.expression {
            secrets.append(expression)
        }
        if let prompt = browserAct?.dialogPromptText {
            secrets.append(prompt)
        }
        if let openPrompt = browserOpen?.dialogPromptText {
            secrets.append(openPrompt)
        }
        return secrets
    }
}

/// Keeps the audit log from becoming a copy of what the user typed. By default typed text, set values and
/// `eval` sources are kept only as their length, and URLs lose their credentials and secret-looking query
/// values. Turning on "Record typed text" (`AuditLogSettings.recordsTypedText`) keeps ordinary text, but
/// explicit credentials and other recognizable sensitive data are still redacted.
public enum AuditRedactor {
    /// Shorter strings are not scrubbed from free text (error messages), where they would match ordinary words.
    static let minimumScrubLength = 4
    static let maxStepsDescribed = 8
    static let maxRecordedTextLength = 120

    /// The summary as the audit log stores it.
    static func scrub(_ summary: String, secrets: [String], recordText: Bool = AuditLogSettings.recordsTypedText) -> String {
        var out = summary
        if !recordText {
            for secret in Set(secrets).sorted(by: { $0.count > $1.count }) where secret.count >= minimumScrubLength {
                out = out.replacingOccurrences(of: secret, with: "[\(lengthLabel(secret))]")
            }
        }
        return scrubSensitivePatterns(in: redactURLs(in: out))
    }

    /// `type (14 chars), pressKey cmd+s, click` for an act or browser_act batch.
    static func describeSteps(_ steps: [ActionStep], recordText: Bool = AuditLogSettings.recordsTypedText) -> String {
        var parts = steps.prefix(maxStepsDescribed).map { describe($0, recordText: recordText) }
        if steps.count > maxStepsDescribed {
            parts.append("+\(steps.count - maxStepsDescribed) more")
        }
        return parts.joined(separator: ", ")
    }

    static func describe(_ step: ActionStep, recordText: Bool) -> String {
        let name = step.action.rawValue
        switch step.action {
        case .type, .setValue:
            let text = step.text ?? ""
            return recordText ? "\(name) \"\(recorded(text))\"" : "\(name) (\(lengthLabel(text)))"
        case .pressKey:
            return "\(name) \(keyLabel(step, recordText: recordText))"
        case .openURL, .navigate:
            guard let url = step.url ?? step.text, !url.isEmpty else { return name }
            return "\(name) \(redactURL(url))"
        case .uploadFile, .saveFile:
            let count = step.files?.count ?? 0
            return "\(name) (\(count) file\(count == 1 ? "" : "s"))"
        case .axAction:
            return step.actionName.map { "\(name) \($0)" } ?? name
        case .fillForm:
            let count = step.fields?.count ?? 0
            return "\(name) (\(count) field\(count == 1 ? "" : "s"))"
        case .menuAction:
            if let path = step.menuPath, !path.isEmpty {
                return "\(name) \(path.joined(separator: " > "))"
            }
            return name
        default:
            return name
        }
    }

    /// The `browser_extract` eval entry: the script's length, never its source unless text recording is on.
    static func evalSummary(_ expression: String, recordText: Bool = AuditLogSettings.recordsTypedText) -> String {
        let head = "Eval (\(expression.count) chars)"
        return recordText ? "\(head): \(recorded(expression))" : head
    }

    /// The `vision_query` entry. OCR reads the screen's text, so its answer is kept only as a length.
    static func visionSummary(mode: String, backend: String, answer: String, recordText: Bool = AuditLogSettings.recordsTypedText) -> String {
        if mode == "ocr", !recordText {
            return "Vision ocr [\(backend)]: read \(lengthLabel(answer))"
        }
        return "Vision \(mode) [\(backend)]: \(answer.prefix(80))"
    }

    // MARK: - Sensitive patterns

    private static let pemPattern = try! NSRegularExpression(
        pattern: #"-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY)-----(?:[\s\S]*?-----END \1-----|[^\r\n]*)"#
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)\bBearer[ \t]+[A-Za-z0-9._~+/\-]{8,}=*"#
    )
    private static let jwtPattern = try! NSRegularExpression(
        pattern: #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#
    )
    private static let tokenPattern = try! NSRegularExpression(pattern: [
        #"sk-(?:ant-)?[A-Za-z0-9_-]{12,}"#,
        #"[pr]k_(?:live|test)_[A-Za-z0-9]{12,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"glpat-[A-Za-z0-9_-]{16,}"#,
        #"xox[baprs]-[A-Za-z0-9-]{12,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"AIza[0-9A-Za-z_-]{20,}"#,
        #"umk_[A-Za-z0-9_-]{12,}"#
    ].joined(separator: "|"))
    private static let cookieHeaderPattern = try! NSRegularExpression(pattern: #"(?i)\b(cookie\h*:\h*)[^\r\n]+"#)
    private static let inlineSecretPattern = try! NSRegularExpression(pattern: [
        #"(?i)(?<![\w])(["']?(password|passwd|pwd|secret|api_key|apikey|access_token|refresh_token|auth_token|client_secret|private_key|authorization|cookie)["']?\h*[:=]\h*)"#,
        // These markers may already appear in persisted logs or in a URL just redacted by scrub(_:secrets:recordText:).
        #"(?:(\*\*\*|(?:Bearer\h+)?\[redacted(?:-[a-z]+)?\]|\[\d+ chars?\])(?=[\s&#;,()"'\]<>]|$)|"#,
        #"("(?:\\.|[^"\\\r\n])*(?:"|(?=[\r\n]|$))|'(?:\\.|[^'\\\r\n])*(?:'|(?=[\r\n]|$))|"#,
        #"(?:Bearer|Basic)\h+[^\s"'&#;,()\]<>]+|[^\s"'&#;,()\]<>]+))"#
    ].joined())
    private static let emailOutsideURLPattern = try! NSRegularExpression(
        pattern: urlPattern.pattern + #"|([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})"#
    )
    private static let documentPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9])(?:[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}|[0-9]{3}-[0-9]{2}-[0-9]{4})(?![0-9])"#
    )
    private static let cardPattern = try! NSRegularExpression(
        pattern: #"[0-9]+(?:[ -][0-9]+)*"#
    )

    /// Removes recognizable credentials and personal data even when recording typed text is enabled.
    public static func scrubSensitivePatterns(in text: String) -> String {
        var out = pemPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted-key]")
        // Cookie headers can contain several semicolon-separated values on the same line.
        out = cookieHeaderPattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1[redacted]")
        out = replacingMatches(in: out, of: inlineSecretPattern) { match, source in
            guard match.range(at: 3).location == NSNotFound else { return nil }
            let value = source.substring(with: match.range(at: 4))
            let key = source.substring(with: match.range(at: 2))
            let prefix = source.substring(with: match.range(at: 1))
            return key.lowercased() == "authorization" && value.lowercased().hasPrefix("bearer ")
                ? prefix + "Bearer [redacted]"
                : prefix + "[redacted]"
        }
        for (pattern, replacement) in [
            (bearerPattern, "Bearer [redacted]"),
            (jwtPattern, "[redacted-jwt]"),
            (tokenPattern, "[redacted-token]"),
            (documentPattern, "[redacted-id]")
        ] {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        out = replacingMatches(in: out, of: emailOutsideURLPattern) { match, _ in
            match.range(at: 1).location == NSNotFound ? nil : "[redacted-email]"
        }
        return replacingMatches(in: out, of: cardPattern) { match, source in
            redactCards(in: source.substring(with: match.range))
        }
    }

    private static func redactCards(in text: String) -> String? {
        guard text.utf8.count >= 13 else { return nil }
        let groups = text.split { $0 == " " || $0 == "-" }
        var ranges: [Range<String.Index>] = []
        var start = groups.startIndex
        while start < groups.endIndex {
            var digitCount = 0
            var validEnd: Int?
            // Try at digit-group boundaries: an adjacent number must not hide a valid card,
            // but we should never redact part of an uninterrupted longer number.
            for end in start..<groups.endIndex {
                digitCount += groups[end].utf8.count
                if digitCount > 19 { break }
                if digitCount >= 13, passesLuhn(text[groups[start].startIndex..<groups[end].endIndex]) {
                    validEnd = end
                }
            }
            if let validEnd {
                ranges.append(groups[start].startIndex..<groups[validEnd].endIndex)
                start = validEnd + 1
            } else {
                start += 1
            }
        }
        guard !ranges.isEmpty else { return nil }
        var result = text
        for range in ranges.reversed() { result.replaceSubrange(range, with: "[redacted-card]") }
        return result
    }

    private static func passesLuhn(_ candidate: Substring) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            let value = index.isMultiple(of: 2) ? digit : digit * 2
            sum += value > 9 ? value - 9 : value
        }
        return sum.isMultiple(of: 10)
    }

    // MARK: - Session titles

    private static let titleHostPattern = try! NSRegularExpression(
        pattern: #"\A(?:[\p{L}\p{M}\p{N}._-]+|\[[0-9A-Fa-f:.]+\])\z"#
    )
    private static let quotedTitlePattern = try! NSRegularExpression(
        pattern: #""((?:\\.|[^"\\])*)"|(?<![\p{L}\p{N}])'((?:\\.|[^'\\])*)'(?![\p{L}\p{N}])"#
    )
    private static let localPathPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/])(?:/Users/|~/)(?:\\[ \t]|[^\s"'<>|,;()])+"#
    )
    private static let sensitiveBasenameFragments = [".env", "id_rsa", "id_ed25519", "credential", "secret", "token", ".pem", ".key", "[redacted"]
    private static let genericTitles = ["working…", "working...", "task started", "task completed"]

    /// Reduces task summaries (including legacy ones) to a single, safe display line.
    public static func sanitizeTitle(_ raw: String, maxLength: Int = 72) -> String? {
        guard maxLength > 0 else { return nil }
        var title = replacingMatches(in: raw, of: urlPattern) { match, source in
            let url = source.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ",;!?()"))
            guard let host = URLComponents(string: url)?.host, !host.isEmpty,
                  titleHostPattern.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil else {
                return "[url]"
            }
            return host
        }
        title = scrubSensitivePatterns(in: title)
        title = replacingMatches(in: title, of: quotedTitlePattern) { match, source in
            let content = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            return source.substring(with: content).count >= 16 ? #""[redacted]""# : nil
        }
        title = replacingMatches(in: title, of: localPathPattern) { match, source in
            let path = source.substring(with: match.range)
            let components = path.split(separator: "/")
            guard let basename = components.last, !path.hasPrefix("/Users/") || components.count > 2 else { return "[path]" }
            let normalized = basename.lowercased()
            if sensitiveBasenameFragments.contains(where: { normalized.contains($0) }) { return "[path]" }
            return "…/\(basename.replacingOccurrences(of: #"\ "#, with: " "))"
        }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty, !genericTitles.contains(title.lowercased()) else { return nil }
        return title.count > maxLength ? String(title.prefix(maxLength - 1)) + "…" : title
    }

    private static func replacingMatches(
        in text: String, of pattern: NSRegularExpression, with replacement: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let value = replacement(match, source) else { continue }
            result.replaceCharacters(in: match.range, with: value)
        }
        return result as String
    }

    // MARK: - URLs

    private static let urlPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]+"#)
    private static let sensitiveKeyFragments = [
        "token", "secret", "passw", "pwd", "pass", "auth", "key", "sig", "session", "sid", "code", "otp", "credential", "jwt"
    ]

    /// Every URL in the text, without credentials or secret-looking query values.
    static func redactURLs(in text: String) -> String {
        let ns = text as NSString
        let matches = urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let redacted = redactURL(String(out[range]))
            out.replaceSubrange(range, with: redacted)
        }
        return out
    }

    /// The URL without `user:password@` and with the values of secret-looking query items and fragments replaced.
    static func redactURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.scheme != nil else {
            return stripCredentialsByHand(raw)
        }
        var changed = false
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            components.percentEncodedPassword = nil
            components.percentEncodedUser = "***"
            changed = true
        }
        if let items = components.percentEncodedQueryItems, !items.isEmpty {
            let cleaned = items.map { item -> URLQueryItem in
                guard isSensitiveKey(item.name), let value = item.value, !value.isEmpty else { return item }
                return URLQueryItem(name: item.name, value: "***")
            }
            if cleaned != items {
                components.percentEncodedQueryItems = cleaned
                changed = true
            }
        }
        if let fragment = components.percentEncodedFragment, fragment.contains("="), isSensitiveKey(fragment) {
            components.percentEncodedFragment = "***"
            changed = true
        }
        guard changed else { return raw }
        return components.string ?? stripCredentialsByHand(raw)
    }

    private static func isSensitiveKey(_ name: String) -> Bool {
        let lower = name.lowercased()
        return sensitiveKeyFragments.contains { lower.contains($0) }
    }

    /// For a URL `URLComponents` can't parse: drop anything between `://` and an `@` before the first `/`.
    private static func stripCredentialsByHand(_ raw: String) -> String {
        guard let schemeEnd = raw.range(of: "://") else { return raw }
        let rest = raw[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        guard let at = rest[..<authorityEnd].lastIndex(of: "@") else { return raw }
        return String(raw[..<schemeEnd.upperBound]) + "***" + String(raw[at...])
    }

    // MARK: - Helpers

    static func lengthLabel(_ text: String) -> String {
        text.count == 1 ? "1 char" : "\(text.count) chars"
    }

    private static func recorded(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > maxRecordedTextLength ? String(oneLine.prefix(maxRecordedTextLength)) + "…" : oneLine
    }

    /// Shortcuts (⌘/⌃/⌥) and named keys (return, tab, arrows…) are kept; a plain character is typing, so it is
    /// kept only as a length.
    private static func keyLabel(_ step: ActionStep, recordText: Bool) -> String {
        let key = step.key ?? step.text ?? ""
        let modifiers = (step.modifiers ?? []).map { $0.lowercased() }
        let isShortcut = modifiers.contains { ["cmd", "command", "ctrl", "control", "opt", "option", "alt"].contains($0) }
        let chord = (modifiers + [key]).filter { !$0.isEmpty }.joined(separator: "+")
        if recordText || isShortcut || key.count > 1 {
            return chord
        }
        return "(\(lengthLabel(key)))"
    }
}
