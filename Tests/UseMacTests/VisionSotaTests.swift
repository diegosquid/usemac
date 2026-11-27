import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacIPC
@testable import UseMacProtocol

/// Tests for Wave 2B SOTA vision/engine/bridge deliverables:
/// - `16x10` tile dirty-region diff (`computeDirtyRegion`) & `cropJPEG`
/// - Negation-safe OCR/DOM assertion verification (EN + PT)
/// - Dirty-rect cropped OCR (`recognizeText(inJPEG:region:)`) & `@vN` OCR fusion
/// - Zero-ceremony piggybacked `taskStart`/`taskComplete`
/// - `TargetRules` `tab_url` push cache fast path + Wave 1B wire forwarding
/// - Fixed L1084 reflex + tiered fast `verify` + `diffCrop`
/// - `browser_batch` URL policy filtering & parallel execution
/// - `skill_save` / `skill_list` / `skill_run` & `app_menu` governance
final class VisionSotaTests: XCTestCase {
    private var savedRules: TargetRules!

    override func setUp() {
        super.setUp()
        savedRules = TargetRulesStore.shared.rules
    }

    override func tearDown() {
        TargetRulesStore.shared.update(savedRules, persist: false)
        super.tearDown()
    }

    // MARK: - Synthetic Image Helpers

