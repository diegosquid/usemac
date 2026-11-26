import XCTest
@testable import UseMacEngine

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
        // An id that is not running falls back to the other rules (here: two tasks, nothing named).
        XCTAssertNil(registry.resolve(taskId: "gone", tabId: nil, now: t0))
        XCTAssertEqual(registry.resolve(taskId: "mine", tabId: nil, now: t0), "mine")
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

    func testForgetTabDropsItFromItsTask() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        registry.recordOpenedTab(4, taskId: a, now: t0)
        registry.forgetTab(4)
        XCTAssertNil(registry.resolve(taskId: nil, tabId: 4, now: t0))
    }
}
