import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UseMacProtocol

extension UseMacEngineService {
    func handleNativeObserve(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.observe ?? ObserveParams()
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app,
                activityTitle: "Observe blocked",
                reason: blockReason
            )
        }
        let observeTarget = resolveNativeTarget(params.app)
        if observeTarget == .useMac {
            return selfTargetResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "Observe blocked")
        }
        if case .app(let app) = observeTarget, let blocked = TargetRulesStore.shared.blockedMessage(for: app) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "Observe blocked", message: blocked)
        }
        guard case .app(let resolvedObserveApp) = observeTarget else {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: "App not found", latencyMs: latencyMs, success: false)
            emitLiveActivity(LiveActivityItem(
                kind: .observe,
                appName: params.app,
                title: "App not found",
                subtitle: params.app.map { "Target: \($0)" },
                latencyMs: latencyMs,
                success: false,
                isInProgress: false
            ))
            return .failure(
                id: request.id,
                code: "APP_NOT_FOUND",
                message: "No matching target application found",
                latencyMs: latencyMs
            )
        }

        // `window` pins the observed (and later acted-on) window; observing without it goes back to focus.
        WindowResolver.pin(pid: resolvedObserveApp.pid, title: params.window)
        if let wanted = params.window?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty,
           WindowResolver.window(pid: resolvedObserveApp.pid, titleContains: wanted) == nil {
            WindowResolver.pin(pid: resolvedObserveApp.pid, title: nil)
            let latencyMs = elapsedMs(since: startNs)
            return .failure(
                id: request.id,
                code: "ELEMENT_NOT_FOUND",
                message: "No \(resolvedObserveApp.name) window has a title containing \"\(wanted)\".",
                latencyMs: latencyMs
            )
        }
        let app = WorkspaceMonitor.withTargetWindow(resolvedObserveApp)
        if let blocked = await NativeBrowserSiteRules.blockedMessage(for: app, chromeBridge: chromeBridge) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "Observe blocked", message: blocked)
        }
        taskTabs.recordApp(app.pid, taskId: TaskActivityContext.taskId ?? request.namedTaskId)

        let perms = currentPermissions(promptAccessibility: false)
        let includeOffscreen = params.includeOffscreen ?? false
        let maxDepth = params.maxDepth ?? 10
        let maxElements = params.maxElements ?? 220
        let useCache = params.useCache ?? true
        let includeDiff = params.includeDiff ?? true

        var snapshot: WindowSnapshot
        var capturedShot: ScreenshotResult?
        if params.includeScreenshot == true, perms.screenRecordingGranted {
            let axIndexer = self.axIndexer
            let screenCapturer = self.screenCapturer
            let liveStreamer = self.liveStreamer
            let shotReq = ScreenshotRequest(
                app: params.app,
                includeBase64: params.returnImageContent ?? false
            )
            let currentTaskId = TaskActivityContext.taskId
            async let axTask: WindowSnapshot = Task.detached(priority: .userInitiated) {
                WindowResolver.withTaskPinScope(currentTaskId) {
                    axIndexer.observe(
                        app: app,
                        maxDepth: maxDepth,
                        maxElements: maxElements,
                        useCache: useCache,
                        includeDiff: includeDiff,
                        accessibilityGranted: perms.accessibilityGranted,
                        includeOffscreen: includeOffscreen
                    )
                }
            }.value
            async let shotTask: ScreenshotResult? = try? screenCapturer.capture(shotReq, targetApp: app, streamer: liveStreamer)
            snapshot = await axTask
            capturedShot = await shotTask
            if let shot = capturedShot {
                snapshot.screenshotPath = shot.path
            }
        } else {
            snapshot = axIndexer.observe(
                app: app,
                maxDepth: maxDepth,
                maxElements: maxElements,
                useCache: useCache,
                includeDiff: includeDiff,
                accessibilityGranted: perms.accessibilityGranted,
                includeOffscreen: includeOffscreen
            )
        }

        // Automatic AX + OCR `@vN` fusion for AX-blind Electron/Canvas/PDF windows
        // (runs on the unfiltered AX tree before applying any caller `ElementFilter`).
        // On hot-cache hits, reuse cached OCR nodes instead of re-capturing ScreenCaptureKit + Vision.
        if perms.accessibilityGranted,
           snapshot.elements.count < 5,
           perms.screenRecordingGranted,
           let bounds = snapshot.app.windowBounds,
           bounds.width > 300,
           bounds.height > 200 {
            let ocrNodes: [ElementNode]
            let currentGen = axIndexer.currentGeneration(pid: app.pid)
            if snapshot.fromHotCache {
                ocrNodes = cachedOCRNodes(forPid: app.pid, windowId: app.windowId, generation: currentGen)
            } else {
                ocrNodes = await fuseOCRElements(
                    app: app,
                    windowBounds: bounds,
                    existingScreenshotPath: capturedShot?.path
                )
                storeOCRNodes(ocrNodes, pid: app.pid, windowId: app.windowId, generation: currentGen)
            }
            if !ocrNodes.isEmpty {
                snapshot.elements.append(contentsOf: ocrNodes)
            }
        }

        if let filter = params.filter {
            snapshot = AXIndexer.filteringSnapshot(snapshot, with: filter)
        }

        recordObserveMetrics(latencyMs: snapshot.latencyMs, fromHotCache: snapshot.fromHotCache)
        let latencyMs = elapsedMs(since: startNs)
        let cacheTag = snapshot.fromHotCache ? "hot-cache" : "live-ax"
        let diffSummary = snapshot.diff?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let observeSubtitle = (diffSummary?.isEmpty == false) ? "\(cacheTag) · \(diffSummary!)" : cacheTag
        appendAudit(
            method: request.method.rawValue,
            targetApp: app.name,
            summary: "Observed \(snapshot.elements.count) elements (\(cacheTag))",
            latencyMs: latencyMs,
            success: true
        )
        let elementWord = snapshot.elements.count == 1 ? "element" : "elements"
        emitLiveActivity(LiveActivityItem(
            kind: .observe,
            appName: snapshot.app.name,
            appPid: snapshot.app.pid,
            bundleId: snapshot.app.bundleId,
            windowTitle: snapshot.app.windowTitle,
            windowBounds: snapshot.app.windowBounds,
            title: "Observed \(snapshot.elements.count) \(elementWord)",
            subtitle: observeSubtitle,
            mechanism: cacheTag,
            latencyMs: snapshot.latencyMs,
            success: true,
            isInProgress: false,
            targetGuessed: workspaceMonitor.isGuessedTarget(requestApp: params.app) ? true : nil,
            windowId: snapshot.app.windowId ?? app.windowId,
            isRestrictedPageFallback: nativeRestrictedPageFlag(for: app)
        ))
        return .success(id: request.id, latencyMs: latencyMs, snapshot: snapshot, screenshot: capturedShot)
    }

    func handleNativeScreenshot(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let req = request.screenshot ?? ScreenshotRequest()
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: req.app,
                activityTitle: "Screenshot blocked",
                reason: blockReason
            )
        }
        // A whole-display capture (no app) is a read and may show UseMac; a capture of UseMac itself is not.
        let screenshotTarget = resolveNativeTarget(req.app)
        if screenshotTarget == .useMac {
            return selfTargetResponse(request: request, startNs: startNs, targetApp: req.app, activityTitle: "Screenshot blocked")
        }
        if screenshotTarget == .notFound, req.app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: req.app, summary: "App not found", latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "APP_NOT_FOUND", message: "No matching target application found", latencyMs: latencyMs)
        }
        if case .app(let app) = screenshotTarget, let blocked = TargetRulesStore.shared.blockedMessage(for: app) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "Screenshot blocked", message: blocked)
        }
        let targetApp: AppDescriptor?
        if case .app(let app) = screenshotTarget {
            if let blocked = await NativeBrowserSiteRules.blockedMessage(for: app, chromeBridge: chromeBridge) {
                return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "Screenshot blocked", message: blocked)
            }
            taskTabs.recordApp(app.pid, taskId: TaskActivityContext.taskId ?? request.namedTaskId)
            targetApp = app
        } else {
            targetApp = nil
        }
        guard permissionManager.isScreenRecordingGranted() else {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: req.app, summary: "Screen Recording permission denied", latencyMs: latencyMs, success: false)
            return .failure(
                id: request.id,
                code: "PERMISSION_DENIED",
                message: "Screen Recording permission not granted",
                latencyMs: latencyMs
            )
        }

        do {
            let rawResult = try await screenCapturer.capture(req, targetApp: targetApp, streamer: liveStreamer)
            let targetKey = targetApp.map { "native:\($0.pid)" } ?? "native:display"
            var result = rawResult
            // `FastScreenCapturer.capture` already applies explicit `req.region` on the full-resolution CGImage.
            // Only update the full-frame baseline / compute `diffCrop` when no explicit `region` was requested.
            if req.region == nil, let rawData = try? Data(contentsOf: URL(fileURLWithPath: rawResult.path)) {
                let cropped = applyRegionOrDiffCrop(
                    jpegData: rawData,
                    original: rawResult,
                    targetKey: targetKey,
                    region: nil,
                    diffCrop: req.diffCrop == true,
                    maxDimension: req.maxDimension,
                    quality: req.quality,
                    includeBase64: req.includeBase64
                )
                result = cropped.screenshot
            }
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(
                method: request.method.rawValue,
                targetApp: targetApp?.name,
                summary: "Captured \(result.width)x\(result.height) JPEG (\(result.byteCount) bytes)",
                latencyMs: latencyMs,
                success: true
            )
            emitLiveActivity(LiveActivityItem(
                kind: .screenshot,
                appName: targetApp?.name,
                appPid: targetApp?.pid,
                bundleId: targetApp?.bundleId,
                windowTitle: targetApp?.windowTitle,
                windowBounds: targetApp?.windowBounds,
                title: "Captured \(result.width)×\(result.height) window",
                subtitle: "\(max(1, result.byteCount / 1024)) KB · JPEG",
                latencyMs: result.latencyMs,
                success: true,
                isInProgress: false,
                targetGuessed: workspaceMonitor.isGuessedTarget(requestApp: req.app) ? true : nil,
                windowId: targetApp?.windowId
            ))
            return .success(id: request.id, latencyMs: latencyMs, screenshot: result)
        } catch {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: targetApp?.name, summary: error.localizedDescription, latencyMs: latencyMs, success: false)
            return .failure(
                id: request.id,
                code: "CAPTURE_FAILED",
                message: error.localizedDescription,
                latencyMs: latencyMs
            )
        }
    }

    func handleVisionStatus(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        let vStatus = localVision.currentStatus()
        let latencyMs = elapsedMs(since: startNs)
        return .success(id: request.id, latencyMs: latencyMs, visionStatus: vStatus)
    }

    func handleVisionQuery(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.visionQuery ?? VisionQueryParams()
        let visionTargetLabel = params.profile.map { "Chrome (\($0))" } ?? params.app ?? "Local Vision"
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: visionTargetLabel,
                activityTitle: "Vision query blocked",
                reason: blockReason
            )
        }
        if workspaceMonitor.namesUseMac(params.app) {
            return selfTargetResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "Vision query blocked")
        }
        if let blocked = TargetRulesStore.shared.blockedMessage(forQueries: [params.app], in: workspaceMonitor) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "Vision query blocked", message: blocked)
        }
        if let blocked = await chromeBridge.targetRulesVisionPreflight(params) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: visionTargetLabel, activityTitle: "Vision query blocked", message: blocked.error?.message ?? "")
        }
        if let rawImagePath = params.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawImagePath.isEmpty {
            guard isAllowedVisionImagePath(rawImagePath) else {
                let latencyMs = elapsedMs(since: startNs)
                let message = "imagePath must be inside the UseMac capture directory or the temporary directory."
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: visionTargetLabel,
                    summary: "Blocked imagePath: \(rawImagePath)",
                    latencyMs: latencyMs,
                    success: false
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: visionTargetLabel,
                    title: "Vision query blocked",
                    subtitle: message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                return .failure(id: request.id, code: "IMAGE_PATH_BLOCKED", message: message, latencyMs: latencyMs)
            }
        }
        let normalizedMode = params.mode.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let visionHudTitle: String = {
            switch normalizedMode {
            case "verify": return "Verifying locally…"
            case "locate": return "Locating element locally…"
            case "diagnose": return "Diagnosing screen locally…"
            case "ocr": return "Reading text locally…"
            default: return "Checking screen locally…"
            }
        }()
        let resolved = await resolveVisionInputImage(params: params)
        if case .blocked(let message) = resolved {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: visionTargetLabel, activityTitle: "Vision query blocked", message: message)
        }
        guard case .image(let input) = resolved else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(
                id: request.id,
                code: "NO_IMAGE_SOURCE",
                message: "No screenshot or active browser frame available for vision_query.",
                latencyMs: latencyMs
            )
        }
        if let tooSmall = Self.tooSmallCaptureMessage(path: input.path) {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "CAPTURE_TOO_SMALL", message: tooSmall, latencyMs: latencyMs)
        }
        let targetLabel = input.profileName.map { "Chrome (\($0))" } ?? params.profile.map { "Chrome (\($0))" } ?? params.app ?? "Local Vision"
        emitLiveActivity(LiveActivityItem(
            kind: .observe,
            appName: targetLabel,
            windowTitle: input.title,
            title: visionHudTitle,
            subtitle: localVision.currentStatus().backend,
            mechanism: localVision.currentStatus().backend,
            success: true,
            isInProgress: true,
            browserTabId: input.tabId ?? params.tabId,
            browserProfile: input.profileName ?? params.profile
        ))
        let result = await localVision.query(
            mode: params.mode,
            query: params.query,
            imagePath: input.path,
            viewportWidth: input.width,
            viewportHeight: input.height
        )
        let latencyMs = elapsedMs(since: startNs)
        if result.answer.hasPrefix("CAPTURE_TOO_SMALL:") {
            let message = result.answer.dropFirst("CAPTURE_TOO_SMALL:".count).trimmingCharacters(in: .whitespaces)
            // Settle the "…locally" caption shown above; it would otherwise spin until the next activity.
            emitLiveActivity(LiveActivityItem(
                kind: .observe,
                appName: targetLabel,
                windowTitle: input.title,
                title: "Couldn't check the screen",
                subtitle: ActivityCaption.reason(errorCode: "CAPTURE_TOO_SMALL"),
                mechanism: result.backend,
                latencyMs: result.latencyMs,
                success: false,
                isInProgress: false,
                browserTabId: input.tabId ?? params.tabId,
                browserProfile: input.profileName ?? params.profile
            ))
            return .failure(id: request.id, code: "CAPTURE_TOO_SMALL", message: message, latencyMs: latencyMs)
        }
        let doneTitle: String = {
            switch result.mode {
            case "verify":
                if result.verified == true { return "Verified locally" }
                if result.verified == false { return "Check flagged issue" }
                return "Checked locally"
            case "locate": return "Located locally"
            case "ocr": return "Read screen text"
            default: return "Checked locally"
            }
        }()
        emitLiveActivity(LiveActivityItem(
            kind: .observe,
            appName: targetLabel,
            windowTitle: input.title,
            title: doneTitle,
            subtitle: "\(result.backend) · \(Int(result.latencyMs)) ms",
            mechanism: result.backend,
            latencyMs: result.latencyMs,
            success: true,
            isInProgress: false,
            browserTabId: input.tabId ?? params.tabId,
            browserProfile: input.profileName ?? params.profile
        ))
        appendAudit(
            method: request.method.rawValue,
            targetApp: targetLabel,
            summary: AuditRedactor.visionSummary(mode: result.mode, backend: result.backend, answer: result.answer),
            latencyMs: latencyMs,
            success: true
        )
        return .success(id: request.id, latencyMs: latencyMs, visionResult: result)
    }

    private typealias VisionInputImage = (path: String, width: Double, height: Double, tabId: Int?, profileName: String?, title: String?)

    private enum VisionInputResolution {
        case image(VisionInputImage)
        case blocked(String)
        case unavailable
    }

    private func resolveVisionInputImage(params: VisionQueryParams) async -> VisionInputResolution {
        if let rawExplicit = params.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawExplicit.isEmpty {
            let expanded = (rawExplicit as NSString).expandingTildeInPath
            let explicit = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            if FileManager.default.fileExists(atPath: explicit) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: explicit)),
                   let cg = LocalVisionEngine.decodeCGImage(fromJPEG: data) {
                    return .image((explicit, Double(cg.width), Double(cg.height), params.tabId, params.profile, nil))
                }
                return .image((explicit, 1280, 800, params.tabId, params.profile, nil))
            }
        }

        // Prefer Chrome tab frame if profile/tabId/selector/elementId requested or Chrome bridge is connected
        let wantsChrome = params.profile != nil || params.tabId != nil || params.selector != nil || params.elementId != nil || (params.app == nil && !chromeBridge.connectedProfiles().isEmpty)
        if wantsChrome {
            // When caller targets a specific element/CSS selector crop, capture a sharp local crop directly
            if params.selector != nil || params.elementId != nil {
                let cropResp = await chromeBridge.screenshot(BrowserScreenshotParams(
                    profile: params.profile,
                    tabId: params.tabId,
                    selector: params.selector,
                    elementId: params.elementId,
                    fullPage: false,
                    quality: 88,
                    returnImageContent: false
                ))
                if cropResp.ok, let shot = cropResp.screenshot {
                    return .image((
                        shot.path,
                        Double(shot.width),
                        Double(shot.height),
                        cropResp.tabId ?? params.tabId,
                        cropResp.profileName ?? params.profile,
                        cropResp.title
                    ))
                }
            }

            // Use cached live stream frame when fresh (< 1.5s old) for zero capture latency
            if let cached = chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId),
               Date().timeIntervalSince(cached.capturedAt) < 1.5,
               !cached.showsIndicator {
                let dir = UseMacDefaults.captureDirectory
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let path = (dir as NSString).appendingPathComponent("vision-browser-\(cached.tabId ?? 0)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                if (try? cached.jpegData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
                    return .image((
                        path,
                        Double(cached.viewportWidth),
                        Double(cached.viewportHeight),
                        cached.tabId,
                        cached.profileName,
                        cached.title
                    ))
                }
            }

            // Otherwise capture a fresh local-only JPEG directly from the background Chrome tab (~35ms, never sent to cloud)
            let freshResp = await chromeBridge.screenshot(BrowserScreenshotParams(
                profile: params.profile,
                tabId: params.tabId,
                fullPage: false,
                quality: 84,
                returnImageContent: false
            ))
            if freshResp.ok, let shot = freshResp.screenshot {
                return .image((
                    shot.path,
                    Double(shot.width),
                    Double(shot.height),
                    freshResp.tabId ?? params.tabId,
                    freshResp.profileName ?? params.profile,
                    freshResp.title
                ))
            }

            // Fallback to slightly older cached frame if fresh capture wasn't possible
            if let cached = chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId) {
                let dir = UseMacDefaults.captureDirectory
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let path = (dir as NSString).appendingPathComponent("vision-browser-\(cached.tabId ?? 0)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                if (try? cached.jpegData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
                    return .image((
                        path,
                        Double(cached.viewportWidth),
                        Double(cached.viewportHeight),
                        cached.tabId,
                        cached.profileName,
                        cached.title
                    ))
                }
            }
        }

        // Fallback to native app screenshot
        let targetApp: AppDescriptor?
        switch resolveNativeTarget(params.app) {
        case .app(let app):
            if let blocked = await NativeBrowserSiteRules.blockedMessage(for: app, chromeBridge: chromeBridge) {
                return .blocked(blocked)
            }
            targetApp = app
        case .useMac, .notFound:
            targetApp = nil
        }
        let shotReq = ScreenshotRequest(
            app: params.app,
            maxDimension: 1280,
            quality: 0.82,
            includeBase64: false
        )
        if let shot = try? await screenCapturer.capture(shotReq, targetApp: targetApp, streamer: liveStreamer) {
            let w = targetApp?.windowBounds?.width ?? Double(shot.width)
            let h = targetApp?.windowBounds?.height ?? Double(shot.height)
            return .image((shot.path, w, h, nil, nil, targetApp?.windowTitle ?? targetApp?.name))
        }
        return .unavailable
    }

    private func normalizedDirectoryPrefix(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasSuffix("/") ? resolved : resolved + "/"
    }

    /// A capture this small is almost certainly the wrong window (e.g. a 52x20 helper strip); answering from
    /// it would be a confident guess. Returns the refusal message, or nil when the image is usable.
    static func tooSmallCaptureMessage(path: String?) -> String? {
        guard let path,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        guard min(width, height) < 64 else { return nil }
        return "The captured image is only \(width)x\(height) px, which means the wrong window was captured. Nothing was analyzed. Observe the app again or pass a tabId/selector."
    }

    private func isAllowedVisionImagePath(_ rawPath: String) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolvedPath = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        let allowedRoots = [
            normalizedDirectoryPrefix(NSTemporaryDirectory()),
            normalizedDirectoryPrefix("/private/tmp")
        ]
        return allowedRoots.contains { resolvedPath.hasPrefix($0) }
    }

    func performCachedHighlight(_ elementId: String, durationMs: Int) async -> CachedHighlightResult {
        let owner: (node: ElementNode, pid: Int32, windowId: UInt32?)
        if elementId.hasPrefix("@v") {
            guard let app = workspaceMonitor.resolveApp(query: nil),
                  let node = lookupOCRNode(
                    elementId, pid: app.pid, windowId: app.windowId, generation: axIndexer.currentGeneration(pid: app.pid)
                  ) else { return .notFound }
            owner = (node, app.pid, app.windowId)
        } else {
            guard let cached = axIndexer.cachedElementOwner(for: elementId) else { return .notFound }
            owner = cached
        }

        let runningApp = NSRunningApplication(processIdentifier: owner.pid)
        let app = AppDescriptor(pid: owner.pid, name: runningApp?.localizedName ?? "", bundleId: runningApp?.bundleIdentifier)
        if TargetRulesStore.shared.blocksProcess(pid: owner.pid) {
            let message = TargetRulesStore.shared.blockedMessage(for: app) ?? "The element's app is blocked by the app and site rules."
            return .blocked(message)
        }
        if TargetRulesStore.shared.rules.hasSiteRules {
            guard runningApp != nil else { return .notFound }
            if NativeBrowserSiteRules.isChromiumApp(bundleId: app.bundleId, name: app.name) {
                let target = currentNativeWindow(for: app)
                guard let windowId = owner.windowId, target.windowId == windowId else {
                    return .blocked(TargetRules.unconfirmedSiteMessage(reason: "the cached element's window is no longer the browser target"))
                }
                if let message = await NativeBrowserSiteRules.blockedMessage(for: target, chromeBridge: chromeBridge) {
                    return .blocked(message)
                }
            }
        }

        onOverlayEvent?(.highlightElement(
            rect: owner.node.frame,
            label: owner.node.id,
            role: owner.node.role,
            durationMs: durationMs,
            pid: owner.pid,
            windowId: owner.windowId
        ))
        return .highlighted(owner.node.frame)
    }

    // MARK: - Tiered Verification, Dirty-Rect Cropping, AX+OCR Fusion, Filtering

    /// Tiered local verification: checks deterministic DOM/AX snapshot text first (`<1 ms`),
    /// then falls back to negation-safe Apple Vision OCR (`~20 ms`) when needed.
    func runTieredVerify(
        assertion: String,
        snapshot: WindowSnapshot?,
        visionParams: VisionQueryParams,
        inMemoryJPEG: Data?,
        viewportWidth: Double?,
        viewportHeight: Double?
    ) async -> VisionQueryResult? {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let negated = LocalVisionEngine.isNegatedAssertion(assertion)
        let corpus = Self.deterministicTextCorpus(from: snapshot)
        var tier1Result: VisionQueryResult?

        if !corpus.isEmpty {
            let check = LocalVisionEngine.verifyAssertion(assertion, againstOCRText: corpus)
            let tier1Ms = (elapsedMs(since: startNs) * 100).rounded() / 100
            let candidate = VisionQueryResult(
                mode: "verify",
                backend: "dom-ax-text",
                modelId: nil,
                latencyMs: tier1Ms,
                answer: check.evidence,
                verified: check.verified,
                blockingDetected: false,
                detections: [],
                imagePath: snapshot?.screenshotPath
            )
            tier1Result = candidate

            let hasRichSnapshot: Bool = {
                guard let snapshot else { return false }
                let hasText = !(snapshot.pageState?.readableText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                return snapshot.elements.count >= 5 || hasText
            }()

            // Conclusive deterministic hit:
            // - Positive assertion matched DOM/AX text -> verified immediately (<1 ms).
            // - Negated assertion found forbidden text in DOM/AX -> failed immediately (<1 ms).
            // - Negated assertion saw no forbidden text in a full/rich snapshot -> verified immediately (<1 ms).
            if (!negated && check.verified) || (negated && !check.verified) || (negated && check.verified && hasRichSnapshot) {
                return candidate
            }
        }

        // Tier 2: Fast in-memory Apple Vision OCR if we already have the post-action JPEG (~15-25 ms, zero disk I/O).
        if let jpeg = inMemoryJPEG,
           let cgImage = LocalVisionEngine.decodeCGImage(fromJPEG: jpeg),
           min(cgImage.width, cgImage.height) >= LocalVisionEngine.minimumImageSide {
            let ocrStartNs = DispatchTime.now().uptimeNanoseconds
            let ocr = await Task.detached(priority: .userInitiated) {
                LocalVisionEngine.recognizeTextDetailed(
                    in: cgImage,
                    viewportWidth: Double(cgImage.width),
                    viewportHeight: Double(cgImage.height),
                    fast: false
                )
            }.value
            let ocrMs = (elapsedMs(since: ocrStartNs) * 100).rounded() / 100
            if let ocrError = ocr.error {
                return VisionQueryResult(
                    mode: "verify",
                    backend: "apple-vision-ocr",
                    modelId: nil,
                    latencyMs: ocrMs,
                    answer: "Apple Vision OCR failed (\(ocrError)); verification is indeterminate.",
                    verified: nil,
                    blockingDetected: false,
                    detections: [],
                    imagePath: snapshot?.screenshotPath
                )
            }
            let ocrText = ocr.detections.map(\.label).joined(separator: " | ")
            let combinedText = [corpus, ocrText].filter { !$0.isEmpty }.joined(separator: " | ")
            let check = LocalVisionEngine.verifyAssertion(assertion, againstOCRText: combinedText)
            return VisionQueryResult(
                mode: "verify",
                backend: "apple-vision-ocr",
                modelId: nil,
                latencyMs: ocrMs,
                answer: check.evidence,
                verified: check.verified,
                blockingDetected: false,
                detections: [],
                imagePath: snapshot?.screenshotPath
            )
        }

        // Tier 2 fallback via resolved capture image when no in-memory JPEG is available.
        if case .image(let input) = await resolveVisionInputImage(params: visionParams) {
            return await localVision.query(
                mode: "verify",
                query: assertion,
                imagePath: input.path,
                viewportWidth: viewportWidth ?? input.width,
                viewportHeight: viewportHeight ?? input.height
            )
        }

        return tier1Result
    }

    static func deterministicTextCorpus(from snapshot: WindowSnapshot?) -> String {
        guard let snapshot else { return "" }
        var parts: [String] = []
        if let title = snapshot.app.windowTitle, !title.isEmpty {
            parts.append(title)
        }
        for node in snapshot.elements {
            if let t = node.title, !t.isEmpty { parts.append(t) }
            if let v = node.value, !v.isEmpty { parts.append(v) }
        }
        if let diff = snapshot.diff {
            for node in diff.added + diff.changed {
                if let t = node.title, !t.isEmpty { parts.append(t) }
                if let v = node.value, !v.isEmpty { parts.append(v) }
            }
        }
        if let page = snapshot.pageState {
            if let overlay = page.blockingOverlay, !overlay.summary.isEmpty {
                parts.append(overlay.summary)
            }
            if let text = page.readableText, !text.isEmpty {
                parts.append(text)
            }
            if let tables = page.tablesMarkdown, !tables.isEmpty {
                parts.append(tables)
            }
        }
        return parts.joined(separator: " | ")
    }

    struct InMemoryDiagnosis {
        let blockingDetected: Bool
        let summary: String
        let deltaText: String
        let closeX: Double?
        let closeY: Double?
    }

    static func diagnoseInMemoryWithAppleVision(
        jpegData: Data,
        dirtyRect: ScreenRect?,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> InMemoryDiagnosis {
        guard let cgImage = LocalVisionEngine.decodeCGImage(fromJPEG: jpegData),
              min(cgImage.width, cgImage.height) >= LocalVisionEngine.minimumImageSide else {
            return InMemoryDiagnosis(blockingDetected: false, summary: "", deltaText: "", closeX: nil, closeY: nil)
        }

        var deltaText = ""
        if let dirtyRect {
            deltaText = LocalVisionEngine.recognizeText(in: cgImage, region: dirtyRect, fast: true).text
        }

        let detections = LocalVisionEngine.recognizeText(
            in: cgImage,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            fast: true
        )
        let dismissKeywords = ["fechar", "close", "nao", "agora nao", "recusar", "rejeitar", "no thanks", "not now", "x", "×"]
        let popupKeywords = ["notificac", "cookies", "permitir", "eu quero", "newsletter", "assine", "consent", "privacy"]

        let hasPopup = detections.contains { det in
            let lower = det.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return popupKeywords.contains(where: { lower.contains($0) })
        }
        let closeMatch = detections.first { det in
            let lower = det.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return dismissKeywords.contains(where: { lower == $0 || lower.contains($0) })
        }

        let preview = !deltaText.isEmpty
            ? deltaText
            : detections.prefix(16).map(\.label).joined(separator: " | ")
        let summary: String
        if let closeMatch, hasPopup {
            summary = "Apple Vision OCR detected overlay dismiss \"\(closeMatch.label)\" at (\(Int(closeMatch.x)), \(Int(closeMatch.y)))."
        } else if hasPopup {
            summary = "Apple Vision OCR detected popup/banner text: \(preview)"
        } else {
            summary = preview
        }

        return InMemoryDiagnosis(
            blockingDetected: hasPopup,
            summary: summary,
            deltaText: deltaText,
            closeX: hasPopup ? closeMatch?.x : nil,
            closeY: hasPopup ? closeMatch?.y : nil
        )
    }

    private func fuseOCRElements(
        app: AppDescriptor,
        windowBounds: ScreenRect,
        existingScreenshotPath: String?
    ) async -> [ElementNode] {
        if let path = existingScreenshotPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return await Task.detached(priority: .userInitiated) {
                LocalVisionEngine.ocrElementNodes(fromJPEG: data, windowBounds: windowBounds)
            }.value
        }
        guard let preview = await screenCapturer.capturePreviewCGImage(
            targetApp: app,
            maxDimension: 1280,
            streamer: liveStreamer
        ) else {
            return []
        }
        let effectiveBounds = preview.windowBounds ?? windowBounds
        let image = preview.image
        return await Task.detached(priority: .userInitiated) {
            LocalVisionEngine.ocrElementNodes(from: image, windowBounds: effectiveBounds)
        }.value
    }

    private func storeOCRNodes(_ nodes: [ElementNode], pid: Int32, windowId: UInt32?, generation: UInt64) {
        var map: [String: ElementNode] = [:]
        for node in nodes {
            map[node.id] = node
        }
        stateLock.lock()
        if map.isEmpty {
            ocrNodesByPid.removeValue(forKey: pid)
        } else {
            ocrNodesByPid[pid] = OCRSnapshotRecord(windowId: windowId, generation: generation, nodes: map)
        }
        stateLock.unlock()
    }

    func invalidateOCRNodes(forPid pid: Int32) {
        stateLock.lock()
        ocrNodesByPid.removeValue(forKey: pid)
        stateLock.unlock()
    }

    private func cachedOCRNodes(forPid pid: Int32, windowId: UInt32?, generation: UInt64) -> [ElementNode] {
        stateLock.lock()
        let record = ocrNodesByPid[pid]
        stateLock.unlock()
        guard let record else { return [] }
        if let recWin = record.windowId, let curWin = windowId, recWin != curWin {
            return []
        }
        guard record.generation == generation else { return [] }
        return Array(record.nodes.values).sorted { lhs, rhs in
            let lNum = Int(lhs.id.dropFirst(2)) ?? Int.max
            let rNum = Int(rhs.id.dropFirst(2)) ?? Int.max
            return lNum < rNum
        }
    }

    private func lookupOCRNode(_ id: String, pid: Int32, windowId: UInt32?, generation: UInt64) -> ElementNode? {
        stateLock.lock()
        let record = ocrNodesByPid[pid]
        stateLock.unlock()
        guard let record else { return nil }
        if let recWin = record.windowId, let curWin = windowId, recWin != curWin {
            return nil
        }
        guard record.generation == generation else { return nil }
        return record.nodes[id]
    }

    func resolveOCRElementTargets(in request: BatchActionRequest, defaultApp: AppDescriptor?) -> BatchActionRequest {
        guard request.steps.contains(where: { $0.elementId?.hasPrefix("@v") == true && $0.x == nil && $0.y == nil }) else {
            return request
        }
        var copy = request
        var activeApp = defaultApp
        for idx in copy.steps.indices {
            if let stepAppQuery = copy.steps[idx].app,
               !stepAppQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activeApp = workspaceMonitor.resolveApp(query: stepAppQuery)
            }
            guard let id = copy.steps[idx].elementId, id.hasPrefix("@v"),
                  copy.steps[idx].x == nil, copy.steps[idx].y == nil else {
                continue
            }
            guard let target = activeApp, target.pid > 0 else {
                continue
            }
            let currentGen = axIndexer.currentGeneration(pid: target.pid)
            if let node = lookupOCRNode(id, pid: target.pid, windowId: target.windowId, generation: currentGen) {
                copy.steps[idx].x = node.frame.centerX
                copy.steps[idx].y = node.frame.centerY
                copy.steps[idx].elementId = nil
            }
            // If no valid OCR ref exists for this app/window/generation, leave `@vN` untouched so
            // ActionExecutor fails cleanly as stale instead of substituting coordinates from another app.
        }
        return copy
    }

    func cachedScreenshotJPEG(forKey key: String) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastScreenshotJPEGByTarget[key]
    }

    func storeScreenshotJPEG(_ data: Data, forKey key: String) {
        guard data.count <= 6_000_000 else { return }
        stateLock.lock()
        lastScreenshotJPEGByTarget[key] = data
        lastScreenshotKeyOrder.removeAll { $0 == key }
        lastScreenshotKeyOrder.append(key)
        while lastScreenshotKeyOrder.count > 12 {
            let oldest = lastScreenshotKeyOrder.removeFirst()
            lastScreenshotJPEGByTarget.removeValue(forKey: oldest)
        }
        stateLock.unlock()
    }

    func applyRegionOrDiffCrop(
        jpegData: Data,
        original: ScreenshotResult,
        targetKey: String,
        region: ScreenRect?,
        diffCrop: Bool,
        maxDimension: Int,
        quality: Double,
        includeBase64: Bool
    ) -> (screenshot: ScreenshotResult, dirtyRect: ScreenRect?) {
        let previousJPEG = cachedScreenshotJPEG(forKey: targetKey)
        storeScreenshotJPEG(jpegData, forKey: targetKey)

        if let region {
            if let cropped = saveCroppedJPEG(
                fromJPEG: jpegData,
                rect: region,
                padding: 0,
                maxDimension: maxDimension,
                quality: quality,
                includeBase64: includeBase64,
                latencyMs: original.latencyMs
            ) {
                return (cropped, region)
            }
            return (original, nil)
        }

        if diffCrop, let previousJPEG {
            let dirty = LocalVisionEngine.computeDirtyRegion(beforeJPEG: previousJPEG, afterJPEG: jpegData)
            if let dirtyRect = dirty.dirtyRect,
               let cropped = saveCroppedJPEG(
                fromJPEG: jpegData,
                rect: dirtyRect,
                padding: 24,
                maxDimension: maxDimension,
                quality: quality,
                includeBase64: includeBase64,
                latencyMs: original.latencyMs
               ) {
                return (cropped, dirtyRect)
            }
        }

        return (original, nil)
    }

    func saveCroppedJPEG(
        fromJPEG data: Data,
        rect: ScreenRect,
        padding: Double,
        maxDimension: Int,
        quality: Double,
        includeBase64: Bool,
        latencyMs: Double
    ) -> ScreenshotResult? {
        guard let croppedData = LocalVisionEngine.cropJPEG(
            fromJPEG: data,
            rect: rect,
            padding: padding,
            maxDimension: maxDimension,
            quality: quality
        ),
              let croppedCG = LocalVisionEngine.decodeCGImage(fromJPEG: croppedData) else {
            return nil
        }

        let dir = UseMacDefaults.captureDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let path = "\(dir)/crop-\(nowMs)-\(UUID().uuidString.prefix(4)).jpg"
        guard (try? croppedData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else {
            return nil
        }
        return ScreenshotResult(
            path: path,
            mimeType: "image/jpeg",
            width: croppedCG.width,
            height: croppedCG.height,
            byteCount: croppedData.count,
            latencyMs: latencyMs,
            base64Data: includeBase64 ? croppedData.base64EncodedString() : nil
        )
    }
}
