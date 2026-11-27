import Foundation
import XCTest
@testable import UseMacProtocol
@testable import UseMacIPC

/// Covers the reliability contract on the MCP side: new act steps and batch fields, observe/browser_open
/// arguments, their type validation, and how step effects, warnings and error codes are reported back.
final class MCPReliabilityContractTests: XCTestCase {
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [RPCRequest] = []

        func append(_ request: RPCRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var last: RPCRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests.last
        }
    }

    private func makeServer(
        handler: (@Sendable (RPCRequest) -> RPCResponse)? = nil
    ) -> (MCPStdioServer, RequestBox) {
        let box = RequestBox()
        let missingSocket = "/tmp/usemac-mcp-contract-\(UUID().uuidString.prefix(8)).sock"
        let stub = StubService { request in
            box.append(request)
            if let handler {
                return handler(request)
            }
            return RPCResponse.success(id: request.id, latencyMs: 0.1)
        }
        return (MCPStdioServer(socketPath: missingSocket, fallbackService: stub), box)
    }

    private func call(_ mcp: MCPStdioServer, tool: String, arguments: String) async throws -> [String: Any] {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":""# + tool + #"","arguments":"# + arguments + "}}"
        let output = await mcp.processLine(line)
        let raw = try XCTUnwrap(output)
        let data = try XCTUnwrap(raw.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func resultText(_ response: [String: Any]) throws -> (text: String, isError: Bool) {
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Expected a tool result, got \(response)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return (text, result["isError"] as? Bool ?? false)
    }

    private func invalidParamsMessage(_ response: [String: Any]) throws -> String {
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Expected a JSON-RPC error, got \(response)")
        XCTAssertEqual(error["code"] as? Int, MCPError.invalidParams)
        return try XCTUnwrap(error["message"] as? String)
    }

    private func toolList(_ mcp: MCPStdioServer) async throws -> [[String: Any]] {
        let output = await mcp.processLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)
        let raw = try XCTUnwrap(output)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return try XCTUnwrap((obj["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    }

    private func properties(of tool: String, in tools: [[String: Any]]) throws -> [String: Any] {
        let def = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == tool }), "Missing tool \(tool)")
        let schema = try XCTUnwrap(def["inputSchema"] as? [String: Any])
        return try XCTUnwrap(schema["properties"] as? [String: Any])
    }

    // MARK: - Decoding through the MCP argument path

    func testActDecodesNewStepsAndBatchFields() async throws {
        let (mcp, box) = makeServer()
        defer { mcp.close() }

        let args = """
        {"app":"Notes","expectWindowTitle":"Shopping list","allowStaleSnapshot":true,"foreground":true,"steps":[
          {"action":"click","match":{"role":"button","title":"New Note","exact":true,"index":1}},
          {"action":"scrollIntoView","match":{"text":"Total"}},
          {"action":"axAction","elementId":"@e44","actionName":"AXOpen"},
          {"action":"waitFor","match":{"value":"Saved"},"timeoutMs":8000,"gone":true}
        ]}
        """.replacingOccurrences(of: "\n", with: "")
        let response = try await call(mcp, tool: "usemac_act", arguments: args)
        XCTAssertNil(response["error"], "Unexpected error: \(String(describing: response["error"]))")

        let batch = try XCTUnwrap(box.last?.act)
        XCTAssertEqual(box.last?.method, .act)
        XCTAssertEqual(batch.app, "Notes")
        XCTAssertEqual(batch.expectWindowTitle, "Shopping list")
        XCTAssertEqual(batch.allowStaleSnapshot, true)
        XCTAssertEqual(batch.foreground, true)
        XCTAssertEqual(batch.steps.map(\.action), [.click, .scrollIntoView, .axAction, .waitFor])
        XCTAssertEqual(batch.steps[0].match, ElementMatch(role: "button", title: "New Note", exact: true, index: 1))
        XCTAssertEqual(batch.steps[1].match?.text, "Total")
        XCTAssertEqual(batch.steps[2].elementId, "@e44")
        XCTAssertEqual(batch.steps[2].actionName, "AXOpen")
        XCTAssertEqual(batch.steps[3].match?.value, "Saved")
        XCTAssertEqual(batch.steps[3].timeoutMs, 8000)
        XCTAssertEqual(batch.steps[3].gone, true)
    }

    func testActLeavesNewBatchFieldsUnsetByDefault() async throws {
        let (mcp, box) = makeServer()
        defer { mcp.close() }

        _ = try await call(mcp, tool: "usemac_act", arguments: #"{"steps":[{"action":"wait","durationMs":10}]}"#)
        let batch = try XCTUnwrap(box.last?.act)
        XCTAssertNil(batch.expectWindowTitle)
        XCTAssertNil(batch.allowStaleSnapshot)
        XCTAssertNil(batch.foreground)
        XCTAssertNil(batch.steps[0].match)
    }

    func testActRejectsWrongTypesForNewFields() async throws {
        let (mcp, box) = makeServer()
        defer { mcp.close() }

        let cases: [(arguments: String, mentions: String)] = [
            (#"{"foreground":"yes","steps":[{"action":"wait"}]}"#, "foreground"),
            (#"{"allowStaleSnapshot":1,"steps":[{"action":"wait"}]}"#, "allowStaleSnapshot"),
            (#"{"expectWindowTitle":42,"steps":[{"action":"wait"}]}"#, "expectWindowTitle"),
            (#"{"steps":[{"action":"click","match":{"index":"2"}}]}"#, "steps[0].match.index"),
            (#"{"steps":[{"action":"wait"},{"action":"waitFor","timeoutMs":"fast"}]}"#, "steps[1].timeoutMs"),
            (#"{"steps":[{"action":"waitFor","gone":"yes"}]}"#, "steps[0].gone"),
            (#"{"steps":[{"action":"click","match":"Save"}]}"#, "steps[0].match"),
            (#"{"steps":[{"action":"teleport"}]}"#, "teleport")
        ]
        for testCase in cases {
            let response = try await call(mcp, tool: "usemac_act", arguments: testCase.arguments)
            let message = try invalidParamsMessage(response)
            XCTAssertTrue(message.contains(testCase.mentions), "Expected '\(testCase.mentions)' in: \(message)")
        }
        XCTAssertNil(box.last, "Invalid arguments must never reach the daemon")
    }

    func testObserveOffscreenAndDepthArguments() async throws {
        let (mcp, box) = makeServer()
        defer { mcp.close() }

        _ = try await call(mcp, tool: "usemac_observe", arguments: #"{"app":"Google Chrome","includeOffscreen":false}"#)
        XCTAssertEqual(box.last?.observe?.includeOffscreen, false)
        XCTAssertEqual(box.last?.observe?.app, "Google Chrome")

        _ = try await call(mcp, tool: "usemac_observe", arguments: #"{"app":"Notes"}"#)
        XCTAssertNil(box.last?.observe?.includeOffscreen, "Omitted means the daemon default (true)")

        let bad = try await call(mcp, tool: "usemac_observe", arguments: #"{"includeOffscreen":"no"}"#)
        XCTAssertTrue(try invalidParamsMessage(bad).contains("includeOffscreen"))

        _ = try await call(mcp, tool: "usemac_observe", arguments: #"{"app":"Finder","maxDepth":24,"maxElements":900}"#)
        XCTAssertEqual(box.last?.observe?.maxDepth, 24)
        XCTAssertEqual(box.last?.observe?.maxElements, 900)

        let zeroDepth = try await call(mcp, tool: "usemac_observe", arguments: #"{"maxDepth":0}"#)
        XCTAssertTrue(try invalidParamsMessage(zeroDepth).contains("maxDepth"))
        let textDepth = try await call(mcp, tool: "usemac_observe", arguments: #"{"maxElements":"lots"}"#)
        XCTAssertTrue(try invalidParamsMessage(textDepth).contains("maxElements"))
    }

    func testBrowserOpenActivateAndNewWindow() async throws {
        let (mcp, box) = makeServer()
        defer { mcp.close() }

        // Activate an existing tab without a URL.
        let activated = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"tabId":77,"activate":true}"#)
        XCTAssertNil(activated["error"])
        let activateParams = try XCTUnwrap(box.last?.browserOpen)
        XCTAssertEqual(activateParams.url, "")
        XCTAssertEqual(activateParams.tabId, 77)
        XCTAssertEqual(activateParams.activate, true)
        XCTAssertEqual(activateParams.newTab, false)
        XCTAssertTrue(try resultText(activated).text.hasPrefix("Activated browser tab"))

        // New unfocused window.
        _ = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"url":"https://chromewebstore.google.com/","newWindow":true}"#)
        let windowParams = try XCTUnwrap(box.last?.browserOpen)
        XCTAssertEqual(windowParams.url, "https://chromewebstore.google.com/")
        XCTAssertEqual(windowParams.newWindow, true)
        XCTAssertNil(windowParams.activate)

        // Plain open keeps the old defaults.
        _ = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"url":"https://example.com"}"#)
        XCTAssertEqual(box.last?.browserOpen?.newTab, true)
        XCTAssertNil(box.last?.browserOpen?.activate)
        XCTAssertNil(box.last?.browserOpen?.newWindow)
    }

    func testBrowserOpenValidation() async throws {
        let (mcp, _) = makeServer()
        defer { mcp.close() }

        let noURL = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"tabId":77}"#)
        XCTAssertTrue(try invalidParamsMessage(noURL).contains("url"))

        let activateWithoutTab = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"activate":true}"#)
        XCTAssertTrue(try invalidParamsMessage(activateWithoutTab).contains("url"))

        let windowAndTab = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"url":"https://example.com","tabId":7,"newWindow":true}"#)
        XCTAssertTrue(try invalidParamsMessage(windowAndTab).contains("newWindow"))

        let badActivate = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"tabId":7,"activate":"true"}"#)
        XCTAssertTrue(try invalidParamsMessage(badActivate).contains("activate"))
    }

    // MARK: - Schemas and instructions

    func testSchemasExpose9CompactToolsUnder10_5KBAndSotaFields() async throws {
        let (mcp, _) = makeServer()
        defer { mcp.close() }
        let rawListOpt = await mcp.processLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)
        let rawList = try XCTUnwrap(rawListOpt)
        let toolsListBytes = rawList.utf8.count
        XCTAssertLessThan(toolsListBytes, 10_500, "tools/list compact JSON should be < 10.5 KB (got \(toolsListBytes) bytes)")

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawList.utf8)) as? [String: Any])
        let tools = try XCTUnwrap((obj["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 9)
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "usemac_observe",
            "usemac_act",
            "usemac_browser_open",
            "usemac_browser_extract",
            "usemac_screenshot",
            "usemac_discover",
            "usemac_vision",
            "usemac_skill",
            "usemac_session"
        ])

        // Dead viewport/deviceScaleFactor params must not bloat tools/list.
        for deadParam in ["viewportWidth", "viewportHeight", "deviceScaleFactor"] {
            XCTAssertFalse(rawList.contains(deadParam), "Dead param \(deadParam) should not appear in tools/list")
        }

        let actProps = try properties(of: "usemac_act", in: tools)
        for key in ["app", "window", "tabId", "profile", "steps", "verify", "observationMode", "returnDiffOnly", "diffCrop", "foregroundFallback", "returnImageContent", "task", "completeTask", "expectWindowTitle", "allowStaleSnapshot", "foreground", "taskId"] {
            XCTAssertNotNil(actProps[key], "usemac_act is missing \(key)")
        }
        let stepProps = try XCTUnwrap(((actProps["steps"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        let actions = try XCTUnwrap((stepProps["action"] as? [String: Any])?["enum"] as? [String])
        for action in ["scrollIntoView", "axAction", "waitFor", "click", "uploadFile", "openURL", "navigate", "assert", "scrollUntil", "fillForm", "menuAction"] {
            XCTAssertTrue(actions.contains(action), "usemac_act step enum is missing \(action)")
        }
        for key in ["match", "actionName", "timeoutMs", "gone", "elementId", "files", "optional", "fields", "menuPath", "expectText", "maxScrolls"] {
            XCTAssertNotNil(stepProps[key], "usemac_act step is missing \(key)")
        }
        let matchProps = try XCTUnwrap((stepProps["match"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual(Set(matchProps.keys), ["role", "title", "value", "text", "exact", "index"])
        XCTAssertEqual((matchProps["index"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((matchProps["exact"] as? [String: Any])?["type"] as? String, "boolean")

        let observeProps = try properties(of: "usemac_observe", in: tools)
        XCTAssertEqual((observeProps["includeOffscreen"] as? [String: Any])?["type"] as? String, "boolean")
        for key in ["app", "window", "tabId", "profile", "filter", "maxElements", "returnImageContent", "task", "taskId"] {
            XCTAssertNotNil(observeProps[key], "usemac_observe is missing \(key)")
        }

        let openTool = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "usemac_browser_open" }))
        let openSchema = try XCTUnwrap(openTool["inputSchema"] as? [String: Any])
        let openProps = try XCTUnwrap(openSchema["properties"] as? [String: Any])
        for key in ["url", "tabId", "profile", "activate", "newWindow", "steps", "autoDismissOverlays", "task"] {
            XCTAssertNotNil(openProps[key], "usemac_browser_open is missing \(key)")
        }
        XCTAssertFalse((openSchema["required"] as? [String] ?? []).contains("url"), "url is optional for tabId + activate")

        let extractProps = try properties(of: "usemac_browser_extract", in: tools)
        for key in ["mode", "tabId", "profile", "urlFilter", "scanHorizontal", "scanVertical", "frameIndex", "maxChars", "urls"] {
            XCTAssertNotNil(extractProps[key], "usemac_browser_extract is missing \(key)")
        }
        let extractModes = try XCTUnwrap((extractProps["mode"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(extractModes.contains("network"))

        let shotProps = try properties(of: "usemac_screenshot", in: tools)
        for key in ["app", "tabId", "profile", "maxDimension", "diffCrop", "region", "elementId", "selector", "fullPage", "returnImageContent"] {
            XCTAssertNotNil(shotProps[key], "usemac_screenshot is missing \(key)")
        }

        let discoverProps = try properties(of: "usemac_discover", in: tools)
        let discoverKinds = try XCTUnwrap((discoverProps["kind"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(discoverKinds), ["apps", "tabs", "menu", "status"])

        let visionProps = try properties(of: "usemac_vision", in: tools)
        let visionModes = try XCTUnwrap((visionProps["mode"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(visionModes), ["ocr", "verify", "locate", "diagnose"])

        let skillProps = try properties(of: "usemac_skill", in: tools)
        let skillActions = try XCTUnwrap((skillProps["action"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(skillActions), ["list", "save", "run"])
        XCTAssertNotNil(skillProps["postAssertions"])

        let sessionProps = try properties(of: "usemac_session", in: tools)
        let sessionActions = try XCTUnwrap((sessionProps["action"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(sessionActions), ["status", "task_start", "task_complete", "highlight", "report_prepare"])
    }

    func testInstructionsCoverTheReliabilityRules() async throws {
        let (mcp, _) = makeServer()
        defer { mcp.close() }
        let output = await mcp.processLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        let raw = try XCTUnwrap(output)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let instructions = try XCTUnwrap((obj["result"] as? [String: Any])?["instructions"] as? String)
        XCTAssertFalse(instructions.contains("Call usemac_status first."), "Zero-ceremony instructions must not force status first")
        for phrase in [
            "untrusted data", "background", "match", "effect", "RESTRICTED_PAGE", "newWindow",
            "uploadFile", "foreground", "USER_ACTIVE", "POLICY_BLOCKED", "SELF_TARGET_BLOCKED",
            "TARGET_BLOCKED", "task", "completeTask", "browser_open", "steps", "fillForm",
            "optional", "assert", "menuAction", "network", "skill"
        ] {
            XCTAssertTrue(instructions.contains(phrase), "Instructions should mention \(phrase)")
        }
    }

    func testConsolidatedToolsAndLegacyAliasesDispatchCleanly() async throws {
        let (mcp, box) = makeServer { req in
            switch req.method {
            case .appMenu:
                return .success(id: req.id, latencyMs: 2.0, appMenuResult: AppMenuResult(
                    app: "Notes",
                    items: [AppMenuItemInfo(path: ["File", "Export as PDF…"], title: "Export as PDF…", shortcut: "⌘E", enabled: true)]
                ))
            case .browserBatch:
                return .success(id: req.id, latencyMs: 12.0, browserBatchResult: BrowserBatchResult(
                    results: [BrowserBatchItemResult(url: "https://a.test", tabId: 10, success: true, extract: BrowserExtractResult(mode: "text", text: "Alpha"), latencyMs: 5.0)],
                    totalLatencyMs: 12.0
                ))
            case .skillList:
                return .success(id: req.id, latencyMs: 1.0, skills: SkillListResult(skills: [
                    SkillRecord(name: "export-pdf", description: "Export note", target: "native", app: "Notes", params: ["path"], steps: [ActionStep(action: .menuAction, menuPath: ["File", "Export as PDF…"])])
                ]))
            case .skillSave:
                return .success(id: req.id, latencyMs: 1.0, skills: SkillListResult(saved: SkillRecord(
                    name: req.skillSave?.name ?? "s", target: req.skillSave?.target, steps: req.skillSave?.steps ?? []
                )))
            case .skillRun:
                return .success(id: req.id, latencyMs: 8.0, skillResult: SkillRunResult(
                    name: req.skillRun?.name ?? "s",
                    success: true,
                    actionResult: BatchActionResult(success: true, totalLatencyMs: 7.0, stepResults: [
                        ActionStepResult(index: 0, action: .click, success: true, mechanism: "cdp", latencyMs: 3.0, skipped: true)
                    ]),
                    totalLatencyMs: 8.0
                ))
            default:
                return .success(id: req.id, latencyMs: 0.5)
            }
        }
        defer { mcp.close() }

        // Consolidated routing
        _ = try await call(mcp, tool: "usemac_observe", arguments: #"{"tabId":55,"filter":{"role":"button","viewportOnly":true}}"#)
        XCTAssertEqual(box.last?.method, .browserObserve)
        XCTAssertEqual(box.last?.browserObserve?.tabId, 55)
        XCTAssertEqual(box.last?.browserObserve?.filter?.role, "button")

        _ = try await call(mcp, tool: "usemac_act", arguments: #"{"tabId":55,"steps":[{"action":"click","elementId":"@b2"}],"observationMode":"delta","diffCrop":true}"#)
        XCTAssertEqual(box.last?.method, .browserAct)
        XCTAssertEqual(box.last?.browserAct?.tabId, 55)
        XCTAssertEqual(box.last?.browserAct?.observationMode, .delta)
        XCTAssertEqual(box.last?.browserAct?.diffCrop, true)

        let batchResp = try await call(mcp, tool: "usemac_browser_extract", arguments: #"{"urls":["https://a.test","https://b.test"],"mode":"text","closeAfter":true}"#)
        XCTAssertEqual(box.last?.method, .browserBatch)
        XCTAssertEqual(box.last?.browserBatch?.urls, ["https://a.test", "https://b.test"])
        XCTAssertEqual(box.last?.browserBatch?.extractMode, "text")
        XCTAssertTrue(try resultText(batchResp).text.contains("Browser batch (1 URLs"))

        let menuResp = try await call(mcp, tool: "usemac_discover", arguments: #"{"kind":"menu","app":"Notes","query":"Export"}"#)
        XCTAssertEqual(box.last?.method, .appMenu)
        XCTAssertEqual(box.last?.appMenu?.app, "Notes")
        XCTAssertEqual(box.last?.appMenu?.query, "Export")
        XCTAssertTrue(try resultText(menuResp).text.contains("File → Export as PDF… (⌘E)"))

        let saveResp = try await call(mcp, tool: "usemac_skill", arguments: ##"{"action":"save","name":"my-flow","kind":"browser","steps":[{"action":"click","selector":"#go"}],"postAssertions":[{"expectText":"Done"}]}"##)
        XCTAssertEqual(box.last?.method, .skillSave)
        XCTAssertEqual(box.last?.skillSave?.target, "browser")
        XCTAssertEqual(box.last?.skillSave?.steps.map(\.action), [.click, .assert])
        XCTAssertEqual(box.last?.skillSave?.steps.last?.expectText, "Done")
        XCTAssertTrue(try resultText(saveResp).text.contains("Saved skill 'my-flow'"))

        let listResp = try await call(mcp, tool: "usemac_skill", arguments: #"{"action":"list","kind":"native"}"#)
        XCTAssertEqual(box.last?.method, .skillList)
        XCTAssertTrue(try resultText(listResp).text.contains("export-pdf"))

        let runResp = try await call(mcp, tool: "usemac_skill", arguments: #"{"action":"run","name":"export-pdf","params":{"path":"/tmp/a.pdf"}}"#)
        XCTAssertEqual(box.last?.method, .skillRun)
        XCTAssertEqual(box.last?.skillRun?.params?["path"], "/tmp/a.pdf")
        XCTAssertTrue(try resultText(runResp).text.contains("SKIPPED"))

        _ = try await call(mcp, tool: "usemac_vision", arguments: #"{"mode":"verify","query":"Success","tabId":9}"#)
        XCTAssertEqual(box.last?.method, .visionQuery)
        XCTAssertEqual(box.last?.visionQuery?.mode, "verify")

        _ = try await call(mcp, tool: "usemac_session", arguments: #"{"action":"highlight","elementId":"@e3","durationMs":500}"#)
        XCTAssertEqual(box.last?.method, .highlight)
        XCTAssertEqual(box.last?.elementId, "@e3")

        // All 12 legacy aliases still dispatch cleanly in tools/call
        let legacyCases: [(String, String, RPCMethod)] = [
            ("usemac_status", "{}", .status),
            ("usemac_list_apps", "{}", .listApps),
            ("usemac_browser_tabs", #"{"query":"mail"}"#, .browserTabs),
            ("usemac_browser_observe", #"{"tabId":12}"#, .browserObserve),
            ("usemac_browser_act", #"{"tabId":12,"steps":[{"action":"wait","durationMs":1}]}"#, .browserAct),
            ("usemac_browser_screenshot", #"{"tabId":12}"#, .browserScreenshot),
            ("usemac_vision_status", "{}", .visionStatus),
            ("usemac_vision_query", #"{"mode":"ocr"}"#, .visionQuery),
            ("usemac_task_start", #"{"summary":"Legacy"}"#, .taskStart),
            ("usemac_task_complete", #"{"summary":"Done"}"#, .taskComplete),
            ("usemac_highlight", #"{"elementId":"@e1"}"#, .highlight),
            ("usemac_report_prepare", #"{"summary":"Bug details"}"#, .reportPrepare)
        ]
        for (name, args, expectedMethod) in legacyCases {
            let resp = try await call(mcp, tool: name, arguments: args)
            XCTAssertNil(resp["error"], "Legacy alias \(name) returned JSON-RPC error: \(String(describing: resp["error"]))")
            XCTAssertEqual(box.last?.method, expectedMethod, "Legacy alias \(name) routed wrong")
        }
    }

    func testPiggybackedTaskStartAndCompletePropagateIntoMCPTaskScope() async throws {
        let (mcp, box) = makeServer { req in
            if req.taskStart != nil {
                return .success(id: req.id, latencyMs: 1.0, browserTabId: 88, taskId: "task-piggy-1")
            }
            if req.taskComplete != nil {
                return .success(
                    id: req.id,
                    latencyMs: 1.0,
                    actionResult: BatchActionResult(success: true, totalLatencyMs: 2.0, stepResults: []),
                    taskId: req.taskId ?? "task-piggy-1",
                    taskSummary: TaskSummary(taskId: "task-piggy-1", requests: 2, actions: 1, durationMs: 1200)
                )
            }
            return .success(id: req.id, latencyMs: 1.0, actionResult: BatchActionResult(success: true, totalLatencyMs: 1.0, stepResults: []))
        }
        defer { mcp.close() }

        // 1. Piggybacked taskStart on browser_open registers task-piggy-1 in MCPTaskScope
        let openResp = try await call(mcp, tool: "usemac_browser_open", arguments: #"{"url":"https://example.com","task":"Check pricing","autoDismissOverlays":true}"#)
        XCTAssertEqual(box.last?.taskStart?.summary, "Check pricing")
        XCTAssertEqual(box.last?.browserOpen?.autoDismissOverlays, true)
        XCTAssertTrue(try resultText(openResp).text.contains("taskId: task-piggy-1"))

        // 2. Next call without explicit taskId automatically receives task-piggy-1
        _ = try await call(mcp, tool: "usemac_act", arguments: #"{"tabId":88,"steps":[{"action":"wait","durationMs":1}]}"#)
        XCTAssertEqual(box.last?.taskId, "task-piggy-1")

        // 3. Piggybacked completeTask closes task-piggy-1 in MCPTaskScope
        let doneResp = try await call(mcp, tool: "usemac_act", arguments: #"{"tabId":88,"steps":[{"action":"wait","durationMs":1}],"completeTask":"Pricing verified"}"#)
        XCTAssertEqual(box.last?.taskComplete?.summary, "Pricing verified")
        XCTAssertEqual(box.last?.taskComplete?.taskId, "task-piggy-1")
        XCTAssertTrue(try resultText(doneResp).text.contains("Summary: 2 requests"))

        // 4. Subsequent call has no active taskId
        _ = try await call(mcp, tool: "usemac_observe", arguments: #"{"tabId":88}"#)
        XCTAssertNil(box.last?.taskId)
    }

    func testInlineImageReturnedForNativeScreenshotObserveAndAct() async throws {
        try FileManager.default.createDirectory(atPath: UseMacDefaults.captureDirectory, withIntermediateDirectories: true)
        let captureFile = (UseMacDefaults.captureDirectory as NSString).appendingPathComponent("native-inline-\(UUID().uuidString).jpg")
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xD9])
        let fakeB64 = fakeJPEG.base64EncodedString()
        try fakeJPEG.write(to: URL(fileURLWithPath: captureFile))
        defer { try? FileManager.default.removeItem(atPath: captureFile) }

        let (mcp, box) = makeServer { req in
            switch req.method {
            case .screenshot:
                return .success(id: req.id, latencyMs: 2.0, screenshot: ScreenshotResult(
                    path: captureFile, width: 640, height: 480, byteCount: fakeJPEG.count, latencyMs: 2.0, base64Data: fakeB64
                ))
            case .observe:
                return .success(id: req.id, latencyMs: 3.0, snapshot: WindowSnapshot(
                    app: AppDescriptor(pid: 12, name: "Notes"),
                    timestampMs: 1,
                    latencyMs: 3.0,
                    elements: [],
                    screenshotPath: captureFile
                ))
            case .act:
                return .success(id: req.id, latencyMs: 4.0, actionResult: BatchActionResult(
                    success: true,
                    totalLatencyMs: 4.0,
                    stepResults: [],
                    observation: WindowSnapshot(app: AppDescriptor(pid: 12, name: "Notes"), timestampMs: 2, latencyMs: 2.0, elements: [], screenshotPath: captureFile),
                    networkErrors: ["500 POST /api/save"],
                    dirtyRect: ScreenRect(x: 10, y: 20, width: 300, height: 120),
                    visualDeltaOCR: "Saved successfully"
                ))
            default:
                return .success(id: req.id, latencyMs: 1.0)
            }
        }
        defer { mcp.close() }

        // 1. Native usemac_screenshot defaults returnImageContent to true!
        let shotResp = try await call(mcp, tool: "usemac_screenshot", arguments: #"{"app":"Notes","diffCrop":true}"#)
        XCTAssertEqual(box.last?.screenshot?.includeBase64, true)
        XCTAssertEqual(box.last?.screenshot?.diffCrop, true)
        let shotBlocks = try XCTUnwrap((shotResp["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(shotBlocks.count, 2)
        XCTAssertEqual(shotBlocks[1]["type"] as? String, "image")
        XCTAssertEqual(shotBlocks[1]["data"] as? String, fakeB64)

        // 2. Native usemac_observe(returnImageContent: true) reads from screenshotPath inside captureDirectory
        let obsResp = try await call(mcp, tool: "usemac_observe", arguments: #"{"app":"Notes","returnImageContent":true}"#)
        XCTAssertEqual(box.last?.observe?.includeScreenshot, true)
        let obsBlocks = try XCTUnwrap((obsResp["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(obsBlocks.count, 2)
        XCTAssertEqual(obsBlocks[1]["type"] as? String, "image")
        XCTAssertEqual(obsBlocks[1]["data"] as? String, fakeB64)

        // 3. Native usemac_act(returnImageContent: true) returns inline image + formats networkErrors/dirtyRect/visualDeltaOCR
        let actResp = try await call(mcp, tool: "usemac_act", arguments: #"{"app":"Notes","returnImageContent":true,"steps":[{"action":"wait","durationMs":1}]}"#)
        XCTAssertEqual(box.last?.act?.includeScreenshot, true)
        let actBlocks = try XCTUnwrap((actResp["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(actBlocks.count, 2)
        XCTAssertEqual(actBlocks[1]["type"] as? String, "image")
        XCTAssertEqual(actBlocks[1]["data"] as? String, fakeB64)
        let actText = try XCTUnwrap(actBlocks[0]["text"] as? String)
        XCTAssertTrue(actText.contains("NetworkErrors (1):"), actText)
        XCTAssertTrue(actText.contains("500 POST /api/save"), actText)
        XCTAssertTrue(actText.contains("DirtyRect: (10,20 300x120)"), actText)
        XCTAssertTrue(actText.contains("VisualDeltaOCR: Saved successfully"), actText)
    }

    func testMaxElementsAndReturnDiffOnlyAreRespectedInMCPFormatting() async throws {
        let manyNodes = (1...300).map { i in
            ElementNode(id: "@e\(i)", role: "AXButton", title: "Btn \(i)", frame: ScreenRect(x: 0, y: Double(i), width: 20, height: 20))
        }
        let addedNode = ElementNode(id: "@e999", role: "AXStaticText", title: "Toast Saved", frame: ScreenRect(x: 0, y: 0, width: 100, height: 20))
        let diff = SnapshotDiff(added: [addedNode], removedIds: ["@e5"], changed: [], summary: "+1 -1")

        let (mcp, _) = makeServer { req in
            switch req.method {
            case .observe:
                return .success(id: req.id, latencyMs: 2.0, snapshot: WindowSnapshot(
                    app: AppDescriptor(pid: 9, name: "Notes"), timestampMs: 1, latencyMs: 2.0, elements: manyNodes
                ))
            case .act:
                return .success(id: req.id, latencyMs: 2.0, actionResult: BatchActionResult(
                    success: true,
                    totalLatencyMs: 2.0,
                    stepResults: [],
                    observation: WindowSnapshot(
                        app: AppDescriptor(pid: 9, name: "Notes"),
                        timestampMs: 2,
                        latencyMs: 2.0,
                        elements: [],
                        diff: diff
                    )
                ))
            default:
                return .success(id: req.id, latencyMs: 1.0)
            }
        }
        defer { mcp.close() }

        // Requesting maxElements: 300 must not silently truncate at 250!
        let obsResp = try await call(mcp, tool: "usemac_observe", arguments: #"{"app":"Notes","maxElements":300}"#)
        let obsText = try resultText(obsResp).text
        XCTAssertTrue(obsText.contains("@e300"), "Expected @e300 when maxElements=300 was requested")
        XCTAssertFalse(obsText.contains("more elements omitted"))

        // Delta-only snapshot (elements: [], diff != nil) must render + / - diff entries!
        let actResp = try await call(mcp, tool: "usemac_act", arguments: #"{"app":"Notes","returnDiffOnly":true,"steps":[{"action":"wait","durationMs":1}]}"#)
        let actText = try resultText(actResp).text
        XCTAssertTrue(actText.contains("+ @e999"), actText)
        XCTAssertTrue(actText.contains("- @e5"), actText)
    }

    // MARK: - Reporting effects, warnings and error codes

    func testActResultShowsEffectWarningErrorCodeAndResolvedId() async throws {
        let (mcp, _) = makeServer { request in
            let result = BatchActionResult(
                success: false,
                totalLatencyMs: 400,
                stepResults: [
                    ActionStepResult(index: 0, action: .click, success: true, mechanism: "AXPress", latencyMs: 10, message: "Clicked", effect: ActionEffect.none, warning: "AXPress returned ok but nothing changed", resolvedElementId: "@e12"),
                    ActionStepResult(index: 1, action: .setValue, success: true, mechanism: "AXValue", latencyMs: 5, effect: .changed, warning: "AX path failed, used HID"),
                    ActionStepResult(index: 2, action: .pressKey, success: false, mechanism: "hid", latencyMs: 1, message: "Notes is not frontmost", errorCode: "TARGET_NOT_FRONTMOST")
                ]
            )
            return RPCResponse.success(id: request.id, latencyMs: 1, actionResult: result)
        }
        defer { mcp.close() }

        let response = try await call(mcp, tool: "usemac_act", arguments: #"{"app":"Notes","steps":[{"action":"wait"}]}"#)
        let (text, isError) = try resultText(response)
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("target=@e12"), text)
        XCTAssertTrue(text.contains("no visible effect (effect=none): AXPress returned ok but nothing changed"), text)
        XCTAssertTrue(text.contains("effect=changed"), text)
        XCTAssertTrue(text.contains("WARNING: AX path failed, used HID"), text)
        XCTAssertTrue(text.contains("FAIL [TARGET_NOT_FRONTMOST]"), text)
        XCTAssertTrue(text.contains("Next: "), text)
        XCTAssertTrue(text.contains("foreground: true"), text)
    }

    func testRPCErrorsCarryANextStepHint() async throws {
        let (mcp, _) = makeServer { request in
            RPCResponse.failure(id: request.id, code: "RESTRICTED_PAGE", message: "The extension cannot script chromewebstore.google.com")
        }
        defer { mcp.close() }

        let response = try await call(mcp, tool: "usemac_browser_observe", arguments: #"{"tabId":5}"#)
        let (text, isError) = try resultText(response)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.hasPrefix("Error [RESTRICTED_PAGE]: "), text)
        XCTAssertTrue(text.contains("activate: true"), text)
        XCTAssertTrue(text.contains("Google Chrome"), text)
    }

    func testEveryNewErrorCodeHasAHint() {
        for code in ["TARGET_NOT_FRONTMOST", "STALE_SNAPSHOT", "USER_ACTIVE", "ELEMENT_NOT_FOUND", "WAIT_TIMEOUT", "RESTRICTED_PAGE", "CAPTURE_TOO_SMALL", "POLICY_BLOCKED", "SELF_TARGET_BLOCKED", "TARGET_BLOCKED", "DAEMON_REQUIRED"] {
            XCTAssertNotNil(UseMacErrorGuide.hint(for: code), "Missing hint for \(code)")
        }
        XCTAssertNil(UseMacErrorGuide.hint(for: "SOMETHING_ELSE"))
    }

    // MARK: - Client-side element filter (usemac find / observe --role --text)

    private let nodes: [ElementNode] = [
        ElementNode(id: "@e1", role: "AXButton", title: "Salvar", frame: ScreenRect(x: 0, y: 0, width: 10, height: 10)),
        ElementNode(id: "@e2", role: "AXTextField", title: "Endereço", value: "Rua São João", frame: ScreenRect(x: 0, y: 0, width: 10, height: 10)),
        ElementNode(id: "@e3", role: "AXButton", title: "Salvar como…", frame: ScreenRect(x: 0, y: 0, width: 10, height: 10)),
        ElementNode(id: "@e4", role: "AXRow", value: "report.pdf", frame: ScreenRect(x: 0, y: 0, width: 0, height: 0), actions: ["AXOpen"], offscreen: true)
    ]

    func testFilterRoleWithOrWithoutAXPrefix() {
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(role: "button")).map(\.id), ["@e1", "@e3"])
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(role: "AXButton")).map(\.id), ["@e1", "@e3"])
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(role: "textfield")).map(\.id), ["@e2"])
        XCTAssertTrue(ClientElementFilter.filter(nodes, ElementMatch(role: "butt")).isEmpty, "Role is compared whole, not as a substring")
    }

    func testFilterTextIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(title: "endereco")).map(\.id), ["@e2"])
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(value: "SAO JOAO")).map(\.id), ["@e2"])
        // text covers title and value.
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(text: "report")).map(\.id), ["@e4"])
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(text: "salvar")).map(\.id), ["@e1", "@e3"])
        // title does not look at the value.
        XCTAssertTrue(ClientElementFilter.filter(nodes, ElementMatch(title: "report")).isEmpty)
    }

    func testFilterExactAndIndex() {
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(title: "salvar", exact: true)).map(\.id), ["@e1"])
        XCTAssertEqual(ClientElementFilter.resolve(nodes, ElementMatch(role: "button", index: 1))?.id, "@e3")
        XCTAssertEqual(ClientElementFilter.resolve(nodes, ElementMatch(role: "button"))?.id, "@e1")
        XCTAssertNil(ClientElementFilter.resolve(nodes, ElementMatch(role: "button", index: 5)))
        // All given fields must match.
        XCTAssertEqual(ClientElementFilter.filter(nodes, ElementMatch(role: "row", text: "pdf")).map(\.id), ["@e4"])
        XCTAssertTrue(ClientElementFilter.filter(nodes, ElementMatch(role: "button", text: "pdf")).isEmpty)
    }

    // MARK: - Socket path decoding of the same fields

    func testSocketRequestDecodesNewFields() throws {
        let json = #"{"method":"act","act":{"app":"Finder","foreground":true,"allowStaleSnapshot":false,"expectWindowTitle":"Downloads","steps":[{"action":"axAction","match":{"role":"row","text":"report.pdf"},"actionName":"AXOpen"}]}}"#
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(json.utf8))
        let batch = try XCTUnwrap(request.act)
        XCTAssertEqual(batch.foreground, true)
        XCTAssertEqual(batch.allowStaleSnapshot, false)
        XCTAssertEqual(batch.expectWindowTitle, "Downloads")
        XCTAssertEqual(batch.steps.first?.match?.role, "row")
        XCTAssertEqual(batch.steps.first?.actionName, "AXOpen")

        let openJSON = #"{"method":"browser_open","browserOpen":{"url":"","tabId":3,"activate":true}}"#
        let open = try XCTUnwrap(try JSONDecoder().decode(RPCRequest.self, from: Data(openJSON.utf8)).browserOpen)
        XCTAssertEqual(open.activate, true)
        XCTAssertEqual(open.url, "")

        let observeJSON = #"{"method":"observe","observe":{"app":"Notes","includeOffscreen":false}}"#
        let observe = try XCTUnwrap(try JSONDecoder().decode(RPCRequest.self, from: Data(observeJSON.utf8)).observe)
        XCTAssertEqual(observe.includeOffscreen, false)
    }
}
