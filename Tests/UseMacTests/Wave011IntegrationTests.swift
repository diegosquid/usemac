import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// End-to-end integration tests for Wave 0.11 seams:
/// - Per-app & per-site Read-only and Ask policies through UseMacEngineService.handle(...)
/// - Redirected browser_open inline step governance
/// - BrowserStepValidation (`saveFile`, targetless `drag`, invalid `dialogAction`) on browser_act / browser_open
final class Wave011IntegrationTests: XCTestCase {
    private var savedRules: TargetRules!

    override func setUp() {
        super.setUp()
        savedRules = TargetRulesStore.shared.rules
    }

    override func tearDown() {
        TargetRulesStore.shared.update(savedRules, persist: false)
        super.tearDown()
    }

    private func use(_ rules: TargetRules) {
        TargetRulesStore.shared.update(rules, persist: false)
    }

    private func makeService() -> (UseMacEngineService, URL) {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-w011-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        return (service, keyDir)
    }

    func testBrowserStepValidationWiredIntoEngine() async {
        let (service, keyDir) = makeService()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let saveInBrowser = await service.handle(RPCRequest(
            id: "v1",
            method: .browserAct,
            browserAct: BrowserActParams(steps: [ActionStep(action: .saveFile, files: ["/tmp/out.txt"])])
        ))
        XCTAssertEqual(saveInBrowser.error?.code, "INVALID_REQUEST")
        XCTAssertTrue(saveInBrowser.error?.message.contains("saveFile") == true)

        let dragWithoutDest = await service.handle(RPCRequest(
            id: "v2",
            method: .browserAct,
            browserAct: BrowserActParams(steps: [ActionStep(action: .drag, elementId: "@b1")])
        ))
        XCTAssertEqual(dragWithoutDest.error?.code, "INVALID_REQUEST")
        XCTAssertTrue(dragWithoutDest.error?.message.contains("destination") == true)

        let badDialogOnAct = await service.handle(RPCRequest(
            id: "v3",
            method: .browserAct,
            browserAct: BrowserActParams(
                steps: [ActionStep(action: .click, elementId: "@b1")],
                dialogAction: "maybe"
            )
        ))
        XCTAssertEqual(badDialogOnAct.error?.code, "INVALID_REQUEST")
        XCTAssertTrue(badDialogOnAct.error?.message.contains("dialogAction") == true)

        let badDialogOnOpen = await service.handle(RPCRequest(
            id: "v4",
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "https://example.com", dialogAction: "ignore")
        ))
        XCTAssertEqual(badDialogOnOpen.error?.code, "INVALID_REQUEST")
        XCTAssertTrue(badDialogOnOpen.error?.message.contains("dialogAction") == true)
    }

    func testReadOnlySiteAllowsReadsAndScrollButBlocksMutatingActionsAndEval() async throws {
        use(TargetRules(readOnlySites: ["readonly.example"]))
        let (service, keyDir) = makeService()
        defer {
            service.chromeBridge.stop()
            try? FileManager.default.removeItem(at: keyDir)
        }
        service.chromeBridge.baseCommandTimeoutSeconds = 0.5
        service.chromeBridge.start()
        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.chromeBridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Default", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { !service.chromeBridge.connectedProfiles().isEmpty }
        XCTAssertTrue(ready)

        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask),
                      (obj["type"] as? String) == "request",
                      let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { break }
                var resp: [String: Any] = ["type": "response", "id": id, "profileName": "Default", "ok": true, "tabId": 10, "url": "https://readonly.example/docs", "title": "Docs"]
                switch command {
                case "tabs":
                    resp["tabs"] = [["tabId": 10, "title": "Docs", "url": "https://readonly.example/docs", "active": true, "usemac": true]]
                case "observe":
                    resp["snapshot"] = [
                        "app": ["pid": 1, "name": "Google Chrome", "isActive": false, "isHidden": false],
                        "timestampMs": 1,
                        "latencyMs": 1.0,
                        "fromHotCache": false,
                        "elements": []
                    ]
                case "extract":
                    resp["extractResult"] = ["mode": "text", "tabId": 10, "url": "https://readonly.example/docs", "title": "Docs", "latencyMs": 1.0, "text": "Hello"]
                case "act":
                    resp["actionResult"] = [
                        "success": true,
                        "totalLatencyMs": 1.0,
                        "stepResults": [["index": 0, "action": "scroll", "success": true, "mechanism": "dom-scroll", "latencyMs": 1.0]]
                    ]
                default:
                    break
                }
                try? await sendBridgeJSON(resp, on: wsTask)
            }
        }
        defer { responder.cancel() }

        // Read-only operations succeed.
        let obs = await service.handle(RPCRequest(id: "r1", method: .browserObserve, browserObserve: BrowserObserveParams(tabId: 10)))
        XCTAssertTrue(obs.ok, String(describing: obs.error))

        let textExt = await service.handle(RPCRequest(id: "r2", method: .browserExtract, browserExtract: BrowserExtractParams(tabId: 10, mode: "text")))
        XCTAssertTrue(textExt.ok, String(describing: textExt.error))

        let scrollAct = await service.handle(RPCRequest(
            id: "r3",
            method: .browserAct,
            browserAct: BrowserActParams(tabId: 10, steps: [ActionStep(action: .scroll, deltaY: 200)])
        ))
        XCTAssertTrue(scrollAct.ok, String(describing: scrollAct.error))

        // Mutating operations fail with POLICY_BLOCKED + TargetRules.stopHint.
        let clickAct = await service.handle(RPCRequest(
            id: "m1",
            method: .browserAct,
            browserAct: BrowserActParams(tabId: 10, steps: [ActionStep(action: .click, elementId: "@b1")])
        ))
        XCTAssertEqual(clickAct.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(clickAct.error?.hint, TargetRules.stopHint)

        let evalExt = await service.handle(RPCRequest(
            id: "m2",
            method: .browserExtract,
            browserExtract: BrowserExtractParams(tabId: 10, mode: "eval", expression: "1+1")
        ))
        XCTAssertEqual(evalExt.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(evalExt.error?.hint, TargetRules.stopHint)

        let mutatingOpen = await service.handle(RPCRequest(
            id: "m3",
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "https://readonly.example/docs", autoDismissOverlays: true)
        ))
        XCTAssertEqual(mutatingOpen.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(mutatingOpen.error?.hint, TargetRules.stopHint)
    }

    func testAskSiteInAutonomousModePromptsOnRedirectedOpenWithInlineSteps() async throws {
        use(TargetRules(askSites: ["ask.example"]))
        let (service, keyDir) = makeService()
        defer {
            service.chromeBridge.stop()
            try? FileManager.default.removeItem(at: keyDir)
        }
        XCTAssertEqual(service.getGovernancePolicy(), .autonomous)

        service.chromeBridge.baseCommandTimeoutSeconds = 0.5
        service.chromeBridge.start()
        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.chromeBridge.pairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Default", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { !service.chromeBridge.connectedProfiles().isEmpty }
        XCTAssertTrue(ready)

        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask),
                      (obj["type"] as? String) == "request",
                      let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { break }
                var resp: [String: Any] = ["type": "response", "id": id, "profileName": "Default", "ok": true, "tabId": 22, "url": "https://ask.example/checkout", "title": "Checkout"]
                switch command {
                case "open":
                    // Verify deferred inline steps were stripped before the redirect was confirmed.
                    XCTAssertNil(obj["steps"])
                    resp["snapshot"] = [
                        "app": ["pid": 1, "name": "Google Chrome", "isActive": false, "isHidden": false],
                        "timestampMs": 1,
                        "latencyMs": 1.0,
                        "fromHotCache": false,
                        "elements": []
                    ]
                case "tabs":
                    resp["tabs"] = [["tabId": 22, "title": "Checkout", "url": "https://ask.example/checkout", "active": true, "usemac": true]]
                case "act":
                    resp["actionResult"] = [
                        "success": true,
                        "totalLatencyMs": 1.0,
                        "stepResults": [["index": 0, "action": "click", "success": true, "mechanism": "dom-click", "latencyMs": 1.0]]
                    ]
                default:
                    break
                }
                try? await sendBridgeJSON(resp, on: wsTask)
            }
        }
        defer { responder.cancel() }

        let openTask = Task {
            await service.handle(RPCRequest(
                id: "ask-redir",
                method: .browserOpen,
                browserOpen: BrowserOpenParams(
                    url: "https://short.example/go",
                    steps: [ActionStep(action: .click, elementId: "@b1")]
                )
            ))
        }

        let promptShown = await waitForBridgeCondition { service.approvals.currentPrompt != nil }
        XCTAssertTrue(promptShown, "Redirect onto an Ask site must hold deferred inline steps for user approval")
        let prompt = try XCTUnwrap(service.approvals.currentPrompt)
        let click = ApprovalInputCheck.PhysicalClick(sourcePid: 0, downTime: 1, upTime: 1.1)
        XCTAssertTrue(service.approvals.decide(promptId: prompt.id, decision: .deny, click: click))

        let denied = await openTask.value
        XCTAssertEqual(denied.error?.code, "APPROVAL_DENIED")
    }
}
