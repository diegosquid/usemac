import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

/// Per-task tab fallback, closed-tab bookkeeping and the task_complete summary (TaskTabRegistry.scope/record,
/// UseMacEngineService.handle, MCPTaskScope).
final class TaskScopeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func observe(tab: Int? = nil, task: String? = nil, profile: String? = nil) -> RPCRequest {
        RPCRequest(method: .browserObserve, browserObserve: BrowserObserveParams(profile: profile, tabId: tab), taskId: task)
    }

    private func act(tab: Int? = nil, task: String? = nil) -> RPCRequest {
        RPCRequest(method: .browserAct, browserAct: BrowserActParams(tabId: tab, steps: [ActionStep(action: .click)]), taskId: task)
    }

    // MARK: - Per-task last tab

    func testARequestWithoutTabGoesToItsOwnTasksLastTab() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(11, taskId: a, now: t0)
        registry.recordOpenedTab(22, taskId: b, now: t0)

        let forA = registry.scope(act(task: a), now: t0)
        XCTAssertEqual(forA.taskId, a)
        XCTAssertEqual(forA.filledTabId, 11)
        XCTAssertEqual(forA.request.browserAct?.tabId, 11)

        let forB = registry.scope(observe(task: b), now: t0)
        XCTAssertEqual(forB.request.browserObserve?.tabId, 22, "B's last tab, not the last tab any agent touched")
    }

    func testWithoutATaskTheRequestIsLeftAlone() {
        let registry = TaskTabRegistry()
        let none = registry.scope(observe(), now: t0)
        XCTAssertNil(none.taskId)
        XCTAssertNil(none.request.browserObserve?.tabId, "no task: the extension picks the tab as before")

        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        registry.recordOpenedTab(11, taskId: a, now: t0)
        let unresolved = registry.scope(observe(), now: t0)
        XCTAssertNil(unresolved.taskId, "two tasks and nothing named: no task")
        XCTAssertNil(unresolved.filledTabId)
    }

    func testTheOnlyRunningTaskGetsRequestsWithoutAnId() {
        let registry = TaskTabRegistry()
        let only = registry.start(now: t0)
        registry.recordOpenedTab(5, taskId: only, now: t0)
        XCTAssertEqual(registry.scope(observe(), now: t0).filledTabId, 5)
    }

    func testANamedTabIsKeptAndBecomesTheTasksLastTab() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        registry.recordOpenedTab(11, taskId: a, now: t0)

        let named = registry.scope(observe(tab: 42, task: a), now: t0)
        XCTAssertNil(named.filledTabId)
        XCTAssertEqual(named.request.browserObserve?.tabId, 42)
        registry.record(named, response: .success(id: "1", latencyMs: 1), now: t0)
        XCTAssertEqual(registry.lastTab(of: a), 42, "the user's tab the task worked in is now its last tab")
        XCTAssertFalse(registry.complete(taskId: a, tabId: nil, now: t0).ownTabIds?.contains(42) ?? true,
                       "naming a tab never makes it the task's own (it is never closed by the cleanup)")
    }

    func testAClosedTabHandsTheFallbackToThePreviousOne() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        registry.recordOpenedTab(2, taskId: a, now: t0)
        XCTAssertEqual(registry.lastTab(of: a), 2)
        registry.forgetTab(2)
        XCTAssertEqual(registry.lastTab(of: a), 1)
        XCTAssertFalse(registry.knowsTab(2))
        XCTAssertTrue(registry.knowsTab(1))
    }

    func testATabOfAnotherProfileIsNotFilledIn() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, profile: "Work", now: t0)
        XCTAssertNil(registry.scope(observe(task: a, profile: "Personal"), now: t0).filledTabId)
        let same = registry.scope(observe(task: a), now: t0)
        XCTAssertEqual(same.filledTabId, 1)
        XCTAssertEqual(same.request.browserObserve?.profile, "Work", "the tab's profile comes along")
    }

    func testOnlyRequestsThatWouldUseTheExtensionsLastTabAreFilledIn() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        let newTab = RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(url: "https://example.com"), taskId: a)
        XCTAssertNil(registry.scope(newTab, now: t0).filledTabId, "a new tab is a new tab")
        let sameTab = RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(url: "https://example.com", newTab: false), taskId: a)
        XCTAssertEqual(registry.scope(sameTab, now: t0).request.browserOpen?.tabId, 1)
        let downloads = RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "downloads"), taskId: a)
        XCTAssertNil(registry.scope(downloads, now: t0).filledTabId)
        let nativeVision = RPCRequest(method: .visionQuery, visionQuery: VisionQueryParams(app: "TextEdit"), taskId: a)
        XCTAssertNil(registry.scope(nativeVision, now: t0).filledTabId)
        let browserVision = RPCRequest(method: .visionQuery, visionQuery: VisionQueryParams(), taskId: a)
        XCTAssertEqual(registry.scope(browserVision, now: t0).request.visionQuery?.tabId, 1)
        let start = RPCRequest(method: .taskStart, taskStart: TaskStartParams(), taskId: a)
        XCTAssertNil(registry.scope(start, now: t0).taskId)
    }

    func testTheParamsTaskIdWinsOverTheEnvelopes() {
        let request = RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "https://example.com", taskId: "inner"),
            taskId: "outer"
        )
        XCTAssertEqual(request.namedTaskId, "inner")
        XCTAssertEqual(observe(task: "outer").namedTaskId, "outer")
    }

    func testTheEnvelopeTaskIdRoundTrips() throws {
        let data = try JSONEncoder().encode(observe(task: "task-1"))
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(decoded.taskId, "task-1")
        let legacy = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"method":"browser_observe"}"#.utf8))
        XCTAssertNil(legacy.taskId)
    }

    // MARK: - Summary

    func testTheSummaryCountsWhatTheTaskDid() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        let b = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        registry.recordOpenedTab(2, taskId: a, now: t0)
        registry.recordOpenedTab(3, taskId: a, now: t0)
        registry.forgetTab(1)

        let steps = [
            ActionStepResult(index: 0, action: .click, success: true, mechanism: "cdp", latencyMs: 1),
            ActionStepResult(index: 1, action: .type, success: false, mechanism: "cdp", latencyMs: 1, errorCode: "ELEMENT_NOT_FOUND")
        ]
        let acted = RPCResponse.success(
            id: "1", latencyMs: 1, actionResult: BatchActionResult(success: false, totalLatencyMs: 2, stepResults: steps)
        )
        registry.record(registry.scope(act(task: a), now: t0), response: acted, now: t0)
        registry.record(registry.scope(observe(task: a), now: t0), response: .failure(id: "2", code: "URL_BLOCKED", message: "no"), now: t0)
        registry.record(registry.scope(observe(task: a), now: t0), response: .success(id: "3", latencyMs: 1), now: t0)
        // B's work never shows up in A's summary.
        registry.record(registry.scope(act(task: b), now: t0), response: acted, now: t0)

        let done = registry.complete(taskId: a, tabId: nil, keepTabIds: [3], now: t0.addingTimeInterval(12.5))
        let summary = try? XCTUnwrap(done.summary)
        XCTAssertEqual(summary?.taskId, a)
        XCTAssertEqual(summary?.requests, 3)
        XCTAssertEqual(summary?.actions, 2)
        XCTAssertEqual(summary?.failedActions, 1)
        XCTAssertEqual(summary?.blocked, 1)
        XCTAssertEqual(summary?.tabsOpened, [1, 2, 3])
        XCTAssertEqual(summary?.tabsClosed, [1])
        XCTAssertEqual(summary?.tabsClosing, [2], "3 is kept, 1 is already closed")
        XCTAssertEqual(summary?.durationMs, 12_500)
    }

    func testKeepTabsMeansNothingIsClosing() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        registry.recordOpenedTab(1, taskId: a, now: t0)
        XCTAssertEqual(registry.complete(taskId: a, tabId: nil, keepTabs: true, now: t0).summary?.tabsClosing, [])
    }

    func testNoSummaryWhenItCannotTellWhichTaskFinished() {
        let registry = TaskTabRegistry()
        XCTAssertNil(registry.complete(taskId: nil, tabId: nil, now: t0).summary)
        _ = registry.start(now: t0)
        _ = registry.start(now: t0)
        XCTAssertNil(registry.complete(taskId: nil, tabId: nil, now: t0).summary)
    }

    func testRequestsKeepATaskAlive() {
        let registry = TaskTabRegistry()
        let a = registry.start(now: t0)
        _ = registry.start(now: t0)
        let later = t0.addingTimeInterval(TaskTabRegistry.idleExpiry - 60)
        _ = registry.scope(observe(task: a), now: later)
        let muchLater = t0.addingTimeInterval(TaskTabRegistry.idleExpiry + 60)
        XCTAssertEqual(registry.resolve(taskId: a, tabId: nil, now: muchLater), a, "A was used 2 minutes ago")
        XCTAssertEqual(registry.runningTaskCount, 1, "the idle task expired")
    }

    // MARK: - MCP connection scope

    func testMCPStampsItsOnlyOpenTask() {
        let scope = MCPTaskScope()
        var before = observe()
        scope.stamp(&before, explicitTaskId: nil, now: t0)
        XCTAssertNil(before.taskId, "no task started on this connection")

        let start = RPCRequest(method: .taskStart, taskStart: TaskStartParams())
        scope.record(start, response: .success(id: "s", latencyMs: 1, taskId: "task-a"), now: t0)
        var request = observe()
        scope.stamp(&request, explicitTaskId: nil, now: t0)
        XCTAssertEqual(request.taskId, "task-a")

        var explicit = observe()
        scope.stamp(&explicit, explicitTaskId: "task-z", now: t0)
        XCTAssertEqual(explicit.taskId, "task-z", "an explicit taskId argument wins")

        var newStart = start
        scope.stamp(&newStart, explicitTaskId: nil, now: t0)
        XCTAssertNil(newStart.taskId, "task_start always opens a new task")

        // A second open task on the same connection (subagents): stamp nothing rather than guess.
        scope.record(start, response: .success(id: "s2", latencyMs: 1, taskId: "task-b"), now: t0)
        var ambiguous = observe()
        scope.stamp(&ambiguous, explicitTaskId: nil, now: t0)
        XCTAssertNil(ambiguous.taskId)

        let complete = RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams())
        scope.record(complete, response: .success(id: "d", latencyMs: 1, taskId: "task-b"), now: t0)
        var afterDone = observe()
        scope.stamp(&afterDone, explicitTaskId: nil, now: t0)
        XCTAssertEqual(afterDone.taskId, "task-a")
    }

    func testMCPWindowAndTabToolsTakeATaskId() {
        let observeTool = MCPToolDefinition(name: "usemac_observe", description: "", inputSchema: ["type": "object", "properties": [:]])
        let props = MCPTaskScope.withTaskIdArgument(observeTool).inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(props?["taskId"])
        let statusTool = MCPToolDefinition(name: "usemac_status", description: "", inputSchema: ["type": "object", "properties": [:]])
        XCTAssertEqual(MCPTaskScope.withTaskIdArgument(statusTool), statusTool)
    }

    // MARK: - Engine, against a mock extension

    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [[String: Any]] = []
        private var closed: Set<Int> = []
        private var nextTab = 100

        func append(_ item: [String: Any]) { lock.lock(); sent.append(item); lock.unlock() }
        func requests(_ command: String) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return sent.filter { ($0["command"] as? String) == command }
        }
        func close(_ tabId: Int) { lock.lock(); closed.insert(tabId); lock.unlock() }
        func isClosed(_ tabId: Int?) -> Bool { lock.lock(); defer { lock.unlock() }; return tabId.map(closed.contains) ?? false }
        func openTab() -> Int { lock.lock(); defer { lock.unlock() }; nextTab += 1; return nextTab }
        var openTabs: [Int] {
            lock.lock(); defer { lock.unlock() }
            return nextTab > 100 ? (101...nextTab).filter { !closed.contains($0) } : []
        }
    }

    private func withEngine(_ body: (UseMacEngineService, Wire, URLSessionWebSocketTask) async throws -> Void) async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-scope-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }
        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let ws = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Scope", tabCount: 1)
        defer { ws.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "Scope" }
        XCTAssertTrue(ready)

        let wire = Wire()
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: ws) else { break }
                wire.append(obj)
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                var resp: [String: Any] = ["type": "response", "id": id, "ok": true, "profileName": "Scope"]
                let tabId = obj["tabId"] as? Int
                if wire.isClosed(tabId) {
                    resp["ok"] = false
                    resp["error"] = ["code": "EXTENSION_ERROR", "message": "No tab with id: \(tabId ?? 0)."]
                } else {
                    switch command {
                    case "open":
                        resp["tabId"] = tabId ?? wire.openTab()
                        resp["url"] = obj["url"] as? String ?? ""
                        resp["title"] = "Page"
                    case "extract":
                        resp["tabId"] = tabId ?? 1
                        resp["extractResult"] = ["mode": "text", "latencyMs": 1.0, "text": "hello"]
                    case "act":
                        resp["tabId"] = tabId ?? 1
                    case "tabs":
                        resp["tabs"] = wire.openTabs.map { ["tabId": $0, "title": "t", "url": "https://x.test/", "active": false] }
                    default:
                        resp["tabId"] = tabId ?? 1
                    }
                }
                try? await sendBridgeJSON(resp, on: ws)
            }
        }
        defer { responder.cancel() }
        try await body(service, wire, ws)
    }

    private func startTask(_ engine: UseMacEngineService) async throws -> String {
        let response = await engine.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams()))
        return try XCTUnwrap(response.taskId)
    }

    private func openTab(_ engine: UseMacEngineService, task: String) async throws -> Int {
        let response = await engine.handle(open(task: task))
        return try XCTUnwrap(response.browserTabId, "\(String(describing: response.error))")
    }

    private func read(task: String?) -> RPCRequest {
        RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "text"), taskId: task)
    }

    private func open(task: String?) -> RPCRequest {
        RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(url: "http://127.0.0.1:9/", stream: false), taskId: task)
    }

    func testTwoTasksEachActInTheirOwnTabWithoutNamingIt() async throws {
        try await withEngine { engine, wire, _ in
            let a = try await startTask(engine)
            let b = try await startTask(engine)
            let tabA = try await openTab(engine, task: a)
            let tabB = try await openTab(engine, task: b)

            let readA = await engine.handle(read(task: a))
            XCTAssertTrue(readA.ok, "\(String(describing: readA.error))")
            XCTAssertEqual(wire.requests("extract").last?["tabId"] as? Int, tabA, "A's request goes to A's tab")
            _ = await engine.handle(RPCRequest(
                method: .browserAct,
                browserAct: BrowserActParams(steps: [ActionStep(action: .scroll)]),
                taskId: b
            ))
            XCTAssertEqual(wire.requests("act").last?["tabId"] as? Int, tabB, "B's request goes to B's tab")

            _ = await engine.handle(read(task: nil))
            XCTAssertNil(wire.requests("extract").last?["tabId"], "a request of no task is sent as before")

            let done = await engine.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(keepTabs: true), taskId: a))
            XCTAssertEqual(done.taskId, a)
            XCTAssertEqual(done.taskSummary?.requests, 2, "browser_open and the read")
            XCTAssertEqual(done.taskSummary?.tabsOpened, [tabA])
            XCTAssertEqual(done.taskSummary?.tabsClosing, [], "keepTabs")
        }
    }

    func testAReadRetriesWhenTheTasksLastTabClosedUnnoticed() async throws {
        try await withEngine { engine, wire, _ in
            let a = try await startTask(engine)
            _ = await engine.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams()))
            let first = try await openTab(engine, task: a)
            let second = try await openTab(engine, task: a)
            wire.close(second)

            let readResp = await engine.handle(read(task: a))
            XCTAssertTrue(readResp.ok, "the read ran again on the task's previous tab: \(String(describing: readResp.error))")
            XCTAssertEqual(wire.requests("extract").map { $0["tabId"] as? Int }, [second, first])

            wire.close(first)
            let actResp = await engine.handle(RPCRequest(
                method: .browserAct,
                browserAct: BrowserActParams(steps: [ActionStep(action: .click)]),
                taskId: a
            ))
            XCTAssertEqual(actResp.error?.code, "NO_USEMAC_TAB", "an action never moves to another tab on its own")
            XCTAssertEqual(wire.requests("act").count, 1)

            let done = await engine.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(), taskId: a))
            XCTAssertEqual(done.taskSummary?.tabsClosed, [second, first])
            XCTAssertEqual(done.taskSummary?.tabsClosing, [])
        }
    }

    func testAClosedSignalFromTheExtensionForgetsTheTab() async throws {
        try await withEngine { engine, wire, ws in
            let a = try await startTask(engine)
            let first = try await openTab(engine, task: a)
            let second = try await openTab(engine, task: a)

            try await sendBridgeJSON(["type": "stream_stopped", "tabId": second, "reason": "closed"], on: ws)
            let forgotten = await waitForBridgeCondition { engine.taskTabs.lastTab(of: a) == first }
            XCTAssertTrue(forgotten, "a closed tab is forgotten at once")

            // An old extension says nothing about why: UseMac asks Chrome whether the tab is still open.
            try await sendBridgeJSON(["type": "stream_stopped", "tabId": first], on: ws)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(engine.taskTabs.lastTab(of: a), first, "still open, so still the task's tab")
            wire.close(first)
            try await sendBridgeJSON(["type": "stream_stopped", "tabId": first], on: ws)
            let gone = await waitForBridgeCondition { engine.taskTabs.lastTab(of: a) == nil }
            XCTAssertTrue(gone)
        }
    }
}
