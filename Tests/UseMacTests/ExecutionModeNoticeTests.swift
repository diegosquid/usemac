import Darwin
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

/// What the menu bar shows for each mode, and what agents are told when the mode, a pause or the Emergency stop
/// refuses them (#61).
final class ExecutionModeNoticeTests: XCTestCase {
    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-notice-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    private func clickRequest() -> RPCRequest {
        RPCRequest(method: .act, act: BatchActionRequest(
            app: "no-such-app-\(UUID().uuidString)",
            steps: [ActionStep(action: .click, elementId: "e1")],
            returnObservation: false
        ))
    }

    private final class ActivityCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LiveActivityItem] = []
        func append(_ item: LiveActivityItem) { lock.lock(); items.append(item); lock.unlock() }
        var failures: [LiveActivityItem] { lock.lock(); defer { lock.unlock() }; return items.filter { !$0.success } }
    }

    // MARK: - Menu bar

    func testOnlyReadOnlyPausedAndTheEmergencyStopBadgeTheIcon() {
        XCTAssertEqual(ExecutionModeNotice.badge(policy: .autonomous, killSwitchTripped: false), .none)
        XCTAssertEqual(ExecutionModeNotice.badge(policy: .ask, killSwitchTripped: false), .none)
        XCTAssertEqual(ExecutionModeNotice.badge(policy: .confirmSensitive, killSwitchTripped: false), .none)
        XCTAssertEqual(ExecutionModeNotice.badge(policy: .readOnly, killSwitchTripped: false), .readOnly)
        XCTAssertEqual(ExecutionModeNotice.badge(policy: .paused, killSwitchTripped: false), .paused)
        for policy in GovernancePolicy.allCases {
            XCTAssertEqual(ExecutionModeNotice.badge(policy: policy, killSwitchTripped: true), .paused, "\(policy)")
        }
    }

    func testEveryModeButAutonomousGetsAMenuLine() {
        XCTAssertNil(ExecutionModeNotice.menuTitle(policy: .autonomous))
        XCTAssertNil(ExecutionModeNotice.menuSubtitle(policy: .autonomous))
        XCTAssertEqual(ExecutionModeNotice.menuTitle(policy: .readOnly), "Mode: Read-only")
        XCTAssertEqual(ExecutionModeNotice.menuTitle(policy: .confirmSensitive), "Mode: Block sensitive")
        XCTAssertEqual(ExecutionModeNotice.menuTitle(policy: .ask), "Mode: Ask")
        XCTAssertEqual(ExecutionModeNotice.menuTitle(policy: .paused), "Mode: Paused")
        for policy in GovernancePolicy.allCases where policy != .autonomous {
            XCTAssertEqual(ExecutionModeNotice.menuSubtitle(policy: policy)?.isEmpty, false, "\(policy)")
        }
    }

    func testNamesMatchSettings() {
        let names = GovernancePolicy.allCases.map { ExecutionModeNotice.name(of: $0) }
        XCTAssertEqual(Set(names), ["Autonomous", "Ask", "Block sensitive", "Read-only", "Paused"])
    }

    func testTooltipNamesTheModeOrTheStop() {
        XCTAssertEqual(ExecutionModeNotice.tooltip(policy: .autonomous, killSwitchTripped: false, agentActing: false), "UseMac (Running)")
        XCTAssertEqual(ExecutionModeNotice.tooltip(policy: .autonomous, killSwitchTripped: false, agentActing: true), "UseMac (Agent acting)")
        XCTAssertEqual(ExecutionModeNotice.tooltip(policy: .readOnly, killSwitchTripped: false, agentActing: false), "UseMac (Mode: Read-only)")
        XCTAssertEqual(ExecutionModeNotice.tooltip(policy: .ask, killSwitchTripped: false, agentActing: true), "UseMac (Agent acting, mode: Ask)")
        XCTAssertEqual(ExecutionModeNotice.tooltip(policy: .paused, killSwitchTripped: false, agentActing: false), "UseMac (Paused)")
        XCTAssertTrue(ExecutionModeNotice.tooltip(policy: .readOnly, killSwitchTripped: true, agentActing: false).contains("emergency stop"))
    }

    // MARK: - Hints

    func testAHintExactlyWhenSomethingBlocksAgents() {
        XCTAssertNil(ExecutionModeNotice.agentHint(policy: .autonomous, killSwitchTripped: false))
        XCTAssertNil(ExecutionModeNotice.agentHint(policy: .ask, killSwitchTripped: false))
        XCTAssertNil(ExecutionModeNotice.activityReason(policy: .autonomous, killSwitchTripped: false))
        XCTAssertNil(ExecutionModeNotice.activityReason(policy: .ask, killSwitchTripped: false))

        let namedAs: [GovernancePolicy: String] = [.confirmSensitive: "Block sensitive", .readOnly: "Read-only", .paused: "paused"]
        for (policy, words) in namedAs {
            let hint = ExecutionModeNotice.agentHint(policy: policy, killSwitchTripped: false) ?? ""
            XCTAssertTrue(hint.contains(words), "\(policy): \(hint)")
            XCTAssertTrue(hint.contains("Settings → Safety"), "\(policy): \(hint)")
            XCTAssertTrue(hint.contains("Agents can't") || hint.contains("agents can't"), "\(policy): \(hint)")
            XCTAssertNotNil(ExecutionModeNotice.activityReason(policy: policy, killSwitchTripped: false))
        }
        for policy in GovernancePolicy.allCases {
            let hint = ExecutionModeNotice.agentHint(policy: policy, killSwitchTripped: true)
            XCTAssertTrue(hint?.contains("emergency stop") == true, "\(policy)")
            XCTAssertTrue(hint?.contains("Resume Agents") == true, "\(policy)")
        }
    }

    // MARK: - Refusals carry the hint

    func testReadOnlyRefusalNamesTheModeAndWhereToChangeIt() async {
        let service = makeService()
        let collector = ActivityCollector()
        service.onLiveActivity = { collector.append($0) }
        service.setGovernancePolicy(.readOnly)

        let response = await service.handle(clickRequest())
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED")
        XCTAssertTrue(response.error?.message.contains("Read-only mode") == true, response.error?.message ?? "")
        XCTAssertEqual(response.error?.hint, ExecutionModeNotice.agentHint(policy: .readOnly, killSwitchTripped: false))
        XCTAssertTrue(response.error?.hint?.contains("Settings → Safety") == true)
        // The live preview's caption says why, in plain words.
        XCTAssertEqual(collector.failures.last?.subtitle, "Read-only mode is on")
    }

    func testPauseAndEmergencyStopRefusalsSayHowToResume() async {
        let service = makeService()
        service.setGovernancePolicy(.paused)
        let paused = await service.handle(RPCRequest(method: .listApps))
        XCTAssertEqual(paused.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(paused.error?.hint, ExecutionModeNotice.agentHint(policy: .paused, killSwitchTripped: false))

        let stopped = makeService()
        stopped.tripKillSwitch(true)
        let observe = await stopped.handle(RPCRequest(method: .observe, observe: ObserveParams(app: "Finder")))
        XCTAssertEqual(observe.error?.code, "POLICY_BLOCKED")
        XCTAssertTrue(observe.error?.message.contains("emergency stop") == true, observe.error?.message ?? "")
        XCTAssertTrue(observe.error?.hint?.contains("Resume Agents") == true, observe.error?.hint ?? "")
    }

    func testBlockSensitiveRefusalNamesTheMode() async {
        let service = makeService()
        service.setGovernancePolicy(.confirmSensitive)
        let response = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(tabId: 1, steps: [ActionStep(action: .pressKey, key: "q", modifiers: ["cmd"])])
        ))
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED")
        XCTAssertTrue(response.error?.hint?.contains("Block sensitive") == true, response.error?.hint ?? "")
    }

    func testTheAgentsOwnReadOnlyFlagDoesNotBlameTheUsersMode() async {
        let service = makeService()
        let collector = ActivityCollector()
        service.onLiveActivity = { collector.append($0) }
        service.setGovernancePolicy(.confirmSensitive)
        let response = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(tabId: 1, steps: [ActionStep(action: .click, elementId: "b1")], readOnly: true)
        ))
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(response.error?.hint, ExecutionModeNotice.readOnlyRequestedHint)
        XCTAssertTrue(collector.failures.last?.subtitle?.contains("readOnly=true") == true, collector.failures.last?.subtitle ?? "")
    }

    func testRelaxingTheModeSaysOnlyTheUserCan() async {
        let service = makeService()
        service.setGovernancePolicy(.readOnly)
        let response = await service.handle(RPCRequest(method: .setPolicy, policy: .autonomous))
        XCTAssertEqual(response.error?.code, "POLICY_LOCKED")
        XCTAssertEqual(response.error?.hint, ExecutionModeNotice.relaxHint(current: .readOnly))
        XCTAssertTrue(response.error?.hint?.contains("Read-only") == true)
    }

    func testAStepRefusedInsideABatchCarriesTheHintInItsMessage() async {
        let executor = ActionExecutor(
            axIndexer: AXIndexer(),
            workspaceMonitor: WorkspaceMonitor(),
            killSwitch: KillSwitch(policy: .readOnly)
        )
        let request = BatchActionRequest(app: "no-such-app-\(UUID().uuidString)", steps: [
            ActionStep(action: .click, elementId: "e1")
        ], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        let step = try? XCTUnwrap(result.stepResults.first)
        XCTAssertEqual(step?.errorCode, "POLICY_BLOCKED")
        XCTAssertTrue(step?.message?.contains("Settings → Safety") == true, step?.message ?? "")
    }

    func testAStepWaitingForApprovalSaysWhatChanged() async throws {
        let service = makeService()
        service.setGovernancePolicy(.ask)
        let eval = RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(tabId: 41, mode: "eval", expression: "document.title"))

        async let tightened = service.handle(eval)
        try await waitForPrompt(service.approvals)
        service.setGovernancePolicy(.readOnly)
        let readOnly = await tightened
        XCTAssertEqual(readOnly.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(readOnly.error?.hint, ExecutionModeNotice.agentHint(policy: .readOnly, killSwitchTripped: false))

        service.setGovernancePolicy(.ask)
        async let relaxed = service.handle(eval)
        try await waitForPrompt(service.approvals)
        service.setGovernancePolicy(.autonomous)
        let autonomous = await relaxed
        XCTAssertEqual(autonomous.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(autonomous.error?.hint, ExecutionModeNotice.modeChangedWhileWaitingHint)
    }

    private struct NoPrompt: Error {}

    private func waitForPrompt(_ broker: ApprovalBroker) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if broker.currentPrompt != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("No approval prompt appeared")
        throw NoPrompt()
    }

    // MARK: - Transports

    func testTheHintTravelsInTheSocketJSONOnlyWhenSet() throws {
        let encoder = JSONEncoder()
        let withHint = RPCResponse.failure(id: "1", code: "POLICY_BLOCKED", message: "m", hint: "h")
        let json = try XCTUnwrap(String(data: encoder.encode(withHint), encoding: .utf8))
        XCTAssertTrue(json.contains(#""hint":"h""#), json)
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.error?.hint, "h")

        let without = try XCTUnwrap(String(data: encoder.encode(RPCResponse.failure(id: "2", code: "X_Y", message: "m")), encoding: .utf8))
        XCTAssertFalse(without.contains("hint"), without)
        // A reply from an older daemon, without the field, still decodes.
        let old = try JSONDecoder().decode(RPCResponse.self, from: Data(#"{"id":"3","ok":false,"serverLatencyMs":0,"error":{"code":"POLICY_BLOCKED","message":"m"}}"#.utf8))
        XCTAssertNil(old.error?.hint)
    }

    /// The real engine behind the real socket server: the raw NDJSON line carries `error.hint`.
    func testTheSocketLineCarriesTheHint() throws {
        let service = makeService()
        service.setGovernancePolicy(.readOnly)
        let socketPath = "/tmp/usemac-notice-sock-\(UUID().uuidString.prefix(8)).sock"
        let server = UnixSocketServer(socketPath: socketPath, service: service)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in socketPath.utf8.enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)

        let line = #"{"id":"s1","method":"act","act":{"app":"no-such-app","steps":[{"action":"click","elementId":"e1"}],"returnObservation":false}}"# + "\n"
        _ = line.utf8CString.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress!, line.utf8.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !received.contains(0x0A) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[..<count])
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: received) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "POLICY_BLOCKED")
        XCTAssertEqual(error["hint"] as? String, ExecutionModeNotice.agentHint(policy: .readOnly, killSwitchTripped: false))
    }

    func testMCPShowsTheDaemonsHintAsTheNextStep() async throws {
        let service = makeService()
        service.setGovernancePolicy(.paused)
        let mcp = MCPStdioServer(socketPath: "/tmp/usemac-notice-mcp-\(UUID().uuidString.prefix(8)).sock", fallbackService: service)
        defer { mcp.close() }
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"usemac_list_apps","arguments":{}}}"#
        let raw = await mcp.processLine(line)
        let output = try XCTUnwrap(raw)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Error [POLICY_BLOCKED]"), text)
        let hint = try XCTUnwrap(ExecutionModeNotice.agentHint(policy: .paused, killSwitchTripped: false))
        XCTAssertTrue(text.contains("Next: \(hint)"), text)
    }

    func testTheStaticGuideStillCoversOlderDaemonsAndStepResults() {
        XCTAssertTrue(UseMacErrorGuide.hint(for: "POLICY_BLOCKED")?.contains("Settings → Safety") == true)
        XCTAssertTrue(UseMacErrorGuide.hint(for: "POLICY_LOCKED")?.contains("Settings → Safety") == true)
    }
}
