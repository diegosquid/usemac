import XCTest
@testable import UseMacEngine

final class PreviewDeckFocusTests: XCTestCase {
    private let workingTab = PreviewDeckFocus.Front(isBrowser: true, browserTabId: 11, hasPreview: true, isBusy: true)
    private let workingApp = PreviewDeckFocus.Front(isBrowser: false, appPid: 300, hasPreview: true, isBusy: true)

    // MARK: When the front card gives way

    func testEmptyDeckYields() {
        XCTAssertTrue(PreviewDeckFocus.frontYieldsToActivity(nil))
    }

    func testEmptyBrowserPlaceholderYields() {
        let placeholder = PreviewDeckFocus.Front(isBrowser: true, browserTabId: nil, hasPreview: false, isBusy: true)
        XCTAssertTrue(PreviewDeckFocus.frontYieldsToActivity(placeholder))
    }

    func testFinishedFrontCardYields() {
        let finished = PreviewDeckFocus.Front(isBrowser: true, browserTabId: 11, hasPreview: true, isBusy: false, isCompleted: true)
        XCTAssertTrue(PreviewDeckFocus.frontYieldsToActivity(finished))
    }

    func testWorkingFrontCardHoldsTheFront() {
        XCTAssertFalse(PreviewDeckFocus.frontYieldsToActivity(workingTab))
        XCTAssertFalse(PreviewDeckFocus.frontYieldsToActivity(workingApp))
    }

    func testQuietButUnfinishedFrontCardHoldsTheFront() {
        // An agent thinking between steps (stream paused, no task_complete yet) keeps the card the user is watching.
        let quiet = PreviewDeckFocus.Front(isBrowser: true, browserTabId: 11, hasPreview: true, isBusy: false, isCompleted: false)
        XCTAssertFalse(PreviewDeckFocus.frontYieldsToActivity(quiet))
    }

    func testTabWithAFrameIsNotAPlaceholder() {
        let tabWithoutIdYet = PreviewDeckFocus.Front(isBrowser: true, browserTabId: nil, hasPreview: true, isBusy: true)
        XCTAssertFalse(PreviewDeckFocus.frontYieldsToActivity(tabWithoutIdYet))
    }

    // MARK: Whose activity it is

    func testAnotherTabIsBackgroundWork() {
        XCTAssertTrue(PreviewDeckFocus.isBackgroundActivity(front: workingTab, tabId: 22, appPid: nil, isChromiumApp: false))
    }

    func testTheFrontTabIsNotBackgroundWork() {
        XCTAssertFalse(PreviewDeckFocus.isBackgroundActivity(front: workingTab, tabId: 11, appPid: nil, isChromiumApp: false))
    }

    func testBrowserWorkWhileANativeAppIsInFrontIsBackgroundWork() {
        XCTAssertTrue(PreviewDeckFocus.isBackgroundActivity(front: workingApp, tabId: 22, appPid: nil, isChromiumApp: false))
    }

    func testAnotherNativeAppIsBackgroundWork() {
        XCTAssertTrue(PreviewDeckFocus.isBackgroundActivity(front: workingApp, tabId: nil, appPid: 400, isChromiumApp: false))
        XCTAssertTrue(PreviewDeckFocus.isBackgroundActivity(front: workingTab, tabId: nil, appPid: 400, isChromiumApp: false))
    }

    func testTheFrontNativeAppIsNotBackgroundWork() {
        XCTAssertFalse(PreviewDeckFocus.isBackgroundActivity(front: workingApp, tabId: nil, appPid: 300, isChromiumApp: false))
    }

    func testNativeWorkInChromeCountsAsTheFrontTabs() {
        // Native accessibility work in a Chrome window can be on the front tab's own page.
        XCTAssertFalse(PreviewDeckFocus.isBackgroundActivity(front: workingTab, tabId: nil, appPid: 500, isChromiumApp: true))
    }

    func testActivityThatNamesNothingCountsAsTheFrontCards() {
        XCTAssertFalse(PreviewDeckFocus.isBackgroundActivity(front: workingTab, tabId: nil, appPid: nil, isChromiumApp: false))
    }

    func testNothingIsBackgroundWhenTheFrontYields() {
        XCTAssertFalse(PreviewDeckFocus.isBackgroundActivity(front: nil, tabId: 22, appPid: nil, isChromiumApp: false))
        let finished = PreviewDeckFocus.Front(isBrowser: true, browserTabId: 11, hasPreview: true, isBusy: false, isCompleted: true)
        XCTAssertFalse(PreviewDeckFocus.isBackgroundActivity(front: finished, tabId: 22, appPid: nil, isChromiumApp: false))
    }

    // MARK: Golden rule: only UseMac tabs and apps an agent named

    func testGuessedTargetNeverReachesThePreview() {
        XCTAssertFalse(PreviewDeckFocus.previewShows(targetGuessed: true))
        XCTAssertTrue(PreviewDeckFocus.previewShows(targetGuessed: false))
    }

    func testATabsCardComesFromItsFrameNotFromASteps() {
        // Steps on a tab (even successful ones, like "starting") never add its card: a closed tab would leave an empty one.
        XCTAssertFalse(PreviewDeckFocus.activityAddsCard(isBrowser: true, namesTab: true, success: true))
        XCTAssertFalse(PreviewDeckFocus.activityAddsCard(isBrowser: true, namesTab: true, success: false))
        // A browser task that has not opened a tab yet may show the placeholder.
        XCTAssertTrue(PreviewDeckFocus.activityAddsCard(isBrowser: true, namesTab: false, success: true))
        XCTAssertFalse(PreviewDeckFocus.activityAddsCard(isBrowser: true, namesTab: false, success: false))
        // Native apps an agent named keep their cards.
        XCTAssertTrue(PreviewDeckFocus.activityAddsCard(isBrowser: false, namesTab: false, success: false))
    }

    func testTargetIsGuessedOnlyWhenNothingNamesAnApp() {
        XCTAssertTrue(WorkspaceMonitor.isGuessedTarget(requestApp: nil, hasPairedApp: false))
        XCTAssertTrue(WorkspaceMonitor.isGuessedTarget(requestApp: "  ", stepApps: [nil, ""], hasPairedApp: false))
        XCTAssertFalse(WorkspaceMonitor.isGuessedTarget(requestApp: "TextEdit", hasPairedApp: false))
        XCTAssertFalse(WorkspaceMonitor.isGuessedTarget(requestApp: nil, stepApps: [nil, "Notes"], hasPairedApp: false))
        XCTAssertFalse(WorkspaceMonitor.isGuessedTarget(requestApp: nil, hasPairedApp: true), "pair_app names the target")
    }
}
