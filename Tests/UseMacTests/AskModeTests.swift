import CoreGraphics
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

final class AskModeTests: XCTestCase {
    private func makeService() -> UseMacEngineService {
        UseMacEngineService(
            socketPath: "/tmp/usemac-ask-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0
        )
    }

    /// A click as the prompt would see it from the HID system (tests can't make a real one).
    private let testClick = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)

    private func evalRequest(_ expression: String = "document.title", tabId: Int? = 41) -> RPCRequest {
        RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(tabId: tabId, mode: "eval", expression: expression))
    }

    private func waitForPrompt(_ broker: ApprovalBroker, count: Int = 1, timeout: TimeInterval = 2) async -> ApprovalPrompt? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if broker.pendingCount >= count, let prompt = broker.currentPrompt { return prompt }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private struct NoPrompt: Error {}

    private func requirePrompt(_ broker: ApprovalBroker, count: Int = 1) async throws -> ApprovalPrompt {
        guard let prompt = await waitForPrompt(broker, count: count) else {
            XCTFail("No approval prompt appeared")
            throw NoPrompt()
        }
        return prompt
    }

    // MARK: - Mode and strictness

    func testAskSitsBetweenAutonomousAndBlockSensitive() async {
        let service = makeService()
        let intoAsk = await service.handle(RPCRequest(method: .setPolicy, policy: .ask))
        XCTAssertTrue(intoAsk.ok)
        XCTAssertEqual(service.getGovernancePolicy(), .ask)

        let backToAutonomous = await service.handle(RPCRequest(method: .setPolicy, policy: .autonomous))
        XCTAssertEqual(backToAutonomous.error?.code, "POLICY_LOCKED")
        XCTAssertEqual(service.getGovernancePolicy(), .ask)

        let tighter = await service.handle(RPCRequest(method: .setPolicy, policy: .confirmSensitive))
        XCTAssertTrue(tighter.ok)
        let relaxToAsk = await service.handle(RPCRequest(method: .setPolicy, policy: .ask))
        XCTAssertEqual(relaxToAsk.error?.code, "POLICY_LOCKED")
        XCTAssertEqual(service.getGovernancePolicy(), .confirmSensitive)
        XCTAssertEqual(GovernancePolicy(rawValue: "ask"), .ask)
    }

    func testAskDoesNotHoldReadsOrNonSensitiveSteps() async {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        let text = await service.handle(RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "text")))
        XCTAssertEqual(text.error?.code, "EXTENSION_NOT_CONNECTED")
        let click = await service.handle(RPCRequest(method: .browserAct, browserAct: BrowserActParams(tabId: 3, steps: [
            ActionStep(action: .click, elementId: "@b1"),
            ActionStep(action: .pressKey, key: "return")
        ])))
        XCTAssertEqual(click.error?.code, "EXTENSION_NOT_CONNECTED")
        XCTAssertEqual(service.approvals.pendingCount, 0)
    }

    // MARK: - Answers

    func testNoAnswerDeniesWithApprovalTimeoutAndAudits() async {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        service.approvals.timeoutInterval = 0.3
        let started = Date()
        let response = await service.handle(evalRequest())
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "APPROVAL_TIMEOUT")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(service.approvals.pendingCount, 0)
        let audit = service.recentAuditEntries(limit: 1).first
        XCTAssertEqual(audit?.success, false)
        XCTAssertTrue(audit?.summary.hasPrefix("Approval: timed out") == true, audit?.summary ?? "")
        XCTAssertTrue(audit?.summary.contains("Run a page script") == true, "The audit log may redact the script itself")
    }

    func testDenyAndAllowFromThePrompt() async throws {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        let broker = service.approvals

        async let denied = service.handle(evalRequest())
        let first = try await requirePrompt(broker)
        XCTAssertEqual(first.method, "browser_extract")
        XCTAssertEqual(first.kinds, [.script])
        XCTAssertTrue(first.target.hasPrefix("Chrome (Browser) · tab 41"), first.target)
        XCTAssertTrue(broker.decide(promptId: first.id, decision: .deny, click: testClick))
        let deniedResponse = await denied
        XCTAssertEqual(deniedResponse.error?.code, "APPROVAL_DENIED")
        XCTAssertEqual(service.recentAuditEntries(limit: 1).first?.summary.hasPrefix("Approval: denied"), true)

        async let allowed = service.handle(evalRequest())
        let second = try await requirePrompt(broker)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertFalse(broker.decide(promptId: first.id, decision: .allowOnce, click: testClick), "An old prompt can't be answered")
        XCTAssertTrue(broker.decide(promptId: second.id, decision: .allowOnce, click: testClick))
        let allowedResponse = await allowed
        // Allowed, so it went on to Chrome (not connected in tests).
        XCTAssertEqual(allowedResponse.error?.code, "EXTENSION_NOT_CONNECTED")
        let summaries = service.recentAuditEntries(limit: 5).map(\.summary)
        XCTAssertTrue(summaries.contains { $0.hasPrefix("Approval: allowed once") }, "\(summaries)")
    }

    func testOnlyOnePromptAtATimeAndAQueuedPromptGetsTimeOnScreen() async throws {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        let broker = service.approvals
        broker.timeoutInterval = 0.6
        broker.minimumVisibleInterval = 0.5

        async let first = service.handle(evalRequest("1+1"))
        let shown = try await requirePrompt(broker)
        async let second = service.handle(evalRequest("2+2"))
        let both = try await requirePrompt(broker, count: 2)
        XCTAssertEqual(both.id, shown.id, "The second request waits behind the first")
        XCTAssertEqual(both.waitingBehind, 1)

        // Nobody answers the first: it times out, and the second reaches the screen with at least 0.5 s to go.
        let firstResponse = await first
        XCTAssertEqual(firstResponse.error?.code, "APPROVAL_TIMEOUT")
        let next = try XCTUnwrap(broker.currentPrompt)
        XCTAssertNotEqual(next.id, shown.id)
        XCTAssertEqual(next.waitingBehind, 0)
        XCTAssertGreaterThan(next.deadline.timeIntervalSinceNow, 0.3)
        XCTAssertTrue(broker.decide(promptId: next.id, decision: .deny, click: testClick))
        let secondResponse = await second
        XCTAssertEqual(secondResponse.error?.code, "APPROVAL_DENIED")
        XCTAssertNil(broker.currentPrompt)
    }

    func testKillSwitchOrModeChangeWhileWaitingAnswersPolicyBlocked() async throws {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        let broker = service.approvals

        async let tripped = service.handle(evalRequest())
        _ = try await requirePrompt(broker)
        service.tripKillSwitch(true)
        let trippedResponse = await tripped
        XCTAssertEqual(trippedResponse.error?.code, "POLICY_BLOCKED")
        XCTAssertTrue(trippedResponse.error?.message.contains("Kill Switch") == true)
        service.tripKillSwitch(false)

        async let changed = service.handle(evalRequest())
        _ = try await requirePrompt(broker)
        service.setGovernancePolicy(.autonomous)
        let changedResponse = await changed
        XCTAssertEqual(changedResponse.error?.code, "POLICY_BLOCKED")
        XCTAssertTrue(changedResponse.error?.message.contains("execution mode changed") == true)
    }

    func testBrowserActPromptShowsTheCanonicalUploadPathAndShortcut() async throws {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        let broker = service.approvals
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/usemac-ask-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: file)

        let raw = folder.path + "/./report.pdf"
        async let response = service.handle(RPCRequest(method: .browserAct, browserAct: BrowserActParams(tabId: 7, steps: [
            ActionStep(action: .click, elementId: "@b1"),
            ActionStep(action: .uploadFile, files: [raw]),
            ActionStep(action: .pressKey, key: "s", modifiers: ["cmd"])
        ])))
        let prompt = try await requirePrompt(broker)
        XCTAssertEqual(prompt.kinds, [.upload, .shortcut])
        XCTAssertEqual(prompt.steps.count, 2)
        XCTAssertTrue(prompt.steps[0].hasPrefix("Upload ~/Downloads/"), prompt.steps[0])
        XCTAssertTrue(prompt.steps[0].hasSuffix("/report.pdf"), prompt.steps[0])
        XCTAssertFalse(prompt.steps[0].contains("/./"), "Shows the path UseMac would upload")
        XCTAssertEqual(prompt.steps[1], "Press ⌘S")
        XCTAssertFalse(prompt.canAllowForTask, "Uploads are never allowed for a whole task")
        XCTAssertTrue(broker.decide(promptId: prompt.id, decision: .deny, click: testClick))
        let denied = await response
        XCTAssertEqual(denied.error?.code, "APPROVAL_DENIED")
    }

    // MARK: - Task grants

    func testAllowForTaskCoversTheSameKindAndTargetOnly() async throws {
        let broker = ApprovalBroker(pollInterval: 0.02)
        broker.timeoutInterval = 0.4
        let shortcutInTextEdit = ApprovalBroker.Request(
            method: "act", target: "TextEdit", steps: ["Press ⌘S"], kinds: [.shortcut], taskId: "task-a", grantTarget: "app:textedit"
        )

        async let first = broker.requestApproval(shortcutInTextEdit)
        let prompt = try await requirePrompt(broker)
        XCTAssertTrue(prompt.canAllowForTask)
        XCTAssertTrue(broker.decide(promptId: prompt.id, decision: .allowForTask, click: testClick))
        let firstOutcome = await first
        XCTAssertEqual(firstOutcome, .allowedForTask(taskId: "task-a"))

        let again = await broker.requestApproval(shortcutInTextEdit)
        XCTAssertEqual(again, .allowedByTaskGrant(taskId: "task-a"))
        XCTAssertEqual(broker.pendingCount, 0)

        var otherApp = shortcutInTextEdit
        otherApp.grantTarget = "app:finder"
        let elsewhere = await broker.requestApproval(otherApp)
        guard case .timedOut(_, whileQueued: false) = elsewhere else {
            return XCTFail("Another app needs its own answer: \(elsewhere)")
        }

        var otherTask = shortcutInTextEdit
        otherTask.taskId = "task-b"
        let otherTaskOutcome = await broker.requestApproval(otherTask)
        XCTAssertFalse(otherTaskOutcome.isAllowed)

        var script = shortcutInTextEdit
        script.kinds = [.shortcut, .script]
        let wider = await broker.requestApproval(script)
        XCTAssertFalse(wider.isAllowed, "A grant never widens to a kind the user didn't see")

        broker.endTask("task-a")
        let afterDone = await broker.requestApproval(shortcutInTextEdit)
        XCTAssertFalse(afterDone.isAllowed)
    }

    func testAllowForTaskIsRefusedForUploadsAndRequestsWithoutATask() async throws {
        let broker = ApprovalBroker(pollInterval: 0.02)
        broker.timeoutInterval = 1
        async let upload = broker.requestApproval(ApprovalBroker.Request(
            method: "act", target: "Safari", steps: ["Upload ~/a.pdf"], kinds: [.upload], taskId: "task-a", grantTarget: "app:safari"
        ))
        let prompt = try await requirePrompt(broker)
        XCTAssertFalse(broker.decide(promptId: prompt.id, decision: .allowForTask, click: testClick))
        XCTAssertTrue(broker.decide(promptId: prompt.id, decision: .allowOnce, click: testClick))
        let uploadOutcome = await upload
        XCTAssertEqual(uploadOutcome, .allowedOnce)
        XCTAssertFalse(broker.hasGrant(taskId: "task-a", kind: .upload, target: "app:safari"))

        async let noTask = broker.requestApproval(ApprovalBroker.Request(
            method: "act", target: "TextEdit", steps: ["Press ⌘S"], kinds: [.shortcut], taskId: nil, grantTarget: "app:textedit"
        ))
        let second = try await requirePrompt(broker)
        XCTAssertFalse(second.canAllowForTask)
        XCTAssertFalse(broker.decide(promptId: second.id, decision: .allowForTask, click: testClick))
        XCTAssertTrue(broker.decide(promptId: second.id, decision: .deny, click: testClick))
        let noTaskOutcome = await noTask
        XCTAssertEqual(noTaskOutcome, .denied)
    }

    // MARK: - Unreachable by automation

    func testPostedClicksDoNotCount() {
        // An event this process made carries its pid, like one any agent posts.
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)
        XCTAssertEqual(ApprovalInputCheck.sourcePid(of: down), Int64(getpid()))
        XCTAssertFalse(ApprovalInputCheck.isPhysical(down))
        XCTAssertNil(ApprovalInputCheck.verifyClick(down: down, up: up, downTime: 10, upTime: 10.1, armedAt: 0))
        XCTAssertFalse(ApprovalInputCheck.isPhysical(nil))

        XCTAssertTrue(ApprovalInputCheck.isPhysicalSource(pid: 0))
        XCTAssertFalse(ApprovalInputCheck.isPhysicalSource(pid: Int64(getpid())))
        XCTAssertFalse(ApprovalInputCheck.isPhysicalSource(pid: 1))
    }

    func testClickTimingRules() {
        XCTAssertNotNil(ApprovalInputCheck.verifyTiming(sourcePid: 0, downTime: 10, upTime: 10.2, armedAt: 9))
        XCTAssertNil(ApprovalInputCheck.verifyTiming(sourcePid: 0, downTime: 10, upTime: 10.2, armedAt: 10.5), "Pressed before the buttons armed")
        XCTAssertNil(ApprovalInputCheck.verifyTiming(sourcePid: 0, downTime: 10, upTime: 9.9, armedAt: 0))
        XCTAssertNil(ApprovalInputCheck.verifyTiming(sourcePid: 0, downTime: 10, upTime: 16, armedAt: 0), "Held too long")

        // Both halves of the click must be physical and the left button.
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)
        down?.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertNil(ApprovalInputCheck.verifyClick(down: down, up: up, downTime: 10, upTime: 10.1, armedAt: 0))
        up?.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertNotNil(ApprovalInputCheck.verifyClick(down: down, up: up, downTime: 10, upTime: 10.1, armedAt: 0))
        XCTAssertNil(ApprovalInputCheck.verifyClick(down: up, up: down, downTime: 10, upTime: 10.1, armedAt: 0))
    }

    func testRealMouseInputAimedAtThePromptIsRefused() {
        let killSwitch = KillSwitch()
        XCTAssertNil(killSwitch.approvalPromptRefusal(at: CGPoint(x: 100, y: 100)))
        killSwitch.approvalPromptFrame = CGRect(x: 1000, y: 700, width: 316, height: 160)
        XCTAssertNotNil(killSwitch.approvalPromptRefusal(at: CGPoint(x: 1200, y: 780)))
        XCTAssertNotNil(killSwitch.approvalPromptRefusal(at: CGPoint(x: 990, y: 700)), "A margin around it counts too")
        XCTAssertNil(killSwitch.approvalPromptRefusal(at: CGPoint(x: 500, y: 300)))
        killSwitch.approvalPromptFrame = nil
        XCTAssertNil(killSwitch.approvalPromptRefusal(at: CGPoint(x: 1200, y: 780)))
    }

    func testNoSocketMethodOrMCPToolAnswersAPrompt() async throws {
        for name in ["approve", "approval", "approval_decide", "approve_step", "answer_approval", "decide", "allow", "deny"] {
            XCTAssertNil(RPCMethod(rawValue: name), name)
        }
        let mcp = MCPStdioServer(socketPath: "/tmp/usemac-ask-none-\(UUID().uuidString.prefix(6)).sock", fallbackService: makeService())
        defer { mcp.close() }
        let raw = await mcp.processLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(raw).utf8)) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains { $0.contains("approv") || $0.contains("allow") || $0.contains("deny") }, "\(names)")
    }

    // MARK: - What the prompt says

    func testPromptTextIsCleanedAndReadable() {
        XCTAssertEqual(ApprovalText.shortcut(key: "s", modifiers: ["cmd"]), "⌘S")
        XCTAssertEqual(ApprovalText.shortcut(key: "k", modifiers: ["shift", "cmd", "ctrl", "opt"]), "⌃⌥⇧⌘K")
        XCTAssertEqual(ApprovalText.shortcut(key: "return", modifiers: ["command"]), "⌘Return")
        XCTAssertEqual(ApprovalText.clean("Text\nEdit\u{202E}gpj.exe", limit: 60), "Text Edit gpj.exe")
        XCTAssertEqual(ApprovalText.clean("   ", limit: 10), nil)
        XCTAssertEqual(ApprovalText.clean(String(repeating: "a", count: 30), limit: 10)?.count, 10)
        XCTAssertEqual(ApprovalText.describeScript("document.title"), "Run a page script: document.title")
        XCTAssertEqual(ApprovalText.describeScript("a\nb"), "Run a page script (3 characters)")
        XCTAssertTrue(ApprovalText.describeScript(String(repeating: "x", count: 1240)).hasPrefix("Run a page script (1"))
        let long = "/Users/someone/" + String(repeating: "deep/", count: 20) + "final-report.pdf"
        let shown = ApprovalText.displayPath(long)
        XCTAssertLessThanOrEqual(shown?.count ?? 0, 72)
        XCTAssertTrue(shown?.hasSuffix("final-report.pdf") == true)
        XCTAssertEqual(ApprovalText.capped(["1", "2", "3", "4", "5"]), ["1", "2", "3", "and 2 more sensitive steps"])
    }

    /// Ask mode holds exactly what Block sensitive blocks.
    func testHeldStepsMatchBlockSensitive() async {
        let steps: [ActionStep] = [
            ActionStep(action: .uploadFile, files: ["/tmp/a.txt"]),
            ActionStep(action: .pressKey, key: "s", modifiers: ["cmd"]),
            ActionStep(action: .pressKey, key: "c", modifiers: ["control"]),
            ActionStep(action: .pressKey, key: "a", modifiers: ["shift"]),
            ActionStep(action: .pressKey, key: "return"),
            ActionStep(action: .axAction, elementId: "@e1", actionName: "AXOpen"),
            ActionStep(action: .axAction, elementId: "@e1", actionName: "AXPress"),
            ActionStep(action: .click, elementId: "@b1"),
            ActionStep(action: .type, text: "hi")
        ]
        let service = makeService()
        service.setGovernancePolicy(.confirmSensitive)
        for step in steps {
            let response = await service.handle(RPCRequest(method: .browserAct, browserAct: BrowserActParams(tabId: 1, steps: [step])))
            let blocked = response.error?.code == "POLICY_BLOCKED"
            XCTAssertEqual(ApprovalText.kind(of: step) != nil, blocked, "\(step.action.rawValue) \(step.modifiers ?? []) \(step.actionName ?? "")")
        }
    }

    func testClientsWaitLongerForMethodsThatCanBeHeld() {
        XCTAssertEqual(ApprovalTiming.clientAllowanceMs(for: .act), ApprovalTiming.clientAllowanceMs)
        XCTAssertEqual(ApprovalTiming.clientAllowanceMs(for: .browserAct), ApprovalTiming.clientAllowanceMs)
        XCTAssertEqual(ApprovalTiming.clientAllowanceMs(for: .browserExtract), ApprovalTiming.clientAllowanceMs)
        XCTAssertEqual(ApprovalTiming.clientAllowanceMs(for: .observe), 0)
        XCTAssertGreaterThan(ApprovalTiming.clientAllowanceMs, ApprovalTiming.timeoutRangeSeconds.upperBound * 1000)
        XCTAssertEqual(ApprovalTiming.clampedTimeoutSeconds(nil), 45)
        XCTAssertEqual(ApprovalTiming.clampedTimeoutSeconds(1), 5)
        XCTAssertEqual(ApprovalTiming.clampedTimeoutSeconds(600), 60)
        XCTAssertEqual(UseMacErrorGuide.hint(for: "APPROVAL_DENIED")?.isEmpty, false)
        XCTAssertEqual(UseMacErrorGuide.hint(for: "APPROVAL_TIMEOUT")?.isEmpty, false)
    }
}
