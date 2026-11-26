import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// The tab indicator's bridge messages (docs/BRIDGE-PROTOCOL.md, "Tab indicator"): `tab_control` from the daemon when
/// the kill switch, Pause or task_complete ends an agent's control, and `stop_requested` from the pill's Stop button.
final class BridgeTabControlTests: XCTestCase {

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func append(_ item: [String: Any]) { lock.lock(); items.append(item); lock.unlock() }
        func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return items }
        func ofType(_ type: String) -> [[String: Any]] { snapshot().filter { ($0["type"] as? String) == type } }
    }

    private final class StopCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Int?)] = []
        func append(_ item: (String, Int?)) { lock.lock(); items.append(item); lock.unlock() }
        func snapshot() -> [(String, Int?)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// An engine whose bridge has one paired mock extension. The mock answers `open` with tab 501, then 502, ...
    private func withEngineAndExtension(
        _ body: (UseMacEngineService, URLSessionWebSocketTask, Received) async throws -> Void
    ) async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-tabctl-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.baseCommandTimeoutSeconds = 3
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Indicator")
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "Indicator" }
        XCTAssertTrue(ready)

        let received = Received()
        let responder = Task {
            var nextTabId = 501
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                received.append(obj)
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String else { continue }
                var tabId: Any = (obj["tabId"] as? Int) ?? NSNull()
                if (obj["command"] as? String) == "open" {
                    tabId = nextTabId
                    nextTabId += 1
                }
                try? await sendBridgeJSON([
                    "type": "response",
                    "id": id,
                    "ok": true,
                    "tabId": tabId,
                    "profileName": "Indicator",
                    "url": "https://example.com/",
                    "title": "Example",
                    "snapshot": NSNull(),
                    "actionResult": NSNull(),
                    "error": NSNull()
                ], on: wsTask)
            }
        }
        defer { responder.cancel() }

        try await body(service, wsTask, received)
    }

    func testStopRequestedFromThePairedExtensionReachesTheHandler() async throws {
        try await withEngineAndExtension { service, wsTask, _ in
            let calls = StopCalls()
            service.chromeBridge.onUserStopRequested = { profile, tabId in calls.append((profile, tabId)) }

            try await sendBridgeJSON(["type": "stop_requested", "tabId": 42], on: wsTask)
            let arrived = await waitForBridgeCondition { !calls.snapshot().isEmpty }
            XCTAssertTrue(arrived)
            XCTAssertEqual(calls.snapshot().first?.0, "Indicator")
            XCTAssertEqual(calls.snapshot().first?.1, 42)
            XCTAssertFalse(service.isKillSwitchTripped(), "the app's handler replaced the engine's default")
        }
    }

    func testStopRequestedTripsTheKillSwitchAndTellsTheExtensionBeforeCancelling() async throws {
        try await withEngineAndExtension { service, wsTask, received in
            try await sendBridgeJSON(["type": "stop_requested", "tabId": 42], on: wsTask)
            let tripped = await waitForBridgeCondition { service.isKillSwitchTripped() }
            XCTAssertTrue(tripped)

            let gotCancel = await waitForBridgeCondition { !received.ofType("cancel").isEmpty }
            XCTAssertTrue(gotCancel)
            let types = received.snapshot().compactMap { $0["type"] as? String }
            let control = try XCTUnwrap(types.firstIndex(of: "tab_control"))
            let cancel = try XCTUnwrap(types.firstIndex(of: "cancel"))
            XCTAssertLessThan(control, cancel, "the pill says Stopped before the debugger detaches")
            XCTAssertEqual(received.ofType("tab_control").first?["state"] as? String, "stopped")
            service.tripKillSwitch(false)
        }
    }

    func testStopRequestedBeforePairingIsDropped() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-tabctl-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }
        let port = await waitForListeningPort(of: service.chromeBridge)
        let calls = StopCalls()
        service.chromeBridge.onUserStopRequested = { profile, tabId in calls.append((profile, tabId)) }

        let wsTask = try openMockExtensionSocket(port: port)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        try await sendBridgeJSON(["type": "stop_requested", "tabId": 7], on: wsTask)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(calls.snapshot().isEmpty)
        XCTAssertFalse(service.isKillSwitchTripped())
    }

    func testPauseSendsTabControlStoppedWithoutCancelling() async throws {
        try await withEngineAndExtension { service, _, received in
            service.setGovernancePolicy(.paused)
            let got = await waitForBridgeCondition { !received.ofType("tab_control").isEmpty }
            XCTAssertTrue(got)
            XCTAssertEqual(received.ofType("tab_control").first?["state"] as? String, "stopped")
            XCTAssertNil(received.ofType("tab_control").first?["keepTabIds"] as? [Int])
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(received.ofType("cancel").isEmpty)

            service.setGovernancePolicy(.autonomous)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(received.ofType("tab_control").count, 1, "only Pause stops the indicator")
        }
    }

    func testTaskCompleteEndsControlExceptOnTabsAnotherTaskOwns() async throws {
        try await withEngineAndExtension { service, _, received in
            _ = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "A", taskId: "task-a")))
            let openA = await service.handle(RPCRequest(
                method: .browserOpen,
                browserOpen: BrowserOpenParams(url: "https://example.com/a", profile: "Indicator", taskId: "task-a")
            ))
            XCTAssertTrue(openA.ok, "\(String(describing: openA.error))")
            _ = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "B", taskId: "task-b")))
            let openB = await service.handle(RPCRequest(
                method: .browserOpen,
                browserOpen: BrowserOpenParams(url: "https://example.com/b", profile: "Indicator", taskId: "task-b")
            ))
            XCTAssertTrue(openB.ok, "\(String(describing: openB.error))")

            _ = await service.handle(RPCRequest(
                method: .taskComplete,
                taskComplete: TaskCompleteParams(summary: "A done", keepTabs: true, taskId: "task-a")
            ))
            let ended = await waitForBridgeCondition { !received.ofType("tab_control").isEmpty }
            XCTAssertTrue(ended)
            let first = try XCTUnwrap(received.ofType("tab_control").first)
            XCTAssertEqual(first["state"] as? String, "ended", "sent even with keepTabs")
            XCTAssertEqual(first["keepTabIds"] as? [Int], [502], "B's tab keeps its indicator")

            _ = await service.handle(RPCRequest(
                method: .taskComplete,
                taskComplete: TaskCompleteParams(summary: "B done", keepTabs: true, taskId: "task-b")
            ))
            let endedAgain = await waitForBridgeCondition { received.ofType("tab_control").count == 2 }
            XCTAssertTrue(endedAgain)
            XCTAssertEqual(received.ofType("tab_control").last?["keepTabIds"] as? [Int], [])
        }
    }

    func testFramesThatShowTheIndicatorAreNotReusableScreenshots() async throws {
        try await withEngineAndExtension { service, wsTask, _ in
            let jpeg = "/9j/4AAQSkZJRgABAQ=="
            try await sendBridgeJSON([
                "type": "frame", "tabId": 9, "profileName": "Indicator", "url": "https://example.com/", "title": "Example",
                "viewportWidth": 1280, "viewportHeight": 800, "jpegBase64": jpeg, "indicator": true
            ], on: wsTask)
            let flagged = await waitForBridgeCondition { service.chromeBridge.latestFrame(tabId: 9)?.showsIndicator == true }
            XCTAssertTrue(flagged)

            try await sendBridgeJSON([
                "type": "frame", "tabId": 9, "profileName": "Indicator", "url": "https://example.com/", "title": "Example",
                "viewportWidth": 1280, "viewportHeight": 800, "jpegBase64": jpeg
            ], on: wsTask)
            let plain = await waitForBridgeCondition { service.chromeBridge.latestFrame(tabId: 9)?.showsIndicator == false }
            XCTAssertTrue(plain, "frames from older extensions (no field) count as plain")
        }
    }
}
