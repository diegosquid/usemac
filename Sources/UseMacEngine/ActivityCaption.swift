import Foundation
import UseMacProtocol

/// Plain words for the live preview's caption when work fails, and the mark its caption pill shows.
///
/// The pill used to say "Batch failed" next to a spinner: jargon, no step, no reason, and a progress spinner on work
/// that had already stopped. A failed caption now names what UseMac couldn't do ("Couldn't click “Open”") and carries a
/// short reason as its subtitle ("needs the app in front"). Agents still get the full message and error code in
/// `stepResults`; these words are for the person watching.
public enum ActivityCaption {
    /// The mark at the start of the caption pill.
    public enum Mark: Equatable, Sendable {
        /// Work is still running: a spinner.
        case progress
        /// Finished fine.
        case done
        /// Failed or was refused: a failure mark, never a spinner.
        case failed
    }

    /// The pill's mark. A failed caption is finished work, so it never spins, even while the agent's task goes on
    /// (`agentBusy`, which keeps the preview open between an agent's steps). A finished caption shows progress while
    /// the agent is still busy, as before.
    public static func mark(isInProgress: Bool, success: Bool, agentBusy: Bool, stopped: Bool) -> Mark {
        if !success { return .failed }
        if stopped { return .done }
        return (isInProgress || agentBusy) ? .progress : .done
    }

    // MARK: - Titles

    /// Title for a step that failed: what UseMac couldn't do, in plain words. `targetName` is the element's name when
    /// UseMac knows it (its title from the last observe); without one, `position` (1-based index, step count) tells
    /// which step it was when the batch had several.
    public static func failedStepTitle(step: ActionStep, targetName: String? = nil, position: (index: Int, count: Int)? = nil) -> String {
        let name = displayName(step: step, targetName: targetName)
        let quoted = name.map { "“\($0)”" }
        // Without a name, say which step it was (only useful when there were several).
        let stepSuffix: String = {
            guard let position, position.count > 1 else { return "" }
            return " (step \(position.index) of \(position.count))"
        }()

        /// "Couldn't <verb> “Name”", or the wording without an object (`bare`) when the name is unknown.
        func couldnt(_ verb: String, bare: String? = nil) -> String {
            if let quoted { return "Couldn't \(verb) \(quoted)" }
            return "Couldn't \(bare ?? verb)\(stepSuffix)"
        }

        switch step.action {
        case .click: return couldnt("click")
        case .doubleClick: return couldnt("double-click")
        case .rightClick: return couldnt("right-click")
        case .hover: return couldnt("point at", bare: "hover")
        case .focus: return couldnt("focus")
        case .scroll: return couldnt("scroll")
        case .scrollIntoView: return couldnt("scroll to", bare: "scroll it into view")
        case .axAction: return couldnt("use", bare: "use the control")
        case .setValue:
            if let quoted { return "Couldn't fill in \(quoted)" }
            return "Couldn't fill in the field\(stepSuffix)"
        case .type:
            if let text = clipped(step.text, limit: 18) { return "Couldn't type “\(text)”" }
            return "Couldn't type\(stepSuffix)"
        case .pressKey:
            return "Couldn't press \(keyChord(key: step.key, modifiers: step.modifiers))"
        case .openURL, .navigate:
            if let host = hostOrText(step.url ?? step.text) { return "Couldn't open \(host)" }
            return "Couldn't open the page"
        case .uploadFile:
            let count = step.files?.count ?? 0
            return count > 1 ? "Couldn't upload \(count) files" : "Couldn't upload the file"
        case .waitFor:
            if step.gone == true {
                return quoted.map { "\($0) didn't go away" } ?? "It didn't go away\(stepSuffix)"
            }
            return quoted.map { "\($0) didn't appear" } ?? "What it waited for didn't appear"
        case .target:
            if let app = clipped(step.app, limit: 24) { return "Couldn't switch to \(app)" }
            return "Couldn't switch apps"
        case .wait:
            return "Couldn't wait\(stepSuffix)"
        case .assert:
            return "Check failed\(stepSuffix)"
        case .scrollUntil:
            return quoted.map { "Couldn't scroll to \($0)" } ?? "Couldn't find it while scrolling\(stepSuffix)"
        case .fillForm:
            return "Couldn't fill the form\(stepSuffix)"
        case .menuAction:
            if let last = clipped(step.menuPath?.last, limit: 24) { return "Couldn't choose “\(last)”" }
            return "Couldn't use the menu\(stepSuffix)"
        }
    }

    /// What the caption of a failed batch says: a title naming the step that failed and a short reason.
    public struct Failure: Equatable, Sendable {
        public var title: String
        public var reason: String?

        public init(title: String, reason: String?) {
            self.title = title
            self.reason = reason
        }
    }

