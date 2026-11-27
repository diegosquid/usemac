import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

public final class ActionExecutor: @unchecked Sendable {
    let axIndexer: AXIndexer
    let workspaceMonitor: WorkspaceMonitor
    let killSwitch: KillSwitch

    /// When UseMac itself last posted real (HID) input, so its own events are not mistaken for the user's.
    let syntheticInputLock = NSLock()
    var lastSyntheticInputAt: Date = .distantPast

    /// The user must have been idle this long before a foreground burst may take the screen.
    static let userIdleRequiredSeconds: Double = 1.5
    /// How long UseMac watches for a reaction after an action before reporting `effect: none`.
    static let effectWindowMs: UInt64 = 350

    public init(
        axIndexer: AXIndexer,
        workspaceMonitor: WorkspaceMonitor,
        killSwitch: KillSwitch
    ) {
        self.axIndexer = axIndexer
        self.workspaceMonitor = workspaceMonitor
        self.killSwitch = killSwitch
    }

    /// Error codes that represent hard safety/policy blocks and must never be bypassed by `optional: true`.
    private static let nonSkippableErrorCodes: Set<String> = [
        "POLICY_BLOCKED",
        "SELF_TARGET_BLOCKED",
        "TARGET_BLOCKED",
        "UPLOAD_BLOCKED",
        "URL_BLOCKED"
    ]

