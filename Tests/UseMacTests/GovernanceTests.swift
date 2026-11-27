import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

final class GovernanceTests: XCTestCase {

    private func makeService(prefix: String = "usemac-gov") -> UseMacEngineService {
        UseMacEngineService(
            socketPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0
        )
    }

    private func blockedReadRequests() -> [(name: String, request: RPCRequest)] {
        [
            ("list_apps", RPCRequest(method: .listApps)),
            ("observe", RPCRequest(method: .observe, observe: ObserveParams())),
            ("screenshot", RPCRequest(method: .screenshot, screenshot: ScreenshotRequest())),
            ("pair_app", RPCRequest(method: .pairApp, appTarget: "Finder")),
            ("highlight", RPCRequest(method: .highlight, elementId: "@e1")),
            ("browser_tabs", RPCRequest(method: .browserTabs, browserTabs: BrowserTabsParams())),
            ("browser_observe", RPCRequest(method: .browserObserve, browserObserve: BrowserObserveParams())),
            ("browser_extract", RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "text"))),
            ("browser_screenshot", RPCRequest(method: .browserScreenshot, browserScreenshot: BrowserScreenshotParams())),
            ("vision_query", RPCRequest(method: .visionQuery, visionQuery: VisionQueryParams(mode: "ask", query: "status")))
        ]
    }

    private func alwaysAllowedRequests() -> [(name: String, request: RPCRequest)] {
        [
            ("ping", RPCRequest(method: .ping)),
            ("status", RPCRequest(method: .status)),
            ("audit_log", RPCRequest(method: .auditLog)),
            ("browser_status", RPCRequest(method: .browserStatus)),
            ("vision_status", RPCRequest(method: .visionStatus)),
            ("task_start", RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "check"))),
            ("task_complete", RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(summary: "done")))
        ]
    }

    func testKillSwitchBlocksReadMethods() async {
        final class ActivityCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [LiveActivityItem] = []

            func append(_ item: LiveActivityItem) {
                lock.lock()
                items.append(item)
                lock.unlock()
            }

            func snapshot() -> [LiveActivityItem] {
                lock.lock()
                defer { lock.unlock() }
                return items
            }
        }

        let service = makeService(prefix: "usemac-gov-ks")
        let collector = ActivityCollector()
        service.onLiveActivity = { item in
            collector.append(item)
        }

        service.tripKillSwitch(true)

        for (name, req) in blockedReadRequests() {
            let res = await service.handle(req)
            XCTAssertFalse(res.ok, "Expected \(name) to be blocked while kill switch is tripped")
            XCTAssertEqual(res.error?.code, "POLICY_BLOCKED", "Unexpected error code for \(name)")
            let latestAudit = service.recentAuditEntries(limit: 1).first
            XCTAssertEqual(latestAudit?.success, false, "Expected failed audit entry for \(name)")
            XCTAssertTrue(
                latestAudit?.summary.hasPrefix("Blocked: ") == true,
                "Expected 'Blocked: ' audit summary for \(name), got \(latestAudit?.summary ?? "<nil>")"
            )
        }

        let safetyActivities = collector.snapshot().filter {
            $0.kind == .policyOrSafety && !$0.success && !$0.isInProgress
        }
        XCTAssertGreaterThanOrEqual(safetyActivities.count, blockedReadRequests().count)

        for (name, req) in alwaysAllowedRequests() {
            let res = await service.handle(req)
            XCTAssertTrue(res.ok, "Expected \(name) to remain allowed while kill switch is tripped: \(res.error?.message ?? "")")
        }

        service.tripKillSwitch(false)
        let afterClear = await service.handle(RPCRequest(method: .listApps))
        XCTAssertTrue(afterClear.ok, "Expected list_apps to succeed after clearing kill switch")
    }

    func testPausedPolicyBlocksReadMethods() async {
        let service = makeService(prefix: "usemac-gov-paused")
        XCTAssertFalse(service.isKillSwitchTripped())
        service.setGovernancePolicy(.paused)

        for (name, req) in blockedReadRequests() {
            let res = await service.handle(req)
            XCTAssertFalse(res.ok, "Expected \(name) to be blocked under paused policy")
            XCTAssertEqual(res.error?.code, "POLICY_BLOCKED", "Unexpected error code for \(name)")
        }

        for (name, req) in alwaysAllowedRequests() {
            let res = await service.handle(req)
            XCTAssertTrue(res.ok, "Expected \(name) to remain allowed under paused policy: \(res.error?.message ?? "")")
        }

        service.setGovernancePolicy(.autonomous)
        let afterResume = await service.handle(RPCRequest(method: .listApps))
        XCTAssertTrue(afterResume.ok)
    }

    func testReadOnlyAllowsReadingAndBlocksEval() async {
        let service = makeService(prefix: "usemac-gov-ro")
        service.setGovernancePolicy(.readOnly)

        let appsRes = await service.handle(RPCRequest(method: .listApps))
        XCTAssertTrue(appsRes.ok)

        let textExtractRes = await service.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(mode: "text")
        ))
        XCTAssertFalse(textExtractRes.ok)
        XCTAssertEqual(textExtractRes.error?.code, "EXTENSION_NOT_CONNECTED")

        let evalRes = await service.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(mode: "eval", expression: "document.title")
        ))
        XCTAssertFalse(evalRes.ok)
        XCTAssertEqual(evalRes.error?.code, "POLICY_BLOCKED")

        let paddedUpperEvalRes = await service.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(mode: " EVAL ", expression: "document.cookie")
        ))
        XCTAssertFalse(paddedUpperEvalRes.ok)
        XCTAssertEqual(paddedUpperEvalRes.error?.code, "POLICY_BLOCKED")
    }

    func testEvalBlockedUnderConfirmSensitiveAndAllowedUnderAutonomous() async {
        let service = makeService(prefix: "usemac-gov-eval")

        service.setGovernancePolicy(.confirmSensitive)
        let blockedRes = await service.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(mode: "eval", expression: "1 + 1")
        ))
        XCTAssertFalse(blockedRes.ok)
        XCTAssertEqual(blockedRes.error?.code, "POLICY_BLOCKED")

        service.setGovernancePolicy(.autonomous)
        let allowedRes = await service.handle(RPCRequest(
            method: .browserExtract,
            browserExtract: BrowserExtractParams(mode: "eval", expression: "1 + 1")
        ))
        XCTAssertFalse(allowedRes.ok)
        XCTAssertEqual(allowedRes.error?.code, "EXTENSION_NOT_CONNECTED")
    }

    func testSetPolicyOverRPCCanOnlyTighten() async {
        let service = makeService(prefix: "usemac-gov-policy")
        XCTAssertEqual(service.getGovernancePolicy(), .autonomous)

        let tightenToReadOnly = await service.handle(RPCRequest(method: .setPolicy, policy: .readOnly))
        XCTAssertTrue(tightenToReadOnly.ok)
        XCTAssertEqual(service.getGovernancePolicy(), .readOnly)

        let relaxToAutonomous = await service.handle(RPCRequest(method: .setPolicy, policy: .autonomous))
        XCTAssertFalse(relaxToAutonomous.ok)
        XCTAssertEqual(relaxToAutonomous.error?.code, "POLICY_LOCKED")
        XCTAssertEqual(
            relaxToAutonomous.error?.message,
            "Execution mode can only be relaxed from the UseMac app (Settings → Safety)."
        )
        XCTAssertEqual(service.getGovernancePolicy(), .readOnly)
        XCTAssertEqual(service.recentAuditEntries(limit: 1).first?.success, false)

        let relaxToConfirm = await service.handle(RPCRequest(method: .setPolicy, policy: .confirmSensitive))
        XCTAssertFalse(relaxToConfirm.ok)
        XCTAssertEqual(relaxToConfirm.error?.code, "POLICY_LOCKED")
        XCTAssertEqual(service.getGovernancePolicy(), .readOnly)

        let tightenToPaused = await service.handle(RPCRequest(method: .setPolicy, policy: .paused))
        XCTAssertTrue(tightenToPaused.ok)
        XCTAssertEqual(service.getGovernancePolicy(), .paused)

        // Direct in-process call (used by the native app) remains unrestricted.
        service.setGovernancePolicy(.autonomous)
        XCTAssertEqual(service.getGovernancePolicy(), .autonomous)
    }

    func testNavigationPolicyTable() {
        let acceptedCases: [(input: String, expected: String)] = [
            ("https://example.com", "https://example.com"),
            ("http://localhost:3000/x", "http://localhost:3000/x"),
            ("example.com/path", "https://example.com/path"),
            ("localhost:3000", "https://localhost:3000"),
            ("ABOUT:BLANK", "about:blank")
        ]

        for (input, expected) in acceptedCases {
            switch NavigationPolicy.validate(input) {
            case .success(let normalized):
                XCTAssertEqual(normalized, expected, "Unexpected normalized URL for '\(input)'")
            case .failure(let blocked):
                XCTFail("Expected '\(input)' to be accepted as '\(expected)', but was blocked: \(blocked.message)")
            }
        }

        let blockedCases: [String] = [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>",
            "chrome://settings",
            "chrome-extension://abc/popup.html",
            "shortcuts://run-shortcut?name=x",
            "x-apple.systempreferences:com.apple.preference.security",
            "view-source:https://a.com",
            "",
            "   "
        ]

        for input in blockedCases {
            if case .success(let normalized) = NavigationPolicy.validate(input) {
                XCTFail("Expected '\(input)' to be blocked, but was accepted as '\(normalized)'")
            }
        }
    }

    func testBlockedSchemesAreRejectedBeforeReachingChromeOrWorkspace() async {
        let service = makeService(prefix: "usemac-gov-url")

        let openRes = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "file:///etc/passwd")
        ))
        XCTAssertFalse(openRes.ok)
        XCTAssertEqual(openRes.error?.code, "URL_BLOCKED")

        let browserActRes = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                steps: [ActionStep(action: .navigate, url: "javascript:alert(1)")]
            )
        ))
        XCTAssertFalse(browserActRes.ok)
        XCTAssertEqual(browserActRes.error?.code, "URL_BLOCKED")

        let nativeActRes = await service.handle(RPCRequest(
            method: .act,
            act: BatchActionRequest(
                steps: [ActionStep(action: .openURL, url: "shortcuts://run-shortcut?name=x")],
                returnObservation: false
            )
        ))
        XCTAssertEqual(nativeActRes.actionResult?.stepResults.first?.success, false)
        XCTAssertTrue(
            nativeActRes.actionResult?.stepResults.first?.message?.contains("Only http(s)") == true,
            "Expected message containing 'Only http(s)', got \(nativeActRes.actionResult?.stepResults.first?.message ?? "<nil>")"
        )
    }

    func testUploadDenylistExtended() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("usemac-gov-upload-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let pemFile = tmpDir.appendingPathComponent("server.pem")
        let zshHistory = tmpDir.appendingPathComponent(".zsh_history")
        let kdbxFile = tmpDir.appendingPathComponent("vault.kdbx")
        let chromePrefsDir = tmpDir.appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try fm.createDirectory(at: chromePrefsDir, withIntermediateDirectories: true)
        let chromePrefs = chromePrefsDir.appendingPathComponent("Preferences")

        let deckKey = tmpDir.appendingPathComponent("deck.key")
        let reportPDF = tmpDir.appendingPathComponent("report.pdf")

        for fileURL in [pemFile, zshHistory, kdbxFile, chromePrefs, deckKey, reportPDF] {
            try Data("sample".utf8).write(to: fileURL)
        }

        for blockedURL in [pemFile, zshHistory, kdbxFile, chromePrefs] {
            if case .success(let paths) = ActionExecutor.validateAndNormalizeUploadFiles([blockedURL.path]) {
                XCTFail("Expected \(blockedURL.path) to be blocked, but succeeded with \(paths)")
            }
        }

        for allowedURL in [deckKey, reportPDF] {
            let expectedCanonical = allowedURL.standardizedFileURL.resolvingSymlinksInPath().path
            switch ActionExecutor.validateAndNormalizeUploadFiles([allowedURL.path]) {
            case .success(let paths):
                XCTAssertEqual(paths, [expectedCanonical])
            case .failure(let err):
                XCTFail("Expected \(allowedURL.lastPathComponent) to be allowed, got error: \(err.message)")
            }
        }
    }

    func testVisionQueryImagePathIsRestricted() async {
        let service = makeService(prefix: "usemac-gov-vision-path")

        let res = await service.handle(RPCRequest(
            method: .visionQuery,
            visionQuery: VisionQueryParams(mode: "ask", query: "read", imagePath: "/etc/hosts")
        ))
        XCTAssertFalse(res.ok)
        XCTAssertEqual(res.error?.code, "IMAGE_PATH_BLOCKED")
        XCTAssertEqual(
            res.error?.message,
            "imagePath must be inside the UseMac capture directory or the temporary directory."
        )
    }

    func testTaskStartHasNoHardcodedProfileAndCapturesArePruned() async throws {
        let service = makeService(prefix: "usemac-gov-profile-prune")
        let fm = FileManager.default
        let captureDir = URL(fileURLWithPath: UseMacDefaults.captureDirectory, isDirectory: true)
        try fm.createDirectory(at: captureDir, withIntermediateDirectories: true)

        let token = UUID().uuidString.prefix(8)
        let oldFile = captureDir.appendingPathComponent("gov-old-\(token).jpg")
        let freshFile = captureDir.appendingPathComponent("gov-fresh-\(token).jpg")
        defer {
            try? fm.removeItem(at: oldFile)
            try? fm.removeItem(at: freshFile)
        }

        try Data("old".utf8).write(to: oldFile)
        try Data("fresh".utf8).write(to: freshFile)
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: oldFile.path)

        let removed = service.pruneCaptures(olderThan: 1800)
        XCTAssertGreaterThanOrEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: oldFile.path), "Expected 2-hour-old capture to be pruned")
        XCTAssertTrue(fm.fileExists(atPath: freshFile.path), "Expected fresh capture to be retained")

        let taskRes = await service.handle(RPCRequest(
            method: .taskStart,
            taskStart: TaskStartParams(tabId: 5)
        ))
        XCTAssertTrue(taskRes.ok)
        XCTAssertEqual(service.recentAuditEntries(limit: 1).first?.targetApp, "Chrome (Browser)")
    }
}
