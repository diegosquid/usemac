import Foundation
import UseMacProtocol

/// Shape checks on `browser_act` steps that the daemon makes before anything is sent to Chrome.
enum BrowserStepValidation {
    /// Why the batch can't run because a `setValue` names no field, or nil when every `setValue` has a target.
    ///
    /// A browser `setValue` replaces a field's text. With no `elementId`, `selector` or point, the extension used to
    /// press ⌘A and Backspace and type into whatever had focus in the page, and report success. Typing into the
    /// focused element is what `type` is for.
    static func targetlessSetValueMessage(in steps: [ActionStep]) -> String? {
        guard let index = steps.firstIndex(where: { $0.action == .setValue && !namesTarget($0) }) else {
            return nil
        }
        let matchNote = steps[index].match != nil ? " (match works only in native act)" : ""
        return "setValue at step index \(index) names no field\(matchNote): pass elementId (an @bN id from browser_observe) "
            + "or selector. Nothing ran. To type into the focused field, use type."
    }

    /// True when the step says where to act: a non-blank `elementId` or `selector`, or both `x` and `y`.
    static func namesTarget(_ step: ActionStep) -> Bool {
        func named(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return named(step.elementId) || named(step.selector) || (step.x != nil && step.y != nil)
    }
}
