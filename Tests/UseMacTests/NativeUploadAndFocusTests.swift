import XCTest
@testable import UseMacEngine
import UseMacProtocol

final class NativeUploadAndFocusTests: XCTestCase {
    func testEvaluateSetValueReadBackSuggestsForegroundForChromiumBackground() {
        let result = ActionExecutor.evaluateSetValueReadBack(
            requested: "new value", before: "old value", readBack: "old value",
            isToggle: false, isSecure: false, isChromiumBackground: true
        )

        XCTAssertEqual(result.effect, ActionEffect.none)
        XCTAssertNil(result.message)
        XCTAssertTrue(result.warning?.contains("background Chrome/Chromium windows") == true)
        XCTAssertTrue(result.warning?.contains("\"foreground\": true") == true)
    }

    func testEvaluateSetValueReadBackKeepsGenericWarningForNonChromium() {
        let result = ActionExecutor.evaluateSetValueReadBack(
            requested: "new value", before: "old value", readBack: "old value",
            isToggle: false, isSecure: false
        )

        XCTAssertEqual(result.effect, ActionEffect.none)
        XCTAssertNil(result.message)
        XCTAssertEqual(result.warning, "The field still reads back \"old value\" instead of the text you set: the app may have rejected it.")
    }

    func testEvaluateSetValueReadBackDetectsFormattedChange() {
        let result = ActionExecutor.evaluateSetValueReadBack(
            requested: "12345678", before: "old value", readBack: "1234-5678",
            isToggle: false, isSecure: false, isChromiumBackground: true
        )

        XCTAssertEqual(result.effect, .changed)
        XCTAssertEqual(result.message, "Field value updated and formatted as \"1234-5678\".")
        XCTAssertNil(result.warning)
    }

