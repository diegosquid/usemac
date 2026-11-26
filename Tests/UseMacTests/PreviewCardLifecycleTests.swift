import XCTest
@testable import UseMacEngine

final class PreviewCardLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var quietSince: Date { now.addingTimeInterval(-PreviewCardLifecycle.quietSettleSeconds - 1) }
    private var justNow: Date { now.addingTimeInterval(-2) }

    // MARK: The sweep

    func testGhostCardLeaves() {
        // A background native card with no picture and a busy dot, untouched for a while: Diego's grey ghost card.
        let ghost = PreviewCardLifecycle.Card(isBrowser: false, hasPreview: false, isBusy: true, lastActivity: quietSince)
        XCTAssertEqual(PreviewCardLifecycle.sweep(ghost, now: now), .remove)
    }

    func testQuietCardWithAPictureStopsTheBusyDot() {
        let card = PreviewCardLifecycle.Card(isBrowser: false, hasPreview: true, isBusy: true, lastActivity: quietSince)
        XCTAssertEqual(PreviewCardLifecycle.sweep(card, now: now), .settle)
        let settled = PreviewCardLifecycle.Card(isBrowser: false, hasPreview: true, isBusy: false, lastActivity: quietSince)
        XCTAssertEqual(PreviewCardLifecycle.sweep(settled, now: now), .keep)
    }

    func testRecentlyActiveCardsStay() {
        let working = PreviewCardLifecycle.Card(isBrowser: false, hasPreview: false, isBusy: true, lastActivity: justNow)
        XCTAssertEqual(PreviewCardLifecycle.sweep(working, now: now), .keep)
        let tab = PreviewCardLifecycle.Card(isBrowser: true, hasPreview: true, isBusy: true, lastActivity: justNow)
        XCTAssertEqual(PreviewCardLifecycle.sweep(tab, now: now), .keep)
    }

    func testFrontCardIsLeftToTheTaskEnd() {
        // An agent thinking for minutes keeps the card the user is watching; task_complete or the idle failsafe ends it.
        let front = PreviewCardLifecycle.Card(isBrowser: false, isFront: true, hasPreview: false, isBusy: true, lastActivity: quietSince)
        XCTAssertEqual(PreviewCardLifecycle.sweep(front, now: now), .keep)
    }

    func testCardOfAnAppThatQuitLeavesEvenInFront() {
        let quit = PreviewCardLifecycle.Card(isBrowser: false, isFront: true, hasPreview: true, isBusy: true, appRunning: false, lastActivity: justNow)
        XCTAssertEqual(PreviewCardLifecycle.sweep(quit, now: now), .remove)
    }

    func testQuietBrowserPlaceholderLeaves() {
        let placeholder = PreviewCardLifecycle.Card(isBrowser: true, hasPreview: false, isBusy: true, lastActivity: quietSince)
        XCTAssertEqual(PreviewCardLifecycle.sweep(placeholder, now: now), .remove)
    }

    func testFinishedCardIsLeftToTheCompletionCleanup() {
        let finished = PreviewCardLifecycle.Card(isBrowser: false, hasPreview: false, isBusy: false, isCompleted: true, lastActivity: quietSince)
        XCTAssertEqual(PreviewCardLifecycle.sweep(finished, now: now), .keep)
    }

    // MARK: task_complete

    private func finishes(
        isBrowser: Bool, tab: Int? = nil, pid: Int32? = nil,
        finishedTabs: Set<Int>, finishedTab: Int? = nil, finishedApp: Int32? = nil
    ) -> Bool {
        PreviewCardLifecycle.taskCompleteFinishes(
            isBrowser: isBrowser, browserTabId: tab, appPid: pid,
            finishedTabIds: finishedTabs, finishedTabId: finishedTab, finishedAppPid: finishedApp
        )
    }

    func testDoneWithOnlyATaskIdFinishesTheNativeAppCard() {
        // `usemac done --task X` after TextEdit work: the task owned no tab and named no app. Before, the card stayed
        // busy forever (and, in front, brought the Stop button and spinner back after the completion check).
        XCTAssertTrue(finishes(isBrowser: false, pid: 300, finishedTabs: []))
    }

    func testBrowserTaskDoneLeavesNativeCardsAlone() {
        XCTAssertFalse(finishes(isBrowser: false, pid: 300, finishedTabs: [11]))
    }

    func testNamedAppFinishesOnlyThatApp() {
        XCTAssertTrue(finishes(isBrowser: false, pid: 300, finishedTabs: [], finishedApp: 300))
        XCTAssertFalse(finishes(isBrowser: false, pid: 301, finishedTabs: [], finishedApp: 300))
    }

    func testTabsFinishOnlyForTheirTask() {
        XCTAssertTrue(finishes(isBrowser: true, tab: 11, finishedTabs: [11, 12]))
        XCTAssertFalse(finishes(isBrowser: true, tab: 13, finishedTabs: [11, 12]))
        XCTAssertTrue(finishes(isBrowser: true, tab: 13, finishedTabs: [], finishedTab: 13))
    }

    func testBrowserPlaceholderFinishes() {
        XCTAssertTrue(finishes(isBrowser: true, tab: nil, finishedTabs: [11]))
    }

    // MARK: Stills

    func testBackgroundNativeCardGetsAStill() {
        XCTAssertTrue(PreviewCardLifecycle.wantsStill(isBrowser: false, isChromium: false, isFront: false, hasPreview: false, lastAttempt: nil, now: now))
        // Refreshed while its agent works, but not on every step.
        XCTAssertFalse(PreviewCardLifecycle.wantsStill(isBrowser: false, isChromium: false, isFront: false, hasPreview: true, lastAttempt: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(PreviewCardLifecycle.wantsStill(isBrowser: false, isChromium: false, isFront: false, hasPreview: true, lastAttempt: now.addingTimeInterval(-5), now: now))
    }

    func testNoStillsForTabsChromiumOrTheStreamedFrontCard() {
        XCTAssertFalse(PreviewCardLifecycle.wantsStill(isBrowser: true, isChromium: false, isFront: false, hasPreview: false, lastAttempt: nil, now: now))
        XCTAssertFalse(PreviewCardLifecycle.wantsStill(isBrowser: false, isChromium: true, isFront: false, hasPreview: false, lastAttempt: nil, now: now))
        XCTAssertFalse(PreviewCardLifecycle.wantsStill(isBrowser: false, isChromium: false, isFront: true, hasPreview: true, lastAttempt: nil, now: now))
        // A front card with no picture yet may get one (its stream has not delivered a frame).
        XCTAssertTrue(PreviewCardLifecycle.wantsStill(isBrowser: false, isChromium: false, isFront: true, hasPreview: false, lastAttempt: nil, now: now))
    }

    func testStageKeepsTheFrontCardsStillWhenTheStreamGoesIdle() {
        XCTAssertTrue(PreviewCardLifecycle.stageKeepsStill(frontIsBrowser: false, frontIsChromium: false, frontHasPreview: true))
        XCTAssertFalse(PreviewCardLifecycle.stageKeepsStill(frontIsBrowser: false, frontIsChromium: false, frontHasPreview: false))
        XCTAssertFalse(PreviewCardLifecycle.stageKeepsStill(frontIsBrowser: false, frontIsChromium: true, frontHasPreview: true))
    }
}
