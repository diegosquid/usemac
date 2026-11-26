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
    public let localVision = LocalVisionEngine()
    private let actionExecutor: ActionExecutor
    /// Ask mode: sensitive requests waiting for the user's answer in the HUD.
    public let approvals = ApprovalBroker()
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
        auditStore: AuditLogStore? = nil
    ) {
        self.socketPath = socketPath
        self.auditStore = auditStore
        self.auditEntries = auditStore?.recentEntries() ?? []
        let pairingStore = bridgeKeyDirectory.map { BridgePairingStore(directory: $0) } ?? BridgePairingStore()
        self.chromeBridge = ChromeExtensionBridge(port: extensionPort, pairingStore: pairingStore)
        self.actionExecutor = ActionExecutor(
            axIndexer: axIndexer,
            workspaceMonitor: workspaceMonitor,
            killSwitch: killSwitch
        )
        // Stop in the pill on a controlled Chrome tab. The app replaces this with the HUD's Stop (AppState).
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
            var snapshot = axIndexer.observe(
                app: app,
                maxDepth: params.maxDepth ?? 10,
                maxElements: params.maxElements ?? 220,
                useCache: params.useCache ?? true,
                includeDiff: params.includeDiff ?? true,
                accessibilityGranted: perms.accessibilityGranted,
                includeOffscreen: params.includeOffscreen ?? true
            )

            if params.includeScreenshot == true, perms.screenRecordingGranted {
                if let shot = try? await screenCapturer.capture(ScreenshotRequest(app: params.app), targetApp: app) {
                    snapshot.screenshotPath = shot.path
                }
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
            response = .success(id: request.id, latencyMs: latencyMs, snapshot: snapshot)

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
            let (actResult, resolvedApp) = await actionExecutor.executeBatch(
                actReq,
                onOverlayEvent: overlay,
                onLiveActivity: liveActivity
            )
            incrementActionCount(by: actResult.stepResults.count)

            let targetApp = resolvedApp ?? workspaceMonitor.resolveApp(query: actReq.app)
            var observation: WindowSnapshot?
            if actReq.returnObservation, let targetApp {
                let perms = currentPermissions(promptAccessibility: false)
                var snap = axIndexer.observe(
                    app: targetApp,
                    useCache: false,
                    includeDiff: true,
                    accessibilityGranted: perms.accessibilityGranted
                )
                if actReq.returnDiffOnly, snap.diff != nil {
                    snap.elements = []
                }
                if actReq.includeScreenshot, perms.screenRecordingGranted {
                    if let shot = try? await screenCapturer.capture(ScreenshotRequest(app: actReq.app), targetApp: targetApp) {
                        snap.screenshotPath = shot.path
                    }
                }
                observation = snap
            }

            let finalResult = BatchActionResult(
                success: actResult.success,
                totalLatencyMs: actResult.totalLatencyMs,
                stepResults: actResult.stepResults,
                observation: observation
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
            response = .success(id: request.id, latencyMs: latencyMs, snapshot: observation, actionResult: finalResult)

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
                let result = try await screenCapturer.capture(req, targetApp: targetApp)
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
                response = .failure(id: request.id, code: "POLICY_LOCKED", message: message, latencyMs: latencyMs)
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

            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: false) {
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
                    snapshot: bridgeResp.snapshot,
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
            let bridgeResp = await chromeBridge.screenshot(params)
            let latencyMs = elapsedMs(since: startNs)
            let resolvedProfile = bridgeResp.profileName ?? params.profile ?? "Browser"
            let resolvedLabel = "Chrome (\(resolvedProfile))"

            if bridgeResp.ok, let shot = bridgeResp.screenshot {
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
            if blockReason == nil, params.readOnly == true, hasMutating {
                blockReason = "Mutating browser step blocked because readOnly=true was requested (only scroll, hover, wait, and target are permitted)."
            }
            if let blockReason {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: params.profile ?? "Chrome",
                    activityAppName: "Chrome (\(params.profile ?? "Browser"))",
                    activityTitle: "Browser action blocked",
                    reason: blockReason
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
                var noVisualEffectStep: ActionStepType?
                var noVisualEffectDiffPct: Double?
                if let beforeJPEG = beforeFrame?.jpegData,
                   let afterJPEG = afterFrame?.jpegData,
                   beforeFrame?.capturedAt != afterFrame?.capturedAt,
                   let diffPct = LocalVisionEngine.computeFrameDiffPercent(beforeJPEG: beforeJPEG, afterJPEG: afterJPEG),
                   var actionRes = enrichedActionResult,
                   !actionRes.stepResults.isEmpty {
                    let lastActionIdx = actionRes.stepResults.lastIndex(where: { $0.action != .wait }) ?? (actionRes.stepResults.count - 1)
                    actionRes.stepResults[lastActionIdx].visualChangePercent = diffPct
                    let stepAction = actionRes.stepResults[lastActionIdx].action
                    let mechLower = actionRes.stepResults[lastActionIdx].mechanism.lowercased()
                    let isDownloadClick = mechLower.contains("download") || actionRes.stepResults[lastActionIdx].downloadPath != nil
                    // Only flag low visual diff on scroll, or no-effect click/key when URL/DOM/download didn't change
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
                              diffPct < 0.65,
                              !isDownloadClick,
                              !urlChanged,
                              (domUnchanged || diffPct < 0.35),
                              actionRes.stepResults[lastActionIdx].blockedWarning == nil {
                        noVisualEffectStep = stepAction
                        noVisualEffectDiffPct = diffPct
                    }
                    enrichedActionResult = actionRes
                }

                // Two-Way Auto-Visual Reflex: when a scroll stalls, a click/key has no visible effect, or an overlay blocks the page,
                // UseMac immediately diagnoses what happened locally (DOM + Apple Silicon MLX Vision) without needing a cloud screenshot.
                if var actionRes = enrichedActionResult {
                    let blockedStep = actionRes.stepResults.last(where: { $0.blockedWarning != nil })
                    let domOverlay = actionRes.observation?.pageState?.blockingOverlay
                    let mlxReady = localVision.currentStatus().backend == "mlx-vlm"
                    let shouldRunNoEffectReflex = (noVisualEffectStep != nil && mlxReady && params.verify == nil)
                    if blockedStep != nil || domOverlay != nil || shouldRunNoEffectReflex {
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
                        } else if let afterJPEG = afterFrame?.jpegData {
                            let dir = UseMacDefaults.captureDirectory
                            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                            let tmpPath = (dir as NSString).appendingPathComponent("reflex-\(bridgeResp.tabId ?? 0)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                            if (try? afterJPEG.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)) != nil {
                                let reflexContext: String
                                if let blockedWarn = blockedStep?.blockedWarning {
                                    reflexContext = "\(blockedWarn) Find any popup/banner close X button."
                                } else if let noEff = noVisualEffectStep {
                                    let pctStr = String(format: "%.2f%%", noVisualEffectDiffPct ?? 0)
                                    reflexContext = "After \(noEff.rawValue), the screen barely changed (\(pctStr)). Check if there is a red validation error, disabled button, modal, or blocking overlay."
                                } else {
                                    reflexContext = "A popup, banner, or modal may be blocking the page. Find any close X button."
                                }
                                emitLiveActivity(LiveActivityItem(
                                    kind: .observe,
                                    appName: resolvedLabel,
                                    windowTitle: bridgeResp.title,
                                    title: "Checking screen locally…",
                                    subtitle: "local-vision-reflex",
                                    mechanism: "mlx-vlm",
                                    success: true,
                                    isInProgress: true,
                                    browserTabId: bridgeResp.tabId ?? params.tabId,
                                    browserProfile: resolvedProfile
                                ))
                                let vr = await localVision.query(
                                    mode: "diagnose",
                                    query: reflexContext,
                                    imagePath: tmpPath,
                                    viewportWidth: Double(afterFrame?.viewportWidth ?? 1280),
                                    viewportHeight: Double(afterFrame?.viewportHeight ?? 800)
                                )
                                if vr.blockingDetected {
                                    let suggestion: String
                                    if let rx = vr.x, let ry = vr.y {
                                        suggestion = String(format: "Click the detected dismiss/close control at (%.1f, %.1f), then retry.", rx, ry)
                                    } else {
                                        suggestion = "Check the validation error / disabled control or press Escape before retrying."
                                    }
                                    actionRes.agentFeedback = AgentFeedback(
                                        severity: "blocked",
                                        trigger: blockedStep?.action == .scroll
                                            ? "scroll_blocked"
                                            : (noVisualEffectStep != nil ? "action_no_visual_change" : "blocking_overlay"),
                                        diagnosis: "\(blockedStep?.blockedWarning ?? "") \(vr.answer)".trimmingCharacters(in: .whitespaces),
                                        suggestedAction: suggestion,
                                        suggestedX: vr.x,
                                        suggestedY: vr.y,
                                        source: vr.backend,
                                        latencyMs: vr.latencyMs
                                    )
                                } else if let warn = blockedStep?.blockedWarning {
                                    actionRes.agentFeedback = AgentFeedback(
                                        severity: "warning",
                                        trigger: "scroll_blocked",
                                        diagnosis: "\(warn) Local vision saw no popup overlay.",
                                        suggestedAction: "Try scrolling inside a specific inner container or check if you reached the end of the page.",
                                        source: vr.backend,
                                        latencyMs: vr.latencyMs
                                    )
                                } else if let noEff = noVisualEffectStep, !vr.answer.isEmpty {
                                    actionRes.agentFeedback = AgentFeedback(
                                        severity: "info",
                                        trigger: "action_no_visual_change",
                                        diagnosis: String(format: "After %@ (visualDiff=%.2f%%), local vision reports: %@", noEff.rawValue, noVisualEffectDiffPct ?? 0, vr.answer),
                                        suggestedAction: "Use vision_query(mode: 'ask') if you need more visual detail without taking a full screenshot.",
                                        source: vr.backend,
                                        latencyMs: vr.latencyMs
                                    )
                                }
                            }
                        }
                        enrichedActionResult = actionRes
                    }

                    // Optional inline local visual verification (`params.verify`) in one single round-trip (0 cloud image tokens)
                    if let verifyPrompt = params.verify?.trimmingCharacters(in: .whitespacesAndNewlines), !verifyPrompt.isEmpty {
                        emitLiveActivity(LiveActivityItem(
                            kind: .observe,
                            appName: resolvedLabel,
                            windowTitle: bridgeResp.title,
                            title: "Verifying locally…",
                            subtitle: verifyPrompt,
                            mechanism: localVision.currentStatus().backend,
                            success: true,
                            isInProgress: true,
                            browserTabId: bridgeResp.tabId ?? params.tabId,
                            browserProfile: resolvedProfile
                        ))
                        let verifyInput = await resolveVisionInputImage(params: VisionQueryParams(
                            mode: "verify",
                            query: verifyPrompt,
                            profile: resolvedProfile,
                            tabId: bridgeResp.tabId ?? params.tabId
                        ))
                        if let input = verifyInput {
                            let vr = await localVision.query(
                                mode: "verify",
                                query: verifyPrompt,
                                imagePath: input.path,
                                viewportWidth: input.width,
                                viewportHeight: input.height
                            )
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

                if let shot = bridgeResp.screenshot {
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
                    browserTabId: bridgeResp.tabId ?? params.tabId,
                    browserProfile: resolvedProfile
                ))
                response = .success(
                    id: request.id,
                    latencyMs: latencyMs,
                    snapshot: bridgeResp.snapshot ?? enrichedActionResult?.observation,
                    actionResult: enrichedActionResult,
                    screenshot: bridgeResp.screenshot,
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

        case .visionInstall:
            let params = request.visionInstall ?? VisionInstallParams()
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
                response = blockedPolicyResponse(
                    request: request,
                    startNs: startNs,
                    targetApp: "Local Vision",
                    activityTitle: "Vision install blocked",
                    reason: blockReason
                )
                break
            }
            let allowedModels = LocalVisionModelPreset.allCases.map(\.rawValue)
            let trimmedModelId = params.modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let modelId = trimmedModelId, !modelId.isEmpty, !allowedModels.contains(modelId) {
                let latencyMs = elapsedMs(since: startNs)
                let message = "Unknown local vision model. Allowed: \(allowedModels.joined(separator: ", "))"
                appendAudit(
                    method: request.method.rawValue,
                    targetApp: "Local Vision",
                    summary: "Rejected model: \(modelId)",
                    latencyMs: latencyMs,
                    success: false
                )
                emitLiveActivity(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: "Local Vision",
                    title: "Vision install blocked",
                    subtitle: message,
                    latencyMs: latencyMs,
                    success: false,
                    isInProgress: false
                ))
                response = .failure(id: request.id, code: "INVALID_MODEL", message: message, latencyMs: latencyMs)
                break
            }
            let validatedModelId = (trimmedModelId?.isEmpty == false) ? trimmedModelId : params.modelId
            let vStatus = await localVision.install(modelId: validatedModelId, enable: params.enable ?? true)
            let latencyMs = elapsedMs(since: startNs)
            appendAudit(
                method: request.method.rawValue,
                targetApp: "Local Vision",
                summary: "Vision install (\(vStatus.modelId)): \(vStatus.state)",
                latencyMs: latencyMs,
                success: vStatus.lastError == nil
            )
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
            let latencyMs = elapsedMs(since: startNs)
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
            let taskId = taskTabs.start(taskId: params.taskId, agent: params.agent)
            appendAudit(
                method: request.method.rawValue,
                targetApp: targetName,
                summary: summaryText,
                latencyMs: latencyMs,
                success: true,
                taskId: taskId
            )
            emitLiveActivity(LiveActivityItem(
                kind: .taskStart,
                appName: targetName,
                appPid: resolvedApp?.pid,
                bundleId: resolvedProfile != nil ? "com.google.Chrome" : resolvedApp?.bundleId,
                title: summaryText,
                latencyMs: latencyMs,
                success: true,
                isInProgress: true,
                browserTabId: params.tabId,
                browserProfile: resolvedProfile
            ))
            localVision.warmupIfReady()
            response = .success(id: request.id, latencyMs: latencyMs, status: currentStatus(), taskId: taskId)

        case .taskComplete:
            let params = request.taskComplete ?? TaskCompleteParams()
            let latencyMs = elapsedMs(since: startNs)
            // Only this task's tabs close and only its cards are marked done; other running tasks keep theirs.
            let completion = taskTabs.complete(
                taskId: request.namedTaskId, tabId: params.tabId, keepTabIds: Set(params.keepTabIds ?? []), keepTabs: params.keepTabs == true
            )
            let resolvedProfile: String? = {
                if let p = params.profile, !p.isEmpty { return p }
                if params.tabId != nil {
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
                method: request.method.rawValue,
                targetApp: targetName,
                summary: summaryText,
                latencyMs: latencyMs,
                success: true,
                taskId: completion.taskId
            )
            // The tab indicator goes away on this task's tabs (and on tabs kept with keepTabIds).
            chromeBridge.sendTabControlEnded(keepTabIds: Array(completion.protectedTabIds))
            emitLiveActivity(LiveActivityItem(
                kind: .taskComplete,
                appName: targetName,
                appPid: resolvedApp?.pid,
                bundleId: resolvedProfile != nil ? "com.google.Chrome" : resolvedApp?.bundleId,
                title: summaryText,
                latencyMs: latencyMs,
                success: true,
                isInProgress: false,
                browserTabId: params.tabId,
                browserProfile: resolvedProfile,
                taskTabIds: completion.ownTabIds.map { Array($0).sorted() }
            ))
            if params.keepTabs != true {
                // A finished task closes only its own tabs (closeTabIds); with no task, every owned tab as before.
                let ownTabs = completion.taskId != nil ? completion.ownTabIds.map { Array($0).sorted() } : nil
                scheduleOwnedTabCleanup(profile: params.profile, keepTabIds: params.keepTabIds ?? [], closeTabIds: ownTabs)
            }
            response = .success(
                id: request.id, latencyMs: latencyMs, status: currentStatus(), taskId: completion.taskId, taskSummary: completion.summary
            )
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
        if let targetApp = workspaceMonitor.resolveApp(query: nil) {
            foundNode = axIndexer.node(for: elementId, pid: targetApp.pid)
        }
        if foundNode == nil {
            foundNode = axIndexer.node(for: elementId)?.node
        }
        guard let node = foundNode else {
            return nil
        }

        let owner = axIndexer.node(for: elementId)?.pid
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
        reason: String
    ) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(
            method: request.method.rawValue,
            targetApp: targetApp,
            summary: "Blocked: \(reason)",
            latencyMs: latencyMs,
            success: false
        )
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety,
            appName: activityAppName ?? targetApp,
            title: activityTitle,
            subtitle: reason,
            latencyMs: latencyMs,
            success: false,
            isInProgress: false
        ))
        return .failure(id: request.id, code: "POLICY_BLOCKED", message: reason, latencyMs: latencyMs)
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
        case .target, .scroll, .hover, .wait, .scrollIntoView, .waitFor:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile, .axAction:
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
}
