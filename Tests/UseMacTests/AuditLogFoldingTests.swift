import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// History lists entries newest first, so these build them that way: `at` counts seconds, larger is newer.
private func entry(
    _ summary: String = "Listed 10 tab(s)",
    at second: Int64,
    method: String = "browser_tabs",
    app: String? = "Chrome (Diego)",
    success: Bool = true,
    taskId: String? = "task-0cbf8bf6",
    agent: String? = nil
) -> AuditEntry {
    AuditEntry(
        timestampMs: 1_764_115_303_000 + second * 1000,
        method: method,
        targetApp: app,
        summary: summary,
        latencyMs: 3,
        success: success,
        taskId: taskId,
        agent: agent
    )
}

final class AuditLogFoldingTests: XCTestCase {
    func testConsecutiveIdenticalEntriesFoldWithCountAndTimeRange() {
        let newestFirst = (0..<5).reversed().map { entry(at: Int64($0)) }

        let runs = AuditLogFolding.fold(newestFirst)

        XCTAssertEqual(runs.count, 1)
        let run = runs[0]
        XCTAssertEqual(run.count, 5)
        XCTAssertTrue(run.isFolded)
        XCTAssertEqual(run.firstTimestampMs, newestFirst.last!.timestampMs, "first is the oldest")
        XCTAssertEqual(run.lastTimestampMs, newestFirst.first!.timestampMs, "last is the newest")
        XCTAssertEqual(run.entries.map(\.id), newestFirst.map(\.id), "every entry stays, in order")
        XCTAssertEqual(run.representative.id, newestFirst.first!.id)
        XCTAssertEqual(run.kind, .observation)
    }

    func testRunKeepsItsIdWhileNewerEntriesJoin() {
        let older = (0..<3).reversed().map { entry(at: Int64($0)) }
        let before = AuditLogFolding.fold(older)
        let after = AuditLogFolding.fold([entry(at: 3)] + older)

        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].count, 4)
        XCTAssertEqual(after[0].id, before[0].id, "an expanded row stays expanded as the run grows")
    }

    func testInterleavedEntriesDoNotFold() {
        let newestFirst = [
            entry(at: 4),
            entry("Observed 12 DOM elements", at: 3, method: "browser_observe"),
            entry(at: 2),
            entry("Observed 12 DOM elements", at: 1, method: "browser_observe"),
            entry(at: 0)
        ]

        let runs = AuditLogFolding.fold(newestFirst)

        XCTAssertEqual(runs.count, 5)
        XCTAssertTrue(runs.allSatisfy { !$0.isFolded })
        XCTAssertEqual(runs.map(\.representative.id), newestFirst.map(\.id), "still chronological")
    }

    func testSuccessAndFailureNeverFoldTogether() {
        let newestFirst = [
            entry("Extension not connected", at: 3, success: false),
            entry("Extension not connected", at: 2, success: false),
            entry("Extension not connected", at: 1, success: true),
            entry("Extension not connected", at: 0, success: true)
        ]

        let runs = AuditLogFolding.fold(newestFirst)

        XCTAssertEqual(runs.map(\.count), [2, 2])
        XCTAssertEqual(runs.map(\.representative.success), [false, true])
    }

    func testDifferentTasksDoNotFold() {
        let newestFirst = [
            entry(at: 3, taskId: "task-b"),
            entry(at: 2, taskId: "task-a"),
            entry(at: 1, taskId: "task-a"),
            entry(at: 0, taskId: nil)
        ]

        XCTAssertEqual(AuditLogFolding.fold(newestFirst).map(\.count), [1, 2, 1])
    }

    func testDifferentAgentsDoNotFold() {
        let newestFirst = [
            entry(at: 3, agent: "Claude Code"),
            entry(at: 2, agent: "Codex"),
            entry(at: 1, agent: "Codex"),
            entry(at: 0)
        ]

        XCTAssertEqual(AuditLogFolding.fold(newestFirst).map(\.count), [1, 2, 1])
    }

    func testAppMethodAndSummaryMustMatch() {
        XCTAssertEqual(AuditLogFolding.fold([entry(at: 1), entry(at: 0, app: "Chrome (Work)")]).count, 2)
        XCTAssertEqual(AuditLogFolding.fold([entry(at: 1), entry(at: 0, method: "browser_status")]).count, 2)
        XCTAssertEqual(AuditLogFolding.fold([entry(at: 1), entry("Listed 11 tab(s)", at: 0)]).count, 2)
    }

    func testLatencyAndIdDoNotPreventFolding() {
        var slower = entry(at: 0)
        slower.latencyMs = 250
        XCTAssertEqual(AuditLogFolding.fold([entry(at: 1), slower]).map(\.count), [2])
    }

    func testEmptyInputHasNoRuns() {
        XCTAssertTrue(AuditLogFolding.fold([]).isEmpty)
    }

}

final class AuditEntryKindTests: XCTestCase {
    func testMutatingMethodsAreActions() {
        for method in ["act", "browser_act", "browser_open"] {
            XCTAssertEqual(AuditEntryKind(method: method), .action, method)
        }
    }

    func testReadOnlyMethodsAreObservations() {
        for method in ["observe", "screenshot", "browser_tabs", "browser_observe", "browser_screenshot",
                       "browser_status", "vision_query", "list_apps", "highlight"] {
            XCTAssertEqual(AuditEntryKind(method: method), .observation, method)
        }
    }

    func testBrowserExtractIsAnActionOnlyInEvalMode() {
        XCTAssertEqual(AuditEntryKind(method: "browser_extract", summary: "Extracted table (3 rows, 2 cols)"), .observation)
        XCTAssertEqual(
            AuditEntryKind(method: "browser_extract", summary: AuditRedactor.evalSummary("document.title", recordText: false)),
            .action,
            "the eval summary the engine writes"
        )
        XCTAssertEqual(
            AuditEntryKind(method: "browser_extract", summary: AuditRedactor.evalSummary("document.title", recordText: true)),
            .action
        )
    }

    func testTasksSettingsAndUnknownMethodsAreOther() {
        for method in ["task_start", "task_complete", "set_policy", "pair_app", "skill_save", "report_prepare", "approval", "something_new"] {
            XCTAssertEqual(AuditEntryKind(method: method), .other, method)
        }
    }

    func testQueryCanHideObservations() {
        let newestFirst = [
            entry("Executed 1 browser step(s): ok · click", at: 3, method: "browser_act"),
            entry(at: 2),
            entry("Task started", at: 1, method: "task_start"),
            entry(at: 0)
        ]
        let query = AuditLogQuery(limit: nil, kinds: [.action, .other])

        XCTAssertEqual(query.apply(to: newestFirst).map(\.method), ["browser_act", "task_start"])
        XCTAssertEqual(AuditLogQuery(limit: nil).apply(to: newestFirst).count, 4, "no kinds keeps everything")
    }
}
