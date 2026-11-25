import Foundation
import XCTest
@testable import MacUseEngine
@testable import MacUseProtocol

/// Runs the real `Extension/background.js` in Node (with a stubbed `chrome` API) against the real Swift bridge,
/// so a protocol drift between the two implementations of `docs/BRIDGE-PROTOCOL.md` fails here.
final class BridgeInteropTests: XCTestCase {

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var collected: [String] = []

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    collected.append(line)
                }
            }
            lock.unlock()
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }
    }

    private struct ExtensionProcess {
        let process: Process
        let stdin: Pipe
        let output: LineCollector

        func stop() {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
    }

    private static func locateNode() -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v node"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
        } catch {
            return nil
        }
        shell.waitUntilExit()
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = raw.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static var harnessURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExtensionTests/support/run-background-in-node.cjs")
    }

    private func launchExtension(node: String, port: UInt16, key: String, profile: String) throws -> ExtensionProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [Self.harnessURL.path, String(port), key, profile]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let collector = LineCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data)
            }
        }
        try process.run()
        return ExtensionProcess(process: process, stdin: stdin, output: collector)
    }

    private func makeStartedService() async throws -> (service: MacUseEngineService, keyDir: URL, port: UInt16) {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        let service = MacUseEngineService(
            socketPath: "/tmp/macuse-ut-interop-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.start()
        let port = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(port, 0, "Expected the bridge to bind an ephemeral port")
        return (service, keyDir, port)
    }

    func testRealExtensionAuthenticatesListsTabsAndReceivesCancel() async throws {
        guard let node = Self.locateNode() else {
            throw XCTSkip("Node.js is not installed; the extension interop test needs it.")
        }
        let (service, keyDir, port) = try await makeStartedService()
        defer {
            service.chromeBridge.stop()
            try? FileManager.default.removeItem(at: keyDir)
        }
        let keyText = try XCTUnwrap(service.bridgePairingKeyText())

        let ext = try launchExtension(node: node, port: port, key: keyText, profile: "Interop")
        defer { ext.stop() }

        let listed = await waitForBridgeCondition(timeoutMs: 8000) {
            service.chromeBridge.connectedProfiles().contains { $0.profileName == "Interop" && $0.tabCount == 2 }
        }
        XCTAssertTrue(listed, "The real extension did not complete the handshake. Extension states: \(ext.output.lines)")
        // The harness prints its state on a 25 ms poll, so give the line time to arrive.
        let reportedReady = await waitForBridgeCondition(timeoutMs: 3000) {
            ext.output.lines.contains("STATE connected ready")
        }
        XCTAssertTrue(reportedReady, "Extension states: \(ext.output.lines)")

        // A real command round-trip through the authenticated session: the stubbed Chrome has two tabs.
        let tabsResponse = await service.handle(RPCRequest(method: .browserTabs, browserTabs: BrowserTabsParams()))
        XCTAssertTrue(tabsResponse.ok, "browser_tabs failed: \(tabsResponse.error?.message ?? "")")
        XCTAssertEqual(tabsResponse.browserTabs?.count, 2)
        XCTAssertEqual(tabsResponse.browserTabs?.first?.title, "Interop One")

        // Blocked schemes never reach the extension, and the kill switch blocks reading too.
        let blocked = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "file:///etc/passwd")
        ))
        XCTAssertEqual(blocked.error?.code, "URL_BLOCKED")

        service.tripKillSwitch(true)
        let whileStopped = await service.handle(RPCRequest(method: .browserTabs, browserTabs: BrowserTabsParams()))
        XCTAssertEqual(whileStopped.error?.code, "POLICY_BLOCKED")
        service.tripKillSwitch(false)

        // The session survives a cancel frame and still answers afterwards.
        let afterCancel = await service.handle(RPCRequest(method: .browserTabs, browserTabs: BrowserTabsParams()))
        XCTAssertTrue(afterCancel.ok, "browser_tabs after cancel failed: \(afterCancel.error?.message ?? "")")
    }

    func testRealExtensionWithWrongKeyIsRejectedAndReportsKeyMismatch() async throws {
        guard let node = Self.locateNode() else {
            throw XCTSkip("Node.js is not installed; the extension interop test needs it.")
        }
        let (service, keyDir, port) = try await makeStartedService()
        defer {
            service.chromeBridge.stop()
            try? FileManager.default.removeItem(at: keyDir)
        }
        let wrongKey = BridgeKey.random().text

        let ext = try launchExtension(node: node, port: port, key: wrongKey, profile: "Impostor")
        defer { ext.stop() }

        let mismatch = await waitForBridgeCondition(timeoutMs: 8000) {
            ext.output.lines.contains { $0.hasSuffix(" key_mismatch") }
        }
        XCTAssertTrue(mismatch, "Expected the extension to report key_mismatch. States: \(ext.output.lines)")
        XCTAssertTrue(service.chromeBridge.connectedProfiles().isEmpty)
        XCTAssertFalse(ext.output.lines.contains("STATE connected ready"))
    }

    func testRealExtensionWithoutKeyWaitsForPairing() async throws {
        guard let node = Self.locateNode() else {
            throw XCTSkip("Node.js is not installed; the extension interop test needs it.")
        }
        let (service, keyDir, port) = try await makeStartedService()
        defer {
            service.chromeBridge.stop()
            try? FileManager.default.removeItem(at: keyDir)
        }

        let ext = try launchExtension(node: node, port: port, key: "none", profile: "Fresh")
        defer { ext.stop() }

        let pending = await waitForBridgeCondition(timeoutMs: 8000) {
            service.pendingBrowserPairings().contains("Fresh")
        }
        XCTAssertTrue(pending, "Expected the unpaired profile to be listed as pending. States: \(ext.output.lines)")
        XCTAssertTrue(service.chromeBridge.connectedProfiles().isEmpty)

        let response = await service.handle(RPCRequest(method: .browserTabs, browserTabs: BrowserTabsParams()))
        XCTAssertEqual(response.error?.code, "EXTENSION_NOT_PAIRED")
    }
}
