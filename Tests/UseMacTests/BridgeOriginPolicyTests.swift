import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// The store build must pair exactly like the unpacked one (issue #7): the Origin check is the only place the
/// extension ID matters.
final class BridgeOriginPolicyTests: XCTestCase {
    private let storeId = "abcdefghijklmnopabcdefghijklmnop"
    private let bundledId = "cjmjpbjmbbokoknjmnppdcifkeaaapca"
    private let repoFolderId = "ponmlkjihgfedcbaponmlkjihgfedcba"

    func testOriginParsing() {
        XCTAssertEqual(BridgeOriginPolicy.extensionId(fromOrigin: "chrome-extension://\(storeId)"), storeId)
        XCTAssertEqual(BridgeOriginPolicy.extensionId(fromOrigin: " CHROME-EXTENSION://\(storeId.uppercased())/popup.html "), storeId)
        XCTAssertNil(BridgeOriginPolicy.extensionId(fromOrigin: "chrome-extension://"))
        XCTAssertNil(BridgeOriginPolicy.extensionId(fromOrigin: "https://evil.example.com"))
        XCTAssertNil(BridgeOriginPolicy.extensionId(fromOrigin: ""))
    }

    func testBetaBuildWithoutStoreIdAcceptsAnyExtension() {
        let allowed = BridgeOriginPolicy.allowedExtensionIds(environment: [:], defaultsIds: [], webStoreId: nil, bundledUnpackedId: bundledId)
        XCTAssertTrue(allowed.isEmpty, "No store ID and no allowlist: every chrome-extension:// origin may try to pair")
    }

    func testStoreBuildAcceptsTheStoreIdAndTheAppsOwnUnpackedFolder() {
        let allowed = BridgeOriginPolicy.allowedExtensionIds(
            environment: [:],
            defaultsIds: [],
            webStoreId: " \(storeId.uppercased())\n",
            bundledUnpackedId: bundledId
        )
        XCTAssertEqual(allowed, [storeId, bundledId])
        // A copy loaded from another folder (a repo checkout) needs USEMAC_ALLOWED_EXTENSION_IDS.
        XCTAssertFalse(allowed.contains(repoFolderId))

        let withRepo = BridgeOriginPolicy.allowedExtensionIds(
            environment: ["USEMAC_ALLOWED_EXTENSION_IDS": " \(repoFolderId) , ,"],
            defaultsIds: [],
            webStoreId: storeId,
            bundledUnpackedId: bundledId
        )
        XCTAssertEqual(withRepo, [storeId, bundledId, repoFolderId])
    }

    func testDefaultsIdsWidenAStoreBuildButNeverTurnTheCheckOn() {
        let widened = BridgeOriginPolicy.allowedExtensionIds(
            environment: [:],
            defaultsIds: [" \(repoFolderId.uppercased()) ", ""],
            webStoreId: storeId,
            bundledUnpackedId: bundledId
        )
        XCTAssertEqual(widened, [storeId, bundledId, repoFolderId])

        let beta = BridgeOriginPolicy.allowedExtensionIds(
            environment: [:],
            defaultsIds: [repoFolderId],
            webStoreId: nil,
            bundledUnpackedId: bundledId
        )
        XCTAssertTrue(beta.isEmpty, "A build without a store ID keeps accepting any extension")
    }

    func testDefaultsIdsReadAnArrayOrACommaSeparatedString() throws {
        let suite = "usemac-origin-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(BridgeOriginPolicy.defaultsExtensionIds(defaults), [])
        defaults.set([repoFolderId, 42, storeId], forKey: BridgeOriginPolicy.allowedIdsDefaultsKey)
        XCTAssertEqual(BridgeOriginPolicy.defaultsExtensionIds(defaults), [repoFolderId, storeId])
        defaults.set("\(repoFolderId), \(storeId)", forKey: BridgeOriginPolicy.allowedIdsDefaultsKey)
        XCTAssertEqual(
            BridgeOriginPolicy.allowedExtensionIds(
                environment: [:],
                defaultsIds: BridgeOriginPolicy.defaultsExtensionIds(defaults),
                webStoreId: storeId,
                bundledUnpackedId: nil
            ),
            [repoFolderId, storeId]
        )
    }

    func testStoreBuildRunningOutsideTheAppBundleAcceptsOnlyTheStoreId() {
        let allowed = BridgeOriginPolicy.allowedExtensionIds(environment: [:], defaultsIds: [], webStoreId: storeId, bundledUnpackedId: nil)
        XCTAssertEqual(allowed, [storeId])
    }

    func testAllowlistWithoutStoreIdStillTrustsTheBundledFolder() {
        let allowed = BridgeOriginPolicy.allowedExtensionIds(
            environment: ["USEMAC_ALLOWED_EXTENSION_IDS": repoFolderId],
            defaultsIds: [],
            webStoreId: nil,
            bundledUnpackedId: bundledId
        )
        XCTAssertEqual(allowed, [repoFolderId, bundledId])
    }

