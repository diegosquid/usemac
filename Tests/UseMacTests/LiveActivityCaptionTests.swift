import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Checks the live preview captions the engine emits for real failures in TextEdit (what the HUD's pill shows).
/// Skipped unless USEMAC_LIVE_TESTS=1, because it needs Accessibility permission and opens a TextEdit window. It never
/// sends real input, never edits the document, and closes its window afterwards.
final class LiveActivityCaptionTests: XCTestCase {
    private var service: UseMacEngineService!
    private var startedTextEdit = false
    private var fixture: URL?
    private let collected = ActivityCollector()

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["USEMAC_LIVE_TESTS"] == "1", "Set USEMAC_LIVE_TESTS=1 to run live Accessibility tests.")
        try XCTSkipUnless(AXIsProcessTrusted(), "This process needs Accessibility permission.")
        service = UseMacEngineService(socketPath: "/tmp/usemac-live-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
        let collector = collected
        service.onLiveActivity = { item in collector.append(item) }
    }

    override func tearDown() async throws {
        if let fixture {
            closeTextEditWindow(titled: fixture.lastPathComponent)
            try? FileManager.default.removeItem(at: fixture)
        }
        if startedTextEdit, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first {
            app.terminate()
        }
        service = nil
    }

    // MARK: - Tests

    func testFailedClickNamesTheStepAndWhy() async throws {
        try await openFixtureDocument()
        let name = "No such button \(UUID().uuidString.prefix(4))"
        collected.reset()
        let result = try await act([ActionStep(action: .click, match: ElementMatch(role: "AXButton", title: name))])
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "ELEMENT_NOT_FOUND")

        let complete = try XCTUnwrap(collected.last(.actionComplete))
        XCTAssertFalse(complete.success)
        XCTAssertFalse(complete.isInProgress)
        XCTAssertEqual(complete.title, "Couldn't click “\(name)”")
        XCTAssertEqual(complete.subtitle, "couldn't find it on screen")
        XCTAssertEqual(ActivityCaption.mark(isInProgress: complete.isInProgress, success: complete.success, agentBusy: true, stopped: false), .failed)

        let step = try XCTUnwrap(collected.last(.actionStep))
        XCTAssertEqual(step.title, "Couldn't click “\(name)”", "The step caption must not say 'Clicked' for a click that never happened")
        XCTAssertEqual(step.subtitle, "couldn't find it on screen")
    }

    func testRefusedBatchSaysNothingRan() async throws {
        try await openFixtureDocument()
        collected.reset()
        let response = await service.handle(RPCRequest(id: UUID().uuidString, method: .act, act: BatchActionRequest(
            app: "TextEdit",
            steps: [ActionStep(action: .scroll, deltaY: -200, match: ElementMatch(role: "AXTextArea"))],
            returnObservation: false,
            expectWindowTitle: "a title no window has \(UUID().uuidString.prefix(4))"
        )))
        let result = try XCTUnwrap(response.actionResult)
        XCTAssertEqual(result.stepResults.first?.errorCode, "STALE_SNAPSHOT")

        let complete = try XCTUnwrap(collected.last(.actionComplete))
        XCTAssertEqual(complete.title, "Didn't run the step")
        XCTAssertEqual(complete.subtitle, "the window changed since the last look")
        let refusal = try XCTUnwrap(collected.last(.policyOrSafety))
        XCTAssertEqual(refusal.title, "Didn't run the step")
    }

    func testRealInputRefusalSaysTheAppMustBeInFront() async throws {
        try await openFixtureDocument()
        try XCTSkipIf(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit", "TextEdit is in front; this test needs another app in front.")
        collected.reset()
        let result = try await act([ActionStep(action: .hover, preferBackground: false, match: ElementMatch(role: "AXTextArea"))])
        XCTAssertEqual(result.stepResults.first?.errorCode, "TARGET_NOT_FRONTMOST")
        let complete = try XCTUnwrap(collected.last(.actionComplete))
        XCTAssertEqual(complete.title, "Couldn't hover")
        XCTAssertEqual(complete.subtitle, "needs the app in front")
    }

    func testSuccessfulBatchCaptionIsUnchanged() async throws {
        try await openFixtureDocument()
        collected.reset()
        let result = try await act([ActionStep(action: .scroll, deltaY: -300, match: ElementMatch(role: "AXTextArea"))])
        XCTAssertTrue(result.success, result.stepResults.first?.message ?? "")
        let complete = try XCTUnwrap(collected.last(.actionComplete))
        XCTAssertTrue(complete.success)
        XCTAssertEqual(complete.title, "Finished 1 step")
    }

    // MARK: - Helpers

    private func act(_ steps: [ActionStep]) async throws -> BatchActionResult {
        let response = await service.handle(RPCRequest(id: UUID().uuidString, method: .act, act: BatchActionRequest(
            app: "TextEdit", steps: steps, returnObservation: false, allowStaleSnapshot: true
        )))
        return try XCTUnwrap(response.actionResult, response.error?.message ?? "no action result")
    }

    /// Opens a small text file of this test's own in TextEdit, in the background.
    private func openFixtureDocument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usemac-live-captions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("usemac-caption-\(UUID().uuidString.prefix(6)).txt")
        try (1...60).map { "Line \($0) of the UseMac caption test." }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        fixture = file
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty {
            startedTextEdit = true
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: config)
        for _ in 0..<40 {
            let response = await service.handle(RPCRequest(id: UUID().uuidString, method: .observe, observe: ObserveParams(
                app: "TextEdit", maxDepth: 30, maxElements: 300, useCache: false, window: file.lastPathComponent
            )))
            if response.snapshot?.elements.contains(where: { $0.role == "AXTextArea" }) == true { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("TextEdit did not show the fixture document")
    }

    /// Presses the close button of this test's window (the document was never edited, so no save sheet appears).
    private func closeTextEditWindow(titled title: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard (titleRef as? String) == title else { continue }
            var closeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeRef) == .success, let closeRef {
                AXUIElementPerformAction(closeRef as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }
}

/// Collects the live activities an in-process engine emits.
private final class ActivityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LiveActivityItem] = []

    func append(_ item: LiveActivityItem) {
        lock.lock(); items.append(item); lock.unlock()
    }

    func reset() {
        lock.lock(); items.removeAll(); lock.unlock()
    }

    func last(_ kind: LiveActivityKind) -> LiveActivityItem? {
        lock.lock(); defer { lock.unlock() }
        return items.last { $0.kind == kind }
    }
}
