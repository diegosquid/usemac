import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Extension IDs, version ordering and the outdated / wrong-source verdict (issue #6).
final class ChromeExtensionCheckTests: XCTestCase {

    // MARK: - IDs

    func testGenerateMatchesChromiumIdUtilVector() {
        // components/crx_file/id_util_unittest.cc: GenerateId("test").
        XCTAssertEqual(ChromeExtensionID.generate(from: Data("test".utf8)), "jpignaibiiemhngfjkcpokkamffknabf")
    }

    func testUnpackedIdOfTheAppBundleFolder() {
        // Derived with: printf '<path>' | shasum -a 256 | cut -c1-32 | tr 0-9a-f a-p
        let path = "/Applications/UseMac.app/Contents/Resources/chrome-extension"
        XCTAssertEqual(ChromeExtensionID.generate(from: Data(path.utf8)), "cjmjpbjmbbokoknjmnppdcifkeaaapca")
        XCTAssertTrue(ChromeExtensionID.isValid("cjmjpbjmbbokoknjmnppdcifkeaaapca"))
        XCTAssertFalse(ChromeExtensionID.isValid("cjmjpbjmbbokoknjmnppdcifkeaaapcz"))
        XCTAssertFalse(ChromeExtensionID.isValid("short"))
    }

    func testManifestKeyIdHashesTheDecodedKey() {
        XCTAssertEqual(ChromeExtensionID.forManifestKey("dGVz\ndA=="), "jpignaibiiemhngfjkcpokkamffknabf")
        XCTAssertNil(ChromeExtensionID.forManifestKey("not base64!"))
    }

    /// Chrome hashes the path `realpath(3)` returns: symlinks resolved, no trailing slash, on-disk case.
    func testUnpackedIdUsesTheCanonicalPath() throws {
        let root = URL(fileURLWithPath: ChromeExtensionID.canonicalPath(NSTemporaryDirectory()))
            .appendingPathComponent("usemac-ext-id-\(UUID().uuidString)")
        let real = root.appendingPathComponent("CaseProbe/Extension")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("CaseProbe"))

        XCTAssertEqual(ChromeExtensionID.canonicalPath(link.path + "/Extension/"), real.path)
        XCTAssertEqual(ChromeExtensionID.forUnpackedFolder(link.path + "/Extension"), ChromeExtensionID.generate(from: Data(real.path.utf8)))
        XCTAssertEqual(ChromeExtensionID.canonicalPath("/tmp"), "/private/tmp")

        let lowercased = root.appendingPathComponent("caseprobe/extension").path
        if FileManager.default.fileExists(atPath: lowercased) { // case-insensitive volume (the macOS default)
            XCTAssertEqual(ChromeExtensionID.canonicalPath(lowercased), real.path)
        }
    }

    // MARK: - Versions

    func testVersionOrdering() throws {
        let ordered = ["0.5.0", "0.6.0 alpha", "0.6.0 beta 2", "0.6.0-beta.3", "0.6.0 rc 1", "0.6.0", "0.6.1", "1.0"]
        let versions = try ordered.map { try XCTUnwrap(ChromeExtensionVersion($0), $0) }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            XCTAssertLessThan(lower, higher)
        }
        XCTAssertEqual(ChromeExtensionVersion("0.6.0-beta.2"), ChromeExtensionVersion("0.6.0 beta 2"))
        XCTAssertEqual(ChromeExtensionVersion("v0.6"), ChromeExtensionVersion("0.6.0"))
        XCTAssertNil(ChromeExtensionVersion("unknown"))
        XCTAssertNil(ChromeExtensionVersion(""))
        XCTAssertNil(ChromeExtensionVersion("0.6.0 nightly"))
    }

    // MARK: - Bundled copy

    func testBundledExtensionReadsVersionNameAndFolderId() throws {
        let dir = try makeExtensionFolder(manifest: ["manifest_version": 3, "version": "0.6.0", "version_name": "0.6.0 beta 3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = try XCTUnwrap(BundledChromeExtension(directory: dir.path))
        XCTAssertEqual(bundled.version, "0.6.0 beta 3")
        XCTAssertEqual(bundled.directory, ChromeExtensionID.canonicalPath(dir.path))
        XCTAssertEqual(bundled.extensionId, ChromeExtensionID.forUnpackedFolder(dir.path))
    }

    func testBundledExtensionWithKeyUsesTheKeyId() throws {
        let dir = try makeExtensionFolder(manifest: ["version": "0.7.0", "key": "dGVzdA=="])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = try XCTUnwrap(BundledChromeExtension(directory: dir.path))
        XCTAssertEqual(bundled.version, "0.7.0")
        XCTAssertEqual(bundled.extensionId, "jpignaibiiemhngfjkcpokkamffknabf")
        XCTAssertNil(BundledChromeExtension(directory: dir.appendingPathComponent("missing").path))
    }

    // MARK: - Verdict

    private let bundled = BundledChromeExtension(directory: "/Applications/UseMac.app/Contents/Resources/chrome-extension", version: "0.6.0 beta 2", extensionId: "cjmjpbjmbbokoknjmnppdcifkeaaapca")
    private let storeId = "nkbihfbeogaeaoehlefnkodbefgpgknn"

    /// Diego's setup: an old copy loaded unpacked from a repo checkout, without hello.extensionId.
    func testOldCopyFromAnotherFolderIsOutdatedAndSaysSo() {
        let health = ChromeExtensionHealth.evaluate(extensionVersion: "0.5.0", extensionId: "gbdlncgdehanogjlemdkbefefdckkmnb", reloadable: false, bundled: bundled, webStoreId: nil)
        XCTAssertEqual(health.source, .otherFolder)
        XCTAssertEqual(health.outdated, true)
        XCTAssertEqual(health.bundledVersion, "0.6.0 beta 2")
        XCTAssertFalse(health.reloadable)
        let note = health.note ?? ""
        XCTAssertTrue(note.hasPrefix("Loaded from another folder, app updates won't reach it."), note)
        XCTAssertTrue(note.contains("chrome://extensions"), note)
    }

    func testCurrentCopyFromTheAppHasNoNote() {
        let health = ChromeExtensionHealth.evaluate(extensionVersion: "0.6.0 beta 2", extensionId: "CJMJPBJMBBOKOKNJMNPPDCIFKEAAAPCA", reloadable: true, bundled: bundled, webStoreId: storeId)
        XCTAssertEqual(health.source, .app)
        XCTAssertEqual(health.outdated, false)
        XCTAssertNil(health.note)
    }

    func testOutdatedAppCopyAsksForAReload() {
        let health = ChromeExtensionHealth.evaluate(extensionVersion: "0.6.0 beta 1", extensionId: bundled.extensionId, reloadable: true, bundled: bundled, webStoreId: nil)
        XCTAssertEqual(health.source, .app)
        XCTAssertEqual(health.outdated, true)
        XCTAssertEqual(health.note, "Chrome runs extension 0.6.0 beta 1; this app ships 0.6.0 beta 2. Reload the extension to run the new code.")
    }

    func testStoreCopyAndUnknownSources() {
        let store = ChromeExtensionHealth.evaluate(extensionVersion: "0.6.0", extensionId: storeId, reloadable: true, bundled: bundled, webStoreId: storeId)
        XCTAssertEqual(store.source, .webStore)
        XCTAssertEqual(store.outdated, false)
        XCTAssertNil(store.note)

        let noId = ChromeExtensionHealth.evaluate(extensionVersion: "0.5.0", extensionId: nil, reloadable: false, bundled: bundled, webStoreId: nil)
        XCTAssertEqual(noId.source, .unknown)
        XCTAssertEqual(noId.outdated, true)

        let noBundle = ChromeExtensionHealth.evaluate(extensionVersion: "0.5.0", extensionId: "gbdlncgdehanogjlemdkbefefdckkmnb", reloadable: true, bundled: nil, webStoreId: nil)
        XCTAssertEqual(noBundle.source, .unknown)
        XCTAssertNil(noBundle.outdated)
        XCTAssertNil(noBundle.note)
    }

    func testOriginLogOnlyAnswersWhenUnambiguous() {
        let log = ExtensionOriginLog()
        let start = Date()
        XCTAssertNil(log.unambiguousId(since: start))
        log.record("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP", at: start)
        log.record("abcdefghijklmnopabcdefghijklmnop", at: start.addingTimeInterval(0.1))
        XCTAssertEqual(log.unambiguousId(since: start), "abcdefghijklmnopabcdefghijklmnop")
        log.record("pppppppppppppppppppppppppppppppp", at: start.addingTimeInterval(0.2))
        XCTAssertNil(log.unambiguousId(since: start))
        XCTAssertEqual(log.unambiguousId(since: start.addingTimeInterval(0.15)), "pppppppppppppppppppppppppppppppp")
    }

    func testReloadRequestDecodes() throws {
        let json = #"{"method":"browser_reload_extension","browserReloadExtension":{"profile":"Work","force":true}}"#
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.method, .browserReloadExtension)
        XCTAssertEqual(request.browserReloadExtension, BrowserReloadExtensionParams(profile: "Work", force: true))
    }

    private func makeExtensionFolder(manifest: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usemac-bundled-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }
}

