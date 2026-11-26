import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UseMacProtocol

public final class UseMacEngineService: UseMacServiceProtocol, @unchecked Sendable {
    private let socketPath: String
    private let permissionManager = PermissionManager()
    let killSwitch = KillSwitch()
    let workspaceMonitor = WorkspaceMonitor()
    /// Which running task owns which Chrome tabs UseMac opened (see TaskTabRegistry).
    let taskTabs = TaskTabRegistry()
    private let axIndexer = AXIndexer()
    private let screenCapturer = FastScreenCapturer()
    public let liveStreamer = LiveScreenStreamer()
    public let chromeBridge: ChromeExtensionBridge
    public let localVision: LocalVisionEngine
    public let skillStore: SkillStore
    private let actionExecutor: ActionExecutor
    /// Ask mode: sensitive requests waiting for the user's answer in the HUD.
    public let approvals = ApprovalBroker()
    /// `report_prepare` drafts waiting in the app's review window (UseMacEngineService+ProblemReport.swift).
    public let problemReports = ProblemReportBroker()
    /// Debug capture: off until the user turns it on in Settings (UseMacEngineService+DebugCapture.swift).
    let debugCaptureGate = DebugCaptureGate()
    /// The audit log on disk; nil keeps it in memory only (tests, in-process CLI calls).
    public let auditStore: AuditLogStore?

    private let stateLock = NSLock()
    private let startedAt = Date()
    private var totalRequests: Int = 0
    private var totalActions: Int = 0
    private var lastObserveLatencyMs: Double = 0
    private var totalObserveLatencyMs: Double = 0
    private var observeCount: Int = 0
    private var hotCacheHits: Int = 0
    private var activeClients: Int = 0
    private var auditEntries: [AuditEntry] = []
    private var lastCapturePruneAt: Date?
    /// Last full screenshot JPEG per target key (`native:<pid>`, `browser:<profile>:<tabId>`) for `diffCrop`.
    private var lastScreenshotJPEGByTarget: [String: Data] = [:]
    private var lastScreenshotKeyOrder: [String] = []
    /// Last OCR-fused `@vN` element nodes per app PID so native `act` / `highlight` can target them.
    private var ocrNodesByPid: [Int32: [String: ElementNode]] = [:]
    private static let capturePruneInterval: TimeInterval = 60
    private static let captureRetentionSeconds: TimeInterval = 1800
    private static let capturePruneQueue = DispatchQueue(label: "app.usemac.capture-prune", qos: .utility)

    private var _onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    private var _onLiveActivity: (@Sendable (LiveActivityItem) -> Void)?
    private var _onStateChanged: (@Sendable () -> Void)?

