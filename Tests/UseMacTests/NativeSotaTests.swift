import CoreGraphics
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

final class NativeSotaTests: XCTestCase {

    // MARK: - AXIndexer Diff Jitter Tolerance

    func testComputeDiffIgnoresSub5PxFrameJitter() {
        let app = AppDescriptor(pid: 42, name: "TestApp")
        let oldNodes = [
            ElementNode(
                id: "@e1",
                role: "AXButton",
                title: "Submit",
                enabled: true,
                focused: false,
                frame: ScreenRect(x: 100, y: 200, width: 120, height: 32),
                actions: ["AXPress"]
            ),
            ElementNode(
                id: "@e2",
                role: "AXTextField",
                title: "Email",
                value: "alice@example.com",
                enabled: true,
                focused: true,
                frame: ScreenRect(x: 100, y: 140, width: 240, height: 28),
                actions: []
            )
        ]
        let prev = WindowSnapshot(app: app, timestampMs: 1000, latencyMs: 5, elements: oldNodes)

        // Sub-5 px jitter across x, y, width, height should NOT count as ~changed.
        let jitteredNodes = [
            ElementNode(
                id: "@e1",
                role: "AXButton",
                title: "Submit",
                enabled: true,
                focused: false,
                frame: ScreenRect(x: 103.5, y: 196.1, width: 122.0, height: 30.0),
                actions: ["AXPress"]
            ),
            ElementNode(
                id: "@e2",
                role: "AXTextField",
                title: "Email",
                value: "alice@example.com",
                enabled: true,
                focused: true,
                frame: ScreenRect(x: 96.0, y: 144.9, width: 244.0, height: 26.0),
                actions: []
            )
        ]
        let jitterDiff = AXIndexer.computeDiff(previous: prev, current: jitteredNodes)
        XCTAssertEqual(jitterDiff?.added.count, 0)
        XCTAssertEqual(jitterDiff?.removedIds.count, 0)
        XCTAssertEqual(jitterDiff?.changed.count, 0)
        XCTAssertEqual(jitterDiff?.summary, "no changes")

        // >= 5 px move MUST be detected as ~changed.
        let movedNodes = [
            ElementNode(
                id: "@e1",
                role: "AXButton",
                title: "Submit",
                enabled: true,
                focused: false,
                frame: ScreenRect(x: 105.0, y: 200, width: 120, height: 32),
                actions: ["AXPress"]
            ),
            // Semantic value change with identical frame MUST also be detected.
            ElementNode(
                id: "@e2",
                role: "AXTextField",
                title: "Email",
                value: "bob@example.com",
                enabled: true,
                focused: true,
                frame: ScreenRect(x: 100, y: 140, width: 240, height: 28),
                actions: []
            )
        ]
        let realDiff = AXIndexer.computeDiff(previous: prev, current: movedNodes)
        XCTAssertEqual(realDiff?.changed.map(\.id), ["@e1", "@e2"])
        XCTAssertEqual(realDiff?.summary, "+0 added, -0 removed, ~2 changed")
    }

    // MARK: - AXIndexer find() Short-Circuiting

    func testLazyMatchChecksRoleFirstAndAvoidsValueIPCWhenUnneeded() {
        var titleCalls = 0
        var descCalls = 0
        var valueCalls = 0

        let buttonMatch = ElementMatch(role: "button", title: "Save")

        // Role mismatch must short-circuit BEFORE fetching title, description, or value.
        let mismatch = ElementMatcher.matchesLazy(
            role: "AXStaticText",
            match: buttonMatch,
            title: { titleCalls += 1; return "Save" },
            description: { descCalls += 1; return "Save" },
            value: { valueCalls += 1; return "Save" }
        )
        XCTAssertFalse(mismatch)
        XCTAssertEqual(titleCalls, 0)
        XCTAssertEqual(descCalls, 0)
        XCTAssertEqual(valueCalls, 0)

        // Role matches and title matches -> description and value must NOT be fetched.
        let titleHit = ElementMatcher.matchesLazy(
            role: "AXButton",
            match: buttonMatch,
            title: { titleCalls += 1; return "Save Document" },
            description: { descCalls += 1; return "desc" },
            value: { valueCalls += 1; return "val" }
        )
        XCTAssertTrue(titleHit)
        XCTAssertEqual(titleCalls, 1)
        XCTAssertEqual(descCalls, 0)
        XCTAssertEqual(valueCalls, 0)

        // Title misses -> checks description, still NEVER fetches value since match.value == nil && match.text == nil.
        titleCalls = 0
        let descHit = ElementMatcher.matchesLazy(
            role: "AXButton",
            match: buttonMatch,
            title: { titleCalls += 1; return nil },
            description: { descCalls += 1; return "Save changes" },
            value: { valueCalls += 1; return "should not run" }
        )
        XCTAssertTrue(descHit)
        XCTAssertEqual(titleCalls, 1)
        XCTAssertEqual(descCalls, 1)
        XCTAssertEqual(valueCalls, 0)

        // match.value != nil fetches value once.
        let valueMatch = ElementMatch(role: "textfield", value: "hello")
        let valHit = ElementMatcher.matchesLazy(
            role: "AXTextField",
            match: valueMatch,
            title: { titleCalls += 1; return "Field" },
            description: { descCalls += 1; return nil },
            value: { valueCalls += 1; return "hello world" }
        )
        XCTAssertTrue(valHit)
        XCTAssertEqual(valueCalls, 1)
    }

