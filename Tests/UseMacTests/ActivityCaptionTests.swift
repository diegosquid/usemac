import XCTest
import UseMacProtocol
@testable import UseMacEngine

final class ActivityCaptionTests: XCTestCase {
    // MARK: The pill's mark

    func testFailedCaptionNeverSpinsWhileTheTaskGoesOn() {
        // The bug: a finished, failed step showed a spinner because the agent's task was still open.
        XCTAssertEqual(ActivityCaption.mark(isInProgress: false, success: false, agentBusy: true, stopped: false), .failed)
        XCTAssertEqual(ActivityCaption.mark(isInProgress: true, success: false, agentBusy: true, stopped: false), .failed)
    }

    func testFinishedCaptionKeepsTheSpinnerWhileTheAgentIsBusy() {
        XCTAssertEqual(ActivityCaption.mark(isInProgress: false, success: true, agentBusy: true, stopped: false), .progress)
        XCTAssertEqual(ActivityCaption.mark(isInProgress: true, success: true, agentBusy: false, stopped: false), .progress)
        XCTAssertEqual(ActivityCaption.mark(isInProgress: false, success: true, agentBusy: false, stopped: false), .done)
    }

    func testStoppedNeverSpins() {
        XCTAssertEqual(ActivityCaption.mark(isInProgress: true, success: true, agentBusy: true, stopped: true), .done)
        XCTAssertEqual(ActivityCaption.mark(isInProgress: true, success: false, agentBusy: true, stopped: true), .failed)
    }

    // MARK: Failed step titles

