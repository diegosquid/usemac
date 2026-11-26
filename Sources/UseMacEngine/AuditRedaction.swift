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

    /// Text this request carries that the audit log must not copy: typed and set values, and page scripts.
    var auditSecrets: [String] {
        let steps = (act?.steps ?? []) + (browserAct?.steps ?? [])
        var secrets = steps
            .filter { $0.action == .type || $0.action == .setValue }
            .compactMap(\.text)
        if let expression = browserExtract?.expression {
            secrets.append(expression)
        }
        return secrets
    }
}

/// Keeps the audit log from becoming a copy of what the user typed. By default typed text, set values and
/// `eval` sources are kept only as their length, and URLs lose their credentials and secret-looking query
/// values. Turning on "Record typed text" (`AuditLogSettings.recordsTypedText`) keeps the text; URLs are
/// always cleaned.
enum AuditRedactor {
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
        return redactURLs(in: out)
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
        case .uploadFile:
            let count = step.files?.count ?? 0
            return "\(name) (\(count) file\(count == 1 ? "" : "s"))"
        case .axAction:
            return step.actionName.map { "\(name) \($0)" } ?? name
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
