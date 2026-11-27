import Foundation
import os
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

final class DownloadsPipelineTests: XCTestCase {
    private var savedRules: TargetRules!

    override func setUp() {
        super.setUp()
        savedRules = TargetRulesStore.shared.rules
        useRules(TargetRules())
    }

    override func tearDown() {
        useRules(savedRules)
        super.tearDown()
    }

    func testBlobRulesMatchWebOriginInDenyAndAllowModes() {
        let deny = TargetRules(deniedSites: ["blocked.example:443"])
        let allow = TargetRules(mode: .allow, allowedSites: ["allowed.example"])
        XCTAssertTrue(deny.blocksURL("BLOB:https://blocked.example/uuid"))
        XCTAssertTrue(deny.blocksURL("blob:wss://blocked.example/uuid"))
        XCTAssertTrue(allow.blocksURL("blob:https://blocked.example/uuid"))
        XCTAssertFalse(allow.blocksURL("blob:https://allowed.example/uuid"))
        XCTAssertNil(TargetRules.host(ofURL: "blob:null/uuid"))
        XCTAssertFalse(deny.blocksURL("blob:null/uuid"))
        XCTAssertTrue(allow.blocksURL("blob:null/uuid"))
    }

    func testDownloadURLSanitizerKeepsWebPathAndOnlyBlobOrigin() {
        XCTAssertEqual(
            TargetRules.sanitizeDownloadURL(" HTTPS://name:secret@host.example/path?X-Amz-Signature=123&token=456#secret "),
            "https://host.example/path"
        )
        XCTAssertEqual(TargetRules.sanitizeDownloadURL("http://host.example:8080/a%2Fb?token=456"), "http://host.example:8080/a%2Fb")
        XCTAssertEqual(TargetRules.sanitizeDownloadURL("https://host.example"), "https://host.example/")
        XCTAssertEqual(TargetRules.sanitizeDownloadURL("blob:https://host.example/uuid"), "blob:https://host.example")
        XCTAssertEqual(
            TargetRules.sanitizeDownloadURL("BLOB:HTTPS://user:pw@[::1]:8080/uuid?token=456#secret"),
            "blob:https://[::1]:8080"
        )
        for invalid in [nil, " ", "data:text/plain,secret", "blob:null/uuid", "blob:wss://host.example/uuid",
                        "http:///path", "file:///tmp/file", "javascript:alert(1)"] {
            XCTAssertNil(TargetRules.sanitizeDownloadURL(invalid), invalid ?? "nil")
        }
    }

