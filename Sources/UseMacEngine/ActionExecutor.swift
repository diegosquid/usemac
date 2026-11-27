import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

public final class ActionExecutor: @unchecked Sendable {
    private let axIndexer: AXIndexer
    private let workspaceMonitor: WorkspaceMonitor
    private let killSwitch: KillSwitch

    /// When UseMac itself last posted real (HID) input, so its own events are not mistaken for the user's.
    private let syntheticInputLock = NSLock()
    private var lastSyntheticInputAt: Date = .distantPast

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
                if Self.shouldEscalateToForeground(step: step, outcome: outcome, targetPid: target.pid) {
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

    private static func shouldEscalateToForeground(step: ActionStep, outcome: StepOutcome, targetPid: pid_t) -> Bool {
        // Only escalate when input was demonstrably NOT sent. Replaying a succeeded click,
        // typing, shortcut, or upload because AX saw no change risks duplicate side effects.
        guard !outcome.success else {
            return false
        }
        return outcome.errorCode == "TARGET_NOT_FRONTMOST"
    }

    private struct StepOutcome {
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
    private struct ResolvedElement {
        var pid: Int32
        var element: AXUIElement?
        var node: ElementNode?
    }

    private struct Refusal: Error {
        let mechanism: String
        let errorCode: String
        let message: String
    }

    private struct ForegroundBurst {
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
            let lowerPath = canonicalPath.lowercased()
            let fileNameLower = canonicalURL.lastPathComponent.lowercased()

            if blockedPathFragments.contains(where: { lowerPath.contains($0) })
                || blockedFileNames.contains(fileNameLower)
                || fileNameLower.hasPrefix(".env.")
                || blockedFileSuffixes.contains(where: { fileNameLower.hasSuffix($0) }) {
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

    private func isMutatingStep(_ step: ActionStep) -> Bool {
        switch step.action {
        case .target, .scroll, .hover, .wait, .scrollIntoView, .waitFor, .assert, .scrollUntil:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile, .axAction, .fillForm, .menuAction:
            return true
        }
    }

    private func isSensitiveStep(_ step: ActionStep) -> Bool {
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
        return ModifierAliases.isSensitive(step.modifiers)
    }

    // MARK: - Preconditions

    /// Stale-snapshot and expected-title checks. Returns a refusal when the batch must not run.
    private func preflightRefusal(_ request: BatchActionRequest, targetApp: AppDescriptor?) -> Refusal? {
        // The app the batch resolved to, named or not (the app in front), may be one the user's rules block.
        if let blocked = TargetRulesStore.shared.blockedMessage(for: targetApp) {
            return Refusal(mechanism: "target-rules", errorCode: TargetRules.errorCode, message: blocked)
        }
        guard let pid = targetApp?.pid, pid > 0 else { return nil }
        if let pinned = WindowResolver.pinnedTitle(pid: pid), WindowResolver.window(pid: pid, titleContains: pinned) == nil {
            return Refusal(
                mechanism: "window-pin",
                errorCode: "ELEMENT_NOT_FOUND",
                message: "No \(targetApp?.name ?? "app") window has a title containing \"\(pinned)\" anymore. Observe again (without `window` for the focused window)."
            )
        }
        let stepsSwitchApps = request.steps.contains { step in
            guard let app = step.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return false }
            return workspaceMonitor.resolveApp(query: app)?.pid != pid
        }
        if stepsSwitchApps { return nil }

        let usesSnapshotIds = request.allowStaleSnapshot != true && request.steps.contains { step in
            guard step.optional != true else { return false }
            let stepHasId = (step.elementId?.isEmpty == false) && (step.match == nil || step.match?.isEmpty == true)
            let formHasId = step.fields?.contains(where: { ($0.elementId?.isEmpty == false) && ($0.match == nil || $0.match?.isEmpty == true) }) == true
            return stepHasId || formHasId
        }
        let expected = request.expectWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesSnapshotIds || (expected?.isEmpty == false) else { return nil }

        let current = axIndexer.currentContext(pid: pid)

        if usesSnapshotIds, let snapshot = axIndexer.snapshotContext(pid: pid), let current {
            let decision = Self.evaluateStaleSnapshot(
                snapshot: snapshot,
                current: current,
                elementsAlive: { self.allReferencedElementsAlive(in: request.steps, pid: pid) }
            )
            if decision.shouldRefuse {
                if decision.windowChanged {
                    return Refusal(
                        mechanism: "stale-check",
                        errorCode: "STALE_SNAPSHOT",
                        message: "The \(targetApp?.name ?? "app") window changed since the last observe (now \"\(current.windowTitle ?? "untitled")\"). Element ids would hit the wrong place: observe again, or use `match`."
                    )
                }
                return Refusal(
                    mechanism: "stale-check",
                    errorCode: "STALE_SNAPSHOT",
                    message: "The window now shows \"\(current.windowTitle ?? "")\" but the last observe saw \"\(snapshot.windowTitle ?? "")\". Observe again, or use `match`, or pass allowStaleSnapshot if this is expected."
                )
            }
        }

        if let expected, !expected.isEmpty {
            let have = current?.windowTitle ?? targetApp?.windowTitle ?? ""
            if !Self.comparableTitle(have).contains(Self.comparableTitle(expected)) {
                return Refusal(
                    mechanism: "expect-title",
                    errorCode: "STALE_SNAPSHOT",
                    message: "Expected the window title to contain \"\(expected)\", but it is \"\(have)\". Nothing was sent."
                )
            }
        }
        return nil
    }

    /// Evaluates whether snapshot ids are stale. Always refuses when `windowId` changed; when `windowId` is
    /// unchanged and only `comparableTitle` drifted, verifies per-element liveness instead of aborting blindly.
    static func evaluateStaleSnapshot(
        snapshot: AXIndexer.SnapshotContext,
        current: AXIndexer.SnapshotContext,
        elementsAlive: () -> Bool
    ) -> (shouldRefuse: Bool, windowChanged: Bool) {
        if let before = snapshot.windowId, let now = current.windowId, before != now {
            return (true, true)
        }
        if let before = snapshot.windowTitle, let now = current.windowTitle,
           comparableTitle(before) != comparableTitle(now) {
            let sameWindow = (snapshot.windowId != nil && snapshot.windowId == current.windowId)
            if sameWindow && elementsAlive() {
                return (false, false)
            }
            return (true, false)
        }
        return (false, false)
    }

    private func allReferencedElementsAlive(in steps: [ActionStep], pid: pid_t) -> Bool {
        var ids: [String] = []
        for step in steps where step.optional != true {
            if let id = step.elementId, !id.isEmpty, (step.match == nil || step.match?.isEmpty == true) {
                ids.append(id)
            }
            if let fields = step.fields {
                for field in fields {
                    if let id = field.elementId, !id.isEmpty, (field.match == nil || field.match?.isEmpty == true) {
                        ids.append(id)
                    }
                }
            }
        }
        guard !ids.isEmpty else { return true }
        for id in ids {
            let cachedRole = axIndexer.node(for: id, pid: pid)?.role
            guard let live = axIndexer.liveNode(for: id, pid: pid) else {
                return false
            }
            if let cachedRole,
               ElementMatcher.normalizeRole(live.node.role) != ElementMatcher.normalizeRole(cachedRole) {
                return false
            }
        }
        return true
    }

    /// Letters only, folded: unread counters, emoji and punctuation do not make a window "different".
    static func comparableTitle(_ title: String) -> String {
        let letters = title.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return ElementMatcher.normalize(String(letters))
    }

    // MARK: - Foreground burst

    static func remainingBudgetMs(nowNs: UInt64, deadlineNs: UInt64) -> Int {
        guard nowNs < deadlineNs else { return 0 }
        return Int((deadlineNs - nowNs) / 1_000_000)
    }

    private func beginForegroundBurst(targetApp: AppDescriptor?, waitForIdleMs: Int? = nil) async -> Result<ForegroundBurst, Refusal> {
        guard let app = targetApp, app.pid > 0,
              let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            return .failure(Refusal(mechanism: "foreground-burst", errorCode: "APP_NOT_FOUND", message: "A foreground burst needs a running target app."))
        }
        let idleWaitBudgetMs = min(max(0, waitForIdleMs ?? 2000), 60_000)
        var idle = WindowResolver.secondsSinceUserInput()
        if idle < Self.userIdleRequiredSeconds && !idleIsFromOwnInput(idle) && idleWaitBudgetMs > 0 {
            let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(idleWaitBudgetMs) * 1_000_000
            while true {
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let remainingMs = Self.remainingBudgetMs(nowNs: nowNs, deadlineNs: deadlineNs)
                guard remainingMs > 0 else { break }
                let toIdleMs = Int(max(40, (Self.userIdleRequiredSeconds - idle) * 1000.0))
                let sliceMs = min(150, toIdleMs, remainingMs)
                try? await Task.sleep(nanoseconds: UInt64(sliceMs) * 1_000_000)
                idle = WindowResolver.secondsSinceUserInput()
                if idle >= Self.userIdleRequiredSeconds || idleIsFromOwnInput(idle) {
                    break
                }
            }
        }
        if idle < Self.userIdleRequiredSeconds && !idleIsFromOwnInput(idle) {
            return .failure(Refusal(
                mechanism: "foreground-burst",
                errorCode: "USER_ACTIVE",
                message: String(format: "The user used the keyboard or mouse %.1f s ago. UseMac will not take over the screen while they are active; retry in a moment or stay in the background.", idle)
            ))
        }

        let previous = NSWorkspace.shared.frontmostApplication
        let cursor = CGEvent(source: nil)?.location
        if !WindowResolver.isFrontmost(pid: app.pid) {
            let activated = await waitForApplicationActivation(pid: app.pid, timeoutMs: 1500) {
                _ = running.activate(options: [])
            }
            guard activated && WindowResolver.isFrontmost(pid: app.pid) else {
                return .failure(Refusal(
                    mechanism: "foreground-burst",
                    errorCode: "TARGET_NOT_FRONTMOST",
                    message: "\(app.name) did not come to the front, so nothing was sent."
                ))
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        var previousWindow: AXUIElement?
        var borrowedWindowId: CGWindowID?
        if let pinned = WindowResolver.pinnedTitle(pid: app.pid),
           let pinnedWindow = WindowResolver.window(pid: app.pid, titleContains: pinned),
           let pinnedID = WindowResolver.windowID(of: pinnedWindow),
           InputRouting.focusedWindowId(pid: app.pid) != pinnedID {
            let axApp = AXUIElementCreateApplication(app.pid)
            if let focusedWindow = Self.axElement(axApp, kAXFocusedWindowAttribute),
               !CFEqual(focusedWindow, pinnedWindow) {
                previousWindow = focusedWindow
            }
            Self.raiseAXWindow(pinnedWindow)
            borrowedWindowId = pinnedID
            let deadline = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < deadline, WindowResolver.isFrontmost(pid: app.pid),
                  InputRouting.focusedWindowId(pid: app.pid) != pinnedID {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return .success(ForegroundBurst(
            targetPid: app.pid,
            previousApp: previous?.processIdentifier == app.pid ? nil : previous,
            previousWindow: previousWindow,
            borrowedWindowId: borrowedWindowId,
            savedCursor: cursor
        ))
    }

    private final class ActivationWaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var observer: NSObjectProtocol?
        private var timeoutItem: DispatchWorkItem?
        private let continuation: CheckedContinuation<Bool, Never>

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func attach(observer: NSObjectProtocol, timeoutItem: DispatchWorkItem) {
            var alreadyDone = false
            lock.lock()
            if resumed {
                alreadyDone = true
            } else {
                self.observer = observer
                self.timeoutItem = timeoutItem
            }
            lock.unlock()
            if alreadyDone {
                timeoutItem.cancel()
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }

        func complete(_ ok: Bool) {
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            resumed = true
            let obs = observer
            observer = nil
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()
            item?.cancel()
            if let obs {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
            continuation.resume(returning: ok)
        }
    }

    private func waitForApplicationActivation(
        pid: pid_t,
        timeoutMs: Int,
        activate: @escaping () -> Void
    ) async -> Bool {
        if WindowResolver.isFrontmost(pid: pid) { return true }
        return await withCheckedContinuation { continuation in
            let state = ActivationWaitState(continuation: continuation)
            let obs = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { note in
                if let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   activated.processIdentifier == pid {
                    state.complete(true)
                }
            }
            let item = DispatchWorkItem {
                state.complete(WindowResolver.isFrontmost(pid: pid))
            }
            state.attach(observer: obs, timeoutItem: item)

            activate()

            if WindowResolver.isFrontmost(pid: pid) {
                state.complete(true)
                return
            }

            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .milliseconds(max(1, timeoutMs)),
                execute: item
            )
        }
    }

    static func shouldRestorePreviousWindow(
        appIsFrontmost: Bool,
        borrowedWindowId: CGWindowID?,
        currentFocusedWindowId: CGWindowID?,
        secondsSinceUserInput: Double,
        ownInputRecent: Bool
    ) -> Bool {
        appIsFrontmost
            && (borrowedWindowId == nil || currentFocusedWindowId == borrowedWindowId)
            && (secondsSinceUserInput >= userIdleRequiredSeconds || ownInputRecent)
    }

    private func endForegroundBurst(_ burst: ForegroundBurst) async {
        if let cursor = burst.savedCursor {
            _ = CGWarpMouseCursorPosition(cursor)
        }
        if let previousWindow = burst.previousWindow {
            let idle = WindowResolver.secondsSinceUserInput()
            if Self.shouldRestorePreviousWindow(
                appIsFrontmost: WindowResolver.isFrontmost(pid: burst.targetPid),
                borrowedWindowId: burst.borrowedWindowId,
                currentFocusedWindowId: InputRouting.focusedWindowId(pid: burst.targetPid),
                secondsSinceUserInput: idle,
                ownInputRecent: idleIsFromOwnInput(idle)
            ) {
                Self.raiseAXWindow(previousWindow)
            }
        }
        if let previous = burst.previousApp, !previous.isTerminated, WindowResolver.isFrontmost(pid: burst.targetPid) {
            _ = previous.activate(options: [])
        }
    }

    private func noteSyntheticInput() {
        syntheticInputLock.lock()
        lastSyntheticInputAt = Date()
        syntheticInputLock.unlock()
    }

    /// True when the most recent HID event is one UseMac posted itself.
    private func idleIsFromOwnInput(_ idle: Double) -> Bool {
        syntheticInputLock.lock()
        let last = lastSyntheticInputAt
        syntheticInputLock.unlock()
        let sinceOwn = Date().timeIntervalSince(last)
        return abs(sinceOwn - idle) < 0.25
    }

    /// Real (HID) input goes to whatever app is in front. Refuse unless that is the target.
    /// `point` is where a mouse event would land, for the check that it is not a UseMac window.
    private func frontmostGuard(_ targetApp: AppDescriptor?, input: String, at point: CGPoint? = nil) -> StepOutcome? {
        if let point, let refusal = killSwitch.approvalPromptRefusal(at: point) {
            return StepOutcome(success: false, mechanism: "self-target", message: refusal, errorCode: "SELF_TARGET_BLOCKED")
        }
        if let pid = targetApp?.pid, pid > 0, !WindowResolver.isFrontmost(pid: pid) {
            return notFrontmostOutcome(targetApp: targetApp, input: input)
        }
        return ownWindowGuard(targetApp, at: point)
    }

    /// Real input lands in whichever window the window server picks, which can be a UseMac window (Settings)
    /// even when the target is another app. Refuse before sending anything when it would.
    private func ownWindowGuard(_ targetApp: AppDescriptor?, at point: CGPoint?) -> StepOutcome? {
        var receivers: [pid_t] = []
        // Topmost normal window at the point. UseMac's overlays sit above layer 0 and let clicks through.
        if let point, let top = WindowResolver.onScreenWindows().first(where: { $0.frame.contains(point) }) {
            receivers.append(top.pid)
        }
        // Without a target app, keys and clicks go to whatever app is in front.
        if (targetApp?.pid ?? 0) <= 0, let front = WindowResolver.frontmostPid() {
            receivers.append(front)
        }
        if receivers.contains(where: { !workspaceMonitor.isUseMacProcess(pid: $0) && TargetRulesStore.shared.blocksProcess(pid: $0) }) {
            return StepOutcome(
                success: false,
                mechanism: "target-rules",
                message: "This input would land in a window of an app the user's UseMac rules block, so nothing was sent. \(TargetRules.stopHint)",
                errorCode: TargetRules.errorCode
            )
        }
        guard receivers.contains(where: { workspaceMonitor.isUseMacProcess(pid: $0) }) else { return nil }
        return StepOutcome(
            success: false,
            mechanism: "self-target",
            message: "This input would land in a UseMac window, so nothing was sent. \(WorkspaceMonitor.selfTargetMessage)",
            errorCode: "SELF_TARGET_BLOCKED"
        )
    }

    private func notFrontmostOutcome(targetApp: AppDescriptor?, input: String) -> StepOutcome {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
        return StepOutcome(
            success: false,
            mechanism: "hid-guard",
            message: "\(targetApp?.name ?? "The target app") is not in front (\(front) is), so UseMac did not send real \(input): it would have landed in the wrong app. Use background steps, or run the batch with \"foreground\": true.",
            errorCode: "TARGET_NOT_FRONTMOST"
        )
    }

    /// The window a step must reach when the batch names one (`window`, which pins it): UseMac works in that
    /// window even when another window of the app is in front. Without a pin the target is whichever window
    /// of the app is in front, which can change during the batch (⌘N opens one), so no id is enforced.
    private func pinnedWindowId(_ targetApp: AppDescriptor?) -> CGWindowID? {
        guard let pid = targetApp?.pid, pid > 0, WindowResolver.pinnedTitle(pid: pid) != nil else { return nil }
        return targetApp?.windowId.map { CGWindowID($0) }
    }

    /// Real mouse input lands in the window on top at the point. With the target app in front, that can still be
    /// another window: the user's own Chrome window over the one UseMac works in, or another app's window.
    /// Decides how a step that would post real input sends it. `backgroundAllowed`: the event has a background
    /// route without side effects (wheel and mouse-moved events, not clicks).
    private func pointerRoute(_ targetApp: AppDescriptor?, at point: CGPoint?, backgroundAllowed: Bool) -> InputRouting.PointerRoute {
        guard let pid = targetApp?.pid, pid > 0 else { return .foreground }
        var documentIds: Set<CGWindowID>?
        return InputRouting.pointerRoute(
            point: point,
            targetPid: pid,
            targetWindowId: pinnedWindowId(targetApp),
            windows: InputRouting.pointerWindows(),
            isDocumentWindow: { id in
                if documentIds == nil { documentIds = InputRouting.documentWindowIds(pid: pid) }
                return documentIds?.contains(id) == true
            },
            backgroundAllowed: backgroundAllowed
        )
    }

    /// Refuses real mouse input (clicks) that would land in another window than the target.
    private func pointerRefusal(_ targetApp: AppDescriptor?, at point: CGPoint?, input: String) -> StepOutcome? {
        switch pointerRoute(targetApp, at: point, backgroundAllowed: false) {
        case .foreground:
            return nil
        case .background(let covering), .refuse(let covering):
            return coveredWindowOutcome(targetApp: targetApp, covering: covering, input: input)
        }
    }

    private func coveredWindowOutcome(targetApp: AppDescriptor?, covering: WindowResolver.WindowInfo?, input: String) -> StepOutcome {
        let app = targetApp?.name ?? "the target app"
        let place: String
        if let covering {
            place = covering.pid == targetApp?.pid
                ? "another \(app) window is on top of it there"
                : "a \(NSRunningApplication(processIdentifier: covering.pid)?.localizedName ?? "another app") window is on top of it there"
        } else {
            place = "it is not on screen there"
        }
        return StepOutcome(
            success: false,
            mechanism: "hid-guard",
            message: "The \(app) window UseMac works in would not get real \(input): \(place). Nothing was sent. Use a background step (setValue, axAction, scrollIntoView, or click an element with AXPress), or wait until that window is in front.",
            errorCode: "TARGET_NOT_FRONTMOST"
        )
    }

    /// Real keys go to the focused (key) window of the app in front. Refuses when that is not the window UseMac
    /// works in, e.g. a window it opened that sits behind the user's own window of the same app.
    private func keyWindowGuard(_ targetApp: AppDescriptor?, input: String, pickerReceiver: AXUIElement? = nil) -> StepOutcome? {
        guard let pid = targetApp?.pid, pid > 0, let target = pinnedWindowId(targetApp) else { return nil }
        let keysReach = InputRouting.keysReachTarget(
            appIsFrontmost: WindowResolver.isFrontmost(pid: pid),
            targetWindowId: target,
            focusedWindowId: InputRouting.focusedWindowId(pid: pid)
        )
        if keysReach { return nil }
        // A picker opened by the pinned window can take keys in its own AX window.
        if let pickerReceiver,
           let focusedWindow = Self.axElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
           Self.isHosted(in: focusedWindow, element: pickerReceiver) {
            return nil
        }
        let app = targetApp?.name ?? "the target app"
        return StepOutcome(
            success: false,
            mechanism: "hid-guard",
            message: "The \(app) window UseMac works in is not \(app)'s focused window, so real \(input) would go to the window in front (probably the user's). Nothing was sent. Use setValue or axAction, which work without focus.",
            errorCode: "TARGET_NOT_FRONTMOST"
        )
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
        case .click, .doubleClick, .rightClick, .hover, .type, .focus, .pressKey:
            return true
        default:
            return false
        }
    }

    private static func checksEffect(_ action: ActionStepType) -> Bool {
        switch action {
        case .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .scroll, .scrollIntoView, .axAction, .focus:
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

    static func openURLRuleRefusal(normalizedURL: String, handlerBundleId: String?, rules: TargetRules) -> String? {
        if rules.blocksURL(normalizedURL) {
            return TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: normalizedURL))
        }
        if let handlerBundleId, rules.blocksApp(bundleId: handlerBundleId) {
            return "The default app for this URL (\(handlerBundleId)) is blocked by UseMac target rules. \(TargetRules.stopHint)"
        }
        return nil
    }

    private func performOpenURL(step: ActionStep) async -> StepOutcome {
        let normalizedURL: String
        switch NavigationPolicy.validate(step.url ?? step.text) {
        case .success(let validURL):
            normalizedURL = validURL
        case .failure(let blocked):
            return StepOutcome(success: false, mechanism: "open-url", message: blocked.message, errorCode: "URL_BLOCKED")
        }
        guard let parsedURL = URL(string: normalizedURL) else {
            return StepOutcome(success: false, mechanism: "open-url", message: "Invalid URL.", errorCode: "INVALID_REQUEST")
        }
        let handlerBundleId = NSWorkspace.shared.urlForApplication(toOpen: parsedURL)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        if let message = Self.openURLRuleRefusal(
            normalizedURL: normalizedURL, handlerBundleId: handlerBundleId, rules: TargetRulesStore.shared.rules
        ) {
            return StepOutcome(success: false, mechanism: "target-rules", message: message, errorCode: TargetRules.errorCode)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = (step.preferBackground == false)
        do {
            _ = try await NSWorkspace.shared.open(parsedURL, configuration: config)
            return StepOutcome(success: true, mechanism: "nsworkspace-open", message: "Opened \(normalizedURL)", effect: .unverified)
        } catch {
            return StepOutcome(success: false, mechanism: "nsworkspace-open", message: error.localizedDescription)
        }
    }

    // MARK: - Element resolution

    private func resolve(
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

    private static func describe(_ match: ElementMatch) -> String {
        var parts: [String] = []
        if let role = match.role { parts.append("role \(role)") }
        if let title = match.title { parts.append("title \"\(title)\"") }
        if let value = match.value { parts.append("value \"\(value)\"") }
        if let text = match.text { parts.append("text \"\(text)\"") }
        return parts.isEmpty ? "(empty match)" : parts.joined(separator: ", ")
    }

    /// Where a pointer event for the step goes: the given coordinates, or the middle of the part of the element
    /// inside its window. The middle of a tall text area or list can lie below the window, over another app.
    private func resolvePoint(step: ActionStep, node: ElementNode?, targetApp: AppDescriptor?) -> CGPoint? {
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
    private func targetWindowFrame(_ targetApp: AppDescriptor?) -> CGRect? {
        if let windowId = targetApp?.windowId, let info = WindowResolver.info(windowId: CGWindowID(windowId)) {
            return info.frame
        }
        return targetApp?.windowBounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    private func highlight(_ node: ElementNode?, targetApp: AppDescriptor?, onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?) {
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

    private func pulse(_ point: CGPoint, label: String?, targetApp: AppDescriptor?, onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?) {
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

    // MARK: - Actions

    private func performFocus(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        if let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            let raiseErr = step.preferBackground == false
                ? AXUIElementPerformAction(axEl, kAXRaiseAction as CFString)
                : .apiDisabled
            let focusErr = step.preferBackground == false
                ? AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                : .apiDisabled
            if step.preferBackground == false, resolved.pid > 0 {
                _ = NSRunningApplication(processIdentifier: resolved.pid)?.activate(options: [])
            }
            if raiseErr == .success || focusErr == .success {
                return StepOutcome(success: true, mechanism: "ax-focus", node: resolved.node)
            }
            if step.preferBackground != false {
                return StepOutcome(
                    success: true,
                    mechanism: "background-noop-focus",
                    node: resolved.node,
                    effect: .unverified,
                    warning: "Focus is not moved in the background (it would pull the app forward). setValue/axAction work without focus."
                )
            }
        }

        if step.preferBackground == false,
           let pid = targetApp?.pid,
           let running = NSRunningApplication(processIdentifier: pid) {
            let ok = running.activate(options: [])
            return StepOutcome(
                success: ok,
                mechanism: "app-activate",
                message: ok ? nil : "Failed to activate app",
                node: resolved.node
            )
        }

        return StepOutcome(
            success: false,
            mechanism: "app-activate",
            message: "No target app or element to focus",
            node: resolved.node
        )
    }

    private func performClick(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        // Chromium's native "New Tab" AXPress triggers BrowserWindow::Activate() and steals focus.
        // Intercept in background mode and dispatch zero-focus Cmd+T directly to the background PID.
        if let bgPid,
           let node = resolved.node,
           node.role == "AXButton",
           let title = node.title?.lowercased(),
           (title == "new tab" || title == "nova guia"),
           isChromiumApp(targetApp) {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            let shortcutStep = ActionStep(action: .pressKey, key: "t", modifiers: ["cmd"], preferBackground: true)
            var res = performPressKey(step: shortcutStep, resolved: ResolvedElement(pid: bgPid), targetApp: targetApp)
            res.mechanism = "cgevent-pid-newtab"
            res.node = node
            return res
        }

        if step.preferBackground != false,
           let axEl = resolved.element,
           let node = resolved.node,
           node.actions.contains("AXPress") {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if AXUIElementPerformAction(axEl, kAXPressAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-press", node: node)
            }
        }

        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: resolved.node?.offscreen == true
                    ? "Element \(resolved.node?.id ?? "") is scrolled out of view and could not be scrolled into view."
                    : "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point)
            ?? pointerRefusal(targetApp, at: point, input: "clicks") {
            var refusedWithNode = refused
            refusedWithNode.node = resolved.node
            return refusedWithNode
        }

        pulse(point, label: resolved.node?.id ?? "click", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let ok = postMouseClick(
            at: point,
            button: .left,
            clickCount: 1,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid,
            windowId: targetApp?.windowId
        )
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post CGEvent click",
            node: resolved.node
        )
    }

    private func performHover(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        var bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil {
            if let refused = frontmostGuard(targetApp, input: "mouse movement", at: point) {
                return refused
            }
            switch pointerRoute(targetApp, at: point, backgroundAllowed: step.preferBackground != false) {
            case .foreground:
                break
            case .background:
                bgPid = targetApp?.pid
            case .refuse(let covering):
                return coveredWindowOutcome(targetApp: targetApp, covering: covering, input: "mouse movement")
            }
        }

        if resolved.node != nil {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        } else {
            pulse(point, label: "hover", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return StepOutcome(success: false, mechanism: "cgevent-hover", message: "Failed to construct CGEvent mouseMoved", node: resolved.node)
        }
        if let bgPid {
            Self.routeToWindow(moveEvent, windowId: targetApp?.windowId)
            moveEvent.postToPid(bgPid)
        } else {
            moveEvent.post(tap: .cghidEventTap)
            noteSyntheticInput()
        }
        return StepOutcome(
            success: true,
            mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
            node: resolved.node,
            effect: .unverified
        )
    }

    private func performDoubleClick(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        // Rows in file pickers, Finder-like lists and tables open with AXOpen: no events, no focus needed.
        if step.preferBackground != false,
           let element = resolved.element,
           let node = resolved.node,
           node.actions.contains("AXOpen") {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if AXUIElementPerformAction(element, "AXOpen" as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-open", node: node)
            }
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point)
            ?? pointerRefusal(targetApp, at: point, input: "clicks") {
            return refused
        }

        pulse(point, label: resolved.node?.id ?? "doubleClick", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let ok = postMouseClick(
            at: point,
            button: .left,
            clickCount: 2,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid,
            windowId: targetApp?.windowId
        )
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post double click",
            node: resolved.node
        )
    }

    private func performRightClick(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        if step.preferBackground != false,
           let element = resolved.element,
           let node = resolved.node,
           node.actions.contains("AXShowMenu") {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-show-menu", node: node)
            }
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point)
            ?? pointerRefusal(targetApp, at: point, input: "clicks") {
            return refused
        }

        pulse(point, label: resolved.node?.id ?? "rightClick", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let ok = postMouseClick(
            at: point,
            button: .right,
            clickCount: 1,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid,
            windowId: targetApp?.windowId
        )
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post right click",
            node: resolved.node
        )
    }

    private func performSetValue(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let text = step.text ?? ""
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        let omniboxWarning = isChromiumApp(targetApp) && Self.isAddressBar(resolved.node)
            ? "Typing into Chrome's address bar acts on whichever tab is active at that moment. To navigate, use browser_open with tabId (works on Web Store and chrome:// pages too)."
            : nil

        if step.preferBackground != false, let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            // IMPORTANT: Never set kAXFocusedAttribute while app is in background!
            // In Chromium/Electron, kAXFocusedAttribute calls Widget::Activate() and steals focus/Spaces.
            // The same goes for a window of the app in front that is not its focused window (one UseMac opened
            // behind the user's): focusing it would bring it over the user's window and take their keys.
            if bgPid == nil, keyWindowGuard(targetApp, input: "typing") == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            let beforeValue = resolved.node?.value ?? Self.axString(axEl, kAXValueAttribute)
            let genBefore = resolved.pid > 0 ? axIndexer.currentGeneration(pid: resolved.pid) : 0
            if AXUIElementSetAttributeValue(axEl, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                var readBack = Self.axString(axEl, kAXValueAttribute)
                let isToggle = ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(resolved.node?.role ?? "")
                let isSecure = Self.axString(axEl, kAXSubroleAttribute) == "AXSecureTextField"
                // Chromium sets the value in the page and updates its accessibility tree a moment later: wait
                // briefly via AXObserver before inspecting readback.
                if !isToggle, !isSecure, let current = readBack,
                   ElementMatcher.normalize(current) != ElementMatcher.normalize(text) {
                    var waitedMs = 0
                    var lastGen = genBefore
                    while waitedMs < 300 {
                        if resolved.pid > 0 {
                            _ = await axIndexer.waitForChange(pid: resolved.pid, sinceGeneration: lastGen, timeoutMs: 50)
                            lastGen = axIndexer.currentGeneration(pid: resolved.pid)
                        } else {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        waitedMs += 50
                        readBack = Self.axString(axEl, kAXValueAttribute)
                        if let rb = readBack,
                           ElementMatcher.normalize(rb) == ElementMatcher.normalize(text)
                           || ElementMatcher.normalize(rb) != ElementMatcher.normalize(beforeValue ?? "") {
                            break
                        }
                    }
                }
                let eval = Self.evaluateSetValueReadBack(
                    requested: text,
                    before: beforeValue,
                    readBack: readBack,
                    isToggle: isToggle,
                    isSecure: isSecure,
                    isChromiumBackground: bgPid != nil && isChromiumApp(targetApp)
                )
                return StepOutcome(
                    success: true,
                    mechanism: "ax-set-value",
                    message: eval.message,
                    node: resolved.node,
                    effect: eval.effect,
                    warning: eval.warning ?? omniboxWarning
                )
            }
        }

        if bgPid == nil {
            let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp)
            if let refused = frontmostGuard(targetApp, input: "typing", at: point)
                ?? keyWindowGuard(targetApp, input: "typing")
                ?? point.flatMap({ pointerRefusal(targetApp, at: $0, input: "clicks") }) {
                return refused
            }
            if let point {
                pulse(point, label: resolved.node?.id ?? "setValue", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                _ = postMouseClick(at: point, button: .left, clickCount: 1, restoreCursor: step.restoreCursor != false, targetPid: nil)
            }
        }

        let ok = typeUnicodeString(text, targetPid: bgPid)
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-unicode" : "cgevent-unicode",
            message: ok ? nil : "Failed to type text",
            node: resolved.node,
            warning: omniboxWarning ?? (resolved.element != nil ? "AXValue could not be set; typed the text instead." : nil)
        )
    }

    /// Evaluates `AXValue` readback after `setValue`: if the app reformatted the text (so `readBack != before`),
    /// reports `effect: .changed` with an informational message instead of a false `effect: .none` warning.
    static func evaluateSetValueReadBack(
        requested: String,
        before: String?,
        readBack: String?,
        isToggle: Bool,
        isSecure: Bool,
        isChromiumBackground: Bool = false
    ) -> (effect: ActionEffect, message: String?, warning: String?) {
        if isToggle || isSecure {
            return (.changed, nil, nil)
        }
        guard let readBack else {
            return (.changed, nil, nil)
        }
        let normReq = ElementMatcher.normalize(requested)
        let normRead = ElementMatcher.normalize(readBack)
        if normRead == normReq {
            return (.changed, nil, nil)
        }
        let normBefore = ElementMatcher.normalize(before ?? "")
        if normRead != normBefore {
            return (
                .changed,
                "Field value updated and formatted as \"\(readBack.prefix(80))\".",
                nil
            )
        }
        if isChromiumBackground {
            return (
                ActionEffect.none,
                nil,
                "The field still reads back \"\(readBack.prefix(60))\" instead of the text you set: web fields in background Chrome/Chromium windows (such as RESTRICTED_PAGE windows) often ignore AXValue without focus. Retry this batch with \"foreground\": true."
            )
        }
        return (
            ActionEffect.none,
            nil,
            "The field still reads back \"\(readBack.prefix(60))\" instead of the text you set: the app may have rejected it."
        )
    }

    private static func isAddressBar(_ node: ElementNode?) -> Bool {
        guard let node, node.role == "AXTextField" else { return false }
        let title = (node.title ?? "").lowercased()
        return title.contains("address") || title.contains("endereço") || title.contains("omnibox")
    }

    private func performType(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?,
        pickerReceiver: AXUIElement? = nil
    ) -> StepOutcome {
        let text = step.text ?? ""
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        // Where a real click places the caret first (an element or explicit coordinates).
        let clickPoint: CGPoint? = bgPid == nil && (resolved.node != nil || (step.x != nil && step.y != nil))
            ? resolvePoint(step: step, node: resolved.node, targetApp: targetApp)
            : nil
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "typing", at: resolvePoint(step: step, node: resolved.node, targetApp: targetApp))
            ?? keyWindowGuard(targetApp, input: "typing", pickerReceiver: pickerReceiver)
            ?? clickPoint.flatMap({ pointerRefusal(targetApp, at: $0, input: "clicks") }) {
            return refused
        }

        if let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            // Only set kAXFocusedAttribute if already frontmost; otherwise it activates background Chromium/Electron windows.
            if bgPid == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        if let point = clickPoint {
            pulse(point, label: resolved.node?.id ?? "type", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            _ = postMouseClick(at: point, button: .left, clickCount: 1, restoreCursor: step.restoreCursor != false, targetPid: nil)
        }

        let ok = typeUnicodeString(text, targetPid: bgPid)
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-unicode" : "cgevent-unicode",
            message: ok ? nil : "Failed to type text",
            node: resolved.node
        )
    }

    private func performPressKey(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        pickerReceiver: AXUIElement? = nil
    ) -> StepOutcome {
        guard let keyName = step.key?.trimmingCharacters(in: .whitespacesAndNewlines),
              let keyCode = NativeKeyMap.keyCode(for: step.key) else {
            return StepOutcome(
                success: false,
                mechanism: "cgevent-key",
                message: NativeKeyMap.unsupportedKeyMessage(for: step.key),
                errorCode: "INVALID_REQUEST"
            )
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        var warning: String?
        if bgPid != nil,
           (keyName.lowercased() == "return" || keyName.lowercased() == "enter"),
           (step.modifiers?.isEmpty ?? true),
           let axEl = resolved.element {
            if AXUIElementPerformAction(axEl, kAXConfirmAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-confirm", node: resolved.node)
            }
            warning = "AXConfirm failed on \(resolved.node?.id ?? "the element"); sent a key event instead."
        }

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "key presses")
            ?? keyWindowGuard(targetApp, input: "key presses", pickerReceiver: pickerReceiver) {
            return refused
        }

        let flags = modifierFlags(from: step.modifiers)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return StepOutcome(success: false, mechanism: "cgevent-key", message: "Failed to construct key CGEvent")
        }

        down.flags = flags
        up.flags = flags
        if let bgPid {
            down.postToPid(bgPid)
            up.postToPid(bgPid)
            return StepOutcome(success: true, mechanism: "cgevent-pid-key", node: resolved.node, warning: warning)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        noteSyntheticInput()
        return StepOutcome(success: true, mechanism: "cgevent-key", node: resolved.node, warning: warning)
    }

    private func performScroll(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        var bgPid = backgroundPid(for: step, targetApp: targetApp)
        let dy = Int32(step.deltaY ?? 0)
        let dx = Int32(step.deltaX ?? 0)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            return StepOutcome(success: false, mechanism: "cgevent-scroll", message: "Failed to create scroll CGEvent", node: resolved.node)
        }

        // Where to scroll: the visible part of the element, the given point, or the middle of the window.
        // Wheel events are routed by location, so a scroll without one (or with a point off screen, like the
        // center of a 5000 px text view) is silently dropped.
        let point = scrollPoint(step: step, node: resolved.node, targetApp: targetApp)
        let pid = resolved.pid > 0 ? resolved.pid : (targetApp?.pid ?? 0)

        // 1. Native scroll views: move the scroll bar through AX. No events, works in the background.
        if pid > 0, let shift = scrollViaScrollBar(pid: pid, point: point, element: resolved.element, dx: Double(dx), dy: Double(dy)) {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            let atEdge = shift.x == 0 && shift.y == 0
            return StepOutcome(
                success: true,
                mechanism: "ax-scrollbar",
                node: resolved.node,
                effect: atEdge ? ActionEffect.none : .changed,
                warning: atEdge ? "Already at the end of the scroll view." : nil,
                scrollDeltaY: shift.y
            )
        }

        let probes = scrollProbes(pid: pid, near: point)

        // The app is in front, but a real wheel event goes to the window on top at the point, which may not be
        // the target window (the user's own window of the same app, or another app's): scroll it in the
        // background then.
        if bgPid == nil {
            if let refused = frontmostGuard(targetApp, input: "scrolling", at: point) {
                return refused
            }
            switch pointerRoute(targetApp, at: point, backgroundAllowed: step.preferBackground != false) {
            case .foreground:
                break
            case .background:
                bgPid = targetApp?.pid
            case .refuse(let covering):
                var refused = coveredWindowOutcome(targetApp: targetApp, covering: covering, input: "scrolling")
                refused.node = resolved.node
                return refused
            }
        }

        if let bgPid {
            if let point {
                scrollEvent.location = point
            }
            Self.routeToWindow(scrollEvent, windowId: targetApp?.windowId)
            scrollEvent.postToPid(bgPid)
            let moved = await measureScroll(probes: probes)
            if moved.map({ abs($0) >= 1 }) != true, dy != 0,
               let fallback = await scrollToNextOffscreen(
                   pid: pid,
                   down: dy < 0,
                   point: point,
                   elementId: resolved.node?.id,
                   targetApp: targetApp,
                   onOverlayEvent: onOverlayEvent
               ) {
                return fallback
            }
            return StepOutcome(success: true, mechanism: "cgevent-pid-scroll", node: resolved.node, scrollDeltaY: moved)
        }

        let savedCursor = CGEvent(source: nil)?.location
        var movedCursor = false
        if let point,
           let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
            movedCursor = true
        }
        scrollEvent.post(tap: .cghidEventTap)
        noteSyntheticInput()
        if movedCursor && step.restoreCursor != false, let savedCursor {
            _ = CGWarpMouseCursorPosition(savedCursor)
        }
        let moved = await measureScroll(probes: probes)
        return StepOutcome(success: true, mechanism: "cgevent-scroll", node: resolved.node, scrollDeltaY: moved)
    }

    /// A point inside both the element and its window (the middle of their overlap).
    private func scrollPoint(step: ActionStep, node: ElementNode?, targetApp: AppDescriptor?) -> CGPoint? {
        if let x = step.x, let y = step.y {
            return CGPoint(x: x, y: y)
        }
        let window = targetWindowFrame(targetApp)
        if let node, node.offscreen != true, node.frame.width > 0, node.frame.height > 0 {
            let rect = CGRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
            if let window {
                let visible = rect.intersection(window)
                if !visible.isNull, visible.width > 1, visible.height > 1 {
                    return CGPoint(x: visible.midX, y: visible.midY)
                }
            } else {
                return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        return window.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Scrolls the AXScrollArea under `element`/`point` by setting its scroll bar values. Returns the content
    /// shift in points (0 when already at the edge), or nil when there is no settable scroll bar.
    private func scrollViaScrollBar(pid: Int32, point: CGPoint?, element: AXUIElement?, dx: Double, dy: Double) -> (x: Double, y: Double)? {
        var start = element
        if start == nil, let point {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &hit) == .success {
                start = hit
            }
        }
        guard var current = start else { return nil }
        var scrollArea: AXUIElement?
        for _ in 0..<12 {
            if Self.axString(current, kAXRoleAttribute) == "AXScrollArea" {
                scrollArea = current
                break
            }
            guard let parent = Self.axElement(current, kAXParentAttribute) else { break }
            current = parent
        }
        guard let area = scrollArea, let areaFrame = Self.axFrame(area) else { return nil }
        let content = Self.axChildren(area, attribute: kAXContentsAttribute).first
            ?? Self.axChildren(area).first { Self.axString($0, kAXRoleAttribute) != "AXScrollBar" }
        guard let contentFrame = content.flatMap({ Self.axFrame($0) }) else { return nil }

        func move(_ barAttribute: String, delta: Double, contentLength: Double, visibleLength: Double) -> Double? {
            guard delta != 0, let bar = Self.axElement(area, barAttribute) else { return nil }
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return nil }
            let range = contentLength - visibleLength
            guard range > 1, let before = Self.axDouble(bar, kAXValueAttribute) else { return nil }
            let target = min(1, max(0, before + (-delta) / range))
            if abs(target - before) < 0.000001 { return 0 }
            guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target)) == .success else { return nil }
            let after = Self.axDouble(bar, kAXValueAttribute) ?? target
            return -(after - before) * range
        }

        let y = move(kAXVerticalScrollBarAttribute, delta: dy, contentLength: Double(contentFrame.height), visibleLength: Double(areaFrame.height))
        let x = move(kAXHorizontalScrollBarAttribute, delta: dx, contentLength: Double(contentFrame.width), visibleLength: Double(areaFrame.width))
        if x == nil && y == nil { return nil }
        return (x ?? 0, y ?? 0)
    }

    /// Web content exposes no scroll bars and may ignore background wheel events. Scrolling the next element
    /// that is out of view into view (AXScrollToVisible) pages through it without any events. The candidate is
    /// taken from the web area or scroll area under `point` (or holding `elementId`), never from the rest of the
    /// window: Chrome lists its infobar and tab strip after the page.
    private func scrollToNextOffscreen(
        pid: Int32,
        down: Bool,
        point: CGPoint?,
        elementId: String?,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome? {
        var layout = axIndexer.latestScrollLayout(pid: pid)
        var elementIndex = elementId.flatMap { id in layout.nodes.firstIndex(where: { $0.id == id }) }
        var index = ScrollFallback.nextOffscreenIndex(
            nodes: layout.nodes,
            containers: layout.containers,
            at: point,
            down: down,
            elementIndex: elementIndex
        )
        if index == nil, !layout.nodes.contains(where: { $0.offscreen == true }), let app = targetApp {
            // Default observes omit offscreen elements; index them on demand before giving up on the fallback.
            _ = axIndexer.observe(
                app: app,
                maxDepth: 40,
                maxElements: 600,
                useCache: false,
                includeDiff: false,
                accessibilityGranted: true,
                includeOffscreen: true
            )
            layout = axIndexer.latestScrollLayout(pid: pid)
            elementIndex = elementId.flatMap { id in layout.nodes.firstIndex(where: { $0.id == id }) }
            index = ScrollFallback.nextOffscreenIndex(
                nodes: layout.nodes,
                containers: layout.containers,
                at: point,
                down: down,
                elementIndex: elementIndex
            )
        }
        guard let index else { return nil }
        let candidate = layout.nodes[index]
        guard let element = axIndexer.element(for: candidate.id, pid: pid) else { return nil }
        guard AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) == .success else { return nil }
        try? await Task.sleep(nanoseconds: 180_000_000)
        let refreshed = axIndexer.liveNode(for: candidate.id, pid: pid)?.node
        guard refreshed?.offscreen != true else { return nil }
        highlight(refreshed, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        return StepOutcome(
            success: true,
            mechanism: "ax-scroll-to-next",
            message: "Scrolled \(down ? "down" : "up") to \(candidate.id) (the next element out of view).",
            node: refreshed,
            effect: .changed,
            warning: "The page ignored the wheel event; UseMac scrolled the next out-of-view element into view instead. Observe again for the new positions."
        )
    }

    private func windowCenter(_ app: AppDescriptor?) -> CGPoint? {
        if let windowId = app?.windowId, let info = WindowResolver.info(windowId: CGWindowID(windowId)) {
            return CGPoint(x: info.frame.midX, y: info.frame.midY)
        }
        if let bounds = app?.windowBounds {
            return CGPoint(x: bounds.centerX, y: bounds.centerY)
        }
        return nil
    }

    private struct ScrollProbe {
        let element: AXUIElement
        let y: Double
    }

    /// A few visible elements near the scroll point whose movement tells whether the scroll worked.
    private func scrollProbes(pid: Int32, near point: CGPoint?) -> [ScrollProbe] {
        guard pid > 0 else { return [] }
        let candidates = axIndexer.latestNodes(pid: pid).filter { node in
            node.offscreen != true && node.role != "AXWindow" && node.role != "AXWebArea"
                && node.frame.height > 4 && node.frame.height < 400
        }
        let sorted = candidates.sorted { a, b in
            guard let point else { return false }
            return abs(a.frame.centerY - point.y) + abs(a.frame.centerX - point.x)
                < abs(b.frame.centerY - point.y) + abs(b.frame.centerX - point.x)
        }
        var probes: [ScrollProbe] = []
        for node in sorted.prefix(12) {
            guard let element = axIndexer.element(for: node.id, pid: pid),
                  let frame = Self.axFrame(element) else { continue }
            probes.append(ScrollProbe(element: element, y: Double(frame.origin.y)))
            if probes.count >= 6 { break }
        }
        return probes
    }

    /// Median vertical shift of the probes after the scroll (nil when nothing could be measured).
    private func measureScroll(probes: [ScrollProbe]) async -> Double? {
        guard !probes.isEmpty else { return nil }
        var best: Double = 0
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 60_000_000)
            var shifts: [Double] = []
            for probe in probes {
                if let frame = Self.axFrame(probe.element) {
                    shifts.append(Double(frame.origin.y) - probe.y)
                } else {
                    shifts.append(.infinity)
                }
            }
            let finite = shifts.filter { $0.isFinite }.sorted()
            if finite.count < shifts.count {
                // Probes disappeared (scrolled out and pruned): the content moved.
                return finite.isEmpty ? -1 : (finite[finite.count / 2] == 0 ? -1 : finite[finite.count / 2])
            }
            if let median = finite.isEmpty ? nil : finite[finite.count / 2], abs(median) >= 1 {
                best = median
                break
            }
        }
        return best
    }

    private func performScrollIntoView(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        guard let element = resolved.element, let id = resolved.node?.id else {
            return StepOutcome(success: false, mechanism: "ax-scroll-to-visible", message: "scrollIntoView needs elementId or match.", errorCode: "INVALID_REQUEST")
        }
        let before = Self.axFrame(element)
        let err = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        guard err == .success else {
            return StepOutcome(
                success: false,
                mechanism: "ax-scroll-to-visible",
                message: "The element does not support AXScrollToVisible (\(err.rawValue)). Use scroll with deltaY near it instead.",
                node: resolved.node
            )
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        let refreshed = axIndexer.liveNode(for: id, pid: resolved.pid)?.node ?? resolved.node
        highlight(refreshed, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let after = Self.axFrame(element)
        let moved: Double? = {
            guard let before, let after else { return nil }
            return Double(after.origin.y - before.origin.y)
        }()
        let alreadyVisible = resolved.node?.offscreen != true && (moved ?? 0) == 0
        return StepOutcome(
            success: true,
            mechanism: "ax-scroll-to-visible",
            message: alreadyVisible ? "Already in view" : nil,
            node: refreshed,
            effect: alreadyVisible ? .unverified : (refreshed?.offscreen == true ? ActionEffect.none : .changed),
            warning: refreshed?.offscreen == true ? "The element is still reported out of view." : nil,
            scrollDeltaY: moved
        )
    }

    private func performAXAction(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        guard let name = step.actionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return StepOutcome(success: false, mechanism: "ax-action", message: "axAction needs actionName (e.g. \"AXOpen\").", errorCode: "INVALID_REQUEST")
        }
        guard let element = resolved.element else {
            return StepOutcome(success: false, mechanism: "ax-action", message: "axAction needs elementId or match.", errorCode: "INVALID_REQUEST")
        }
        let actionName = name.hasPrefix("AX") ? name : "AX" + name.prefix(1).uppercased() + name.dropFirst()
        let supported = resolved.node?.actions ?? []
        highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let err = AXUIElementPerformAction(element, actionName as CFString)
        guard err == .success else {
            return StepOutcome(
                success: false,
                mechanism: "ax-action",
                message: "\(actionName) failed (\(err.rawValue)). The element supports: \(supported.isEmpty ? "no actions" : supported.joined(separator: ", ")).",
                node: resolved.node
            )
        }
        return StepOutcome(
            success: true,
            mechanism: "ax-action",
            node: resolved.node,
            warning: supported.contains(actionName) ? nil : "\(actionName) is not in the element's advertised actions (\(supported.joined(separator: ", "))); check the result."
        )
    }

    private func performWaitFor(step: ActionStep, targetApp: AppDescriptor?) async -> StepOutcome {
        guard let pid = targetApp?.pid, pid > 0 else {
            return StepOutcome(success: false, mechanism: "wait-for", message: "waitFor needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let hasMatch = step.match?.isEmpty == false
        guard hasMatch || step.elementId?.isEmpty == false else {
            return StepOutcome(success: false, mechanism: "wait-for", message: "waitFor needs match or elementId.", errorCode: "INVALID_REQUEST")
        }
        let timeoutMs = min(30_000, max(100, step.timeoutMs ?? step.durationMs ?? 5000))
        let wantGone = step.gone == true
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000

        while true {
            let genBeforeCheck = axIndexer.currentGeneration(pid: pid)
            var found: ElementNode?
            if hasMatch, let match = step.match {
                let index = max(0, match.index ?? 0)
                let hits = axIndexer.find(pid: pid, match: match, limit: index + 1)
                found = hits.count > index ? hits[index].node : nil
            } else if let id = step.elementId {
                found = axIndexer.liveNode(for: id, pid: pid)?.node
            }
            if wantGone ? (found == nil) : (found != nil) {
                return StepOutcome(success: true, mechanism: "wait-for", node: found, effect: .unverified)
            }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= deadline {
                let what = hasMatch ? Self.describe(step.match!) : (step.elementId ?? "element")
                return StepOutcome(
                    success: false,
                    mechanism: "wait-for",
                    message: "Timed out after \(timeoutMs) ms waiting for \(what) to \(wantGone ? "go away" : "appear").",
                    node: found,
                    errorCode: "WAIT_TIMEOUT"
                )
            }
            let remainingMs = Int((deadline - nowNs) / 1_000_000)
            let sliceMs = min(500, max(1, remainingMs))
            let woke = await axIndexer.waitForChange(pid: pid, sinceGeneration: genBeforeCheck, timeoutMs: sliceMs)
            if !woke {
                axIndexer.invalidate(pid: pid)
            }
        }
    }

    // MARK: - Resilient SOTA Steps (assert, scrollUntil, fillForm, menuAction)

    private func performAssert(step: ActionStep, targetApp: AppDescriptor?) -> StepOutcome {
        let hasExpectTitle = !(step.expectTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasExpectText = !(step.expectText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasExpectNotText = !(step.expectNotText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasMatch = step.match?.isEmpty == false
        let hasElementId = !(step.elementId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard hasExpectTitle || hasExpectText || hasExpectNotText || hasMatch || hasElementId else {
            return StepOutcome(
                success: false,
                mechanism: "assert",
                message: "assert requires at least one of expectTitle, expectText, expectNotText, match, or elementId.",
                errorCode: "INVALID_REQUEST"
            )
        }
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(
                success: false,
                mechanism: "assert",
                message: "assert needs a target app.",
                errorCode: "APP_NOT_FOUND"
            )
        }
        let pid = targetApp.pid
        let windowTitle = axIndexer.currentContext(pid: pid)?.windowTitle ?? targetApp.windowTitle ?? ""

        let eval = Self.evaluateAssert(
            step: step,
            appName: targetApp.name,
            windowTitle: windowTitle,
            findMatch: { match in
                let idx = max(0, match.index ?? 0)
                let hits = self.axIndexer.find(pid: pid, match: match, limit: idx + 1)
                return hits.count > idx ? hits[idx].node : nil
            },
            findElementById: { id in
                self.axIndexer.liveNode(for: id, pid: pid)?.node
            }
        )
        return StepOutcome(
            success: eval.passed,
            mechanism: "assert",
            message: eval.message,
            node: eval.node,
            errorCode: eval.passed ? nil : "ASSERTION_FAILED",
            effect: .unverified
        )
    }

    internal static func evaluateAssert(
        step: ActionStep,
        appName: String,
        windowTitle: String,
        findMatch: (ElementMatch) -> ElementNode?,
        findElementById: (String) -> ElementNode?
    ) -> (passed: Bool, message: String, node: ElementNode?) {
        var matchedNode: ElementNode?

        if let expectedTitle = step.expectTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !expectedTitle.isEmpty {
            let normHave = ElementMatcher.normalize(windowTitle)
            let normWant = ElementMatcher.normalize(expectedTitle)
            if !normHave.contains(normWant) {
                return (false, "Expected window title to contain \"\(expectedTitle)\", but got \"\(windowTitle)\".", nil)
            }
        }

        if let expectText = step.expectText?.trimmingCharacters(in: .whitespacesAndNewlines), !expectText.isEmpty {
            let found = findMatch(ElementMatch(text: expectText))
            let titleContains = ElementMatcher.normalize(windowTitle).contains(ElementMatcher.normalize(expectText))
            if found == nil && !titleContains {
                return (false, "Expected text \"\(expectText)\" was not found in \(appName).", nil)
            }
            matchedNode = matchedNode ?? found
        }

        if let expectNotText = step.expectNotText?.trimmingCharacters(in: .whitespacesAndNewlines), !expectNotText.isEmpty {
            let found = findMatch(ElementMatch(text: expectNotText))
            let titleContains = ElementMatcher.normalize(windowTitle).contains(ElementMatcher.normalize(expectNotText))
            if found != nil || titleContains {
                return (false, "Text \"\(expectNotText)\" was unexpectedly present in \(appName).", found)
            }
        }

        let wantGone = step.gone == true
        if let match = step.match, !match.isEmpty {
            let found = findMatch(match)
            if wantGone {
                if found != nil {
                    return (false, "Expected element matching \(describe(match)) to be gone, but it is still present.", found)
                }
            } else {
                guard let found else {
                    return (false, "Expected element matching \(describe(match)) was not found in \(appName).", nil)
                }
                matchedNode = matchedNode ?? found
            }
        } else if let id = step.elementId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let found = findElementById(id)
            if wantGone {
                if found != nil {
                    return (false, "Expected element \(id) to be gone, but it is still present.", found)
                }
            } else {
                guard let found else {
                    return (false, "Expected element \(id) was not found in \(appName).", nil)
                }
                matchedNode = matchedNode ?? found
            }
        }

        return (true, "Assertion passed", matchedNode)
    }

    private func performScrollUntil(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(success: false, mechanism: "scroll-until", message: "scrollUntil needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let effectiveMatch: ElementMatch? = {
            if let m = step.match, !m.isEmpty { return m }
            if let txt = step.expectText?.trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty {
                return ElementMatch(text: txt)
            }
            return nil
        }()
        let hasElementId = !(step.elementId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard effectiveMatch != nil || hasElementId else {
            return StepOutcome(
                success: false,
                mechanism: "scroll-until",
                message: "scrollUntil requires match, expectText, or elementId.",
                errorCode: "INVALID_REQUEST"
            )
        }

        let pid = targetApp.pid
        let maxScrolls = min(30, max(1, step.maxScrolls ?? 8))
        let deltaY = step.deltaY ?? -360
        let deltaX = step.deltaX ?? 0

        func lookupTarget() -> (element: AXUIElement, node: ElementNode)? {
            if let match = effectiveMatch {
                let idx = max(0, match.index ?? 0)
                let hits = axIndexer.find(pid: pid, match: match, limit: idx + 1)
                guard hits.count > idx else { return nil }
                return (hits[idx].element, hits[idx].node)
            }
            if let id = step.elementId {
                return axIndexer.liveNode(for: id, pid: pid)
            }
            return nil
        }

        for attempt in 0...maxScrolls {
            if let found = lookupTarget() {
                if found.node.offscreen != true {
                    highlight(found.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                    return StepOutcome(
                        success: true,
                        mechanism: "scroll-until",
                        message: attempt == 0 ? "Target already visible" : "Found after \(attempt) scroll\(attempt == 1 ? "" : "s")",
                        node: found.node,
                        effect: attempt == 0 ? .unverified : .changed
                    )
                }
                // Found offscreen: try direct AXScrollToVisible before scrolling manually.
                if AXUIElementPerformAction(found.element, "AXScrollToVisible" as CFString) == .success {
                    let gen = axIndexer.currentGeneration(pid: pid)
                    _ = await axIndexer.waitForChange(pid: pid, sinceGeneration: gen, timeoutMs: 150)
                    if let refreshed = axIndexer.liveNode(for: found.node.id, pid: pid), refreshed.node.offscreen != true {
                        highlight(refreshed.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                        return StepOutcome(
                            success: true,
                            mechanism: "scroll-until",
                            message: "Scrolled target into view",
                            node: refreshed.node,
                            effect: .changed
                        )
                    }
                }
            }

            if attempt == maxScrolls { break }

            let genBeforeScroll = axIndexer.currentGeneration(pid: pid)
            let scrollStep = ActionStep(
                action: .scroll,
                x: step.x,
                y: step.y,
                deltaX: deltaX,
                deltaY: deltaY,
                preferBackground: step.preferBackground,
                restoreCursor: step.restoreCursor
            )
            let scrollOutcome = await performScroll(
                step: scrollStep,
                resolved: ResolvedElement(pid: pid),
                targetApp: targetApp,
                onOverlayEvent: onOverlayEvent
            )
            if !scrollOutcome.success {
                return scrollOutcome
            }
            axIndexer.invalidate(pid: pid)
            if scrollOutcome.warning == "Already at the end of the scroll view." {
                break
            }
            _ = await axIndexer.waitForChange(pid: pid, sinceGeneration: genBeforeScroll, timeoutMs: 120)
        }

        let targetDesc = effectiveMatch.map(Self.describe) ?? (step.elementId ?? "target")
        return StepOutcome(
            success: false,
            mechanism: "scroll-until",
            message: "Could not find visible \(targetDesc) after \(maxScrolls) scroll\(maxScrolls == 1 ? "" : "s").",
            errorCode: "ELEMENT_NOT_FOUND"
        )
    }

    private func performFillForm(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(success: false, mechanism: "fill-form", message: "fillForm needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        guard let fields = step.fields, !fields.isEmpty else {
            return StepOutcome(success: false, mechanism: "fill-form", message: "fillForm requires a non-empty fields array.", errorCode: "INVALID_REQUEST")
        }

        var filledCount = 0
        var lastNode: ElementNode?

        for (fieldIdx, field) in fields.enumerated() {
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
                let hint = ExecutionModeNotice.agentHint(policy: killSwitch.policy, killSwitchTripped: killSwitch.isTripped)
                return StepOutcome(
                    success: false,
                    mechanism: "blocked",
                    message: hint.map { "\(blockReason) \($0)" } ?? blockReason,
                    node: lastNode,
                    errorCode: "POLICY_BLOCKED"
                )
            }
            let fieldDesc = field.label ?? field.elementId ?? field.match.map(Self.describe) ?? "field #\(fieldIdx + 1)"
            let fieldMatch: ElementMatch? = {
                if let m = field.match, !m.isEmpty { return m }
                if field.elementId?.isEmpty != false,
                   let label = field.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !label.isEmpty {
                    return ElementMatch(title: label)
                }
                return nil
            }()
            var probeStep = ActionStep(
                action: .setValue,
                elementId: field.elementId,
                preferBackground: step.preferBackground,
                restoreCursor: step.restoreCursor,
                match: fieldMatch
            )

            var fieldResolved: ResolvedElement?
            switch await resolve(step: probeStep, targetApp: targetApp, scrollOffscreenIntoView: true) {
            case .success(let found):
                fieldResolved = found
            case .failure:
                // Fallback for label matching against text (value/title/description) if title-only missed.
                if field.match == nil, field.elementId == nil,
                   let label = field.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    probeStep.match = ElementMatch(text: label)
                    if case .success(let fallbackFound) = await resolve(step: probeStep, targetApp: targetApp, scrollOffscreenIntoView: true) {
                        fieldResolved = fallbackFound
                    }
                }
            }

            guard let resolved = fieldResolved, let axEl = resolved.element else {
                return StepOutcome(
                    success: false,
                    mechanism: "fill-form",
                    message: "Could not locate form field \(fieldDesc).",
                    errorCode: "FORM_FILL_FAILED"
                )
            }

            let role = resolved.node?.role ?? ""
            let isToggleRole = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"].contains(role)

            if field.checked != nil || isToggleRole {
                let wantChecked = field.checked ?? {
                    let v = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return v == "true" || v == "1" || v == "yes" || v == "on"
                }()
                let currentChecked = Self.axBool(axEl, kAXValueAttribute)
                    ?? (resolved.node?.value == "1" || resolved.node?.value?.lowercased() == "true")
                if currentChecked != wantChecked {
                    let toggleRes = performClick(
                        step: ActionStep(action: .click, preferBackground: step.preferBackground, restoreCursor: step.restoreCursor),
                        resolved: resolved,
                        targetApp: targetApp,
                        onOverlayEvent: onOverlayEvent
                    )
                    if !toggleRes.success {
                        return StepOutcome(
                            success: false,
                            mechanism: "fill-form",
                            message: "Failed to toggle \(fieldDesc): \(toggleRes.message ?? toggleRes.errorCode ?? "unknown error")",
                            node: resolved.node,
                            errorCode: "FORM_FILL_FAILED"
                        )
                    }
                }
            } else if role == "AXPopUpButton", let desired = field.value {
                let selected = await selectPopUpOption(
                    element: axEl,
                    desired: desired,
                    pid: resolved.pid,
                    node: resolved.node,
                    targetApp: targetApp,
                    onOverlayEvent: onOverlayEvent
                )
                if !selected {
                    return StepOutcome(
                        success: false,
                        mechanism: "fill-form",
                        message: "Failed to select \"\(desired)\" in \(fieldDesc).",
                        node: resolved.node,
                        errorCode: "FORM_FILL_FAILED"
                    )
                }
            } else if let textValue = field.value {
                let setRes = await performSetValue(
                    step: ActionStep(action: .setValue, text: textValue, preferBackground: step.preferBackground, restoreCursor: step.restoreCursor),
                    resolved: resolved,
                    targetApp: targetApp,
                    onOverlayEvent: onOverlayEvent
                )
                if !setRes.success {
                    return StepOutcome(
                        success: false,
                        mechanism: "fill-form",
                        message: "Failed to set \(fieldDesc): \(setRes.message ?? setRes.errorCode ?? "unknown error")",
                        node: resolved.node,
                        errorCode: "FORM_FILL_FAILED"
                    )
                }
            }

            filledCount += 1
            lastNode = resolved.node
            axIndexer.invalidate(pid: targetApp.pid)
        }

        if let submitMatch = step.submitMatch, !submitMatch.isEmpty {
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
                let hint = ExecutionModeNotice.agentHint(policy: killSwitch.policy, killSwitchTripped: killSwitch.isTripped)
                return StepOutcome(
                    success: false,
                    mechanism: "blocked",
                    message: hint.map { "\(blockReason) \($0)" } ?? blockReason,
                    node: lastNode,
                    errorCode: "POLICY_BLOCKED"
                )
            }
            let submitStep = ActionStep(
                action: .click,
                preferBackground: step.preferBackground,
                restoreCursor: step.restoreCursor,
                match: submitMatch
            )
            switch await resolve(step: submitStep, targetApp: targetApp, scrollOffscreenIntoView: true) {
            case .success(let submitResolved):
                let clickRes = performClick(
                    step: submitStep,
                    resolved: submitResolved,
                    targetApp: targetApp,
                    onOverlayEvent: onOverlayEvent
                )
                if !clickRes.success {
                    return StepOutcome(
                        success: false,
                        mechanism: "fill-form",
                        message: "Filled \(filledCount) field(s), but submit failed: \(clickRes.message ?? clickRes.errorCode ?? "click failed")",
                        node: submitResolved.node,
                        errorCode: "FORM_FILL_FAILED"
                    )
                }
                lastNode = submitResolved.node
            case .failure(let refusal):
                return StepOutcome(
                    success: false,
                    mechanism: "fill-form",
                    message: "Filled \(filledCount) field(s), but submit button was not found: \(refusal.message)",
                    errorCode: "FORM_FILL_FAILED"
                )
            }
        }

        let submitNote = (step.submitMatch?.isEmpty == false) ? " and submitted" : ""
        return StepOutcome(
            success: true,
            mechanism: "fill-form",
            message: "Filled \(filledCount) field\(filledCount == 1 ? "" : "s")\(submitNote)",
            node: lastNode,
            effect: .changed
        )
    }

    private func selectPopUpOption(
        element: AXUIElement,
        desired: String,
        pid: pid_t,
        node: ElementNode?,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> Bool {
        highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        // First try direct AXValue assignment if the popup supports it.
        if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, desired as CFTypeRef) == .success {
            if let rb = Self.axString(element, kAXValueAttribute),
               ElementMatcher.normalize(rb).contains(ElementMatcher.normalize(desired)) {
                return true
            }
        }
        // Otherwise open its AXMenu via AXPress, locate matching AXMenuItem, and press it.
        let gen = axIndexer.currentGeneration(pid: pid)
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            return false
        }
        _ = await axIndexer.waitForChange(pid: pid, sinceGeneration: gen, timeoutMs: 250)
        let wantNorm = ElementMatcher.normalize(desired)
        let children = Self.axChildren(element)
        let menus = children.filter { Self.axString($0, kAXRoleAttribute) == "AXMenu" }
        for menu in menus {
            let items = Self.axChildren(menu)
            if let exact = items.first(where: {
                guard let title = Self.axString($0, kAXTitleAttribute) else { return false }
                return ElementMatcher.normalize(title) == wantNorm
            }) ?? items.first(where: {
                guard let title = Self.axString($0, kAXTitleAttribute) else { return false }
                return ElementMatcher.normalize(title).contains(wantNorm)
            }) {
                return AXUIElementPerformAction(exact, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    private func performMenuAction(
        step: ActionStep,
        targetApp: AppDescriptor?,
        siteRuleGuard: (@Sendable (AppDescriptor) async -> String?)?
    ) async -> StepOutcome {
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(
                success: false,
                mechanism: "ax-menu-action",
                message: "menuAction needs a target app.",
                errorCode: "APP_NOT_FOUND"
            )
        }
        guard let menuPath = step.menuPath, !menuPath.isEmpty else {
            return StepOutcome(
                success: false,
                mechanism: "ax-menu-action",
                message: "menuAction requires a non-empty menuPath (e.g. [\"File\", \"Save\"]).",
                errorCode: "INVALID_REQUEST"
            )
        }
        let pid = targetApp.pid
        let hasPin = WindowResolver.pinnedTitle(pid: pid) != nil
        let chromiumGuard = isChromiumApp(targetApp) ? siteRuleGuard : nil
        let focusedWindowId = (hasPin || chromiumGuard != nil) ? InputRouting.focusedWindowId(pid: pid) : nil
        if hasPin {
            let pinnedId = pinnedWindowId(WorkspaceMonitor.withTargetWindow(targetApp))
            guard let pinnedId, focusedWindowId == pinnedId else {
                return StepOutcome(
                    success: false,
                    mechanism: "ax-menu-action",
                    message: "Menus act on \(targetApp.name)'s key window, not the pinned window. Make the pinned window the key window before using menuAction.",
                    errorCode: "TARGET_NOT_FRONTMOST"
                )
            }
        }
        if let chromiumGuard {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            let focusedWindow = Self.axElement(axApp, kAXFocusedWindowAttribute)
            var focusedApp = targetApp
            focusedApp.windowId = focusedWindowId
            focusedApp.windowTitle = focusedWindow.flatMap { Self.axString($0, kAXTitleAttribute) }
            focusedApp.windowBounds = focusedWindow.flatMap(Self.axFrame).map {
                .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
            }
            if let message = await chromiumGuard(focusedApp) {
                return StepOutcome(success: false, mechanism: "target-rules", message: message, errorCode: TargetRules.errorCode)
            }
            guard InputRouting.focusedWindowId(pid: pid) == focusedWindowId else {
                return StepOutcome(
                    success: false,
                    mechanism: "ax-menu-action",
                    message: "\(targetApp.name)'s key window changed while checking the site. No menu action was sent.",
                    errorCode: "TARGET_NOT_FRONTMOST"
                )
            }
        }
        let inv = MenuBarController.invoke(pid: pid, appName: targetApp.name, path: menuPath)
        return StepOutcome(
            success: inv.success,
            mechanism: "ax-menu-action",
            message: inv.message ?? inv.result.message,
            errorCode: inv.errorCode,
            effect: inv.success ? .changed : nil
        )
    }

    // MARK: - Native file picker

    /// Picks a file in an open panel without Finder navigation or focus: type the file name in the panel's
    /// search field, select the result row with exactly that path and press the panel's Open button (AXOpen
    /// as a fallback). Falls back to ⌘⇧G only when the app is already in front. A file the search can never list
    /// (/tmp, $TMPDIR, hidden folders) goes straight to ⌘⇧G in front, and fails fast in the background.
    private func performNativeUploadFile(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let normalized: [String]
        switch Self.validateAndNormalizeUploadFiles(step.files) {
        case .success(let paths):
            normalized = paths
        case .failure(let err):
            return StepOutcome(success: false, mechanism: "upload-guard", message: err.message, errorCode: "UPLOAD_BLOCKED")
        }
        guard let pid = targetApp?.pid, pid > 0 else {
            return StepOutcome(success: false, mechanism: "nsopenpanel", message: "uploadFile needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let previousFrontApp = frontApp?.processIdentifier == pid ? nil : frontApp

        // Open the picker first when a trigger (button or drop zone) was given.
        if resolved.element != nil || (step.x != nil && step.y != nil) {
            let trigger = performClick(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if !trigger.success {
                var failed = trigger
                failed.mechanism = "nsopenpanel-trigger"
                return failed
            }
        }

        var panel: OpenPanelParts?
        for _ in 0..<40 {
            panel = findOpenPanel(pid: pid)
            if panel != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let file = normalized[0]
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let extra = normalized.count > 1 ? " Only the first file was picked; open the picker again for the others." : ""

        guard let panel else {
            return StepOutcome(
                success: false,
                mechanism: "nsopenpanel",
                message: "No file picker opened in \(targetApp?.name ?? "the app"). Click the upload button first (pass its elementId/match on this step).",
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }

        let appName = targetApp?.name ?? "the app"
        func selected(_ mechanism: String) async -> StepOutcome {
            let warning = await restoreFocusAfterBackgroundUploadIfNeeded(
                targetPid: pid, targetAppName: appName, previousApp: previousFrontApp
            )
            return StepOutcome(success: true, mechanism: mechanism, message: "Selected \(fileName).\(extra)", effect: .changed, warning: warning)
        }

        // 1. Walk the folders like a person would (sidebar → folders → file), selecting rows and pressing Open.
        //    Deterministic and independent of Spotlight.
        if await navigateAndPick(panel: panel, file: file, pid: pid) {
            return await selected("nsopenpanel-navigate")
        }

        // Spotlight never lists files in /tmp, $TMPDIR or hidden folders, and Go to Folder takes no keys in the
        // background (see OpenPanelReach). Say so now instead of searching; with the app in front, go to ⌘⇧G.
        let searchBlocker = OpenPanelReach.searchBlocker(for: file)
        if let searchBlocker, !WindowResolver.isFrontmost(pid: pid) {
            return StepOutcome(
                success: false,
                mechanism: "nsopenpanel-unreachable",
                message: OpenPanelReach.backgroundMessage(fileName: fileName, reason: searchBlocker, appName: targetApp?.name ?? "the app"),
                errorCode: "TARGET_NOT_FRONTMOST"
            )
        }

        // 2. Search by name (Spotlight) when the file's folders are not reachable from the sidebar.
        if searchBlocker == nil, let search = panel.searchField {
            // The picker search is Spotlight: index the file now so a file created seconds ago is found.
            await Self.indexForSpotlight(file)
            _ = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, fileName as CFTypeRef)
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)

            // Spotlight results keep streaming in for a while and the list is rebuilt as they do, which drops
            // a selection made too early. Re-find, re-select and confirm until it sticks (up to ~10 s).
            let targetPath = URL(fileURLWithPath: file).standardizedFileURL.path
            var ambiguous = false
            var sawRow = false
            var pressedOpen = false
            var lastCandidate: AXUIElement?
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if pressedOpen, findOpenPanel(pid: pid) == nil {
                    return await selected("nsopenpanel-search-select")
                }
                let rows = openableRows(in: panel.root, named: fileName)
                let exact = rows.filter { Self.rowURL($0)?.standardizedFileURL.path == targetPath }
                let candidate = exact.first ?? ((rows.count == 1 && Self.rowURL(rows[0]) == nil) ? rows[0] : nil)
                ambiguous = exact.isEmpty && rows.count > 1
                if let candidate, let rowElement = Self.enclosingRow(of: candidate) {
                    sawRow = true
                    if lastCandidate == nil {
                        // Asking the name field to open (even when it reports "unsupported") makes the panel
                        // adopt the row as its real selection, which enables Open; a bare AXSelected does not.
                        _ = AXUIElementPerformAction(candidate, "AXOpen" as CFString)
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if pressedOpen == false, findOpenPanel(pid: pid) == nil {
                            return await selected("nsopenpanel-search-axopen")
                        }
                    }
                    lastCandidate = candidate
                    if Self.axBool(rowElement, kAXSelectedAttribute) != true {
                        _ = AXUIElementSetAttributeValue(rowElement, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if let open = findOpenPanel(pid: pid)?.defaultButton ?? panel.defaultButton,
                       Self.axBool(rowElement, kAXSelectedAttribute) == true,
                       Self.axBool(open, kAXEnabledAttribute) != false {
                        if AXUIElementPerformAction(open, kAXPressAction as CFString) == .success {
                            pressedOpen = true
                            if await waitForPanelToClose(pid: pid) {
                                return await selected("nsopenpanel-search-select")
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            if sawRow {
                // Some panels open the item on AXOpen instead of Open.
                if let candidate = lastCandidate, Self.axActions(candidate).contains("AXOpen"),
                   AXUIElementPerformAction(candidate, "AXOpen" as CFString) == .success,
                   await waitForPanelToClose(pid: pid) {
                    return await selected("nsopenpanel-search-axopen")
                }
            }
            if !OpenPanelReach.shouldAttemptGoToFolderAfterSearchFailure(isFrontmost: WindowResolver.isFrontmost(pid: pid)) {
                if sawRow {
                    return StepOutcome(
                        success: false,
                        mechanism: "nsopenpanel-search",
                        message: "Found \(fileName) in the picker but could not confirm it in the background (Open stayed disabled). Rerun this step in a batch with \"foreground\": true.",
                        errorCode: "UPLOAD_FAILED"
                    )
                }
                return StepOutcome(
                    success: false,
                    mechanism: "nsopenpanel-search",
                    message: ambiguous
                        ? "Several files named \(fileName) showed up in the picker search. Give the file a unique name, or rerun this step in a batch with \"foreground\": true."
                        : "The picker could not be driven in the background: browsing its folders did not enable Open, and its search (Spotlight) did not list \(fileName) yet. Rerun this step in a batch with \"foreground\": true (UseMac types the path with ⌘⇧G and gives focus back), or retry once Spotlight has indexed the file.",
                    errorCode: "ELEMENT_NOT_FOUND"
                )
            }
        }

        // Last resort: ⌘⇧G with real keys, only when the app is in front.
        var outcome = await pickViaGoToFolder(panel: panel, file: file, fileName: fileName, extra: extra, pid: pid, targetApp: targetApp)
        if outcome.success {
            outcome.warning = await restoreFocusAfterBackgroundUploadIfNeeded(
                targetPid: pid, targetAppName: appName, previousApp: previousFrontApp
            )
        }
        return outcome
    }

    private func restoreFocusAfterBackgroundUploadIfNeeded(
        targetPid: Int32,
        targetAppName: String,
        previousApp: NSRunningApplication?
    ) async -> String? {
        guard let previousApp, !previousApp.isTerminated else { return nil }
        // Document apps can activate shortly after the open panel disappears.
        for attempt in 0..<3 {
            if WindowResolver.isFrontmost(pid: targetPid) {
                let idle = WindowResolver.secondsSinceUserInput()
                guard !previousApp.isTerminated, OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
                    previousPid: previousApp.processIdentifier,
                    targetPid: targetPid,
                    targetBecameFrontmost: true,
                    secondsSinceUserInput: idle,
                    ownInputRecent: idleIsFromOwnInput(idle)
                ) else { return nil }
                _ = await waitForApplicationActivation(pid: previousApp.processIdentifier, timeoutMs: 400) {
                    if WindowResolver.isFrontmost(pid: targetPid) {
                        _ = previousApp.activate(options: [])
                    }
                }
                return WindowResolver.isFrontmost(pid: targetPid)
                    ? "Opening the document brought \(targetAppName) to the front and focus could not be returned automatically."
                    : nil
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        return nil
    }

    private func pickViaGoToFolder(
        panel: OpenPanelParts,
        file: String,
        fileName: String,
        extra: String,
        pid: Int32,
        targetApp: AppDescriptor?
    ) async -> StepOutcome {
        if let refused = frontmostGuard(targetApp, input: "keys to the file picker") {
            return refused
        }
        let panelRoot = findOpenPanel(pid: pid)?.root ?? panel.root
        let frontmost = ResolvedElement(pid: pid)

        func press(_ key: String, modifiers: [String] = [], in receiver: AXUIElement) -> StepOutcome {
            performPressKey(
                step: ActionStep(action: .pressKey, key: key, modifiers: modifiers, preferBackground: false),
                resolved: frontmost, targetApp: targetApp, pickerReceiver: receiver
            )
        }
        func result(closed: Bool, detectedField: Bool, failure: StepOutcome? = nil) -> StepOutcome {
            StepOutcome(
                success: closed,
                mechanism: "nsopenpanel-goto",
                message: closed ? "Selected \(fileName) via ⌘⇧G.\(extra)"
                    : failure?.message ?? OpenPanelReach.goToFolderFailureMessage(fileName: fileName, detectedField: detectedField),
                errorCode: closed ? nil : failure?.errorCode ?? "UPLOAD_FAILED",
                effect: closed ? .changed : ActionEffect.none
            )
        }
        Self.raiseAXWindow(panelRoot)
        try? await Task.sleep(for: .milliseconds(80))
        var field = findGoToFolderField(in: panelRoot, pid: pid)
        if field == nil {
            let shortcut = press("g", modifiers: ["cmd", "shift"], in: panelRoot)
            guard shortcut.success else { return result(closed: false, detectedField: false, failure: shortcut) }
            let started = ContinuousClock.now
            let retryAt = started + .milliseconds(600)
            let deadline = started + .milliseconds(1200)
            var retried = false
            while ContinuousClock.now < deadline, field == nil {
                field = findGoToFolderField(in: panelRoot, pid: pid)
                if field == nil, !retried, ContinuousClock.now >= retryAt {
                    retried = true
                    Self.raiseAXWindow(panelRoot)
                    try? await Task.sleep(for: .milliseconds(80))
                    field = findGoToFolderField(in: panelRoot, pid: pid)
                    if field != nil { break }
                    let retry = press("g", modifiers: ["cmd", "shift"], in: panelRoot)
                    guard retry.success else { return result(closed: false, detectedField: false, failure: retry) }
                }
                if field == nil { try? await Task.sleep(for: .milliseconds(80)) }
            }
        }

        guard let field else { return result(closed: false, detectedField: false) }
        if let refused = frontmostGuard(targetApp, input: "the Go to Folder path") {
            return refused
        }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, file as CFTypeRef)
        if Self.axString(field, kAXValueAttribute) != file {
            let selectAll = press("a", modifiers: ["cmd"], in: field)
            guard selectAll.success else { return result(closed: false, detectedField: true, failure: selectAll) }
            let typed = performType(
                step: ActionStep(action: .type, text: file, preferBackground: false),
                resolved: frontmost, targetApp: targetApp, onOverlayEvent: nil, pickerReceiver: field
            )
            guard typed.success else { return result(closed: false, detectedField: true, failure: typed) }
        }

        try? await Task.sleep(for: .milliseconds(150))
        let navigate = press("return", in: field)
        guard navigate.success else { return result(closed: false, detectedField: true, failure: navigate) }

        let navigationStarted = ContinuousClock.now
        let retryAt = navigationStarted + .milliseconds(800)
        let navigationDeadline = navigationStarted + .seconds(2)
        var retried = false
        while let openField = findGoToFolderField(in: panelRoot, pid: pid) {
            guard ContinuousClock.now < navigationDeadline else { return result(closed: false, detectedField: true) }
            if !retried, ContinuousClock.now >= retryAt {
                retried = true
                let retry = press("return", in: openField)
                guard retry.success else { return result(closed: false, detectedField: true, failure: retry) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            guard let currentPanel = findOpenPanel(pid: pid) else { return result(closed: true, detectedField: true) }
            if let open = currentPanel.defaultButton, Self.axBool(open, kAXEnabledAttribute) != false {
                if AXUIElementPerformAction(open, kAXPressAction as CFString) != .success {
                    let confirm = press("return", in: currentPanel.root)
                    guard confirm.success else { return result(closed: false, detectedField: true, failure: confirm) }
                }
                let closed = await waitForPanelToClose(pid: pid)
                return result(closed: closed, detectedField: true)
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return result(closed: false, detectedField: true)
    }

    private func findGoToFolderField(in panelRoot: AXUIElement, pid: Int32) -> AXUIElement? {
        func field(in root: AXUIElement) -> AXUIElement? {
            var queue = [(element: root, depth: 0, inGoToFolderContainer: false)]
            var index = 0
            while index < queue.count {
                let (element, depth, inContainer) = queue[index]
                index += 1
                let role = Self.axString(element, kAXRoleAttribute)
                // Neither list rows nor the browser's web content can contain the path field.
                switch role {
                case "AXRow", "AXOutline", "AXTable", "AXBrowser", "AXWebArea":
                    continue
                default:
                    break
                }
                let inGoToFolderContainer = inContainer
                    || ((role == "AXSheet" || role == "AXPopover") && !CFEqual(element, panelRoot))
                if inGoToFolderContainer, role == "AXComboBox" || role == "AXTextField",
                   OpenPanelReach.isGoToFolderFieldCandidate(
                       role: role,
                       subrole: Self.axString(element, kAXSubroleAttribute),
                       inFileRow: false,
                       isSearchField: false
                   ) {
                    return element
                }
                if depth < 6 {
                    queue.append(contentsOf: Self.axChildren(element).map { ($0, depth + 1, inGoToFolderContainer) })
                }
            }
            return nil
        }

        if let pathField = field(in: panelRoot) { return pathField }

        // Some panels expose Go to Folder under the app's focused or auxiliary window instead.
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        let focused = Self.axElement(axApp, kAXFocusedWindowAttribute)
        if let focused, !CFEqual(focused, panelRoot), let pathField = field(in: focused) {
            return pathField
        }
        for window in Self.axChildren(axApp, attribute: kAXWindowsAttribute)
            where !CFEqual(window, panelRoot) && focused.map({ !CFEqual(window, $0) }) != false {
            let role = Self.axString(window, kAXRoleAttribute)
            let subrole = Self.axString(window, kAXSubroleAttribute)
            if role == "AXSheet" || role == "AXPopover" || subrole == "AXDialog",
               let pathField = field(in: window) {
                return pathField
            }
        }
        return nil
    }

    private struct OpenPanelParts {
        let root: AXUIElement
        let searchField: AXUIElement?
        let defaultButton: AXUIElement?
    }

    /// Button titles that confirm an open panel, in the languages macOS ships most often.
    private static let openButtonTitles: Set<String> = [
        "open", "abrir", "choose", "escolher", "select", "selecionar", "upload", "carregar", "enviar",
        "insert", "inserir", "ouvrir", "öffnen", "abrir archivo", "aprire", "apri"
    ]

    /// The open panel of `pid`: a sheet on its window, a dialog, or (TextEdit, sandboxed apps) a standard
    /// window. Recognized by its own controls near the top of the tree (search field, file list, Open button),
    /// never by deep web content, so a browser window with a search box and a table does not qualify.
    private func findOpenPanel(pid: Int32) -> OpenPanelParts? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        var candidates: [AXUIElement] = []
        if let pinned = WindowResolver.pinnedTitle(pid: pid),
           let window = WindowResolver.window(pid: pid, titleContains: pinned) {
            candidates.append(window)
            candidates.append(contentsOf: Self.axChildren(window).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" })
        }
        if let focused = Self.axElement(axApp, kAXFocusedWindowAttribute) {
            candidates.append(focused)
            candidates.append(contentsOf: Self.axChildren(focused).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" })
        }
        for window in Self.axChildren(axApp, attribute: kAXWindowsAttribute) {
            candidates.append(window)
            candidates.append(contentsOf: Self.axChildren(window).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" })
        }
        for candidate in candidates {
            let role = Self.axString(candidate, kAXRoleAttribute)
            let subrole = Self.axString(candidate, kAXSubroleAttribute)
            guard role == "AXSheet" || subrole == "AXDialog" || subrole == "AXStandardWindow" else { continue }
            guard let search = Self.firstDescendant(of: candidate, maxDepth: 3, where: { element in
                Self.axString(element, kAXSubroleAttribute) == "AXSearchField"
            }) else { continue }
            let hasFileList = Self.firstDescendant(of: candidate, maxDepth: 7, where: { element in
                let r = Self.axString(element, kAXRoleAttribute)
                return r == "AXOutline" || r == "AXBrowser" || r == "AXTable"
            }) != nil
            guard hasFileList else { continue }
            let declaredDefault = Self.axElement(candidate, kAXDefaultButtonAttribute)
            let openButton = declaredDefault ?? Self.firstDescendant(of: candidate, maxDepth: 3, where: { element in
                guard Self.axString(element, kAXRoleAttribute) == "AXButton",
                      let title = Self.axString(element, kAXTitleAttribute) else { return false }
                return Self.openButtonTitles.contains(title.trimmingCharacters(in: .whitespaces).lowercased())
            })
            guard role == "AXSheet" || openButton != nil else { continue }
            return OpenPanelParts(root: candidate, searchField: search, defaultButton: openButton)
        }
        return nil
    }

    /// Result rows whose name cell shows exactly `fileName` (the text element, which carries AXURL).
    private func openableRows(in root: AXUIElement, named fileName: String) -> [AXUIElement] {
        let wanted = fileName.lowercased()
        var rows: [AXUIElement] = []
        Self.collectDescendants(of: root, maxDepth: 18, into: &rows) { element in
            let role = Self.axString(element, kAXRoleAttribute)
            guard role == "AXTextField" || role == "AXStaticText" else { return false }
            guard (Self.axString(element, kAXValueAttribute) ?? "").lowercased() == wanted else { return false }
            // Skip the path bar at the bottom of the panel: only items inside a list row count.
            return Self.enclosingRow(of: element) != nil
        }
        return rows
    }

    /// Selects the deepest sidebar location that contains `file`, then opens each folder below it and finally
    /// the file, by selecting list rows and pressing the panel's Open button. Returns true when the panel closed.
    private func navigateAndPick(
        panel: OpenPanelParts,
        file: String,
        pid: Int32
    ) async -> Bool {
        guard panel.defaultButton != nil else { return false }
        // The panel rebuilds its controls while it loads, so look the Open button up fresh each time.
        func openButton() -> AXUIElement? {
            findOpenPanel(pid: pid)?.defaultButton
        }
        let fm = FileManager.default
        let sidebar = Self.firstDescendant(of: panel.root, maxDepth: 6) { element in
            Self.axString(element, kAXRoleAttribute) == "AXOutline"
                && (Self.axString(element, kAXDescriptionAttribute) ?? "").lowercased().contains("sidebar")
        } ?? Self.firstDescendant(of: panel.root, maxDepth: 6) { Self.axString($0, kAXRoleAttribute) == "AXOutline" }
        guard let sidebar else { return false }

        // Sidebar entries by display name.
        var sidebarRows: [String: AXUIElement] = [:]
        for row in Self.axChildren(sidebar, attribute: kAXRowsAttribute) {
            var texts: [AXUIElement] = []
            Self.collectDescendants(of: row, maxDepth: 3, into: &texts) { Self.axString($0, kAXRoleAttribute) == "AXStaticText" }
            for text in texts {
                if let name = Self.axString(text, kAXValueAttribute), !name.isEmpty, sidebarRows[name] == nil {
                    sidebarRows[name] = row
                }
            }
        }

        // Deepest ancestor folder that the sidebar offers.
        var components = (file as NSString).pathComponents
        let fileComponent = components.removeLast()
        var anchorIndex: Int?
        var anchorRow: AXUIElement?
        for index in stride(from: components.count, through: 2, by: -1) {
            let folder = NSString.path(withComponents: Array(components[0..<index]))
            let display = fm.displayName(atPath: folder)
            if let row = sidebarRows[display] ?? sidebarRows[(folder as NSString).lastPathComponent] {
                anchorIndex = index
                anchorRow = row
                break
            }
        }
        guard let anchorIndex, let anchorRow else { return false }

        // The "Where" popup shows the folder on display; use it to confirm each navigation step.
        func whereValue() -> String? {
            Self.firstDescendant(of: panel.root, maxDepth: 4) { Self.axString($0, kAXIdentifierAttribute) == "where popup" }
                .flatMap { Self.axString($0, kAXValueAttribute) }
        }
        func waitForFolder(_ names: Set<String>) async -> Bool {
            for _ in 0..<20 {
                if let shown = whereValue() {
                    if names.contains(shown.lowercased()) { return true }
                } else {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    return true
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return false
        }

        let anchorPath = NSString.path(withComponents: Array(components[0..<anchorIndex]))
        guard AXUIElementSetAttributeValue(anchorRow, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success,
              await waitForFolder([fm.displayName(atPath: anchorPath).lowercased(), (anchorPath as NSString).lastPathComponent.lowercased()]) else {
            return false
        }

        var steps = Array(components[anchorIndex...])
        steps.append(fileComponent)
        var currentPath = anchorPath
        for (offset, name) in steps.enumerated() {
            currentPath = (currentPath as NSString).appendingPathComponent(name)
            let display = fm.displayName(atPath: currentPath)
            let isLast = offset == steps.count - 1

            var confirmed = false
            for _ in 0..<3 where !confirmed {
                var row: AXUIElement?
                for _ in 0..<10 {
                    row = folderListRow(in: panel.root, named: [name, display])
                    if row != nil { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                Self.panelDebug("step \(name) row=\(row != nil)")
                guard let row else { return false }
                _ = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                var open = openButton()
                for _ in 0..<15 where Self.axBool(row, kAXSelectedAttribute) != true || open.map({ Self.axBool($0, kAXEnabledAttribute) == false }) != false {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    open = openButton()
                }
                Self.panelDebug("  selected=\(String(describing: Self.axBool(row, kAXSelectedAttribute))) openEnabled=\(String(describing: open.flatMap { Self.axBool($0, kAXEnabledAttribute) })) where=\(whereValue() ?? "nil")")
                // Some panels (sandboxed apps host theirs out of process) do not enable Open for a selection
                // made through AX while browsing folders. Give up fast and let the search path try.
                guard Self.axBool(row, kAXSelectedAttribute) == true, let open, Self.axBool(open, kAXEnabledAttribute) != false else { return false }
                let pressed = AXUIElementPerformAction(open, kAXPressAction as CFString)
                Self.panelDebug("  press=\(pressed.rawValue)")
                guard pressed == .success else { continue }
                if isLast {
                    return await waitForPanelToClose(pid: pid)
                }
                confirmed = await waitForFolder([name.lowercased(), display.lowercased()])
                Self.panelDebug("  confirmed=\(confirmed) where=\(whereValue() ?? "nil")")
            }
            if !confirmed { return false }
        }
        return false
    }

    static func panelDebug(_ message: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["USEMAC_DEBUG_PANEL"] == "1" {
            FileHandle.standardError.write(Data("[panel] \(message())\n".utf8))
        }
    }

    /// A row of the panel's file list whose name is one of `names`, in the folder being shown (rows inside
    /// an expanded subfolder are skipped; rows under a date-group header count). The list is looked up again
    /// every time because the panel replaces it after each navigation.
    private func folderListRow(in root: AXUIElement, named names: [String]) -> AXUIElement? {
        let wanted = Set(names.map { $0.lowercased() })
        guard let list = Self.firstDescendant(of: root, maxDepth: 8, where: { element in
            let role = Self.axString(element, kAXRoleAttribute)
            guard role == "AXOutline" || role == "AXTable" else { return false }
            if Self.axString(element, kAXIdentifierAttribute) == "ListView" { return true }
            return !(Self.axString(element, kAXDescriptionAttribute) ?? "").lowercased().contains("sidebar")
        }) else { return nil }
        for row in Self.axChildren(list, attribute: kAXRowsAttribute) {
            guard let nameField = Self.rowNameField(row),
                  wanted.contains((Self.axString(nameField, kAXValueAttribute) ?? "").lowercased()) else { continue }
            if let owner = Self.axElement(row, "AXDisclosedByRow"), Self.rowNameField(owner) != nil {
                continue
            }
            return row
        }
        return nil
    }

    /// The editable name field of a file-list row (group headers have none).
    private static func rowNameField(_ row: AXUIElement) -> AXUIElement? {
        for cell in axChildren(row).prefix(2) {
            for child in axChildren(cell) where axString(child, kAXRoleAttribute) == "AXTextField" {
                return child
            }
        }
        return nil
    }

    /// Runs `mdimport` on a user file so Spotlight (and the open panel search) knows it right away.
    private static func indexForSpotlight(_ path: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        for _ in 0..<30 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
        }
        // Give the index a moment to answer queries.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func enclosingRow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current else { return nil }
            if axString(node, kAXRoleAttribute) == "AXRow" { return node }
            current = axElement(node, kAXParentAttribute)
        }
        return nil
    }

    private func waitForPanelToClose(pid: Int32) async -> Bool {
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if findOpenPanel(pid: pid) == nil { return true }
        }
        return false
    }

    private static func rowURL(_ element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<3 {
            guard let node = current else { return nil }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &value) == .success {
                if let url = value as? URL { return url }
                if let string = value as? String, let url = URL(string: string) { return url }
            }
            current = axElement(node, kAXParentAttribute)
        }
        return nil
    }

    // MARK: - Small AX helpers

    private static func raiseAXWindow(_ window: AXUIElement) {
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func isHosted(in window: AXUIElement, element: AXUIElement) -> Bool {
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

    private func backgroundPid(for step: ActionStep, targetApp: AppDescriptor?) -> pid_t? {
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

    private func isChromiumApp(_ app: AppDescriptor?) -> Bool {
        NativeBrowserSiteRules.isChromiumApp(bundleId: app?.bundleId, name: app?.name)
    }

    /// AppKit routes mouse and wheel events to a window by these fields; events posted straight to a pid
    /// arrive without them, so a background app has no window to deliver them to.
    private static func routeToWindow(_ event: CGEvent, windowId: UInt32?) {
        guard let windowId else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowId))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowId))
    }

    private func postMouseClick(
        at point: CGPoint,
        button: CGMouseButton,
        clickCount: Int,
        restoreCursor: Bool,
        targetPid: pid_t? = nil,
        windowId: UInt32? = nil
    ) -> Bool {
        let savedCursor = targetPid == nil ? CGEvent(source: nil)?.location : nil
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp

        for clickState in 1...max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                return false
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            if let targetPid {
                Self.routeToWindow(down, windowId: windowId)
                Self.routeToWindow(up, windowId: windowId)
                down.postToPid(targetPid)
                up.postToPid(targetPid)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }

        if targetPid == nil, restoreCursor, let savedCursor {
            _ = CGWarpMouseCursorPosition(savedCursor)
        }
        return true
    }

    private func typeUnicodeString(_ text: String, targetPid: pid_t? = nil) -> Bool {
        guard !text.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let utf16 = Array(text.utf16)
        // Post in small chunks to avoid exceeding CGEvent unicode string buffer limits
        let chunkSize = 16
        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var slice = Array(utf16[index..<end])

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }

            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            if let targetPid {
                down.postToPid(targetPid)
                up.postToPid(targetPid)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }

            index = end
        }
        return true
    }

    private func modifierFlags(from modifiers: [String]?) -> CGEventFlags {
        ModifierAliases.eventFlags(modifiers)
    }
}
