import Darwin
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

final class AgentIdentityTests: XCTestCase {
    func testKnownAgentsFromExecutableBundleAndScriptPaths() {
        let cases: [(PeerProcessInfo, String)] = [
            (process("/usr/local/bin/Claude"), "Claude Code"),
            (process("/Applications/Claude.app/Contents/MacOS/Claude"), "Claude"),
            (process("/usr/bin/node", arguments: ["node", "--no-warnings", "/opt/@anthropic-ai/claude-code/cli.js"]), "Claude Code"),
            (process("/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper"), "Codex"),
            (process("/Applications/Antigravity.app/Contents/MacOS/Electron"), "Antigravity"),
            (process("/Applications/Cursor.app/Contents/MacOS/Cursor"), "Cursor"),
            (process("/Applications/T3 Code.app/Contents/MacOS/Electron"), "T3 Code"),
            (process("/usr/bin/node", arguments: ["node", "/usr/local/bin/openclaw.mjs"]), "OpenClaw"),
            (process("/Applications/Windsurf.app/Contents/MacOS/Electron"), "Windsurf"),
            (process("/usr/local/bin/opencode"), "OpenCode"),
            (process("/usr/local/bin/goose"), "Goose"),
            (process("/usr/bin/python3", arguments: ["python3", "-m", "aider"]), "Aider"),
            (process("/opt/extensions/cline/bin/agent"), "Cline"),
            (process("/opt/extensions/roocode/bin/agent"), "Roo Code"),
            (process("/Applications/Zed.app/Contents/MacOS/zed"), "Zed"),
            (process("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"), "ChatGPT")
        ]
        for (peer, expected) in cases {
            XCTAssertEqual(PeerProcessIdentifier.classify(chain: [peer]), expected, peer.executablePath)
        }
    }

    func testKnownAgentWinsOverWrappersAndTerminal() {
        let chain = [
            process("/usr/local/bin/usemac", arguments: ["usemac", "--summary", "cursor"]),
            process("/bin/zsh", arguments: ["-zsh"]),
            process("/Applications/Ghostty.app/Contents/MacOS/Ghostty"),
            process("/usr/local/bin/codex")
        ]
        XCTAssertEqual(PeerProcessIdentifier.classify(chain: chain), "Codex")
        XCTAssertEqual(PeerProcessIdentifier.classify(chain: Array(chain.dropLast())), "Ghostty")
        XCTAssertEqual(PeerProcessIdentifier.classify(chain: [process("/Applications/Code.app/Contents/MacOS/Electron")]), "VS Code")
    }

    func testUnknownBundleAndExecutableFallbacksIgnorePayloadArguments() {
        let helper = process("/usr/local/bin/OpenWorkspace", arguments: ["OpenWorkspace", "--message", "/tmp/codex/memo"])
        let directory = process("/Applications/Notes Helper.app/Contents/MacOS/Helper")
        XCTAssertEqual(PeerProcessIdentifier.classify(chain: [helper, directory]), "Notes Helper")
        XCTAssertEqual(PeerProcessIdentifier.classify(chain: [process("/usr/bin/env"), helper]), "OpenWorkspace")
        let name = String(repeating: "É", count: 41)
        XCTAssertEqual(PeerProcessIdentifier.classify(chain: [process("/app/helper", bundle: "  \(name)  ")]), String(name.prefix(40)))
        XCTAssertNil(PeerProcessIdentifier.classify(chain: [
            process("/Applications/UseMac.app/Contents/MacOS/UseMac"),
            process("/usr/bin/ignored", bundle: " UseMac.app "),
            process("/bin/zsh", arguments: ["zsh", "-c", "/tmp/codex"]),
            process("/sbin/launchd")
        ]))
    }

    func testRPCRequestAgentIsOptionalAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"method":"ping"}"#.utf8))
        XCTAssertNil(legacy.agent)
        let encoded = try JSONEncoder().encode(RPCRequest(method: .ping, agent: "Reviewer"))
        XCTAssertEqual(try JSONDecoder().decode(RPCRequest.self, from: encoded).agent, "Reviewer")
    }

    func testSocketStampsActualPeerWithoutOverwritingExplicitAgent() throws {
        let expectedAgent = try XCTUnwrap(PeerProcessIdentifier.resolveAgentName(forPID: getpid()))
        XCTAssertNil(PeerProcessIdentifier.peerPID(forSocketFd: -1))
        let path = socketPath()
        let service = StubService { request in
            .success(id: request.id, latencyMs: 0, taskId: request.agent)
        }
        let server = UnixSocketServer(socketPath: path, service: service)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketClient(socketPath: path, timeoutMs: 5000, keepAlive: true)
        defer { client.close() }

        XCTAssertEqual(try client.send(RPCRequest(method: .ping)).0.taskId, expectedAgent)
        XCTAssertEqual(try client.send(RPCRequest(method: .ping, agent: " \n")).0.taskId, expectedAgent)
        XCTAssertEqual(try client.send(RPCRequest(method: .ping, agent: "Explicit reviewer")).0.taskId, "Explicit reviewer")
    }

    func testMCPStampsClientWithoutATaskAndPreservesExplicitTaskAgent() async {
        let requests = Recorder<RPCRequest>()
        let stub = StubService { request in
            requests.append(request)
            return .success(id: request.id, latencyMs: 0)
        }
        let mcp = MCPStdioServer(socketPath: socketPath(), fallbackService: stub)
        defer { mcp.close() }
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"My MCP Client","version":"1"}}}"#)
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"usemac_session","arguments":{"action":"status"}}}"#)
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"usemac_session","arguments":{"action":"task_start","agent":"Named reviewer"}}}"#)
        _ = await mcp.processLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"usemac_observe","arguments":{"taskStart":{"summary":"Read page"}}}}"#)

        let seen = requests.values
        XCTAssertEqual(seen.map(\.agent), ["My MCP Client", "My MCP Client", "My MCP Client"])
        XCTAssertEqual(seen.map { $0.taskStart?.agent }, [nil, "Named reviewer", "My MCP Client"])

        let scope = MCPTaskScope()
        scope.clientName = "My MCP Client"
        var explicit = RPCRequest(method: .ping, agent: "Explicit reviewer")
        scope.stamp(&explicit, explicitTaskId: nil)
        XCTAssertEqual(explicit.agent, "Explicit reviewer")
    }

    func testActiveAgentsAreDistinctRecentAndStillRunning() {
        let registry = TaskTabRegistry()
        let now = Date()
        registry.start(agent: "Old", now: now.addingTimeInterval(-61))
        registry.start(agent: "Codex", now: now.addingTimeInterval(-45))
        let claude = registry.start(agent: "  Claude Code  ", now: now.addingTimeInterval(-30))
        registry.start(agent: "Codex", now: now.addingTimeInterval(-15))
        registry.start(now: now)

        XCTAssertEqual(registry.activeAgentNames(activeWithin: 60, now: now), ["Codex", "Claude Code"])
        _ = registry.scope(RPCRequest(method: .ping, taskId: claude), now: now)
        XCTAssertEqual(registry.activeAgentNames(activeWithin: 60, now: now), ["Claude Code", "Codex"])
        _ = registry.complete(taskId: claude, tabId: nil, now: now)
        XCTAssertEqual(registry.activeAgentNames(activeWithin: 60, now: now), ["Codex"])
    }

    func testStandaloneAndInlineLifecyclesCarryAgentInHistoryAndPreview() async throws {
        let engine = makeEngine()
        let live = Recorder<LiveActivityItem>()
        engine.onLiveActivity = { live.append($0) }

        let start = await engine.handle(RPCRequest(method: .taskStart, agent: "  Codex  "))
        let taskId = try XCTUnwrap(start.taskId)
        XCTAssertEqual(engine.activeAgentNames(), ["Codex"])
        _ = await engine.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(keepTabs: true, taskId: taskId)))
        XCTAssertTrue(engine.activeAgentNames().isEmpty)

        let inline = await engine.handle(RPCRequest(
            method: .observe,
            observe: ObserveParams(app: "NoSuchApp-\(UUID())"),
            taskStart: TaskStartParams(agent: "Named task agent"),
            taskComplete: TaskCompleteParams(keepTabs: true),
            agent: "Client agent"
        ))
        let inlineTaskId = try XCTUnwrap(inline.taskId)
        XCTAssertEqual(inline.taskSummary?.agent, "Named task agent")

        let entries = engine.recentAuditEntries()
        XCTAssertEqual(entries.filter { $0.taskId == taskId }.map(\.agent), ["Codex", "Codex"])
        XCTAssertEqual(entries.filter { $0.taskId == inlineTaskId }.map(\.agent), Array(repeating: "Named task agent", count: 3))
        let lifecycle = live.values.filter { $0.kind == .taskStart || $0.kind == .taskComplete }
        XCTAssertEqual(lifecycle.map(\.agentName), ["Codex", "Codex", "Named task agent", "Named task agent"])
        let query = AuditLogQuery(AuditLogParams(agent: "  Codex  "))
        XCTAssertEqual(query.apply(to: entries).map(\.method), ["task_complete", "task_start"])
    }

    func testExplicitTaskAgentWinsOverClientOnLaterRequests() async throws {
        let engine = makeEngine()
        let live = Recorder<LiveActivityItem>()
        engine.onLiveActivity = { live.append($0) }

        let start = await engine.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(agent: "Named reviewer")))
        let taskId = try XCTUnwrap(start.taskId)
        let response = await engine.handle(RPCRequest(
            method: .observe,
            observe: ObserveParams(app: "NoSuchApp-\(UUID())"),
            taskId: taskId,
            agent: "My MCP Client"
        ))
        XCTAssertEqual(response.error?.code, "APP_NOT_FOUND")

        let entry = try XCTUnwrap(engine.recentAuditEntries().first { $0.method == RPCMethod.observe.rawValue && $0.taskId == taskId })
        let activity = try XCTUnwrap(live.values.first { $0.kind == .observe && $0.taskId == taskId })
        XCTAssertEqual(entry.agent, "Named reviewer")
        XCTAssertEqual(activity.agentName, "Named reviewer")
    }

    func testRequestWithoutTaskCarriesAgentToApprovalActivityAndAudit() async throws {
        let engine = makeEngine()
        let live = Recorder<LiveActivityItem>()
        engine.onLiveActivity = { live.append($0) }
        engine.setGovernancePolicy(.ask)
        engine.approvals.timeoutInterval = 2

        async let response = engine.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(tabId: 41, mode: "eval", expression: "document.title"),
            agent: "  Claude Code  "
        ))
        let prompt = try await waitForPrompt(engine.approvals)
        XCTAssertNil(prompt.taskId)
        XCTAssertEqual(prompt.agentName, "Claude Code")
        let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)
        XCTAssertTrue(engine.approvals.decide(promptId: prompt.id, decision: .deny, click: click))
        let denied = await response
        XCTAssertEqual(denied.error?.code, "APPROVAL_DENIED")
        XCTAssertEqual(engine.recentAuditEntries().first?.agent, "Claude Code")
        XCTAssertEqual(live.values.filter { $0.mechanism == "approval" }.map(\.agentName), ["Claude Code", "Claude Code"])
    }

    private func process(_ path: String, arguments: [String] = [], bundle: String? = nil) -> PeerProcessInfo {
        PeerProcessInfo(pid: 10, ppid: 1, executablePath: path, arguments: arguments, appBundleName: bundle)
    }

    private func socketPath() -> String {
        "/tmp/usemac-agent-\(UUID().uuidString.prefix(8)).sock"
    }

    private func makeEngine() -> UseMacEngineService {
        UseMacEngineService(socketPath: socketPath(), extensionPort: 0)
    }

    private func waitForPrompt(_ broker: ApprovalBroker) async throws -> ApprovalPrompt {
        for _ in 0..<100 {
            if let prompt = broker.currentPrompt { return prompt }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(broker.currentPrompt)
    }

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []

        func append(_ value: Value) {
            lock.lock(); defer { lock.unlock() }
            storage.append(value)
        }

        var values: [Value] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