    func testUnpackedIdMatchesChromeForTheAppFolder() throws {
        // printf '<path>' | shasum -a 256 | cut -c1-32 | tr 0-9a-f a-p
        XCTAssertEqual(
            BridgeOriginPolicy.unpackedExtensionId(forFolder: "/Applications/UseMac.app/Contents/Resources/chrome-extension"),
            bundledId
        )

        // Chrome hashes realpath(3): a folder reached through a symlink gets the real folder's ID.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usemac-origin-\(UUID().uuidString)")
        let real = root.appendingPathComponent("Real/chrome-extension")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Real"))
        XCTAssertEqual(
            BridgeOriginPolicy.unpackedExtensionId(forFolder: link.appendingPathComponent("chrome-extension").path),
            BridgeOriginPolicy.unpackedExtensionId(forFolder: real.path)
        )
    }

    func testStoreBuildPairsTheStoreExtensionAndRefusesOtherExtensions() async throws {
        let restore = Self.setEnvironment([
            "USEMAC_CHROME_EXTENSION_ID": storeId,
            "USEMAC_ALLOWED_EXTENSION_IDS": nil
        ])
        defer { restore() }
        XCTAssertEqual(UseMacDefaults.chromeWebStoreExtensionId, storeId)
        XCTAssertEqual(UseMacDefaults.chromeWebStoreListingURL?.absoluteString, "https://chromewebstore.google.com/detail/\(storeId)")

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Another extension (or an unpacked copy from another folder) never reaches the handshake.
        let otherWs = try openMockExtensionSocket(port: port, origin: "chrome-extension://\(repoFolderId)", session: session)
        do {
            try await sendBridgeJSON([
                "type": "hello",
                "protocol": 2,
                "clientNonce": BridgeAuth.randomNonceHex(),
                "hasKey": true
            ], on: otherWs)
            _ = try await otherWs.receive()
            XCTFail("Expected the WebSocket upgrade from an extension that isn't the store one to be rejected")
        } catch {
            // Expected rejection
        }
        otherWs.cancel()
        XCTAssertTrue(bridge.connectedProfiles().isEmpty)

        // The store install (Origin chrome-extension://<store ID>) runs the same handshake as an unpacked one.
        let storeWs = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "StoreInstall")
        defer { storeWs.cancel(with: .goingAway, reason: nil) }
        let connected = await waitForBridgeCondition {
            bridge.connectedProfiles().first?.profileName == "StoreInstall"
        }
        XCTAssertTrue(connected)
    }

    func testStoreBuildLetsTheUserAllowARepoCopyThroughTheAppDefaults() async throws {
        let restore = Self.setEnvironment([
            "USEMAC_CHROME_EXTENSION_ID": storeId,
            "USEMAC_ALLOWED_EXTENSION_IDS": nil
        ])
        defer { restore() }
        // The argument domain is in memory only, and the app reads UserDefaults.standard on every upgrade.
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }
        let port = await waitForListeningPort(of: bridge)
        XCTAssertNotEqual(port, 0)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        func reachesTheHandshake() async -> Bool {
            guard let ws = try? openMockExtensionSocket(port: port, origin: "chrome-extension://\(repoFolderId)", session: session) else {
                return false
            }
            defer { ws.cancel() }
            do {
                try await sendBridgeJSON([
                    "type": "hello",
                    "protocol": 2,
                    "clientNonce": BridgeAuth.randomNonceHex(),
                    "hasKey": true
                ], on: ws)
                return try await receiveBridgeJSON(from: ws)["type"] as? String == "challenge"
            } catch {
                return false
            }
        }

        let refusedByDefault = await reachesTheHandshake()
        XCTAssertFalse(refusedByDefault, "A repo copy is refused on a store build by default")
        var arguments = previousArguments
        arguments[BridgeOriginPolicy.allowedIdsDefaultsKey] = [repoFolderId]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let allowedByUser = await reachesTheHandshake()
        XCTAssertTrue(allowedByUser, "usemac.bridge.allowedExtensionIds lets the user's repo copy pair")
    }

    func testListingURLNeedsAValidStoreId() {
        let restore = Self.setEnvironment(["USEMAC_CHROME_EXTENSION_ID": "not-an-id"])
        defer { restore() }
        XCTAssertEqual(UseMacDefaults.chromeWebStoreExtensionId, "not-an-id")
        XCTAssertNil(UseMacDefaults.chromeWebStoreListingURL)
    }

    /// Sets (or, for nil, unsets) environment variables and returns a closure that puts the old values back.
    private static func setEnvironment(_ values: [String: String?]) -> () -> Void {
        var previous: [String: String?] = [:]
        for (name, value) in values {
            previous[name] = ProcessInfo.processInfo.environment[name]
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        return {
            for (name, value) in previous {
                if let value {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
        }
    }
}
