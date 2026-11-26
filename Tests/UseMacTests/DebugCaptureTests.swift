import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

/// Debug capture lets agents screenshot UseMac's own windows, for developing UseMac. The user must turn it on: these
/// pin that it starts off, that nothing a request carries turns it on, and that while it is off `debug_capture` fails
/// with DEBUG_CAPTURE_OFF without asking for a window or writing a file.
final class DebugCaptureTests: XCTestCase {
    private var suiteNames: [String] = []
    private var tempFolders: [URL] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        for folder in tempFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        suiteNames = []
        tempFolders = []
        super.tearDown()
    }

    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-debug-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "usemac-debug-capture-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usemac-debug-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tempFolders.append(folder)
        return folder
    }

    private func debugFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: UseMacDefaults.captureDirectory)) ?? []
        return Set(names.filter { $0.hasPrefix("debug-") })
    }

    /// Counts how often the engine asks the app for its windows.
    private final class ProviderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func attachSpy(to service: UseMacEngineService) -> ProviderSpy {
        let spy = ProviderSpy()
        service.setDebugCaptureWindowProvider {
            spy.record()
            return [DebugCaptureWindowRef(windowId: 1, kind: .preview, title: "")]
        }
        return spy
    }

    private func decode(_ line: String) throws -> RPCRequest {
        try JSONDecoder().decode(RPCRequest.self, from: Data(line.utf8))
    }

    // MARK: - The gate

    func testANewEngineStartsWithDebugCaptureOff() {
        XCTAssertFalse(makeService().isDebugCaptureEnabled)
        XCTAssertFalse(DebugCaptureGate().isEnabled)
    }

    func testWhileOffEveryRequestIsRefusedAndNothingIsCaptured() async throws {
        let service = makeService()
        let spy = attachSpy(to: service)
        let before = debugFiles()

        let requests = [
            RPCRequest(method: .debugCapture),
            RPCRequest(method: .debugCapture, debugCapture: DebugCaptureParams(window: "preview", frames: 40, intervalMs: 100, context: true)),
            RPCRequest(method: .debugCapture, debugCapture: DebugCaptureParams(window: "nonsense"))
        ]
        for request in requests {
            let response = await service.handle(request)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, "DEBUG_CAPTURE_OFF")
            XCTAssertEqual(response.error?.code, DebugCaptureNotice.offCode)
            XCTAssertEqual(response.error?.hint, DebugCaptureNotice.offHint)
            XCTAssertTrue(response.error?.hint?.contains("Settings → Developer") == true)
            XCTAssertNil(response.debugCapture)
        }

        XCTAssertEqual(spy.calls, 0, "the engine never asks for UseMac's windows while debug capture is off")
        XCTAssertEqual(debugFiles(), before, "no PNG is written")

        let entries = service.recentAuditEntries(limit: 10).filter { $0.method == "debug_capture" }
        XCTAssertEqual(entries.count, requests.count, "every refusal is audited")
        XCTAssertTrue(entries.allSatisfy { !$0.success && $0.summary == "Blocked: Debug capture is off" && $0.targetApp == "UseMac" })
    }

    func testNothingARequestCarriesTurnsItOn() async throws {
        let service = makeService()
        let lines = [
            #"{"method":"debug_capture","debugCapture":{"enabled":true,"window":"preview"},"debugCaptureEnabled":true}"#,
            #"{"method":"debug_capture","debugCapture":{"window":"all"},"enabled":true,"policy":"autonomous"}"#,
            #"{"method":"set_policy","policy":"autonomous","debugCapture":{"enabled":true}}"#,
            #"{"method":"status","debugCaptureEnabled":true}"#
        ]
        for line in lines {
            _ = await service.handle(try decode(line))
            XCTAssertFalse(service.isDebugCaptureEnabled, line)
        }
        let response = await service.handle(try decode(lines[0]))
        XCTAssertEqual(response.error?.code, "DEBUG_CAPTURE_OFF")
    }

    /// Only the app turns it on: from what the user confirmed in Settings (AppState) or saved (StartupSafetyState).
    /// Nothing in the socket server, the MCP server or the CLI may call the setter.
    func testOnlyTheAppTurnsItOn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = [
            "Sources/UseMacEngine/UseMacEngineService+DebugCapture.swift",
            "Sources/UseMacEngine/StartupSafetyState.swift",
            "Sources/UseMacApp/AppState.swift"
        ]
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var callers: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            if text.contains("setDebugCaptureEnabled(") || text.contains("debugCaptureGate.setEnabled(") {
                callers.append("Sources/\(relative)")
            }
        }
        XCTAssertEqual(Set(callers), allowed, "only the app may change Debug capture")
    }

    func testTheKillSwitchAndPauseBlockItFirst() async {
        let service = makeService()
        let spy = attachSpy(to: service)
        service.setDebugCaptureEnabled(true, recordInHistory: false)

        service.tripKillSwitch(true)
        var response = await service.handle(RPCRequest(method: .debugCapture))
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED")
        service.tripKillSwitch(false)

        service.setGovernancePolicy(.paused)
        response = await service.handle(RPCRequest(method: .debugCapture))
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED")

        XCTAssertEqual(spy.calls, 0)
    }

    func testWhileOnAnUnknownWindowIsAnInvalidRequest() async {
        let service = makeService()
        let spy = attachSpy(to: service)
        service.setDebugCaptureEnabled(true, recordInHistory: false)

        let response = await service.handle(RPCRequest(method: .debugCapture, debugCapture: DebugCaptureParams(window: "preview,hud")))
        XCTAssertEqual(response.error?.code, "INVALID_REQUEST")
        XCTAssertTrue(response.error?.message.contains("'hud'") == true)
        XCTAssertEqual(spy.calls, 0)
    }

    /// No window of the kinds asked for is listed (the test process has none): with Screen Recording that is
    /// CAPTURE_FAILED without touching ScreenCaptureKit, without it the permission check refuses first. Either way
    /// nothing is written.
    func testWhileOnNothingListedMeansNothingCaptured() async {
        let service = makeService()
        service.setDebugCaptureEnabled(true, recordInHistory: false)
        service.setDebugCaptureWindowProvider { [DebugCaptureWindowRef(windowId: 1, kind: .report, title: "")] }
        let before = debugFiles()

        let response = await service.handle(RPCRequest(
            method: .debugCapture,
            debugCapture: DebugCaptureParams(window: "settings", frames: 3, intervalMs: 100)
        ))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(["CAPTURE_FAILED", "PERMISSION_DENIED"].contains(response.error?.code ?? ""), "\(String(describing: response.error))")
        if response.error?.code == "CAPTURE_FAILED" {
            XCTAssertTrue(response.error?.message.contains("settings") == true)
            XCTAssertNotNil(response.error?.hint)
        }
        XCTAssertEqual(debugFiles(), before)
    }

    func testTurningItOnOrOffIsRecordedOnceInHistory() {
        let service = makeService()

        service.setDebugCaptureEnabled(true)
        service.setDebugCaptureEnabled(true)
        XCTAssertTrue(service.isDebugCaptureEnabled)
        service.setDebugCaptureEnabled(false)
        service.setDebugCaptureEnabled(true, recordInHistory: false)

        let entries = service.recentAuditEntries(limit: 10).filter { $0.method == DebugCaptureNotice.settingAuditMethod }
        XCTAssertEqual(entries.map(\.summary).sorted(), ["Turned off", "Turned on by the user in Settings"])
        XCTAssertTrue(entries.allSatisfy { AuditEntryKind($0) == .other }, "a setting change, never hidden with the observations")
    }

    // MARK: - Saved at launch

    func testNothingSavedStartsWithDebugCaptureOff() {
        let state = StartupSafetyState.load(from: makeDefaults())
        XCTAssertFalse(state.debugCaptureEnabled)
        XCTAssertEqual(state, .factoryDefault)
        XCTAssertFalse(StartupSafetyState.resolve(savedPolicy: nil, savedPolicyBeforePause: nil, savedKillSwitchTripped: false).debugCaptureEnabled)
    }

    func testTheSavedValueIsRestoredWithoutAHistoryEntry() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: StartupSafetyState.DefaultsKey.debugCaptureEnabled)
        let state = StartupSafetyState.load(from: defaults)
        XCTAssertTrue(state.debugCaptureEnabled)

        let service = makeService()
        state.apply(to: service)
        XCTAssertTrue(service.isDebugCaptureEnabled)
        XCTAssertTrue(service.recentAuditEntries(limit: 10).isEmpty)

        StartupSafetyState.factoryDefault.apply(to: service)
        XCTAssertFalse(service.isDebugCaptureEnabled)
    }

    /// Renaming the key would silently drop the user's choice.
    func testTheDefaultsKeyDoesntChange() {
        XCTAssertEqual(StartupSafetyState.DefaultsKey.debugCaptureEnabled, "usemac.safety.debugCaptureEnabled")
    }

    // MARK: - Options

    func testDefaults() throws {
        let options = try DebugCaptureParams().resolved()
        XCTAssertEqual(options.kinds, DebugCaptureWindowKind.allCases)
        XCTAssertEqual(options.frames, 1)
        XCTAssertEqual(options.intervalMs, 250)
        XCTAssertFalse(options.context)
        XCTAssertEqual(options.contextMargin, 48)
        XCTAssertTrue(options.notes.isEmpty)
        XCTAssertEqual(options.spanMs, 0)
    }

    func testWindowNames() throws {
        XCTAssertEqual(try DebugCaptureParams(window: "preview").resolved().kinds, [.preview])
        XCTAssertEqual(try DebugCaptureParams(window: " Settings , PREVIEW ").resolved().kinds, [.preview, .settings], "any case, any spaces, allCases order")
        XCTAssertEqual(try DebugCaptureParams(window: "preview,preview").resolved().kinds, [.preview])
        XCTAssertEqual(try DebugCaptureParams(window: "").resolved().kinds, DebugCaptureWindowKind.allCases)
        XCTAssertEqual(try DebugCaptureParams(window: "all,preview").resolved().kinds, DebugCaptureWindowKind.allCases)

        let contextOnly = try DebugCaptureParams(window: "context").resolved()
        XCTAssertEqual(contextOnly.kinds, [])
        XCTAssertTrue(contextOnly.context)
        XCTAssertEqual(contextOnly.label, "context")

        let both = try DebugCaptureParams(window: "preview", context: true).resolved()
        XCTAssertEqual(both.kinds, [.preview])
        XCTAssertTrue(both.context)
        XCTAssertEqual(both.label, "preview, context")

        XCTAssertThrowsError(try DebugCaptureParams(window: "preview,hud").resolved()) { error in
            let invalid = error as? DebugCaptureParams.InvalidWindow
            XCTAssertEqual(invalid?.name, "hud")
            for name in ["preview", "settings", "all", "context"] {
                XCTAssertTrue(invalid?.message.contains(name) == true, name)
            }
        }
    }

    func testFramesIntervalAndMarginAreCapped() throws {
        let high = try DebugCaptureParams(frames: 500, intervalMs: 60_000, contextMargin: 10_000).resolved()
        XCTAssertEqual(high.frames, 40)
        XCTAssertEqual(high.intervalMs, 1000)
        XCTAssertEqual(high.contextMargin, 400)
        XCTAssertEqual(high.notes.count, 3, "each change is reported")
        XCTAssertEqual(high.spanMs, 39_000)
        XCTAssertGreaterThan(high.clientTimeoutMs, high.spanMs)

        let low = try DebugCaptureParams(frames: 0, intervalMs: 10, contextMargin: -5).resolved()
        XCTAssertEqual(low.frames, 1)
        XCTAssertEqual(low.intervalMs, 100)
        XCTAssertEqual(low.contextMargin, 0)
        XCTAssertEqual(low.notes, ["frames 0 → 1 (1 to 40)", "interval 10 ms → 100 ms (100 to 1000)", "context margin -5 → 0 pt (0 to 400)"])

        let inRange = try DebugCaptureParams(frames: 12, intervalMs: 100, contextMargin: 0).resolved()
        XCTAssertEqual(inRange.frames, 12)
        XCTAssertEqual(inRange.intervalMs, 100)
        XCTAssertTrue(inRange.notes.isEmpty)
    }

    func testRequestAndResultCoding() throws {
        let request = try decode(#"{"method":"debug_capture","debugCapture":{"window":"preview","frames":12,"intervalMs":100,"context":true,"contextMargin":24}}"#)
        XCTAssertEqual(request.method, .debugCapture)
        XCTAssertEqual(request.debugCapture, DebugCaptureParams(window: "preview", frames: 12, intervalMs: 100, context: true, contextMargin: 24))

        let image = DebugCaptureImage(
            path: "/tmp/debug.png", kind: "preview", title: "", windowId: 42,
            frame: ScreenRect(x: 1, y: 2, width: 3, height: 4), width: 6, height: 8, byteCount: 99, frameIndex: 0, offsetMs: 0
        )
        let result = DebugCaptureResult(window: "preview", frames: 1, intervalMs: 250, directory: "/tmp", images: [image], latencyMs: 5)
        let response = RPCResponse.success(id: "1", latencyMs: 5, debugCapture: result)
        let decoded = try JSONDecoder().decode(RPCResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.debugCapture, result)
    }

    func testCopyingToAnOutFolderNeverReplacesAFile() throws {
        let source = try makeTempFolder()
        let out = try makeTempFolder().appendingPathComponent("frames/deeper", isDirectory: true)
        let png = source.appendingPathComponent("debug-1-00-preview-7.png")
        try Data("first".utf8).write(to: png)
        let image = DebugCaptureImage(
            path: png.path, kind: "preview", title: nil, windowId: 7,
            frame: ScreenRect(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1, byteCount: 5, frameIndex: 0, offsetMs: 0
        )
        let result = DebugCaptureResult(window: "preview", frames: 1, intervalMs: 250, directory: source.path, images: [image], latencyMs: 1)

        let first = try result.copied(to: out.path)
        XCTAssertEqual(first.directory, out.standardizedFileURL.path)
        XCTAssertEqual(first.images[0].path, out.appendingPathComponent(png.lastPathComponent).standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.images[0].path))

        let second = try result.copied(to: out.path)
        XCTAssertEqual((second.images[0].path as NSString).lastPathComponent, "debug-1-00-preview-7-2.png")
        XCTAssertEqual(try String(contentsOfFile: first.images[0].path, encoding: .utf8), "first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "the original stays")
    }

    // MARK: - Capturing helpers

    func testContextRegionIsThePreviewPlusTheMarginOnItsDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(
            DebugCaptureCapturer.contextRegion(windowFrame: CGRect(x: 100, y: 100, width: 300, height: 200), margin: 48, displayFrame: display),
            CGRect(x: 52, y: 52, width: 396, height: 296)
        )
        // At the bottom-right corner the region stops at the display's edge.
        XCTAssertEqual(
            DebugCaptureCapturer.contextRegion(windowFrame: CGRect(x: 1126, y: 676, width: 300, height: 210), margin: 48, displayFrame: display),
            CGRect(x: 1078, y: 628, width: 362, height: 272)
        )
        XCTAssertEqual(
            DebugCaptureCapturer.contextRegion(windowFrame: CGRect(x: 10, y: 10, width: 20, height: 20), margin: -8, displayFrame: display),
            CGRect(x: 10, y: 10, width: 20, height: 20)
        )
    }

    func testPNGsKeepTransparencyAndNeverReplaceAFile() throws {
        let width = 4, height = 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Left half opaque red, right half fully transparent.
        for y in 0..<height {
            for x in 0..<(width / 2) {
                let i = (y * width + x) * 4
                pixels[i] = 255
                pixels[i + 3] = 255
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let path = try makeTempFolder().appendingPathComponent("debug-test.png").path

        let bytes = try XCTUnwrap(DebugCaptureCapturer.writePNG(image, to: path))
        XCTAssertGreaterThan(bytes, 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyHasAlpha] as? Bool, true)

        let read = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let readContext = try XCTUnwrap(CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        readContext.draw(read, in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertEqual(rgba[3], 255, "the opaque half stays opaque")
        XCTAssertEqual(rgba[(width - 1) * 4 + 3], 0, "the transparent half stays transparent")

        XCTAssertNil(DebugCaptureCapturer.writePNG(image, to: path), "an existing file is never replaced")
    }

    func testTheAuditSummaryNamesKindsNotTitles() {
        func image(_ kind: String, title: String?) -> DebugCaptureImage {
            DebugCaptureImage(
                path: "/tmp/x.png", kind: kind, title: title, windowId: nil,
                frame: ScreenRect(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1, byteCount: 1, frameIndex: 0, offsetMs: 0
            )
        }
        let result = DebugCaptureResult(
            window: "preview, settings, context", frames: 3, intervalMs: 100, directory: "/tmp",
            images: [image("context", title: nil), image("settings", title: "Secret project – UseMac"), image("preview", title: "")],
            latencyMs: 1
        )
        let summary = UseMacEngineService.debugCaptureSummary(result)
        XCTAssertEqual(summary, "Captured 3 PNG(s) of preview, settings, context (3 frames, 100 ms apart)")
        XCTAssertFalse(summary.contains("Secret"))
    }

    // MARK: - History and hints

    func testHistoryFilesCapturesWithTheObservations() {
        XCTAssertEqual(AuditEntryKind(method: "debug_capture"), .observation)
        XCTAssertEqual(AuditEntryKind(method: DebugCaptureNotice.settingAuditMethod), .other)

        func entry(_ second: Int64, success: Bool = true, summary: String = "Captured 1 PNG(s) of preview (1 frame)") -> AuditEntry {
            AuditEntry(timestampMs: 1_764_115_303_000 + second * 1000, method: "debug_capture", targetApp: "UseMac", summary: summary, latencyMs: 40, success: success, taskId: nil)
        }
        let newestFirst = [
            entry(4), entry(3), entry(2),
            entry(1, success: false, summary: "Blocked: Debug capture is off"),
            entry(0, success: false, summary: "Blocked: Debug capture is off")
        ]
        let runs = AuditLogFolding.fold(newestFirst)
        XCTAssertEqual(runs.map(\.count), [3, 2])
        XCTAssertEqual(runs.map(\.kind), [.observation, .observation])
        XCTAssertEqual(runs.map(\.representative.success), [true, false])
    }

    func testClientsTellAgentsToAskTheUser() {
        let hint = UseMacErrorGuide.hint(for: "DEBUG_CAPTURE_OFF")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("Settings → Developer") == true)
        XCTAssertTrue(hint?.contains("Only they can turn it on") == true)
    }
}
