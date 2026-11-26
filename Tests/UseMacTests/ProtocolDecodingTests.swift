import Foundation
import XCTest
import UseMacProtocol

final class ProtocolDecodingTests: XCTestCase {
    func testReadmeActExampleDecodes() throws {
        let json = #"{"id":"4","method":"act","act":{"app":"TextEdit","steps":[{"action":"type","text":"Teste via NDJSON"}]}}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let request = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(request.id, "4")
        XCTAssertEqual(request.method, .act)

        let batch = try XCTUnwrap(request.act)
        XCTAssertEqual(batch.app, "TextEdit")
        XCTAssertEqual(batch.steps.count, 1)
        XCTAssertEqual(batch.steps[0].action, .type)
        XCTAssertEqual(batch.steps[0].text, "Teste via NDJSON")
        XCTAssertTrue(batch.stopOnError)
        XCTAssertTrue(batch.returnObservation)
        XCTAssertFalse(batch.returnDiffOnly)
        XCTAssertFalse(batch.includeScreenshot)
    }

    func testRequestWithoutIdGetsGeneratedId() throws {
        let data = try XCTUnwrap(#"{"method":"ping"}"#.data(using: .utf8))

        let first = try JSONDecoder().decode(RPCRequest.self, from: data)
        let second = try JSONDecoder().decode(RPCRequest.self, from: data)

        XCTAssertEqual(first.method, .ping)
        XCTAssertEqual(second.method, .ping)
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertFalse(second.id.isEmpty)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testScreenshotRequestDefaults() throws {
        let emptyData = try XCTUnwrap("{}".data(using: .utf8))
        let empty = try JSONDecoder().decode(ScreenshotRequest.self, from: emptyData)
        XCTAssertNil(empty.app)
        XCTAssertEqual(empty.maxDimension, 1280)
        XCTAssertEqual(empty.quality, 0.78, accuracy: 0.0001)
        XCTAssertFalse(empty.includeBase64)

        let partialData = try XCTUnwrap(#"{"maxDimension":640}"#.data(using: .utf8))
        let partial = try JSONDecoder().decode(ScreenshotRequest.self, from: partialData)
        XCTAssertNil(partial.app)
        XCTAssertEqual(partial.maxDimension, 640)
        XCTAssertEqual(partial.quality, 0.78, accuracy: 0.0001)
        XCTAssertFalse(partial.includeBase64)
    }

    func testExtractAndVisionModeDefaults() throws {
        let emptyData = try XCTUnwrap("{}".data(using: .utf8))

        let extract = try JSONDecoder().decode(BrowserExtractParams.self, from: emptyData)
        XCTAssertEqual(extract.mode, "auto")

        let vision = try JSONDecoder().decode(VisionQueryParams.self, from: emptyData)
        XCTAssertEqual(vision.mode, "ask")
    }

    func testBatchWithoutStepsFails() throws {
        let data = try XCTUnwrap(#"{"app":"Notes"}"#.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(BatchActionRequest.self, from: data))
    }

    func testEncodingRoundTripIsUnchanged() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let batch = BatchActionRequest(
            app: "Notes",
            steps: [ActionStep(action: .type, text: "Hello")],
            stopOnError: false,
            returnObservation: true,
            returnDiffOnly: true,
            includeScreenshot: true
        )
        let batchData = try encoder.encode(batch)
        let decodedBatch = try decoder.decode(BatchActionRequest.self, from: batchData)
        XCTAssertEqual(decodedBatch, batch)

        let batchJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: batchData) as? [String: Any])
        XCTAssertEqual(
            Set(batchJSON.keys),
            Set(["app", "steps", "stopOnError", "returnObservation", "returnDiffOnly", "includeScreenshot"])
        )

        let screenshot = ScreenshotRequest(
            app: "Safari",
            maxDimension: 1024,
            quality: 0.85,
            includeBase64: true
        )
        let screenshotData = try encoder.encode(screenshot)
        let decodedScreenshot = try decoder.decode(ScreenshotRequest.self, from: screenshotData)
        XCTAssertEqual(decodedScreenshot, screenshot)

        let screenshotJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: screenshotData) as? [String: Any])
        XCTAssertEqual(
            Set(screenshotJSON.keys),
            Set(["app", "maxDimension", "quality", "includeBase64"])
        )
    }

    func testCompactLineV2RoleMappingFramesAndDefaultActions() {
        let frame = ScreenRect(x: 10, y: 20, width: 120, height: 34)

        let btn = ElementNode(id: "@b1", role: "AXButton", title: "Submit", frame: frame, actions: ["AXPress"])
        XCTAssertEqual(btn.compactLine, #"@b1 [btn] "Submit""#)
        XCTAssertEqual(btn.compactLine(includeFrames: true), #"@b1 [btn] "Submit" (10,20 120x34)"#)

        let btnExtra = ElementNode(id: "@b2", role: "AXButton", title: "More", frame: frame, actions: ["AXPress", "AXShowMenu"])
        XCTAssertEqual(btnExtra.compactLine, #"@b2 [btn] "More" {AXShowMenu}"#)

        let inputDefault = ElementNode(id: "@e3", role: "AXTextField", title: "Email", value: "a@b.com", focused: true, frame: frame, actions: ["AXConfirm", "AXSetValue"])
        XCTAssertEqual(inputDefault.compactLine, #"@e3 [input] "Email" val="a@b.com" *focused*"#)

        let disabledSelect = ElementNode(id: "@e4", role: "AXPopUpButton", title: "Country", enabled: false, frame: frame, actions: ["AXShowMenu"])
        XCTAssertEqual(disabledSelect.compactLine, #"@e4 [select] "Country" (disabled) {AXShowMenu}"#)

        let offscreenText = ElementNode(id: "@e5", role: "AXStaticText", value: "Footer", frame: frame, offscreen: true)
        XCTAssertEqual(offscreenText.compactLine, #"@e5 [text] val="Footer" (offscreen)"#)

        let nonRefNode = ElementNode(id: "raw-1", role: "AXCustomToolbar", title: "Bar", frame: frame)
        XCTAssertEqual(nonRefNode.compactLine, #"raw-1 [customtoolbar] "Bar" (10,20 120x34)"#)

        let rolePairs: [(String, String)] = [
            ("AXLink", "link"),
            ("AXTextArea", "textarea"),
            ("AXCheckBox", "checkbox"),
            ("AXRadioButton", "radio"),
            ("AXComboBox", "select"),
            ("AXMenuItem", "menuitem"),
            ("AXRow", "row"),
            ("AXTab", "tab"),
            ("AXImage", "img"),
            ("AXHeading", "heading")
        ]
        for (axRole, expected) in rolePairs {
            let node = ElementNode(id: "@e9", role: axRole, frame: frame)
            XCTAssertTrue(node.compactLine.hasPrefix("@e9 [\(expected)]"), "Expected \(axRole) -> \(expected), got \(node.compactLine)")
        }
    }

    func testFormattedCompactSummaryDiffOnlyVisiblePriorityLatencyAndHints() {
        let frame = ScreenRect(x: 0, y: 0, width: 100, height: 30)
        let off1 = ElementNode(id: "@e1", role: "AXButton", title: "Offscreen 1", frame: frame, offscreen: true)
        let off2 = ElementNode(id: "@e2", role: "AXButton", title: "Offscreen 2", frame: frame, offscreen: true)
        let vis1 = ElementNode(id: "@e3", role: "AXButton", title: "Visible Save", frame: frame, actions: ["AXPress"])
        let added = ElementNode(id: "@e4", role: "AXStaticText", value: "Saved!", frame: frame)
        let changed = ElementNode(id: "@e3", role: "AXButton", title: "Saved", frame: frame, actions: ["AXPress"])

        let snap = WindowSnapshot(
            app: AppDescriptor(pid: 42, name: "Notes", windowTitle: "Draft"),
            timestampMs: 1_700_000_000_000,
            latencyMs: 12.34,
            fromHotCache: true,
            focusedElementId: "@e3",
            elements: [off1, off2, vis1],
            diff: SnapshotDiff(added: [added], removedIds: ["@e9"], changed: [changed], summary: "+1 ~1 -1"),
            pageState: PageState(
                viewportWidth: 1280,
                viewportHeight: 800,
                tablesSummary: "2 tables (14 rows)",
                webMcpTools: ["search_docs", "create_issue"]
            ),
            offscreenCount: 2
        )

        // Default: omits Latency, sorts visible before offscreen before prefix(maxElements), includes hints
        let capped = snap.formattedCompactSummary(maxElements: 1)
        XCTAssertFalse(capped.contains("Latency:"))
        XCTAssertTrue(capped.contains("Offscreen: 2 elements"))
        XCTAssertTrue(capped.contains("Tables: 2 tables (14 rows)"))
        XCTAssertTrue(capped.contains("WebMCP: search_docs, create_issue"))
        XCTAssertTrue(capped.contains(#"@e3 [btn] "Visible Save""#))
        XCTAssertFalse(capped.contains("Offscreen 1"))
        XCTAssertTrue(capped.contains("2 more elements omitted"))

        // Explicit includeLatency
        let withLatency = snap.formattedCompactSummary(includeLatency: true)
        XCTAssertTrue(withLatency.contains("Latency: 12.34 ms [hot-cache] | Elements: 3"))

        // returnDiffOnly renders delta lines only
        let diffOnly = snap.formattedCompactSummary(returnDiffOnly: true)
        XCTAssertTrue(diffOnly.contains("Diff: +1 ~1 -1"))
        XCTAssertTrue(diffOnly.contains(#"+ @e4 [text] val="Saved!""#))
        XCTAssertTrue(diffOnly.contains(#"~ @e3 [btn] "Saved""#))
        XCTAssertTrue(diffOnly.contains("- @e9"))
        XCTAssertFalse(diffOnly.contains("Offscreen 1"))
    }

    func testSOTAProtocolMethodsAndPiggybackedLifecycleRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let step = ActionStep(
            action: .fillForm,
            optional: true,
            fields: [FormFieldEntry(selector: "#email", label: "Email", value: "a@b.com", checked: nil)],
            submitMatch: ElementMatch(role: "AXButton", title: "Continue"),
            submitSelector: "button[type=submit]",
            maxScrolls: 5,
            menuPath: ["File", "Export"],
            expectText: "Done",
            expectNotText: "Error",
            expectUrl: "/success",
            expectTitle: "Dashboard"
        )
        let actReq = RPCRequest(
            id: "req-1",
            method: .act,
            act: BatchActionRequest(
                app: "Notes",
                steps: [step],
                observationMode: .delta,
                maxElements: 80,
                includeText: false,
                includeTables: false,
                diffCrop: true,
                verify: "Saved banner visible",
                foregroundFallback: true,
                waitForIdleMs: 300,
                returnImageContent: true
            ),
            taskStart: TaskStartParams(app: "Notes", summary: "Auto-fill"),
            taskComplete: TaskCompleteParams(summary: "Filled")
        )
        let decodedActReq = try decoder.decode(RPCRequest.self, from: try encoder.encode(actReq))
        XCTAssertEqual(decodedActReq.method, .act)
        XCTAssertEqual(decodedActReq.taskStart?.summary, "Auto-fill")
        XCTAssertEqual(decodedActReq.taskComplete?.summary, "Filled")
        XCTAssertEqual(decodedActReq.act?.observationMode, .delta)
        XCTAssertEqual(decodedActReq.act?.foregroundFallback, true)
        XCTAssertEqual(decodedActReq.act?.steps.first?.action, .fillForm)
        XCTAssertEqual(decodedActReq.act?.steps.first?.optional, true)
        XCTAssertEqual(decodedActReq.act?.steps.first?.fields?.first?.value, "a@b.com")

        let menuReq = RPCRequest(method: .appMenu, appMenu: AppMenuParams(app: "Notes", query: "Export", menuPath: ["File", "Export as PDF…"]))
        let decodedMenuReq = try decoder.decode(RPCRequest.self, from: try encoder.encode(menuReq))
        XCTAssertEqual(decodedMenuReq.method, .appMenu)
        XCTAssertEqual(decodedMenuReq.appMenu?.menuPath, ["File", "Export as PDF…"])

        let batchReq = RPCRequest(method: .browserBatch, browserBatch: BrowserBatchParams(profile: "Work", urls: ["https://a.example", "https://b.example"], mode: "extract", extractMode: "text", maxElements: 50, autoDismissOverlays: true, closeAfter: true))
        let decodedBatchReq = try decoder.decode(RPCRequest.self, from: try encoder.encode(batchReq))
        XCTAssertEqual(decodedBatchReq.method, .browserBatch)
        XCTAssertEqual(decodedBatchReq.browserBatch?.urls.count, 2)

        let resp = RPCResponse.success(
            id: "r1",
            latencyMs: 4.2,
            browserBatchResult: BrowserBatchResult(results: [BrowserBatchItemResult(url: "https://a.example", tabId: 10, success: true, latencyMs: 2.1)], totalLatencyMs: 2.1),
            appMenuResult: AppMenuResult(app: "Notes", items: [AppMenuItemInfo(path: ["File", "Save"], title: "Save", shortcut: "⌘S", enabled: true)]),
            skillResult: SkillRunResult(name: "login", success: true, totalLatencyMs: 1.5),
            skills: SkillListResult(skills: [SkillRecord(name: "login", steps: [ActionStep(action: .click, elementId: "@b1")])])
        )
        let decodedResp = try decoder.decode(RPCResponse.self, from: try encoder.encode(resp))
        XCTAssertEqual(decodedResp.appMenuResult?.items?.first?.shortcut, "⌘S")
        XCTAssertEqual(decodedResp.browserBatchResult?.results.first?.tabId, 10)
        XCTAssertEqual(decodedResp.skillResult?.name, "login")
        XCTAssertEqual(decodedResp.skills?.skills.first?.name, "login")
    }
}
