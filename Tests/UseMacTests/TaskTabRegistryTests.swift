import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

final class TaskTabRegistryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFinishingOneTaskNeverClosesAnotherTasksTabs() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        registry.recordOpenedTab(2, taskId: b, now: t0)

        let done = registry.complete(taskId: a, tabId: nil, now: t0)
        XCTAssertEqual(done.taskId, a)
        XCTAssertEqual(done.ownTabIds, [1], "only A's cards are marked done")
        XCTAssertEqual(done.protectedTabIds, [2], "B's tab is kept open")
        XCTAssertEqual(registry.runningTaskCount, 1)
    }

    func testTheTabATaskNamesTellsWhichTaskFinished() {
        // An agent that forgot its taskId but passes its tab (usemac done --tab 1).
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        registry.recordOpenedTab(2, taskId: b, now: t0)

        let done = registry.complete(taskId: nil, tabId: 1, now: t0)
        XCTAssertEqual(done.taskId, a)
        XCTAssertEqual(done.protectedTabIds, [2])
    }

    func testWithOneTaskRunningRequestsWithoutAnIdBelongToIt() {
        let registry = TaskTabRegistry()
        let only = registry.start(now: t0)
        registry.recordOpenedTab(7, taskId: nil, now: t0)

        let done = registry.complete(taskId: nil, tabId: nil, now: t0)
        XCTAssertEqual(done.taskId, only)
        XCTAssertEqual(done.ownTabIds, [7])
        XCTAssertEqual(done.protectedTabIds, [])
    }

    func testWhenItCannotTellWhoFinishedItClosesNothingARunningTaskOwns() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        registry.recordOpenedTab(2, taskId: b, now: t0)

        let done = registry.complete(taskId: nil, tabId: nil, now: t0)
        XCTAssertNil(done.taskId)
        XCTAssertEqual(done.protectedTabIds, [1, 2])
        XCTAssertEqual(done.ownTabIds, [], "no card is marked done")
        XCTAssertEqual(registry.runningTaskCount, 2, "neither task ends")
    }

    func testWithNoTasksAtAllItBehavesAsBefore() {
        let registry = TaskTabRegistry()
        let done = registry.complete(taskId: nil, tabId: nil, now: t0)
        XCTAssertNil(done.taskId)
        XCTAssertEqual(done.protectedTabIds, [])
        XCTAssertNil(done.ownTabIds, "every card belongs to whoever finished")
    }

    func testATabOpenedWithoutAnIdWhileSeveralTasksRunBelongsToNoTask() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        registry.recordOpenedTab(9, taskId: nil, now: t0)

        let done = registry.complete(taskId: a, tabId: nil, now: t0)
        XCTAssertEqual(done.ownTabIds, [])
        XCTAssertFalse(done.protectedTabIds.contains(9), "an unowned tab is closed like before")
    }

    func testCallerChosenIdAndUnknownIds() {
        let registry = TaskTabRegistry()
        XCTAssertEqual(registry.start(taskId: "  mine ", now: t0), "mine")
        let other = registry.start(now: t0)
        XCTAssertTrue(other.hasPrefix("task-"))
        // An id that is not running belongs to no task, even when its tab or a single running task would say otherwise.
        XCTAssertNil(registry.resolve(taskId: "gone", tabId: nil, now: t0))
        XCTAssertEqual(registry.resolve(taskId: "mine", tabId: nil, now: t0), "mine")
    }

    func testAFinishedTasksIdNeverFinishesTheOnlyOtherTask() {
        // Agent B finished (or expired) and calls done --task B again while only A runs: A must keep its tabs.
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)

        let done = registry.complete(taskId: "task-b", tabId: nil, now: t0)
        XCTAssertNil(done.taskId)
        XCTAssertEqual(done.protectedTabIds, [1], "A's tab stays open")
        XCTAssertEqual(done.ownTabIds, [])
        XCTAssertEqual(registry.runningTaskCount, 1)
    }

    func testIdleTasksStopProtectingTheirTabs() {
        let registry = TaskTabRegistry()
        let stale = registry.start(now: t0)
        registry.recordOpenedTab(3, taskId: stale, now: t0)
        let fresh = registry.start(now: t0.addingTimeInterval(TaskTabRegistry.idleExpiry + 1))

        let done = registry.complete(taskId: fresh, tabId: nil, now: t0.addingTimeInterval(TaskTabRegistry.idleExpiry + 2))
        XCTAssertEqual(done.protectedTabIds, [], "a task idle for 30 min no longer keeps its tabs")
        XCTAssertEqual(registry.runningTaskCount, 0)
    }

    func testExpiringATaskClearsOnlyItsWindowPins() {
        let registry = TaskTabRegistry()
        let stale = registry.start(now: t0)
        let freshTime = t0.addingTimeInterval(TaskTabRegistry.idleExpiry - 1)
        let fresh = registry.start(now: freshTime)
        let pid: Int32 = 101
        WindowResolver.pin(pid: pid, title: "Stale window", taskId: stale)
        WindowResolver.pin(pid: pid, title: "Fresh window", taskId: fresh)
        defer {
            WindowResolver.clearPins(forTaskId: stale)
            WindowResolver.clearPins(forTaskId: fresh)
        }
        XCTAssertEqual(WindowResolver.pinnedTitle(pid: pid, taskId: stale), "Stale window")
        XCTAssertEqual(WindowResolver.pinnedTitle(pid: pid, taskId: fresh), "Fresh window")

        XCTAssertNil(registry.resolve(taskId: stale, tabId: nil, now: freshTime.addingTimeInterval(1)))
        XCTAssertNil(WindowResolver.pinnedTitle(pid: pid, taskId: stale))
        XCTAssertEqual(WindowResolver.pinnedTitle(pid: pid, taskId: fresh), "Fresh window")
    }

    func testForgetTabDropsItFromItsTask() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        registry.recordOpenedTab(4, taskId: a, now: t0)
        registry.forgetTab(4)
        XCTAssertNil(registry.resolve(taskId: nil, tabId: 4, now: t0))
    }

    func testCompletionIncludesOnlyAppsRecordedOrClaimedByThatTask() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordApp(101, taskId: a, now: t0)
        registry.recordApp(101, taskId: a, now: t0)
        registry.recordApp(0, taskId: a, now: t0)
        registry.recordApp(201, taskId: b, now: t0)
        registry.recordApp(301, taskId: nil, now: t0)
        registry.recordApp(401, taskId: "unknown", now: t0)

        let request = RPCRequest(method: .observe)
        let scopeA = TaskTabRegistry.Scope(request: request, taskId: a, filledTabId: nil)
        let scopeB = TaskTabRegistry.Scope(request: request, taskId: b, filledTabId: nil)
        let window = TaskTabRegistry.WindowLease(pid: 102, windowId: 1, label: "Window")
        let invalidWindow = TaskTabRegistry.WindowLease(pid: 0, windowId: 2, label: "Unknown window")
        XCTAssertNil(registry.claim(scopeA, windows: [window, invalidWindow], tabs: [], now: t0))
        XCTAssertEqual(registry.claim(scopeB, windows: [window], tabs: [], now: t0)?.taskId, a)

        XCTAssertEqual(registry.complete(taskId: a, tabId: nil, now: t0).ownAppPids, [101, 102])
        XCTAssertEqual(registry.complete(taskId: b, tabId: nil, now: t0).ownAppPids, [201])
    }

    func testRecordingAnAppRefreshesTheOnlyRunningTask() {
        let registry = TaskTabRegistry()
        let task = registry.start(now: t0)
        let expiry = TaskTabRegistry.idleExpiry
        registry.recordApp(101, taskId: nil, now: t0.addingTimeInterval(expiry - 1))

        let done = registry.complete(taskId: nil, tabId: nil, now: t0.addingTimeInterval(expiry + 1))
        XCTAssertEqual(done.taskId, task)
        XCTAssertEqual(done.ownAppPids, [101])
    }

    func testCompletionDistinguishesNoKnownAppsFromNoRunningTask() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordApp(101, taskId: b, now: t0)

        XCTAssertEqual(registry.complete(taskId: nil, tabId: nil, now: t0).ownAppPids, [])
        XCTAssertEqual(registry.complete(taskId: a, tabId: nil, now: t0).ownAppPids, [])
        XCTAssertEqual(registry.complete(taskId: a, tabId: nil, now: t0).ownAppPids, [])
        XCTAssertEqual(registry.complete(taskId: b, tabId: nil, now: t0).ownAppPids, [101])
        XCTAssertNil(registry.complete(taskId: nil, tabId: nil, now: t0).ownAppPids)
    }

    func testOwnedTabsFilterByProfileAfterRecentHistoryEvictsTabs() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, profile: " Work ", now: t0)
        registry.recordOpenedTab(1, taskId: a, profile: " ", now: t0)
        registry.recordOpenedTab(2, taskId: a, now: t0)
        registry.recordOpenedTab(2, taskId: b, now: t0)
        for tab in (3...20).reversed() {
            registry.recordOpenedTab(tab, taskId: a, profile: "Personal", now: t0)
        }
        let scope = TaskTabRegistry.Scope(request: RPCRequest(method: .observe), taskId: a, filledTabId: nil)
        XCTAssertNil(registry.claim(scope, windows: [], tabs: [21], now: t0))
        XCTAssertTrue(registry.protectedTabIds(now: t0).contains(21))

        XCTAssertEqual(registry.ownedTabIds(now: t0), Array(1...20))
        XCTAssertEqual(registry.ownedTabIds(forProfile: " \n", now: t0), Array(1...20))
        XCTAssertEqual(registry.ownedTabIds(forProfile: " wOrK \n", now: t0), [1])
        XCTAssertEqual(registry.ownedTabIds(forProfile: "Personal", now: t0), Array(3...20))

        registry.forgetTab(1)
        XCTAssertEqual(registry.ownedTabIds(now: t0), Array(2...20))
        registry.recordOpenedTab(1, taskId: a, now: t0)
        XCTAssertEqual(registry.ownedTabIds(forProfile: "Work", now: t0), [])
        XCTAssertEqual(registry.ownedTabIds(forProfile: "Personal", now: t0), Array(3...20))
    }

    func testOwnedTabsWithoutProfilesAreNotRestoredToNamedProfiles() {
        let registry = TaskTabRegistry()
        let task = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: task, profile: "Work", now: t0)
        registry.recordOpenedTab(2, taskId: task, now: t0)

        XCTAssertEqual(registry.ownedTabIds(forProfile: nil, now: t0), [1, 2])
        XCTAssertEqual(registry.ownedTabIds(forProfile: "work", now: t0), [1])
        XCTAssertEqual(registry.ownedTabIds(forProfile: "Personal", now: t0), [])
    }

    func testOwnedTabsExcludeExpiredAndCompletedTasks() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        let later = t0.addingTimeInterval(TaskTabRegistry.idleExpiry - 1)
        registry.recordOpenedTab(1, taskId: a, profile: "Work", now: t0)
        registry.recordOpenedTab(2, taskId: b, profile: "Work", now: later)

        let afterExpiry = later.addingTimeInterval(2)
        XCTAssertEqual(registry.ownedTabIds(forProfile: "Work", now: afterExpiry), [2])
        _ = registry.complete(taskId: b, tabId: nil, keepTabs: true, now: afterExpiry)
        XCTAssertEqual(registry.ownedTabIds(forProfile: "Work", now: afterExpiry), [])
    }

    func testPendingBrowserOpenCountsOverlappingOpensWithoutUnderflow() {
        let registry = TaskTabRegistry()
        XCTAssertFalse(registry.hasPendingBrowserOpen)
        registry.endBrowserOpen()
        registry.beginBrowserOpen()
        XCTAssertTrue(registry.hasPendingBrowserOpen)
        registry.beginBrowserOpen()
        registry.endBrowserOpen()
        XCTAssertTrue(registry.hasPendingBrowserOpen)
        registry.endBrowserOpen()
        registry.endBrowserOpen()
        XCTAssertFalse(registry.hasPendingBrowserOpen)
        registry.beginBrowserOpen()
        XCTAssertTrue(registry.hasPendingBrowserOpen)
        registry.endBrowserOpen()
        XCTAssertFalse(registry.hasPendingBrowserOpen)
    }
}