    public var onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onOverlayEvent
        }
        set {
            stateLock.lock()
            _onOverlayEvent = newValue
            stateLock.unlock()
        }
    }

    public var onLiveActivity: (@Sendable (LiveActivityItem) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onLiveActivity.map(TaskActivityContext.labeling)
        }
        set {
            stateLock.lock()
            _onLiveActivity = newValue
            stateLock.unlock()
        }
    }

    public var onStateChanged: (@Sendable () -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onStateChanged
        }
        set {
            stateLock.lock()
            _onStateChanged = newValue
            stateLock.unlock()
        }
    }

    public init(
        socketPath: String = UseMacDefaults.defaultSocketPath,
        extensionPort: UInt16 = UseMacDefaults.defaultExtensionPort,
        bridgeKeyDirectory: URL? = nil,
        auditStore: AuditLogStore? = nil,
        skillStore: SkillStore = SkillStore()
    ) {
        self.socketPath = socketPath
        self.localVision = LocalVisionEngine()
        self.skillStore = skillStore
        self.auditStore = auditStore
        self.auditEntries = auditStore?.recentEntries() ?? []
        let pairingStore = bridgeKeyDirectory.map { BridgePairingStore(directory: $0) } ?? BridgePairingStore()
        self.chromeBridge = ChromeExtensionBridge(port: extensionPort, pairingStore: pairingStore)
        self.actionExecutor = ActionExecutor(
            axIndexer: axIndexer,
            workspaceMonitor: workspaceMonitor,
            killSwitch: killSwitch
        )
        // Stop in the pill on a controlled Chrome tab. The app replaces this with its emergency stop (AppState).
        self.chromeBridge.onUserStopRequested = { [weak self] _, _ in
            self?.tripKillSwitch(true)
        }
        self.chromeBridge.onProfilesChanged = { [weak self] _ in
            self?.notifyStateChanged()
        }
        self.chromeBridge.onPairingStateChanged = { [weak self] in
            self?.notifyStateChanged()
        }
        self.chromeBridge.onTabStreamEnded = { [weak self] profile, tabId, reason in
            self?.tabStreamEnded(profile: profile, tabId: tabId, reason: reason)
        }
    }

    /// Runs one request. `handle` (UseMacEngineService+Tasks.swift) ties it to its task first; this sets the
    /// request audit entries read to name its task and to scrub what it typed.
    func handleRequest(_ request: RPCRequest) async -> RPCResponse {
        await AuditRequestContext.$request.withValue(request) {
            await handleRequestBody(request)
        }
    }

    private func handleRequestBody(_ request: RPCRequest) async -> RPCResponse {
        let startNs = DispatchTime.now().uptimeNanoseconds
        incrementRequestCount()
        scheduleCapturePruneIfNeeded()

        let response: RPCResponse

        switch request.method {
        case .ping:
            let latencyMs = elapsedMs(since: startNs)
            response = .success(id: request.id, latencyMs: latencyMs, pong: "pong")

        case .status:
            let status = currentStatus()
            let latencyMs = elapsedMs(since: startNs)
            response = .success(id: request.id, latencyMs: latencyMs, status: status)

        case .listApps:
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: nil,
                    activityTitle: "List apps blocked",
                    reason: blockReason
                )
                break
            }
            let apps = TargetRulesStore.shared.rules.visibleApps(listRunningApps())
            let latencyMs = elapsedMs(since: startNs)
            response = .success(id: request.id, latencyMs: latencyMs, apps: apps)

        case .observe:
            let params = request.observe ?? ObserveParams()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.app,
                    activityTitle: "Observe blocked",
                    reason: blockReason
                )
                break
            }
            let observeTarget = workspaceMonitor.resolveTarget(query: params.app)
            if observeTarget == .useMac {
                response = selfTargetResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "Observe blocked")
                break
            }
            if case .app(let app) = observeTarget, let blocked = TargetRulesStore.shared.blockedMessage(for: app) {
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "Observe blocked", message: blocked)
                break
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
                response = .failure(
                    id: request.id,
                    code: "APP_NOT_FOUND",
                    message: "No matching target application found",
                    latencyMs: latencyMs
                )
                break
            }

            // `window` pins the observed (and later acted-on) window; observing without it goes back to focus.
            WindowResolver.pin(pid: resolvedObserveApp.pid, title: params.window)
            if let wanted = params.window?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty,
               WindowResolver.window(pid: resolvedObserveApp.pid, titleContains: wanted) == nil {
                WindowResolver.pin(pid: resolvedObserveApp.pid, title: nil)
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(
                    id: request.id,
                    code: "ELEMENT_NOT_FOUND",
                    message: "No \(resolvedObserveApp.name) window has a title containing \"\(wanted)\".",
                    latencyMs: latencyMs
                )
                break
            }
            let app = WorkspaceMonitor.withTargetWindow(resolvedObserveApp)

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
                let shotReq = ScreenshotRequest(
                    app: params.app,
                    includeBase64: params.returnImageContent ?? false
                )
                async let axTask: WindowSnapshot = Task.detached(priority: .userInitiated) {
                    axIndexer.observe(
                        app: app,
                        maxDepth: maxDepth,
                        maxElements: maxElements,
                        useCache: useCache,
                        includeDiff: includeDiff,
                        accessibilityGranted: perms.accessibilityGranted,
                        includeOffscreen: includeOffscreen
                    )
                }.value
                async let shotTask: ScreenshotResult? = try? screenCapturer.capture(shotReq, targetApp: app)
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

            // Automatic AX + OCR `@vN` fusion for AX-blind Electron/Canvas/PDF windows.
            if snapshot.elements.count < 5,
               perms.screenRecordingGranted,
               let bounds = snapshot.app.windowBounds,
               bounds.width > 300,
               bounds.height > 200 {
                let ocrNodes = await fuseOCRElements(
                    app: app,
                    windowBounds: bounds,
                    existingScreenshotPath: capturedShot?.path
                )
                if !ocrNodes.isEmpty {
                    snapshot.elements.append(contentsOf: ocrNodes)
                    storeOCRNodes(ocrNodes, pid: app.pid)
                }
            }

            if let filter = params.filter {
                snapshot.elements = Self.filterElements(
                    snapshot.elements,
                    filter: filter,
                    viewport: snapshot.app.windowBounds
                )
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
                targetGuessed: workspaceMonitor.isGuessedTarget(requestApp: params.app) ? true : nil
            ))
            response = .success(id: request.id, latencyMs: latencyMs, snapshot: snapshot, screenshot: capturedShot)

        case .act:
            guard let actReq = request.act else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing act payload", latencyMs: latencyMs)
                break
            }

            // Refuse the whole batch up front, like browser_act, so a blocked request always answers POLICY_BLOCKED.
            let actHasSensitive = actReq.steps.contains { isSensitiveStepForPolicy($0) }
            let actHasMutating = actReq.steps.contains { isMutatingStepForPolicy($0) }
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: actHasSensitive, isMutatingAction: actHasMutating) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: actReq.app,
                    activityTitle: "Action blocked",
                    reason: blockReason
                )
                break
            }

            if workspaceMonitor.namesUseMac(actReq.app) || actReq.steps.contains(where: { workspaceMonitor.namesUseMac($0.app) }) {
                response = selfTargetResponse(request: request, startNs: startNs, targetApp: actReq.app, activityTitle: "Action blocked")
                break
            }
            if let blocked = TargetRulesStore.shared.blockedMessage(forQueries: [actReq.app] + actReq.steps.map(\.app), in: workspaceMonitor) {
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: actReq.app, activityTitle: "Action blocked", message: blocked)
                break
            }

            let overlay = onOverlayEvent
            // Work on a guessed target (no app named, none paired: the app in front) is marked so the live preview
            // never shows the user's own app.
            let targetGuessed = workspaceMonitor.isGuessedTarget(requestApp: actReq.app, stepApps: actReq.steps.map(\.app))
            let liveActivity: (@Sendable (LiveActivityItem) -> Void)?
            if targetGuessed, let forward = onLiveActivity {
                liveActivity = { item in
                    var marked = item
                    marked.targetGuessed = true
                    forward(marked)
                }
            } else {
                liveActivity = onLiveActivity
            }
            if let refusal = await approvalRefusal(for: request, startNs: startNs) {
                response = refusal
                break
            }

            // Resolve any `@vN` OCR-fused element references to their global frame centers so native act can click them.
            let preResolvedApp = workspaceMonitor.resolveApp(query: actReq.app)
            let effectiveActReq = resolveOCRElementTargets(in: actReq, pid: preResolvedApp?.pid)

            let actPerms = currentPermissions(promptAccessibility: false)
            let beforeNativeCG: CGImage? = {
                nil
            }()
            var capturedBeforeCG = beforeNativeCG
            if actReq.diffCrop == true, actPerms.screenRecordingGranted, let preApp = preResolvedApp {
                capturedBeforeCG = await screenCapturer.capturePreviewCGImage(targetApp: preApp, maxDimension: 1280)?.image
            }

            let (actResult, resolvedApp) = await actionExecutor.executeBatch(
                effectiveActReq,
                onOverlayEvent: overlay,
                onLiveActivity: liveActivity
            )
            incrementActionCount(by: actResult.stepResults.count)

            let targetApp = resolvedApp ?? preResolvedApp ?? workspaceMonitor.resolveApp(query: actReq.app)
            let shouldObserve = actReq.returnObservation && actReq.observationMode != ObservationMode.none
            var observation: WindowSnapshot?
            var actionScreenshot: ScreenshotResult?
            var actionDirtyRect: ScreenRect?
            var actionVisualDeltaOCR: String?
            var afterNativeJPEG: Data?

            if shouldObserve, let targetApp {
                var snap = axIndexer.observe(
                    app: targetApp,
                    maxElements: actReq.maxElements ?? 220,
                    useCache: false,
                    includeDiff: true,
                    accessibilityGranted: actPerms.accessibilityGranted,
                    includeOffscreen: false
                )
                let useDiffOnly: Bool = {
                    if actReq.returnDiffOnly || actReq.observationMode == .delta {
                        return snap.diff != nil
                    }
                    if actReq.observationMode == .auto, let diff = snap.diff {
                        let changed = diff.added.count + diff.changed.count + diff.removedIds.count
                        return changed < max(1, Int(Double(max(1, snap.elements.count)) * 0.4))
                    }
                    return false
                }()
                if useDiffOnly {
                    snap.elements = []
                }
                observation = snap
            }

            let wantsNativeShot = (actReq.includeScreenshot || actReq.diffCrop == true || actReq.returnImageContent == true)
                && actPerms.screenRecordingGranted
            if wantsNativeShot, let targetApp {
                let shotReq = ScreenshotRequest(
                    app: actReq.app,
                    includeBase64: actReq.returnImageContent ?? false
                )
                if let shot = try? await screenCapturer.capture(shotReq, targetApp: targetApp) {
                    var finalShot = shot
                    let fullData = try? Data(contentsOf: URL(fileURLWithPath: shot.path))
                    afterNativeJPEG = fullData
                    let targetKey = "native:\(targetApp.pid)"
                    if actReq.diffCrop == true, let fullData {
                        let dirty: DirtyRegionResult?
                        if let beforeCG = capturedBeforeCG, let afterCG = LocalVisionEngine.decodeCGImage(fromJPEG: fullData) {
                            dirty = LocalVisionEngine.computeDirtyRegion(before: beforeCG, after: afterCG)
                        } else if let prevData = cachedScreenshotJPEG(forKey: targetKey) {
                            dirty = LocalVisionEngine.computeDirtyRegion(beforeJPEG: prevData, afterJPEG: fullData)
                        } else {
                            dirty = nil
                        }
                        storeScreenshotJPEG(fullData, forKey: targetKey)
                        if let dirty, let rect = dirty.dirtyRect {
                            actionDirtyRect = rect
                            if let cropped = saveCroppedJPEG(
                                fromJPEG: fullData,
                                rect: rect,
                                padding: 24,
                                maxDimension: 1024,
                                quality: 0.80,
                                includeBase64: actReq.returnImageContent ?? false,
                                latencyMs: shot.latencyMs
                            ) {
                                finalShot = cropped
                            }
                            let ocr = await Task.detached(priority: .userInitiated) {
                                LocalVisionEngine.recognizeText(inJPEG: fullData, region: rect, fast: true)
                            }.value
                            if !ocr.text.isEmpty {
                                actionVisualDeltaOCR = ocr.text
                            }
                        }
                    } else if let fullData {
                        storeScreenshotJPEG(fullData, forKey: targetKey)
                    }
                    actionScreenshot = finalShot
                    observation?.screenshotPath = finalShot.path
                }
            }

            var visualVerification: VisionQueryResult?
            var agentFeedback: AgentFeedback?
            if let verifyPrompt = actReq.verify?.trimmingCharacters(in: .whitespacesAndNewlines), !verifyPrompt.isEmpty {
                let verifyRes = await runTieredVerify(
                    assertion: verifyPrompt,
                    snapshot: observation,
                    visionParams: VisionQueryParams(
                        mode: "verify",
                        query: verifyPrompt,
                        app: targetApp?.name ?? actReq.app
                    ),
                    inMemoryJPEG: afterNativeJPEG,
                    viewportWidth: targetApp?.windowBounds?.width,
                    viewportHeight: targetApp?.windowBounds?.height
                )
                visualVerification = verifyRes
                if let vr = verifyRes, vr.verified == false {
                    agentFeedback = AgentFeedback(
                        severity: "warning",
                        trigger: "visual_verify_failed",
                        diagnosis: vr.answer,
                        suggestedAction: "Inspect the local verification result or call observe/vision_query before retrying.",
                        source: vr.backend,
                        latencyMs: vr.latencyMs
                    )
                }
            }

            let finalResult = BatchActionResult(
                success: actResult.success,
                totalLatencyMs: actResult.totalLatencyMs,
                stepResults: actResult.stepResults,
                observation: observation,
                agentFeedback: agentFeedback,
                visualVerification: visualVerification,
                screenshot: actionScreenshot,
                dirtyRect: actionDirtyRect,
                visualDeltaOCR: actionVisualDeltaOCR
            )
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(
                method: request.method.rawValue,
                targetApp: targetApp?.name ?? actReq.app,
                summary: "Executed \(actResult.stepResults.count) step(s): \(actResult.success ? "ok" : "failed") · \(AuditRedactor.describeSteps(actReq.steps))",
                latencyMs: latencyMs,
                success: actResult.success
            )
            let activityApp = observation?.app ?? targetApp
            let rawDiff = observation?.diff?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let completeSubtitle = (rawDiff?.isEmpty == false) ? rawDiff : nil
            // A failed batch names its failed step and why, in plain words (ActivityCaption).
            let failure = actResult.success ? nil : ActivityCaption.batchFailure(
                steps: actReq.steps,
                results: actResult.stepResults,
                elementName: { [axIndexer] id in activityApp.flatMap { axIndexer.node(for: id, pid: $0.pid) }?.title ?? axIndexer.node(for: id)?.node.title }
            )
            emitLiveActivity(LiveActivityItem(
                kind: .actionComplete,
                appName: activityApp?.name,
                appPid: activityApp?.pid,
                bundleId: activityApp?.bundleId,
                windowTitle: activityApp?.windowTitle,
                windowBounds: activityApp?.windowBounds,
                title: failure?.title
                    ?? "Finished \(actResult.stepResults.count) step\(actResult.stepResults.count == 1 ? "" : "s")",
                subtitle: failure.map { $0.reason } ?? completeSubtitle,
                latencyMs: actResult.totalLatencyMs,
                success: actResult.success,
                isInProgress: false,
                targetGuessed: targetGuessed ? true : nil
            ))
            response = .success(id: request.id, latencyMs: latencyMs, snapshot: observation, actionResult: finalResult, screenshot: actionScreenshot)

        case .screenshot:
            let req = request.screenshot ?? ScreenshotRequest()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: req.app,
                    activityTitle: "Screenshot blocked",
                    reason: blockReason
                )
                break
            }
            // A whole-display capture (no app) is a read and may show UseMac; a capture of UseMac itself is not.
            let screenshotTarget = workspaceMonitor.resolveTarget(query: req.app)
            if screenshotTarget == .useMac {
                response = selfTargetResponse(request: request, startNs: startNs, targetApp: req.app, activityTitle: "Screenshot blocked")
                break
            }
            if case .app(let app) = screenshotTarget, let blocked = TargetRulesStore.shared.blockedMessage(for: app) {
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "Screenshot blocked", message: blocked)
                break
            }
            guard permissionManager.isScreenRecordingGranted() else {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: req.app, summary: "Screen Recording permission denied", latencyMs: latencyMs, success: false)
                response = .failure(
                    id: request.id,
                    code: "PERMISSION_DENIED",
                    message: "Screen Recording permission not granted",
                    latencyMs: latencyMs
                )
                break
            }

            var targetApp: AppDescriptor?
            if case .app(let app) = screenshotTarget {
                targetApp = app
            }
            do {
                let rawResult = try await screenCapturer.capture(req, targetApp: targetApp)
                let targetKey = targetApp.map { "native:\($0.pid)" } ?? "native:display"
                var result = rawResult
                if let rawData = try? Data(contentsOf: URL(fileURLWithPath: rawResult.path)) {
                    let cropped = applyRegionOrDiffCrop(
                        jpegData: rawData,
                        original: rawResult,
                        targetKey: targetKey,
                        region: req.region,
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
                    targetGuessed: workspaceMonitor.isGuessedTarget(requestApp: req.app) ? true : nil
                ))
                response = .success(id: request.id, latencyMs: latencyMs, screenshot: result)
            } catch {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: targetApp?.name, summary: error.localizedDescription, latencyMs: latencyMs, success: false)
                response = .failure(
                    id: request.id,
                    code: "CAPTURE_FAILED",
                    message: error.localizedDescription,
                    latencyMs: latencyMs
                )
            }

        case .setPolicy:
            guard let policy = request.policy else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing policy", latencyMs: latencyMs)
                break
            }
            if let currentPolicy = killSwitch.tightenPolicy(to: policy) {
                let latencyMs = elapsedMs(since: startNs)
                let message = "Execution mode can only be relaxed from the UseMac app (Settings → Safety)."
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: nil,
                    summary: "Blocked policy relaxation from \(currentPolicy.rawValue) to \(policy.rawValue)",
                    latencyMs: latencyMs,
                    success: false
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .policyOrSafety,
                    title: "Policy relaxation blocked",
                    subtitle: message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: "POLICY_LOCKED", message: message, latencyMs: latencyMs, hint: ExecutionModeNotice.relaxHint(current: currentPolicy))
                break
            }
            emitLiveActivity(LiveActivityItem(
                kind: .policyOrSafety,
                title: "Policy set to \(policy.rawValue)",
                success: true,
                isInProgress: false
            ))
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: nil, summary: "Policy set to \(policy.rawValue)", latencyMs: latencyMs, success: true)
            response = .success(id: request.id, latencyMs: latencyMs, status: currentStatus())

        case .pairApp:
            let query = request.appTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: query,
                    activityTitle: "Pair app blocked",
                    reason: blockReason
                )
                break
            }
            if workspaceMonitor.namesUseMac(query) {
                response = selfTargetResponse(request: request, startNs: startNs, targetApp: query, activityTitle: "Pair app blocked")
                break
            }
            if let blocked = TargetRulesStore.shared.blockedMessage(forQueries: [query], in: workspaceMonitor) {
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: query, activityTitle: "Pair app blocked", message: blocked)
                break
            }
            let paired = setPairedApp(query)
            let latencyMs = elapsedMs(since: startNs)
            if let query, !query.isEmpty, paired == nil {
                appendAudit(method: request.method.rawValue, targetApp: query, summary: "Pair failed: app not found", latencyMs: latencyMs, success: false)
                response = .failure(id: request.id, code: "APP_NOT_FOUND", message: "No matching app for '\(query)'", latencyMs: latencyMs)
            } else {
                appendAudit(method: request.method.rawValue, targetApp: paired?.name, summary: paired.map { "Paired with \($0.name)" } ?? "Cleared paired app", latencyMs: latencyMs, success: true)
                response = .success(id: request.id, latencyMs: latencyMs, status: currentStatus())
            }

        case .auditLog:
            let entries = auditLog(request.auditLog)
            let latencyMs = elapsedMs(since: startNs)
            response = .success(id: request.id, latencyMs: latencyMs, auditEntries: entries)

        case .highlight:
            guard let elementId = request.elementId, !elementId.isEmpty else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing elementId", latencyMs: latencyMs)
                break
            }
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: nil,
                    activityTitle: "Highlight blocked",
                    reason: blockReason
                )
                break
            }
            let durationMs = request.durationMs ?? 1500
            if let rect = highlightCachedElement(elementId, durationMs: durationMs) {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: nil, summary: "Highlighted \(elementId) at (\(Int(rect.x)),\(Int(rect.y)))", latencyMs: latencyMs, success: true)
                emitLiveActivity(LiveActivityItem(
                    kind: .highlight,
                    title: "Highlighted \(elementId)",
                    elementId: elementId,
                    elementFrame: rect,
                    latencyMs: latencyMs,
                    success: true,
                    isInProgress: false
                ))
                response = .success(id: request.id, latencyMs: latencyMs)
            } else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "ELEMENT_NOT_FOUND", message: "Cached element \(elementId) not found", latencyMs: latencyMs)
            }

        case .browserStatus:
            let profiles = chromeBridge.connectedProfiles()
            let latencyMs = elapsedMs(since: startNs)
            response = .success(
                id: request.id,
                latencyMs: latencyMs,
                status: currentStatus(),
                browserProfiles: profiles
            )

        case .browserReloadExtension:
            let params = request.browserReloadExtension ?? BrowserReloadExtensionParams()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Extension reload blocked",
                    reason: blockReason
                )
                break
            }
            let outcome = await chromeBridge.reloadExtension(profile: params.profile, force: params.force ?? false)
            let latencyMs = elapsedMs(since: startNs)
            let summary = outcome.ok
                ? "Reloaded the Chrome extension: " + outcome.profiles.map { "\($0.profileName) v\($0.extensionVersion)" }.joined(separator: ", ")
                : (outcome.error?.message ?? "Extension reload failed")
            appendAudit(method: request.method.rawValue, targetApp: "Chrome (\(params.profile ?? "all profiles"))", summary: summary, latencyMs: latencyMs, success: outcome.ok)
            if outcome.ok {
                response = .success(id: request.id, latencyMs: latencyMs, browserProfiles: outcome.profiles)
            } else {
                response = .failure(
                    id: request.id,
                    code: outcome.error?.code ?? "EXTENSION_ERROR",
                    message: outcome.error?.message ?? "Extension reload failed",
                    latencyMs: latencyMs
                )
            }

        case .browserTabs:
            let params = request.browserTabs ?? BrowserTabsParams()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Browser tabs blocked",
                    reason: blockReason
                )
                break
            }
            let bridgeResp = await chromeBridge.tabs(params)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            if bridgeResp.ok {
                let tabs = bridgeResp.tabs ?? []
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: "Chrome (\(resolvedProfile))",
                    summary: "Listed \(tabs.count) tab(s)",
                    latencyMs: latencyMs,
                    success: true
                )
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    browserTabs: tabs,
                    browserTabId: bridgeResp.tabId
                )
            } else {
                let code = bridgeResp.error?.code ?? "BROWSER_TABS_FAILED"
                let message = bridgeResp.error?.message ?? "Failed to list Chrome tabs"
                appendAudit(method: request.method.rawValue, targetApp: "Chrome (\(resolvedProfile))", summary: message, latencyMs: latencyMs, success: false)
                response = .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }

        case .browserOpen:
            guard var params = request.browserOpen else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing browserOpen payload", latencyMs: latencyMs)
                break
            }

            // With a tabId and activate, an empty url means "only make this tab active" (no navigation).
            let activateOnly = params.activate == true && params.tabId != nil
                && params.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let urlValidation: Result<String, NavigationPolicy.BlockedURL> = activateOnly
                ? .success("")
                : NavigationPolicy.validate(params.url)
            if case .failure(let blocked) = urlValidation {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "URL blocked: \(blocked.message)", latencyMs: latencyMs, success: false)
                emitLiveActivity(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: "Chrome (\(params.profile ?? "Browser"))",
                    title: "Browser open URL blocked",
                    subtitle: blocked.message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: "URL_BLOCKED", message: blocked.message, latencyMs: latencyMs)
                break
            }
            if case .success(let normalizedURL) = urlValidation {
                params.url = normalizedURL
            }

            // Govern any inline `steps` on browser_open identically to browser_act.
            let inlineOpenSteps = params.steps ?? []
            if !inlineOpenSteps.isEmpty {
                if let invalid = BrowserStepValidation.targetlessSetValueMessage(in: inlineOpenSteps) {
                    let latencyMs = elapsedMs(since: startNs)
                    appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: invalid, latencyMs: latencyMs, success: false)
                    response = .failure(id: request.id, code: "INVALID_REQUEST", message: invalid, latencyMs: latencyMs)
                    break
                }
                var stepUrlErr: String?
                var normalizedSteps = inlineOpenSteps
                for idx in normalizedSteps.indices where normalizedSteps[idx].action == .openURL || normalizedSteps[idx].action == .navigate {
                    switch NavigationPolicy.validate(normalizedSteps[idx].url ?? normalizedSteps[idx].text) {
                    case .success(let normalized):
                        normalizedSteps[idx].url = normalized
                    case .failure(let err):
                        stepUrlErr = err.message
                    }
                    if stepUrlErr != nil { break }
                }
                if let stepUrlErr {
                    let latencyMs = elapsedMs(since: startNs)
                    appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "URL blocked: \(stepUrlErr)", latencyMs: latencyMs, success: false)
                    response = .failure(id: request.id, code: "URL_BLOCKED", message: stepUrlErr, latencyMs: latencyMs)
                    break
                }
                var uploadErr: String?
                for idx in normalizedSteps.indices where normalizedSteps[idx].action == .uploadFile {
                    switch ActionExecutor.validateAndNormalizeUploadFiles(normalizedSteps[idx].files) {
                    case .success(let canonical):
                        normalizedSteps[idx].files = canonical
                    case .failure(let err):
                        uploadErr = err.message
                    }
                    if uploadErr != nil { break }
                }
                if let uploadErr {
                    let latencyMs = elapsedMs(since: startNs)
                    appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "Upload blocked: \(uploadErr)", latencyMs: latencyMs, success: false)
                    response = .failure(id: request.id, code: "UPLOAD_BLOCKED", message: uploadErr, latencyMs: latencyMs)
                    break
                }
                params.steps = normalizedSteps
            }

            let openHasSensitive = (params.steps ?? []).contains { isSensitiveStepForPolicy($0) }
            let openHasMutating = (params.steps ?? []).contains { isMutatingStepForPolicy($0) }
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: openHasSensitive, isMutatingAction: openHasMutating) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Browser open blocked",
                    reason: blockReason
                )
                break
            }

            if openHasSensitive, let steps = params.steps {
                let syntheticAct = RPCRequest(
                    id: request.id,
                    method: .browserAct,
                    browserAct: BrowserActParams(profile: params.profile, tabId: params.tabId, steps: steps),
                    taskId: request.namedTaskId
                )
                if let refusal = await approvalRefusal(for: syntheticAct, startNs: startNs, browserAct: syntheticAct.browserAct) {
                    response = refusal
                    break
                }
            }

            let targetProfile = params.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            let targetLabel = "Chrome (\(targetProfile))"
            emitLiveActivity(LiveActivityItem(
                kind: .actionStart,
                appName: targetLabel,
                title: "Opening \(params.url)",
                isInProgress: true,
                browserTabId: nil,
                browserProfile: targetProfile
            ))

            let bridgeResp = await chromeBridge.open(params)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            let resolvedLabel = "Chrome (\(resolvedProfile))"
            if bridgeResp.ok {
                // A tab UseMac created belongs to the request's task, so another task finishing never closes it.
                if params.tabId == nil, let openedTabId = bridgeResp.tabId {
                    taskTabs.recordOpenedTab(openedTabId, taskId: request.namedTaskId, profile: params.profile)
                }
                if let stepCount = bridgeResp.actionResult?.stepResults.count, stepCount > 0 {
                    incrementActionCount(by: stepCount)
                }
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: resolvedLabel,
                    summary: "Opened \(bridgeResp.url ?? params.url)",
                    latencyMs: latencyMs,
                    success: true
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: resolvedLabel,
                    windowTitle: bridgeResp.title,
                    title: "Opened \(bridgeResp.title ?? params.url)",
                    subtitle: bridgeResp.url,
                    latencyMs: latencyMs,
                    success: true,
                    isInProgress: false,
                    browserTabId: bridgeResp.tabId,
                    browserProfile: resolvedProfile
                ))
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    snapshot: bridgeResp.snapshot ?? bridgeResp.actionResult?.observation,
                    actionResult: bridgeResp.actionResult,
                    screenshot: bridgeResp.screenshot,
                    browserTabId: bridgeResp.tabId,
                    browserUrl: bridgeResp.url,
                    browserTitle: bridgeResp.title
                )
            } else {
                let code = bridgeResp.error?.code ?? "BROWSER_OPEN_FAILED"
                let message = bridgeResp.error?.message ?? "Failed to open URL in Chrome"
                appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: resolvedLabel,
                    title: ActivityCaption.hostOrText(params.url).map { "Couldn't open \($0)" } ?? "Couldn't open the page",
                    subtitle: ActivityCaption.reason(errorCode: code, message: message, inBrowser: true) ?? message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }

        case .browserObserve:
            let params = request.browserObserve ?? BrowserObserveParams()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Browser observe blocked",
                    reason: blockReason
                )
                break
            }
            let bridgeResp = await chromeBridge.observe(params)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            let resolvedLabel = "Chrome (\(resolvedProfile))"

            if bridgeResp.ok, var snapshot = bridgeResp.snapshot {
                recordObserveMetrics(latencyMs: snapshot.latencyMs, fromHotCache: false)
                if let overlay = snapshot.pageState?.blockingOverlay {
                    snapshot.agentFeedback = AgentFeedback(
                        severity: overlay.blocksScroll ? "blocked" : "warning",
                        trigger: "blocking_overlay",
                        diagnosis: "Overlay detected on page: \"\(overlay.summary)\"",
                        suggestedAction: overlay.closeElementId != nil || (overlay.closeX != nil && overlay.closeY != nil)
                            ? "Dismiss the overlay before interacting with the page."
                            : "Press Escape or call vision_query(mode: 'diagnose') to locate the close button.",
                        suggestedX: overlay.closeX,
                        suggestedY: overlay.closeY,
                        suggestedElementId: overlay.closeElementId,
                        source: "dom-overlay",
                        latencyMs: snapshot.latencyMs
                    )
                }
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: resolvedLabel,
                    summary: "Observed \(snapshot.elements.count) DOM elements",
                    latencyMs: latencyMs,
                    success: true
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .observe,
                    appName: resolvedLabel,
                    windowTitle: bridgeResp.title ?? snapshot.app.windowTitle,
                    windowBounds: snapshot.app.windowBounds,
                    title: "Observed \(snapshot.elements.count) elements",
                    subtitle: "chrome-dom",
                    mechanism: "chrome-dom",
                    latencyMs: snapshot.latencyMs,
                    success: true,
                    isInProgress: false,
                    browserTabId: bridgeResp.tabId ?? params.tabId,
                    browserProfile: resolvedProfile
                ))
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    snapshot: snapshot,
                    screenshot: bridgeResp.screenshot,
                    browserTabId: bridgeResp.tabId,
                    browserUrl: bridgeResp.url,
                    browserTitle: bridgeResp.title
                )
            } else {
                let code = bridgeResp.error?.code ?? "BROWSER_OBSERVE_FAILED"
                let message = bridgeResp.error?.message ?? "Failed to observe browser tab"
                appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
                emitLiveActivity(LiveActivityItem(
                    kind: .observe,
                    appName: resolvedLabel,
                    title: "Couldn't read the page",
                    subtitle: ActivityCaption.reason(errorCode: code, message: message, inBrowser: true) ?? message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }

        case .browserExtract:
            let params = request.browserExtract ?? BrowserExtractParams()
            let normalizedMode = params.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isEvalMode = (normalizedMode == "eval")
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: isEvalMode, isMutatingAction: isEvalMode) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: isEvalMode ? "Browser eval blocked" : "Browser extract blocked",
                    reason: blockReason
                )
                break
            }
            if let refusal = await approvalRefusal(for: request, startNs: startNs) {
                response = refusal
                break
            }
            let bridgeResp = await chromeBridge.extract(params)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            let resolvedLabel = "Chrome (\(resolvedProfile))"

            if bridgeResp.ok, let extracted = bridgeResp.extractResult {
                let auditSummary: String
                if isEvalMode {
                    auditSummary = AuditRedactor.evalSummary(params.expression ?? "")
                } else {
                    auditSummary = "Extracted \(extracted.mode) (\(extracted.rowCount ?? 0) rows, \(extracted.columnCount ?? 0) cols)"
                }
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: resolvedLabel,
                    summary: auditSummary,
                    latencyMs: latencyMs,
                    success: true
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .observe,
                    appName: resolvedLabel,
                    windowTitle: bridgeResp.title ?? extracted.title,
                    title: "Extracted \(extracted.mode) data",
                    subtitle: extracted.rowCount.map { "\($0) rows · \(extracted.columnCount ?? 0) cols" } ?? "chrome-extract",
                    mechanism: "chrome-extract",
                    latencyMs: extracted.latencyMs,
                    success: true,
                    isInProgress: false,
                    browserTabId: bridgeResp.tabId ?? params.tabId,
                    browserProfile: resolvedProfile
                ))
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    browserExtract: extracted,
                    browserTabId: bridgeResp.tabId ?? extracted.tabId,
                    browserUrl: bridgeResp.url ?? extracted.url,
                    browserTitle: bridgeResp.title ?? extracted.title
                )
            } else {
                let code = bridgeResp.error?.code ?? "BROWSER_EXTRACT_FAILED"
                let message = bridgeResp.error?.message ?? "Failed to extract browser data"
                appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
                response = .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }

        case .browserScreenshot:
            let params = request.browserScreenshot ?? BrowserScreenshotParams()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Browser screenshot blocked",
                    reason: blockReason
                )
                break
            }
            let beforeShotFrame = (params.diffCrop == true)
                ? chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId)
                : nil
            let bridgeResp = await chromeBridge.screenshot(params)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            let resolvedLabel = "Chrome (\(resolvedProfile))"

            if bridgeResp.ok, let rawShot = bridgeResp.screenshot {
                var shot = rawShot
                let resolvedTabId = bridgeResp.tabId ?? params.tabId
                let targetKey = "browser:\(resolvedProfile.lowercased()):\(resolvedTabId ?? -1)"
                let rawData = rawShot.base64Data.flatMap { Data(base64Encoded: $0) }
                    ?? (try? Data(contentsOf: URL(fileURLWithPath: rawShot.path)))
                if let rawData {
                    if params.diffCrop == true, cachedScreenshotJPEG(forKey: targetKey) == nil, let beforeJPEG = beforeShotFrame?.jpegData {
                        storeScreenshotJPEG(beforeJPEG, forKey: targetKey)
                    }
                    let maxDim = max(params.viewportWidth ?? 1280, params.viewportHeight ?? 1280)
                    let quality = Double(params.quality ?? 84) / 100.0
                    let cropped = applyRegionOrDiffCrop(
                        jpegData: rawData,
                        original: rawShot,
                        targetKey: targetKey,
                        region: params.region,
                        diffCrop: params.diffCrop == true,
                        maxDimension: maxDim,
                        quality: quality,
                        includeBase64: params.returnImageContent != false
                    )
                    shot = cropped.screenshot
                }
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: resolvedLabel,
                    summary: "Captured browser \(shot.width)x\(shot.height) JPEG (\(shot.byteCount) bytes)",
                    latencyMs: latencyMs,
                    success: true
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .screenshot,
                    appName: resolvedLabel,
                    windowTitle: bridgeResp.title,
                    title: (params.selector != nil || params.elementId != nil) ? "Inspecting element" : "Inspecting page",
                    subtitle: "\(shot.width)×\(shot.height) · \(max(1, shot.byteCount / 1024)) KB",
                    latencyMs: shot.latencyMs,
                    success: true,
                    isInProgress: false,
                    browserTabId: bridgeResp.tabId ?? params.tabId,
                    browserProfile: resolvedProfile
                ))
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    screenshot: shot,
                    browserTabId: bridgeResp.tabId,
                    browserUrl: bridgeResp.url,
                    browserTitle: bridgeResp.title
                )
            } else {
                let code = bridgeResp.error?.code ?? "BROWSER_SCREENSHOT_FAILED"
                let message = bridgeResp.error?.message ?? "Failed to capture browser screenshot"
                appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
                response = .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }

        case .browserAct:
            guard var params = request.browserAct else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing browserAct payload", latencyMs: latencyMs)
                break
            }
            // A setValue with no field would type into whatever has focus in the page: refuse it before anything else.
            if let invalid = BrowserStepValidation.targetlessSetValueMessage(in: params.steps) {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: invalid, latencyMs: latencyMs, success: false)
                response = .failure(id: request.id, code: "INVALID_REQUEST", message: invalid, latencyMs: latencyMs)
                break
            }

            var urlValidationError: String?
            for idx in params.steps.indices where params.steps[idx].action == .openURL || params.steps[idx].action == .navigate {
                switch NavigationPolicy.validate(params.steps[idx].url ?? params.steps[idx].text) {
                case .success(let normalizedURL):
                    params.steps[idx].url = normalizedURL
                case .failure(let err):
                    urlValidationError = err.message
                }
                if urlValidationError != nil { break }
            }
            if let urlErr = urlValidationError {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "URL blocked: \(urlErr)", latencyMs: latencyMs, success: false)
                emitLiveActivity(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: "Chrome (\(params.profile ?? "Browser"))",
                    title: "Browser URL blocked",
                    subtitle: urlErr,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: "URL_BLOCKED", message: urlErr, latencyMs: latencyMs)
                break
            }

            let hasSensitive = params.steps.contains { isSensitiveStepForPolicy($0) }
            let hasMutating = params.steps.contains { isMutatingStepForPolicy($0) }
            var blockReason = killSwitch.isBlocked(forSensitiveAction: hasSensitive, isMutatingAction: hasMutating)
            let readOnlyRequested = blockReason == nil && params.readOnly == true && hasMutating
            if readOnlyRequested {
                blockReason = "Mutating browser step blocked because readOnly=true was requested (only scroll, hover, wait, and target are permitted)."
            }
            if let blockReason {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Browser action blocked",
                    reason: blockReason,
                    readOnlyRequested: readOnlyRequested
                )
                break
            }

            // Validate & canonicalize local file paths before sending uploadFile steps to Chrome CDP
            var uploadValidationError: String?
            for idx in params.steps.indices where params.steps[idx].action == .uploadFile {
                switch ActionExecutor.validateAndNormalizeUploadFiles(params.steps[idx].files) {
                case .success(let canonicalPaths):
                    params.steps[idx].files = canonicalPaths
                case .failure(let err):
                    uploadValidationError = err.message
                }
                if uploadValidationError != nil { break }
            }
            if let uploadErr = uploadValidationError {
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(method: request.method.rawValue, targetApp: params.profile ?? "Chrome", summary: "Upload blocked: \(uploadErr)", latencyMs: latencyMs, success: false)
                emitLiveActivity(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: "Chrome (\(params.profile ?? "Browser"))",
                    title: "File upload blocked",
                    subtitle: uploadErr,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: "UPLOAD_BLOCKED", message: uploadErr, latencyMs: latencyMs)
                break
            }

            if let refusal = await approvalRefusal(for: request, startNs: startNs, browserAct: params) {
                response = refusal
                break
            }
            let targetProfile = params.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            let targetLabel = "Chrome (\(targetProfile))"
            emitLiveActivity(LiveActivityItem(
                kind: .actionStart,
                appName: targetLabel,
                title: "Running \(params.steps.count) browser step\(params.steps.count == 1 ? "" : "s")…",
                isInProgress: true,
                browserTabId: params.tabId,
                browserProfile: targetProfile
            ))

            let beforeFrame = chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId)
            let bridgeResp = await chromeBridge.act(params)
            let afterFrame = chromeBridge.latestFrame(profileQuery: bridgeResp.profileName ?? params.profile, tabId: bridgeResp.tabId ?? params.tabId)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            let resolvedLabel = "Chrome (\(resolvedProfile))"

            if bridgeResp.ok {
                var enrichedActionResult = bridgeResp.actionResult
                var responseScreenshot = bridgeResp.screenshot
                var noVisualEffectStep: ActionStepType?
                var noVisualEffectDiffPct: Double?
                var computedDirty: DirtyRegionResult?

                let resolvedTabId = bridgeResp.tabId ?? params.tabId
                let browserTargetKey = "browser:\(resolvedProfile.lowercased()):\(resolvedTabId ?? -1)"
                let afterShotJPEG: Data? = bridgeResp.screenshot?.base64Data.flatMap { Data(base64Encoded: $0) }
                    ?? (bridgeResp.screenshot.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0.path)) })
                let effectiveAfterJPEG = afterShotJPEG ?? afterFrame?.jpegData
                let effectiveBeforeJPEG: Data? = {
                    if let before = beforeFrame?.jpegData {
                        if afterShotJPEG != nil || beforeFrame?.capturedAt != afterFrame?.capturedAt {
                            return before
                        }
                    }
                    return cachedScreenshotJPEG(forKey: browserTargetKey)
                }()

                if let beforeJPEG = effectiveBeforeJPEG,
                   let afterJPEG = effectiveAfterJPEG {
                    let dirty = LocalVisionEngine.computeDirtyRegion(beforeJPEG: beforeJPEG, afterJPEG: afterJPEG)
                    computedDirty = dirty
                    let diffPct = dirty.overallDiffPercent

                    if var actionRes = enrichedActionResult {
                        if let dirtyRect = dirty.dirtyRect {
                            actionRes.dirtyRect = dirtyRect
                        }
                        if !actionRes.stepResults.isEmpty {
                            let lastActionIdx = actionRes.stepResults.lastIndex(where: { $0.action != .wait }) ?? (actionRes.stepResults.count - 1)
                            actionRes.stepResults[lastActionIdx].visualChangePercent = diffPct
                            let stepAction = actionRes.stepResults[lastActionIdx].action
                            let mechLower = actionRes.stepResults[lastActionIdx].mechanism.lowercased()
                            let isDownloadClick = mechLower.contains("download") || actionRes.stepResults[lastActionIdx].downloadPath != nil
                            // Only flag low visual diff on scroll, or no-effect click/key when BOTH DOM is unchanged AND max 16x10 tile diff < 0.8%.
                            let urlChanged = beforeFrame?.url != nil && afterFrame?.url != nil && beforeFrame?.url != afterFrame?.url
                            let domUnchanged: Bool = {
                                guard let diff = actionRes.observation?.diff else { return true }
                                return diff.added.isEmpty && diff.changed.isEmpty && diff.removedIds.isEmpty
                            }()
                            if diffPct < 1.2 && !isDownloadClick && !urlChanged && stepAction == .scroll && actionRes.stepResults[lastActionIdx].blockedWarning == nil {
                                actionRes.stepResults[lastActionIdx].blockedWarning = String(
                                    format: "Visual diff after %@ was only %.2f%% — screen barely changed (possible popup/overlay or scroll lock).",
                                    stepAction.rawValue,
                                    diffPct
                                )
                            } else if (stepAction == .click || stepAction == .doubleClick || stepAction == .pressKey),
                                      !isDownloadClick,
                                      !urlChanged,
                                      domUnchanged && dirty.maxTileDiffPercent < 0.8,
                                      actionRes.stepResults[lastActionIdx].blockedWarning == nil {
                                noVisualEffectStep = stepAction
                                noVisualEffectDiffPct = diffPct
                            }

                            // Fast <20 ms dirty-rect Apple Vision OCR delta when pixels changed locally without a DOM diff (e.g. canvas/toast).
                            if let dirtyRect = dirty.dirtyRect,
                               dirty.maxTileDiffPercent >= 0.8,
                               (domUnchanged || params.diffCrop == true) {
                                let deltaOCR = await Task.detached(priority: .userInitiated) {
                                    LocalVisionEngine.recognizeText(inJPEG: afterJPEG, region: dirtyRect, fast: true)
                                }.value
                                if !deltaOCR.text.isEmpty {
                                    actionRes.visualDeltaOCR = deltaOCR.text
                                }
                            }
                        }
                        enrichedActionResult = actionRes
                    }
                }
                if let effectiveAfterJPEG {
                    storeScreenshotJPEG(effectiveAfterJPEG, forKey: browserTargetKey)
                }

                // Wire `diffCrop: true` on browser_act: crop post-action JPEG to dirtyRect.
                if params.diffCrop == true,
                   let afterJPEG = effectiveAfterJPEG,
                   let dirtyRect = computedDirty?.dirtyRect {
                    if let croppedShot = saveCroppedJPEG(
                        fromJPEG: afterJPEG,
                        rect: dirtyRect,
                        padding: 24,
                        maxDimension: 1024,
                        quality: 0.80,
                        includeBase64: params.returnImageContent != false,
                        latencyMs: bridgeResp.screenshot?.latencyMs ?? 0
                    ) {
                        responseScreenshot = croppedShot
                        enrichedActionResult?.screenshot = croppedShot
                        enrichedActionResult?.observation?.screenshotPath = croppedShot.path
                    }
                }

                // Two-Way Auto-Visual Reflex: when a scroll stalls or an overlay blocks the page,
                // UseMac immediately diagnoses what happened locally (DOM + fast <20ms dirty-rect Apple Vision OCR) with zero disk I/O.
                if var actionRes = enrichedActionResult {
                    let blockedStep = actionRes.stepResults.last(where: { $0.blockedWarning != nil })
                    let domOverlay = actionRes.observation?.pageState?.blockingOverlay
                    if blockedStep != nil || domOverlay != nil {
                        if let overlay = domOverlay, (overlay.closeElementId != nil || (overlay.closeX != nil && overlay.closeY != nil)) {
                            actionRes.agentFeedback = AgentFeedback(
                                severity: "blocked",
                                trigger: blockedStep?.action == .scroll ? "scroll_blocked" : "blocking_overlay",
                                diagnosis: blockedStep?.blockedWarning ?? "Overlay blocking page: \"\(overlay.summary)\"",
                                suggestedAction: "Click the overlay close control, then retry your action.",
                                suggestedX: overlay.closeX,
                                suggestedY: overlay.closeY,
                                suggestedElementId: overlay.closeElementId,
                                source: "dom-overlay",
                                latencyMs: 0.2
                            )
                        } else if let afterJPEG = effectiveAfterJPEG {
                            let reflexStartNs = DispatchTime.now().uptimeNanoseconds
                            let vpW = Double(afterFrame?.viewportWidth ?? Int(actionRes.observation?.pageState?.viewportWidth ?? 1280))
                            let vpH = Double(afterFrame?.viewportHeight ?? Int(actionRes.observation?.pageState?.viewportHeight ?? 800))
                            let reflexRegion = computedDirty?.dirtyRect
                            let diag = await Task.detached(priority: .userInitiated) {
                                Self.diagnoseInMemoryWithAppleVision(
                                    jpegData: afterJPEG,
                                    dirtyRect: reflexRegion,
                                    viewportWidth: vpW,
                                    viewportHeight: vpH
                                )
                            }.value
                            let reflexMs = elapsedMs(since: reflexStartNs)
                            if actionRes.visualDeltaOCR == nil, !diag.deltaText.isEmpty {
                                actionRes.visualDeltaOCR = diag.deltaText
                            }
                            if diag.blockingDetected {
                                let suggestion: String
                                if let rx = diag.closeX, let ry = diag.closeY {
                                    suggestion = String(format: "Click the detected dismiss/close control at (%.1f, %.1f), then retry.", rx, ry)
                                } else {
                                    suggestion = "Check the validation error / disabled control or press Escape before retrying."
                                }
                                actionRes.agentFeedback = AgentFeedback(
                                    severity: "blocked",
                                    trigger: blockedStep?.action == .scroll
                                        ? "scroll_blocked"
                                        : (noVisualEffectStep != nil ? "action_no_visual_change" : "blocking_overlay"),
                                    diagnosis: "\(blockedStep?.blockedWarning ?? "") \(diag.summary)".trimmingCharacters(in: .whitespaces),
                                    suggestedAction: suggestion,
                                    suggestedX: diag.closeX,
                                    suggestedY: diag.closeY,
                                    source: "apple-vision-ocr",
                                    latencyMs: (reflexMs * 100).rounded() / 100
                                )
                            } else if let warn = blockedStep?.blockedWarning {
                                actionRes.agentFeedback = AgentFeedback(
                                    severity: "warning",
                                    trigger: "scroll_blocked",
                                    diagnosis: "\(warn) Apple Vision OCR saw no popup overlay.",
                                    suggestedAction: "Try scrolling inside a specific inner container or check if you reached the end of the page.",
                                    source: "apple-vision-ocr",
                                    latencyMs: (reflexMs * 100).rounded() / 100
                                )
                            } else if let noEff = noVisualEffectStep, !diag.summary.isEmpty {
                                actionRes.agentFeedback = AgentFeedback(
                                    severity: "info",
                                    trigger: "action_no_visual_change",
                                    diagnosis: String(format: "After %@ (visualDiff=%.2f%%), Apple Vision OCR reports: %@", noEff.rawValue, noVisualEffectDiffPct ?? 0, diag.summary),
                                    suggestedAction: "Use vision_query(mode: 'ask') if you need more visual detail without taking a full screenshot.",
                                    source: "apple-vision-ocr",
                                    latencyMs: (reflexMs * 100).rounded() / 100
                                )
                            }
                        }
                        enrichedActionResult = actionRes
                    }

                    // Tiered fast inline verification (`params.verify`): DOM text first (<1 ms), then negation-safe Apple Vision OCR (~20 ms).
                    if let verifyPrompt = params.verify?.trimmingCharacters(in: .whitespacesAndNewlines), !verifyPrompt.isEmpty {
                        let verifyRes = await runTieredVerify(
                            assertion: verifyPrompt,
                            snapshot: bridgeResp.snapshot ?? actionRes.observation,
                            visionParams: VisionQueryParams(
                                mode: "verify",
                                query: verifyPrompt,
                                profile: resolvedProfile,
                                tabId: resolvedTabId
                            ),
                            inMemoryJPEG: effectiveAfterJPEG,
                            viewportWidth: Double(afterFrame?.viewportWidth ?? Int(actionRes.observation?.pageState?.viewportWidth ?? 1280)),
                            viewportHeight: Double(afterFrame?.viewportHeight ?? Int(actionRes.observation?.pageState?.viewportHeight ?? 800))
                        )
                        if let vr = verifyRes {
                            actionRes.visualVerification = vr
                            if vr.verified == false && actionRes.agentFeedback == nil {
                                actionRes.agentFeedback = AgentFeedback(
                                    severity: "warning",
                                    trigger: "visual_verify_failed",
                                    diagnosis: vr.answer,
                                    suggestedAction: "Inspect the local verification result or call vision_query(mode: 'ask') before retrying.",
                                    source: vr.backend,
                                    latencyMs: vr.latencyMs
                                )
                            }
                            enrichedActionResult = actionRes
                        }
                    }
                }

                if let shot = responseScreenshot {
                    enrichedActionResult?.screenshot = shot
                    if enrichedActionResult?.observation != nil && enrichedActionResult?.observation?.screenshotPath == nil {
                        enrichedActionResult?.observation?.screenshotPath = shot.path
                    }
                }
                let stepCount = enrichedActionResult?.stepResults.count ?? params.steps.count
                let actionSuccess = enrichedActionResult?.success ?? true
                incrementActionCount(by: stepCount)
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: resolvedLabel,
                    summary: "Executed \(stepCount) browser step(s): \(actionSuccess ? "ok" : "failed") · \(AuditRedactor.describeSteps(params.steps))",
                    latencyMs: latencyMs,
                    success: actionSuccess
                )
                let browserFailure = actionSuccess ? nil : ActivityCaption.batchFailure(
                    steps: params.steps,
                    results: enrichedActionResult?.stepResults ?? [],
                    inBrowser: true,
                    elementName: { id in (bridgeResp.snapshot ?? enrichedActionResult?.observation)?.elements.first(where: { $0.id == id })?.title }
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: resolvedLabel,
                    windowTitle: bridgeResp.title,
                    title: browserFailure?.title
                        ?? "Finished \(stepCount) browser step\(stepCount == 1 ? "" : "s")",
                    subtitle: browserFailure.map { $0.reason } ?? bridgeResp.url,
                    latencyMs: enrichedActionResult?.totalLatencyMs ?? latencyMs,
                    success: actionSuccess,
                    isInProgress: false,
                    browserTabId: resolvedTabId,
                    browserProfile: resolvedProfile
                ))
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    snapshot: bridgeResp.snapshot ?? enrichedActionResult?.observation,
                    actionResult: enrichedActionResult,
                    screenshot: responseScreenshot,
                    browserTabId: bridgeResp.tabId,
                    browserUrl: bridgeResp.url,
                    browserTitle: bridgeResp.title
                )
            } else {
                let code = bridgeResp.error?.code ?? "BROWSER_ACT_FAILED"
                let message = bridgeResp.error?.message ?? "Failed to execute browser action"
                appendAudit(method: request.method.rawValue, targetApp: resolvedLabel, summary: message, latencyMs: latencyMs, success: false)
                let failedSteps = bridgeResp.actionResult.map { ActivityCaption.batchFailure(steps: params.steps, results: $0.stepResults, inBrowser: true) }
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: resolvedLabel,
                    title: failedSteps?.title ?? "Couldn't act in Chrome",
                    subtitle: ActivityCaption.reason(errorCode: code, message: message, inBrowser: true) ?? failedSteps?.reason ?? message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
            }

        case .visionStatus:
            let vStatus = localVision.currentStatus()
            let latencyMs = elapsedMs(since: startNs)
            response = .success(id: request.id, latencyMs: latencyMs, visionStatus: vStatus)

        case .visionQuery:
            let params = request.visionQuery ?? VisionQueryParams()
            let visionTargetLabel = params.profile.map { "Chrome (\($0))" } ?? params.app ?? "Local Vision"
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: visionTargetLabel,
                    activityTitle: "Vision query blocked",
                    reason: blockReason
                )
                break
            }
            if workspaceMonitor.namesUseMac(params.app) {
                response = selfTargetResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "Vision query blocked")
                break
            }
            if let blocked = TargetRulesStore.shared.blockedMessage(forQueries: [params.app], in: workspaceMonitor) {
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "Vision query blocked", message: blocked)
                break
            }
            if let blocked = await chromeBridge.targetRulesVisionPreflight(params) {
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: visionTargetLabel, activityTitle: "Vision query blocked", message: blocked.error?.message ?? "")
                break
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
                    response = .failure(id: request.id, code: "IMAGE_PATH_BLOCKED", message: message, latencyMs: latencyMs)
                    break
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
            guard let input = resolved else {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(
                    id: request.id,
                    code: "NO_IMAGE_SOURCE",
                    message: "No screenshot or active browser frame available for vision_query.",
                    latencyMs: latencyMs
                )
                break
            }
            if let tooSmall = Self.tooSmallCaptureMessage(path: input.path) {
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "CAPTURE_TOO_SMALL", message: tooSmall, latencyMs: latencyMs)
                break
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
                response = .failure(id: request.id, code: "CAPTURE_TOO_SMALL", message: message, latencyMs: latencyMs)
                break
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
            response = .success(id: request.id, latencyMs: latencyMs, visionResult: result)

        case .taskStart:
            let params = request.taskStart ?? TaskStartParams()
            let taskId = startTaskInline(params, explicitTaskId: nil)
            let latencyMs = elapsedMs(since: startNs)
            response = .success(id: request.id, latencyMs: latencyMs, status: currentStatus(), taskId: taskId)

        case .taskComplete:
            let params = request.taskComplete ?? TaskCompleteParams()
            let completion = completeTaskInline(
                params,
                taskId: request.namedTaskId,
                fallbackTabId: params.tabId,
                fallbackProfile: params.profile,
                success: true
            )
            let latencyMs = elapsedMs(since: startNs)
            response = .success(
                id: request.id, latencyMs: latencyMs, status: currentStatus(), taskId: completion.taskId, taskSummary: completion.summary
            )

        case .reportPrepare:
            // Only UseMac's own log and window are involved, so every mode allows it; the Kill Switch stops it.
            if isKillSwitchTripped(), let reason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(request: request, startNs: startNs, targetApp: nil, activityTitle: "Problem report blocked", reason: reason)
                break
            }
            response = prepareProblemReport(request, startNs: startNs)

        case .debugCapture:
            // A read of UseMac's own windows: the Kill Switch and pause stop it like a screenshot.
            if let reason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
                response = blockedPolicyResponse(request: request, startNs: startNs, targetApp: WorkspaceMonitor.useMacAppName, activityTitle: "Debug capture blocked", reason: reason)
                break
            }
            response = await handleDebugCapture(request, startNs: startNs)

        case .appMenu:
            response = await handleAppMenu(request, startNs: startNs)

        case .browserBatch:
            response = await handleBrowserBatch(request, startNs: startNs)

        case .skillSave:
            response = handleSkillSave(request, startNs: startNs)

        case .skillList:
            response = handleSkillList(request, startNs: startNs)

        case .skillRun:
            response = await handleSkillRun(request, startNs: startNs)
        }

        notifyStateChanged()
        return response
    }

    /// Closes the Chrome tabs UseMac opened during the task once the completion animation has played, so the
    /// user's tab strip does not fill up with agent tabs. The extension never closes tabs the user had open,
    /// the tab the user is looking at, or tabs with a running download.
    private func scheduleOwnedTabCleanup(profile: String?, keepTabIds: [Int], closeTabIds: [Int]? = nil) {
        let profiles: [String?] = {
            if let profile, !profile.isEmpty { return [profile] }
            let connected = chromeBridge.connectedProfiles().map(\.profileName)
            return connected.isEmpty ? [] : connected.map { Optional($0) }
        }()
        guard !profiles.isEmpty else { return }
        Task { [chromeBridge, taskTabs] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            // Built now, not at task_complete: a tab another task opened in the meantime stays open, also with
            // extensions that predate closeTabIds and go by keepTabIds alone.
            let keep = Set(keepTabIds).union(taskTabs.protectedTabIds()).sorted()
            for name in profiles {
                _ = await chromeBridge.closeOwnedTabs(profile: name, keepTabIds: keep, closeTabIds: closeTabIds)
            }
        }
    }

    private func resolveVisionInputImage(
        params: VisionQueryParams
    ) async -> (path: String, width: Double, height: Double, tabId: Int?, profileName: String?, title: String?)? {
        if let rawExplicit = params.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawExplicit.isEmpty {
            let expanded = (rawExplicit as NSString).expandingTildeInPath
            let explicit = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
            if FileManager.default.fileExists(atPath: explicit) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: explicit)),
                   let cg = LocalVisionEngine.decodeCGImage(fromJPEG: data) {
                    return (explicit, Double(cg.width), Double(cg.height), params.tabId, params.profile, nil)
                }
                return (explicit, 1280, 800, params.tabId, params.profile, nil)
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
                    return (
                        shot.path,
                        Double(shot.width),
                        Double(shot.height),
                        cropResp.tabId ?? params.tabId,
                        cropResp.profileName ?? params.profile,
                        cropResp.title
                    )
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
                    return (
                        path,
                        Double(cached.viewportWidth),
                        Double(cached.viewportHeight),
                        cached.tabId,
                        cached.profileName,
                        cached.title
                    )
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
                return (
                    shot.path,
                    Double(shot.width),
                    Double(shot.height),
                    freshResp.tabId ?? params.tabId,
                    freshResp.profileName ?? params.profile,
                    freshResp.title
                )
            }

            // Fallback to slightly older cached frame if fresh capture wasn't possible
            if let cached = chromeBridge.latestFrame(profileQuery: params.profile, tabId: params.tabId) {
                let dir = UseMacDefaults.captureDirectory
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let path = (dir as NSString).appendingPathComponent("vision-browser-\(cached.tabId ?? 0)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                if (try? cached.jpegData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
                    return (
                        path,
                        Double(cached.viewportWidth),
                        Double(cached.viewportHeight),
                        cached.tabId,
                        cached.profileName,
                        cached.title
                    )
                }
            }
        }

        // Fallback to native app screenshot
        let targetApp = workspaceMonitor.resolveApp(query: params.app)
        let shotReq = ScreenshotRequest(
            app: params.app,
            maxDimension: 1280,
            quality: 0.82,
            includeBase64: false
        )
        if let shot = try? await screenCapturer.capture(shotReq, targetApp: targetApp) {
            let w = targetApp?.windowBounds?.width ?? Double(shot.width)
            let h = targetApp?.windowBounds?.height ?? Double(shot.height)
            return (shot.path, w, h, nil, nil, targetApp?.windowTitle ?? targetApp?.name)
        }
        return nil
    }

    public func currentPermissions(promptAccessibility: Bool = false) -> PermissionStatus {
        permissionManager.currentStatus(promptAccessibility: promptAccessibility)
    }

    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        let granted = permissionManager.requestScreenRecordingPermission()
        notifyStateChanged()
        return granted
    }

    public func openAccessibilitySettings() {
        permissionManager.openAccessibilitySettings()
    }

    public func openScreenRecordingSettings() {
        permissionManager.openScreenRecordingSettings()
    }

    @discardableResult
    public func resetAccessibilityPermissionEntry() -> Bool {
        let ok = permissionManager.resetTCCEntry(service: "Accessibility")
        notifyStateChanged()
        return ok
    }

    @discardableResult
    public func resetScreenRecordingPermissionEntry() -> Bool {
        let ok = permissionManager.resetTCCEntry(service: "ScreenCapture")
        notifyStateChanged()
        return ok
    }

    public func setGovernancePolicy(_ policy: GovernancePolicy) {
        killSwitch.setPolicy(policy)
        if policy == .paused { chromeBridge.sendTabControlStopped() }
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            title: "Policy set to \(policy.rawValue)",
            success: true,
            isInProgress: false
        ))
        notifyStateChanged()
    }

    public func getGovernancePolicy() -> GovernancePolicy {
        killSwitch.getPolicy()
    }

    public func tripKillSwitch(_ tripped: Bool) {
        killSwitch.trip(tripped)
        if tripped {
            onOverlayEvent?(.clear)
            chromeBridge.sendTabControlStopped()
            chromeBridge.cancelActiveCommands()
            chromeBridge.stopActiveStreams()
        }
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            title: tripped ? "Kill Switch Tripped" : "Kill Switch Cleared",
            subtitle: tripped ? "All agent actions halted" : "Agent actions resumed",
            success: !tripped,
            isInProgress: false
        ))
        notifyStateChanged()
    }

    public func isKillSwitchTripped() -> Bool {
        killSwitch.isTripped
    }

    public func bridgePairingKeyText() -> String? {
        chromeBridge.pairingKeyText()
    }

    public func resetBridgePairingKey() -> String? {
        let keyText = chromeBridge.resetPairingKey()
        if keyText != nil {
            notifyStateChanged()
        }
        return keyText
    }

    public func pendingBrowserPairings() -> [String] {
        chromeBridge.pendingPairingProfiles()
    }

    @discardableResult
    public func setPairedApp(_ query: String?) -> AppDescriptor? {
        let app = workspaceMonitor.setPairedApp(query)
        notifyStateChanged()
        return app
    }

    public func getPairedApp() -> AppDescriptor? {
        workspaceMonitor.getPairedApp()
    }

    @discardableResult
    public func captureFrontmostExternalApp() -> AppDescriptor? {
        let app = workspaceMonitor.captureFrontmostExternalApp()
        notifyStateChanged()
        return app
    }

    public func listRunningApps() -> [AppDescriptor] {
        workspaceMonitor.listRunningApps()
    }

    public func captureWindowPreview(
        for app: AppDescriptor?,
        maxDimension: Int = 560
    ) async -> (image: CGImage, windowBounds: ScreenRect?)? {
        guard permissionManager.isScreenRecordingGranted() else {
            return nil
        }
        return await screenCapturer.capturePreviewCGImage(targetApp: app, maxDimension: maxDimension)
    }

    public func recentAuditEntries(limit: Int = 50) -> [AuditEntry] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard limit > 0 else { return [] }
        return Array(auditEntries.suffix(limit).reversed())
    }

    public func updateActiveClientCount(_ count: Int) {
        stateLock.lock()
        activeClients = max(0, count)
        stateLock.unlock()
        notifyStateChanged()
    }

    @discardableResult
    public func highlightCachedElement(_ elementId: String, durationMs: Int = 1500) -> ScreenRect? {
        var foundNode: ElementNode?
        var owner: Int32?
        if let targetApp = workspaceMonitor.resolveApp(query: nil) {
            if let node = axIndexer.node(for: elementId, pid: targetApp.pid) {
                foundNode = node
                owner = targetApp.pid
            } else if elementId.hasPrefix("@v"), let node = lookupOCRNode(elementId, pid: targetApp.pid) {
                foundNode = node
                owner = targetApp.pid
            }
        }
        if foundNode == nil, let cached = axIndexer.node(for: elementId) {
            foundNode = cached.node
            owner = cached.pid
        }
        if foundNode == nil, elementId.hasPrefix("@v"), let ocrMatch = lookupAnyOCRNode(elementId) {
            foundNode = ocrMatch.node
            owner = ocrMatch.pid
        }
        guard let node = foundNode else {
            return nil
        }

        onOverlayEvent?(.highlightElement(
            rect: node.frame,
            label: node.id,
            role: node.role,
            durationMs: durationMs,
            pid: owner,
            windowId: owner.flatMap { WindowResolver.targetWindowID(pid: $0) }.map { UInt32($0) }
        ))
        return node.frame
    }

    public func currentStatus() -> DaemonStatus {
        let permissions = permissionManager.currentStatus(promptAccessibility: false)
        // Apps the user's rules block are left out, like UseMac itself.
        let rules = TargetRulesStore.shared.rules
        let paired = workspaceMonitor.getPairedApp().flatMap { rules.blocksApp(bundleId: $0.bundleId) ? nil : $0 }
        let frontmost = workspaceMonitor.currentExternalFrontmostApp().flatMap { rules.blocksApp(bundleId: $0.bundleId) ? nil : $0 }
        let policy = killSwitch.getPolicy()
        let tripped = killSwitch.isTripped

        stateLock.lock()
        let uptime = Date().timeIntervalSince(startedAt)
        let reqs = totalRequests
        let actions = totalActions
        let lastObs = lastObserveLatencyMs
        let avgObs = observeCount > 0 ? (totalObserveLatencyMs / Double(observeCount)) : 0
        let cacheHits = hotCacheHits
        let clients = activeClients
        stateLock.unlock()

        let telemetry = TelemetrySummary(
            uptimeSeconds: uptime,
            totalRequests: reqs,
            totalActions: actions,
            lastObserveLatencyMs: lastObs,
            avgObserveLatencyMs: avgObs,
            hotCacheHits: cacheHits,
            activeClients: clients
        )

        return DaemonStatus(
            version: UseMacDefaults.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            socketPath: socketPath,
            policy: policy,
            killSwitchTripped: tripped,
            permissions: permissions,
            pairedApp: paired,
            frontmostApp: frontmost,
            telemetry: telemetry,
            browserProfiles: chromeBridge.connectedProfiles()
        )
    }

    @discardableResult
    func pruneCaptures(olderThan seconds: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let captureDirURL = URL(fileURLWithPath: UseMacDefaults.captureDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: captureDirURL.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }

        let dirPrefix = captureDirURL.path.hasSuffix("/") ? captureDirURL.path : captureDirURL.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: captureDirURL, includingPropertiesForKeys: keys, options: []) else {
            return 0
        }

        var removedCount = 0
        for itemURL in entries {
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isDirectory != true,
                  values.isRegularFile == true,
                  let modDate = values.contentModificationDate else {
                continue
            }

            let resolvedItem = itemURL.standardizedFileURL.resolvingSymlinksInPath()
            guard resolvedItem.path.hasPrefix(dirPrefix),
                  resolvedItem.deletingLastPathComponent().path == captureDirURL.path else {
                continue
            }

            guard now.timeIntervalSince(modDate) > seconds else {
                continue
            }

            do {
                try fm.removeItem(at: itemURL)
                removedCount += 1
            } catch {
                continue
            }
        }
        return removedCount
    }

    private func scheduleCapturePruneIfNeeded() {
        let now = Date()
        stateLock.lock()
        let shouldPrune: Bool
        if let lastPrune = lastCapturePruneAt {
            shouldPrune = now.timeIntervalSince(lastPrune) >= Self.capturePruneInterval
        } else {
            shouldPrune = true
        }
        if shouldPrune {
            lastCapturePruneAt = now
        }
        stateLock.unlock()

        guard shouldPrune else { return }
        Self.capturePruneQueue.async { [weak self] in
            _ = self?.pruneCaptures(olderThan: Self.captureRetentionSeconds)
        }
    }

    private func blockedPolicyResponse(
        request: RPCRequest,
        startNs: UInt64,
        targetApp: String?,
        activityAppName: String? = nil,
        activityTitle: String,
        reason: String,
        readOnlyRequested: Bool = false
    ) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(
            method: request.method.rawValue,
            targetApp: targetApp,
            summary: "Blocked: \(reason)",
            latencyMs: latencyMs,
            success: false
        )
        // The caption and the agent's hint name the mode, pause or Emergency stop that refused it (ExecutionModeNotice).
        // browser_act's readOnly flag is the agent's own choice, not the user's.
        let policy = killSwitch.getPolicy()
        let tripped = killSwitch.isTripped
        let caption = readOnlyRequested ? nil : ExecutionModeNotice.activityReason(policy: policy, killSwitchTripped: tripped)
        let hint = readOnlyRequested
            ? ExecutionModeNotice.readOnlyRequestedHint
            : ExecutionModeNotice.agentHint(policy: policy, killSwitchTripped: tripped)
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            appName: activityAppName ?? targetApp,
            title: activityTitle,
            subtitle: caption ?? reason,
            latencyMs: latencyMs,
            success: false,
            isInProgress: false
        ))
        return .failure(id: request.id, code: "POLICY_BLOCKED", message: reason, latencyMs: latencyMs, hint: hint)
    }

    /// Refusal for a request whose target the user's app and site rules block (TargetRules).
    private func targetBlockedResponse(
        request: RPCRequest,
        startNs: UInt64,
        targetApp: String?,
        activityTitle: String,
        message: String
    ) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(
            method: request.method.rawValue,
            targetApp: targetApp,
            summary: "Blocked by the app and site rules",
            latencyMs: latencyMs,
            success: false
        )
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            title: activityTitle,
            subtitle: message,
            latencyMs: latencyMs,
            success: false,
            isInProgress: false
        ))
        return .failure(id: request.id, code: TargetRules.errorCode, message: message, latencyMs: latencyMs)
    }

    /// Refusal for a request that names UseMac itself: agents never observe or act on its own windows.
    private func selfTargetResponse(
        request: RPCRequest,
        startNs: UInt64,
        targetApp: String?,
        activityTitle: String
    ) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        let message = WorkspaceMonitor.selfTargetMessage
        appendAudit(
            method: request.method.rawValue,
            targetApp: targetApp,
            summary: "Blocked: request named UseMac itself",
            latencyMs: latencyMs,
            success: false
        )
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            title: activityTitle,
            subtitle: message,
            latencyMs: latencyMs,
            success: false,
            isInProgress: false
        ))
        return .failure(id: request.id, code: "SELF_TARGET_BLOCKED", message: message, latencyMs: latencyMs)
    }

    /// Refusal for an acting request on a window or tab another running task holds (TaskTabRegistry.claim).
    func targetBusyResponse(request: RPCRequest, busy: TaskTabRegistry.Busy) -> RPCResponse {
        let holder = busy.agent.map { "\($0) (\(busy.taskId))" } ?? busy.taskId
        let message = "\(busy.target) is in use by another task, \(holder), active \(busy.idleSeconds) s ago. "
            + "Wait until it finishes (task_complete), then retry; observe and screenshot still work."
        appendAudit(method: request.method.rawValue, targetApp: busy.target, summary: "Busy: held by \(holder)", latencyMs: 0, success: false)
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            title: "\(busy.target) is busy",
            subtitle: message,
            success: false,
            isInProgress: false
        ))
        return .failure(id: request.id, code: "TARGET_BUSY", message: message)
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

    private func isMutatingStepForPolicy(_ step: ActionStep) -> Bool {
        switch step.action {
        case .target, .scroll, .hover, .wait, .scrollIntoView, .waitFor, .assert, .scrollUntil:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile, .axAction, .fillForm, .menuAction:
            return true
        }
    }

    private func isSensitiveStepForPolicy(_ step: ActionStep) -> Bool {
        if step.action == .uploadFile {
            return true
        }
        // AXOpen picks a file in an open panel, which is an upload in disguise.
        if step.action == .axAction, step.actionName?.lowercased() == "axopen" {
            return true
        }
        guard step.action == .pressKey else {
            return false
        }
        // Any spelling either path presses as ⌘ or ⌃, "meta" included (ModifierAliases).
        return ModifierAliases.isSensitive(step.modifiers)
    }

    private func incrementRequestCount() {
        stateLock.lock()
        totalRequests += 1
        stateLock.unlock()
    }

    private func incrementActionCount(by count: Int) {
        stateLock.lock()
        totalActions += count
        stateLock.unlock()
    }

    private func elapsedMs(since startNs: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
    }

    private func recordObserveMetrics(latencyMs: Double, fromHotCache: Bool) {
        stateLock.lock()
        lastObserveLatencyMs = latencyMs
        totalObserveLatencyMs += latencyMs
        observeCount += 1
        if fromHotCache {
            hotCacheHits += 1
        }
        stateLock.unlock()
    }

    func appendAudit(
        method: String,
        targetApp: String?,
        summary: String,
        latencyMs: Double,
        success: Bool,
        taskId: String? = nil
    ) {
        let request = AuditRequestContext.request
        let hint = request?.auditTaskHint
        let entry = AuditEntry(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            method: method,
            targetApp: targetApp,
            summary: AuditRedactor.scrub(summary, secrets: request?.auditSecrets ?? []),
            latencyMs: latencyMs,
            success: success,
            taskId: taskId ?? taskTabs.resolve(taskId: hint?.taskId, tabId: hint?.tabId)
        )

        stateLock.lock()
        auditEntries.append(entry)
        if auditEntries.count > 500 {
            auditEntries.removeFirst(auditEntries.count - 500)
        }
        stateLock.unlock()
        auditStore?.append(entry)
    }

    private func emitLiveActivity(_ item: LiveActivityItem) {
        onLiveActivity?(item)
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    // MARK: - Inline Task Lifecycle (standalone + piggybacked)

    func startTaskInline(_ params: TaskStartParams, explicitTaskId: String?) -> String {
        let resolvedProfile: String? = {
            if let p = params.profile, !p.isEmpty { return p }
            if params.tabId != nil {
                return chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            }
            if params.app == nil, let prof = chromeBridge.connectedProfiles().first?.profileName {
                return prof
            }
            return nil
        }()
        let resolvedApp = params.app.flatMap { workspaceMonitor.resolveApp(query: $0) }
        let targetName = resolvedProfile.map { "Chrome (\($0))" } ?? resolvedApp?.name ?? params.app ?? "Agent"
        let summaryText = (params.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? params.summary!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Working…"
        let taskId = taskTabs.start(taskId: params.taskId ?? explicitTaskId, agent: params.agent)
        appendAudit(
            method: RPCMethod.taskStart.rawValue,
            targetApp: targetName,
            summary: summaryText,
            latencyMs: 0,
            success: true,
            taskId: taskId
        )
        emitLiveActivity(LiveActivityItem(
            kind: .taskStart,
            appName: targetName,
            appPid: resolvedApp?.pid,
            bundleId: resolvedProfile != nil ? "com.google.Chrome" : resolvedApp?.bundleId,
            title: summaryText,
            latencyMs: 0,
            success: true,
            isInProgress: true,
            browserTabId: params.tabId,
            browserProfile: resolvedProfile,
            agentName: TaskTabRegistry.cleanAgent(params.agent),
            taskId: taskId
        ))
        return taskId
    }

    func completeTaskInline(
        _ params: TaskCompleteParams,
        taskId: String?,
        fallbackTabId: Int? = nil,
        fallbackProfile: String? = nil,
        success: Bool = true
    ) -> TaskTabRegistry.Completion {
        let effectiveTabId = params.tabId ?? fallbackTabId
        let completion = taskTabs.complete(
            taskId: taskId,
            tabId: effectiveTabId,
            keepTabIds: Set(params.keepTabIds ?? []),
            keepTabs: params.keepTabs == true
        )
        let resolvedProfile: String? = {
            if let p = params.profile, !p.isEmpty { return p }
            if let p = fallbackProfile, !p.isEmpty { return p }
            if effectiveTabId != nil {
                return chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            }
            return nil
        }()
        approvals.endTask(completion.taskId)
        let resolvedApp = params.app.flatMap { workspaceMonitor.resolveApp(query: $0) }
        let targetName = resolvedProfile.map { "Chrome (\($0))" } ?? resolvedApp?.name ?? params.app ?? "Agent"
        let summaryText = (params.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? params.summary!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Task completed"
        appendAudit(
            method: RPCMethod.taskComplete.rawValue,
            targetApp: targetName,
            summary: summaryText,
            latencyMs: 0,
            success: success,
            taskId: completion.taskId
        )
        chromeBridge.sendTabControlEnded(keepTabIds: Array(completion.protectedTabIds))
        emitLiveActivity(LiveActivityItem(
            kind: .taskComplete,
            appName: targetName,
            appPid: resolvedApp?.pid,
            bundleId: resolvedProfile != nil ? "com.google.Chrome" : resolvedApp?.bundleId,
            title: summaryText,
            latencyMs: 0,
            success: success,
            isInProgress: false,
            browserTabId: effectiveTabId,
            browserProfile: resolvedProfile,
            taskTabIds: completion.ownTabIds.map { Array($0).sorted() },
            taskId: completion.taskId
        ))
        if params.keepTabs != true {
            let ownTabs = completion.taskId != nil ? completion.ownTabIds.map { Array($0).sorted() } : nil
            scheduleOwnedTabCleanup(profile: params.profile ?? fallbackProfile, keepTabIds: params.keepTabIds ?? [], closeTabIds: ownTabs)
        }
        return completion
    }

    // MARK: - SOTA Handlers: app_menu, browser_batch, skill_save, skill_list, skill_run

    private func handleAppMenu(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        let params = request.appMenu ?? AppMenuParams()
        let cleanedPath = (params.menuPath ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let isInvoke = !cleanedPath.isEmpty

        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: isInvoke) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app,
                activityTitle: isInvoke ? "App menu invoke blocked" : "App menu search blocked",
                reason: blockReason
            )
        }

        let target = workspaceMonitor.resolveTarget(query: params.app)
        if target == .useMac {
            return selfTargetResponse(request: request, startNs: startNs, targetApp: params.app, activityTitle: "App menu blocked")
        }
        if case .app(let app) = target, let blocked = TargetRulesStore.shared.blockedMessage(for: app) {
            return targetBlockedResponse(request: request, startNs: startNs, targetApp: app.name, activityTitle: "App menu blocked", message: blocked)
        }
        guard case .app(let app) = target else {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: "App not found", latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "APP_NOT_FOUND", message: "No matching target application found", latencyMs: latencyMs)
        }

        guard currentPermissions(promptAccessibility: false).accessibilityGranted else {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: app.name, summary: "Accessibility permission denied", latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "PERMISSION_DENIED", message: "Accessibility permission not granted", latencyMs: latencyMs)
        }

        if isInvoke {
            let invokeRes = await Task.detached(priority: .userInitiated) {
                NativeAppMenuHelper.invoke(pid: app.pid, path: cleanedPath)
            }.value
            let latencyMs = elapsedMs(since: startNs)
            switch invokeRes {
            case .success(let resolvedPath):
                let joined = resolvedPath.joined(separator: " > ")
                incrementActionCount(by: 1)
                appendAudit(method: request.method.rawValue, targetApp: app.name, summary: "Invoked menu \(joined)", latencyMs: latencyMs, success: true)
                emitLiveActivity(LiveActivityItem(
                    kind: .actionComplete,
                    appName: app.name,
                    appPid: app.pid,
                    bundleId: app.bundleId,
                    windowTitle: app.windowTitle,
                    title: "Menu: \(resolvedPath.last ?? joined)",
                    subtitle: joined,
                    mechanism: "ax-menu",
                    latencyMs: latencyMs,
                    success: true,
                    isInProgress: false
                ))
                return .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    appMenuResult: AppMenuResult(app: app.name, invokedPath: resolvedPath, message: "Invoked \(joined)")
                )
            case .failure(let err):
                appendAudit(method: request.method.rawValue, targetApp: app.name, summary: err.message, latencyMs: latencyMs, success: false)
                return .failure(id: request.id, code: err.code, message: err.message, latencyMs: latencyMs)
            }
        } else {
            let query = params.query
            let items = await Task.detached(priority: .userInitiated) {
                NativeAppMenuHelper.search(pid: app.pid, query: query, maxItems: 200)
            }.value
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: app.name, summary: "Found \(items.count) menu item(s)", latencyMs: latencyMs, success: true)
            return .success(
                id: request.id,
                latencyMs: latencyMs,
                appMenuResult: AppMenuResult(app: app.name, items: items)
            )
        }
    }

    private func handleBrowserBatch(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        guard let params = request.browserBatch, !params.urls.isEmpty else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "browser_batch requires a non-empty urls array.", latencyMs: latencyMs)
        }

        let batchMode = (params.mode ?? "observe").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extractMode = (params.extractMode ?? "auto").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isEvalMode = (batchMode == "extract" && extractMode == "eval")

        if let blockReason = killSwitch.isBlocked(forSensitiveAction: isEvalMode, isMutatingAction: isEvalMode) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                activityTitle: "Browser batch blocked",
                reason: blockReason
            )
        }
        if TargetRulesStore.shared.rules.blocksBrowser {
            return targetBlockedResponse(
                request: request,
                startNs: startNs,
                targetApp: params.profile ?? "Chrome",
                activityTitle: "Browser batch blocked",
                message: TargetRules.blockedBrowserMessage
            )
        }

        let taskId = request.namedTaskId
        let rules = TargetRulesStore.shared.rules
        let profile = params.profile
        let maxElements = params.maxElements
        let autoDismiss = params.autoDismissOverlays
        let closeAfter = params.closeAfter == true
        let bridge = self.chromeBridge
        let taskTabs = self.taskTabs

        var indexedResults: [(Int, BrowserBatchItemResult, Int?)] = []
        indexedResults.reserveCapacity(params.urls.count)

        await withTaskGroup(of: (Int, BrowserBatchItemResult, Int?).self) { group in
            for (index, rawUrl) in params.urls.enumerated() {
                group.addTask {
                    let itemStart = DispatchTime.now().uptimeNanoseconds
                    func itemElapsed() -> Double {
                        ((Double(DispatchTime.now().uptimeNanoseconds - itemStart) / 1_000_000.0) * 100).rounded() / 100
                    }

                    let normalizedUrl: String
                    switch NavigationPolicy.validate(rawUrl) {
                    case .success(let valid):
                        normalizedUrl = valid
                    case .failure(let blocked):
                        return (index, BrowserBatchItemResult(
                            url: rawUrl,
                            tabId: nil,
                            success: false,
                            error: "URL_BLOCKED: \(blocked.message)",
                            latencyMs: itemElapsed()
                        ), nil)
                    }

                    if rules.blocksURL(normalizedUrl) {
                        let msg = TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: normalizedUrl))
                        return (index, BrowserBatchItemResult(
                            url: normalizedUrl,
                            tabId: nil,
                            success: false,
                            error: "\(TargetRules.errorCode): \(msg)",
                            latencyMs: itemElapsed()
                        ), nil)
                    }

                    let openResp = await bridge.open(BrowserOpenParams(
                        url: normalizedUrl,
                        profile: profile,
                        newTab: true,
                        stream: false,
                        taskId: taskId,
                        autoDismissOverlays: autoDismiss,
                        observationMode: batchMode == "extract" ? ObservationMode.none : nil
                    ))
                    guard openResp.ok, let openedTabId = openResp.tabId else {
                        let code = openResp.error?.code ?? "BROWSER_OPEN_FAILED"
                        let message = openResp.error?.message ?? "Failed to open URL"
                        return (index, BrowserBatchItemResult(
                            url: normalizedUrl,
                            tabId: openResp.tabId,
                            success: false,
                            error: "\(code): \(message)",
                            latencyMs: itemElapsed()
                        ), nil)
                    }

                    if !closeAfter {
                        taskTabs.recordOpenedTab(openedTabId, taskId: taskId, profile: profile)
                    }
                    let resolvedProf = openResp.profileName ?? profile

                    if batchMode == "extract" {
                        let extResp = await bridge.extract(BrowserExtractParams(
                            profile: resolvedProf,
                            tabId: openedTabId,
                            mode: extractMode
                        ))
                        if extResp.ok {
                            return (index, BrowserBatchItemResult(
                                url: openResp.url ?? normalizedUrl,
                                tabId: openedTabId,
                                success: true,
                                extract: extResp.extractResult,
                                latencyMs: itemElapsed()
                            ), openedTabId)
                        } else {
                            let code = extResp.error?.code ?? "BROWSER_EXTRACT_FAILED"
                            let msg = extResp.error?.message ?? "Failed to extract page"
                            return (index, BrowserBatchItemResult(
                                url: openResp.url ?? normalizedUrl,
                                tabId: openedTabId,
                                success: false,
                                error: "\(code): \(msg)",
                                latencyMs: itemElapsed()
                            ), openedTabId)
                        }
                    } else {
                        var snap = openResp.snapshot
                        if snap == nil {
                            let obsResp = await bridge.observe(BrowserObserveParams(
                                profile: resolvedProf,
                                tabId: openedTabId,
                                maxElements: maxElements
                            ))
                            if !obsResp.ok {
                                let code = obsResp.error?.code ?? "BROWSER_OBSERVE_FAILED"
                                let msg = obsResp.error?.message ?? "Failed to observe page"
                                return (index, BrowserBatchItemResult(
                                    url: openResp.url ?? normalizedUrl,
                                    tabId: openedTabId,
                                    success: false,
                                    error: "\(code): \(msg)",
                                    latencyMs: itemElapsed()
                                ), openedTabId)
                            }
                            snap = obsResp.snapshot
                        }
                        return (index, BrowserBatchItemResult(
                            url: openResp.url ?? normalizedUrl,
                            tabId: openedTabId,
                            success: true,
                            snapshot: snap,
                            latencyMs: itemElapsed()
                        ), openedTabId)
                    }
                }
            }

            for await item in group {
                indexedResults.append(item)
            }
        }

        indexedResults.sort { $0.0 < $1.0 }
        let items = indexedResults.map(\.1)
        let openedTabIds = indexedResults.compactMap(\.2)
        if closeAfter, !openedTabIds.isEmpty {
            _ = await chromeBridge.closeOwnedTabs(profile: profile, keepTabIds: [], closeTabIds: openedTabIds)
            for tid in openedTabIds {
                taskTabs.forgetTab(tid)
            }
        }

        let latencyMs = elapsedMs(since: startNs)
        let okCount = items.filter(\.success).count
        let batchResult = BrowserBatchResult(results: items, totalLatencyMs: (latencyMs * 100).rounded() / 100)
        appendAudit(
            method: request.method.rawValue,
            targetApp: "Chrome (\(params.profile ?? "Browser"))",
            summary: "Batch \(batchMode) \(okCount)/\(items.count) URL(s)",
            latencyMs: latencyMs,
            success: okCount == items.count
        )
        return .success(id: request.id, latencyMs: latencyMs, browserBatchResult: batchResult)
    }

    private func handleSkillList(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: nil,
                activityTitle: "Skill list blocked",
                reason: blockReason
            )
        }
        let skills = skillStore.list(filter: request.skillList)
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(
            method: request.method.rawValue,
            targetApp: nil,
            summary: "Listed \(skills.count) skill(s)",
            latencyMs: latencyMs,
            success: true
        )
        return .success(id: request.id, latencyMs: latencyMs, skills: SkillListResult(skills: skills))
    }

    private func handleSkillSave(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        guard let params = request.skillSave else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing skillSave payload", latencyMs: latencyMs)
        }
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app,
                activityTitle: "Skill save blocked",
                reason: blockReason
            )
        }

        do {
            if params.delete == true {
                let removed = try skillStore.delete(name: params.name)
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: params.app,
                    summary: removed ? "Deleted skill '\(params.name)'" : "Skill '\(params.name)' not found for delete",
                    latencyMs: latencyMs,
                    success: removed
                )
                return .success(id: request.id, latencyMs: latencyMs, skills: SkillListResult(skills: skillStore.list()))
            } else {
                let saved = try skillStore.save(params)
                let latencyMs = elapsedMs(since: startNs)
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: saved.app ?? saved.target,
                    summary: "Saved skill '\(saved.name)' (\(saved.steps.count) step(s))",
                    latencyMs: latencyMs,
                    success: true
                )
                return .success(id: request.id, latencyMs: latencyMs, skills: SkillListResult(skills: skillStore.list(), saved: saved))
            }
        } catch {
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: error.localizedDescription, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: error.localizedDescription, latencyMs: latencyMs)
        }
    }

    private func handleSkillRun(_ request: RPCRequest, startNs: UInt64) async -> RPCResponse {
        guard let params = request.skillRun else {
            let latencyMs = elapsedMs(since: startNs)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: "Missing skillRun payload", latencyMs: latencyMs)
        }
        if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
            return blockedPolicyResponse(
                request: request,
                startNs: startNs,
                targetApp: params.app ?? params.profile,
                activityTitle: "Skill run blocked",
                reason: blockReason
            )
        }

        guard let skill = skillStore.get(name: params.name) else {
            let latencyMs = elapsedMs(since: startNs)
            let msg = SkillStoreError.notFound(params.name).localizedDescription
            appendAudit(method: request.method.rawValue, targetApp: params.app, summary: msg, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "SKILL_NOT_FOUND", message: msg, latencyMs: latencyMs)
        }

        let interpolatedSteps = SkillStore.interpolate(steps: skill.steps, with: params.params ?? [:])
        let missingParams = SkillStore.extractParamNames(from: interpolatedSteps)
        if !missingParams.isEmpty {
            let latencyMs = elapsedMs(since: startNs)
            let msg = "Missing skill parameter(s) for '\(skill.name)': \(missingParams.joined(separator: ", "))."
            appendAudit(method: request.method.rawValue, targetApp: params.app ?? skill.app, summary: msg, latencyMs: latencyMs, success: false)
            return .failure(id: request.id, code: "INVALID_REQUEST", message: msg, latencyMs: latencyMs)
        }

        let targetKind: String = {
            if let explicit = skill.target?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !explicit.isEmpty {
                return explicit
            }
            if params.tabId != nil || params.profile != nil || (skill.urlPattern?.isEmpty == false) {
                return "browser"
            }
            if params.app != nil || (skill.app?.isEmpty == false) {
                return "native"
            }
            if interpolatedSteps.contains(where: { $0.selector != nil || $0.action == .openURL || $0.action == .navigate }) {
                return "browser"
            }
            return "native"
        }()

        // Execute through the exact same governed act / browser_act path (GovernancePolicy, TargetRules, Ask mode, URL/upload checks).
        let delegatedRequest: RPCRequest
        if targetKind == "browser" {
            delegatedRequest = RPCRequest(
                id: request.id,
                method: .browserAct,
                browserAct: BrowserActParams(
                    profile: params.profile,
                    tabId: params.tabId,
                    steps: interpolatedSteps,
                    stopOnError: params.stopOnError ?? true,
                    returnObservation: params.returnObservation ?? true,
                    returnDiffOnly: params.returnDiffOnly ?? false,
                    observationMode: params.observationMode
                ),
                taskId: request.namedTaskId
            )
        } else {
            delegatedRequest = RPCRequest(
                id: request.id,
                method: .act,
                act: BatchActionRequest(
                    app: params.app ?? skill.app,
                    steps: interpolatedSteps,
                    stopOnError: params.stopOnError ?? true,
                    returnObservation: params.returnObservation ?? true,
                    returnDiffOnly: params.returnDiffOnly ?? false,
                    observationMode: params.observationMode
                ),
                taskId: request.namedTaskId
            )
        }

        let execResp = await handleRequest(delegatedRequest)
        let latencyMs = elapsedMs(since: startNs)
        if !execResp.ok {
            return execResp
        }

        let actionResult = execResp.actionResult
        let succeeded = actionResult?.success ?? true
        let updatedSkill = skillStore.recordRun(name: skill.name, success: succeeded)
        let driftMessage: String? = {
            guard !succeeded else { return nil }
            if let failed = actionResult?.stepResults.first(where: { !$0.success }) {
                let reason = failed.message ?? failed.errorCode ?? "failed"
                return "Skill '\(skill.name)' drifted at step \(failed.index) (\(failed.action.rawValue)): \(reason)"
            }
            return "Skill '\(skill.name)' did not complete all steps."
        }()

        let skillResult = SkillRunResult(
            name: skill.name,
            success: succeeded,
            actionResult: actionResult,
            totalLatencyMs: (latencyMs * 100).rounded() / 100,
            message: driftMessage,
            skill: updatedSkill ?? skill
        )
        appendAudit(
            method: request.method.rawValue,
            targetApp: params.app ?? skill.app ?? params.profile ?? targetKind,
            summary: "Ran skill '\(skill.name)': \(succeeded ? "ok" : (driftMessage ?? "failed"))",
            latencyMs: latencyMs,
            success: succeeded
        )
        return .success(
            id: request.id,
            latencyMs: latencyMs,
            snapshot: execResp.snapshot ?? actionResult?.observation,
            actionResult: actionResult,
            screenshot: execResp.screenshot,
            browserTabId: execResp.browserTabId,
            browserUrl: execResp.browserUrl,
            browserTitle: execResp.browserTitle,
            skillResult: skillResult
        )
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
                LocalVisionEngine.recognizeText(in: cgImage, region: nil, fast: false)
            }.value
            let combinedText = [corpus, ocr.text].filter { !$0.isEmpty }.joined(separator: " | ")
            let check = LocalVisionEngine.verifyAssertion(assertion, againstOCRText: combinedText)
            let ocrMs = (elapsedMs(since: ocrStartNs) * 100).rounded() / 100
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
        if let input = await resolveVisionInputImage(params: visionParams) {
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

    private struct InMemoryDiagnosis {
        let blockingDetected: Bool
        let summary: String
        let deltaText: String
        let closeX: Double?
        let closeY: Double?
    }

    private static func diagnoseInMemoryWithAppleVision(
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
        guard let preview = await screenCapturer.capturePreviewCGImage(targetApp: app, maxDimension: 1280) else {
            return []
        }
        let effectiveBounds = preview.windowBounds ?? windowBounds
        let image = preview.image
        return await Task.detached(priority: .userInitiated) {
            LocalVisionEngine.ocrElementNodes(from: image, windowBounds: effectiveBounds)
        }.value
    }

    private func storeOCRNodes(_ nodes: [ElementNode], pid: Int32) {
        var map: [String: ElementNode] = [:]
        for node in nodes {
            map[node.id] = node
        }
        stateLock.lock()
        ocrNodesByPid[pid] = map
        stateLock.unlock()
    }

    private func lookupOCRNode(_ id: String, pid: Int32) -> ElementNode? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ocrNodesByPid[pid]?[id]
    }

    private func lookupAnyOCRNode(_ id: String) -> (pid: Int32, node: ElementNode)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        for (pid, map) in ocrNodesByPid {
            if let node = map[id] {
                return (pid, node)
            }
        }
        return nil
    }

    private func resolveOCRElementTargets(in request: BatchActionRequest, pid: Int32?) -> BatchActionRequest {
        guard request.steps.contains(where: { $0.elementId?.hasPrefix("@v") == true && $0.x == nil && $0.y == nil }) else {
            return request
        }
        var copy = request
        for idx in copy.steps.indices {
            guard let id = copy.steps[idx].elementId, id.hasPrefix("@v"),
                  copy.steps[idx].x == nil, copy.steps[idx].y == nil else {
                continue
            }
            let node = pid.flatMap { lookupOCRNode(id, pid: $0) } ?? lookupAnyOCRNode(id)?.node
            if let node {
                copy.steps[idx].x = node.frame.centerX
                copy.steps[idx].y = node.frame.centerY
                copy.steps[idx].elementId = nil
            }
        }
        return copy
    }

    static func filterElements(_ elements: [ElementNode], filter: ElementFilter, viewport: ScreenRect?) -> [ElementNode] {
        elements.filter { node in
            if filter.viewportOnly == true, node.offscreen == true {
                return false
            }
            if let role = filter.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
                if ElementMatcher.normalizeRole(node.role) != ElementMatcher.normalizeRole(role) {
                    return false
                }
            }
            if let text = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let needle = ElementMatcher.normalize(text)
                let haystacks = [node.title, node.value, node.roleDescription].compactMap { $0 }
                if !haystacks.contains(where: { ElementMatcher.normalize($0).contains(needle) }) {
                    return false
                }
            }
            return true
        }
    }

    private func cachedScreenshotJPEG(forKey key: String) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastScreenshotJPEGByTarget[key]
    }

    private func storeScreenshotJPEG(_ data: Data, forKey key: String) {
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

    private func applyRegionOrDiffCrop(
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

    private func saveCroppedJPEG(
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

// MARK: - Native Menu Bar AX Helper (zero focus steal)

private enum NativeAppMenuHelper {
    struct MenuError: Error {
        let code: String
        let message: String
    }

    static func search(pid: Int32, query: String?, maxItems: Int = 200) -> [AppMenuItemInfo] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let menuBar = copyElement(axApp, attribute: kAXMenuBarAttribute) else {
            return []
        }

        let needle = query.map { ElementMatcher.normalize($0) }
        let hasQuery = !(needle?.isEmpty ?? true)
        var results: [AppMenuItemInfo] = []

        func walkMenu(_ menuElement: AXUIElement, pathPrefix: [String], depth: Int) {
            guard depth <= 4, results.count < maxItems else { return }
            let children = copyChildren(menuElement)
            for child in children {
                guard results.count < maxItems else { break }
                let title = (copyString(child, attribute: kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                if depth == 0 && title == "Apple" { continue }

                let currentPath = pathPrefix + [title]
                let subChildren = copyChildren(child)
                if let submenu = subChildren.first(where: { copyString($0, attribute: kAXRoleAttribute) == kAXMenuRole as String }) {
                    walkMenu(submenu, pathPrefix: currentPath, depth: depth + 1)
                } else if depth > 0 {
                    let enabled = copyBool(child, attribute: kAXEnabledAttribute) ?? true
                    let shortcut = formatShortcut(for: child)
                    if !hasQuery || matchesQuery(needle!, title: title, path: currentPath) {
                        results.append(AppMenuItemInfo(path: currentPath, title: title, shortcut: shortcut, enabled: enabled))
                    }
                }
            }
        }

        walkMenu(menuBar, pathPrefix: [], depth: 0)
        return results
    }

    static func invoke(pid: Int32, path: [String]) -> Result<[String], MenuError> {
        guard !path.isEmpty else {
            return .failure(MenuError(code: "INVALID_REQUEST", message: "menuPath must not be empty."))
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let menuBar = copyElement(axApp, attribute: kAXMenuBarAttribute) else {
            return .failure(MenuError(code: "ELEMENT_NOT_FOUND", message: "Application menu bar is not accessible."))
        }

        var currentContainer = menuBar
        var resolvedPath: [String] = []

        for (index, segment) in path.enumerated() {
            let children = copyChildren(currentContainer)
            guard let matched = matchMenuItem(segment: segment, in: children) else {
                let joined = path.joined(separator: " > ")
                return .failure(MenuError(code: "ELEMENT_NOT_FOUND", message: "Menu item '\(joined)' not found (stopped at '\(segment)')."))
            }
            let title = copyString(matched, attribute: kAXTitleAttribute) ?? segment
            resolvedPath.append(title)

            if index < path.count - 1 {
                let subChildren = copyChildren(matched)
                guard let submenu = subChildren.first(where: { copyString($0, attribute: kAXRoleAttribute) == kAXMenuRole as String }) else {
                    return .failure(MenuError(code: "ELEMENT_NOT_FOUND", message: "Menu '\(title)' has no submenu for '\(path[index + 1])'."))
                }
                currentContainer = submenu
            } else {
                let enabled = copyBool(matched, attribute: kAXEnabledAttribute) ?? true
                guard enabled else {
                    let joined = resolvedPath.joined(separator: " > ")
                    return .failure(MenuError(code: "APP_MENU_FAILED", message: "Menu item '\(joined)' is disabled."))
                }
                let status = AXUIElementPerformAction(matched, kAXPressAction as CFString)
                guard status == .success else {
                    let joined = resolvedPath.joined(separator: " > ")
                    return .failure(MenuError(code: "APP_MENU_FAILED", message: "Failed to press menu item '\(joined)' (AXError \(status.rawValue))."))
                }
                return .success(resolvedPath)
            }
        }
        return .failure(MenuError(code: "ELEMENT_NOT_FOUND", message: "Menu item not found."))
    }

    private static func matchMenuItem(segment: String, in children: [AXUIElement]) -> AXUIElement? {
        let want = ElementMatcher.normalize(segment)
        guard !want.isEmpty else { return nil }
        var prefixMatch: AXUIElement?
        var containsMatch: AXUIElement?
        for child in children {
            guard let title = copyString(child, attribute: kAXTitleAttribute), !title.isEmpty else { continue }
            let have = ElementMatcher.normalize(title)
            if have == want { return child }
            if prefixMatch == nil && have.hasPrefix(want) { prefixMatch = child }
            if containsMatch == nil && have.contains(want) { containsMatch = child }
        }
        return prefixMatch ?? containsMatch
    }

    private static func matchesQuery(_ normalizedNeedle: String, title: String, path: [String]) -> Bool {
        if ElementMatcher.normalize(title).contains(normalizedNeedle) { return true }
        return ElementMatcher.normalize(path.joined(separator: " ")).contains(normalizedNeedle)
    }

    private static func formatShortcut(for item: AXUIElement) -> String? {
        guard let cmdChar = copyString(item, attribute: kAXMenuItemCmdCharAttribute), !cmdChar.isEmpty else {
            return nil
        }
        let mods = copyInt(item, attribute: kAXMenuItemCmdModifiersAttribute) ?? 0
        var prefix = ""
        if (mods & (1 << 2)) != 0 { prefix += "⌃" }
        if (mods & (1 << 1)) != 0 { prefix += "⌥" }
        if (mods & (1 << 0)) != 0 { prefix += "⇧" }
        if (mods & (1 << 3)) == 0 { prefix += "⌘" }
        return prefix + cmdChar.uppercased()
    }

    private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else {
            return nil
        }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else {
            return []
        }
        return list
    }

    private static func copyString(_ element: AXUIElement, attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func copyBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func copyInt(_ element: AXUIElement, attribute: String) -> Int? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.intValue
    }
}
