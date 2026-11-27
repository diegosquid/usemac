import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

public final class UseMacEngineService: UseMacServiceProtocol, @unchecked Sendable {
    private let socketPath: String
    let permissionManager = PermissionManager()
    let killSwitch = KillSwitch()
    let workspaceMonitor: WorkspaceMonitor
    let resolveNativeTarget: @Sendable (String?) -> AppQueryMatch
    /// Which running task owns which Chrome tabs UseMac opened (see TaskTabRegistry).
    let taskTabs = TaskTabRegistry()
    let axIndexer = AXIndexer()
    let screenCapturer = FastScreenCapturer()
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

    let stateLock = NSLock()
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
    var lastScreenshotJPEGByTarget: [String: Data] = [:]
    var lastScreenshotKeyOrder: [String] = []
    /// Last OCR-fused `@vN` element nodes per app PID (bound to windowId + AX generation) so native `act` can target them safely.
    struct OCRSnapshotRecord {
        let windowId: UInt32?
        let generation: UInt64
        let nodes: [String: ElementNode]
    }
    var ocrNodesByPid: [Int32: OCRSnapshotRecord] = [:]
    /// Delay before closing a completed task's owned Chrome tabs (1.8 s in production; overridable in tests).
    internal var ownedTabCleanupDelayNs: UInt64 = 1_800_000_000
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

    public convenience init(
        socketPath: String = UseMacDefaults.defaultSocketPath,
        extensionPort: UInt16 = UseMacDefaults.defaultExtensionPort,
        bridgeKeyDirectory: URL? = nil,
        auditStore: AuditLogStore? = nil,
        skillStore: SkillStore = SkillStore()
    ) {
        self.init(
            observeTargetResolver: nil,
            socketPath: socketPath,
            extensionPort: extensionPort,
            bridgeKeyDirectory: bridgeKeyDirectory,
            auditStore: auditStore,
            skillStore: skillStore
        )
    }