    func testDownloadDecodingPreservesZeroAndErrorButDropsNegativeBytes() throws {
        let raw = Data(#"""
        {"id":1,"filename":"file.zip","url":"https://host.example/path","state":"interrupted",
         "bytesReceived":0,"totalBytes":-1,"mime":"application/zip","startTime":"2026-11-27T01:02:18.023Z",
         "error":"NETWORK_FAILED"}
        """#.utf8)
        let result = try JSONDecoder().decode(BrowserDownloadInfo.self, from: raw)
        XCTAssertEqual(result.bytesReceived, 0)
        XCTAssertNil(result.totalBytes)
        XCTAssertEqual(result.error, "NETWORK_FAILED")
        XCTAssertEqual(result.url, "https://host.example/path")
        XCTAssertEqual(result.mime, "application/zip")
        XCTAssertEqual(result.startTime, "2026-11-27T01:02:18.023Z")

        let legacy = Data(#"{"id":2,"filename":"","state":"in_progress","bytesReceived":-1}"#.utf8)
        let legacyResult = try JSONDecoder().decode(BrowserDownloadInfo.self, from: legacy)
        XCTAssertNil(legacyResult.bytesReceived)
        XCTAssertNil(legacyResult.error)
    }

    func testDownloadsSkipsTabLookupAndFiltersEveryURLBeforeSanitizing() async throws {
        useRules(TargetRules(deniedSites: ["blocked.example"]))
        let items = [
            download(1, [
                "url": "https://user:pw@safe.example/a.zip?X-Amz-Signature=signed#fragment",
                "originalUrl": "https://safe.example/original?private=1", "referrer": "https://safe.example/referrer",
                "bytesReceived": 0, "totalBytes": -1, "error": "NETWORK_FAILED"
            ]),
            download(2, ["url": "https://blocked.example/file"]),
            download(3, ["url": "https://safe.example/file", "originalUrl": "https://blocked.example/before-redirect"]),
            download(4, ["url": "https://safe.example/file", "referrer": "https://blocked.example/source"]),
            download(5, ["url": "blob:https://blocked.example/uuid"]),
            download(6, ["originalUrl": "blob:https://safe.example/other-uuid?token=secret", "bytesReceived": -1]),
            download(7, ["url": "data:text/plain,private"])
        ]
        try await withExtension(reply: { request in
            XCTAssertEqual(request["command"] as? String, "extract", "downloads must not preflight with tabs")
            XCTAssertEqual(request["mode"] as? String, "downloads")
            XCTAssertNil(request["tabId"], "a legacy input tab must not be sent")
            return [
                "tabId": 44, "url": "https://blocked.example/legacy-tab", "title": "Private tab",
                "tabs": [["tabId": 44, "title": "Private tab", "url": "https://blocked.example/legacy-tab", "active": true]],
                "extractResult": [
                    "mode": "downloads", "latencyMs": 1, "tabId": 45, "url": "https://blocked.example/legacy-extract",
                    "title": "Private extract", "downloads": items
                ]
            ]
        }) { service in
            let response = await service.chromeBridge.extract(BrowserExtractParams(profile: "Work", tabId: 44, mode: " DOWNLOADS\n"))
            XCTAssertTrue(response.ok, String(describing: response.error))
            XCTAssertEqual(response.profileName, "Work")
            XCTAssertNil(response.tabId)
            XCTAssertNil(response.url)
            XCTAssertNil(response.title)
            XCTAssertNil(response.tabs)
            let result = try XCTUnwrap(response.extractResult)
            XCTAssertNil(result.tabId)
            XCTAssertNil(result.url)
            XCTAssertNil(result.title)
            let downloads = try XCTUnwrap(result.downloads)
            XCTAssertEqual(downloads.map(\.id), [1, 6, 7])
            XCTAssertEqual(downloads.map(\.url), ["https://safe.example/a.zip", "blob:https://safe.example", nil])
            XCTAssertEqual(downloads.first?.bytesReceived, 0)
            XCTAssertNil(downloads.first?.totalBytes)
            XCTAssertEqual(downloads.first?.error, "NETWORK_FAILED")
            XCTAssertNil(downloads.first(where: { $0.id == 6 })?.bytesReceived)

            let publicJSON = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            for privateValue in ["originalUrl", "referrer", "X-Amz-Signature", "fragment", "other-uuid", "data:text"] {
                XCTAssertFalse(publicJSON.contains(privateValue), privateValue)
            }
        }
    }

    func testDownloadsStillRefusesWhenChromeIsDenied() async {
        useRules(TargetRules(deniedApps: [TargetRules.chromeBundleId]))
        let bridge = ChromeExtensionBridge(port: 0)
        let response = await bridge.extract(BrowserExtractParams(tabId: 44, mode: "downloads"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "TARGET_BLOCKED")
        XCTAssertNil(response.tabId)
    }

    func testDownloadAllowListRequiresVerifiableWebURLAndRejectsBlockedRedirectSource() async throws {
        useRules(TargetRules(mode: .allow, allowedSites: ["safe.example"]))
        let items = [
            download(1, ["url": "https://safe.example/file"]),
            download(2, ["url": "blob:https://safe.example/uuid"]),
            download(3, [:]),
            download(4, ["url": "blob:null/uuid"]),
            download(5, ["url": "about:blank"]),
            download(6, ["url": "https://safe.example/file", "originalUrl": "https://other.example/original"]),
            download(7, ["url": "wss://safe.example/socket"]),
            download(8, ["referrer": "https://safe.example/source"])
        ]
        try await withExtension(reply: { _ in
            ["extractResult": ["mode": "downloads", "latencyMs": 1, "downloads": items]]
        }) { service in
            let response = await service.chromeBridge.extract(BrowserExtractParams(mode: "downloads"))
            XCTAssertTrue(response.ok, String(describing: response.error))
            let downloads = try XCTUnwrap(response.extractResult?.downloads)
            XCTAssertEqual(downloads.map(\.id), [1, 2, 8])
            XCTAssertNil(downloads.first(where: { $0.id == 8 })?.url, "referrer is not a public fallback URL")
        }
    }

    func testNetworkFilteringUpdatesRowCountIncludingEmptyAndUnchangedArrays() async throws {
        useRules(TargetRules(deniedSites: ["blocked.example"]))
        try await withExtension(reply: { request in
            if request["command"] as? String == "tabs" { return ["tabs": []] }
            let json: String
            switch request["urlFilter"] as? String {
            case "mixed":
                json = #"[{"url":"https://safe.example/api"},{"url":"https://blocked.example/api"}]"#
            case "blocked":
                json = #"[{"url":"https://blocked.example/api"}]"#
            default:
                json = #"[{"url":"https://safe.example/other"}]"#
            }
            return ["extractResult": ["mode": "network", "latencyMs": 1, "jsonResult": json, "rowCount": 99]]
        }) { service in
            for (filter, count) in [("mixed", 1), ("blocked", 0), ("unchanged", 1)] {
                let response = await service.chromeBridge.extract(BrowserExtractParams(mode: "network", urlFilter: filter))
                XCTAssertTrue(response.ok, String(describing: response.error))
                let result = try XCTUnwrap(response.extractResult)
                let json = try XCTUnwrap(result.jsonResult)
                XCTAssertEqual(result.rowCount, count, filter)
                XCTAssertFalse(json.contains("blocked.example"), filter)
                if count == 0 { XCTAssertEqual(json, "[]") }
            }
        }
    }

    func testActionResultDropsURLDownloadPathsAndKeepsLocalPaths() async throws {
        let paths = [" http://host.example/a ", "\nHTTPS://host.example/b", "blob:https://host.example/uuid",
                     "DATA:text/plain,private", " javascript:alert(1)", "/tmp/file.zip"]
        try await withExtension(reply: { request in
            XCTAssertEqual(request["command"] as? String, "act")
            let steps = paths.enumerated().map { index, path in
                ["index": index, "action": "click", "success": true, "mechanism": "chrome", "latencyMs": 1,
                 "downloadPath": path] as [String: Any]
            }
            return ["actionResult": ["success": true, "totalLatencyMs": 6, "stepResults": steps]]
        }) { service in
            let steps = paths.map { _ in ActionStep(action: .click, x: 10, y: 20) }
            let response = await service.chromeBridge.act(BrowserActParams(tabId: 42, steps: steps))
            XCTAssertTrue(response.ok, String(describing: response.error))
            XCTAssertEqual(response.actionResult?.stepResults.map(\.downloadPath), [nil, nil, nil, nil, nil, "/tmp/file.zip"])
        }
    }

    func testMalformedDownloadResponseFailsImmediatelyWithDocumentedError() async throws {
        try await withExtension(reply: { _ in
            ["extractResult": ["mode": "downloads", "latencyMs": 1, "downloads": [
                self.download(1, ["totalBytes": "not a number"])
            ]]]
        }) { service in
            let start = ContinuousClock.now
            let response = await service.chromeBridge.extract(BrowserExtractParams(mode: "downloads"))
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, "INVALID_REQUEST")
            XCTAssertEqual(response.error?.message, "Invalid extension response payload.")
            XCTAssertLessThan(start.duration(to: .now), .seconds(3), "must not wait for the extract timeout")
        }
    }

    func testDownloadsInheritsLastKnownProfileWithoutChangingRecentTabs() {
        let registry = TaskTabRegistry()
        let taskId = registry.start()
        registry.recordOpenedTab(11, taskId: taskId, profile: "Work")
        registry.recordOpenedTab(12, taskId: taskId)

        let profileOnly = RPCRequest(
            method: .browserExtract, browserExtract: BrowserExtractParams(profile: "  ", mode: " DOWNLOADS "), taskId: taskId
        )
        let scope = registry.scope(profileOnly)
        XCTAssertEqual(scope.request.browserExtract?.profile, "Work")
        XCTAssertNil(scope.request.browserExtract?.tabId)
        XCTAssertNil(scope.filledTabId)

        let legacy = RPCRequest(
            method: .browserExtract, browserExtract: BrowserExtractParams(profile: "Personal", tabId: 99, mode: "downloads"),
            taskId: taskId
        )
        XCTAssertNil(legacy.namedTabId)
        XCTAssertFalse(legacy.fallsBackToLastTab)
        let legacyScope = registry.scope(legacy)
        XCTAssertEqual(legacyScope.request.browserExtract?.profile, "Personal")
        registry.record(legacyScope, response: .success(id: legacy.id, latencyMs: 1))
        XCTAssertEqual(registry.lastTab(of: taskId), 12)
    }

    func testEngineRejectsBatchDownloadsBeforeOpeningAnyTab() async throws {
        try await withExtension(reply: { request in
            XCTFail("Rejected batch sent a Chrome command: \(request)")
            return ["ok": false]
        }) { service in
            for mode in ["extract", "observe"] {
                let response = await service.handle(RPCRequest(method: .browserBatch, browserBatch: BrowserBatchParams(
                    urls: ["https://safe.example/"], mode: mode, extractMode: " DOWNLOADS "
                )))
                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.error?.code, "INVALID_ARGUMENT")
                XCTAssertTrue(response.error?.message.contains("browser_extract") == true)
            }
        }
    }

    func testEngineAuditAndHUDReportVisibleDownloadsAndNetworkResponses() async throws {
        useRules(TargetRules(deniedSites: ["blocked.example"]))
        let items = [
            download(1, ["url": "https://safe.example/file"]),
            download(2, ["url": "https://blocked.example/download"])
        ]
        let activity = OSAllocatedUnfairLock(initialState: [LiveActivityItem]())
        try await withExtension(reply: { request in
            if request["command"] as? String == "tabs" { return ["tabs": []] }
            if request["mode"] as? String == "downloads" {
                return ["tabId": 42, "extractResult": ["mode": "downloads", "latencyMs": 1, "downloads": items]]
            }
            return [
                "tabId": 42, "url": "https://safe.example/",
                "extractResult": [
                    "mode": "network", "latencyMs": 1, "rowCount": 3,
                    "jsonResult": #"[{"url":"https://safe.example/one"},{"url":"https://safe.example/two"},{"url":"https://blocked.example/api"}]"#
                ]
            ]
        }) { service in
            service.onLiveActivity = { item in activity.withLock { $0.append(item) } }
            let downloads = await service.handle(RPCRequest(
                method: .browserExtract, browserExtract: BrowserExtractParams(tabId: 42, mode: "downloads")
            ))
            XCTAssertTrue(downloads.ok, String(describing: downloads.error))
            XCTAssertNil(downloads.browserTabId)
            XCTAssertEqual(downloads.browserExtract?.downloads?.count, 1)
            let network = await service.handle(RPCRequest(
                method: .browserExtract, browserExtract: BrowserExtractParams(tabId: 42, mode: "network")
            ))
            XCTAssertTrue(network.ok, String(describing: network.error))
            XCTAssertEqual(network.browserTabId, 42)
            XCTAssertEqual(network.browserExtract?.rowCount, 2)

            let audit = await service.handle(RPCRequest(method: .auditLog))
            let summaries = audit.auditEntries?.filter { $0.method == "browser_extract" }.map(\.summary)
            XCTAssertEqual(summaries, ["Extracted network (2 responses)", "Extracted downloads (1 download)"])
            let cards = activity.withLock { $0.filter { $0.title.hasPrefix("Extracted ") } }
            XCTAssertEqual(cards.map(\.subtitle), ["1 download", "2 responses"])
            XCTAssertEqual(cards.map(\.browserTabId), [nil, 42])
        }
    }

    func testMCPRejectsAnyURLsArgumentForDownloadsWithoutDispatching() async throws {
        let mcp = makeMCP { request in
            XCTFail("Incompatible downloads request was dispatched: \(request.method)")
            return .success(id: request.id, latencyMs: 1)
        }
        defer { mcp.close() }
        for urls in ["[]", #"["https://safe.example/"]"#, "null"] {
            let result = try await callMCP(mcp, arguments: #"{"mode":" DOWNLOADS ","urls":"# + urls + "}")
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("INVALID_ARGUMENT"))
            XCTAssertTrue(result.text.contains("Omit urls"))
        }
    }

    func testMCPFormatsProgressAndErrorWithoutTabOrURLs() async throws {
        let mcp = makeMCP { request in
            XCTAssertEqual(request.method, .browserExtract)
            XCTAssertEqual(request.browserExtract?.profile, "Work")
            let downloads = [
                BrowserDownloadInfo(id: 1, filename: "a.zip", url: "https://safe.example/a?token=private",
                                    state: "interrupted", bytesReceived: 0, totalBytes: 100, error: "NETWORK_FAILED"),
                BrowserDownloadInfo(id: 2, filename: "b.zip", state: "complete", bytesReceived: -1, totalBytes: 20),
                BrowserDownloadInfo(id: 3, filename: "c.zip", state: "in_progress", totalBytes: -1, error: " ")
            ]
            let extract = BrowserExtractResult(mode: "downloads", tabId: 77, url: "https://safe.example/tab", downloads: downloads)
            return .success(id: request.id, latencyMs: 1, browserExtract: extract, browserTabId: 88, browserUrl: "https://safe.example/fallback")
        }
        defer { mcp.close() }
        let result = try await callMCP(mcp, arguments: #"{"mode":"downloads","profile":"Work"}"#)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("[interrupted] a.zip (0/100 bytes) — error: NETWORK_FAILED"))
        XCTAssertTrue(result.text.contains("[complete] b.zip (20 bytes)"))
        XCTAssertTrue(result.text.contains("[in_progress] c.zip"))
        XCTAssertFalse(result.text.contains("-1"))
        XCTAssertFalse(result.text.contains("tabId="))
        XCTAssertFalse(result.text.contains("https://"))
    }

    private func useRules(_ rules: TargetRules) {
        TargetRulesStore.shared.update(rules, persist: false)
    }

    private func download(_ id: Int, _ fields: [String: Any]) -> [String: Any] {
        fields.merging(["id": id, "filename": "file-\(id).zip", "state": "interrupted"]) { value, _ in value }
    }

    private func withExtension(
        reply: @escaping ([String: Any]) -> [String: Any],
        run: (UseMacEngineService) async throws -> Void
    ) async throws {
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-downloads-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0, bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }
        let port = await waitForListeningPort(of: service.chromeBridge)
        XCTAssertNotEqual(port, 0)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let socket = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "Work", tabCount: 0)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "Work" }
        XCTAssertTrue(ready)

        let responder = Task {
            while !Task.isCancelled {
                guard let request = try? await receiveBridgeJSON(from: socket) else { break }
                guard request["type"] as? String == "request", let id = request["id"] as? String else { continue }
                let payload = reply(request).merging([
                    "type": "response", "id": id, "ok": true, "profileName": "Work"
                ]) { value, _ in value }
                try await sendBridgeJSON(payload, on: socket)
            }
        }
        defer { responder.cancel() }
        try await run(service)
    }

    private func makeMCP(_ handle: @escaping @Sendable (RPCRequest) -> RPCResponse) -> MCPStdioServer {
        MCPStdioServer(
            socketPath: "/tmp/usemac-downloads-mcp-\(UUID().uuidString.prefix(8)).sock",
            fallbackService: StubService(handler: handle)
        )
    }

    private func callMCP(_ mcp: MCPStdioServer, arguments: String) async throws -> (text: String, isError: Bool) {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"usemac_browser_extract","arguments":"# + arguments + "}}"
        let output = await mcp.processLine(line)
        let raw = try XCTUnwrap(output)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String), try XCTUnwrap(result["isError"] as? Bool))
    }
}