    public func executeBatch(
        _ request: BatchActionRequest,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)? = nil,
        onLiveActivity: (@Sendable (LiveActivityItem) -> Void)? = nil,
        preResolvedTarget: AppDescriptor? = nil,
        siteRuleGuard: (@Sendable (AppDescriptor) async -> String?)? = nil
    ) async -> (result: BatchActionResult, resolvedApp: AppDescriptor?) {
        let batchStartNs = DispatchTime.now().uptimeNanoseconds
        let requestTarget: AppQueryMatch
        if let preResolvedTarget {
            if workspaceMonitor.isUseMacProcess(pid: preResolvedTarget.pid)
                || WorkspaceMonitor.isUseMac(
                    pid: preResolvedTarget.pid,
                    bundleId: preResolvedTarget.bundleId,
                    selfPid: ProcessInfo.processInfo.processIdentifier
                )
                || workspaceMonitor.namesUseMac(request.app) {
                requestTarget = .useMac
            } else {
                requestTarget = .app(preResolvedTarget)
            }
        } else {
            requestTarget = workspaceMonitor.resolveTarget(query: request.app)
        }
        var currentApp: AppDescriptor?
        if case .app(let app) = requestTarget {
            currentApp = app
        }
        if let window = request.window, let app = currentApp {
            WindowResolver.pin(pid: app.pid, title: window)
            currentApp = WorkspaceMonitor.withTargetWindow(app)
        }
        var stepResults: [ActionStepResult] = []
        stepResults.reserveCapacity(request.steps.count)

        let bannerAppName = currentApp?.name ?? request.app ?? "Desktop"
        onOverlayEvent?(.agentBanner(
            appName: bannerAppName,
            message: "Executing \(request.steps.count) action(s)...",
            active: true
        ))

        onLiveActivity?(LiveActivityItem(
            kind: .actionStart,
            appName: currentApp?.name,
            appPid: currentApp?.pid,
            bundleId: currentApp?.bundleId,
            windowTitle: currentApp?.windowTitle,
            windowBounds: currentApp?.windowBounds,
            title: "Running \(request.steps.count) step\(request.steps.count == 1 ? "" : "s")…",
            isInProgress: true,
            windowId: currentApp?.windowId
        ))

        defer {
            onOverlayEvent?(.agentBanner(appName: bannerAppName, message: "Idle", active: false))
        }

        func finish(_ success: Bool) -> (result: BatchActionResult, resolvedApp: AppDescriptor?) {
            let totalLatencyMs = Double(DispatchTime.now().uptimeNanoseconds - batchStartNs) / 1_000_000.0
            return (
                BatchActionResult(success: success, totalLatencyMs: totalLatencyMs, stepResults: stepResults, observation: nil),
                currentApp
            )
        }

        // Preconditions run before anything is sent, so a refused batch never half-runs.
        // UseMac's own windows are never a target: a batch or step that names UseMac does not run at all.
        let batchNamesUseMac = requestTarget == .useMac
            || request.steps.contains(where: { workspaceMonitor.namesUseMac($0.app) })
        let selfTargetRefusal: Refusal? = batchNamesUseMac
            ? Refusal(mechanism: "self-target", errorCode: "SELF_TARGET_BLOCKED", message: WorkspaceMonitor.selfTargetMessage)
            : nil
        if let refusal = selfTargetRefusal ?? preflightRefusal(request, targetApp: currentApp) {
            stepResults.append(ActionStepResult(
                index: 0,
                action: request.steps.first?.action ?? .wait,
                success: false,
                mechanism: refusal.mechanism,
                latencyMs: 0,
                message: refusal.message,
                errorCode: refusal.errorCode
            ))
            onLiveActivity?(LiveActivityItem(
                kind: .policyOrSafety,
                appName: currentApp?.name,
                appPid: currentApp?.pid,
                bundleId: currentApp?.bundleId,
                windowTitle: currentApp?.windowTitle,
                windowBounds: currentApp?.windowBounds,
                title: ActivityCaption.refusedBatchTitle(stepCount: request.steps.count),
                subtitle: ActivityCaption.reason(errorCode: refusal.errorCode, message: refusal.message) ?? refusal.message,
                mechanism: refusal.mechanism,
                latencyMs: 0,
                success: false,
                isInProgress: false,
                windowId: currentApp?.windowId
            ))
            return finish(false)
        }

        var burst: ForegroundBurst?
        if request.foreground == true {
            switch await beginForegroundBurst(targetApp: currentApp, waitForIdleMs: request.waitForIdleMs) {
            case .success(let started):
                burst = started
                onLiveActivity?(LiveActivityItem(
                    kind: .actionStep,
                    appName: currentApp?.name,
                    appPid: currentApp?.pid,
                    bundleId: currentApp?.bundleId,
                    windowTitle: currentApp?.windowTitle,
                    windowBounds: currentApp?.windowBounds,
                    title: "Borrowing the screen",
                    subtitle: "\(currentApp?.name ?? "The app") is in front for a moment",
                    mechanism: "foreground-burst",
                    success: true,
                    isInProgress: true,
                    windowId: currentApp?.windowId
                ))
            case .failure(let refusal):
                stepResults.append(ActionStepResult(
                    index: 0,
                    action: request.steps.first?.action ?? .wait,
                    success: false,
                    mechanism: refusal.mechanism,
                    latencyMs: 0,
                    message: refusal.message,
                    errorCode: refusal.errorCode
                ))
                return finish(false)
            }
        }

        let lastEffectIndex = request.steps.lastIndex(where: { Self.checksEffect($0.action) })
        var allSucceeded = true
        var hadMutatingSuccess = false

        func runStep(_ step: ActionStep, measureEffect: Bool) async -> StepOutcome {
            if let siteRuleGuard, let target = currentApp, isChromiumApp(target) {
                let effectiveStepApp = WorkspaceMonitor.withTargetWindow(target)
                currentApp = effectiveStepApp
                if let message = await siteRuleGuard(effectiveStepApp) {
                    return StepOutcome(success: false, mechanism: "target-rules", message: message, errorCode: TargetRules.errorCode)
                }
            }
            return await executeStep(
                step,
                targetApp: currentApp,
                measureEffect: measureEffect,
                onOverlayEvent: onOverlayEvent,
                siteRuleGuard: siteRuleGuard
            )
        }

        for (index, step) in request.steps.enumerated() {
            if let blockReason = killSwitch.isBlocked(
                forSensitiveAction: isSensitiveStep(step),
                isMutatingAction: isMutatingStep(step)
            ) {
                allSucceeded = false
                // Usually the mode, a pause or the Emergency stop changed while the batch ran (the engine refuses a
                // blocked batch up front). A step result has no hint field, so its message says what to do next.
                let policy = killSwitch.policy
                let tripped = killSwitch.isTripped
                let hint = ExecutionModeNotice.agentHint(policy: policy, killSwitchTripped: tripped)
                stepResults.append(ActionStepResult(
                    index: index,
                    action: step.action,
                    success: false,
                    mechanism: "blocked",
                    latencyMs: 0,
                    message: hint.map { "\(blockReason) \($0)" } ?? blockReason,
                    errorCode: "POLICY_BLOCKED"
                ))
                onLiveActivity?(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: currentApp?.name,
                    appPid: currentApp?.pid,
                    bundleId: currentApp?.bundleId,
                    windowTitle: currentApp?.windowTitle,
                    windowBounds: currentApp?.windowBounds,
                    title: ActivityCaption.failedStepTitle(step: step, position: (index + 1, request.steps.count)),
                    subtitle: ExecutionModeNotice.activityReason(policy: policy, killSwitchTripped: tripped)
                        ?? ActivityCaption.reason(errorCode: "POLICY_BLOCKED"),
                    elementId: step.elementId,
                    mechanism: "blocked",
                    latencyMs: 0,
                    success: false,
                    isInProgress: false,
                    windowId: currentApp?.windowId
                ))
                if request.stopOnError {
                    break
                }
                continue
            }

            if let stepAppQuery = step.app, !stepAppQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentApp = workspaceMonitor.resolveApp(query: stepAppQuery)
            }

            // Skip redundant measureEffect waits on non-gating intermediate steps in multi-step batches.
            let nextStep = (index + 1 < request.steps.count) ? request.steps[index + 1] : nil
            let nextIsGating = nextStep.map { next in
                next.action == .waitFor || next.action == .assert || next.action == .uploadFile
                    || !(next.app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            } ?? false
            let shouldMeasureEffect = request.steps.count == 1
                || index == lastEffectIndex
                || nextIsGating
                || request.foregroundFallback == true

            let stepStartNs = DispatchTime.now().uptimeNanoseconds
            var outcome: StepOutcome
            if let burst, let pid = currentApp?.pid, pid == burst.targetPid, !WindowResolver.isFrontmost(pid: pid) {
                // The user (or another app) took the front during the burst: stop sending real input.
                outcome = notFrontmostOutcome(targetApp: currentApp, input: "input")
            } else {
                outcome = await runStep(step, measureEffect: shouldMeasureEffect)
            }

            // Opt-in foregroundFallback: escalate inside the same batch ONLY when background input was
            // demonstrably NOT delivered (e.g. TARGET_NOT_FRONTMOST). Never replay an already-sent
            // click/type/shortcut/upload solely because AX observed no visible change; instead mark
            // the effect as unverified so callers never suffer duplicate submissions or double typing.
            if request.foregroundFallback == true,
               request.foreground != true,
               burst == nil,
               let target = currentApp,
               target.pid > 0 {
                if Self.shouldEscalateToForeground(outcome) {
                    switch await beginForegroundBurst(targetApp: target, waitForIdleMs: request.waitForIdleMs) {
                    case .success(let started):
                        burst = started
                        onLiveActivity?(LiveActivityItem(
                            kind: .actionStep,
                            appName: target.name,
                            appPid: target.pid,
                            bundleId: target.bundleId,
                            windowTitle: target.windowTitle,
                            windowBounds: target.windowBounds,
                            title: "Borrowing the screen",
                            subtitle: "\(target.name) needed focus for this step",
                            mechanism: "foreground-fallback",
                            success: true,
                            isInProgress: true,
                            windowId: target.windowId
                        ))
                        var fgStep = step
                        fgStep.preferBackground = false
                        if step.action == .saveFile, outcome.mechanism == "nssavepanel-background" {
                            // The trigger already opened the save panel. Resume there instead of
                            // clicking it again (the dialog may now be covering the original button).
                            fgStep.elementId = nil
                            fgStep.match = nil
                            fgStep.x = nil
                            fgStep.y = nil
                        }
                        outcome = await runStep(fgStep, measureEffect: true)
                    case .failure(let refusal):
                        outcome.message = "\(outcome.message ?? "Background action failed.") Foreground fallback unavailable: \(refusal.message)"
                    }
                } else if outcome.success && outcome.effect == ActionEffect.none && outcome.mechanism != "ax-scrollbar" {
                    outcome.effect = .unverified
                    let baseWarn = outcome.warning ?? "Background input was sent, but AX did not observe a UI change."
                    outcome.warning = "\(baseWarn) Skipped foreground replay to avoid executing the action twice."
                }
            }

            // Resilient `optional: true`: convert non-safety failures into skipped successes so batch continues.
            if step.optional == true, !outcome.success {
                let isSafetyBlock = outcome.errorCode.map { Self.nonSkippableErrorCodes.contains($0) } ?? false
                if !isSafetyBlock {
                    let reason = outcome.message ?? outcome.errorCode ?? "target unavailable"
                    outcome = StepOutcome(
                        success: true,
                        mechanism: outcome.mechanism,
                        message: "Optional step skipped: \(reason)",
                        node: outcome.node,
                        resolvedApp: outcome.resolvedApp,
                        errorCode: nil,
                        effect: .unverified,
                        warning: nil,
                        scrollDeltaY: outcome.scrollDeltaY,
                        skipped: true
                    )
                }
            }

            let stepLatencyMs = Double(DispatchTime.now().uptimeNanoseconds - stepStartNs) / 1_000_000.0

            if let resolvedApp = outcome.resolvedApp {
                currentApp = resolvedApp
            }

            if !outcome.skipped,
               step.action != .wait && step.action != .target && step.action != .hover && step.action != .waitFor && step.action != .assert {
                axIndexer.invalidate(pid: currentApp?.pid)
                if outcome.success && isMutatingStep(step) {
                    hadMutatingSuccess = true
                }
            }

            let result = ActionStepResult(
                index: index,
                action: step.action,
                success: outcome.success,
                mechanism: outcome.mechanism,
                latencyMs: stepLatencyMs,
                message: outcome.message,
                scrollDeltaY: outcome.scrollDeltaY,
                errorCode: outcome.errorCode,
                effect: outcome.effect,
                warning: outcome.warning,
                resolvedElementId: outcome.node?.id,
                skipped: outcome.skipped ? true : nil
            )
            stepResults.append(result)

            // A failed step says what UseMac couldn't do and why, in plain words (ActivityCaption).
            let stepTitle = outcome.success
                ? formatStepTitle(step: step, node: outcome.node, app: currentApp)
                : ActivityCaption.failedStepTitle(step: step, targetName: outcome.node?.title, position: (index + 1, request.steps.count))
            let baseSubtitle = "\(outcome.mechanism) · \(String(format: "%.1f ms", stepLatencyMs))"
            let stepSubtitle: String
            if outcome.skipped {
                stepSubtitle = "skipped (optional)"
            } else if !outcome.success, let reason = ActivityCaption.reason(errorCode: outcome.errorCode, message: outcome.message) {
                stepSubtitle = reason
            } else if !outcome.success, let msg = outcome.message, !msg.isEmpty {
                stepSubtitle = "\(baseSubtitle) · \(msg)"
            } else if outcome.effect == ActionEffect.none {
                stepSubtitle = "\(baseSubtitle) · no visible effect"
            } else {
                stepSubtitle = baseSubtitle
            }

            onLiveActivity?(LiveActivityItem(
                kind: .actionStep,
                appName: currentApp?.name,
                appPid: currentApp?.pid,
                bundleId: currentApp?.bundleId,
                windowTitle: currentApp?.windowTitle,
                windowBounds: currentApp?.windowBounds,
                title: stepTitle,
                subtitle: stepSubtitle,
                elementId: outcome.node?.id ?? step.elementId,
                elementFrame: outcome.node?.frame,
                mechanism: outcome.mechanism,
                latencyMs: stepLatencyMs,
                success: outcome.success,
                isInProgress: true,
                windowId: currentApp?.windowId
            ))

            if !outcome.success {
                allSucceeded = false
                if request.stopOnError {
                    break
                }
            }
        }

        // Post-batch quiescence settle (80 ms quiet window, 300 ms cap) before post-action observation.
        if hadMutatingSuccess,
           request.returnObservation,
           let pid = currentApp?.pid,
           pid > 0,
           axIndexer.hasObserver(for: pid) {
            await settleQuiescence(pid: pid, quietWindowMs: 80, maxWaitMs: 300)
        }

        if let burst {
            await endForegroundBurst(burst)
        }

        return finish(allSucceeded)
    }

    private func settleQuiescence(pid: pid_t, quietWindowMs: Int = 80, maxWaitMs: Int = 300) async {
        let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, maxWaitMs)) * 1_000_000
        while true {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= deadlineNs { break }
            let remainingMs = Int((deadlineNs - nowNs) / 1_000_000)
            let windowMs = min(quietWindowMs, remainingMs)
            guard windowMs > 0 else { break }
            let gen = axIndexer.currentGeneration(pid: pid)
            let changed = await axIndexer.waitForChange(pid: pid, sinceGeneration: gen, timeoutMs: windowMs)
            if !changed {
                break
            }
        }
    }

    private static func shouldEscalateToForeground(_ outcome: StepOutcome) -> Bool {
        // Only escalate when input was demonstrably NOT sent. Replaying a succeeded click,
        // typing, shortcut, or upload because AX saw no change risks duplicate side effects.
        guard !outcome.success else {
            return false
        }
        return outcome.errorCode == "TARGET_NOT_FRONTMOST"
    }

    struct StepOutcome {
        var success: Bool
        var mechanism: String
        var message: String?
        var node: ElementNode?
        var resolvedApp: AppDescriptor?
        var errorCode: String?
        var effect: ActionEffect?
        var warning: String?
        var scrollDeltaY: Double?
        var skipped: Bool

        init(
            success: Bool,
            mechanism: String,
            message: String? = nil,
            node: ElementNode? = nil,
            resolvedApp: AppDescriptor? = nil,
            errorCode: String? = nil,
            effect: ActionEffect? = nil,
            warning: String? = nil,
            scrollDeltaY: Double? = nil,
            skipped: Bool = false
        ) {
            self.success = success
            self.mechanism = mechanism
            self.message = message
            self.node = node
            self.resolvedApp = resolvedApp
            self.errorCode = errorCode
            self.effect = effect
            self.warning = warning
            self.scrollDeltaY = scrollDeltaY
            self.skipped = skipped
        }
    }

    /// An element a step refers to (by `elementId` or `match`), re-read live when the step runs.
    struct ResolvedElement {
        var pid: Int32
        var element: AXUIElement?
        var node: ElementNode?
    }

    struct Refusal: Error {
        let mechanism: String
        let errorCode: String
        let message: String
    }

    struct ForegroundBurst {
        let targetPid: pid_t
        let previousApp: NSRunningApplication?
        let previousWindow: AXUIElement?
        let borrowedWindowId: CGWindowID?
        let savedCursor: CGPoint?
    }

    public struct UploadValidationError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
        public init(_ message: String) { self.message = message }
    }

    public static func validateAndNormalizeUploadFiles(_ rawFiles: [String]?) -> Result<[String], UploadValidationError> {
        guard let rawFiles, !rawFiles.isEmpty else {
            return .failure(UploadValidationError("uploadFile requires a non-empty 'files' array of local file paths."))
        }

        let fm = FileManager.default
        var normalized: [String] = []
        normalized.reserveCapacity(rawFiles.count)

        for raw in rawFiles {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(UploadValidationError("uploadFile contains an empty file path."))
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let canonicalURL = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            let canonicalPath = canonicalURL.path
            if Self.isSensitiveFilePath(canonicalURL) {
                return .failure(UploadValidationError("Blocked sensitive file path for upload safety: \(canonicalURL.lastPathComponent)"))
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: canonicalPath, isDirectory: &isDir) else {
                return .failure(UploadValidationError("Upload file not found: \(canonicalPath)"))
            }
            guard !isDir.boolValue else {
                return .failure(UploadValidationError("Upload path is a directory, expected a file: \(canonicalPath)"))
            }
            normalized.append(canonicalPath)
        }

        return .success(normalized)
    }

    static func isSensitiveFilePath(_ url: URL) -> Bool {
        let blockedPathFragments = [
            "/.ssh/",
            "/.aws/",
            "/.gnupg/",
            "/.kube/",
            "/.config/gcloud/",
            "/library/keychains/",
            "/library/cookies/",
            "/.git-credentials",
            "/.netrc",
            "/.npmrc",
            "/.pypirc",
            "/etc/passwd",
            "/etc/shadow",
            "/.docker/",
            "/.config/gh/",
            "/.config/op/",
            "/.password-store/",
            "/.1password/",
            "/.terraform.d/",
            "/.azure/",
            "/.oci/",
            "/library/application support/google/chrome/",
            "/library/application support/bravesoftware/",
            "/library/application support/microsoft edge/",
            "/library/application support/firefox/",
            "/library/application support/1password/",
            "/library/application support/usemac/",
            "/library/group containers/",
            "/library/messages/",
            "/library/mail/",
            "/library/safari/"
        ]
        let blockedFileNames: Set<String> = [
            ".env",
            "id_rsa",
            "id_ed25519",
            "id_ecdsa",
            "id_dsa",
            "authorized_keys",
            "credentials",
            "credentials.json",
            ".zsh_history",
            ".bash_history",
            ".python_history",
            ".node_repl_history",
            ".psql_history",
            ".mysql_history",
            "known_hosts",
            ".htpasswd",
            "secrets.json",
            "secrets.yaml",
            "secrets.yml",
            "terraform.tfstate",
            "wallet.dat"
        ]
        let blockedFileSuffixes = [
            ".keychain",
            ".keychain-db",
            ".p12",
            ".pem",
            ".pfx",
            ".p8",
            ".kdbx",
            ".ovpn",
            ".jks",
            ".keystore",
            ".tfstate"
        ]

        let path = url.path.lowercased()
        let name = url.lastPathComponent.lowercased()
        return blockedPathFragments.contains { path.contains($0) }
            || blockedFileNames.contains(name)
            || name.hasPrefix(".env.")
            || blockedFileSuffixes.contains { name.hasSuffix($0) }
    }

    private func isMutatingStep(_ step: ActionStep) -> Bool {
        switch step.action {
        case .target, .scroll, .hover, .wait, .scrollIntoView, .waitFor, .assert, .scrollUntil:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile, .axAction, .fillForm, .menuAction, .drag, .saveFile:
            return true
        }
    }

    private func isSensitiveStep(_ step: ActionStep) -> Bool {
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
        return ModifierAliases.isSensitive(step.modifiers)
    }

    // MARK: - Step dispatch

    private func executeStep(
        _ step: ActionStep,
        targetApp: AppDescriptor?,
        measureEffect shouldMeasureEffect: Bool = true,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?,
        siteRuleGuard: (@Sendable (AppDescriptor) async -> String?)?
    ) async -> StepOutcome {
        switch step.action {
        case .target:
            guard let app = workspaceMonitor.resolveApp(query: step.app) ?? targetApp else {
                return StepOutcome(success: false, mechanism: "workspace-target", message: "Target app not found", errorCode: "APP_NOT_FOUND")
            }
            if step.preferBackground == false {
                _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [])
            }
            return StepOutcome(success: true, mechanism: "workspace-target", message: "Targeted \(app.name)", resolvedApp: app, effect: .unverified)

        case .wait:
            let ms = max(0, step.durationMs ?? 250)
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return StepOutcome(success: true, mechanism: "sleep", message: "Waited \(ms)ms", effect: .unverified)

        case .waitFor:
            return await performWaitFor(step: step, targetApp: targetApp)

        case .openURL, .navigate:
            return await performOpenURL(step: step)

        case .assert:
            return performAssert(step: step, targetApp: targetApp)

        case .scrollUntil:
            return await performScrollUntil(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .fillForm:
            return await performFillForm(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .menuAction:
            return await performMenuAction(step: step, targetApp: targetApp, siteRuleGuard: siteRuleGuard)

        default:
            break
        }

        var resolved = ResolvedElement(pid: targetApp?.pid ?? 0)
        if step.elementId?.isEmpty == false || step.match?.isEmpty == false {
            switch await resolve(step: step, targetApp: targetApp, scrollOffscreenIntoView: Self.scrollsTargetIntoView(step.action)) {
            case .success(let found):
                resolved = found
            case .failure(let refusal):
                return StepOutcome(success: false, mechanism: refusal.mechanism, message: refusal.message, errorCode: refusal.errorCode)
            }
        }

        let pid = resolved.pid > 0 ? resolved.pid : (targetApp?.pid ?? 0)
        let willCheckEffect = shouldMeasureEffect && Self.checksEffect(step.action)
        let baseline = (willCheckEffect && pid > 0) ? captureBaseline(pid: pid, resolved: resolved) : nil

        var outcome: StepOutcome
        switch step.action {
        case .focus:
            outcome = performFocus(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .click:
            outcome = performClick(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .doubleClick:
            outcome = performDoubleClick(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .rightClick:
            outcome = performRightClick(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .hover:
            outcome = performHover(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .setValue:
            outcome = await performSetValue(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .type:
            outcome = performType(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .pressKey:
            outcome = performPressKey(step: step, resolved: resolved, targetApp: targetApp)
        case .scroll:
            outcome = await performScroll(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .scrollIntoView:
            outcome = await performScrollIntoView(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .axAction:
            outcome = performAXAction(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .uploadFile:
            outcome = await performNativeUploadFile(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .drag:
            outcome = await performDrag(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .saveFile:
            outcome = await performNativeSaveFile(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        case .target, .wait, .waitFor, .openURL, .navigate, .assert, .scrollUntil, .fillForm, .menuAction:
            outcome = StepOutcome(success: false, mechanism: "dispatch", message: "Unreachable step type")
        }

        if outcome.success, outcome.effect == nil {
            if let baseline, willCheckEffect {
                outcome.effect = await measureEffect(baseline: baseline, outcome: outcome)
                if outcome.effect == ActionEffect.none, outcome.warning == nil {
                    outcome.warning = Self.noEffectWarning(step: step, mechanism: outcome.mechanism)
                }
            } else {
                outcome.effect = .unverified
            }
        }
        return outcome
    }

    private static func scrollsTargetIntoView(_ action: ActionStepType) -> Bool {
        switch action {
        case .click, .doubleClick, .rightClick, .hover, .type, .focus, .pressKey, .drag:
            return true
        default:
            return false
        }
    }

    private static func checksEffect(_ action: ActionStepType) -> Bool {
        switch action {
        case .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .scroll, .scrollIntoView, .axAction, .focus, .drag:
            return true
        default:
            return false
        }
    }

    private static func noEffectWarning(step: ActionStep, mechanism: String) -> String {
        let posted = mechanism.contains("pid")
        switch step.action {
        case .scroll:
            return "Nothing moved. The app ignored the scroll; try scrollIntoView on the element you need."
        case .type, .pressKey:
            return posted
                ? "The app did not react to the keys. Background key events often do not reach web content; prefer setValue or axAction, or run a foreground burst."
                : "The app did not react to the keys."
        case .click, .doubleClick, .rightClick:
            return posted
                ? "The app did not react to the click posted in the background. Prefer an element with AXPress/AXOpen (axAction), or run a foreground burst."
                : "The app did not visibly react to the click. Check the result before continuing."
        default:
            return "UseMac did not see anything change after this step. Check the result before continuing."
        }
    }

    // MARK: - Element resolution

    func resolve(
        step: ActionStep,
        targetApp: AppDescriptor?,
        scrollOffscreenIntoView: Bool
    ) async -> Result<ResolvedElement, Refusal> {
        var resolved: ResolvedElement

        if let match = step.match, !match.isEmpty {
            guard let pid = targetApp?.pid, pid > 0 else {
                return .failure(Refusal(mechanism: "match", errorCode: "APP_NOT_FOUND", message: "`match` needs a target app."))
            }
            let wanted = max(0, match.index ?? 0)
            let hits = axIndexer.find(pid: pid, match: match, limit: wanted + 1)
            guard hits.count > wanted else {
                return .failure(Refusal(
                    mechanism: "match",
                    errorCode: "ELEMENT_NOT_FOUND",
                    message: "No element in \(targetApp?.name ?? "the app")'s front window matches \(Self.describe(match))\(hits.isEmpty ? "" : " at index \(wanted) (found \(hits.count))")."
                ))
            }
            resolved = ResolvedElement(pid: pid, element: hits[wanted].element, node: hits[wanted].node)
        } else if let id = step.elementId, !id.isEmpty {
            if let pid = targetApp?.pid, pid > 0, let live = axIndexer.liveNode(for: id, pid: pid) {
                resolved = ResolvedElement(pid: pid, element: live.element, node: live.node)
            } else if let other = axIndexer.node(for: id), !workspaceMonitor.isUseMacProcess(pid: other.pid),
                      !TargetRulesStore.shared.blocksProcess(pid: other.pid),
                      let live = axIndexer.liveNode(for: id, pid: other.pid) {
                resolved = ResolvedElement(pid: other.pid, element: live.element, node: live.node)
            } else {
                return .failure(Refusal(
                    mechanism: "resolve",
                    errorCode: "ELEMENT_NOT_FOUND",
                    message: "Element \(id) is unknown or no longer exists. Observe again, or target it with `match`."
                ))
            }
        } else {
            return .success(ResolvedElement(pid: targetApp?.pid ?? 0))
        }

        if scrollOffscreenIntoView, resolved.node?.offscreen == true, let element = resolved.element, let id = resolved.node?.id {
            if AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) == .success {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if let refreshed = axIndexer.liveNode(for: id, pid: resolved.pid) {
                    resolved.node = refreshed.node
                }
            }
        }
        return .success(resolved)
    }

    static func describe(_ match: ElementMatch) -> String {
        var parts: [String] = []
        if let role = match.role { parts.append("role \(role)") }
        if let title = match.title { parts.append("title \"\(title)\"") }
        if let value = match.value { parts.append("value \"\(value)\"") }
        if let text = match.text { parts.append("text \"\(text)\"") }
        return parts.isEmpty ? "(empty match)" : parts.joined(separator: ", ")
    }

    /// Where a pointer event for the step goes: the given coordinates, or the middle of the part of the element
    /// inside its window. The middle of a tall text area or list can lie below the window, over another app.
    func resolvePoint(step: ActionStep, node: ElementNode?, targetApp: AppDescriptor?) -> CGPoint? {
        if let x = step.x, let y = step.y {
            return CGPoint(x: x, y: y)
        }
        guard let node, node.offscreen != true, node.frame.width > 0, node.frame.height > 0 else {
            return nil
        }
        let rect = CGRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
        if let window = targetWindowFrame(targetApp) {
            let visible = rect.intersection(window)
            if !visible.isNull, visible.width > 1, visible.height > 1 {
                return CGPoint(x: visible.midX, y: visible.midY)
            }
        }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The target window's frame now (falls back to the bounds seen when the batch started).
    func targetWindowFrame(_ targetApp: AppDescriptor?) -> CGRect? {
        if let windowId = targetApp?.windowId, let info = WindowResolver.info(windowId: CGWindowID(windowId)) {
            return info.frame
        }
        return targetApp?.windowBounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    func highlight(_ node: ElementNode?, targetApp: AppDescriptor?, onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?) {
        guard let node, node.offscreen != true else { return }
        onOverlayEvent?(.highlightElement(
            rect: node.frame,
            label: node.id,
            role: node.role,
            durationMs: 600,
            pid: targetApp?.pid,
            windowId: targetApp?.windowId
        ))
    }

    func pulse(_ point: CGPoint, label: String?, targetApp: AppDescriptor?, onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?) {
        onOverlayEvent?(.pulsePoint(
            x: Double(point.x),
            y: Double(point.y),
            label: label,
            pid: targetApp?.pid,
            windowId: targetApp?.windowId
        ))
    }

    // MARK: - Effect detection

    private struct EffectBaseline {
        let pid: Int32
        let changeCount: UInt64
        let element: AXUIElement?
        let value: String?
        let focused: Bool?
        let frame: CGRect?
        let focusedElement: AXUIElement?
    }

    private func captureBaseline(pid: Int32, resolved: ResolvedElement) -> EffectBaseline {
        let gen = axIndexer.currentGeneration(pid: pid)
        // Reuse attributes already read by `liveNode`/`resolve` (avoiding 4-5 redundant AX IPCs per step).
        if let node = resolved.node {
            let frame = (node.frame.width > 0 || node.frame.height > 0)
                ? CGRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
                : nil
            return EffectBaseline(
                pid: pid,
                changeCount: gen,
                element: resolved.element,
                value: node.value,
                focused: node.focused,
                frame: frame,
                focusedElement: nil
            )
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        return EffectBaseline(
            pid: pid,
            changeCount: gen,
            element: resolved.element,
            value: resolved.element.flatMap { Self.axString($0, kAXValueAttribute) },
            focused: resolved.element.flatMap { Self.axBool($0, kAXFocusedAttribute) },
            frame: resolved.element.flatMap { Self.axFrame($0) },
            focusedElement: Self.axElement(axApp, kAXFocusedUIElementAttribute)
        )
    }

    /// Event-driven effect detection: wakes immediately (2–5 ms) on `AXObserver` notifications via
    /// `axIndexer.waitForChange`, falling back to attribute diffs only if no AX notification fired.
    private func measureEffect(baseline: EffectBaseline, outcome: StepOutcome) async -> ActionEffect {
        if outcome.scrollDeltaY.map({ abs($0) >= 1 }) == true {
            return .changed
        }
        if axIndexer.currentGeneration(pid: baseline.pid) != baseline.changeCount {
            return .changed
        }

        let deadlineNs = DispatchTime.now().uptimeNanoseconds + Self.effectWindowMs * 1_000_000
        let firstSliceMs = min(120, Int(Self.effectWindowMs))
        if await axIndexer.waitForChange(
            pid: baseline.pid,
            sinceGeneration: baseline.changeCount,
            timeoutMs: firstSliceMs
        ) {
            return .changed
        }

        if hasAttributeChanged(baseline: baseline) {
            return .changed
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        if nowNs < deadlineNs {
            let remainingMs = Int((deadlineNs - nowNs) / 1_000_000)
            if remainingMs > 0 {
                if await axIndexer.waitForChange(
                    pid: baseline.pid,
                    sinceGeneration: baseline.changeCount,
                    timeoutMs: remainingMs
                ) {
                    return .changed
                }
                if hasAttributeChanged(baseline: baseline) {
                    return .changed
                }
            }
        }
        return .none
    }

    private func hasAttributeChanged(baseline: EffectBaseline) -> Bool {
        if let element = baseline.element {
            if Self.axString(element, kAXValueAttribute) != baseline.value { return true }
            if Self.axBool(element, kAXFocusedAttribute) != baseline.focused { return true }
            if let before = baseline.frame, let now = Self.axFrame(element), before != now { return true }
        }
        if let beforeFocused = baseline.focusedElement {
            let axApp = AXUIElementCreateApplication(baseline.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            let focusedNow = Self.axElement(axApp, kAXFocusedUIElementAttribute)
            if let focusedNow {
                if !CFEqual(beforeFocused, focusedNow) { return true }
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Small AX helpers

    static func raiseAXWindow(_ window: AXUIElement) {
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    static func isHosted(in window: AXUIElement, element: AXUIElement) -> Bool {
        if CFEqual(element, window) { return true }
        if let host = axElement(element, kAXWindowAttribute), CFEqual(host, window) { return true }
        var current = element
        for _ in 0..<8 {
            guard let parent = axElement(current, kAXParentAttribute) else { return false }
            if CFEqual(parent, window) { return true }
            if CFEqual(parent, current) { return false }
            current = parent
        }
        return false
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func axDouble(_ element: AXUIElement, _ attribute: String) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func axChildren(_ element: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
        }
    }

    static func axActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    static func axFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func firstDescendant(of root: AXUIElement, maxDepth: Int, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            let (element, depth) = queue[index]
            index += 1
            if predicate(element) { return element }
            if depth < maxDepth {
                queue.append(contentsOf: axChildren(element).map { ($0, depth + 1) })
            }
            if index > 4000 { break }
        }
        return nil
    }

    static func collectDescendants(of root: AXUIElement, maxDepth: Int, into result: inout [AXUIElement], where predicate: (AXUIElement) -> Bool) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            let (element, depth) = queue[index]
            index += 1
            if predicate(element) { result.append(element) }
            if depth < maxDepth {
                queue.append(contentsOf: axChildren(element).map { ($0, depth + 1) })
            }
            if index > 6000 { break }
        }
    }

    func backgroundPid(for step: ActionStep, targetApp: AppDescriptor?) -> pid_t? {
        guard step.preferBackground != false,
              let pid = targetApp?.pid,
              pid > 0 else {
            return nil
        }
        if NSRunningApplication(processIdentifier: pid)?.isActive == true {
            return nil
        }
        return pid
    }

    private func formatStepTitle(step: ActionStep, node: ElementNode?, app: AppDescriptor?) -> String {
        let target = formatElementTarget(step: step, node: node)
        switch step.action {
        case .target:
            return "Targeted \(app?.name ?? step.app ?? "app")"
        case .openURL, .navigate:
            return "Opened \(clippedText(step.url ?? step.text ?? "URL", limit: 28))"
        case .focus:
            if let id = step.elementId, !id.isEmpty {
                return "Focused \(target)"
            }
            return "Focused \(app?.name ?? step.app ?? "app")"
        case .click:
            return target.isEmpty ? "Clicked" : "Clicked \(target)"
        case .doubleClick:
            return target.isEmpty ? "Double-clicked" : "Double-clicked \(target)"
        case .rightClick:
            return target.isEmpty ? "Right-clicked" : "Right-clicked \(target)"
        case .hover:
            return target.isEmpty ? "Hovered" : "Hovered \(target)"
        case .setValue:
            let clipped = clippedText(step.text ?? "", limit: 24)
            let dest = target.isEmpty ? "field" : target
            return "Set \(dest) to \"\(clipped)\""
        case .type:
            let clipped = clippedText(step.text ?? "", limit: 24)
            return "Typed \"\(clipped)\""
        case .pressKey:
            return "Pressed \(formatKeyChord(key: step.key, modifiers: step.modifiers))"
        case .scroll:
            return target.isEmpty ? "Scrolled" : "Scrolled \(target)"
        case .wait:
            let ms = max(0, step.durationMs ?? 250)
            return "Waited \(ms) ms"
        case .uploadFile:
            let count = step.files?.count ?? 0
            return count == 1 ? "Uploaded 1 file" : "Uploaded \(count) files"
        case .scrollIntoView:
            return target.isEmpty ? "Scrolled into view" : "Scrolled to \(target)"
        case .axAction:
            let name = step.actionName ?? "action"
            return target.isEmpty ? "Performed \(name)" : "Performed \(name) on \(target)"
        case .waitFor:
            return step.gone == true ? "Waited for \(target.isEmpty ? "element" : target) to go away" : "Waited for \(target.isEmpty ? "element" : target)"
        case .assert:
            return "Checked expectation"
        case .scrollUntil:
            return target.isEmpty ? "Scrolled until match" : "Scrolled until \(target)"
        case .fillForm:
            let count = step.fields?.count ?? 0
            return count == 1 ? "Filled 1 form field" : "Filled \(count) form fields"
        case .menuAction:
            if let path = step.menuPath, !path.isEmpty {
                return "Chose \(clippedText(path.joined(separator: " → "), limit: 28))"
            }
            return "Used menu item"
        case .drag:
            return target.isEmpty ? "Dragged" : "Dragged \(target)"
        case .saveFile:
            let fileName = step.files?.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return fileName.isEmpty ? "Saved file" : "Saved \(clippedText(fileName, limit: 28))"
        }
    }

    private func formatElementTarget(step: ActionStep, node: ElementNode?) -> String {
        if let id = step.elementId, !id.isEmpty {
            if let rawTitle = node?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty {
                let clipped = clippedText(rawTitle.replacingOccurrences(of: "\n", with: " "), limit: 24)
                return "\"\(clipped)\" (\(id))"
            }
            return id
        }
        if let x = step.x, let y = step.y {
            return "(\(Int(x)), \(Int(y)))"
        }
        return ""
    }

    private func clippedText(_ text: String, limit: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= limit {
            return singleLine
        }
        return String(singleLine.prefix(limit)) + "…"
    }

    private func formatKeyChord(key: String?, modifiers: [String]?) -> String {
        let modPrefix = ModifierAliases.symbols(modifiers)
        let rawKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formattedKey = rawKey.count == 1 ? rawKey.uppercased() : rawKey.capitalized
        return modPrefix + (formattedKey.isEmpty ? "Key" : formattedKey)
    }

    func isChromiumApp(_ app: AppDescriptor?) -> Bool {
        NativeBrowserSiteRules.isChromiumApp(bundleId: app?.bundleId, name: app?.name)
    }
}