    // MARK: - AXIndexer Server-Side ElementFilter & Electron Detection

    func testApplyElementFilterSupportsRoleTextAndViewportOnly() {
        let nodes = [
            ElementNode(id: "@e1", role: "AXButton", title: "Save Draft", frame: ScreenRect(x: 10, y: 10, width: 80, height: 30)),
            ElementNode(id: "@e2", role: "AXButton", title: "Cancel", frame: ScreenRect(x: 100, y: 10, width: 80, height: 30)),
            ElementNode(id: "@e3", role: "AXTextField", title: "Notes", value: "Drafting plan", frame: ScreenRect(x: 10, y: 60, width: 200, height: 28)),
            ElementNode(id: "@e4", role: "AXButton", title: "Save Archived", frame: ScreenRect(x: 0, y: 0, width: 0, height: 0), offscreen: true)
        ]

        let onlyButtons = AXIndexer.applyFilter(nodes, filter: ElementFilter(role: "btn"))
        XCTAssertEqual(onlyButtons.map(\.id), ["@e1", "@e2", "@e4"])

        let visibleSaveButtons = AXIndexer.applyFilter(nodes, filter: ElementFilter(role: "button", text: "save", viewportOnly: true))
        XCTAssertEqual(visibleSaveButtons.map(\.id), ["@e1"])

        let inputByValue = AXIndexer.applyFilter(nodes, filter: ElementFilter(role: "input", text: "drafting"))
        XCTAssertEqual(inputByValue.map(\.id), ["@e3"])
    }

    func testElectronAndChromiumDetection() {
        let vscode = AppDescriptor(pid: 101, name: "Code", bundleId: "com.microsoft.VSCode")
        let nativeNotes = AppDescriptor(pid: 102, name: "Notes", bundleId: "com.apple.Notes")
        let populated = [
            ElementNode(id: "@e1", role: "AXWindow", title: "Notes", frame: ScreenRect(x: 0, y: 0, width: 800, height: 600)),
            ElementNode(id: "@e2", role: "AXButton", title: "New", frame: ScreenRect(x: 10, y: 10, width: 40, height: 24)),
            ElementNode(id: "@e3", role: "AXTextArea", value: "Hello", frame: ScreenRect(x: 10, y: 50, width: 700, height: 500))
        ]
        XCTAssertTrue(AXIndexer.looksLikeElectronOrChromium(app: vscode, elements: populated))
        XCTAssertFalse(AXIndexer.looksLikeElectronOrChromium(app: nativeNotes, elements: populated))

        let webStub = [
            ElementNode(id: "@e1", role: "AXWindow", title: "App", frame: ScreenRect(x: 0, y: 0, width: 800, height: 600)),
            ElementNode(id: "@e2", role: "AXWebArea", title: "", frame: ScreenRect(x: 0, y: 40, width: 800, height: 560))
        ]
        XCTAssertTrue(AXIndexer.looksLikeElectronOrChromium(app: nativeNotes, elements: webStub))
    }

    // MARK: - AXIndexer Event-Driven waitForChange

    func testWaitForChangeWakesImmediatelyOnRecordChange() async {
        let indexer = AXIndexer()
        let fakePid: pid_t = 987654
        let gen0 = indexer.currentGeneration(pid: fakePid)

        let startNs = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(15)) {
            indexer.recordChange(pid: fakePid)
        }
        let woken = await indexer.waitForChange(pid: fakePid, sinceGeneration: gen0, timeoutMs: 1500)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0