/// The bridge side: hello → verdict in browser_status and in `ready`, and the `reload_extension` round trip.
final class ExtensionReloadBridgeTests: XCTestCase {
    private static let bundledId = "cjmjpbjmbbokoknjmnppdcifkeaaapca"
    private let bundled = BundledChromeExtension(directory: "/Applications/UseMac.app/Contents/Resources/chrome-extension", version: "0.6.0 beta 3", extensionId: ExtensionReloadBridgeTests.bundledId)

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func append(_ item: [String: Any]) { lock.lock(); items.append(item); lock.unlock() }
        func requests(_ command: String) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return items.filter { ($0["type"] as? String) == "request" && ($0["command"] as? String) == command }
        }
    }

    private func makeBridge(_ keyDir: URL) -> ChromeExtensionBridge {
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir), bundledExtension: bundled)
        bridge.baseCommandTimeoutSeconds = 3
        bridge.start()
        return bridge
    }

    /// Pairs a mock extension and returns its socket and the daemon's `ready` frame. `extensionId: nil` behaves like
    /// an extension that predates the field.
    private func connect(
        port: UInt16,
        key: BridgeKey,
        profileName: String = "Work",
        version: String,
        extensionId: Any?,
        origin: String = testExtensionOrigin
    ) async throws -> (URLSessionWebSocketTask, [String: Any]) {
        let ws = try openMockExtensionSocket(port: port, origin: origin)
        let clientNonce = BridgeAuth.randomNonceHex()
        var hello: [String: Any] = ["type": "hello", "protocol": 2, "extensionVersion": version, "profileName": profileName, "clientNonce": clientNonce, "hasKey": true]
        if let extensionId { hello["extensionId"] = extensionId }
        try await sendBridgeJSON(hello, on: ws)
        let challenge = try await receiveBridgeJSON(from: ws)
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        try await sendBridgeJSON(["type": "auth", "clientProof": BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)], on: ws)
        let ready = try await receiveBridgeJSON(from: ws)
        XCTAssertEqual(ready["type"] as? String, "ready")
        return (ws, ready)
    }

    /// Answers `reload_extension` with `answer` (nil: no answer), then optionally closes, like chrome.runtime.reload().
    private func respond(on ws: URLSessionWebSocketTask, frames: Frames, answer: [String: Any]?, closeAfterReload: Bool) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: ws) else { break }
                frames.append(obj)
                guard (obj["command"] as? String) == "reload_extension", let id = obj["id"] as? String else { continue }
                if var answer {
                    answer["type"] = "response"
                    answer["id"] = id
                    try? await sendBridgeJSON(answer, on: ws)
                }
                if closeAfterReload {
                    ws.cancel(with: .goingAway, reason: nil)
                    break
                }
            }
        }
    }

    func testHelloVerdictReachesStatusAndReadyFrame() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let (ws, ready) = try await connect(port: port, key: key, version: "0.6.0 beta 2", extensionId: Self.bundledId, origin: "chrome-extension://\(Self.bundledId)")
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let status = try XCTUnwrap(ready["extensionStatus"] as? [String: Any])
        XCTAssertEqual(status["source"] as? String, "app")
        XCTAssertEqual(status["outdated"] as? Bool, true)
        XCTAssertEqual(status["reloadable"] as? Bool, true)
        XCTAssertEqual(status["bundledVersion"] as? String, "0.6.0 beta 3")

        let connected = await waitForBridgeCondition { !bridge.connectedProfiles().isEmpty }
        XCTAssertTrue(connected)
        let profile = try XCTUnwrap(bridge.connectedProfiles().first)
        XCTAssertEqual(profile.extensionId, Self.bundledId)
        XCTAssertEqual(profile.extensionSource, "app")
        XCTAssertEqual(profile.bundledExtensionVersion, "0.6.0 beta 3")
        XCTAssertEqual(profile.extensionOutdated, true)
        XCTAssertEqual(profile.extensionReloadable, true)
        XCTAssertEqual(profile.extensionNote, "Chrome runs extension 0.6.0 beta 2; this app ships 0.6.0 beta 3. Reload the extension to run the new code.")
    }

    /// An extension that predates hello.extensionId is identified from its WebSocket Origin, and is never sent
    /// `reload_extension`: the error tells the user to reload it in chrome://extensions.
    func testOldExtensionIsIdentifiedByOriginAndRefusesReload() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let (ws, _) = try await connect(port: port, key: key, version: "0.5.0", extensionId: nil)
        defer { ws.cancel(with: .goingAway, reason: nil) }
        let frames = Frames()
        let responder = respond(on: ws, frames: frames, answer: ["ok": true], closeAfterReload: false)
        defer { responder.cancel() }

        let connected = await waitForBridgeCondition { !bridge.connectedProfiles().isEmpty }
        XCTAssertTrue(connected)
        let profile = try XCTUnwrap(bridge.connectedProfiles().first)
        XCTAssertEqual(profile.extensionId, "abcdefghijklmnopabcdefghijklmnop")
        XCTAssertEqual(profile.extensionSource, "other_folder")
        XCTAssertEqual(profile.extensionOutdated, true)
        XCTAssertEqual(profile.extensionReloadable, false)

        let outcome = await bridge.reloadExtension()
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.error?.code, "EXTENSION_RELOAD_UNSUPPORTED")
        XCTAssertTrue(outcome.error?.message.contains("chrome://extensions") == true, outcome.error?.message ?? "")
        XCTAssertTrue(outcome.error?.message.contains("v0.5.0") == true, outcome.error?.message ?? "")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(frames.requests("reload_extension").isEmpty)
    }

    func testReloadWaitsForTheExtensionToReconnect() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let (ws, _) = try await connect(port: port, key: key, version: "0.6.0 beta 2", extensionId: Self.bundledId)
        let frames = Frames()
        let responder = respond(on: ws, frames: frames, answer: ["ok": true, "profileName": "Work"], closeAfterReload: true)
        defer { responder.cancel() }
        let connected = await waitForBridgeCondition { !bridge.connectedProfiles().isEmpty }
        XCTAssertTrue(connected)

        // Chrome restarts the extension with the new code, which pairs again.
        let reconnect = Task { () -> URLSessionWebSocketTask? in
            let deadline = Date().addingTimeInterval(5)
            while frames.requests("reload_extension").isEmpty, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            return try? await self.connect(port: port, key: key, version: "0.6.0 beta 3", extensionId: Self.bundledId).0
        }

        let outcome = await bridge.reloadExtension(reconnectTimeoutSeconds: 5)
        let newSocket = await reconnect.value
        defer { newSocket?.cancel(with: .goingAway, reason: nil) }
        XCTAssertTrue(outcome.ok, outcome.error?.message ?? "")
        XCTAssertEqual(outcome.profiles.map(\.extensionVersion), ["0.6.0 beta 3"])
        XCTAssertEqual(outcome.profiles.first?.extensionOutdated, false)
        XCTAssertEqual(frames.requests("reload_extension").count, 1)
        XCTAssertEqual(bridge.connectedProfiles().map(\.extensionVersion), ["0.6.0 beta 3"])
    }

    func testReloadRefusesWhileCommandsRunUnlessForced() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let (ws, _) = try await connect(port: port, key: key, version: "0.6.0 beta 3", extensionId: Self.bundledId)
        defer { ws.cancel(with: .goingAway, reason: nil) }
        let frames = Frames()
        // Never answers `tabs`, so that command stays running; answers the reload but never comes back.
        let responder = respond(on: ws, frames: frames, answer: ["ok": true], closeAfterReload: false)
        defer { responder.cancel() }
        let connected = await waitForBridgeCondition { !bridge.connectedProfiles().isEmpty }
        XCTAssertTrue(connected)

        let running = Task { await bridge.tabs(BrowserTabsParams()) }
        defer { running.cancel() }
        let sent = await waitForBridgeCondition { !frames.requests("tabs").isEmpty }
        XCTAssertTrue(sent)

        let refused = await bridge.reloadExtension(profile: "Work")
        XCTAssertEqual(refused.error?.code, "BROWSER_BUSY")
        XCTAssertTrue(frames.requests("reload_extension").isEmpty)

        let forced = await bridge.reloadExtension(profile: "Work", force: true, reconnectTimeoutSeconds: 0.5)
        XCTAssertEqual(forced.error?.code, "EXTENSION_RELOAD_TIMEOUT")
        XCTAssertEqual(frames.requests("reload_extension").count, 1)
    }

    func testUnknownCommandAnswerMeansUnsupported() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let (ws, _) = try await connect(port: port, key: key, version: "0.6.0 beta 3", extensionId: Self.bundledId)
        defer { ws.cancel(with: .goingAway, reason: nil) }
        let frames = Frames()
        let responder = respond(on: ws, frames: frames, answer: ["ok": false, "error": ["code": "UNKNOWN_COMMAND", "message": "Unknown command: reload_extension"]], closeAfterReload: false)
        defer { responder.cancel() }
        let connected = await waitForBridgeCondition { !bridge.connectedProfiles().isEmpty }
        XCTAssertTrue(connected)

        let outcome = await bridge.reloadExtension()
        XCTAssertEqual(outcome.error?.code, "EXTENSION_RELOAD_UNSUPPORTED")
    }

    /// hello.extensionId is informational: a malformed value pairs anyway, as an extension that cannot reload.
    func testMalformedExtensionIdStillPairs() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let (ws, ready) = try await connect(port: port, key: key, version: "0.6.0 beta 3", extensionId: [String: Any]())
        defer { ws.cancel(with: .goingAway, reason: nil) }
        XCTAssertEqual(ready["type"] as? String, "ready")
        let connected = await waitForBridgeCondition { !bridge.connectedProfiles().isEmpty }
        XCTAssertTrue(connected)
        XCTAssertEqual(bridge.connectedProfiles().first?.extensionReloadable, false)
        XCTAssertEqual(bridge.connectedProfiles().first?.extensionId, "abcdefghijklmnopabcdefghijklmnop")
    }

    func testReloadWithoutExtension() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = makeBridge(keyDir)
        defer { bridge.stop() }
        let outcome = await bridge.reloadExtension()
        XCTAssertEqual(outcome.error?.code, "EXTENSION_NOT_CONNECTED")
    }
}
