import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

final class BridgeAuthTests: XCTestCase {

    func testProofsMatchProtocolTestVector() throws {
        let expectedBytes = Data(0..<32)
        let vectorText = "umk_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let clientNonce = String(repeating: "aa", count: 32)
        let serverNonce = String(repeating: "bb", count: 32)
        let expectedServerProof = "0dc1c8449ec46032d911453f6e6668ee5474655b9f6b9d6de080377afc9f794a"
        let expectedClientProof = "c98c470a7e7cf4f566d842b2a2fcdd46e9894e13bcfe448ad0c180cb17fa4f35"

        let key = try XCTUnwrap(BridgeKey(text: vectorText))
        XCTAssertEqual(key.bytes, expectedBytes)
        XCTAssertEqual(key.text, vectorText)
        XCTAssertEqual(BridgeAuth.serverProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce), expectedServerProof)
        XCTAssertEqual(BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce), expectedClientProof)

        // Trims whitespace and accepts uppercase
        let paddedUpper = "  \t\(vectorText.uppercased())\n  "
        XCTAssertEqual(BridgeKey(text: paddedUpper), key)

        // Rejects malformed forms
        XCTAssertNil(BridgeKey(text: ""))
        XCTAssertNil(BridgeKey(text: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        XCTAssertNil(BridgeKey(text: "umk_" + String(repeating: "a", count: 63)))
        XCTAssertNil(BridgeKey(text: "umk_" + String(repeating: "a", count: 65)))
        XCTAssertNil(BridgeKey(text: "umk_" + String(repeating: "a", count: 63) + "g"))
    }

    func testKeyStoreCreatesPrivateKeyFileAndReloadsIt() throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let store1 = BridgePairingStore(directory: keyDir)
        let key1 = try store1.loadOrCreateKey()

        let keyFile = keyDir.appendingPathComponent("bridge-key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile.path))

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: keyDir.path)
        let dirMode = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirMode, 0o700)

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        let fileMode = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(fileMode, 0o600)

        let rawContent = try String(contentsOf: keyFile, encoding: .utf8)
        XCTAssertEqual(rawContent, key1.text + "\n")

        let store2 = BridgePairingStore(directory: keyDir)
        let key2 = try store2.loadOrCreateKey()
        XCTAssertEqual(key2, key1)

        let key3 = try store1.resetKey()
        XCTAssertNotEqual(key3, key1)
        XCTAssertEqual(try store2.loadOrCreateKey(), key3)

        // Corrupt file with garbage -> replaced with a valid key
        try Data("not-a-valid-pairing-key\n".utf8).write(to: keyFile)
        let key4 = try store1.loadOrCreateKey()
        XCTAssertNotEqual(key4, key3)
        let replacedContent = try String(contentsOf: keyFile, encoding: .utf8)
        XCTAssertEqual(replacedContent, key4.text + "\n")
        let replacedMode = (try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(replacedMode, 0o600)
    }

    func testHandshakeWithCorrectKeyListsProfileOnlyAfterReady() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let store = BridgePairingStore(directory: keyDir)
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: store)
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try openMockExtensionSocket(port: port)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        let clientNonce = BridgeAuth.randomNonceHex()
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "Work",
            "clientNonce": clientNonce,
            "hasKey": true
        ], on: wsTask)

        let challenge = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(challenge["type"] as? String, "challenge")
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        let serverProof = try XCTUnwrap(challenge["serverProof"] as? String)
        XCTAssertEqual(serverProof, BridgeAuth.serverProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce))

        // Before auth, profile must NOT be listed
        XCTAssertTrue(bridge.connectedProfiles().isEmpty)

        let clientProof = BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        try await sendBridgeJSON([
            "type": "auth",
            "clientProof": clientProof
        ], on: wsTask)

        let ready = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(ready["type"] as? String, "ready")

        try await sendBridgeJSON([
            "type": "profile_info",
            "profileName": "Work",
            "tabCount": 7
        ], on: wsTask)

        let appeared = await waitForBridgeCondition {
            bridge.connectedProfiles().first?.profileName == "Work" && bridge.connectedProfiles().first?.tabCount == 7
        }
        XCTAssertTrue(appeared)
        let profiles = bridge.connectedProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.profileName, "Work")
        XCTAssertEqual(profiles.first?.tabCount, 7)
        XCTAssertNil(profiles.first?.profileEmail)
    }

    func testHelloWithoutKeyGetsPairingRequired() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-auth-pair-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try openMockExtensionSocket(port: port)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "Personal",
            "clientNonce": BridgeAuth.randomNonceHex(),
            "hasKey": false
        ], on: wsTask)

        let pairingMsg = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(pairingMsg["type"] as? String, "pairing_required")

        XCTAssertTrue(service.chromeBridge.connectedProfiles().isEmpty)
        XCTAssertEqual(service.chromeBridge.pendingPairingProfiles(), ["Personal"])
        XCTAssertEqual(service.pendingBrowserPairings(), ["Personal"])

        let tabsRes = await service.handle(RPCRequest(
            method: .browserTabs,
            browserTabs: BrowserTabsParams()
        ))
        XCTAssertFalse(tabsRes.ok)
        XCTAssertEqual(tabsRes.error?.code, "EXTENSION_NOT_PAIRED")
        XCTAssertEqual(
            tabsRes.error?.message,
            "A Chrome profile is connected but not paired. Open the UseMac extension popup and paste the pairing key from UseMac → Settings → General → Chrome Extension."
        )

        // Re-send hello with key on the SAME socket to complete handshake
        let clientNonce2 = BridgeAuth.randomNonceHex()
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "Personal",
            "clientNonce": clientNonce2,
            "hasKey": true
        ], on: wsTask)

        let challenge = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(challenge["type"] as? String, "challenge")
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        let serverProof = try XCTUnwrap(challenge["serverProof"] as? String)
        XCTAssertEqual(serverProof, BridgeAuth.serverProof(key: key, clientNonce: clientNonce2, serverNonce: serverNonce))

        let clientProof = BridgeAuth.clientProof(key: key, clientNonce: clientNonce2, serverNonce: serverNonce)
        try await sendBridgeJSON([
            "type": "auth",
            "clientProof": clientProof
        ], on: wsTask)

        let ready = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(ready["type"] as? String, "ready")

        try await sendBridgeJSON([
            "type": "profile_info",
            "profileName": "Personal",
            "tabCount": 4
        ], on: wsTask)

        let readyProfile = await waitForBridgeCondition {
            service.chromeBridge.connectedProfiles().first?.profileName == "Personal"
                && service.chromeBridge.connectedProfiles().first?.tabCount == 4
        }
        XCTAssertTrue(readyProfile)
        XCTAssertTrue(service.chromeBridge.pendingPairingProfiles().isEmpty)
    }

    func testWrongClientProofIsRejectedAndClosed() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)

        let wsTask = try openMockExtensionSocket(port: port)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "BadProof",
            "clientNonce": BridgeAuth.randomNonceHex(),
            "hasKey": true
        ], on: wsTask)

        let challenge = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(challenge["type"] as? String, "challenge")

        try await sendBridgeJSON([
            "type": "auth",
            "clientProof": String(repeating: "00", count: 32)
        ], on: wsTask)

        let failed = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(failed["type"] as? String, "auth_failed")
        XCTAssertEqual(failed["reason"] as? String, "bad_proof")

        // Next receive must fail because the daemon closed the socket
        do {
            _ = try await wsTask.receive()
            XCTFail("Expected WebSocket to be closed after bad_proof")
        } catch {
            // Expected close
        }

        XCTAssertTrue(bridge.connectedProfiles().isEmpty)
    }

    func testChallengeIsSingleUse() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try openMockExtensionSocket(port: port)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        let clientNonce = BridgeAuth.randomNonceHex()
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "SingleUse",
            "clientNonce": clientNonce,
            "hasKey": true
        ], on: wsTask)

        let challenge = try await receiveBridgeJSON(from: wsTask)
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        let validClientProof = BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)

        // Send a wrong auth followed immediately by the valid auth for the same challenge
        try await sendBridgeJSON([
            "type": "auth",
            "clientProof": String(repeating: "ff", count: 32)
        ], on: wsTask)
        try? await sendBridgeJSON([
            "type": "auth",
            "clientProof": validClientProof
        ], on: wsTask)

        let reply = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(reply["type"] as? String, "auth_failed")
        XCTAssertEqual(reply["reason"] as? String, "bad_proof")

        do {
            let extra = try await receiveBridgeJSON(from: wsTask)
            XCTFail("Expected connection closed after single-use challenge failed, got \(extra)")
        } catch {
            // Expected close
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(bridge.connectedProfiles().isEmpty)
    }

    func testBadHelloIsRejected() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)

        // Case 1: protocol: 1
        let wsProto1 = try openMockExtensionSocket(port: port)
        defer { wsProto1.cancel(with: .goingAway, reason: nil) }
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 1,
            "extensionVersion": "0.5.0",
            "profileName": "OldProto",
            "clientNonce": BridgeAuth.randomNonceHex(),
            "hasKey": true
        ], on: wsProto1)

        let resp1 = try await receiveBridgeJSON(from: wsProto1)
        XCTAssertEqual(resp1["type"] as? String, "auth_failed")
        XCTAssertEqual(resp1["reason"] as? String, "bad_hello")
        do {
            _ = try await wsProto1.receive()
            XCTFail("Expected socket closed after protocol: 1 bad_hello")
        } catch {
            // Expected close
        }

        // Case 2: short clientNonce
        let wsShortNonce = try openMockExtensionSocket(port: port)
        defer { wsShortNonce.cancel(with: .goingAway, reason: nil) }
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "ShortNonce",
            "clientNonce": "abcd",
            "hasKey": true
        ], on: wsShortNonce)

        let resp2 = try await receiveBridgeJSON(from: wsShortNonce)
        XCTAssertEqual(resp2["type"] as? String, "auth_failed")
        XCTAssertEqual(resp2["reason"] as? String, "bad_hello")
        do {
            _ = try await wsShortNonce.receive()
            XCTFail("Expected socket closed after short clientNonce bad_hello")
        } catch {
            // Expected close
        }

        XCTAssertTrue(bridge.connectedProfiles().isEmpty)
    }

    func testFramesBeforeReadyAreIgnored() async throws {
        final class FrameCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        let frameCounter = FrameCounter()
        bridge.onBrowserFrame = { _, _, _, _, _, _ in
            frameCounter.increment()
        }
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        // Connect an authenticated victim session with an in-flight tabs request so we can also
        // verify an unready session's forged `response` does NOT complete it.
        let readyWs = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Legit", tabCount: 1)
        defer { readyWs.cancel(with: .goingAway, reason: nil) }
        let legitReady = await waitForBridgeCondition { bridge.connectedProfiles().contains { $0.profileName == "Legit" } }
        XCTAssertTrue(legitReady)

        let pendingTabsTask = Task {
            await bridge.tabs(BrowserTabsParams(profile: "Legit"))
        }
        let legitRequest = try await receiveBridgeJSON(from: readyWs)
        let legitReqId = try XCTUnwrap(legitRequest["id"] as? String)

        // Open a second session and stop BEFORE auth (challenged state)
        let unreadyWs = try openMockExtensionSocket(port: port)
        defer { unreadyWs.cancel(with: .goingAway, reason: nil) }

        let clientNonce = BridgeAuth.randomNonceHex()
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": "0.5.0",
            "profileName": "EarlySender",
            "clientNonce": clientNonce,
            "hasKey": true
        ], on: unreadyWs)

        let challenge = try await receiveBridgeJSON(from: unreadyWs)
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)

        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        // Send frame and response BEFORE ready
        try await sendBridgeJSON([
            "type": "frame",
            "tabId": 10,
            "profileName": "EarlySender",
            "url": "https://example.com",
            "title": "Early",
            "viewportWidth": 1280,
            "viewportHeight": 800,
            "jpegBase64": fakeJPEG
        ], on: unreadyWs)
        try await sendBridgeJSON([
            "type": "response",
            "id": legitReqId,
            "ok": true,
            "profileName": "EarlySender",
            "tabs": []
        ], on: unreadyWs)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(frameCounter.value(), 0, "Frame sent before ready must be ignored")
        XCTAssertNil(bridge.latestFrame())

        // Now complete legit session's response to prove it was still pending and not hijacked
        try await sendBridgeJSON([
            "type": "response",
            "id": legitReqId,
            "ok": true,
            "profileName": "Legit",
            "tabs": [[
                "tabId": 99,
                "title": "Real Tab",
                "url": "https://example.com",
                "active": true
            ]]
        ], on: readyWs)
        let legitTabsResp = await pendingTabsTask.value
        XCTAssertTrue(legitTabsResp.ok)
        XCTAssertEqual(legitTabsResp.profileName, "Legit")
        XCTAssertEqual(legitTabsResp.tabs?.first?.tabId, 99)

        // Complete auth on the second session, then send frame & answer a real request -> both work!
        let clientProof = BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        try await sendBridgeJSON([
            "type": "auth",
            "clientProof": clientProof
        ], on: unreadyWs)
        let ready = try await receiveBridgeJSON(from: unreadyWs)
        XCTAssertEqual(ready["type"] as? String, "ready")

        try await sendBridgeJSON([
            "type": "frame",
            "tabId": 11,
            "profileName": "EarlySender",
            "url": "https://example.com",
            "title": "AfterReady",
            "viewportWidth": 1280,
            "viewportHeight": 800,
            "jpegBase64": fakeJPEG
        ], on: unreadyWs)

        let frameDelivered = await waitForBridgeCondition { frameCounter.value() == 1 }
        XCTAssertTrue(frameDelivered, "Frame sent after ready must trigger onBrowserFrame")

        let secondTabsTask = Task {
            await bridge.tabs(BrowserTabsParams(profile: "EarlySender"))
        }
        let secondReq = try await receiveBridgeJSON(from: unreadyWs)
        let secondReqId = try XCTUnwrap(secondReq["id"] as? String)
        try await sendBridgeJSON([
            "type": "response",
            "id": secondReqId,
            "ok": true,
            "profileName": "EarlySender",
            "tabs": [[
                "tabId": 11,
                "title": "Ready Tab",
                "url": "https://example.com",
                "active": true
            ]]
        ], on: unreadyWs)
        let secondResp = await secondTabsTask.value
        XCTAssertTrue(secondResp.ok)
        XCTAssertEqual(secondResp.tabs?.first?.tabId, 11)
    }

    func testMissingAndWebOriginsAreRejected() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // 1. Missing Origin must be rejected
        let noOriginWs = try openMockExtensionSocket(port: port, origin: nil, session: session)
        do {
            try await sendBridgeJSON([
                "type": "hello",
                "protocol": 2,
                "clientNonce": BridgeAuth.randomNonceHex(),
                "hasKey": true
            ], on: noOriginWs)
            _ = try await noOriginWs.receive()
            XCTFail("Expected WebSocket upgrade without Origin to be rejected")
        } catch {
            // Expected rejection
        }
        noOriginWs.cancel()

        // 2. Web Origin must be rejected
        let webOriginWs = try openMockExtensionSocket(port: port, origin: "https://evil.example.com", session: session)
        do {
            try await sendBridgeJSON([
                "type": "hello",
                "protocol": 2,
                "clientNonce": BridgeAuth.randomNonceHex(),
                "hasKey": true
            ], on: webOriginWs)
            _ = try await webOriginWs.receive()
            XCTFail("Expected WebSocket upgrade with https:// Origin to be rejected")
        } catch {
            // Expected rejection
        }
        webOriginWs.cancel()

        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(bridge.connectedProfiles().isEmpty)

        // 3. chrome-extension:// Origin passes upgrade and completes handshake
        let goodWs = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "AllowedExt", tabCount: 2)
        defer { goodWs.cancel(with: .goingAway, reason: nil) }

        let connected = await waitForBridgeCondition {
            bridge.connectedProfiles().first?.profileName == "AllowedExt"
        }
        XCTAssertTrue(connected)
    }

    func testKillSwitchSendsCancelToReadySessions() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-auth-ks-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "KillTarget", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        let ready = await waitForBridgeCondition {
            service.chromeBridge.connectedProfiles().first?.profileName == "KillTarget"
        }
        XCTAssertTrue(ready)

        service.tripKillSwitch(true)

        // The tab indicator learns first (its pill says "Stopped" before the debugger detaches), then cancel.
        let firstMsg = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(firstMsg["type"] as? String, "tab_control")
        XCTAssertEqual(firstMsg["state"] as? String, "stopped")
        let cancelMsg = try await receiveBridgeJSON(from: wsTask)
        XCTAssertEqual(cancelMsg["type"] as? String, "cancel")
        XCTAssertTrue(cancelMsg["tabId"] is NSNull, "Expected explicit null tabId in cancel frame, got \(cancelMsg)")
    }

    func testActTimeoutScalesWithWaitStepsAndSendsCancel() async throws {
        final class ReceivedMessages: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [[String: Any]] = []
            func append(_ item: [String: Any]) { lock.lock(); items.append(item); lock.unlock() }
            func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return items }
        }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.baseCommandTimeoutSeconds = 1
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "SlowExt", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        let ready = await waitForBridgeCondition {
            bridge.connectedProfiles().first?.profileName == "SlowExt"
        }
        XCTAssertTrue(ready)

        let received = ReceivedMessages()
        let reader = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                received.append(obj)
            }
        }
        defer { reader.cancel() }

        let startNs = DispatchTime.now().uptimeNanoseconds
        let resp = await bridge.act(BrowserActParams(
            profile: "SlowExt",
            tabId: 7,
            steps: [ActionStep(action: .wait, durationMs: 1000)]
        ))
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000_000.0

        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "EXTENSION_TIMEOUT")
        XCTAssertGreaterThanOrEqual(elapsedSeconds, 2.0, "Expected timeout >= 2.0s (1s base + 1s wait), got \(elapsedSeconds)s")

        let gotCancel = await waitForBridgeCondition(timeoutMs: 1500) {
            received.snapshot().contains { ($0["type"] as? String) == "cancel" && ($0["tabId"] as? Int) == 7 }
        }
        XCTAssertTrue(gotCancel, "Expected mock extension to receive {\"type\":\"cancel\",\"tabId\":7}, received: \(received.snapshot())")
    }
}
