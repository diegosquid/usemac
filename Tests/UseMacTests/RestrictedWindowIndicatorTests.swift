import UseMacEngine
import UseMacProtocol
import XCTest

final class RestrictedWindowIndicatorTests: XCTestCase {
    private let windowBounds = ScreenRect(x: 40, y: 80, width: 120, height: 120)

    func testShowsForRestrictedChromiumActivityWithValidWindowBounds() {
        var item = activity(.actionStart, title: "  Open settings\n")
        XCTAssertEqual(decide(item), .show(step: "Open settings"))

        let longStep = String(repeating: "é", count: 60)
        item.kind = .actionStep
        item.title = " \(longStep)extra"
        XCTAssertEqual(decide(item), .show(step: longStep))
        item.title = " \n "
        XCTAssertEqual(decide(item), .show(step: nil))

        item.title = "Do not repeat this title"
        for kind: LiveActivityKind in [.observe, .actionComplete] {
            item.kind = kind
            XCTAssertEqual(decide(item), .show(step: nil))
        }
        for kind: LiveActivityKind in [.taskStart, .screenshot, .highlight] {
            item.kind = kind
            XCTAssertEqual(decide(item), .ignore)
        }
    }

    func testIgnoresChromeBridgeActivityBecauseExtensionDrawsItsOwnIndicator() {
        XCTAssertEqual(decide(activity(.actionStep), isChromeBridgeActivity: true), .ignore)
    }

    func testIgnoresNonChromiumNativeApps() {
        var item = activity(.actionStep)
        item.appName = "Notes"
        item.bundleId = "com.apple.Notes"
        XCTAssertEqual(decide(item, isChromiumApp: false), .ignore)
    }

    func testOnlyRestrictedPagesShowAnIndicatorAndAnExplicitNormalPageClearsIt() {
        var item = activity(.observe, taskId: "current-task")
        item.isRestrictedPageFallback = nil
        XCTAssertEqual(decide(item), .ignore)
        item.isRestrictedPageFallback = false
        XCTAssertEqual(decide(item), .ignore)

        item.isRestrictedPageFallback = true
        XCTAssertEqual(decide(item), .show(step: nil))
        item.isRestrictedPageFallback = nil
        XCTAssertEqual(decide(item, currentTaskId: "current-task"), .ignore)
        item.isRestrictedPageFallback = false
        XCTAssertEqual(decide(item, currentTaskId: "current-task"), .clear)
        XCTAssertEqual(decide(item, currentTaskId: "other-task"), .ignore)
    }

    func testSameTaskClearsIndicatorImmediatelyWhenReturningToBridgeOrChangingApps() {
        var item = activity(.actionStep, taskId: "current-task")
        item.windowBounds = nil
        XCTAssertEqual(decide(item, isChromeBridgeActivity: true, currentTaskId: "current-task"), .clear)
        XCTAssertEqual(decide(item, isChromiumApp: false, currentTaskId: "current-task"), .clear)
    }

    func testOtherTaskReturningToBridgeDoesNotClearCurrentIndicator() {
        let item = activity(.actionStep, taskId: "other-task")
        XCTAssertEqual(decide(item, isChromeBridgeActivity: true, currentTaskId: "current-task"), .ignore)
    }

    func testNativeCardIdUsesWindowIdentityBeforeTaskIdentity() {
        let first = RestrictedWindowIndicator.nativeCardId(pid: 42, windowId: 101, taskId: "task-one")
        let second = RestrictedWindowIndicator.nativeCardId(pid: 42, windowId: 102, taskId: "task-two")
        XCTAssertEqual(first, "app:42:win:101")
        XCTAssertEqual(second, "app:42:win:102")
        XCTAssertEqual(first, RestrictedWindowIndicator.nativeCardId(pid: 42, windowId: 101, taskId: "task-two"))
    }

    func testNativeCardIdUsesTrimmedTaskIdentityOrFallsBackToPID() {
        let first = RestrictedWindowIndicator.nativeCardId(pid: 42, windowId: nil, taskId: " task-one\n")
        let second = RestrictedWindowIndicator.nativeCardId(pid: 42, windowId: nil, taskId: "task-two")
        XCTAssertEqual(first, "app:42:task:task-one")
        XCTAssertEqual(second, "app:42:task:task-two")
        for taskId: String? in [nil, "", " \n\t"] {
            XCTAssertEqual(RestrictedWindowIndicator.nativeCardId(pid: 42, windowId: nil, taskId: taskId), "app:42")
        }
    }

    func testIgnoresGuessedTargetsAndTinyHelperWindows() {
        var item = activity(.observe)
        item.targetGuessed = true
        XCTAssertEqual(decide(item), .ignore)

        item.targetGuessed = false
        item.windowBounds?.width = 119
        XCTAssertEqual(decide(item), .ignore)
        item.windowBounds = windowBounds
        item.windowBounds?.height = 119
        XCTAssertEqual(decide(item), .ignore)
        item.windowBounds = nil
        XCTAssertEqual(decide(item), .ignore)

        item.windowBounds = windowBounds
        for pid: Int32? in [nil, 0, -1] {
            item.appPid = pid
            XCTAssertEqual(decide(item), .ignore)
        }
    }

    func testClearsWhenKillSwitchOrPauseBlocksActions() {
        XCTAssertEqual(decide(activity(.actionStart), canAct: false), .clear)
        XCTAssertEqual(
            decide(activity(.taskComplete, taskId: "other-task"), canAct: false, currentTaskId: "current-task"),
            .clear
        )
    }

    func testTaskCompleteClearsMatchingOrUnscopedAndIgnoresOtherTasks() {
        let item = activity(.taskComplete, taskId: "current-task")
        XCTAssertEqual(decide(item, currentTaskId: "current-task"), .clear)
        XCTAssertEqual(decide(item, currentTaskId: nil), .clear)
        XCTAssertEqual(decide(item, currentTaskId: "other-task"), .ignore)
        XCTAssertEqual(decide(activity(.taskComplete), currentTaskId: "current-task"), .clear)
    }

    func testPolicyOrSafetyEventClearsIndicator() {
        var item = activity(.policyOrSafety)
        item.targetGuessed = true
        XCTAssertEqual(decide(item, isChromeBridgeActivity: true, isChromiumApp: false), .clear)
    }

    private func activity(_ kind: LiveActivityKind, title: String = "Open settings", taskId: String? = nil) -> LiveActivityItem {
        var item = LiveActivityItem(
            kind: kind, appName: "Google Chrome", appPid: 42, bundleId: "com.google.Chrome",
            windowBounds: windowBounds, title: title, taskId: taskId
        )
        item.isRestrictedPageFallback = true
        return item
    }

    private func decide(
        _ item: LiveActivityItem,
        isChromeBridgeActivity: Bool = false,
        isChromiumApp: Bool = true,
        canAct: Bool = true,
        currentTaskId: String? = nil
    ) -> RestrictedWindowIndicator.Action {
        RestrictedWindowIndicator.decide(
            for: item,
            isChromeBridgeActivity: isChromeBridgeActivity,
            isChromiumApp: isChromiumApp,
            canAct: canAct,
            currentTaskId: currentTaskId
        )
    }
}
