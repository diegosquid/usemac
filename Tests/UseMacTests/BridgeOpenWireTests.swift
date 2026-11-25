import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Checks what `ChromeExtensionBridge.open` puts on the wire for the `activate` / `newWindow` options
/// (docs/BRIDGE-PROTOCOL.md, "open"), and that the `windowId` / `restricted` response fields reach `BridgeResponse`.
final class BridgeOpenWireTests: XCTestCase {

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func append(_ item: [String: Any]) { lock.lock(); items.append(item); lock.unlock() }
        func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func withConnectedExtension(
        _ body: (ChromeExtensionBridge, Received) async throws -> Void
    ) async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.baseCommandTimeoutSeconds = 3
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "OpenWire", tabCount: 2)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        let ready = await waitForBridgeCondition { bridge.connectedProfiles().first?.profileName == "OpenWire" }
        XCTAssertTrue(ready)

        let received = Received()
        // Answers every `open` like the extension does for a restricted page (extra `windowId` / `restricted`).
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                received.append(obj)
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String else { continue }
                let tabId = (obj["tabId"] as? Int) ?? 77
                try? await sendBridgeJSON([
                    "type": "response",
                    "id": id,
                    "ok": true,
                    "tabId": tabId,
                    "windowId": 9,
                    "profileName": "OpenWire",
                    "url": "https://chromewebstore.google.com/",
                    "title": "Chrome Web Store",
                    "restricted": true,
                    "activated": true,
                    "snapshot": NSNull(),
                    "actionResult": NSNull(),
                    "error": NSNull()
                ], on: wsTask)
            }
        }
        defer { responder.cancel() }

        try await body(bridge, received)
    }

    private func lastOpenRequest(_ received: Received) -> [String: Any]? {
        received.snapshot().last { ($0["command"] as? String) == "open" }
    }

    func testActivateOnlySendsEmptyURLWithTabIdAndActivate() async throws {
        try await withConnectedExtension { bridge, received in
            let resp = await bridge.open(BrowserOpenParams(url: "", profile: "OpenWire", tabId: 42, activate: true))
            XCTAssertTrue(resp.ok, "error: \(String(describing: resp.error))")
            XCTAssertEqual(resp.tabId, 42)
            XCTAssertEqual(resp.windowId, 9)
            XCTAssertEqual(resp.restricted, true)

            let sent = try XCTUnwrap(lastOpenRequest(received))
            XCTAssertEqual(sent["url"] as? String, "")
            XCTAssertEqual(sent["tabId"] as? Int, 42)
            XCTAssertEqual(sent["activate"] as? Bool, true)
            XCTAssertEqual(sent["newTab"] as? Bool, false)
            XCTAssertNil(sent["newWindow"], "unset options are omitted")
        }
    }

    func testNewWindowIsForwardedAndUnsetOptionsAreOmitted() async throws {
        try await withConnectedExtension { bridge, received in
            let resp = await bridge.open(BrowserOpenParams(url: "https://example.com/", profile: "OpenWire", newWindow: true))
            XCTAssertTrue(resp.ok, "error: \(String(describing: resp.error))")

            let sent = try XCTUnwrap(lastOpenRequest(received))
            XCTAssertEqual(sent["url"] as? String, "https://example.com/")
            XCTAssertEqual(sent["newWindow"] as? Bool, true)
            XCTAssertNil(sent["activate"])
            XCTAssertEqual(sent["stream"] as? Bool, true)

            _ = await bridge.open(BrowserOpenParams(url: "https://example.org/", profile: "OpenWire"))
            let plain = try XCTUnwrap(lastOpenRequest(received))
            XCTAssertNil(plain["activate"])
            XCTAssertNil(plain["newWindow"])
            XCTAssertEqual(plain["newTab"] as? Bool, true)
        }
    }
}
