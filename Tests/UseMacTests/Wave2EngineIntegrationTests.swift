import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

final class Wave2EngineIntegrationTests: XCTestCase {
    private func withBridgeEngine(
        _ body: (UseMacEngineService, UInt16, BridgeKey) async throws -> Void
    ) async throws {
        let keyDirectory = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDirectory) }

        let engine = UseMacEngineService(extensionPort: 0, bridgeKeyDirectory: keyDirectory)
        engine.chromeBridge.start()
        defer { engine.chromeBridge.stop() }
        let port = await waitForListeningPort(of: engine.chromeBridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(engine.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        try await body(engine, port, key)
    }

    /// The shared authenticated mock consumes `ready`. Split the handshake here to inspect that frame.
    private func receiveReady(
        on socket: URLSessionWebSocketTask,
        key: BridgeKey,
        profile: String,
        instanceId: String? = nil
    ) async throws -> [String: Any] {
        let clientNonce = BridgeAuth.randomNonceHex()
        var hello: [String: Any] = [
            "type": "hello", "protocol": 2, "profileName": profile, "clientNonce": clientNonce, "hasKey": true
        ]
        if let instanceId { hello["extensionInstanceId"] = instanceId }
        try await sendBridgeJSON(hello, on: socket)
        let challenge = try await receiveBridgeJSON(from: socket)
        XCTAssertEqual(challenge["type"] as? String, "challenge")
        let serverNonce = try XCTUnwrap(challenge["serverNonce"] as? String)
        let serverProof = try XCTUnwrap(challenge["serverProof"] as? String)
        XCTAssertTrue(BridgeAuth.constantTimeEquals(serverProof, BridgeAuth.serverProof(
            key: key, clientNonce: clientNonce, serverNonce: serverNonce
        )))
        try await sendBridgeJSON([
            "type": "auth", "clientProof": BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        ], on: socket)
        let ready = try await receiveBridgeJSON(from: socket)
        XCTAssertEqual(ready["type"] as? String, "ready")
        return ready
    }

    func testReadyMessageIncludesOwnedTabIdsFromProvider() async throws {
        try await withBridgeEngine { engine, port, key in
            let taskId = engine.taskTabs.start(taskId: "restore-tabs")
            engine.taskTabs.recordOpenedTab(80, taskId: taskId, profile: "Work")
            engine.taskTabs.recordOpenedTab(14, taskId: taskId, profile: "Work")
            engine.taskTabs.recordOpenedTab(92, taskId: taskId, profile: "Personal")
            let socket = try openMockExtensionSocket(port: port)
            defer { socket.cancel(with: .goingAway, reason: nil) }

            let ready = try await receiveReady(on: socket, key: key, profile: "Work")
            XCTAssertEqual(ready["ownedTabIds"] as? [Int], [14, 80])
        }
    }

    func testProfileInfoChangeSendsSyncOwnedTabsMessage() async throws {
        try await withBridgeEngine { engine, port, key in
            let taskId = engine.taskTabs.start(taskId: "restore-renamed-profile")
            engine.taskTabs.recordOpenedTab(31, taskId: taskId, profile: "Work")
            engine.taskTabs.recordOpenedTab(52, taskId: taskId, profile: "Personal")
            let socket = try await connectAuthenticatedMockExtension(port: port, key: key)
            defer { socket.cancel(with: .goingAway, reason: nil) }

            try await sendBridgeJSON(["type": "profile_info", "profileName": " Work ", "tabCount": 2], on: socket)
            let sync = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(sync["type"] as? String, "sync_owned_tabs")
            XCTAssertEqual(sync["tabIds"] as? [Int], [31])
        }
    }

    func testReadyMessageOmitsOwnedTabIdsWhenEmpty() async throws {
        try await withBridgeEngine { _, port, key in
            let socket = try openMockExtensionSocket(port: port)
            defer { socket.cancel(with: .goingAway, reason: nil) }

            let ready = try await receiveReady(on: socket, key: key, profile: "Work")
            XCTAssertNil(ready["ownedTabIds"])
        }
    }

    func testOwnershipSyncIsolatesExtensionInstancesWithSameProfileName() async throws {
        try await withBridgeEngine { engine, port, key in
            let taskId = engine.taskTabs.start(taskId: "restore-by-instance")
            let firstInstance = UUID().uuidString
            let secondInstance = UUID().uuidString
            engine.taskTabs.recordOpenedTab(31, taskId: taskId, profile: firstInstance)
            engine.taskTabs.recordOpenedTab(52, taskId: taskId, profile: secondInstance)
            engine.taskTabs.recordOpenedTab(73, taskId: taskId, profile: "Chrome")

            let firstSocket = try openMockExtensionSocket(port: port)
            defer { firstSocket.cancel(with: .goingAway, reason: nil) }
            let secondSocket = try openMockExtensionSocket(port: port)
            defer { secondSocket.cancel(with: .goingAway, reason: nil) }
            let first = try await receiveReady(on: firstSocket, key: key, profile: "Chrome", instanceId: firstInstance)
            let second = try await receiveReady(on: secondSocket, key: key, profile: "Chrome", instanceId: secondInstance)
            XCTAssertEqual(first["ownedTabIds"] as? [Int], [31])
            XCTAssertEqual(second["ownedTabIds"] as? [Int], [52])

            try await sendBridgeJSON(["type": "profile_info", "profileName": "Work"], on: secondSocket)
            let sync = try await receiveBridgeJSON(from: secondSocket)
            XCTAssertEqual(sync["type"] as? String, "sync_owned_tabs")
            XCTAssertEqual(sync["tabIds"] as? [Int], [52])
        }
    }

    func testBrowserOpenRecordsCreatedTabWhenNewTabWasFalse() async throws {
        try await withBridgeEngine { engine, port, key in
            let instanceId = UUID().uuidString
            let socket = try openMockExtensionSocket(port: port)
            defer { socket.cancel(with: .goingAway, reason: nil) }
            _ = try await receiveReady(on: socket, key: key, profile: "Chrome", instanceId: instanceId)
            let taskId = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
            let open = Task {
                await engine.handle(RPCRequest(
                    method: .browserOpen,
                    browserOpen: BrowserOpenParams(url: "https://example.com/", profile: "Chrome", newTab: false, taskId: taskId)
                ))
            }
            let wireOpen = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(wireOpen["command"] as? String, "open")
            XCTAssertEqual(wireOpen["newTab"] as? Bool, false)
            let requestId = try XCTUnwrap(wireOpen["id"] as? String)
            try await sendBridgeJSON([
                "type": "response", "id": requestId, "ok": true, "tabId": 73, "createdTab": true,
                "profileName": "Chrome", "url": "https://example.com/"
            ], on: socket)

            let opened = await open.value
            XCTAssertTrue(opened.ok)
            XCTAssertEqual(engine.taskTabs.ownedTabIds(forProfile: instanceId), [73])
            XCTAssertTrue(engine.taskTabs.ownedTabIds(forProfile: "Chrome").isEmpty)
            let completion = engine.completeTaskInline(TaskCompleteParams(keepTabs: true), taskId: taskId)
            XCTAssertEqual(completion.ownTabIds, [73])
        }
    }

    func testTaskCompleteClearsTaskWindowPinsAndPopulatesTaskAppPids() async throws {
        let app = AppDescriptor(pid: Int32.max, name: "Native fixture", bundleId: "test.native")
        let secondPid = app.pid - 1
        let engine = UseMacEngineService(observeTargetResolver: { $0 == app.name ? .app(app) : .notFound })
        let completedTask = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
        let otherTask = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
        defer {
            WindowResolver.clearPins(forTaskId: completedTask)
            WindowResolver.clearPins(forTaskId: otherTask)
        }

        let observed = await engine.handle(RPCRequest(method: .observe, observe: ObserveParams(app: app.name), taskId: completedTask))
        XCTAssertTrue(observed.ok)
        engine.taskTabs.recordApp(secondPid, taskId: completedTask)
        WindowResolver.pin(pid: app.pid, title: "Completed task window", taskId: completedTask)
        WindowResolver.pin(pid: secondPid, title: "Second completed window", taskId: completedTask)
        WindowResolver.pin(pid: app.pid, title: "Other task window", taskId: otherTask)

        let emitted = expectation(description: "Emitted the completed task's native apps")
        engine.onLiveActivity = { item in
            guard item.kind == .taskComplete else { return }
            XCTAssertEqual(item.taskId, completedTask)
            XCTAssertEqual(item.taskAppPids, [secondPid, app.pid])
            emitted.fulfill()
        }
        let done = await engine.handle(RPCRequest(method: .taskComplete, taskId: completedTask))
        XCTAssertEqual(done.taskId, completedTask)
        await fulfillment(of: [emitted], timeout: 1)
        XCTAssertNil(WindowResolver.pinnedTitle(pid: app.pid, taskId: completedTask))
        XCTAssertNil(WindowResolver.pinnedTitle(pid: secondPid, taskId: completedTask))
        XCTAssertEqual(WindowResolver.pinnedTitle(pid: app.pid, taskId: otherTask), "Other task window")
    }

    func testNativeTaskCompleteWithoutOpenedTabsDoesNotSendCloseOwnedTabs() async throws {
        try await withBridgeEngine { engine, port, key in
            engine.ownedTabCleanupDelayNs = 0
            let socket = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Work")
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let taskId = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)

            let done = await engine.handle(RPCRequest(method: .taskComplete, taskId: taskId))
            XCTAssertEqual(done.taskId, taskId)
            let control = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(control["type"] as? String, "tab_control")
            XCTAssertEqual(control["state"] as? String, "ended")

            let unexpectedClose = expectation(description: "Completing a task without browser tabs sent close_owned_tabs")
            unexpectedClose.isInverted = true
            let listener = Task {
                while let item = try? await receiveBridgeJSON(from: socket) {
                    if item["command"] as? String == "close_owned_tabs" {
                        unexpectedClose.fulfill()
                        return
                    }
                }
            }
            defer { listener.cancel() }
            await fulfillment(of: [unexpectedClose], timeout: 0.3)
        }
    }

    func testNativeObserveBlocksChromiumWindowWhenSiteRulesCannotConfirm() async {
        let savedRules = TargetRulesStore.shared.rules
        TargetRulesStore.shared.update(TargetRules(deniedSites: ["private.example"]), persist: false)
        defer { TargetRulesStore.shared.update(savedRules, persist: false) }

        let chrome = AppDescriptor(pid: Int32.max, name: "Google Chrome", bundleId: "com.google.Chrome")
        let engine = UseMacEngineService(observeTargetResolver: { $0 == chrome.name ? .app(chrome) : .notFound })
        let taskId = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
        let response = await engine.handle(RPCRequest(
            method: .observe,
            observe: ObserveParams(app: chrome.name, includeScreenshot: true),
            taskId: taskId
        ))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, TargetRules.errorCode)
        XCTAssertEqual(response.error?.message, TargetRules.unconfirmedSiteMessage(
            reason: "the window's active URL could not be read via Accessibility and the Chrome extension is not connected"
        ))
        XCTAssertNil(response.snapshot)
        XCTAssertNil(response.screenshot)
        let completion = engine.completeTaskInline(TaskCompleteParams(), taskId: taskId)
        XCTAssertEqual(completion.ownAppPids, [])
        XCTAssertEqual(completion.summary?.blocked, 1)
    }

    func testNativeVisionQueryBlocksChromiumWindowWhenSiteRulesCannotConfirm() async {
        let savedRules = TargetRulesStore.shared.rules
        TargetRulesStore.shared.update(TargetRules(deniedSites: ["private.example"]), persist: false)
        defer { TargetRulesStore.shared.update(savedRules, persist: false) }

        let chrome = AppDescriptor(pid: Int32.max, name: "Google Chrome", bundleId: "com.google.Chrome")
        let engine = UseMacEngineService(observeTargetResolver: { $0 == chrome.name ? .app(chrome) : .notFound })
        let response = await engine.handle(RPCRequest(method: .visionQuery, visionQuery: VisionQueryParams(mode: "ocr", app: chrome.name)))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, TargetRules.errorCode)
        XCTAssertEqual(response.error?.message, TargetRules.unconfirmedSiteMessage(
            reason: "the window's active URL could not be read via Accessibility and the Chrome extension is not connected"
        ))
        XCTAssertNil(response.screenshot)
        XCTAssertNil(response.visionResult)
    }

    func testScreenshotOfUnknownNamedAppDoesNotFallBackToDisplay() async {
        let engine = UseMacEngineService(observeTargetResolver: { _ in .notFound })
        let response = await engine.handle(RPCRequest(method: .screenshot, screenshot: ScreenshotRequest(app: "NonExistentAppXYZ")))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "APP_NOT_FOUND")
        XCTAssertNil(response.screenshot)
    }

    func testLegacyCleanupWaitsForInFlightBrowserOpen() async throws {
        try await withBridgeEngine { engine, port, key in
            engine.ownedTabCleanupDelayNs = 0
            let socket = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Work")
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let openingTask = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
            _ = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)

            let open = Task {
                await engine.handle(RPCRequest(
                    method: .browserOpen,
                    browserOpen: BrowserOpenParams(url: "https://example.com/", profile: "Work", taskId: openingTask)
                ))
            }
            defer { open.cancel() }
            let wireOpen = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(wireOpen["command"] as? String, "open")
            let requestId = try XCTUnwrap(wireOpen["id"] as? String)
            XCTAssertTrue(engine.taskTabs.hasPendingBrowserOpen)

            // With two running tasks, a taskless completion takes the legacy cleanup path.
            let done = await engine.handle(RPCRequest(method: .taskComplete))
            XCTAssertNil(done.taskId)
            let control = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(control["type"] as? String, "tab_control")

            // Let the cleanup run while the extension has not yet returned the newly owned tab ID.
            try await Task.sleep(nanoseconds: 250_000_000)
            try await sendBridgeJSON([
                "type": "response", "id": requestId, "ok": true, "tabId": 73,
                "profileName": "Work", "url": "https://example.com/"
            ], on: socket)
            let opened = await open.value
            XCTAssertTrue(opened.ok)
            XCTAssertFalse(engine.taskTabs.hasPendingBrowserOpen)

            let cleanup = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(cleanup["command"] as? String, "close_owned_tabs")
            XCTAssertNil(cleanup["closeTabIds"])
            XCTAssertEqual(cleanup["keepTabIds"] as? [Int], [73])
            let cleanupId = try XCTUnwrap(cleanup["id"] as? String)
            try await sendBridgeJSON(["type": "response", "id": cleanupId, "ok": true], on: socket)
        }
    }

    func testLegacyCleanupDoesNotCloseTabsWhenBrowserOpenStaysPending() async throws {
        try await withBridgeEngine { engine, port, key in
            engine.ownedTabCleanupDelayNs = 0
            let socket = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Work")
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let openingTask = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
            _ = engine.startTaskInline(TaskStartParams(), explicitTaskId: nil)
            let open = Task {
                await engine.handle(RPCRequest(
                    method: .browserOpen,
                    browserOpen: BrowserOpenParams(url: "https://example.com/", profile: "Work", taskId: openingTask)
                ))
            }
            let wireOpen = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(wireOpen["command"] as? String, "open")
            let requestId = try XCTUnwrap(wireOpen["id"] as? String)
            XCTAssertTrue(engine.taskTabs.hasPendingBrowserOpen)

            let done = await engine.handle(RPCRequest(method: .taskComplete))
            XCTAssertNil(done.taskId)
            let control = try await receiveBridgeJSON(from: socket)
            XCTAssertEqual(control["state"] as? String, "ended")
            let unexpectedClose = expectation(description: "No unrestricted close while a browser open is still pending")
            unexpectedClose.isInverted = true
            let listener = Task {
                while let item = try? await receiveBridgeJSON(from: socket) {
                    if item["command"] as? String == "close_owned_tabs" {
                        unexpectedClose.fulfill()
                        return
                    }
                }
            }
            defer { listener.cancel() }
            await fulfillment(of: [unexpectedClose], timeout: 1.9)
            XCTAssertTrue(engine.taskTabs.hasPendingBrowserOpen)

            try await sendBridgeJSON([
                "type": "response", "id": requestId, "ok": true, "tabId": 73,
                "profileName": "Work", "url": "https://example.com/"
            ], on: socket)
            let opened = await open.value
            XCTAssertTrue(opened.ok)
        }
    }

    func testLeaseWindowsAppliesBatchWindowOnlyToPrimaryApp() {
        let primary = AppDescriptor(pid: 9001, name: "Primary", windowId: 40)
        let secondary = AppDescriptor(pid: 9002, name: "Secondary", windowId: 90)
        let engine = UseMacEngineService(observeTargetResolver: { query in
            if query == primary.name { return .app(primary) }
            if query == secondary.name { return .app(secondary) }
            return .notFound
        })
        var batch = BatchActionRequest(app: primary.name, steps: [
            ActionStep(action: .click),
            ActionStep(action: .click, app: secondary.name)
        ])
        batch.window = "Shared window title"

        var pinLookups: [Int32] = []
        let leases = engine.leaseWindows(for: RPCRequest(method: .act, act: batch)) { pid, title in
            XCTAssertEqual(title, "Shared window title")
            pinLookups.append(pid)
            return nil
        }

        XCTAssertEqual(pinLookups, [primary.pid])
        XCTAssertEqual(leases.map(\.pid), [primary.pid, secondary.pid])
        XCTAssertEqual(leases.map(\.windowId), [40, 90])
    }
}
