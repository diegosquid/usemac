import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// The daemon refuses a browser setValue that names no field before anything reaches Chrome: without one the
/// extension used to select-all and type into whatever had focus, and report success.
final class BrowserStepValidationTests: XCTestCase {
    func testSetValueWithoutAFieldIsRefused() {
        let targetless: [ActionStep] = [
            ActionStep(action: .setValue, elementId: "", text: "secret"),
            ActionStep(action: .setValue, elementId: "  ", text: "secret"),
            ActionStep(action: .setValue, selector: "", text: "secret"),
            ActionStep(action: .setValue, text: "secret"),
            ActionStep(action: .setValue, x: 40, text: "secret")
        ]
        for step in targetless {
            let message = BrowserStepValidation.targetlessSetValueMessage(in: [step])
            XCTAssertEqual(
                message,
                "setValue at step index 0 names no field: pass elementId (an @bN id from browser_observe) or selector. "
                    + "Nothing ran. To type into the focused field, use type.",
                "\(step)"
            )
        }
    }

    func testTheMessageNamesTheStepAndMatch() throws {
        let steps = [
            ActionStep(action: .click, elementId: "@b3"),
            ActionStep(action: .setValue, text: "x", match: ElementMatch(role: "textbox"))
        ]
        let message = try XCTUnwrap(BrowserStepValidation.targetlessSetValueMessage(in: steps))
        XCTAssertTrue(message.hasPrefix("setValue at step index 1 names no field (match works only in native act):"), message)
    }

    func testSetValueWithAFieldOrPointPasses() {
        let targeted: [ActionStep] = [
            ActionStep(action: .setValue, elementId: "@b2", text: "Ada"),
            ActionStep(action: .setValue, selector: "#email", text: "a@example.com"),
            ActionStep(action: .setValue, elementId: "", selector: "input[name=q]", text: "q"),
            ActionStep(action: .setValue, x: 0, y: 0, text: "corner")
        ]
        XCTAssertNil(BrowserStepValidation.targetlessSetValueMessage(in: targeted))
    }

    func testOtherStepsMayGoWithoutATarget() {
        // type writes into the focused element on purpose; pressKey and scroll act on the page.
        let steps = [
            ActionStep(action: .type, text: "hello"),
            ActionStep(action: .pressKey, key: "return"),
            ActionStep(action: .scroll, deltaY: 300),
            ActionStep(action: .click, elementId: "")
        ]
        XCTAssertNil(BrowserStepValidation.targetlessSetValueMessage(in: steps))
    }

    func testDragAcceptsEachBrowserTargetShape() {
        XCTAssertNil(BrowserStepValidation.invalidStepMessage(in: [
            ActionStep(action: .drag, elementId: "@b1", toElementId: "@b2"),
            ActionStep(action: .drag, selector: "#source", toSelector: "#destination"),
            ActionStep(action: .drag, match: ElementMatch(title: "Source"), toMatch: ElementMatch(role: "button")),
            ActionStep(action: .drag, x: 0, y: 50, toX: 100, toY: 0)
        ]))
    }

    func testDragRequiresBothEndpoints() {
        let blank = ElementMatch(role: " \n", exact: true, index: 1)
        XCTAssertEqual(BrowserStepValidation.invalidStepMessage(in: [
            ActionStep(action: .wait),
            ActionStep(action: .drag, elementId: " ", x: 1, match: blank, toSelector: "#destination")
        ]), "drag at step index 1 requires a source: pass elementId, selector, match, or both x and y.")
        XCTAssertEqual(BrowserStepValidation.invalidStepMessage(in: [
            ActionStep(action: .drag, selector: "#source", toSelector: " ", toMatch: blank, toY: 1)
        ]), "drag at step index 0 requires a destination: pass toElementId, toSelector, toMatch, or both toX and toY.")
    }

    func testSaveFileIsNativeOnly() {
        XCTAssertEqual(BrowserStepValidation.invalidStepMessage(in: [
            ActionStep(action: .click, selector: "#download"),
            ActionStep(action: .saveFile, files: ["/Users/me/Downloads/report.pdf"])
        ]), "saveFile at step index 1 is only for native macOS Save panels (act). In Chrome, click the download control and inspect stepResults[].downloadPath or browser_extract mode=\"downloads\".")
    }

    func testTargetlessSetValueStillTakesPrecedence() {
        let steps = [ActionStep(action: .drag), ActionStep(action: .setValue, text: "value")]
        XCTAssertTrue(BrowserStepValidation.invalidStepMessage(in: steps)?.hasPrefix("setValue at step index 1") == true)
    }

    func testDialogActionIsOptionalAndCaseInsensitive() {
        for action in [nil, "accept", "AcCePt", "dismiss", "DISMISS"] {
            XCTAssertNil(BrowserStepValidation.invalidDialogActionMessage(action))
        }
        for action in ["", " accept ", "always"] {
            XCTAssertEqual(BrowserStepValidation.invalidDialogActionMessage(action), "dialogAction must be \"accept\" or \"dismiss\".")
        }
    }
}