    /// The caption for a batch that failed. `elementName` looks up an element's name by id (the step's resolved
    /// element, else its `elementId`); return nil when unknown.
    public static func batchFailure(
        steps: [ActionStep],
        results: [ActionStepResult],
        inBrowser: Bool = false,
        elementName: (String) -> String? = { _ in nil }
    ) -> Failure {
        guard let failed = results.first(where: { !$0.success }) else {
            return Failure(title: "Couldn't finish the steps", reason: nil)
        }
        let code = failed.errorCode ?? (failed.mechanism == "cancelled" ? "CANCELLED" : nil)
        let why = reason(errorCode: code, message: failed.message, inBrowser: inBrowser)
        if isBatchRefusal(mechanism: failed.mechanism) {
            return Failure(title: refusedBatchTitle(stepCount: steps.count), reason: why)
        }
        let step = steps.indices.contains(failed.index) ? steps[failed.index] : ActionStep(action: failed.action)
        let name = (failed.resolvedElementId ?? step.elementId).flatMap { $0.isEmpty ? nil : elementName($0) }
        let title = failedStepTitle(step: step, targetName: name, position: (failed.index + 1, max(steps.count, failed.index + 1)))
        return Failure(title: title, reason: why)
    }

    /// Title when a whole batch was refused before any step ran (stale window, user active, foreground refused).
    public static func refusedBatchTitle(stepCount: Int) -> String {
        stepCount == 1 ? "Didn't run the step" : "Didn't run the steps"
    }

    /// True for the mechanisms of a refusal that stops a batch before its first step (see `ActionExecutor`).
    public static func isBatchRefusal(mechanism: String) -> Bool {
        ["window-pin", "stale-check", "expect-title", "foreground-burst"].contains(mechanism)
    }

    // MARK: - Reasons

    /// A short reason for a failure, from its error code (or, for steps that carry none, a few known messages).
    /// Nil when UseMac has nothing better than the raw message.
    public static func reason(errorCode: String?, message: String? = nil, inBrowser: Bool = false) -> String? {
        switch errorCode?.uppercased() {
        case "TARGET_NOT_FRONTMOST": return "needs the app in front"
        case "ELEMENT_NOT_FOUND": return inBrowser ? "couldn't find it on the page" : "couldn't find it on screen"
        case "STALE_SNAPSHOT": return "the window changed since the last look"
        case "WAIT_TIMEOUT": return "it didn't show up in time"
        case "POLICY_BLOCKED": return "blocked by your safety settings"
        case "UPLOAD_BLOCKED": return "that file isn't allowed"
        case "UPLOAD_FAILED": return "the file didn't attach"
        case "SELF_TARGET_BLOCKED": return "UseMac doesn't act on its own windows"
        case "USER_ACTIVE": return "you were using the Mac"
        case "APP_NOT_FOUND": return "the app isn't open"
        case "URL_BLOCKED": return "that address is blocked"
        case "RESTRICTED_PAGE": return "Chrome doesn't allow this page"
        case "CANCELLED": return "stopped"
        case "INVALID_REQUEST", "INVALID_ARGUMENT": return "the step was missing details"
        case "CAPTURE_TOO_SMALL": return "the capture was too small"
        default: break
        }
        guard let lower = message?.lowercased(), !lower.isEmpty else { return nil }
        if lower.contains("not found") || lower.contains("no element") {
            return inBrowser ? "couldn't find it on the page" : "couldn't find it on screen"
        }
        if lower.contains("timed out") {
            return "it didn't show up in time"
        }
        if lower.contains("does not support") || lower.contains("doesn't support") {
            return "the app doesn't allow that there"
        }
        if lower.contains(" requires ") || lower.contains(" needs ") {
            return "the step was missing details"
        }
        return nil
    }

    // MARK: - Helpers

    /// The element's name for a caption: the observed title, else what `match` looked for. Snapshot ids ("e12") and
    /// CSS selectors mean nothing to the person watching, so they are never shown.
    static func displayName(step: ActionStep, targetName: String?) -> String? {
        let candidates = [targetName, step.match?.title, step.match?.text, step.match?.value]
        for candidate in candidates {
            if let clean = clipped(candidate, limit: 24) { return clean }
        }
        return nil
    }

    static func clipped(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let single = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty else { return nil }
        return single.count <= limit ? single : String(single.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func hostOrText(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let host = URL(string: raw)?.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return clipped(raw, limit: 28)
    }

    static func keyChord(key: String?, modifiers: [String]?) -> String {
        let prefix = ModifierAliases.symbols(modifiers)
        let raw = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formatted = raw.count == 1 ? raw.uppercased() : raw.capitalized
        return prefix + (formatted.isEmpty ? "the key" : formatted)
    }
}
