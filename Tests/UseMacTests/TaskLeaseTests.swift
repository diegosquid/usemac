import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

/// Window and tab leases (TARGET_BUSY) and agent names on preview cards.
final class TaskLeaseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private typealias Lease = TaskTabRegistry.WindowLease

    private func typing(task: String?) -> RPCRequest {
        RPCRequest(method: .act, act: BatchActionRequest(app: "TextEdit", steps: [ActionStep(action: .type, text: "hi")]), taskId: task)
    }

    private func scope(_ registry: TaskTabRegistry, _ request: RPCRequest) -> TaskTabRegistry.Scope {
        registry.scope(request, now: t0)
    }

    private let untitled = Lease(pid: 10, windowId: 1, label: "TextEdit window \"Untitled\"")

    func testAWindowAnotherTaskActsInIsBusyUntilItFinishes() {
        let registry = TaskTabRegistry()
        let a = registry.start(agent: "A", now: t0)
        let b = registry.start(agent: "B", now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0))

        let busy = registry.claim(registry.scope(typing(task: b), now: t0), windows: [untitled], tabs: [], now: t0.addingTimeInterval(12))
        XCTAssertEqual(busy?.taskId, a)
        XCTAssertEqual(busy?.agent, "A")
        XCTAssertEqual(busy?.target, "TextEdit window \"Untitled\"")
        XCTAssertEqual(busy?.idleSeconds, 12)
        XCTAssertNil(registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0), "the holder keeps working")

        _ = registry.complete(taskId: a, tabId: nil, now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: b)), windows: [untitled], tabs: [], now: t0), "free once A is done")
    }

    func testOtherWindowsOfTheSameAppAreFreeButAnUnknownWindowCoversTheApp() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        _ = registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: b)), windows: [Lease(pid: 10, windowId: 2, label: "w2")], tabs: [], now: t0))
        XCTAssertNotNil(registry.claim(scope(registry, typing(task: b)), windows: [Lease(pid: 10, windowId: nil, label: "TextEdit window")], tabs: [], now: t0))
        XCTAssertNil(registry.claim(scope(registry, typing(task: b)), windows: [Lease(pid: 11, windowId: 1, label: "other app")], tabs: [], now: t0))
    }

    func testRequestsOfNoTaskAreNeverRefused() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        _ = registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: nil)), windows: [untitled], tabs: [], now: t0),
                     "two tasks and no taskId: a legacy caller, never refused")
        _ = registry.complete(taskId: a, tabId: nil, now: t0)
        // The legacy request leased nothing, so no one is blocked by it.
        let c = registry.start(now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: c)), windows: [untitled], tabs: [], now: t0))
    }

    func testWithOneTaskRunningARequestWithoutAnIdIsThatTasks() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: nil)), windows: [untitled], tabs: [], now: t0))
    }

    func testAFinishedTasksIdIsRefusedButLeasesNothing() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0)
        XCTAssertEqual(registry.claim(scope(registry, typing(task: "task-gone")), windows: [untitled], tabs: [], now: t0)?.taskId, a)
        XCTAssertNil(registry.claim(scope(registry, typing(task: "task-gone")), windows: [Lease(pid: 12, windowId: 3, label: "x")], tabs: [], now: t0))
        let b = registry.start(now: t0)
        XCTAssertNil(registry.claim(scope(registry, typing(task: b)), windows: [Lease(pid: 12, windowId: 3, label: "x")], tabs: [], now: t0),
                     "the stale id did not lease that window")
    }

    func testLeasesEndWithTheTasksIdleExpiry() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.claim(scope(registry, typing(task: a)), windows: [untitled], tabs: [], now: t0)
        let later = t0.addingTimeInterval(TaskTabRegistry.idleExpiry + 1)
        let b = registry.start(now: later)
        XCTAssertNil(registry.claim(registry.scope(typing(task: b), now: later), windows: [untitled], tabs: [], now: later))
    }

    func testATabAnotherTaskOwnsOrActsInIsBusy() {
        let registry = TaskTabRegistry()
        let a = registry.start(agent: "A", now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(5, taskId: a, now: t0)
        let click = { (task: String?, tab: Int) in
            RPCRequest(method: .browserAct, browserAct: BrowserActParams(tabId: tab, steps: [ActionStep(action: .click)]), taskId: task)
        }
        XCTAssertEqual(registry.claim(scope(registry, click(b, 5)), windows: [], tabs: [5], now: t0)?.target, "Chrome tab 5")
        // A works in the user's tab 42: B can't act there either, and B's cleanup keeps it open.
        XCTAssertNil(registry.claim(scope(registry, click(a, 42)), windows: [], tabs: [42], now: t0))
        XCTAssertEqual(registry.claim(scope(registry, click(b, 42)), windows: [], tabs: [42], now: t0)?.taskId, a)
        XCTAssertTrue(registry.protectedTabIds(now: t0).isSuperset(of: [5, 42]))
        XCTAssertEqual(registry.complete(taskId: a, tabId: nil, now: t0).ownTabIds, [5], "a tab A only acted in is not A's to close")
    }

    func testTheAgentNameReachesTheSummary() {
        let registry = TaskTabRegistry()
        let a = registry.start(agent: "  Claude Code ", now: t0)
        XCTAssertEqual(registry.agent(of: a), "Claude Code")
        XCTAssertEqual(registry.complete(taskId: a, tabId: nil, now: t0).summary?.agent, "Claude Code")
        XCTAssertNil(registry.agent(of: nil))
    }

    func testOnlyRequestsThatChangeATargetTakeALease() {
        XCTAssertTrue(typing(task: nil).actsOnTarget)
        let waits = RPCRequest(method: .act, act: BatchActionRequest(steps: [ActionStep(action: .wait), ActionStep(action: .waitFor)]))
        XCTAssertFalse(waits.actsOnTarget)
        XCTAssertFalse(RPCRequest(method: .observe, observe: ObserveParams(app: "TextEdit")).actsOnTarget)
        XCTAssertFalse(RPCRequest(method: .screenshot, screenshot: ScreenshotRequest(app: "TextEdit")).actsOnTarget)
        XCTAssertTrue(RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(url: "https://x.test", tabId: 3)).actsOnTarget)
        XCTAssertFalse(RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(url: "https://x.test")).actsOnTarget)
        XCTAssertTrue(RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "eval", expression: "1")).actsOnTarget)
        XCTAssertFalse(RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "text")).actsOnTarget)
    }

    func testTargetBusyIsCountedAsBlocked() {
        XCTAssertTrue(TaskTabRegistry.isBlockedCode("TARGET_BUSY"))
    }

    // MARK: - MCP client name

    private final class LastRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: RPCRequest?
        var value: RPCRequest? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    func testTheMCPClientNameIsTheDefaultAgent() async throws {
        let last = LastRequest()
        let stub = StubService { request in
            last.value = request
            return .success(id: request.id, latencyMs: 0.1, taskId: "task-x")
        }
        let mcp = MCPStdioServer(socketPath: "/tmp/usemac-lease-\(UUID().uuidString.prefix(8)).sock", fallbackService: stub)
        defer { mcp.close() }
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"Claude Code","version":"2"}}}"#)
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"usemac_task_start","arguments":{}}}"#)
        XCTAssertEqual(last.value?.taskStart?.agent, "Claude Code")
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"usemac_task_start","arguments":{"agent":"reviewer"}}}"#)
        XCTAssertEqual(last.value?.taskStart?.agent, "reviewer")
    }

    // MARK: - Engine, against a mock extension

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LiveActivityItem] = []
        private var commands: [String] = []
        func append(_ item: LiveActivityItem) { lock.lock(); items.append(item); lock.unlock() }
        func append(command: String) { lock.lock(); commands.append(command); lock.unlock() }
        var allItems: [LiveActivityItem] { lock.lock(); defer { lock.unlock() }; return items }
        func count(_ command: String) -> Int { lock.lock(); defer { lock.unlock() }; return commands.filter { $0 == command }.count }
    }

    private func startTask(_ engine: UseMacEngineService, agent: String) async throws -> String {
        let response = await engine.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(agent: agent)))
        return try XCTUnwrap(response.taskId)
    }

    func testAnotherTasksBrowserActionIsRefusedAndItsReadsAreNot() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let engine = UseMacEngineService(
            socketPath: "/tmp/usemac-lease-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        let recorder = Recorder()
        engine.onLiveActivity = { recorder.append($0) }
        engine.chromeBridge.start()
        defer { engine.chromeBridge.stop() }
        let port = await waitForListeningPort(of: engine.chromeBridge)
        let key = try XCTUnwrap(engine.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let ws = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Lease", tabCount: 1)
        defer { ws.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { engine.chromeBridge.connectedProfiles().first?.profileName == "Lease" }
        XCTAssertTrue(ready)

        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: ws) else { break }
                // The site rules (#12) look the tab up before a tab command; answer it so it isn't refused.
                if await answerTabsLookup(obj, on: ws, profileName: "Lease") { continue }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                recorder.append(command: command)
                var resp: [String: Any] = [
                    "type": "response", "id": id, "ok": true, "profileName": "Lease", "tabId": obj["tabId"] as? Int ?? 300
                ]
                if command == "extract" {
                    resp["extractResult"] = ["mode": "text", "latencyMs": 1.0, "text": "hello"]
                }
                try? await sendBridgeJSON(resp, on: ws)
            }
        }
        defer { responder.cancel() }

        let a = try await startTask(engine, agent: "A")
        let b = try await startTask(engine, agent: "B")
        let opened = await engine.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "http://127.0.0.1:9/", stream: false),
            taskId: a
        ))
        let tabA = try XCTUnwrap(opened.browserTabId)
        XCTAssertTrue(recorder.allItems.contains { $0.agentName == "A" && $0.browserTabId == tabA }, "A's card is labeled A")

        let clickByB = RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(tabId: tabA, steps: [ActionStep(action: .click)]),
            taskId: b
        )
        let refused = await engine.handle(clickByB)
        XCTAssertEqual(refused.error?.code, "TARGET_BUSY")
        XCTAssertTrue(refused.error?.message.contains("A (\(a))") ?? false, refused.error?.message ?? "")
        XCTAssertEqual(recorder.count("act"), 0, "nothing reached the tab")
        XCTAssertTrue(recorder.allItems.contains { $0.agentName == "B" && $0.kind == .policyOrSafety })

        let readByB = await engine.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(tabId: tabA, mode: "text"),
            taskId: b
        ))
        XCTAssertTrue(readByB.ok, "reads never wait: \(String(describing: readByB.error))")

        _ = await engine.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(keepTabs: true), taskId: a))
        let retried = await engine.handle(clickByB)
        XCTAssertTrue(retried.ok, "free once A is done: \(String(describing: retried.error))")
        XCTAssertEqual(recorder.count("act"), 1)

        let doneB = await engine.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(keepTabs: true), taskId: b))
        XCTAssertEqual(doneB.taskSummary?.blocked, 1)
        XCTAssertEqual(doneB.taskSummary?.agent, "B")
    }
}