    /// Renders a solid white RGB image (`width x height`) with optional top-left-origin rectangles and text labels.
    private func renderTestJPEG(
        width: Int,
        height: Int,
        rects: [(x: Int, y: Int, w: Int, h: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [],
        texts: [(string: String, x: CGFloat, y: CGFloat, fontSize: CGFloat)] = []
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "VisionSotaTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        // Fill white background
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw colored rectangles (input y is top-left origin -> convert to Quartz bottom-left origin)
        for rect in rects {
            ctx.setFillColor(red: rect.r, green: rect.g, blue: rect.b, alpha: 1)
            let quartzY = height - rect.y - rect.h
            ctx.fill(CGRect(x: rect.x, y: quartzY, width: rect.w, height: rect.h))
        }

        // Draw crisp black text using pure CoreText directly on the CGContext (thread-safe & headless-CI safe, zero AppKit).
        if !texts.isEmpty {
            let black = CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1])!
            ctx.textMatrix = .identity
            for item in texts {
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, item.fontSize, nil)
                let attrs: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: black
                ]
                let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, item.string as CFString, attrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(attrStr)
                let ascent = CTFontGetAscent(font)
                // Convert top-left origin y to Quartz bottom-left baseline y
                let baselineY = CGFloat(height) - item.y - ascent
                ctx.textPosition = CGPoint(x: item.x, y: baselineY)
                CTLineDraw(line, ctx)
            }
        }

        guard let cgImage = ctx.makeImage(),
              let jpeg = LocalVisionEngine.encodeJPEG(cgImage, quality: 0.92) else {
            throw NSError(domain: "VisionSotaTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG"])
        }
        return jpeg
    }

    // MARK: - 1. Dirty Region (16x10 Tile Grid) & cropJPEG

    func testComputeDirtyRegionIdenticalAndLocalizedTiles() throws {
        let base = try renderTestJPEG(width: 800, height: 500)

        let same = LocalVisionEngine.computeDirtyRegion(beforeJPEG: base, afterJPEG: base)
        XCTAssertEqual(same.overallDiffPercent, 0.0)
        XCTAssertEqual(same.maxTileDiffPercent, 0.0)
        XCTAssertNil(same.dirtyRect)
        XCTAssertEqual(same.changedTileCount, 0)

        // Small 36x36 dark blue checkbox toggle in top-left quadrant:
        // overall diff is tiny (<0.4%) but max tile diff is large (>> 0.8%)!
        let topLeftToggle = try renderTestJPEG(
            width: 800,
            height: 500,
            rects: [(x: 50, y: 40, w: 36, h: 36, r: 0.05, g: 0.2, b: 0.8)]
        )
        let dirtyTL = LocalVisionEngine.computeDirtyRegion(beforeJPEG: base, afterJPEG: topLeftToggle)
        XCTAssertLessThan(dirtyTL.overallDiffPercent, 0.5, "small toggle has tiny global diff")
        XCTAssertGreaterThan(dirtyTL.maxTileDiffPercent, 5.0, "16x10 tile grid catches localized toggle")
        let tlRect = try XCTUnwrap(dirtyTL.dirtyRect)
        XCTAssertLessThan(tlRect.x, 120, "top-left dirtyRect x should be near left edge")
        XCTAssertLessThan(tlRect.y, 120, "top-left dirtyRect y should be near top edge (top-left origin)")
        XCTAssertEqual(dirtyTL.imageWidth, 800)
        XCTAssertEqual(dirtyTL.imageHeight, 500)

        // Localized banner in bottom-right quadrant
        let bottomRightBanner = try renderTestJPEG(
            width: 800,
            height: 500,
            rects: [(x: 680, y: 410, w: 90, h: 60, r: 0.85, g: 0.1, b: 0.1)]
        )
        let dirtyBR = LocalVisionEngine.computeDirtyRegion(beforeJPEG: base, afterJPEG: bottomRightBanner)
        let brRect = try XCTUnwrap(dirtyBR.dirtyRect)
        XCTAssertGreaterThanOrEqual(brRect.x, 600, "bottom-right dirtyRect x should be near right edge")
        XCTAssertGreaterThanOrEqual(brRect.y, 350, "bottom-right dirtyRect y should be near bottom edge")
    }

    func testCropJPEGRespectsPaddingBoundsAndMaxDimension() throws {
        let img = try renderTestJPEG(
            width: 1600,
            height: 1000,
            rects: [(x: 200, y: 150, w: 120, h: 80, r: 0.1, g: 0.5, b: 0.2)]
        )
        let cropData = try XCTUnwrap(LocalVisionEngine.cropJPEG(
            fromJPEG: img,
            rect: ScreenRect(x: 200, y: 150, width: 120, height: 80),
            padding: 24,
            maxDimension: 1024,
            quality: 0.80
        ))
        let croppedCG = try XCTUnwrap(LocalVisionEngine.decodeCGImage(fromJPEG: cropData))
        XCTAssertEqual(croppedCG.width, 168) // 120 + 2*24
        XCTAssertEqual(croppedCG.height, 128) // 80 + 2*24

        // Test maxDimension downscaling on a large crop
        let scaledData = try XCTUnwrap(LocalVisionEngine.cropJPEG(
            fromJPEG: img,
            rect: ScreenRect(x: 0, y: 0, width: 1600, height: 1000),
            padding: 0,
            maxDimension: 400,
            quality: 0.80
        ))
        let scaledCG = try XCTUnwrap(LocalVisionEngine.decodeCGImage(fromJPEG: scaledData))
        XCTAssertEqual(scaledCG.width, 400)
        XCTAssertEqual(scaledCG.height, 250)

        // Extreme and non-finite coordinates clamp safely without trapping on Int conversion.
        XCTAssertNil(LocalVisionEngine.cropJPEG(
            fromJPEG: img,
            rect: ScreenRect(x: .nan, y: 0, width: 100, height: 100)
        ))
        XCTAssertNil(LocalVisionEngine.cropJPEG(
            fromJPEG: img,
            rect: ScreenRect(x: 0, y: .infinity, width: 100, height: 100)
        ))
        let clampedHuge = try XCTUnwrap(LocalVisionEngine.cropJPEG(
            fromJPEG: img,
            rect: ScreenRect(x: -1e12, y: -1e12, width: 1e13, height: 1e13),
            padding: 24,
            maxDimension: 200
        ))
        let clampedCG = try XCTUnwrap(LocalVisionEngine.decodeCGImage(fromJPEG: clampedHuge))
        XCTAssertEqual(clampedCG.width, 200)
        XCTAssertEqual(clampedCG.height, 125)
    }

    // MARK: - 2. Negation-Safe Verification (EN + PT)

    func testVerifyAssertionNegationSafeEnglishAndPortuguese() {
        // English negation with 2-char "no" preserved!
        let noErrClean = LocalVisionEngine.verifyAssertion("No error banner visible", againstOCRText: "Dashboard loaded successfully")
        XCTAssertTrue(noErrClean.verified, noErrClean.evidence)

        let noErrPresent = LocalVisionEngine.verifyAssertion("No error banner visible", againstOCRText: "Error: invalid password")
        XCTAssertFalse(noErrPresent.verified, noErrPresent.evidence)

        // Contractions and other EN negation cues
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Error isn't visible", againstOCRText: "All changes saved").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Error isn't visible", againstOCRText: "Error saving form").verified)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Modal dismissed", againstOCRText: "Main workspace").verified)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Warning absent", againstOCRText: "Status: Healthy").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Without failure message", againstOCRText: "Payment failure detected").verified)

        // Multi-token negation avoids false failures on benign overlap ("email" present, "invalid" absent)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("No invalid email", againstOCRText: "Email saved successfully").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("No invalid email", againstOCRText: "Invalid email address").verified)

        // Portuguese negation cues (with & without accents)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Sem erro visível", againstOCRText: "Salvo com sucesso").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Sem erro visível", againstOCRText: "Erro ao salvar documento").verified)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Não há mensagem de erro", againstOCRText: "Operação concluída").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Não há mensagem de erro", againstOCRText: "Erro interno 500").verified)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Nenhuma falha encontrada", againstOCRText: "Relatório pronto").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Nao aparece aviso de falha", againstOCRText: "Falha na autenticação").verified)

        // Positive assertions (EN + PT)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Saved successfully", againstOCRText: "Document saved successfully").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Saved successfully", againstOCRText: "Draft editing").verified)
        XCTAssertTrue(LocalVisionEngine.verifyAssertion("Pedido confirmado", againstOCRText: "Seu pedido confirmado #1234").verified)
        XCTAssertFalse(LocalVisionEngine.verifyAssertion("Pedido confirmado", againstOCRText: "Carrinho vazio").verified)
    }

    // MARK: - 3. Cropped OCR & @vN OCR Element Fusion

    func testDirtyRectCroppedOCRAndOCRElementFusion() async throws {
        let jpeg = try renderTestJPEG(
            width: 800,
            height: 400,
            texts: [
                ("ALPHA SUBMIT", x: 40, y: 40, fontSize: 34),
                ("OMEGA CANCEL", x: 480, y: 300, fontSize: 34)
            ]
        )

        // Pure deterministic @vN fusion (no Vision runtime required)
        let windowBounds = ScreenRect(x: 100, y: 200, width: 800, height: 400)
        let syntheticNodes = LocalVisionEngine.ocrElementNodes(
            fromDetections: [
                VisionDetection(label: "OMEGA CANCEL", x: 580, y: 315, frame: ScreenRect(x: 480, y: 300, width: 200, height: 30), confidence: 0.99, source: "test"),
                VisionDetection(label: "ALPHA SUBMIT", x: 140, y: 55, frame: ScreenRect(x: 40, y: 40, width: 200, height: 30), confidence: 0.99, source: "test")
            ],
            windowBounds: windowBounds
        )
        XCTAssertEqual(syntheticNodes.count, 2)
        guard syntheticNodes.count == 2 else { return }
        XCTAssertEqual(syntheticNodes[0].id, "@v1")
        XCTAssertEqual(syntheticNodes[0].title, "ALPHA SUBMIT")
        XCTAssertEqual(syntheticNodes[0].frame.x, 140)
        XCTAssertEqual(syntheticNodes[0].frame.y, 240)
        XCTAssertEqual(syntheticNodes[1].id, "@v2")
        XCTAssertEqual(syntheticNodes[1].title, "OMEGA CANCEL")
        XCTAssertEqual(syntheticNodes[1].frame.x, 580)
        XCTAssertEqual(syntheticNodes[1].frame.y, 500)

        // Cropped OCR on top-left region reads ALPHA SUBMIT without OMEGA CANCEL (fast/CPU-safe in CI VMs)
        let topLeftOCR = LocalVisionEngine.recognizeText(
            inJPEG: jpeg,
            region: ScreenRect(x: 20, y: 20, width: 360, height: 110),
            fast: true
        )
        XCTAssertTrue(topLeftOCR.text.uppercased().contains("ALPHA"), "Expected ALPHA in cropped OCR, got: \(topLeftOCR.text)")
        XCTAssertFalse(topLeftOCR.text.uppercased().contains("OMEGA"), "Did not expect OMEGA in top-left crop, got: \(topLeftOCR.text)")

        // @vN OCR fusion from real image produces clickable ElementNodes offset into global windowBounds
        let nodes = LocalVisionEngine.ocrElementNodes(fromJPEG: jpeg, windowBounds: windowBounds)
        XCTAssertGreaterThanOrEqual(nodes.count, 2, "Expected OCR nodes for both labels, got: \(nodes)")
        guard nodes.count >= 2 else { return }
        XCTAssertEqual(nodes[0].id, "@v1")
        XCTAssertEqual(nodes[1].id, "@v2")
        XCTAssertEqual(nodes[0].role, "AXStaticText")
        XCTAssertTrue(nodes.contains { ($0.title ?? "").uppercased().contains("ALPHA") && $0.frame.x >= 100 && $0.frame.y >= 200 })
        XCTAssertTrue(nodes.contains { ($0.title ?? "").uppercased().contains("OMEGA") && $0.frame.x >= 500 && $0.frame.y >= 450 })

        // End-to-end LocalVisionEngine.query(mode: "verify") uses negation-safe verification
        let tmpPath = NSTemporaryDirectory() + "usemac-vision-sota-\(UUID().uuidString).jpg"
        try jpeg.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let engine = LocalVisionEngine()
        let negPass = await engine.query(mode: "verify", query: "No error banner visible", imagePath: tmpPath, viewportWidth: 800, viewportHeight: 400)
        XCTAssertEqual(negPass.verified, true, negPass.answer)
        let negFail = await engine.query(mode: "verify", query: "No ALPHA button visible", imagePath: tmpPath, viewportWidth: 800, viewportHeight: 400)
        XCTAssertEqual(negFail.verified, false, negFail.answer)

        // Corrupt/unreadable image must return indeterminate (verified == nil), NEVER falsely verifying absence!
        let corruptPath = NSTemporaryDirectory() + "usemac-vision-corrupt-\(UUID().uuidString).jpg"
        try Data("not-a-jpeg".utf8).write(to: URL(fileURLWithPath: corruptPath))
        defer { try? FileManager.default.removeItem(atPath: corruptPath) }
        let corruptVerify = await engine.query(mode: "verify", query: "No error banner visible", imagePath: corruptPath, viewportWidth: 800, viewportHeight: 400)
        XCTAssertNil(corruptVerify.verified, "Unreadable image must not verify a negated assertion as true: \(corruptVerify.answer)")
    }

    // MARK: - 4. Zero-Ceremony Piggybacked Task Lifecycle

    func testPiggybackedTaskStartAndTaskComplete() async {
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-piggy-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0
        )

        // One-shot request carrying BOTH taskStart and taskComplete
        let oneShot = await service.handle(RPCRequest(
            method: .ping,
            taskStart: TaskStartParams(summary: "One-shot check", agent: "Wave2B"),
            taskComplete: TaskCompleteParams(summary: "Finished one-shot")
        ))
        XCTAssertTrue(oneShot.ok)
        XCTAssertEqual(oneShot.pong, "pong")
        let oneShotId = oneShot.taskId
        XCTAssertNotNil(oneShotId)
        XCTAssertEqual(oneShot.taskSummary?.taskId, oneShotId)
        XCTAssertEqual(oneShot.taskSummary?.agent, "Wave2B")
        XCTAssertEqual(oneShot.taskSummary?.requests, 1)
        XCTAssertEqual(service.taskTabs.runningTaskCount, 0)

        // Multi-step piggybacked flow: taskStart on request 1, taskComplete on request 2
        let first = await service.handle(RPCRequest(
            method: .ping,
            taskStart: TaskStartParams(summary: "Two-step", agent: "AgentX")
        ))
        let taskId = first.taskId
        XCTAssertNotNil(taskId)
        XCTAssertNil(first.taskSummary)
        XCTAssertEqual(service.taskTabs.runningTaskCount, 1)

        let second = await service.handle(RPCRequest(
            method: .status,
            taskComplete: TaskCompleteParams(summary: "Done two-step"),
            taskId: taskId
        ))
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.taskId, taskId)
        XCTAssertEqual(second.taskSummary?.taskId, taskId)
        XCTAssertEqual(second.taskSummary?.requests, 2)
        XCTAssertEqual(service.taskTabs.runningTaskCount, 0)
    }

    // MARK: - 5. TargetRules tab_url Cache Fast Path, Wire Forwarding, L1084 Reflex Fix & Tiered Verify

    private final class RecordedCommands: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String: Any]] = []
        func append(_ item: [String: Any]) { lock.lock(); list.append(item); lock.unlock() }
        func reset() { lock.lock(); list.removeAll(); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return list }
        var names: [String] { all.compactMap { $0["command"] as? String } }
    }

    func testTabUrlPushCacheEliminatesTabsDumpAndForwardsNewFields() async throws {
        TargetRulesStore.shared.update(TargetRules(deniedSites: ["blocked.example"]), persist: false)
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-cache-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.baseCommandTimeoutSeconds = 3
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "FastCache", tabCount: 2)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "FastCache" }
        XCTAssertTrue(ready)

        let beforeJPEG = try renderTestJPEG(width: 640, height: 400)
        let afterToggleJPEG = try renderTestJPEG(
            width: 640,
            height: 400,
            rects: [(x: 40, y: 40, w: 32, h: 32, r: 0.1, g: 0.3, b: 0.9)]
        )

        let recorded = RecordedCommands()
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                recorded.append(obj)
                var resp: [String: Any] = ["type": "response", "id": id, "ok": true, "profileName": "FastCache"]
                switch command {
                case "observe":
                    resp["tabId"] = obj["tabId"] as? Int ?? 10
                    resp["url"] = "https://fine.example/app"
                    resp["title"] = "Fine App"
                    resp["snapshot"] = [
                        "app": ["pid": 0, "name": "Chrome (FastCache)", "isActive": false, "isHidden": false, "windowTitle": "Fine App"],
                        "timestampMs": 1000,
                        "latencyMs": 3.5,
                        "fromHotCache": false,
                        "elements": [
                            ["id": "@b1", "role": "AXButton", "title": "Save", "enabled": true, "focused": false, "frame": ["x": 10, "y": 10, "width": 80, "height": 30], "actions": ["AXPress"]]
                        ],
                        "offscreenCount": 14,
                        "pageState": [
                            "scrollX": 0, "scrollY": 0, "scrollHeight": 1200, "viewportWidth": 640, "viewportHeight": 400,
                            "canScrollDown": true, "canScrollUp": false, "scrollLocked": false,
                            "tablesSummary": "unchanged",
                            "webMcpTools": ["search_docs", "create_ticket"]
                        ]
                    ]
                case "extract":
                    resp["tabId"] = obj["tabId"] as? Int ?? 10
                    resp["url"] = "https://fine.example/app"
                    resp["extractResult"] = [
                        "mode": obj["mode"] as? String ?? "network",
                        "latencyMs": 1.2,
                        "jsonResult": "[{\"url\":\"/api/items\",\"status\":200}]"
                    ]
                case "act":
                    resp["tabId"] = obj["tabId"] as? Int ?? 10
                    resp["url"] = "https://fine.example/app"
                    resp["title"] = "Fine App"
                    resp["screenshotBase64"] = afterToggleJPEG.base64EncodedString()
                    resp["screenshotWidth"] = 640
                    resp["screenshotHeight"] = 400
                    resp["actionResult"] = [
                        "success": true,
                        "totalLatencyMs": 4.0,
                        "networkErrors": ["POST https://fine.example/api/save -> 500 Internal Server Error"],
                        "stepResults": [
                            ["index": 0, "action": "click", "success": true, "mechanism": "cdp-click", "latencyMs": 2.0]
                        ],
                        "observation": [
                            "app": ["pid": 0, "name": "Chrome (FastCache)", "isActive": false, "isHidden": false, "windowTitle": "Fine App"],
                            "timestampMs": 1001,
                            "latencyMs": 2.0,
                            "fromHotCache": false,
                            "elements": [
                                ["id": "@b1", "role": "AXCheckBox", "title": "Accept terms", "enabled": true, "focused": false, "frame": ["x": 40, "y": 40, "width": 32, "height": 32], "actions": ["AXPress"]],
                                ["id": "@b2", "role": "AXStaticText", "title": "Order saved", "enabled": true, "focused": false, "frame": ["x": 40, "y": 90, "width": 120, "height": 20], "actions": []],
                                ["id": "@b3", "role": "AXButton", "title": "Continue", "enabled": true, "focused": false, "frame": ["x": 40, "y": 130, "width": 100, "height": 30], "actions": ["AXPress"]],
                                ["id": "@b4", "role": "AXLink", "title": "Help", "enabled": true, "focused": false, "frame": ["x": 40, "y": 170, "width": 60, "height": 20], "actions": ["AXPress"]],
                                ["id": "@b5", "role": "AXStaticText", "title": "Status OK", "enabled": true, "focused": false, "frame": ["x": 40, "y": 210, "width": 80, "height": 20], "actions": []]
                            ],
                            "diff": ["added": [], "removedIds": [], "changed": [], "summary": "0 changed"],
                            "pageState": [
                                "scrollX": 0, "scrollY": 0, "scrollHeight": 400, "viewportWidth": 640, "viewportHeight": 400,
                                "canScrollDown": false, "canScrollUp": false, "scrollLocked": false,
                                "readableText": "Order saved successfully. Status OK."
                            ]
                        ]
                    ]
                case "open":
                    resp["tabId"] = 77
                    resp["url"] = obj["url"] as? String ?? ""
                    resp["title"] = "Opened"
                default:
                    resp["tabId"] = obj["tabId"] as? Int ?? 10
                }
                try? await sendBridgeJSON(resp, on: wsTask)
            }
        }
        defer { responder.cancel() }

        // Push live `tab_url` events from extension
        try await sendBridgeJSON(["type": "tab_url", "tabId": 10, "url": "https://fine.example/app", "title": "Fine App"], on: wsTask)
        try await sendBridgeJSON(["type": "tab_url", "tabId": 20, "url": "https://blocked.example/vault", "title": "Vault"], on: wsTask)
        let cachePopulated = await waitForBridgeCondition {
            service.chromeBridge.cachedTabURLs(profileQuery: "FastCache")[20] == "https://blocked.example/vault"
        }
        XCTAssertTrue(cachePopulated)

        // 1. Blocked tab is refused with ZERO WS commands (no `tabs` dump!)
        recorded.reset()
        let blockedObs = await service.chromeBridge.observe(BrowserObserveParams(profile: "FastCache", tabId: 20))
        XCTAssertEqual(blockedObs.error?.code, "TARGET_BLOCKED")
        XCTAssertEqual(recorded.names, [], "Expected zero WS round-trips when tab_url cache hits")

        // 2. Allowed tab runs `observe` with ZERO `tabs` dump, forwards `filter`, and decodes SOTA snapshot fields
        recorded.reset()
        let fineObs = await service.chromeBridge.observe(BrowserObserveParams(
            profile: "FastCache",
            tabId: 10,
            filter: ElementFilter(role: "button", text: "Save", viewportOnly: true)
        ))
        XCTAssertTrue(fineObs.ok, String(describing: fineObs.error))
        XCTAssertEqual(recorded.names, ["observe"], "No preflight `tabs` lookup when tab_url cache is live")
        let obsFilter = recorded.all.first?["filter"] as? [String: Any]
        XCTAssertEqual(obsFilter?["role"] as? String, "button")
        XCTAssertEqual(fineObs.snapshot?.offscreenCount, 14)
        XCTAssertEqual(fineObs.snapshot?.pageState?.tablesSummary, "unchanged")
        XCTAssertEqual(fineObs.snapshot?.pageState?.webMcpTools, ["search_docs", "create_ticket"])

        // 3. Extract forwards urlFilter, scanVertical, frameIndex
        recorded.reset()
        let extResp = await service.chromeBridge.extract(BrowserExtractParams(
            profile: "FastCache",
            tabId: 10,
            mode: "network",
            urlFilter: "/api/items",
            scanVertical: true,
            frameIndex: 0
        ))
        XCTAssertTrue(extResp.ok)
        XCTAssertEqual(recorded.names, ["extract"])
        XCTAssertEqual(recorded.all.first?["urlFilter"] as? String, "/api/items")
        XCTAssertEqual(recorded.all.first?["scanVertical"] as? Bool, true)
        XCTAssertEqual(recorded.all.first?["frameIndex"] as? Int, 0)

        // 4. Seed before frame via WS `frame` event, then run browser_act with diffCrop + verify + observationMode
        try await sendBridgeJSON([
            "type": "frame",
            "tabId": 10,
            "profileName": "FastCache",
            "url": "https://fine.example/app",
            "title": "Fine App",
            "viewportWidth": 640,
            "viewportHeight": 400,
            "jpegBase64": beforeJPEG.base64EncodedString()
        ], on: wsTask)
        let frameArrived = await waitForBridgeCondition {
            service.chromeBridge.latestFrame(profileQuery: "FastCache", tabId: 10) != nil
        }
        XCTAssertTrue(frameArrived)

        recorded.reset()
        let actResp = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(
                profile: "FastCache",
                tabId: 10,
                steps: [ActionStep(action: .click, elementId: "@b1")],
                verify: "No error banner visible",
                returnImageContent: true,
                observationMode: .auto,
                maxElements: 120,
                includeText: true,
                includeTables: false,
                diffCrop: true
            )
        ))
        XCTAssertTrue(actResp.ok, String(describing: actResp.error))
        XCTAssertEqual(recorded.names, ["act"])
        XCTAssertEqual(recorded.all.first?["observationMode"] as? String, "auto")
        XCTAssertEqual(recorded.all.first?["maxElements"] as? Int, 120)
        XCTAssertEqual(recorded.all.first?["includeTables"] as? Bool, false)

        // Network errors decoded cleanly
        XCTAssertEqual(actResp.actionResult?.networkErrors, ["POST https://fine.example/api/save -> 500 Internal Server Error"])
        // L1084 fix: localized checkbox toggle (maxTileDiff >= 0.8) did NOT trigger spurious action_no_visual_change reflex!
        XCTAssertNotEqual(actResp.actionResult?.agentFeedback?.trigger, "action_no_visual_change")
        // diffCrop populated dirtyRect and cropped the screenshot smaller than full 640x400
        let dirtyRect = try XCTUnwrap(actResp.actionResult?.dirtyRect)
        XCTAssertLessThan(dirtyRect.width, 640)
        let croppedShot = try XCTUnwrap(actResp.screenshot)
        XCTAssertLessThan(croppedShot.width, 640)
        // Tier 1 fast DOM verify succeeded in <5 ms without falling back to OCR
        XCTAssertEqual(actResp.actionResult?.visualVerification?.verified, true)
        XCTAssertEqual(actResp.actionResult?.visualVerification?.backend, "dom-ax-text")

        // 5. `tab_url` update to a blocked domain immediately blocks subsequent calls; `removed: true` evicts entry
        try await sendBridgeJSON(["type": "tab_url", "tabId": 10, "url": "https://blocked.example/now"], on: wsTask)
        let updated = await waitForBridgeCondition {
            service.chromeBridge.cachedTabURLs(profileQuery: "FastCache")[10] == "https://blocked.example/now"
        }
        XCTAssertTrue(updated)
        recorded.reset()
        let nowBlocked = await service.chromeBridge.observe(BrowserObserveParams(profile: "FastCache", tabId: 10))
        XCTAssertEqual(nowBlocked.error?.code, "TARGET_BLOCKED")
        XCTAssertEqual(recorded.names, [])

        try await sendBridgeJSON(["type": "tab_url", "tabId": 10, "removed": true], on: wsTask)
        let removed = await waitForBridgeCondition {
            service.chromeBridge.cachedTabURLs(profileQuery: "FastCache")[10] == nil
        }
        XCTAssertTrue(removed)
    }

    private final class AtomicTabCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Int
        init(start: Int) { self.current = start }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; current += 1; return current }
    }

    // MARK: - 6. browser_batch URL Policy Filtering & Concurrent Execution

    func testBrowserBatchPolicyFilteringAndConcurrentExecution() async throws {
        TargetRulesStore.shared.update(TargetRules(deniedSites: ["secret.example"]), persist: false)
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-batch-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.baseCommandTimeoutSeconds = 3
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "BatchProf", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "BatchProf" }
        XCTAssertTrue(ready)

        let recorded = RecordedCommands()
        let tabCounter = AtomicTabCounter(start: 200)
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                recorded.append(obj)
                if command == "open" {
                    let assigned = tabCounter.next()
                    let url = obj["url"] as? String ?? ""
                    try? await sendBridgeJSON([
                        "type": "response",
                        "id": id,
                        "ok": true,
                        "tabId": assigned,
                        "profileName": "BatchProf",
                        "url": url,
                        "title": "Page \(assigned)",
                        "snapshot": [
                            "app": ["pid": 0, "name": "Chrome (BatchProf)", "isActive": false, "isHidden": false, "windowTitle": "Page \(assigned)"],
                            "timestampMs": 1000,
                            "latencyMs": 1.0,
                            "fromHotCache": false,
                            "elements": []
                        ]
                    ], on: wsTask)
                } else {
                    try? await sendBridgeJSON(["type": "response", "id": id, "ok": true, "profileName": "BatchProf"], on: wsTask)
                }
            }
        }
        defer { responder.cancel() }

        let batchResp = await service.handle(RPCRequest(
            method: .browserBatch,
            browserBatch: BrowserBatchParams(
                profile: "BatchProf",
                urls: [
                    "https://one.example/a",
                    "file:///etc/passwd",
                    "https://secret.example/private",
                    "https://two.example/b"
                ],
                mode: "observe",
                autoDismissOverlays: true
            )
        ))
        XCTAssertTrue(batchResp.ok, String(describing: batchResp.error))
        let items = try XCTUnwrap(batchResp.browserBatchResult?.results)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items[0].success)
        XCTAssertEqual(items[0].url, "https://one.example/a")
        XCTAssertFalse(items[1].success)
        XCTAssertTrue(items[1].error?.contains("URL_BLOCKED") == true)
        XCTAssertFalse(items[2].success)
        XCTAssertTrue(items[2].error?.contains("TARGET_BLOCKED") == true)
        XCTAssertTrue(items[3].success)
        XCTAssertEqual(items[3].url, "https://two.example/b")

        let openedUrls = Set(recorded.all.filter { ($0["command"] as? String) == "open" }.compactMap { $0["url"] as? String })
        XCTAssertEqual(openedUrls, ["https://one.example/a", "https://two.example/b"])

        // Kill switch blocks browser_batch immediately
        service.tripKillSwitch(true)
        let killedResp = await service.handle(RPCRequest(
            method: .browserBatch,
            browserBatch: BrowserBatchParams(profile: "BatchProf", urls: ["https://one.example/"])
        ))
        XCTAssertEqual(killedResp.error?.code, "POLICY_BLOCKED")
        service.tripKillSwitch(false)
    }

    // MARK: - 7. skill_save / skill_list / skill_run & app_menu Governance

    func testSkillsLifecycleGovernanceAndReplay() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usemac-ut-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let store = SkillStore(storageURL: tempDir.appendingPathComponent("skills.json"))
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-skill-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir,
            skillStore: store
        )
        service.chromeBridge.baseCommandTimeoutSeconds = 3
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "SkillProf", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "SkillProf" }
        XCTAssertTrue(ready)

        let recorded = RecordedCommands()
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                if await answerTabsLookup(obj, on: wsTask, profileName: "SkillProf") { continue }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String else { continue }
                recorded.append(obj)
                let steps = obj["steps"] as? [[String: Any]] ?? []
                let failStep = steps.first?["text"] as? String == "trigger-drift"
                try? await sendBridgeJSON([
                    "type": "response",
                    "id": id,
                    "ok": true,
                    "tabId": 10,
                    "profileName": "SkillProf",
                    "url": "https://docs.example.com/",
                    "actionResult": [
                        "success": !failStep,
                        "totalLatencyMs": 3.0,
                        "stepResults": [
                            [
                                "index": 0,
                                "action": "setValue",
                                "success": !failStep,
                                "mechanism": "cdp",
                                "latencyMs": 2.0,
                                "message": failStep ? "Selector #search not found" : "ok"
                            ]
                        ],
                        "observation": [
                            "app": ["pid": 0, "name": "Chrome (SkillProf)", "isActive": false, "isHidden": false, "windowTitle": "Docs"],
                            "timestampMs": 1000,
                            "latencyMs": 1.0,
                            "fromHotCache": false,
                            "elements": []
                        ]
                    ]
                ], on: wsTask)
            }
        }
        defer { responder.cancel() }

        // Save a parameterized browser skill
        let saveResp = await service.handle(RPCRequest(
            method: .skillSave,
            skillSave: SkillSaveParams(
                name: "quick-search",
                description: "Search docs",
                target: "browser",
                urlPattern: "https://docs.example.com/*",
                steps: [
                    ActionStep(action: .setValue, selector: "#search", text: "{{query}}"),
                    ActionStep(action: .pressKey, key: "Return")
                ]
            )
        ))
        XCTAssertTrue(saveResp.ok, String(describing: saveResp.error))
        XCTAssertEqual(saveResp.skills?.saved?.params, ["query"])

        // Save a sensitive skill (with cmd+s)
        let saveSensitive = await service.handle(RPCRequest(
            method: .skillSave,
            skillSave: SkillSaveParams(
                name: "sensitive-shortcut",
                target: "browser",
                steps: [ActionStep(action: .pressKey, key: "s", modifiers: ["cmd"])]
            )
        ))
        XCTAssertTrue(saveSensitive.ok)

        // List skills
        let listResp = await service.handle(RPCRequest(method: .skillList, skillList: SkillListParams(query: "search")))
        XCTAssertTrue(listResp.ok)
        XCTAssertEqual(listResp.skills?.skills.map(\.name), ["quick-search"])

        // Missing required param is rejected
        let missingParamResp = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "quick-search", profile: "SkillProf", tabId: 10)
        ))
        XCTAssertEqual(missingParamResp.error?.code, "INVALID_REQUEST")

        // Governance: readOnly blocks skill_save AND mutating skill_run
        service.setGovernancePolicy(.readOnly)
        let readOnlySave = await service.handle(RPCRequest(
            method: .skillSave,
            skillSave: SkillSaveParams(name: "blocked", steps: [ActionStep(action: .wait, durationMs: 1)])
        ))
        XCTAssertEqual(readOnlySave.error?.code, "POLICY_BLOCKED")
        let readOnlyRun = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "quick-search", params: ["query": "swift"], profile: "SkillProf", tabId: 10)
        ))
        XCTAssertEqual(readOnlyRun.error?.code, "POLICY_BLOCKED")

        // Governance: confirmSensitive blocks skill_run containing cmd+s
        service.setGovernancePolicy(.confirmSensitive)
        let sensitiveRun = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "sensitive-shortcut", profile: "SkillProf", tabId: 10)
        ))
        XCTAssertEqual(sensitiveRun.error?.code, "POLICY_BLOCKED")

        // Autonomous mode replays interpolated steps cleanly
        service.setGovernancePolicy(.autonomous)
        recorded.reset()
        let runOk = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "quick-search", params: ["query": "apple vision"], profile: "SkillProf", tabId: 10)
        ))
        XCTAssertTrue(runOk.ok, String(describing: runOk.error))
        XCTAssertEqual(runOk.skillResult?.success, true)
        XCTAssertEqual(runOk.skillResult?.skill?.runCount, 1)
        XCTAssertNotNil(runOk.skillResult?.skill?.lastSuccessAtMs)
        let sentSteps = recorded.all.last?["steps"] as? [[String: Any]]
        XCTAssertEqual(sentSteps?.first?["text"] as? String, "apple vision")

        // Drift reports failed step index + fresh snapshot
        let runDrift = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "quick-search", params: ["query": "trigger-drift"], profile: "SkillProf", tabId: 10)
        ))
        XCTAssertTrue(runDrift.ok)
        XCTAssertEqual(runDrift.skillResult?.success, false)
        XCTAssertTrue(runDrift.skillResult?.message?.contains("step 0") == true)
        XCTAssertNotNil(runDrift.snapshot)

        // Delete skill
        let delResp = await service.handle(RPCRequest(
            method: .skillSave,
            skillSave: SkillSaveParams(name: "quick-search", delete: true)
        ))
        XCTAssertTrue(delResp.ok)
        XCTAssertNil(store.get(name: "quick-search"))
    }

    func testAppMenuGovernanceGuards() async {
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-menu-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0
        )

        // Self-target blocked
        let selfMenu = await service.handle(RPCRequest(
            method: .appMenu,
            appMenu: AppMenuParams(app: WorkspaceMonitor.useMacAppName, query: "Quit")
        ))
        XCTAssertEqual(selfMenu.error?.code, "SELF_TARGET_BLOCKED")

        // Read-only blocks menuPath invoke
        service.setGovernancePolicy(.readOnly)
        let roInvoke = await service.handle(RPCRequest(
            method: .appMenu,
            appMenu: AppMenuParams(app: "Finder", menuPath: ["File", "New Finder Window"])
        ))
        XCTAssertEqual(roInvoke.error?.code, "POLICY_BLOCKED")

        // TargetRules blocks denied app on app_menu
        service.setGovernancePolicy(.autonomous)
        TargetRulesStore.shared.update(TargetRules(deniedApps: ["com.apple.finder"]), persist: false)
        if WorkspaceMonitor().listRunningApps().contains(where: { $0.bundleId == "com.apple.finder" }) {
            let blockedMenu = await service.handle(RPCRequest(
                method: .appMenu,
                appMenu: AppMenuParams(app: "Finder", query: "New")
            ))
            XCTAssertEqual(blockedMenu.error?.code, "TARGET_BLOCKED")
        }
    }

    // MARK: - 8. Astra Review Security & Correctness Regression Tests

    func testReadOnlyBlocksAutoDismissAndRedirectDoesNotRunInlineSteps() async throws {
        TargetRulesStore.shared.update(TargetRules(deniedSites: ["vault.example"]), persist: false)
        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-sec-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir
        )
        service.chromeBridge.baseCommandTimeoutSeconds = 0.5
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "SecProf", tabCount: 1)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "SecProf" }
        XCTAssertTrue(ready)

        let recorded = RecordedCommands()
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String,
                      let command = obj["command"] as? String else { continue }
                recorded.append(obj)
                if command == "open" {
                    // Simulate server-side redirect from allowed shortener to blocked vault.example
                    try? await sendBridgeJSON([
                        "type": "response",
                        "id": id,
                        "ok": true,
                        "tabId": 91,
                        "profileName": "SecProf",
                        "url": "https://vault.example/login",
                        "title": "Vault"
                    ], on: wsTask)
                } else if command == "tabs" {
                    try? await sendBridgeJSON([
                        "type": "response",
                        "id": id,
                        "ok": true,
                        "profileName": "SecProf",
                        "tabs": [
                            ["tabId": 10, "title": "Vault", "url": "https://vault.example/secret", "active": true, "usemac": true]
                        ]
                    ], on: wsTask)
                } else {
                    try? await sendBridgeJSON(["type": "response", "id": id, "ok": true, "tabId": 91, "profileName": "SecProf"], on: wsTask)
                }
            }
        }
        defer { responder.cancel() }

        // 1. ReadOnly blocks browser_open(autoDismissOverlays: true) and browser_batch(autoDismissOverlays: true)
        service.setGovernancePolicy(.readOnly)
        let roOpen = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(url: "https://ok.example/", profile: "SecProf", autoDismissOverlays: true)
        ))
        XCTAssertEqual(roOpen.error?.code, "POLICY_BLOCKED")

        let roBatch = await service.handle(RPCRequest(
            method: .browserBatch,
            browserBatch: BrowserBatchParams(profile: "SecProf", urls: ["https://ok.example/"], autoDismissOverlays: true)
        ))
        XCTAssertEqual(roBatch.error?.code, "POLICY_BLOCKED")
        XCTAssertEqual(recorded.names, [])

        // 2. Under site rules, browser_open strips autoDismissOverlays & inline steps from `open`,
        // catches the redirect to blocked vault.example, and never sends any follow-up `act`.
        service.setGovernancePolicy(.autonomous)
        let redirOpen = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(
                url: "https://short.example/go",
                profile: "SecProf",
                steps: [ActionStep(action: .click, elementId: "@b1")],
                autoDismissOverlays: true
            )
        ))
        XCTAssertEqual(redirOpen.error?.code, "TARGET_BLOCKED")
        XCTAssertEqual(recorded.names, ["open"])
        XCTAssertNil(recorded.all.first?["steps"], "Inline steps must not be forwarded in open when site rules are active")
        XCTAssertNil(recorded.all.first?["autoDismissOverlays"], "autoDismissOverlays must not fire before destination URL passes TargetRules")

        // 3. `tab_url` with `loading: true` invalidates cached allowed URL and forces a live `tabs` lookup.
        try await sendBridgeJSON(["type": "tab_url", "tabId": 10, "url": "https://safe.example/app", "loading": false], on: wsTask)
        let cachedSafe = await waitForBridgeCondition {
            service.chromeBridge.liveCachedTabURL(profileQuery: "SecProf", tabId: 10)?.url == "https://safe.example/app"
        }
        XCTAssertTrue(cachedSafe)
        try await sendBridgeJSON(["type": "tab_url", "tabId": 10, "url": "https://safe.example/app", "loading": true], on: wsTask)
        let invalidated = await waitForBridgeCondition {
            service.chromeBridge.liveCachedTabURL(profileQuery: "SecProf", tabId: 10) == nil
        }
        XCTAssertTrue(invalidated)

        recorded.reset()
        let duringNav = await service.chromeBridge.observe(BrowserObserveParams(profile: "SecProf", tabId: 10))
        XCTAssertEqual(duringNav.error?.code, "TARGET_BLOCKED")
        XCTAssertEqual(recorded.names, ["tabs"], "Loading tab must bypass cache and run live tabs preflight")
    }

    func testSkillRunHonorsTaskIsolationAndLeaseAndAuditRedactsPiggyback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usemac-ut-skill-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyDir = makeTemporaryBridgeKeyDirectory()
        defer { try? FileManager.default.removeItem(at: keyDir) }

        let store = SkillStore(storageURL: tempDir.appendingPathComponent("skills.json"))
        let service = UseMacEngineService(
            socketPath: "/tmp/usemac-ut-skill-iso-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            bridgeKeyDirectory: keyDir,
            skillStore: store
        )
        service.chromeBridge.baseCommandTimeoutSeconds = 0.5
        service.chromeBridge.start()
        defer { service.chromeBridge.stop() }

        let port = await waitForListeningPort(of: service.chromeBridge)
        let key = try XCTUnwrap(service.bridgePairingKeyText().flatMap(BridgeKey.init(text:)))
        let wsTask = try await connectAuthenticatedMockExtension(port: port, key: key, profileName: "IsoProf", tabCount: 2)
        defer { wsTask.cancel(with: .goingAway, reason: nil) }
        let ready = await waitForBridgeCondition { service.chromeBridge.connectedProfiles().first?.profileName == "IsoProf" }
        XCTAssertTrue(ready)

        let recorded = RecordedCommands()
        let responder = Task {
            while !Task.isCancelled {
                guard let obj = try? await receiveBridgeJSON(from: wsTask) else { break }
                if await answerTabsLookup(obj, on: wsTask, profileName: "IsoProf") { continue }
                guard (obj["type"] as? String) == "request", let id = obj["id"] as? String else { continue }
                recorded.append(obj)
                try? await sendBridgeJSON([
                    "type": "response",
                    "id": id,
                    "ok": true,
                    "tabId": obj["tabId"] as? Int ?? 101,
                    "profileName": "IsoProf",
                    "url": "https://app.example/",
                    "actionResult": [
                        "success": true,
                        "totalLatencyMs": 1.0,
                        "stepResults": [["index": 0, "action": "setValue", "success": true, "mechanism": "cdp", "latencyMs": 1.0]]
                    ]
                ], on: wsTask)
            }
        }
        defer { responder.cancel() }

        _ = try store.save(SkillSaveParams(
            name: "fill-secret",
            target: "browser",
            steps: [ActionStep(action: .setValue, selector: "#pw", text: "{{secret}}")]
        ))

        // Task A owns tab 101; Task B owns tab 202.
        let startA = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "Task A")))
        let startB = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "Task B")))
        let taskA = try XCTUnwrap(startA.taskId)
        let taskB = try XCTUnwrap(startB.taskId)
        service.taskTabs.recordOpenedTab(101, taskId: taskA, profile: "IsoProf")
        service.taskTabs.recordOpenedTab(202, taskId: taskB, profile: "IsoProf")

        // Running browser skill without explicit tabId as Task A must route to Task A's tab 101!
        recorded.reset()
        let runA = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "fill-secret", params: ["secret": "hunter2-secret-value"], profile: "IsoProf"),
            taskId: taskA
        ))
        XCTAssertTrue(runA.ok, String(describing: runA.error))
        XCTAssertEqual(recorded.all.last?["tabId"] as? Int, 101, "skill_run must scope to its own task's last tab")

        // Task B attempting to run the skill on Task A's leased tab 101 must fail with TARGET_BUSY!
        let runBOnA = await service.handle(RPCRequest(
            method: .skillRun,
            skillRun: SkillRunParams(name: "fill-secret", params: ["secret": "other-secret-value"], profile: "IsoProf", tabId: 101),
            taskId: taskB
        ))
        XCTAssertEqual(runBOnA.error?.code, "TARGET_BUSY")

        // Piggybacked taskStart/taskComplete summaries that repeat a typed secret are scrubbed in audit logs.
        let secret = "SuperSecretToken98765"
        _ = await service.handle(RPCRequest(
            method: .browserOpen,
            browserOpen: BrowserOpenParams(
                url: "https://app.example/",
                profile: "IsoProf",
                steps: [ActionStep(action: .type, text: secret)]
            ),
            taskStart: TaskStartParams(summary: "Typing \(secret) now"),
            taskComplete: TaskCompleteParams(summary: "Done typing \(secret)")
        ))
        let audits = service.recentAuditEntries(limit: 20)
        XCTAssertFalse(audits.contains { $0.summary.contains(secret) }, "Piggybacked taskStart/taskComplete must scrub secrets: \(audits.map(\.summary))")

        // MCPTaskScope reconciles returned taskId/taskSummary even when the main piggybacked operation fails!
        let mcpScope = MCPTaskScope()
        let failedStartReq = RPCRequest(method: .browserObserve, taskStart: TaskStartParams(summary: "failing op"))
        var failedStartResp = RPCResponse.failure(id: "1", code: "EXTENSION_NOT_CONNECTED", message: "offline")
        failedStartResp.taskId = "task-failed-1"
        mcpScope.record(failedStartReq, response: failedStartResp)
        XCTAssertEqual(mcpScope.currentTaskId(), "task-failed-1")

        let failedCompleteReq = RPCRequest(method: .browserObserve, taskComplete: TaskCompleteParams(summary: "done"), taskId: "task-failed-1")
        var failedCompleteResp = RPCResponse.failure(id: "2", code: "EXTENSION_NOT_CONNECTED", message: "offline")
        failedCompleteResp.taskId = "task-failed-1"
        failedCompleteResp.taskSummary = TaskSummary(taskId: "task-failed-1")
        mcpScope.record(failedCompleteReq, response: failedCompleteResp)
        XCTAssertNil(mcpScope.currentTaskId())
    }
}