    func testShouldRestoreFocusAfterBackgroundUploadWhenAppStoleFocus() {
        XCTAssertTrue(OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
            previousPid: 100, targetPid: 200, targetBecameFrontmost: true,
            secondsSinceUserInput: ActionExecutor.userIdleRequiredSeconds, ownInputRecent: false
        ))
        XCTAssertTrue(OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
            previousPid: 100, targetPid: 200, targetBecameFrontmost: true,
            secondsSinceUserInput: 0.1, ownInputRecent: true
        ))
    }

    func testShouldNotRestoreFocusWhenUserRecentlyInteracted() {
        XCTAssertFalse(OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
            previousPid: 100, targetPid: 200, targetBecameFrontmost: true,
            secondsSinceUserInput: 0.1, ownInputRecent: false
        ))
    }

    func testShouldNotRestoreFocusWhenSameAppOrDidNotActivate() {
        XCTAssertFalse(OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
            previousPid: 200, targetPid: 200, targetBecameFrontmost: true,
            secondsSinceUserInput: 3, ownInputRecent: false
        ))
        XCTAssertFalse(OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
            previousPid: 100, targetPid: 200, targetBecameFrontmost: false,
            secondsSinceUserInput: 3, ownInputRecent: false
        ))
        XCTAssertFalse(OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
            previousPid: nil, targetPid: 200, targetBecameFrontmost: true,
            secondsSinceUserInput: 3, ownInputRecent: false
        ))
    }

    func testIsGoToFolderFieldCandidateDistinguishesSearchAndFileRows() {
        XCTAssertTrue(OpenPanelReach.isGoToFolderFieldCandidate(
            role: "AXComboBox", subrole: nil, inFileRow: false, isSearchField: false
        ))
        XCTAssertTrue(OpenPanelReach.isGoToFolderFieldCandidate(
            role: "AXTextField", subrole: nil, inFileRow: false, isSearchField: false
        ))
        XCTAssertFalse(OpenPanelReach.isGoToFolderFieldCandidate(
            role: "AXTextField", subrole: "AXSearchField", inFileRow: false, isSearchField: false
        ))
        XCTAssertFalse(OpenPanelReach.isGoToFolderFieldCandidate(
            role: "AXTextField", subrole: nil, inFileRow: false, isSearchField: true
        ))
        XCTAssertFalse(OpenPanelReach.isGoToFolderFieldCandidate(
            role: "AXTextField", subrole: nil, inFileRow: true, isSearchField: false
        ))
        XCTAssertFalse(OpenPanelReach.isGoToFolderFieldCandidate(
            role: "AXStaticText", subrole: nil, inFileRow: false, isSearchField: false
        ))
    }

    func testGoToFolderFailureMessageDistinguishesMissingSheetFromUnconfirmedOpen() {
        let missing = OpenPanelReach.goToFolderFailureMessage(fileName: "notes.txt", detectedField: false)
        let unconfirmed = OpenPanelReach.goToFolderFailureMessage(fileName: "notes.txt", detectedField: true)

        XCTAssertTrue(missing.contains("Could not detect the Go to Folder path field"), missing)
        XCTAssertTrue(missing.contains("stopped without confirming the picker"), missing)
        XCTAssertTrue(missing.contains("~/Downloads"), missing)
        XCTAssertTrue(missing.contains("notes.txt"), missing)
        XCTAssertTrue(unconfirmed.contains("picker stayed open without confirming"), unconfirmed)
        XCTAssertTrue(unconfirmed.contains("notes.txt"), unconfirmed)
    }

    func testOpenURLRuleRefusalBlocksSiteAndDefaultHandler() {
        let blockedURL = "https://restricted.example/inbox"
        let allowedURL = "https://allowed.example/inbox"
        let allowedHandler = "com.example.allowed-browser"
        let blockedHandler = "com.example.blocked-browser"
        let rules = TargetRules(deniedApps: [blockedHandler], deniedSites: ["restricted.example"])

        XCTAssertEqual(
            ActionExecutor.openURLRuleRefusal(normalizedURL: blockedURL, handlerBundleId: allowedHandler, rules: rules),
            TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: blockedURL))
        )
        let handlerRefusal = ActionExecutor.openURLRuleRefusal(
            normalizedURL: allowedURL, handlerBundleId: blockedHandler, rules: rules
        )
        XCTAssertTrue(handlerRefusal?.contains(blockedHandler) == true)
        XCTAssertNil(ActionExecutor.openURLRuleRefusal(
            normalizedURL: allowedURL, handlerBundleId: allowedHandler, rules: rules
        ))
        XCTAssertNil(ActionExecutor.openURLRuleRefusal(
            normalizedURL: allowedURL, handlerBundleId: nil, rules: rules
        ))
    }

    func testRemainingBudgetMsReturnsZeroAtOrAfterDeadline() {
        XCTAssertEqual(ActionExecutor.remainingBudgetMs(nowNs: 10_000_000, deadlineNs: 10_000_000), 0)
        XCTAssertEqual(ActionExecutor.remainingBudgetMs(nowNs: 10_000_001, deadlineNs: 10_000_000), 0)
        XCTAssertEqual(ActionExecutor.remainingBudgetMs(nowNs: 9_999_999, deadlineNs: 10_000_000), 0)
        XCTAssertEqual(ActionExecutor.remainingBudgetMs(nowNs: 7_000_000, deadlineNs: 10_000_000), 3)
    }

    func testShouldAttemptGoToFolderAfterSearchFailureOnlyInForeground() {
        XCTAssertTrue(OpenPanelReach.shouldAttemptGoToFolderAfterSearchFailure(isFrontmost: true))
        XCTAssertFalse(OpenPanelReach.shouldAttemptGoToFolderAfterSearchFailure(isFrontmost: false))
    }

    func testShouldNotRestorePreviousWindowAfterFocusedWindowChanges() {
        XCTAssertFalse(ActionExecutor.shouldRestorePreviousWindow(
            appIsFrontmost: true, borrowedWindowId: 2, currentFocusedWindowId: 3,
            secondsSinceUserInput: ActionExecutor.userIdleRequiredSeconds, ownInputRecent: false
        ))
    }

    func testShouldRestorePreviousWindowOnlyWhenFocusAndInputAllowIt() {
        XCTAssertTrue(ActionExecutor.shouldRestorePreviousWindow(
            appIsFrontmost: true, borrowedWindowId: 2, currentFocusedWindowId: 2,
            secondsSinceUserInput: ActionExecutor.userIdleRequiredSeconds, ownInputRecent: false
        ))
        XCTAssertTrue(ActionExecutor.shouldRestorePreviousWindow(
            appIsFrontmost: true, borrowedWindowId: 2, currentFocusedWindowId: 2,
            secondsSinceUserInput: 0.1, ownInputRecent: true
        ))
        XCTAssertFalse(ActionExecutor.shouldRestorePreviousWindow(
            appIsFrontmost: true, borrowedWindowId: 2, currentFocusedWindowId: 2,
            secondsSinceUserInput: 0.1, ownInputRecent: false
        ))
        XCTAssertFalse(ActionExecutor.shouldRestorePreviousWindow(
            appIsFrontmost: false, borrowedWindowId: 2, currentFocusedWindowId: 2,
            secondsSinceUserInput: ActionExecutor.userIdleRequiredSeconds, ownInputRecent: false
        ))
        XCTAssertTrue(ActionExecutor.shouldRestorePreviousWindow(
            appIsFrontmost: true, borrowedWindowId: nil, currentFocusedWindowId: 3,
            secondsSinceUserInput: ActionExecutor.userIdleRequiredSeconds, ownInputRecent: false
        ))
    }
}