        XCTAssertTrue(woken)
        XCTAssertLessThan(elapsedMs, 400, "waitForChange should wake immediately on recordChange instead of waiting for timeout")
        XCTAssertGreaterThan(indexer.currentGeneration(pid: fakePid), gen0)

        // Already-advanced generation returns true immediately.
        let instant = await indexer.waitForChange(pid: fakePid, sinceGeneration: gen0, timeoutMs: 500)
        XCTAssertTrue(instant)

        // Unchanged generation returns false after timeout.
        let gen1 = indexer.currentGeneration(pid: fakePid)
        let timedOut = await indexer.waitForChange(pid: fakePid, sinceGeneration: gen1, timeoutMs: 30)
        XCTAssertFalse(timedOut)
    }

    // MARK: - MenuBarController API & Pure Matching

    func testMenuBarShortcutFormatting() {
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "s", modifiers: 0), "⌘S")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "s", modifiers: 1 << 0), "⇧⌘S")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "i", modifiers: 1 << 1), "⌥⌘I")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "f", modifiers: 1 << 2), "⌃⌘F")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "a", modifiers: (1 << 0) | (1 << 1) | (1 << 2)), "⌃⌥⇧⌘A")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "x", modifiers: 1 << 3), "X")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: "x", modifiers: (1 << 0) | (1 << 3)), "⇧X")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: nil, modifiers: 0, virtualKey: 36), "⌘↩")
        XCTAssertEqual(MenuBarController.formatShortcut(cmdChar: nil, modifiers: 0, virtualKey: 51), "⌘⌫")
        XCTAssertNil(MenuBarController.formatShortcut(cmdChar: nil, modifiers: 0, virtualKey: nil))
    }

    func testMenuBarMatchingNormalizationAndRanking() {
        XCTAssertEqual(MenuBarController.normalizeMenuTitle("Export as PDF…"), "export as pdf")
        XCTAssertEqual(MenuBarController.normalizeMenuTitle("Save As..."), "save as")
        XCTAssertEqual(MenuBarController.normalizePathSegments(["File → Export as PDF…"]), ["File", "Export as PDF…"])
        XCTAssertEqual(MenuBarController.normalizePathSegments(["Edit > Copy"]), ["Edit", "Copy"])

        let titles = ["New Tab", "Export as PDF…", "Export…", "Close Window"]
        XCTAssertEqual(MenuBarController.matchBestTitle("Export as PDF", in: titles), 1)
        XCTAssertEqual(MenuBarController.matchBestTitle("Export", in: titles), 2)
        XCTAssertEqual(MenuBarController.matchBestTitle("window", in: titles), 3)

        let items = [
            AppMenuItemInfo(path: ["Edit", "Find and Replace"], title: "Find and Replace", shortcut: "⌥⌘F"),
            AppMenuItemInfo(path: ["File", "Export as PDF…"], title: "Export as PDF…"),
            AppMenuItemInfo(path: ["Edit", "Find…"], title: "Find…", shortcut: "⌘F"),
            AppMenuItemInfo(path: ["Edit", "Find Next"], title: "Find Next", shortcut: "⌘G")
        ]
        let ranked = MenuBarController.filterItems(items, query: "find", limit: 10)
        XCTAssertEqual(ranked.map(\.title), ["Find…", "Find and Replace", "Find Next"])

        // Invalid path & invalid pid error handling.
        let emptyInv = MenuBarController.invoke(pid: 12345, appName: "FakeApp", path: [])
        XCTAssertFalse(emptyInv.success)
        XCTAssertEqual(emptyInv.errorCode, "INVALID_REQUEST")

        let noPidInv = MenuBarController.invoke(pid: 0, appName: "FakeApp", path: ["File", "Save"])
        XCTAssertFalse(noPidInv.success)
        XCTAssertEqual(noPidInv.errorCode, "APP_NOT_FOUND")

        let invalidSearch = MenuBarController.search(pid: -1, appName: "FakeApp")
        XCTAssertEqual(invalidSearch.app, "FakeApp")
        XCTAssertEqual(invalidSearch.items, [])
    }

    // MARK: - ActionExecutor STALE_SNAPSHOT Same-Window Liveness

    func testStaleSnapshotAllowsSameWindowTitleDriftWhenElementsAreAlive() {
        let before = AXIndexer.SnapshotContext(windowId: 500, windowTitle: "Dashboard - Overview")
        let sameWinDrifted = AXIndexer.SnapshotContext(windowId: 500, windowTitle: "Dashboard - Billing")
        let diffWin = AXIndexer.SnapshotContext(windowId: 501, windowTitle: "Dashboard - Billing")
        let unknownWinBefore = AXIndexer.SnapshotContext(windowId: nil, windowTitle: "Dashboard - Overview")
        let unknownWinNow = AXIndexer.SnapshotContext(windowId: nil, windowTitle: "Dashboard - Billing")

        // Same windowId + elements alive -> allowed!
        let allowSameWin = ActionExecutor.evaluateStaleSnapshot(snapshot: before, current: sameWinDrifted) { true }
        XCTAssertFalse(allowSameWin.shouldRefuse)

        // Same windowId + elements dead -> refused!
        let refuseDead = ActionExecutor.evaluateStaleSnapshot(snapshot: before, current: sameWinDrifted) { false }
        XCTAssertTrue(refuseDead.shouldRefuse)
        XCTAssertFalse(refuseDead.windowChanged)

        // Different windowId -> ALWAYS refused even if elementsAlive closure would return true!
        let refuseDiffWin = ActionExecutor.evaluateStaleSnapshot(snapshot: before, current: diffWin) { true }
        XCTAssertTrue(refuseDiffWin.shouldRefuse)
        XCTAssertTrue(refuseDiffWin.windowChanged)

        // Missing windowId + title drifted -> conservatively refused.
        let refuseUnknownWin = ActionExecutor.evaluateStaleSnapshot(snapshot: unknownWinBefore, current: unknownWinNow) { true }
        XCTAssertTrue(refuseUnknownWin.shouldRefuse)
    }

    // MARK: - ActionExecutor Reformatted setValue

    func testReformattedSetValueReportsChangedInsteadOfNoneWarning() {
        // Currency reformatting: "" -> "$1,000.00" when requested "1000"
        let currency = ActionExecutor.evaluateSetValueReadBack(
            requested: "1000",
            before: "",
            readBack: "$1,000.00",
            isToggle: false,
            isSecure: false
        )
        XCTAssertEqual(currency.effect, .changed)
        XCTAssertNil(currency.warning)
        XCTAssertTrue(currency.message?.contains("$1,000.00") == true)

        // Phone reformatting: nil -> "(555) 123-4567" when requested "5551234567"
        let phone = ActionExecutor.evaluateSetValueReadBack(
            requested: "5551234567",
            before: nil,
            readBack: "(555) 123-4567",
            isToggle: false,
            isSecure: false
        )
        XCTAssertEqual(phone.effect, .changed)
        XCTAssertNil(phone.warning)

        // Truly rejected input (unchanged from beforeValue) -> effect: .none + warning
        let rejected = ActionExecutor.evaluateSetValueReadBack(
            requested: "new value",
            before: "old value",
            readBack: "old value",
            isToggle: false,
            isSecure: false
        )
        XCTAssertEqual(rejected.effect, ActionEffect.none)
        XCTAssertNotNil(rejected.warning)

        // Exact normalized match -> effect: .changed, no warning
        let exact = ActionExecutor.evaluateSetValueReadBack(
            requested: "café",
            before: "",
            readBack: "Cafe",
            isToggle: false,
            isSecure: false
        )
        XCTAssertEqual(exact.effect, .changed)
        XCTAssertNil(exact.warning)
        XCTAssertNil(exact.message)
    }

    // MARK: - ActionExecutor Resilient Steps (optional, assert, scrollUntil, fillForm, menuAction)

    func testOptionalStepSkipsFailureAndContinuesBatch() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let mockTarget = AppDescriptor(pid: 999991, name: "MockApp", windowTitle: "Invoices")
        let request = BatchActionRequest(
            steps: [
                ActionStep(action: .click, elementId: "@e999999", optional: true),
                ActionStep(action: .assert, expectTitle: "Invoices")
            ],
            stopOnError: true,
            returnObservation: false
        )
        let (result, _) = await executor.executeBatch(request, preResolvedTarget: mockTarget)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.stepResults.count, 2)
        XCTAssertTrue(result.stepResults[0].success)
        XCTAssertEqual(result.stepResults[0].skipped, true)
        XCTAssertNil(result.stepResults[0].errorCode)
        XCTAssertTrue(result.stepResults[1].success)
        XCTAssertNil(result.stepResults[1].skipped)
    }

    func testOptionalStepDoesNotBypassPolicyBlock() async {
        let ks = KillSwitch()
        ks.setPolicy(.readOnly)
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: ks)
        let mockTarget = AppDescriptor(pid: 999992, name: "MockApp", windowTitle: "Settings")
        let request = BatchActionRequest(
            steps: [
                ActionStep(action: .click, elementId: "@e1", optional: true)
            ],
            returnObservation: false
        )
        let (result, _) = await executor.executeBatch(request, preResolvedTarget: mockTarget)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "POLICY_BLOCKED")
        XCTAssertNil(result.stepResults.first?.skipped)
    }

    func testAssertStepPredicates() async {
        let saveBtn = ElementNode(id: "@e5", role: "AXButton", title: "Save", frame: ScreenRect(x: 10, y: 10, width: 60, height: 24))
        let toast = ElementNode(id: "@e9", role: "AXStaticText", value: "Saved successfully", frame: ScreenRect(x: 10, y: 50, width: 160, height: 20))

        // Positive title + text + match
        let passAll = ActionExecutor.evaluateAssert(
            step: ActionStep(
                action: .assert,
                match: ElementMatch(role: "button", title: "Save"),
                expectText: "saved successfully",
                expectNotText: "error",
                expectTitle: "Editor"
            ),
            appName: "MockApp",
            windowTitle: "Document Editor — Draft",
            findMatch: { match in
                if match.role == "button" { return saveBtn }
                if match.text?.lowercased().contains("saved") == true { return toast }
                return nil
            },
            findElementById: { _ in nil }
        )
        XCTAssertTrue(passAll.passed)

        // expectNotText fails when present
        let failNotText = ActionExecutor.evaluateAssert(
            step: ActionStep(action: .assert, expectNotText: "saved"),
            appName: "MockApp",
            windowTitle: "Editor",
            findMatch: { _ in toast },
            findElementById: { _ in nil }
        )
        XCTAssertFalse(failNotText.passed)

        // match + gone: true passes when absent, fails when present
        let passGone = ActionExecutor.evaluateAssert(
            step: ActionStep(action: .assert, match: ElementMatch(role: "AXSheet"), gone: true),
            appName: "MockApp",
            windowTitle: "Editor",
            findMatch: { _ in nil },
            findElementById: { _ in nil }
        )
        XCTAssertTrue(passGone.passed)

        let failGone = ActionExecutor.evaluateAssert(
            step: ActionStep(action: .assert, match: ElementMatch(role: "AXButton"), gone: true),
            appName: "MockApp",
            windowTitle: "Editor",
            findMatch: { _ in saveBtn },
            findElementById: { _ in nil }
        )
        XCTAssertFalse(failGone.passed)

        // Live executeBatch with preResolvedTarget checks expectTitle and reports ASSERTION_FAILED on mismatch.
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let mockTarget = AppDescriptor(pid: 999993, name: "MockApp", windowTitle: "Quarterly Report")
        let failReq = BatchActionRequest(
            steps: [ActionStep(action: .assert, expectTitle: "Billing")],
            returnObservation: false
        )
        let (failRes, _) = await executor.executeBatch(failReq, preResolvedTarget: mockTarget)
        XCTAssertFalse(failRes.success)
        XCTAssertEqual(failRes.stepResults.first?.errorCode, "ASSERTION_FAILED")

        let invalidReq = BatchActionRequest(
            steps: [ActionStep(action: .assert)],
            returnObservation: false
        )
        let (invalidRes, _) = await executor.executeBatch(invalidReq, preResolvedTarget: mockTarget)
        XCTAssertFalse(invalidRes.success)
        XCTAssertEqual(invalidRes.stepResults.first?.errorCode, "INVALID_REQUEST")
    }

    func testScrollUntilFillFormAndMenuActionValidation() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let mockTarget = AppDescriptor(pid: 999994, name: "MockApp", windowTitle: "Form")

        // scrollUntil without match/expectText/elementId -> INVALID_REQUEST
        let (suInvalid, _) = await executor.executeBatch(
            BatchActionRequest(steps: [ActionStep(action: .scrollUntil)], returnObservation: false),
            preResolvedTarget: mockTarget
        )
        XCTAssertFalse(suInvalid.success)
        XCTAssertEqual(suInvalid.stepResults.first?.errorCode, "INVALID_REQUEST")

        // scrollUntil with missing app -> APP_NOT_FOUND
        let (suNoApp, _) = await executor.executeBatch(
            BatchActionRequest(
                app: "no-such-app-\(UUID().uuidString)",
                steps: [ActionStep(action: .scrollUntil, match: ElementMatch(text: "Footer"), maxScrolls: 2)],
                returnObservation: false
            )
        )
        XCTAssertFalse(suNoApp.success)
        XCTAssertEqual(suNoApp.stepResults.first?.errorCode, "APP_NOT_FOUND")

        // fillForm without fields -> INVALID_REQUEST
        let (ffInvalid, _) = await executor.executeBatch(
            BatchActionRequest(steps: [ActionStep(action: .fillForm, fields: [])], returnObservation: false),
            preResolvedTarget: mockTarget
        )
        XCTAssertFalse(ffInvalid.success)
        XCTAssertEqual(ffInvalid.stepResults.first?.errorCode, "INVALID_REQUEST")

        // fillForm with unresolvable field -> FORM_FILL_FAILED
        let (ffMissing, _) = await executor.executeBatch(
            BatchActionRequest(
                steps: [ActionStep(action: .fillForm, fields: [FormFieldEntry(label: "Email", value: "a@b.com")])],
                returnObservation: false
            ),
            preResolvedTarget: mockTarget
        )
        XCTAssertFalse(ffMissing.success)
        XCTAssertEqual(ffMissing.stepResults.first?.errorCode, "FORM_FILL_FAILED")

        // fillForm with optional: true skips missing field cleanly
        let (ffOpt, _) = await executor.executeBatch(
            BatchActionRequest(
                steps: [ActionStep(action: .fillForm, optional: true, fields: [FormFieldEntry(label: "Promo", value: "SAVE10")])],
                returnObservation: false
            ),
            preResolvedTarget: mockTarget
        )
        XCTAssertTrue(ffOpt.success)
        XCTAssertEqual(ffOpt.stepResults.first?.skipped, true)

        // menuAction without menuPath -> INVALID_REQUEST
        let (maInvalid, _) = await executor.executeBatch(
            BatchActionRequest(steps: [ActionStep(action: .menuAction, menuPath: [])], returnObservation: false),
            preResolvedTarget: mockTarget
        )
        XCTAssertFalse(maInvalid.success)
        XCTAssertEqual(maInvalid.stepResults.first?.errorCode, "INVALID_REQUEST")
    }

    // MARK: - LiveScreenStreamer + FastScreenCapturer Frame Reuse & writeToDisk

    func testFastScreenCapturerReusesLiveStreamerFrameAndSkipsDiskWrite() async throws {
        let streamer = LiveScreenStreamer()
        let windowId: CGWindowID = 77777
        let image = try makeSolidCGImage(width: 640, height: 400)
        streamer.storeCachedFrameForTesting(
            windowID: windowId,
            image: image,
            bounds: ScreenRect(x: 0, y: 0, width: 640, height: 400)
        )

        XCTAssertNotNil(streamer.latestFrame(forWindowID: windowId))
        XCTAssertNil(streamer.latestFrame(forWindowID: windowId + 1))

        let capturer = FastScreenCapturer()
        let targetApp = AppDescriptor(pid: 999995, name: "MockApp", windowId: UInt32(windowId))
        let req = ScreenshotRequest(app: "MockApp", maxDimension: 320, quality: 0.8, includeBase64: true)

        let result = try await capturer.captureWindow(
            req,
            targetApp: targetApp,
            streamer: streamer,
            writeToDisk: false
        )
        XCTAssertEqual(result.path, "")
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 200)
        XCTAssertGreaterThan(result.byteCount, 100)
        XCTAssertNotNil(result.base64Data)
        XCTAssertLessThan(result.latencyMs, 500)

        // Region crop on live frame works too.
        let cropReq = ScreenshotRequest(
            app: "MockApp",
            maxDimension: 640,
            quality: 0.8,
            includeBase64: false,
            region: ScreenRect(x: 10, y: 20, width: 200, height: 100)
        )
        let cropped = try await capturer.captureWindow(
            cropReq,
            targetApp: targetApp,
            streamer: streamer,
            writeToDisk: false
        )
        XCTAssertEqual(cropped.width, 200)
        XCTAssertEqual(cropped.height, 100)
        XCTAssertNil(cropped.base64Data)

        // Stopping stream clears cached frame.
        streamer.stop()
        XCTAssertNil(streamer.latestFrame(forWindowID: windowId))
    }

    // MARK: - Helpers

    private func makeSolidCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
}
