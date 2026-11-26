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

    func testSchemasExposeNewFields() async throws {
        let (mcp, _) = makeServer()
        defer { mcp.close() }
        let tools = try await toolList(mcp)
        XCTAssertEqual(tools.count, 17)

        let actProps = try properties(of: "usemac_act", in: tools)
        for key in ["expectWindowTitle", "allowStaleSnapshot", "foreground", "steps"] {
            XCTAssertNotNil(actProps[key], "usemac_act is missing \(key)")
        }
        let stepProps = try XCTUnwrap(((actProps["steps"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        let actions = try XCTUnwrap((stepProps["action"] as? [String: Any])?["enum"] as? [String])
        for action in ["scrollIntoView", "axAction", "waitFor", "click", "uploadFile", "openURL"] {
            XCTAssertTrue(actions.contains(action), "usemac_act step enum is missing \(action)")
        }
        for key in ["match", "actionName", "timeoutMs", "gone", "elementId", "files"] {
            XCTAssertNotNil(stepProps[key], "usemac_act step is missing \(key)")
        }
        let matchProps = try XCTUnwrap((stepProps["match"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual(Set(matchProps.keys), ["role", "title", "value", "text", "exact", "index"])
        XCTAssertEqual((matchProps["index"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((matchProps["exact"] as? [String: Any])?["type"] as? String, "boolean")

        // Accessibility-only steps are not offered to the browser tool.
        let browserActProps = try properties(of: "usemac_browser_act", in: tools)
        let browserStepProps = try XCTUnwrap(((browserActProps["steps"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        let browserActions = try XCTUnwrap((browserStepProps["action"] as? [String: Any])?["enum"] as? [String])
        XCTAssertFalse(browserActions.contains("axAction"))
        XCTAssertTrue(browserActions.contains("navigate"))
        XCTAssertNil(browserStepProps["match"])

        let observeProps = try properties(of: "usemac_observe", in: tools)
        XCTAssertEqual((observeProps["includeOffscreen"] as? [String: Any])?["type"] as? String, "boolean")

        let openTool = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "usemac_browser_open" }))
        let openSchema = try XCTUnwrap(openTool["inputSchema"] as? [String: Any])
        let openProps = try XCTUnwrap(openSchema["properties"] as? [String: Any])
        XCTAssertNotNil(openProps["activate"])
        XCTAssertNotNil(openProps["newWindow"])
        XCTAssertFalse((openSchema["required"] as? [String] ?? []).contains("url"), "url is optional for tabId + activate")
    }

    func testInstructionsCoverTheReliabilityRules() async throws {
        let (mcp, _) = makeServer()
        defer { mcp.close() }
        let output = await mcp.processLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        let raw = try XCTUnwrap(output)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let instructions = try XCTUnwrap((obj["result"] as? [String: Any])?["instructions"] as? String)
        for phrase in ["untrusted data", "background", "match", "effect", "RESTRICTED_PAGE", "newWindow", "uploadFile", "foreground", "USER_ACTIVE", "POLICY_BLOCKED", "SELF_TARGET_BLOCKED", "TARGET_BLOCKED"] {
            XCTAssertTrue(instructions.contains(phrase), "Instructions should mention \(phrase)")
        }
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