    init(
        observeTargetResolver: (@Sendable (String?) -> AppQueryMatch)?,
        socketPath: String = UseMacDefaults.defaultSocketPath,
        extensionPort: UInt16 = UseMacDefaults.defaultExtensionPort,
        bridgeKeyDirectory: URL? = nil,
        auditStore: AuditLogStore? = nil,
        skillStore: SkillStore = SkillStore()
    ) {
        self.socketPath = socketPath
        let workspaceMonitor = WorkspaceMonitor()
        self.workspaceMonitor = workspaceMonitor
        self.resolveNativeTarget = observeTargetResolver ?? { workspaceMonitor.resolveTarget(query: $0) }
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
        self.chromeBridge.setOwnedTabIdsProvider { [taskTabs] key in
            taskTabs.ownedTabIds(forProfile: key)
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
            response = await handleNativeObserve(request, startNs: startNs)

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
            if actHasMutating, let readOnly = TargetRulesStore.shared.readOnlyMessage(forQueries: [actReq.app] + actReq.steps.map(\.app), in: workspaceMonitor) {
                response = targetReadOnlyResponse(request: request, startNs: startNs, targetApp: actReq.app, activityTitle: "Action blocked", message: readOnly)
                break
            }
            let initialApp = workspaceMonitor.resolveApp(query: actReq.app)
            if let blocked = await nativeActionSiteRefusal(actReq, defaultApp: initialApp, isMutating: actHasMutating, request: request, startNs: startNs) {
                response = blocked
                break
            }

            if let refusal = await approvalRefusal(for: request, startNs: startNs) {
                response = refusal
                break
            }

            // Neither the app nor its active browser tab is guaranteed to survive an approval prompt unchanged.
            let preResolvedApp = workspaceMonitor.resolveApp(query: actReq.app)
            if actHasMutating, let readOnly = TargetRulesStore.shared.readOnlyMessage(forQueries: [actReq.app] + actReq.steps.map(\.app), in: workspaceMonitor) {
                response = targetReadOnlyResponse(request: request, startNs: startNs, targetApp: actReq.app, activityTitle: "Action blocked", message: readOnly)
                break
            }
            if let blocked = await nativeActionSiteRefusal(actReq, defaultApp: preResolvedApp, isMutating: actHasMutating, request: request, startNs: startNs) {
                response = blocked
                break
            }

            let overlay = onOverlayEvent
            // Work on a guessed target (no app named, none paired: the app in front) is marked so the live preview
            // never shows the user's own app.
            let targetGuessed = workspaceMonitor.isGuessedTarget(requestApp: actReq.app, stepApps: actReq.steps.map(\.app))
            let forward = onLiveActivity
            let taskId = TaskActivityContext.taskId ?? request.namedTaskId
            let liveActivity: @Sendable (LiveActivityItem) -> Void = { [taskTabs] item in
                if item.kind == .actionStep, let pid = item.appPid {
                    taskTabs.recordApp(pid, taskId: taskId)
                }
                var activity = item
                if targetGuessed { activity.targetGuessed = true }
                forward?(activity)
            }

            // Resolve any `@vN` OCR-fused element references strictly against the effective step app, window, and generation.
            let effectiveActReq = resolveOCRElementTargets(in: actReq, defaultApp: preResolvedApp)

            let actPerms = currentPermissions(promptAccessibility: false)
            let beforeNativeCG: CGImage? = {
                nil
            }()
            var capturedBeforeCG = beforeNativeCG
            if actReq.diffCrop == true, actPerms.screenRecordingGranted, let preApp = preResolvedApp {
                capturedBeforeCG = await withActionWindow(actReq.window, app: preApp) { app in
                    await screenCapturer.capturePreviewCGImage(
                        targetApp: app,
                        maxDimension: 1280,
                        streamer: liveStreamer
                    )?.image
                }
            }

            let (actResult, resolvedApp) = await actionExecutor.executeBatch(
                effectiveActReq,
                onOverlayEvent: overlay,
                onLiveActivity: liveActivity,
                preResolvedTarget: preResolvedApp,
                siteRuleGuard: { [chromeBridge] app in
                    await NativeBrowserSiteRules.blockedMessage(for: app, chromeBridge: chromeBridge)
                }
            )
            incrementActionCount(by: actResult.stepResults.count)

            let targetApp = resolvedApp ?? preResolvedApp ?? workspaceMonitor.resolveApp(query: actReq.app)
            if let pid = targetApp?.pid {
                taskTabs.recordApp(pid, taskId: taskId)
            }
            if actHasMutating {
                if let mutatedPid = targetApp?.pid ?? preResolvedApp?.pid {
                    invalidateOCRNodes(forPid: mutatedPid)
                }
                for stepApp in actReq.steps.compactMap(\.app) {
                    if let stepPid = workspaceMonitor.resolveApp(query: stepApp)?.pid {
                        invalidateOCRNodes(forPid: stepPid)
                    }
                }
            }

            // A step can navigate into a denied site. Keep step outcomes, but never read the resulting page.
            let executedSteps = BatchActionResult(
                success: actResult.success,
                totalLatencyMs: actResult.totalLatencyMs,
                stepResults: actResult.stepResults
            )
            if let blockedStep = actResult.stepResults.first(where: { $0.errorCode == TargetRules.errorCode }) {
                response = targetBlockedResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: targetApp?.name ?? actReq.app,
                    activityTitle: "Action blocked",
                    message: blockedStep.message ?? "The action target is blocked by the app and site rules.",
                    actionResult: executedSteps
                )
                break
            }
            if let blocked = await nativeActionSiteRefusal(
                actReq,
                defaultApp: preResolvedApp,
                finalApp: targetApp,
                request: request,
                startNs: startNs,
                actionResult: executedSteps
            ) {
                response = blocked
                break
            }
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
                // Always capture fresh post-action pixels (do not reuse `liveStreamer`, which may lag behind the just-completed action).
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
                targetGuessed: targetGuessed ? true : nil,
                windowId: activityApp?.windowId ?? targetApp?.windowId,
                isRestrictedPageFallback: nativeRestrictedPageFlag(for: activityApp)
            ))
            response = .success(id: request.id, latencyMs: latencyMs, snapshot: observation, actionResult: finalResult, screenshot: actionScreenshot)

        case .screenshot:
            response = await handleNativeScreenshot(request, startNs: startNs)

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
            switch await performCachedHighlight(elementId, durationMs: durationMs) {
            case .highlighted(let rect):
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
            case .blocked(let message):
                response = targetBlockedResponse(request: request, startNs: startNs, targetApp: nil, activityTitle: "Highlight blocked", message: message)
            case .notFound:
                let latencyMs = elapsedMs(since: startNs)
                response = .failure(id: request.id, code: "ELEMENT_NOT_FOUND", message: "Cached element \(elementId) not found", latencyMs: latencyMs)
            }

        case .browserStatus:
            response = handleBrowserStatus(request, startNs: startNs)

        case .browserReloadExtension:
            response = await handleBrowserReloadExtension(request, startNs: startNs)

        case .browserTabs:
            response = await handleBrowserTabs(request, startNs: startNs)

        case .browserOpen:
            response = await handleBrowserOpen(request, startNs: startNs)

        case .browserObserve:
            response = await handleBrowserObserve(request, startNs: startNs)

        case .browserExtract:
            response = await handleBrowserExtract(request, startNs: startNs)

        case .browserScreenshot:
            response = await handleBrowserScreenshot(request, startNs: startNs)

        case .browserAct:
            response = await handleBrowserAct(request, startNs: startNs)

        case .visionStatus:
            response = handleVisionStatus(request, startNs: startNs)

        case .visionQuery:
            response = await handleVisionQuery(request, startNs: startNs)

        case .taskStart:
            var params = request.taskStart ?? TaskStartParams()
            if params.agent == nil { params.agent = request.agent }
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

    private func nativeActionSiteRefusal(
        _ act: BatchActionRequest,
        defaultApp: AppDescriptor?,
        finalApp: AppDescriptor? = nil,
        isMutating: Bool = false,
        request: RPCRequest,
        startNs: UInt64,
        actionResult: BatchActionResult? = nil
    ) async -> RPCResponse? {
        let rules = TargetRulesStore.shared.rules
        guard isMutating ? rules.hasGovernedSiteRules : rules.hasSiteRules else { return nil }

        var apps: [AppDescriptor] = []
        // Even a batch with only explicit step apps can borrow the default window or read it back.
        if let defaultApp, act.foreground == true || act.diffCrop == true || act.returnObservation
            || act.includeScreenshot || act.returnImageContent == true || act.verify?.isEmpty == false
            || act.steps.contains(where: { $0.app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }) {
            apps.append(defaultApp)
        }
        var stepQueries = Set<String>()
        for step in act.steps {
            let query = step.app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A target step without an app can switch to the workspace fallback, not just the current step app.
            guard (!query.isEmpty || step.action == .target), stepQueries.insert(query).inserted,
                  let app = workspaceMonitor.resolveApp(query: query) else { continue }
            apps.append(app)
        }

        var checkedPids = Set<Int32>()
        for app in apps where NativeBrowserSiteRules.isChromiumApp(bundleId: app.bundleId, name: app.name) {
            guard checkedPids.insert(app.pid).inserted else { continue }
            let window = app.pid == defaultApp?.pid ? act.window : nil
            if isMutating {
                let refusal = await withActionWindow(window, app: app) { target in
                    let currentTarget = finalApp != nil && window == nil
                        ? currentNativeWindow(for: target, titleFallback: target.windowTitle)
                        : target
                    return await NativeBrowserSiteRules.mutatingPolicyRefusal(for: currentTarget, rules: rules, chromeBridge: chromeBridge)
                }
                if let refusal {
                    if refusal.code == "POLICY_BLOCKED" {
                        return targetReadOnlyResponse(
                            request: request, startNs: startNs, targetApp: app.name, activityTitle: "Action blocked",
                            message: refusal.message, actionResult: actionResult
                        )
                    }
                    return targetBlockedResponse(
                        request: request, startNs: startNs, targetApp: app.name, activityTitle: "Action blocked",
                        message: refusal.message, actionResult: actionResult
                    )
                }
            } else {
                let blocked = await withActionWindow(window, app: app) { target in
                    let currentTarget = finalApp != nil && window == nil
                        ? currentNativeWindow(for: target, titleFallback: target.windowTitle)
                        : target
                    return await NativeBrowserSiteRules.blockedMessage(for: currentTarget, rules: rules, chromeBridge: chromeBridge)
                }
                if let blocked {
                    return targetBlockedResponse(
                        request: request, startNs: startNs, targetApp: app.name, activityTitle: "Action blocked",
                        message: blocked, actionResult: actionResult
                    )
                }
            }
        }

        // Check the app used for the return artifacts last, after any bridge lookups for the other apps.
        if let finalApp,
           let blocked = await NativeBrowserSiteRules.blockedMessage(for: finalApp, rules: rules, chromeBridge: chromeBridge) {
            return targetBlockedResponse(
                request: request, startNs: startNs, targetApp: finalApp.name, activityTitle: "Action blocked",
                message: blocked, actionResult: actionResult
            )
        }
        return nil
    }

    func nativeRestrictedPageFlag(for app: AppDescriptor?) -> Bool? {
        guard let app, NativeBrowserSiteRules.isChromiumApp(bundleId: app.bundleId, name: app.name) else {
            return nil
        }
        let url = NativeBrowserSiteRules.axWebAreaURL(pid: app.pid, windowTitle: app.windowTitle)
        return NativeBrowserSiteRules.isRestrictedBrowserURL(url)
    }

    /// Resolves an explicit window (or the key window for an empty title) without changing the live task pin.
    func withActionWindow<T>(_ window: String?, app: AppDescriptor, operation: (AppDescriptor) async -> T) async -> T {
        guard let window else { return await operation(app) }
        let temporaryScope = UUID().uuidString
        defer { WindowResolver.clearPins(forTaskId: temporaryScope) }
        return await TaskActivityContext.$taskId.withValue(temporaryScope) {
            WindowResolver.pin(pid: app.pid, title: window)
            return await operation(currentNativeWindow(for: app, titleFallback: window))
        }
    }

    func currentNativeWindow(for app: AppDescriptor, titleFallback: String? = nil) -> AppDescriptor {
        var target = app
        target.windowId = nil
        target.windowBounds = nil
        let title = titleFallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        target.windowTitle = title?.isEmpty == false ? title : nil
        if let element = WindowResolver.focusedWindow(pid: app.pid)?.element {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
               let actualTitle = value as? String, !actualTitle.isEmpty {
                target.windowTitle = actualTitle
            }
        }
        return WorkspaceMonitor.withTargetWindow(target)
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
        return await screenCapturer.capturePreviewCGImage(targetApp: app, maxDimension: maxDimension, streamer: liveStreamer)
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

    enum CachedHighlightResult {
        case highlighted(ScreenRect)
        case blocked(String)
        case notFound
    }

    @discardableResult
    public func highlightCachedElement(_ elementId: String, durationMs: Int = 1500) async -> ScreenRect? {
        guard case .highlighted(let rect) = await performCachedHighlight(elementId, durationMs: durationMs) else { return nil }
        return rect
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

    func blockedPolicyResponse(
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
    func targetBlockedResponse(
        request: RPCRequest,
        startNs: UInt64,
        targetApp: String?,
        activityTitle: String,
        message: String,
        actionResult: BatchActionResult? = nil
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
        var response = RPCResponse.failure(id: request.id, code: TargetRules.errorCode, message: message, latencyMs: latencyMs)
        response.actionResult = actionResult
        return response
    }

    /// Refusal for a mutating request whose target has a Read-only app or site rule (`TargetRules`).
    func targetReadOnlyResponse(
        request: RPCRequest,
        startNs: UInt64,
        targetApp: String?,
        activityTitle: String,
        message: String,
        actionResult: BatchActionResult? = nil
    ) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(
            method: request.method.rawValue,
            targetApp: targetApp,
            summary: "Blocked by Read-only app/site rule",
            latencyMs: latencyMs,
            success: false
        )
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            appName: targetApp,
            title: activityTitle,
            subtitle: message,
            latencyMs: latencyMs,
            success: false,
            isInProgress: false
        ))
        var response = RPCResponse.failure(id: request.id, code: "POLICY_BLOCKED", message: message, latencyMs: latencyMs, hint: TargetRules.stopHint)
        response.actionResult = actionResult
        return response
    }

    /// Refusal for a request that names UseMac itself: agents never observe or act on its own windows.
    func selfTargetResponse(
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

    func isMutatingStepForPolicy(_ step: ActionStep) -> Bool {
        switch step.action {
        case .target, .scroll, .hover, .wait, .scrollIntoView, .waitFor, .assert, .scrollUntil:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile, .axAction, .fillForm, .menuAction, .drag, .saveFile:
            return true
        }
    }

    func isSensitiveStepForPolicy(_ step: ActionStep) -> Bool {
        if step.action == .uploadFile || step.action == .saveFile {
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

    func incrementActionCount(by count: Int) {
        stateLock.lock()
        totalActions += count
        stateLock.unlock()
    }

    func elapsedMs(since startNs: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
    }

    func recordObserveMetrics(latencyMs: Double, fromHotCache: Bool) {
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
        taskId: String? = nil,
        agent: String? = nil
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
            taskId: taskId ?? taskTabs.resolve(taskId: hint?.taskId, tabId: hint?.tabId),
            agent: TaskTabRegistry.cleanAgent(agent ?? TaskActivityContext.agentName ?? request?.taskStart?.agent ?? request?.agent)
        )

        stateLock.lock()
        auditEntries.append(entry)
        if auditEntries.count > 500 {
            auditEntries.removeFirst(auditEntries.count - 500)
        }
        stateLock.unlock()
        auditStore?.append(entry)
    }

    func emitLiveActivity(_ item: LiveActivityItem) {
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
        if let pid = resolvedApp?.pid {
            taskTabs.recordApp(pid, taskId: taskId)
        }
        let agent = TaskActivityContext.agentName ?? taskTabs.agent(of: taskId)
        appendAudit(
            method: RPCMethod.taskStart.rawValue,
            targetApp: targetName,
            summary: summaryText,
            latencyMs: 0,
            success: true,
            taskId: taskId,
            agent: agent
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
            agentName: agent,
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
        WindowResolver.clearPins(forTaskId: completion.taskId)
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
            taskAppPids: completion.ownAppPids.map { Array($0).sorted() },
            taskId: completion.taskId
        ))
        if params.keepTabs != true, completion.taskId == nil || completion.ownTabIds?.isEmpty != true {
            let ownTabs = completion.taskId != nil ? completion.ownTabIds.map { Array($0).sorted() } : nil
            scheduleOwnedTabCleanup(profile: params.profile ?? fallbackProfile, keepTabIds: params.keepTabIds ?? [], closeTabIds: ownTabs)
        }
        return completion
    }
}
