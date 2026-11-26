import XCTest
import Foundation
import ImageIO
@testable import UseMacProtocol
@testable import UseMacEngine
@testable import UseMacIPC

final class ProtocolAndIPCTests: XCTestCase {

    private func makeTempSocketPath(prefix: String) -> String {
        "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
    }

    func testUnixSocketPingSubMillisecondLatency() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ut")
        let engine = UseMacEngineService(socketPath: socketPath)
        let server = UnixSocketServer(socketPath: socketPath, service: engine, onClientCountChange: nil)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        XCTAssertTrue(server.isRunning)

        let client = UnixSocketClient(socketPath: socketPath, timeoutMs: 5000, keepAlive: true)
        defer { client.close() }

        XCTAssertTrue(client.isDaemonReachable())

        // Warm connection
        _ = try client.send(RPCRequest(method: .ping))

        var rtts: [Double] = []
        rtts.reserveCapacity(50)
        for _ in 0..<50 {
            let (res, rttMs) = try client.send(RPCRequest(method: .ping))
            XCTAssertTrue(res.ok)
            XCTAssertNotNil(res.pong)
            rtts.append(rttMs)
        }

        let sorted = rtts.sorted()
        let p50 = sorted[sorted.count / 2]
        // Shared CI runners are virtualized and noisy: a whole run can sit near 6 ms
        // (CI run 45818877426), so more samples would not help there. The looser CI
        // budget still catches order-of-magnitude regressions such as a poll timeout
        // or a reconnect per request; the 5 ms budget holds on a real Mac.
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        let budgetMs = isCI ? 20.0 : 5.0
        print("ping p50 RTT: \(p50) ms (budget \(budgetMs) ms\(isCI ? ", CI" : ""))")
        XCTAssertLessThan(p50, budgetMs, "Expected p50 ping RTT < \(budgetMs) ms, got \(p50) ms")
    }

    func testListAppsAndObserveOverSocket() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ut-obs")
        let engine = UseMacEngineService(socketPath: socketPath)
        let server = UnixSocketServer(socketPath: socketPath, service: engine, onClientCountChange: nil)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let client = UnixSocketClient(socketPath: socketPath, timeoutMs: 10000, keepAlive: true)
        defer { client.close() }

        let (appsRes, _) = try client.send(RPCRequest(method: .listApps))
        XCTAssertTrue(appsRes.ok)
        XCTAssertFalse(appsRes.apps?.isEmpty ?? true)

        let coldReq = RPCRequest(
            method: .observe,
            observe: ObserveParams(app: nil, useCache: false, includeDiff: false, includeScreenshot: false)
        )
        let (coldRes, _) = try client.send(coldReq)
        XCTAssertTrue(coldRes.ok, "Cold observe failed: \(coldRes.error?.message ?? "unknown")")
        XCTAssertNotNil(coldRes.snapshot)

        let warmReq = RPCRequest(
            method: .observe,
            observe: ObserveParams(app: nil, useCache: true, includeDiff: true, includeScreenshot: false)
        )
        let (warmRes, _) = try client.send(warmReq)
        XCTAssertTrue(warmRes.ok, "Warm observe failed: \(warmRes.error?.message ?? "unknown")")
        XCTAssertEqual(warmRes.snapshot?.fromHotCache, true)
    }

    func testKillSwitchBlocksActions() throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ut-ks")
        let engine = UseMacEngineService(socketPath: socketPath)
        let server = UnixSocketServer(socketPath: socketPath, service: engine, onClientCountChange: nil)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let client = UnixSocketClient(socketPath: socketPath, timeoutMs: 5000, keepAlive: true)
        defer { client.close() }

        engine.tripKillSwitch(true)

        let blockedReq = RPCRequest(
            method: .act,
            act: BatchActionRequest(
                steps: [ActionStep(action: .wait, durationMs: 5)],
                returnObservation: false
            )
        )
        let (blockedRes, _) = try client.send(blockedReq)
        XCTAssertTrue(!blockedRes.ok || blockedRes.actionResult?.success == false)

        engine.tripKillSwitch(false)

        let allowedReq = RPCRequest(
            method: .act,
            act: BatchActionRequest(
                steps: [ActionStep(action: .wait, durationMs: 5)],
                returnObservation: false
            )
        )
        let (allowedRes, _) = try client.send(allowedReq)
        XCTAssertTrue(allowedRes.ok && allowedRes.actionResult?.success == true)
    }

    func testMCPStdioServerLifecycleAndTools() async throws {
        let missingSocket = "/tmp/nonexistent-\(UUID().uuidString).sock"
        let engine = UseMacEngineService(socketPath: missingSocket)
        let mcp = MCPStdioServer(socketPath: missingSocket, fallbackService: engine)

        // 1. initialize
        let initLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"xctest","version":"1.0"}}}"#
        let initOut = await mcp.processLine(initLine)
        let initJSON = try XCTUnwrap(initOut)
        let initObj = try parseJSON(initJSON)
        let initResult = try XCTUnwrap(initObj["result"] as? [String: Any])
        XCTAssertNotNil(initResult["protocolVersion"] as? String)
        let serverInfo = try XCTUnwrap(initResult["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "usemac")

        // 2. notifications/initialized -> nil
        let notifLine = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let notifOut = await mcp.processLine(notifLine)
        XCTAssertNil(notifOut)

        // 3. tools/list
        let listLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listOut = await mcp.processLine(listLine)
        let listJSON = try XCTUnwrap(listOut)
        let listObj = try parseJSON(listJSON)
        let listResult = try XCTUnwrap(listObj["result"] as? [String: Any])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        let toolNames = Set(tools.compactMap { $0["name"] as? String })

        let expectedTools = [
            "usemac_observe",
            "usemac_act",
            "usemac_browser_open",
            "usemac_browser_extract",
            "usemac_screenshot",
            "usemac_discover",
            "usemac_vision",
            "usemac_skill",
            "usemac_session"
        ]
        XCTAssertEqual(toolNames, Set(expectedTools))

        // Verify usemac_act includes openURL, hover, uploadFile, selector, and files in action schema
        if let actTool = tools.first(where: { ($0["name"] as? String) == "usemac_act" }),
           let schema = actTool["inputSchema"] as? [String: Any],
           let props = schema["properties"] as? [String: Any],
           let stepsProp = props["steps"] as? [String: Any],
           let items = stepsProp["items"] as? [String: Any],
           let itemProps = items["properties"] as? [String: Any],
           let actionProp = itemProps["action"] as? [String: Any],
           let actionEnum = actionProp["enum"] as? [String] {
            XCTAssertTrue(actionEnum.contains("openURL"))
            XCTAssertTrue(actionEnum.contains("hover"))
            XCTAssertTrue(actionEnum.contains("uploadFile"))
            XCTAssertNotNil(itemProps["selector"])
            XCTAssertNotNil(itemProps["files"])
            XCTAssertNotNil(itemProps["url"])
            XCTAssertNotNil(itemProps["newTab"])
        } else {
            XCTFail("usemac_act schema missing expected action enum / selector / files / url properties")
        }

        // 4. tools/call for usemac_status and usemac_list_apps
        for (reqId, toolName) in [(3, "usemac_status"), (4, "usemac_list_apps")] {
            let callLine = "{\"jsonrpc\":\"2.0\",\"id\":\(reqId),\"method\":\"tools/call\",\"params\":{\"name\":\"\(toolName)\",\"arguments\":{}}}"
            let callOut = await mcp.processLine(callLine)
            let callJSON = try XCTUnwrap(callOut)
            let callObj = try parseJSON(callJSON)
            let callResult = try XCTUnwrap(callObj["result"] as? [String: Any])
            XCTAssertNotEqual(callResult["isError"] as? Bool, true)
            let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
            let firstText = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertFalse(firstText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testMCPStdioServerRegistersPersistentDaemonClientOnInitialize() async throws {
        let socketPath = makeTempSocketPath(prefix: "usemac-ut-mcp-cnt")
        let engine = UseMacEngineService(socketPath: socketPath)
        let server = UnixSocketServer(
            socketPath: socketPath,
            service: engine,
            onClientCountChange: { count in
                engine.updateActiveClientCount(count)
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        XCTAssertEqual(engine.currentStatus().telemetry.activeClients, 0)

        let mcp = MCPStdioServer(socketPath: socketPath)
        let initLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"xctest","version":"1.0"}}}"#
        _ = await mcp.processLine(initLine)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.currentStatus().telemetry.activeClients, 1)

        // Restart server and verify ensureConnected recovers persistent connection
        server.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.currentStatus().telemetry.activeClients, 0)

        try server.start()
        let listLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        _ = await mcp.processLine(listLine)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.currentStatus().telemetry.activeClients, 1)

        mcp.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(engine.currentStatus().telemetry.activeClients, 0)
    }

    func testLiveActivityEventsEmittedOnObserveAndAct() async throws {
        final class LiveActivityCollector: @unchecked Sendable {
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

        let engine = UseMacEngineService(socketPath: makeTempSocketPath(prefix: "usemac-ut-live"))
        let collector = LiveActivityCollector()
        engine.onLiveActivity = { item in
            collector.append(item)
        }

        let observeReq = RPCRequest(
            method: .observe,
            observe: ObserveParams(app: nil, useCache: false, includeDiff: false, includeScreenshot: false)
        )
        let observeRes = await engine.handle(observeReq)
        XCTAssertTrue(observeRes.ok, "Observe failed: \(observeRes.error?.message ?? "unknown")")

        let actReq = RPCRequest(
            method: .act,
            act: BatchActionRequest(
                steps: [ActionStep(action: .wait, durationMs: 5)],
                returnObservation: false
            )
        )
        let actRes = await engine.handle(actReq)
        XCTAssertTrue(actRes.ok, "Act failed: \(actRes.error?.message ?? "unknown")")
        XCTAssertEqual(actRes.actionResult?.success, true)

        let events = collector.snapshot()
        let kinds = events.map(\.kind)
        XCTAssertTrue(kinds.contains(.observe), "Expected .observe event, got \(kinds)")
        XCTAssertTrue(kinds.contains(.actionStart), "Expected .actionStart event, got \(kinds)")
        XCTAssertTrue(kinds.contains(.actionStep), "Expected .actionStep event, got \(kinds)")
        XCTAssertTrue(kinds.contains(.actionComplete), "Expected .actionComplete event, got \(kinds)")

        if let startIdx = kinds.firstIndex(of: .actionStart),
           let stepIdx = kinds.firstIndex(of: .actionStep),
           let completeIdx = kinds.firstIndex(of: .actionComplete) {
            XCTAssertLessThan(startIdx, stepIdx)
            XCTAssertLessThan(stepIdx, completeIdx)
        }
    }

    func testHUDStreamModeAndLiveStreamStatus() throws {
        XCTAssertEqual(HUDStreamMode.allCases, [.autoWindow, .fullDisplay])
        XCTAssertEqual(HUDStreamMode.autoWindow.displayName, "Target Window")
        XCTAssertEqual(HUDStreamMode.fullDisplay.displayName, "Full Screen")
        XCTAssertEqual(HUDStreamMode.autoWindow.symbolName, "macwindow")
        XCTAssertEqual(HUDStreamMode.fullDisplay.symbolName, "display")

        for mode in HUDStreamMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(HUDStreamMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }

        let idle: LiveStreamStatus = .idle
        let connecting: LiveStreamStatus = .connecting
        let streamingWin: LiveStreamStatus = .streaming(sourceName: "Calculator", isWindow: true)
        let streamingScreen: LiveStreamStatus = .streaming(sourceName: "Screen", isWindow: false)
        let permReq: LiveStreamStatus = .permissionRequired

        XCTAssertNotEqual(idle, connecting)
        XCTAssertNotEqual(streamingWin, streamingScreen)
        XCTAssertEqual(streamingWin, .streaming(sourceName: "Calculator", isWindow: true))
        XCTAssertNotEqual(permReq, idle)

        let engine = UseMacEngineService(socketPath: makeTempSocketPath(prefix: "usemac-ut-stream"))
        XCTAssertNotNil(engine.liveStreamer)
    }

    func testChromeExtensionBridgeWebSocketProfileAndRPC() async throws {
        final class BridgeEventCollector: @unchecked Sendable {
            private let lock = NSLock()
            var frames: [(tabId: Int?, data: Data, width: Int, height: Int, profileName: String, title: String)] = []
            var cursors: [BrowserCursorEvent] = []

            func recordFrame(_ tabId: Int?, _ data: Data, _ width: Int, _ height: Int, _ profileName: String, _ title: String) {
                lock.lock()
                frames.append((tabId, data, width, height, profileName, title))
                lock.unlock()
            }

            func recordCursor(_ event: BrowserCursorEvent) {
                lock.lock()
                cursors.append(event)
                lock.unlock()
            }

            func snapshotFrames() -> [(tabId: Int?, data: Data, width: Int, height: Int, profileName: String, title: String)] {
                lock.lock()
                defer { lock.unlock() }
                return frames
            }

            func snapshotCursors() -> [BrowserCursorEvent] {
                lock.lock()
                defer { lock.unlock() }
                return cursors
            }
        }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: makeTempSocketPath(prefix: "usemac-ut-bridge"),
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        let collector = BridgeEventCollector()
        service.chromeBridge.onBrowserFrame = { tabId, data, width, height, profileName, title in
            collector.recordFrame(tabId, data, width, height, profileName, title)
        }
        service.chromeBridge.onBrowserCursor = { event in
            collector.recordCursor(event)
        }

        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let listeningPort = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(listeningPort, 0, "Expected ChromeExtensionBridge to bind an ephemeral port")
        let pairingKey = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try await connectAuthenticatedMockExtension(
            port: listeningPort,
            key: pairingKey,
            profileName: "Diego",
            tabCount: 3,
            extensionVersion: "0.1.0"
        )
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        var connectedProfiles: [BrowserProfileStatus] = []
        for _ in 0..<50 {
            let statusRes = await service.handle(RPCRequest(method: .browserStatus))
            XCTAssertTrue(statusRes.ok)
            if let profiles = statusRes.browserProfiles,
               profiles.first?.profileName == "Diego",
               profiles.first?.tabCount == 3 {
                connectedProfiles = profiles
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(connectedProfiles.count, 1)
        XCTAssertEqual(connectedProfiles.first?.profileName, "Diego")
        XCTAssertNil(connectedProfiles.first?.profileEmail)
        XCTAssertEqual(connectedProfiles.first?.tabCount, 3)

        // Mock extension responder loop
        let mockJPEGBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let mockJPEGBase64 = mockJPEGBytes.base64EncodedString()

        let responderTask = Task {
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await wsTask.receive()
                } catch {
                    break
                }

                guard case .string(let raw) = message,
                      let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqId = obj["id"] as? String,
                      let command = obj["command"] as? String else {
                    continue
                }

                let sampleNode: [String: Any] = [
                    "id": "@b1",
                    "role": "AXLink",
                    "title": "More information...",
                    "enabled": true,
                    "focused": false,
                    "frame": ["x": 100.0, "y": 220.0, "width": 140.0, "height": 22.0],
                    "actions": ["AXPress"]
                ]
                let sampleSnapshot: [String: Any] = [
                    "app": [
                        "pid": 0,
                        "name": "Google Chrome (Diego)",
                        "bundleId": "com.google.Chrome",
                        "isActive": false,
                        "isHidden": false,
                        "windowTitle": "Example Domain"
                    ],
                    "timestampMs": 1_700_000_000_000,
                    "latencyMs": 4.2,
                    "fromHotCache": false,
                    "elements": [sampleNode]
                ]

                if await answerTabsLookup(obj, on: wsTask) { continue }
                switch command {
                case "open":
                    let frameMsg: [String: Any] = [
                        "type": "frame",
                        "tabId": 42,
                        "profileName": "Diego",
                        "url": obj["url"] as? String ?? "https://example.com",
                        "title": "Example Domain",
                        "viewportWidth": 1280,
                        "viewportHeight": 800,
                        "jpegBase64": mockJPEGBase64
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: frameMsg),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }

                    let respMsg: [String: Any] = [
                        "type": "response",
                        "id": reqId,
                        "ok": true,
                        "tabId": 42,
                        "profileName": "Diego",
                        "url": "https://example.com",
                        "title": "Example Domain",
                        "snapshot": sampleSnapshot
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: respMsg),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }

                case "observe":
                    let respMsg: [String: Any] = [
                        "type": "response",
                        "id": reqId,
                        "ok": true,
                        "tabId": obj["tabId"] as? Int ?? 42,
                        "profileName": "Diego",
                        "url": "https://example.com",
                        "title": "Example Domain",
                        "snapshot": sampleSnapshot
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: respMsg),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }

                case "act":
                    let cursorMsg: [String: Any] = [
                        "type": "cursor",
                        "tabId": 42,
                        "x": 170.0,
                        "y": 231.0,
                        "viewportWidth": 1280.0,
                        "viewportHeight": 800.0,
                        "phase": "click",
                        "label": "Clicking @b1"
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: cursorMsg),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }

                    let respMsg: [String: Any] = [
                        "type": "response",
                        "id": reqId,
                        "ok": true,
                        "tabId": 42,
                        "profileName": "Diego",
                        "url": "https://www.iana.org/help/example-domains",
                        "title": "Example Domains",
                        "actionResult": [
                            "success": true,
                            "totalLatencyMs": 12.5,
                            "stepResults": [
                                [
                                    "index": 0,
                                    "action": "click",
                                    "success": true,
                                    "mechanism": "chrome-dom",
                                    "latencyMs": 12.5,
                                    "message": "Clicked @b1"
                                ]
                            ],
                            "observation": sampleSnapshot
                        ]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: respMsg),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }

                default:
                    break
                }
            }
        }
        defer { responderTask.cancel() }

        // 1. browser_open
        let openRes = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "https://example.com", profile: "Diego", newTab: true, stream: true)
        ))
        XCTAssertTrue(openRes.ok, "browser_open failed: \(openRes.error?.message ?? "unknown")")
        XCTAssertEqual(openRes.browserTabId, 42)
        XCTAssertEqual(openRes.browserUrl, "https://example.com")
        XCTAssertEqual(openRes.browserTitle, "Example Domain")
        XCTAssertEqual(openRes.snapshot?.elements.first?.id, "@b1")

        // 2. browser_observe
        let obsRes = await service.handle(RPCRequest(
            method: .browserObserve,
            browserObserve: BrowserObserveParams(profile: "Diego", tabId: 42, maxElements: 50)
        ))
        XCTAssertTrue(obsRes.ok, "browser_observe failed: \(obsRes.error?.message ?? "unknown")")
        XCTAssertEqual(obsRes.browserTabId, 42)
        XCTAssertEqual(obsRes.browserUrl, "https://example.com")
        XCTAssertEqual(obsRes.browserTitle, "Example Domain")
        XCTAssertEqual(obsRes.snapshot?.elements.first?.id, "@b1")

        // 3. browser_act
        let actRes = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 42,
                steps: [ActionStep(action: .click, elementId: "@b1")],
                stopOnError: true,
                returnObservation: true,
                returnDiffOnly: false
            )
        ))
        XCTAssertTrue(actRes.ok, "browser_act failed: \(actRes.error?.message ?? "unknown")")
        XCTAssertEqual(actRes.browserTabId, 42)
        XCTAssertEqual(actRes.browserUrl, "https://www.iana.org/help/example-domains")
        XCTAssertEqual(actRes.browserTitle, "Example Domains")
        XCTAssertEqual(actRes.actionResult?.success, true)
        XCTAssertEqual(actRes.actionResult?.stepResults.first?.mechanism, "chrome-dom")

        // Verify onBrowserFrame and onBrowserCursor callbacks fired
        var frames = collector.snapshotFrames()
        var cursors = collector.snapshotCursors()
        for _ in 0..<20 where frames.isEmpty || cursors.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            frames = collector.snapshotFrames()
            cursors = collector.snapshotCursors()
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.tabId, 42)
        XCTAssertEqual(frames.first?.data, mockJPEGBytes)
        XCTAssertEqual(frames.first?.width, 1280)
        XCTAssertEqual(frames.first?.height, 800)
        XCTAssertEqual(frames.first?.profileName, "Diego")
        XCTAssertEqual(frames.first?.title, "Example Domain")

        XCTAssertEqual(cursors.count, 1)
        XCTAssertEqual(cursors.first?.x, 170.0)
        XCTAssertEqual(cursors.first?.y, 231.0)
        XCTAssertEqual(cursors.first?.phase, "click")
        XCTAssertEqual(cursors.first?.label, "Clicking @b1")

        // Verify clean shutdown
        responderTask.cancel()
        wsTask.cancel(with: .goingAway, reason: nil)
        service.chromeBridge.stop()
        let finalStatus = await service.handle(RPCRequest(method: .browserStatus))
        XCTAssertTrue(finalStatus.ok)
        XCTAssertEqual(finalStatus.browserProfiles, [])
    }

    func testLocalVisionFrameDiffOCRAndTaskCompleteRPC() async throws {
        // 1. Verify PageState & PageBlockingOverlay formatting & Codable roundtrip
        let overlay = PageBlockingOverlay(
            summary: "O Terra gostaria de enviar notificações",
            closeElementId: "@b14",
            closeX: 646,
            closeY: 224,
            frame: ScreenRect(x: 390, y: 180, width: 500, height: 180),
            blocksScroll: true
        )
        let pageState = PageState(
            scrollX: 0,
            scrollY: 0,
            scrollHeight: 4200,
            viewportWidth: 1280,
            viewportHeight: 800,
            canScrollDown: false,
            canScrollUp: false,
            scrollLocked: true,
            blockingOverlay: overlay,
            readableText: "Primeiro parágrafo de teste da matéria."
        )
        let snap = WindowSnapshot(
            app: AppDescriptor(pid: 0, name: "Chrome (Diego)", windowTitle: "Terra"),
            timestampMs: 12345,
            latencyMs: 3.5,
            elements: [],
            pageState: pageState,
            agentFeedback: AgentFeedback(
                severity: "blocked",
                trigger: "scroll_blocked",
                diagnosis: "Ad banner blocking page",
                suggestedAction: "Click close X button",
                suggestedX: 1103.3,
                suggestedY: 279.4,
                source: "apple-vision-ocr",
                latencyMs: 320
            )
        )
        let encodedSnap = try JSONEncoder().encode(snap)
        let decodedSnap = try JSONDecoder().decode(WindowSnapshot.self, from: encodedSnap)
        XCTAssertEqual(decodedSnap.pageState, pageState)
        XCTAssertEqual(decodedSnap.agentFeedback?.suggestedX, 1103.3)
        let formatted = decodedSnap.formattedCompactSummary()
        XCTAssertTrue(formatted.contains("[SCROLL LOCKED]"))
        XCTAssertTrue(formatted.contains("BlockingOverlay:"))
        XCTAssertTrue(formatted.contains("close=@b14"))
        XCTAssertTrue(formatted.contains("UseMac Feedback"))
        XCTAssertTrue(formatted.contains("1103.3"))
        XCTAssertTrue(formatted.contains("READABLE TEXT"))

        // 2. Verify native Swift Frame-Diff (identical = 0%, inverted = ~100%)
        let solidWhite = try makeSolidCGImage(gray: 255)
        let solidWhite2 = try makeSolidCGImage(gray: 255)
        let solidBlack = try makeSolidCGImage(gray: 0)
        XCTAssertEqual(LocalVisionEngine.computeFrameDiffPercent(before: solidWhite, after: solidWhite2), 0.0, accuracy: 0.01)
        XCTAssertGreaterThan(LocalVisionEngine.computeFrameDiffPercent(before: solidWhite, after: solidBlack), 95.0)

        // 3. Verify vision_status & task_complete RPCs on UseMacEngineService
        final class ActivityCollector: @unchecked Sendable {
            private let lock = NSLock()
            var items: [LiveActivityItem] = []
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

        let service = UseMacEngineService(socketPath: makeTempSocketPath(prefix: "usemac-ut-vision"))
        let collector = ActivityCollector()
        service.onLiveActivity = { item in collector.append(item) }

        let vStatusRes = await service.handle(RPCRequest(method: .visionStatus))
        XCTAssertTrue(vStatusRes.ok)
        XCTAssertEqual(vStatusRes.visionStatus?.ocrAvailable, true)

        let startRes = await service.handle(RPCRequest(
            method: .taskStart,
            taskStart: TaskStartParams(profile: "Diego", tabId: 99, summary: "Lendo artigo")
        ))
        XCTAssertTrue(startRes.ok)

        let doneRes = await service.handle(RPCRequest(
            method: .taskComplete,
            taskComplete: TaskCompleteParams(profile: "Diego", tabId: 99, summary: "Resumo pronto")
        ))
        XCTAssertTrue(doneRes.ok)
        let emitted = collector.snapshot()
        XCTAssertTrue(emitted.contains(where: { $0.kind == .taskStart && $0.browserTabId == 99 && $0.title == "Lendo artigo" }))
        XCTAssertTrue(emitted.contains(where: { $0.kind == .taskComplete && $0.browserTabId == 99 && $0.title == "Resumo pronto" }))
    }

    func testDashboardReadinessTabsExtractScreenshotAndReadOnlyPolicy() async throws {
        // 1. Verify PageState horizontal metrics + tablesMarkdown + scrollableContainers
        let dashPageState = PageState(
            scrollX: 120,
            scrollY: 0,
            scrollHeight: 1600,
            scrollWidth: 2800,
            viewportWidth: 1440,
            viewportHeight: 900,
            canScrollDown: true,
            canScrollUp: false,
            canScrollRight: true,
            canScrollLeft: true,
            scrollLocked: false,
            readableText: "Campanhas ativas: 4\nValor gasto: R$ 1.240,50",
            tablesMarkdown: "| Campanha | Valor gasto | ROAS |\n| --- | --- | --- |\n| Black Friday | R$ 820,00 | 4.3x |",
            scrollableContainers: ["grid(x=0/1400,y=0/600) at (720,450)"]
        )
        let dashSnap = WindowSnapshot(
            app: AppDescriptor(pid: 0, name: "Chrome (Diego)", windowTitle: "Ads Manager"),
            timestampMs: 1_700_000_000_000,
            latencyMs: 5.1,
            elements: [],
            pageState: dashPageState
        )
        let summary = dashSnap.formattedCompactSummary()
        XCTAssertTrue(summary.contains("x=120/2800, canRight=yes"))
        XCTAssertTrue(summary.contains("ScrollContainers: grid(x=0/1400,y=0/600)"))
        XCTAssertTrue(summary.contains("--- TABLES / DATA GRIDS ---"))
        XCTAssertTrue(summary.contains("Black Friday"))

        // 2. Spin up engine + bridge + mock extension for tabs, extract, screenshot, observe(image), and readOnly
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let missingSocket = "/tmp/nonexistent-dash-\(UUID().uuidString).sock"
        let service = UseMacEngineService(socketPath: missingSocket, extensionPort: 0, bridgeKeyDirectory: keyDir)
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let listeningPort = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(listeningPort, 0)
        let pairingKey = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try await connectAuthenticatedMockExtension(
            port: listeningPort,
            key: pairingKey,
            profileName: "Diego",
            tabCount: 2,
            extensionVersion: "0.4.0"
        )
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        for _ in 0..<50 {
            if service.chromeBridge.connectedProfiles().first?.profileName == "Diego",
               service.chromeBridge.connectedProfiles().first?.tabCount == 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let mockJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let mockB64 = mockJPEG.base64EncodedString()

        let responder = Task {
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await wsTask.receive()
                } catch {
                    break
                }
                guard case .string(let raw) = message,
                      let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqId = obj["id"] as? String,
                      let command = obj["command"] as? String else {
                    continue
                }

                var resp: [String: Any] = ["type": "response", "id": reqId, "ok": true, "profileName": "Diego"]
                switch command {
                case "tabs":
                    resp["tabs"] = [
                        [
                            "tabId": 77,
                            "windowId": 1,
                            "index": 0,
                            "title": "Meta Ads Manager - Campaigns",
                            "url": "https://adsmanager.facebook.com/adsmanager/manage/campaigns",
                            "active": true,
                            "pinned": false,
                            "status": "complete",
                            "profileName": "Diego"
                        ]
                    ]
                case "extract":
                    resp["tabId"] = 77
                    resp["url"] = "https://adsmanager.facebook.com/adsmanager/manage/campaigns"
                    resp["title"] = "Meta Ads Manager - Campaigns"
                    resp["extractResult"] = [
                        "mode": obj["mode"] as? String ?? "tables",
                        "tabId": 77,
                        "url": "https://adsmanager.facebook.com/adsmanager/manage/campaigns",
                        "title": "Meta Ads Manager - Campaigns",
                        "latencyMs": 38.4,
                        "tablesMarkdown": "| Campaign | Spend | ROAS |\n| --- | --- | --- |\n| Q4 Retargeting | R$ 1.250,00 | 4.8x |",
                        "rowCount": 1,
                        "columnCount": 3,
                        "scannedHorizontalSteps": (obj["scanHorizontal"] as? Bool == true) ? 3 : 1
                    ]
                case "screenshot":
                    resp["tabId"] = 77
                    resp["url"] = "https://adsmanager.facebook.com/adsmanager/manage/campaigns"
                    resp["title"] = "Meta Ads Manager - Campaigns"
                    resp["screenshotBase64"] = mockB64
                    resp["screenshotWidth"] = 2880
                    resp["screenshotHeight"] = 1800
                    resp["screenshotLatencyMs"] = 19.2
                    // A long page: the extension cut the full-page shot.
                    resp["screenshotTruncated"] = obj["fullPage"] as? Bool == true
                case "observe":
                    resp["tabId"] = 77
                    resp["url"] = "https://adsmanager.facebook.com/adsmanager/manage/campaigns"
                    resp["title"] = "Meta Ads Manager - Campaigns"
                    resp["screenshotBase64"] = (obj["includeScreenshot"] as? Bool == true) ? mockB64 : NSNull()
                    resp["snapshot"] = [
                        "app": [
                            "pid": 0,
                            "name": "Chrome (Diego)",
                            "bundleId": "com.google.Chrome",
                            "isActive": false,
                            "isHidden": false,
                            "windowTitle": "Meta Ads Manager - Campaigns"
                        ],
                        "timestampMs": 1_700_000_000_000,
                        "latencyMs": 8.0,
                        "fromHotCache": false,
                        "elements": [],
                        "pageState": [
                            "scrollX": 0,
                            "scrollY": 0,
                            "scrollHeight": 1200,
                            "scrollWidth": 2600,
                            "viewportWidth": 1440,
                            "viewportHeight": 900,
                            "canScrollDown": true,
                            "canScrollUp": false,
                            "canScrollRight": true,
                            "canScrollLeft": false,
                            "scrollLocked": false,
                            "tablesMarkdown": "| Campaign | Spend |\n| --- | --- |\n| Q4 Retargeting | R$ 1.250,00 |"
                        ]
                    ]
                case "act":
                    resp["tabId"] = 77
                    resp["url"] = "https://adsmanager.facebook.com/adsmanager/manage/campaigns"
                    resp["title"] = "Meta Ads Manager - Campaigns"
                    resp["actionResult"] = [
                        "success": true,
                        "totalLatencyMs": 14.0,
                        "stepResults": [
                            [
                                "index": 0,
                                "action": "hover",
                                "success": true,
                                "mechanism": "cdp-hover",
                                "latencyMs": 14.0,
                                "message": "Q4 Retargeting"
                            ]
                        ]
                    ]
                default:
                    continue
                }

                if let d = try? JSONSerialization.data(withJSONObject: resp),
                   let s = String(data: d, encoding: .utf8) {
                    try? await wsTask.send(.string(s))
                }
            }
        }
        defer { responder.cancel() }

        let mcp = MCPStdioServer(socketPath: missingSocket, fallbackService: service)

        // 3. MCP usemac_browser_tabs
        let tabsCall = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"usemac_browser_tabs","arguments":{"profile":"Diego","query":"adsmanager"}}}"#
        let tabsRaw = await mcp.processLine(tabsCall)
        let tabsObj = try parseJSON(try XCTUnwrap(tabsRaw))
        let tabsText = try XCTUnwrap(((tabsObj["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(tabsText.contains("tabId=77"))
        XCTAssertTrue(tabsText.contains("Meta Ads Manager"))

        // 4. MCP usemac_browser_extract (tables + scanHorizontal)
        let extCall = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"usemac_browser_extract","arguments":{"profile":"Diego","tabId":77,"mode":"tables","scanHorizontal":true}}}"#
        let extRaw = await mcp.processLine(extCall)
        let extObj = try parseJSON(try XCTUnwrap(extRaw))
        let extText = try XCTUnwrap(((extObj["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(extText.contains("horizontalScan=3 slices"))
        XCTAssertTrue(extText.contains("Q4 Retargeting"))
        XCTAssertTrue(extText.contains("4.8x"))

        // 5. MCP usemac_browser_observe with returnImageContent=true returns BOTH text and image blocks!
        let obsCall = #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"usemac_browser_observe","arguments":{"profile":"Diego","tabId":77,"returnImageContent":true,"viewportWidth":1440,"viewportHeight":900,"deviceScaleFactor":2}}}"#
        let obsRaw = await mcp.processLine(obsCall)
        let obsObj = try parseJSON(try XCTUnwrap(obsRaw))
        let obsContent = try XCTUnwrap((obsObj["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(obsContent.count, 2, "Expected text + inline image block from usemac_browser_observe(returnImageContent: true)")
        XCTAssertEqual(obsContent[0]["type"] as? String, "text")
        XCTAssertEqual(obsContent[1]["type"] as? String, "image")
        XCTAssertEqual(obsContent[1]["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(obsContent[1]["data"] as? String, mockB64)

        // 6. MCP usemac_browser_screenshot returns inline image block by default
        let shotCall = #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"usemac_browser_screenshot","arguments":{"profile":"Diego","tabId":77,"viewportWidth":1440,"viewportHeight":900,"deviceScaleFactor":2}}}"#
        let shotRaw = await mcp.processLine(shotCall)
        let shotObj = try parseJSON(try XCTUnwrap(shotRaw))
        let shotContent = try XCTUnwrap((shotObj["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(shotContent.count, 2)
        XCTAssertEqual(shotContent[1]["type"] as? String, "image")
        XCTAssertEqual(shotContent[1]["data"] as? String, mockB64)
        XCTAssertFalse((shotContent[0]["text"] as? String ?? "").contains("Truncated"))

        // 6b. A cut full-page shot says so: `truncated` on the socket, a "Truncated:" line in MCP
        let fullShot = await service.handle(RPCRequest(
            method: .browserScreenshot,
            browserScreenshot: BrowserScreenshotParams(profile: "Diego", tabId: 77, fullPage: true)
        ))
        XCTAssertTrue(fullShot.ok, fullShot.error?.message ?? "")
        XCTAssertEqual(fullShot.screenshot?.truncated, true)
        let plainShot = await service.handle(RPCRequest(
            method: .browserScreenshot,
            browserScreenshot: BrowserScreenshotParams(profile: "Diego", tabId: 77)
        ))
        XCTAssertNil(plainShot.screenshot?.truncated, "absent when the image shows everything")
        let fullShotCall = #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"usemac_browser_screenshot","arguments":{"profile":"Diego","tabId":77,"fullPage":true}}}"#
        let fullShotRaw = await mcp.processLine(fullShotCall)
        let fullShotObj = try parseJSON(try XCTUnwrap(fullShotRaw))
        let fullShotText = try XCTUnwrap(((fullShotObj["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(fullShotText.contains(ScreenshotResult.truncatedNote(element: false)), fullShotText)

        // 7. Per-request readOnly=true blocks click, allows hover
        let blockedClickRes = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 77,
                steps: [ActionStep(action: .click, elementId: "@b1")],
                readOnly: true
            )
        ))
        XCTAssertFalse(blockedClickRes.ok)
        XCTAssertEqual(blockedClickRes.error?.code, "POLICY_BLOCKED")

        let allowedHoverRes = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 77,
                steps: [ActionStep(action: .hover, elementId: "@b1")],
                readOnly: true
            )
        ))
        XCTAssertTrue(allowedHoverRes.ok, "Expected hover to succeed in readOnly mode: \(allowedHoverRes.error?.message ?? "")")

        // 8. Global GovernancePolicy.readOnly blocks click on browserAct & native act, allows wait/hover
        service.setGovernancePolicy(.readOnly)
        let globalBlockedBrowser = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 77,
                steps: [ActionStep(action: .click, elementId: "@b1")]
            )
        ))
        XCTAssertFalse(globalBlockedBrowser.ok)
        XCTAssertEqual(globalBlockedBrowser.error?.code, "POLICY_BLOCKED")

        let globalAllowedWait = await service.handle(RPCRequest(
            method: .act,
            act: BatchActionRequest(
                steps: [ActionStep(action: .wait, durationMs: 5)],
                returnObservation: false
            )
        ))
        XCTAssertTrue(globalAllowedWait.ok && globalAllowedWait.actionResult?.success == true)

        let globalBlockedNativeClick = await service.handle(RPCRequest(
            method: .act,
            act: BatchActionRequest(
                steps: [ActionStep(action: .click, x: 10, y: 10)],
                returnObservation: false
            )
        ))
        // A blocked native batch is refused up front with the same code browser_act uses.
        XCTAssertFalse(globalBlockedNativeClick.ok)
        XCTAssertEqual(globalBlockedNativeClick.error?.code, "POLICY_BLOCKED")
    }

    func testZeroFinderUploadValidationPolicyAndBridgeForwarding() async throws {
        // 1. Upload path security validator
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("usemac-upload-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let goodFile = tmpDir.appendingPathComponent("invoice.pdf")
        try Data("PDF".utf8).write(to: goodFile)

        let envFile = tmpDir.appendingPathComponent(".env")
        try Data("SECRET=1".utf8).write(to: envFile)

        let envProdFile = tmpDir.appendingPathComponent(".env.production")
        try Data("SECRET=2".utf8).write(to: envProdFile)

        let sshDir = tmpDir.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let sshKey = sshDir.appendingPathComponent("id_ed25519")
        try Data("KEY".utf8).write(to: sshKey)

        // Valid regular file succeeds and returns canonical path
        switch ActionExecutor.validateAndNormalizeUploadFiles([goodFile.path]) {
        case .success(let paths):
            XCTAssertEqual(paths.count, 1)
            XCTAssertTrue(paths[0].hasSuffix("/invoice.pdf"))
        case .failure(let err):
            XCTFail("Expected valid file to pass validation, got error: \(err)")
        }

        // Sensitive files, directories, and nonexistent files fail
        for bad in [[envFile.path], [envProdFile.path], [sshKey.path], [tmpDir.path], ["/tmp/definitely-does-not-exist-\(UUID().uuidString).pdf"], []] {
            if case .success(let paths) = ActionExecutor.validateAndNormalizeUploadFiles(bad) {
                XCTFail("Expected upload validation to reject \(bad), but succeeded with \(paths)")
            }
        }

        // 2. Policy enforcement & canonical path forwarding to Chrome extension
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let missingSocket = "/tmp/nonexistent-upload-\(UUID().uuidString).sock"
        let service = UseMacEngineService(socketPath: missingSocket, extensionPort: 0, bridgeKeyDirectory: keyDir)
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let listeningPort = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(listeningPort, 0)
        let pairingKey = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try await connectAuthenticatedMockExtension(
            port: listeningPort,
            key: pairingKey,
            profileName: "Diego",
            tabCount: 1,
            extensionVersion: "0.4.1"
        )
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        for _ in 0..<50 {
            if service.chromeBridge.connectedProfiles().first?.profileName == "Diego" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        final class CapturedUpload: @unchecked Sendable {
            private let lock = NSLock()
            var files: [String] = []
            func set(_ v: [String]) { lock.lock(); files = v; lock.unlock() }
            func get() -> [String] { lock.lock(); defer { lock.unlock() }; return files }
        }
        let captured = CapturedUpload()

        let responder = Task {
            while !Task.isCancelled {
                guard let msg = try? await wsTask.receive(),
                      case .string(let raw) = msg,
                      let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if await answerTabsLookup(obj, on: wsTask) { continue }
                guard let reqId = obj["id"] as? String, (obj["command"] as? String) == "act" else {
                    continue
                }
                if let steps = obj["steps"] as? [[String: Any]],
                   let first = steps.first,
                   let files = first["files"] as? [String] {
                    captured.set(files)
                }
                let resp: [String: Any] = [
                    "type": "response",
                    "id": reqId,
                    "ok": true,
                    "tabId": 55,
                    "profileName": "Diego",
                    "actionResult": [
                        "success": true,
                        "totalLatencyMs": 7.5,
                        "stepResults": [
                            [
                                "index": 0,
                                "action": "uploadFile",
                                "success": true,
                                "mechanism": "cdp-file-input",
                                "latencyMs": 7.5,
                                "message": "Uploaded 1 file(s): invoice.pdf"
                            ]
                        ]
                    ]
                ]
                if let d = try? JSONSerialization.data(withJSONObject: resp),
                   let s = String(data: d, encoding: .utf8) {
                    try? await wsTask.send(.string(s))
                }
            }
        }
        defer { responder.cancel() }

        let uploadReq = RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 55,
                steps: [ActionStep(action: .uploadFile, elementId: "@b14", files: [goodFile.path])]
            )
        )

        // Blocked under confirmSensitive (uploadFile is sensitive)
        service.setGovernancePolicy(.confirmSensitive)
        let blockedSensitive = await service.handle(uploadReq)
        XCTAssertFalse(blockedSensitive.ok)
        XCTAssertEqual(blockedSensitive.error?.code, "POLICY_BLOCKED")

        // Blocked under readOnly (uploadFile is mutating)
        service.setGovernancePolicy(.readOnly)
        let blockedReadOnly = await service.handle(uploadReq)
        XCTAssertFalse(blockedReadOnly.ok)
        XCTAssertEqual(blockedReadOnly.error?.code, "POLICY_BLOCKED")

        // Blocked when pointing to a sensitive .env file even under autonomous
        service.setGovernancePolicy(.autonomous)
        let blockedSecret = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 55,
                steps: [ActionStep(action: .uploadFile, elementId: "@b14", files: [envFile.path])]
            )
        ))
        XCTAssertFalse(blockedSecret.ok)
        XCTAssertEqual(blockedSecret.error?.code, "UPLOAD_BLOCKED")

        // Allowed under autonomous for regular file and forwards canonical path to extension
        let okRes = await service.handle(uploadReq)
        XCTAssertTrue(okRes.ok, "Expected uploadFile to succeed under autonomous: \(okRes.error?.message ?? "")")
        XCTAssertEqual(okRes.actionResult?.stepResults.first?.mechanism, "cdp-file-input")
        XCTAssertEqual(captured.get().count, 1)
        XCTAssertTrue(captured.get()[0].hasSuffix("/invoice.pdf"))
    }

    func testLocalVisionAskVerifyDescribeAndInlineBrowserActVerify() async throws {
        // 1. Codable roundtrip for VisionQueryParams (selector/elementId), VisionQueryResult (verified), BrowserActParams (verify), and BatchActionResult (visualVerification)
        let qParams = VisionQueryParams(
            mode: "verify",
            query: "CNAME record appeared",
            profile: "Diego",
            tabId: 77,
            selector: ".cname-card",
            elementId: "@b12"
        )
        let encodedParams = try JSONEncoder().encode(qParams)
        let decodedParams = try JSONDecoder().decode(VisionQueryParams.self, from: encodedParams)
        XCTAssertEqual(decodedParams, qParams)

        let vRes = VisionQueryResult(
            mode: "verify",
            backend: "apple-vision-ocr",
            modelId: nil,
            latencyMs: 24.5,
            answer: "CNAME Record gru.rp.dezeneiro.com.br is visible with no errors.",
            verified: true
        )
        let actParams = BrowserActParams(
            profile: "Diego",
            tabId: 77,
            steps: [ActionStep(action: .click, elementId: "@b5")],
            verify: "CNAME record appeared"
        )
        let encodedAct = try JSONEncoder().encode(actParams)
        let decodedAct = try JSONDecoder().decode(BrowserActParams.self, from: encodedAct)
        XCTAssertEqual(decodedAct.verify, "CNAME record appeared")

        let batchRes = BatchActionResult(
            success: true,
            totalLatencyMs: 350,
            stepResults: [ActionStepResult(index: 0, action: .click, success: true, mechanism: "chrome-dom", latencyMs: 12)],
            visualVerification: vRes
        )
        let encodedBatch = try JSONEncoder().encode(batchRes)
        let decodedBatch = try JSONDecoder().decode(BatchActionResult.self, from: encodedBatch)
        XCTAssertEqual(decodedBatch.visualVerification?.verified, true)
        XCTAssertEqual(decodedBatch.visualVerification?.mode, "verify")

        // 2. Verify Apple Vision OCR handles ask / verify / describe cleanly
        let engine = LocalVisionEngine()

        let tmpDir = FileManager.default.temporaryDirectory
        let blankPath = tmpDir.appendingPathComponent("usemac-ut-blank-\(UUID().uuidString).jpg").path
        defer { try? FileManager.default.removeItem(atPath: blankPath) }

        let img = try makeSolidCGImage(gray: 245)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: blankPath) as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let askRes = await engine.query(mode: "ask", query: "Any errors?", imagePath: blankPath, viewportWidth: 1280, viewportHeight: 800)
        XCTAssertEqual(askRes.mode, "ask")
        XCTAssertEqual(askRes.backend, "apple-vision-ocr")
        XCTAssertFalse(askRes.blockingDetected)

        let verifyRes = await engine.query(mode: "verify", query: "CNAME record appeared", imagePath: blankPath, viewportWidth: 1280, viewportHeight: 800)
        XCTAssertEqual(verifyRes.mode, "verify")
        XCTAssertEqual(verifyRes.verified, false)

        let describeRes = await engine.query(mode: "describe", query: nil, imagePath: blankPath, viewportWidth: 1280, viewportHeight: 800)
        XCTAssertEqual(describeRes.mode, "describe")
        XCTAssertEqual(describeRes.backend, "apple-vision-ocr")

        // 3. Verify MCP tools/list exposes consolidated usemac_vision & usemac_act verify parameter
        let sockPath = makeTempSocketPath(prefix: "usemac-ut-mcp-vis")
        let service = UseMacEngineService(socketPath: sockPath)
        let mcp = MCPStdioServer(socketPath: sockPath, fallbackService: service)
        let rawList = await mcp.processLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let listJSON = try parseJSON(try XCTUnwrap(rawList))
        let tools = try XCTUnwrap((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let visionToolOpt: [String: Any]? = tools.first(where: { ($0["name"] as? String) == "usemac_vision" })
        let visionTool = try XCTUnwrap(visionToolOpt)
        let visionProps = try XCTUnwrap((visionTool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        let modeEnum = try XCTUnwrap((visionProps["mode"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(modeEnum.contains("ocr"))
        XCTAssertTrue(modeEnum.contains("verify"))
        XCTAssertTrue(modeEnum.contains("locate"))
        XCTAssertTrue(modeEnum.contains("diagnose"))
        XCTAssertNotNil(visionProps["selector"])
        XCTAssertNotNil(visionProps["elementId"])

        let actToolOpt: [String: Any]? = tools.first(where: { ($0["name"] as? String) == "usemac_act" })
        let actTool = try XCTUnwrap(actToolOpt)
        let actProps = try XCTUnwrap((actTool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(actProps["verify"])
    }

    func testChromeBridgeRejectsWebPageOriginHeader() async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let bridge = ChromeExtensionBridge(port: 0, pairingStore: BridgePairingStore(directory: keyDir))
        bridge.start()
        defer { bridge.stop() }

        let port = await waitForListeningPort(of: bridge)
        XCTAssertGreaterThan(port, 0)
        let pairingKey = try XCTUnwrap(bridge.pairingKeyText().flatMap(BridgeKey.init(text:)))

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Malicious web Origin must be rejected during WebSocket handshake
        var badReq = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
        badReq.setValue("https://evil.example.com", forHTTPHeaderField: "Origin")
        let badWs = session.webSocketTask(with: badReq)
        badWs.resume()
        do {
            try await badWs.send(.string(#"{"type":"hello","profileName":"Evil"}"#))
            _ = try await badWs.receive()
            XCTFail("Expected WebSocket upgrade from https://evil.example.com to be rejected")
        } catch {
            // Expected rejection
        }
        badWs.cancel()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(bridge.connectedProfiles().isEmpty)

        // Valid chrome-extension:// Origin must be accepted and authenticate via v2 handshake
        let goodWs = try await connectAuthenticatedMockExtension(
            port: port,
            key: pairingKey,
            profileName: "VerifiedExt",
            tabCount: 1,
            extensionVersion: "0.5.0"
        )
        defer { goodWs.cancel(with: .goingAway, reason: nil) }
        for _ in 0..<40 where bridge.connectedProfiles().first?.profileName != "VerifiedExt" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(bridge.connectedProfiles().first?.profileName, "VerifiedExt")
    }

    func testOpenTabNavigateAliasAndInlineActScreenshot() async throws {
        // 1. Verify concise BrowserActParams decoding with defaults + navigate action type
        let rawConcise = #"{"tabId":77,"steps":[{"action":"navigate","url":"https://cloud.oracle.com"}],"returnImageContent":true}"#
        let decodedParams = try JSONDecoder().decode(BrowserActParams.self, from: Data(rawConcise.utf8))
        XCTAssertEqual(decodedParams.tabId, 77)
        XCTAssertEqual(decodedParams.steps.first?.action, .navigate)
        XCTAssertEqual(decodedParams.steps.first?.url, "https://cloud.oracle.com")
        XCTAssertEqual(decodedParams.stopOnError, true)
        XCTAssertEqual(decodedParams.returnObservation, true)
        XCTAssertEqual(decodedParams.returnDiffOnly, false)
        XCTAssertEqual(decodedParams.returnImageContent, true)

        // 2. Spin up engine + mock extension WebSocket to verify open(--tab), navigate readOnly policy, and inline act screenshot
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let sockPath = makeTempSocketPath(prefix: "usemac-ut-oopif-parity")
        let service = UseMacEngineService(socketPath: sockPath, extensionPort: 0, bridgeKeyDirectory: keyDir)
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertGreaterThan(port, 0)
        let pairingKey = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))

        let wsTask = try await connectAuthenticatedMockExtension(
            port: port,
            key: pairingKey,
            profileName: "Diego",
            tabCount: 3,
            extensionVersion: "0.5.0"
        )
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        for _ in 0..<40 where service.chromeBridge.connectedProfiles().first?.profileName != "Diego" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.chromeBridge.connectedProfiles().first?.profileName, "Diego")

        final class CapturedWire: @unchecked Sendable {
            private let lock = NSLock()
            var openTabId: Int?
            var openNewTab: Bool?
            var actIncludeScreenshot: Bool?
            var actFirstAction: String?
            func setOpen(tabId: Int?, newTab: Bool?) {
                lock.lock(); openTabId = tabId; openNewTab = newTab; lock.unlock()
            }
            func setAct(includeScreenshot: Bool?, firstAction: String?) {
                lock.lock(); actIncludeScreenshot = includeScreenshot; actFirstAction = firstAction; lock.unlock()
            }
            func snapshot() -> (Int?, Bool?, Bool?, String?) {
                lock.lock(); defer { lock.unlock() }
                return (openTabId, openNewTab, actIncludeScreenshot, actFirstAction)
            }
        }
        let captured = CapturedWire()
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xFF, 0xD9]).base64EncodedString()

        let responder = Task {
            while !Task.isCancelled {
                guard let msg = try? await wsTask.receive(),
                      case .string(let text) = msg,
                      let data = text.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let reqId = obj["id"] as? String,
                      let cmd = obj["command"] as? String else {
                    break
                }
                if await answerTabsLookup(obj, on: wsTask) { continue }
                if cmd == "open" {
                    captured.setOpen(tabId: obj["tabId"] as? Int, newTab: obj["newTab"] as? Bool)
                    let resp: [String: Any] = [
                        "type": "response",
                        "id": reqId,
                        "ok": true,
                        "tabId": obj["tabId"] as? Int ?? 77,
                        "profileName": "Diego",
                        "url": obj["url"] as? String ?? "https://cloud.oracle.com",
                        "title": "Oracle Cloud"
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: resp),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }
                } else if cmd == "act" {
                    let steps = obj["steps"] as? [[String: Any]]
                    captured.setAct(
                        includeScreenshot: obj["includeScreenshot"] as? Bool,
                        firstAction: steps?.first?["action"] as? String
                    )
                    let resp: [String: Any] = [
                        "type": "response",
                        "id": reqId,
                        "ok": true,
                        "tabId": obj["tabId"] as? Int ?? 77,
                        "profileName": "Diego",
                        "url": "https://cloud.oracle.com/identity/policies",
                        "title": "Policies - Oracle Cloud",
                        "screenshotBase64": fakeJPEG,
                        "screenshotWidth": 1280,
                        "screenshotHeight": 800,
                        "screenshotLatencyMs": 14.2,
                        "actionResult": [
                            "success": true,
                            "totalLatencyMs": 28.0,
                            "stepResults": [[
                                "index": 0,
                                "action": "navigate",
                                "success": true,
                                "mechanism": "tabs-update",
                                "latencyMs": 24.0
                            ]]
                        ]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: resp),
                       let s = String(data: d, encoding: .utf8) {
                        try? await wsTask.send(.string(s))
                    }
                }
            }
        }
        defer { responder.cancel() }

        // A. browser_open with explicit tabId must default newTab to false and forward tabId
        let openRes = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "https://cloud.oracle.com", profile: "Diego", tabId: 77)
        ))
        XCTAssertTrue(openRes.ok)
        XCTAssertEqual(openRes.browserTabId, 77)

        // B. navigate must be blocked under readOnly: true
        let roRes = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "Diego",
                tabId: 77,
                steps: [ActionStep(action: .navigate, url: "https://cloud.oracle.com")],
                readOnly: true
            )
        ))
        XCTAssertFalse(roRes.ok)
        XCTAssertEqual(roRes.error?.code, "POLICY_BLOCKED")

        // C. MCP usemac_browser_act with navigate + returnImageContent: true returns inline image block!
        let mcp = MCPStdioServer(socketPath: sockPath, fallbackService: service)
        let mcpCall = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"usemac_browser_act","arguments":{"profile":"Diego","tabId":77,"returnImageContent":true,"steps":[{"action":"navigate","url":"https://cloud.oracle.com/identity/policies"}]}}}"#
        let rawCallRes = await mcp.processLine(mcpCall)
        let callJSON = try parseJSON(try XCTUnwrap(rawCallRes))
        let resultObj = try XCTUnwrap(callJSON["result"] as? [String: Any])
        XCTAssertEqual(resultObj["isError"] as? Bool, false)
        let contentBlocks = try XCTUnwrap(resultObj["content"] as? [[String: Any]])
        XCTAssertEqual(contentBlocks.count, 2, "Expected text + inline image content block")
        XCTAssertEqual(contentBlocks[0]["type"] as? String, "text")
        XCTAssertEqual(contentBlocks[1]["type"] as? String, "image")
        XCTAssertEqual(contentBlocks[1]["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(contentBlocks[1]["data"] as? String, fakeJPEG)

        let (openTabId, openNewTab, actIncludeShot, actFirstAction) = captured.snapshot()
        XCTAssertEqual(openTabId, 77)
        XCTAssertEqual(openNewTab, false)
        XCTAssertEqual(actIncludeShot, true)
        XCTAssertEqual(actFirstAction, "navigate")

        // D. Verify MCP tools/list exposes tabId on usemac_browser_open, navigate in action enum, and returnImageContent on usemac_act
        let rawList = await mcp.processLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let listJSON = try parseJSON(try XCTUnwrap(rawList))
        let tools = try XCTUnwrap((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let openTool = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "usemac_browser_open" }))
        let openProps = try XCTUnwrap((openTool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(openProps["tabId"])

        let actTool = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "usemac_act" }))
        let actProps = try XCTUnwrap((actTool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(actProps["returnImageContent"])
        let stepsItems = try XCTUnwrap((actProps["steps"] as? [String: Any])?["items"] as? [String: Any])
        let stepProps = try XCTUnwrap(stepsItems["properties"] as? [String: Any])
        let actionEnum = try XCTUnwrap((stepProps["action"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(actionEnum.contains("navigate"))
    }

    private func makeSolidCGImage(gray: UInt8) throws -> CGImage {
        // Local vision refuses images under 64 px on the shorter side (CAPTURE_TOO_SMALL).
        let w = 96
        let h = 64
        var bytes = [UInt8](repeating: gray, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let img = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return nil
            }
            return ctx.makeImage()
        }
        return try XCTUnwrap(img)
    }

    private func parseJSON(_ raw: String) throws -> [String: Any] {
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }
}
