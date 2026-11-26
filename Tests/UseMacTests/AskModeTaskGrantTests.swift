import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// "Allow for this task" end to end: needs the envelope `taskId` (#36).
final class AskModeTaskGrantTests: XCTestCase {
    private let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)

    private func eval(taskId: String?) -> RPCRequest {
        RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(tabId: 41, mode: "eval", expression: "document.title"),
            taskId: taskId
        )
    }

    private func prompt(_ broker: ApprovalBroker) async -> ApprovalPrompt? {
        for _ in 0..<200 {
            if let prompt = broker.currentPrompt { return prompt }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func testAllowForThisTaskLastsUntilTheTaskCompletes() async throws {
        let service = UseMacEngineService(socketPath: "/tmp/usemac-ask-task-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
        service.setGovernancePolicy(.ask)
        let broker = service.approvals
        broker.timeoutInterval = 0.5

        let started = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "ask grant")))
        let taskId = try XCTUnwrap(started.taskId)

        async let first = service.handle(eval(taskId: taskId))
        guard let shown = await prompt(broker) else { return XCTFail("no prompt") }
        XCTAssertEqual(shown.taskId, taskId)
        XCTAssertTrue(shown.canAllowForTask)
        XCTAssertTrue(broker.decide(promptId: shown.id, decision: .allowForTask, click: click))
        let firstResponse = await first
        XCTAssertNotEqual(firstResponse.error?.code, "APPROVAL_DENIED")
        XCTAssertNotEqual(firstResponse.error?.code, "APPROVAL_TIMEOUT")

        // Same task, same kind, same profile: no prompt.
        let second = await service.handle(eval(taskId: taskId))
        XCTAssertNotEqual(second.error?.code, "APPROVAL_TIMEOUT")
        XCTAssertTrue(service.recentAuditEntries(limit: 5).contains { $0.summary.hasPrefix("Approval: allowed by the grant for task \(taskId)") })

        // A request that doesn't name the task gets no grant, even with only this task running.
        let unnamed = await service.handle(eval(taskId: nil))
        XCTAssertEqual(unnamed.error?.code, "APPROVAL_TIMEOUT")

        // After task_complete the grant is gone.
        _ = await service.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(summary: "done", taskId: taskId)))
        let afterDone = await service.handle(eval(taskId: taskId))
        XCTAssertEqual(afterDone.error?.code, "APPROVAL_TIMEOUT")
    }
}
