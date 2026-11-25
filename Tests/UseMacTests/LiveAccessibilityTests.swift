import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Drives real apps through the engine. Skipped unless USEMAC_LIVE_TESTS=1, because it needs Accessibility
/// permission and opens TextEdit windows. It never sends real input to the app in front.
final class LiveAccessibilityTests: XCTestCase {
    private var service: UseMacEngineService!
    private var startedTextEdit = false
    private var fixtureDir: URL!
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["USEMAC_LIVE_TESTS"] == "1", "Set USEMAC_LIVE_TESTS=1 to run live Accessibility tests.")
        try XCTSkipUnless(AXIsProcessTrusted(), "This process needs Accessibility permission.")
        service = UseMacEngineService(socketPath: "/tmp/usemac-live-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)

        // A Spotlight-indexed folder (dist/ is git-ignored) so the open panel search can find the fixture.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        fixtureDir = root.appendingPathComponent("dist/live-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defer {
            for file in createdFiles {
                try? FileManager.default.removeItem(at: file)
            }
            createdFiles = []
        }
        if startedTextEdit, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first {
            app.terminate()
        }
        service = nil
    }

    private func call(_ request: RPCRequest) async -> RPCResponse {
        await service.handle(request)
    }

    private func act(_ steps: [ActionStep], app: String = "TextEdit", foreground: Bool? = nil, allowStale: Bool? = nil) async -> BatchActionResult? {
        let response = await call(RPCRequest(id: UUID().uuidString, method: .act, act: BatchActionRequest(
            app: app, steps: steps, returnObservation: false, allowStaleSnapshot: allowStale, foreground: foreground
        )))
        return response.actionResult
    }

    private func observe(_ app: String = "TextEdit") async -> WindowSnapshot? {
        let response = await call(RPCRequest(id: UUID().uuidString, method: .observe, observe: ObserveParams(app: app, maxDepth: 40, maxElements: 600, useCache: false)))
        return response.snapshot
    }

    private func requireObserve(_ app: String = "TextEdit") async throws -> WindowSnapshot {
        let snapshot = await observe(app)
        return try XCTUnwrap(snapshot)
    }

    private func requireAct(_ steps: [ActionStep], app: String = "TextEdit", allowStale: Bool? = nil) async throws -> BatchActionResult {
        let result = await act(steps, app: app, allowStale: allowStale)
        return try XCTUnwrap(result)
    }

    /// Opens a long text document in TextEdit without bringing it to the front.
    private func openFixtureDocument() async throws -> URL {
        let file = fixtureDir.appendingPathComponent("usemac-live-\(UUID().uuidString.prefix(6)).txt")
        let lines = (1...400).map { "Line \($0) of the UseMac live test document." }.joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        createdFiles.append(file)
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty {
            startedTextEdit = true
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: config)
        for _ in 0..<40 {
            if let snapshot = await observe(), snapshot.elements.contains(where: { $0.role == "AXTextArea" }) {
                return file
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("TextEdit did not show the fixture document")
        return file
    }

    func testStableIdsAcrossObserves() async throws {
        _ = try await openFixtureDocument()
        let first = try await requireObserve()
        let second = try await requireObserve()
        let firstArea = try XCTUnwrap(first.elements.first { $0.role == "AXTextArea" })
        let secondArea = try XCTUnwrap(second.elements.first { $0.role == "AXTextArea" })
        XCTAssertEqual(firstArea.id, secondArea.id, "The same element must keep its id across observes")
        XCTAssertNotNil(first.app.windowId, "Observe should report the exact window id")
    }

    func testWindowPinTargetsAnUnfocusedWindow() async throws {
        let first = try await openFixtureDocument()
        let second = try await openFixtureDocument()
        // TextEdit focuses the last opened document; pin the other one by title.
        let pinnedName = first.lastPathComponent
        let response = await call(RPCRequest(method: .observe, observe: ObserveParams(app: "TextEdit", maxDepth: 30, maxElements: 300, useCache: false, window: pinnedName)))
        let snapshot = try XCTUnwrap(response.snapshot, response.error?.message ?? "no snapshot")
        let window = try XCTUnwrap(snapshot.elements.first { $0.role == "AXWindow" })
        XCTAssertEqual(window.title, pinnedName)

        // Acts without `window` keep using the pinned window.
        let result = try await requireAct([ActionStep(action: .setValue, text: "pinned", match: ElementMatch(role: "AXTextArea"))])
        XCTAssertTrue(result.success)
        let check = await call(RPCRequest(method: .observe, observe: ObserveParams(app: "TextEdit", maxDepth: 30, maxElements: 300, useCache: false, window: pinnedName)))
        XCTAssertEqual(check.snapshot?.elements.first { $0.role == "AXTextArea" }?.value, "pinned")

        // An unknown window is an error, and observing without `window` goes back to the focused window.
        let missing = await call(RPCRequest(method: .observe, observe: ObserveParams(app: "TextEdit", window: "no such window \(UUID().uuidString)")))
        XCTAssertEqual(missing.error?.code, "ELEMENT_NOT_FOUND")
        let focused = await call(RPCRequest(method: .observe, observe: ObserveParams(app: "TextEdit", maxDepth: 30, maxElements: 300, useCache: false)))
        XCTAssertEqual(focused.snapshot?.elements.first { $0.role == "AXWindow" }?.title, second.lastPathComponent)
    }

    func testMatchSetValueReportsChange() async throws {
        _ = try await openFixtureDocument()
        let result = try await requireAct([
            ActionStep(action: .setValue, text: "Hello from match", match: ElementMatch(role: "AXTextArea"))
        ])
        let step = try XCTUnwrap(result.stepResults.first)
        XCTAssertTrue(step.success, step.message ?? "")
        XCTAssertEqual(step.mechanism, "ax-set-value")
        XCTAssertEqual(step.effect, .changed)
        XCTAssertNotNil(step.resolvedElementId)
    }

    func testBackgroundScrollMovesContent() async throws {
        _ = try await openFixtureDocument()
        _ = await observe()
        let result = try await requireAct([
            ActionStep(action: .scroll, deltaY: -600, match: ElementMatch(role: "AXTextArea"))
        ])
        let step = try XCTUnwrap(result.stepResults.first)
        XCTAssertTrue(step.success, step.message ?? "")
        XCTAssertEqual(step.mechanism, "ax-scrollbar", "Native scroll views scroll through their scroll bar")
        XCTAssertEqual(step.effect, .changed, "Background scroll should move TextEdit's content (\(step.warning ?? "no warning"))")
        XCTAssertLessThan(step.scrollDeltaY ?? 0, 0, "Scrolling down moves the content up")
    }

    func testWaitForAppearsAndGone() async throws {
        _ = try await openFixtureDocument()
        let result = try await requireAct([
            ActionStep(action: .waitFor, match: ElementMatch(role: "AXTextArea"), timeoutMs: 2000),
            ActionStep(action: .waitFor, match: ElementMatch(title: "no such element \(UUID().uuidString)"), timeoutMs: 500, gone: true),
            ActionStep(action: .waitFor, match: ElementMatch(title: "no such element \(UUID().uuidString)"), timeoutMs: 400)
        ], allowStale: true)
        let steps = result.stepResults
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].success)
        XCTAssertTrue(steps[1].success)
        XCTAssertFalse(steps[2].success)
        XCTAssertEqual(steps[2].errorCode, "WAIT_TIMEOUT")
    }

    func testRealInputIsRefusedWhenTargetIsNotInFront() async throws {
        _ = try await openFixtureDocument()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        try XCTSkipIf(frontmost == "com.apple.TextEdit", "TextEdit is in front; this test needs another app in front.")
        let cursorBefore = CGEvent(source: nil)?.location
        let result = try await requireAct([
            ActionStep(action: .hover, preferBackground: false, match: ElementMatch(role: "AXTextArea"))
        ])
        let step = try XCTUnwrap(result.stepResults.first)
        XCTAssertFalse(step.success)
        XCTAssertEqual(step.errorCode, "TARGET_NOT_FRONTMOST")
        XCTAssertEqual(CGEvent(source: nil)?.location, cursorBefore, "The cursor must not move")
    }

    func testUnknownMatchIsReported() async throws {
        _ = try await openFixtureDocument()
        let result = try await requireAct([
            ActionStep(action: .click, match: ElementMatch(role: "AXButton", title: "Definitely not here \(UUID().uuidString)"))
        ])
        XCTAssertEqual(result.stepResults.first?.errorCode, "ELEMENT_NOT_FOUND")
    }

    private func waitForSpotlight(_ file: URL, timeoutSeconds: Int) async -> Bool {
        for _ in 0..<(timeoutSeconds * 2) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-name", file.lastPathComponent]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains(file.lastPathComponent) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    func testOpenPanelPicksFileWithoutFocus() async throws {
        _ = try await openFixtureDocument()
        let target = fixtureDir.appendingPathComponent("usemac-pick-\(UUID().uuidString.prefix(6)).txt")
        try "picked".write(to: target, atomically: true, encoding: .utf8)
        createdFiles.append(target)
        // The background path searches the picker by name, which is Spotlight: wait until the file is indexed
        // (fresh files can take a while), as a real download or export would be.
        let indexed = await waitForSpotlight(target, timeoutSeconds: 90)
        try XCTSkipUnless(indexed, "Spotlight did not index the fixture in time.")

        // Open File > Open… through the menu bar (AX only, no keys).
        let pid = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.processIdentifier)
        let app = AXUIElementCreateApplication(pid)
        let openItem = try XCTUnwrap(ActionExecutor.firstDescendant(of: app, maxDepth: 6) { element in
            ActionExecutor.axString(element, kAXRoleAttribute) == "AXMenuItem"
                && (ActionExecutor.axString(element, kAXTitleAttribute)?.hasPrefix("Open") == true
                    || ActionExecutor.axString(element, kAXTitleAttribute)?.hasPrefix("Abrir") == true)
                && ActionExecutor.axString(element, kAXTitleAttribute)?.contains("Recent") != true
                && ActionExecutor.axString(element, kAXTitleAttribute)?.contains("Recente") != true
        })
        XCTAssertEqual(AXUIElementPerformAction(openItem, kAXPressAction as CFString), .success)

        let result = try await requireAct([
            ActionStep(action: .uploadFile, files: [target.path])
        ])
        let step = try XCTUnwrap(result.stepResults.first)
        XCTAssertTrue(step.success, "\(step.mechanism): \(step.message ?? "")")
        XCTAssertTrue(step.mechanism.hasPrefix("nsopenpanel-search") || step.mechanism == "nsopenpanel-navigate", step.mechanism)

        var opened = false
        for _ in 0..<30 {
            let windows = ActionExecutor.axChildren(app, attribute: kAXWindowsAttribute)
            if windows.contains(where: { ActionExecutor.axString($0, kAXTitleAttribute)?.contains(target.lastPathComponent) == true }) {
                opened = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(opened, "TextEdit should open the picked file")
    }
}
