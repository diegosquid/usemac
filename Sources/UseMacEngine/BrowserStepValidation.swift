import Foundation
import UseMacProtocol

/// Shape checks on browser commands that the daemon makes before anything is sent to Chrome.
public enum BrowserStepValidation {
    public static func invalidStepMessage(in steps: [ActionStep]) -> String? {
        if let message = targetlessSetValueMessage(in: steps) {
            return message
        }
        func hasText(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        func hasMatch(_ match: ElementMatch?) -> Bool {
            [match?.role, match?.title, match?.value, match?.text].contains(where: hasText)
        }
        for (index, step) in steps.enumerated() {
            if step.action == .saveFile {
                return "saveFile at step index \(index) is only for native macOS Save panels (act). In Chrome, click the download control and inspect stepResults[].downloadPath or browser_extract mode=\"downloads\"."
            }
            if step.action == .drag {
                if !namesTarget(step) && !hasMatch(step.match) {
                    return "drag at step index \(index) requires a source: pass elementId, selector, match, or both x and y."
                }
                let hasDestination = hasText(step.toElementId) || hasText(step.toSelector) || hasMatch(step.toMatch)
                    || (step.toX != nil && step.toY != nil)
                if !hasDestination {
                    return "drag at step index \(index) requires a destination: pass toElementId, toSelector, toMatch, or both toX and toY."
                }
            }
        }
        return nil
    }

    public static func invalidDialogActionMessage(_ dialogAction: String?) -> String? {
        guard let action = dialogAction?.lowercased(), action != "accept", action != "dismiss" else {
            return nil
        }
        return "dialogAction must be \"accept\" or \"dismiss\"."
    }

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