    func testClickNamesTheElement() {
        let step = ActionStep(action: .click, elementId: "e12")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: step, targetName: "Open"), "Couldn't click “Open”")
    }

    func testMatchGivesTheNameWhenTheElementWasNeverFound() {
        let step = ActionStep(action: .click, match: ElementMatch(role: "AXButton", title: "Save"))
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: step), "Couldn't click “Save”")
    }

    func testSnapshotIdsAndSelectorsAreNeverShown() {
        let byId = ActionStep(action: .click, elementId: "e12")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: byId, position: (2, 3)), "Couldn't click (step 2 of 3)")
        let bySelector = ActionStep(action: .click, selector: "#submit > button")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: bySelector, position: (1, 1)), "Couldn't click")
    }

    func testVerbsThatNeedAnObjectStillReadWithoutAName() {
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .hover)), "Couldn't hover")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .hover), targetName: "Menu"), "Couldn't point at “Menu”")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .scrollIntoView)), "Couldn't scroll it into view")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .axAction, actionName: "AXOpen")), "Couldn't use the control")
    }

    func testOtherActions() {
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .type, text: "hello world")), "Couldn't type “hello world”")
        XCTAssertEqual(
            ActivityCaption.failedStepTitle(step: ActionStep(action: .type, text: "a very long sentence that keeps going")),
            "Couldn't type “a very long senten…”"
        )
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .pressKey, key: "s", modifiers: ["cmd"])), "Couldn't press ⌘S")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .setValue, match: ElementMatch(title: "Name"))), "Couldn't fill in “Name”")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .openURL, url: "https://www.example.com/a?b=c")), "Couldn't open example.com")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .uploadFile, files: ["/a", "/b"])), "Couldn't upload 2 files")
        XCTAssertEqual(ActivityCaption.failedStepTitle(step: ActionStep(action: .waitFor, match: ElementMatch(title: "Done"))), "“Done” didn't appear")
        XCTAssertEqual(
            ActivityCaption.failedStepTitle(step: ActionStep(action: .waitFor, match: ElementMatch(text: "Loading"), gone: true)),
            "“Loading” didn't go away"
        )
    }

    // MARK: Reasons

    func testReasonsFromErrorCodes() {
        XCTAssertEqual(ActivityCaption.reason(errorCode: "TARGET_NOT_FRONTMOST"), "needs the app in front")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "ELEMENT_NOT_FOUND"), "couldn't find it on screen")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "ELEMENT_NOT_FOUND", inBrowser: true), "couldn't find it on the page")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "STALE_SNAPSHOT"), "the window changed since the last look")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "WAIT_TIMEOUT"), "it didn't show up in time")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "POLICY_BLOCKED"), "blocked by your safety settings")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "UPLOAD_BLOCKED"), "that file isn't allowed")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "SELF_TARGET_BLOCKED"), "UseMac doesn't act on its own windows")
        XCTAssertEqual(ActivityCaption.reason(errorCode: "USER_ACTIVE"), "you were using the Mac")
    }

    func testEveryReasonIsShort() {
        let codes = [
            "TARGET_NOT_FRONTMOST", "ELEMENT_NOT_FOUND", "STALE_SNAPSHOT", "WAIT_TIMEOUT", "POLICY_BLOCKED", "UPLOAD_BLOCKED",
            "UPLOAD_FAILED", "SELF_TARGET_BLOCKED", "USER_ACTIVE", "APP_NOT_FOUND", "URL_BLOCKED", "RESTRICTED_PAGE",
            "CANCELLED", "INVALID_REQUEST", "CAPTURE_TOO_SMALL"
        ]
        for code in codes {
            let reason = ActivityCaption.reason(errorCode: code)
            XCTAssertNotNil(reason, code)
            XCTAssertLessThanOrEqual(reason?.count ?? 0, 40, code)
        }
    }

    func testBrowserMessagesWithoutACode() {
        XCTAssertEqual(
            ActivityCaption.reason(errorCode: nil, message: "Element e12 not found in tab 5.", inBrowser: true),
            "couldn't find it on the page"
        )
        XCTAssertEqual(ActivityCaption.reason(errorCode: nil, message: "Timed out after 5000ms waiting for .x"), "it didn't show up in time")
        XCTAssertNil(ActivityCaption.reason(errorCode: nil, message: "Something odd"))
        XCTAssertNil(ActivityCaption.reason(errorCode: "SOME_NEW_CODE"))
    }

    // MARK: A failed batch

    func testBatchFailureNamesTheFailedStepAndWhy() {
        let steps = [
            ActionStep(action: .click, elementId: "e3"),
            ActionStep(action: .click, elementId: "e12"),
            ActionStep(action: .type, text: "x")
        ]
        let results = [
            ActionStepResult(index: 0, action: .click, success: true, mechanism: "ax-press", latencyMs: 2),
            ActionStepResult(
                index: 1, action: .click, success: false, mechanism: "hid-guard", latencyMs: 1,
                message: "TextEdit is not in front", errorCode: "TARGET_NOT_FRONTMOST"
            )
        ]
        let failure = ActivityCaption.batchFailure(steps: steps, results: results, elementName: { $0 == "e12" ? "Open" : nil })
        XCTAssertEqual(failure, ActivityCaption.Failure(title: "Couldn't click “Open”", reason: "needs the app in front"))
    }

    func testBatchFailureWithoutANameSaysWhichStep() {
        let steps = [ActionStep(action: .pressKey, key: "a"), ActionStep(action: .click, elementId: "e99")]
        let results = [
            ActionStepResult(index: 0, action: .pressKey, success: true, mechanism: "cgevent-key", latencyMs: 1),
            ActionStepResult(index: 1, action: .click, success: false, mechanism: "snapshot", latencyMs: 1, errorCode: "ELEMENT_NOT_FOUND")
        ]
        let failure = ActivityCaption.batchFailure(steps: steps, results: results)
        XCTAssertEqual(failure.title, "Couldn't click (step 2 of 2)")
        XCTAssertEqual(failure.reason, "couldn't find it on screen")
    }

    func testRefusedBatchSaysNothingRan() {
        let steps = [ActionStep(action: .click, elementId: "e1"), ActionStep(action: .type, text: "x")]
        let results = [
            ActionStepResult(index: 0, action: .click, success: false, mechanism: "stale-check", latencyMs: 0, errorCode: "STALE_SNAPSHOT")
        ]
        let failure = ActivityCaption.batchFailure(steps: steps, results: results)
        XCTAssertEqual(failure, ActivityCaption.Failure(title: "Didn't run the steps", reason: "the window changed since the last look"))
    }

    func testCancelledBrowserStepSaysStopped() {
        let steps = [ActionStep(action: .click, elementId: "b4")]
        let results = [ActionStepResult(index: 0, action: .click, success: false, mechanism: "cancelled", latencyMs: 0, message: "Cancelled")]
        XCTAssertEqual(ActivityCaption.batchFailure(steps: steps, results: results, inBrowser: true).reason, "stopped")
    }
}
