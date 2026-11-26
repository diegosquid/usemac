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

    public func executeBatch(
        _ request: BatchActionRequest,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)? = nil,
        onLiveActivity: (@Sendable (LiveActivityItem) -> Void)? = nil
    ) async -> (result: BatchActionResult, resolvedApp: AppDescriptor?) {
        let batchStartNs = DispatchTime.now().uptimeNanoseconds
        let requestTarget = workspaceMonitor.resolveTarget(query: request.app)
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
            isInProgress: true
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
                title: "Did not run",
                subtitle: refusal.message,
                mechanism: refusal.mechanism,
                latencyMs: 0,
                success: false,
                isInProgress: false
            ))
            return finish(false)
        }

        var burst: ForegroundBurst?
        if request.foreground == true {
            switch await beginForegroundBurst(targetApp: currentApp) {
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
                    isInProgress: true
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

        var allSucceeded = true

        for (index, step) in request.steps.enumerated() {
            if let blockReason = killSwitch.isBlocked(
                forSensitiveAction: isSensitiveStep(step),
                isMutatingAction: isMutatingStep(step)
            ) {
                allSucceeded = false
                stepResults.append(ActionStepResult(
                    index: index,
                    action: step.action,
                    success: false,
                    mechanism: "blocked",
                    latencyMs: 0,
                    message: blockReason,
                    errorCode: "POLICY_BLOCKED"
                ))
                onLiveActivity?(LiveActivityItem(
                    kind: .policyOrSafety,
                    appName: currentApp?.name,
                    appPid: currentApp?.pid,
                    bundleId: currentApp?.bundleId,
                    windowTitle: currentApp?.windowTitle,
                    windowBounds: currentApp?.windowBounds,
                    title: "Blocked \(step.action.rawValue)",
                    subtitle: blockReason,
                    elementId: step.elementId,
                    mechanism: "blocked",
                    latencyMs: 0,
                    success: false,
                    isInProgress: false
                ))
                if request.stopOnError {
                    break
                }
                continue
            }

            if let stepAppQuery = step.app, !stepAppQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentApp = workspaceMonitor.resolveApp(query: stepAppQuery)
            }

            let stepStartNs = DispatchTime.now().uptimeNanoseconds
            var outcome: StepOutcome
            if let burst, let pid = currentApp?.pid, pid == burst.targetPid, !WindowResolver.isFrontmost(pid: pid) {
                // The user (or another app) took the front during the burst: stop sending real input.
                outcome = notFrontmostOutcome(targetApp: currentApp, input: "input")
            } else {
                outcome = await executeStep(step, targetApp: currentApp, onOverlayEvent: onOverlayEvent)
            }
            let stepLatencyMs = Double(DispatchTime.now().uptimeNanoseconds - stepStartNs) / 1_000_000.0

            if let resolvedApp = outcome.resolvedApp {
                currentApp = resolvedApp
            }

            if step.action != .wait && step.action != .target && step.action != .hover && step.action != .waitFor {
                axIndexer.invalidate(pid: currentApp?.pid)
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
                resolvedElementId: outcome.node?.id
            )
            stepResults.append(result)

            let stepTitle = formatStepTitle(step: step, node: outcome.node, app: currentApp)
            let baseSubtitle = "\(outcome.mechanism) · \(String(format: "%.1f ms", stepLatencyMs))"
            let stepSubtitle: String
            if !outcome.success, let msg = outcome.message, !msg.isEmpty {
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
                isInProgress: true
            ))

            if !outcome.success {
                allSucceeded = false
                if request.stopOnError {
                    break
                }
            }
        }

        if let burst {
            await endForegroundBurst(burst)
        }

        return finish(allSucceeded)
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

        init(
            success: Bool,
            mechanism: String,
            message: String? = nil,
            node: ElementNode? = nil,
            resolvedApp: AppDescriptor? = nil,
            errorCode: String? = nil,
            effect: ActionEffect? = nil,
            warning: String? = nil,
            scrollDeltaY: Double? = nil
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
        case .target, .scroll, .hover, .wait, .scrollIntoView, .waitFor:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile, .axAction:
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
        guard step.action == .pressKey, let modifiers = step.modifiers else {
            return false
        }
        let lower = Set(modifiers.map { $0.lowercased() })
        return lower.contains("cmd")
            || lower.contains("command")
            || lower.contains("ctrl")
            || lower.contains("control")
    }

    // MARK: - Preconditions

    /// Stale-snapshot and expected-title checks. Returns a refusal when the batch must not run.
    private func preflightRefusal(_ request: BatchActionRequest, targetApp: AppDescriptor?) -> Refusal? {
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
            (step.elementId?.isEmpty == false) && (step.match == nil || step.match?.isEmpty == true)
        }
        let expected = request.expectWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesSnapshotIds || (expected?.isEmpty == false) else { return nil }

        let current = axIndexer.currentContext(pid: pid)

        if usesSnapshotIds, let snapshot = axIndexer.snapshotContext(pid: pid), let current {
            if let before = snapshot.windowId, let now = current.windowId, before != now {
                return Refusal(
                    mechanism: "stale-check",
                    errorCode: "STALE_SNAPSHOT",
                    message: "The \(targetApp?.name ?? "app") window changed since the last observe (now \"\(current.windowTitle ?? "untitled")\"). Element ids would hit the wrong place: observe again, or use `match`."
                )
            }
            if let before = snapshot.windowTitle, let now = current.windowTitle,
               Self.comparableTitle(before) != Self.comparableTitle(now) {
                return Refusal(
                    mechanism: "stale-check",
                    errorCode: "STALE_SNAPSHOT",
                    message: "The window now shows \"\(now)\" but the last observe saw \"\(before)\". Observe again, or use `match`, or pass allowStaleSnapshot if this is expected."
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

    /// Letters only, folded: unread counters, emoji and punctuation do not make a window "different".
    static func comparableTitle(_ title: String) -> String {
        let letters = title.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return ElementMatcher.normalize(String(letters))
    }

    // MARK: - Foreground burst

    private func beginForegroundBurst(targetApp: AppDescriptor?) async -> Result<ForegroundBurst, Refusal> {
        guard let app = targetApp, app.pid > 0,
              let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            return .failure(Refusal(mechanism: "foreground-burst", errorCode: "APP_NOT_FOUND", message: "A foreground burst needs a running target app."))
        }
        let idle = WindowResolver.secondsSinceUserInput()
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
            _ = running.activate(options: [])
            var waitedMs = 0
            while !WindowResolver.isFrontmost(pid: app.pid) && waitedMs < 1500 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waitedMs += 50
            }
            guard WindowResolver.isFrontmost(pid: app.pid) else {
                return .failure(Refusal(
                    mechanism: "foreground-burst",
                    errorCode: "TARGET_NOT_FRONTMOST",
                    message: "\(app.name) did not come to the front, so nothing was sent."
                ))
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return .success(ForegroundBurst(
            targetPid: app.pid,
            previousApp: previous?.processIdentifier == app.pid ? nil : previous,
            savedCursor: cursor
        ))
    }

    private func endForegroundBurst(_ burst: ForegroundBurst) async {
        if let cursor = burst.savedCursor {
            _ = CGWarpMouseCursorPosition(cursor)
        }
        // Give the screen back only if the target is still in front (the user may already have moved on).
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

    // MARK: - Step dispatch

    private func executeStep(
        _ step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
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
        let baseline = pid > 0 ? captureBaseline(pid: pid, resolved: resolved) : nil

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
            outcome = performSetValue(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
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
        case .target, .wait, .waitFor, .openURL, .navigate:
            outcome = StepOutcome(success: false, mechanism: "dispatch", message: "Unreachable step type")
        }

        if outcome.success, outcome.effect == nil {
            if let baseline, Self.checksEffect(step.action) {
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

    private func resolvePoint(step: ActionStep, node: ElementNode?) -> CGPoint? {
        if let x = step.x, let y = step.y {
            return CGPoint(x: x, y: y)
        }
        if let node, node.offscreen != true, node.frame.width > 0, node.frame.height > 0 {
            return CGPoint(x: node.frame.centerX, y: node.frame.centerY)
        }
        return nil
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
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        return EffectBaseline(
            pid: pid,
            changeCount: axIndexer.changeCount(pid: pid),
            element: resolved.element,
            value: resolved.element.flatMap { Self.axString($0, kAXValueAttribute) },
            focused: resolved.element.flatMap { Self.axBool($0, kAXFocusedAttribute) },
            frame: resolved.element.flatMap { Self.axFrame($0) },
            focusedElement: Self.axElement(axApp, kAXFocusedUIElementAttribute)
        )
    }

    /// Watches for AX notifications or attribute changes after an action. `none` only when nothing at all
    /// changed in the window, so it is a conservative signal.
    private func measureEffect(baseline: EffectBaseline, outcome: StepOutcome) async -> ActionEffect {
        if outcome.scrollDeltaY.map({ abs($0) >= 1 }) == true {
            return .changed
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.effectWindowMs * 1_000_000
        repeat {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if axIndexer.changeCount(pid: baseline.pid) != baseline.changeCount {
                return .changed
            }
            if let element = baseline.element {
                if Self.axString(element, kAXValueAttribute) != baseline.value { return .changed }
                if Self.axBool(element, kAXFocusedAttribute) != baseline.focused { return .changed }
                if let before = baseline.frame, let now = Self.axFrame(element), before != now { return .changed }
            }
            let axApp = AXUIElementCreateApplication(baseline.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            let focusedNow = Self.axElement(axApp, kAXFocusedUIElementAttribute)
            switch (baseline.focusedElement, focusedNow) {
            case (nil, nil):
                break
            case let (before?, now?):
                if !CFEqual(before, now) { return .changed }
            default:
                return .changed
            }
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return .none
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

        guard let point = resolvePoint(step: step, node: resolved.node) else {
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

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point) {
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
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "mouse movement", at: point) {
            return refused
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
        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point) {
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
        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point) {
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
    ) -> StepOutcome {
        let text = step.text ?? ""
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        let omniboxWarning = isChromiumApp(targetApp) && Self.isAddressBar(resolved.node)
            ? "Typing into Chrome's address bar acts on whichever tab is active at that moment. To navigate, use browser_open with tabId (works on Web Store and chrome:// pages too)."
            : nil

        if step.preferBackground != false, let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            // IMPORTANT: Never set kAXFocusedAttribute while app is in background!
            // In Chromium/Electron, kAXFocusedAttribute calls Widget::Activate() and steals focus/Spaces.
            if bgPid == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            if AXUIElementSetAttributeValue(axEl, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                let readBack = Self.axString(axEl, kAXValueAttribute)
                let isToggle = ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(resolved.node?.role ?? "")
                let isSecure = Self.axString(axEl, kAXSubroleAttribute) == "AXSecureTextField"
                if !isToggle, !isSecure, let readBack, ElementMatcher.normalize(readBack) != ElementMatcher.normalize(text) {
                    return StepOutcome(
                        success: true,
                        mechanism: "ax-set-value",
                        node: resolved.node,
                        effect: ActionEffect.none,
                        warning: "The field reads back \"\(readBack.prefix(60))\" instead of the text you set: the app may have rejected or reformatted it."
                    )
                }
                return StepOutcome(success: true, mechanism: "ax-set-value", node: resolved.node, effect: .changed, warning: omniboxWarning)
            }
        }

        if bgPid == nil {
            if let refused = frontmostGuard(targetApp, input: "typing", at: resolvePoint(step: step, node: resolved.node)) {
                return refused
            }
            if let point = resolvePoint(step: step, node: resolved.node) {
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

    private static func isAddressBar(_ node: ElementNode?) -> Bool {
        guard let node, node.role == "AXTextField" else { return false }
        let title = (node.title ?? "").lowercased()
        return title.contains("address") || title.contains("endereço") || title.contains("omnibox")
    }

    private func performType(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let text = step.text ?? ""
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "typing", at: resolvePoint(step: step, node: resolved.node)) {
            return refused
        }

        if let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            // Only set kAXFocusedAttribute if already frontmost; otherwise it activates background Chromium/Electron windows.
            if bgPid == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        if bgPid == nil,
           let point = resolvePoint(step: step, node: resolved.node),
           resolved.node != nil || (step.x != nil && step.y != nil) {
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

    private func performPressKey(step: ActionStep, resolved: ResolvedElement, targetApp: AppDescriptor?) -> StepOutcome {
        guard let keyName = step.key?.trimmingCharacters(in: .whitespacesAndNewlines),
              let keyCode = Self.keyCodeMap[keyName.lowercased()] else {
            return StepOutcome(
                success: false,
                mechanism: "cgevent-key",
                message: "Unsupported or missing key: \(step.key ?? "<nil>")",
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

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "key presses") {
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
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
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

        if let bgPid {
            if let point {
                scrollEvent.location = point
            }
            Self.routeToWindow(scrollEvent, windowId: targetApp?.windowId)
            scrollEvent.postToPid(bgPid)
            let moved = await measureScroll(probes: probes)
            if moved.map({ abs($0) >= 1 }) != true, dy != 0,
               let fallback = await scrollToNextOffscreen(pid: pid, down: dy < 0, targetApp: targetApp, onOverlayEvent: onOverlayEvent) {
                return fallback
            }
            return StepOutcome(success: true, mechanism: "cgevent-pid-scroll", node: resolved.node, scrollDeltaY: moved)
        }

        if let refused = frontmostGuard(targetApp, input: "scrolling", at: point) {
            return refused
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
        let window: CGRect? = {
            if let windowId = targetApp?.windowId, let info = WindowResolver.info(windowId: CGWindowID(windowId)) {
                return info.frame
            }
            return targetApp?.windowBounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        }()
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
    /// that is out of view into view (AXScrollToVisible) pages through it without any events.
    private func scrollToNextOffscreen(
        pid: Int32,
        down: Bool,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome? {
        let nodes = axIndexer.latestNodes(pid: pid)
        guard let firstVisible = nodes.firstIndex(where: { $0.offscreen != true && $0.role != "AXWindow" }),
              let lastVisible = nodes.lastIndex(where: { $0.offscreen != true && $0.role != "AXWindow" }) else { return nil }
        let candidate: ElementNode? = down
            ? nodes[(lastVisible + 1)...].first(where: { $0.offscreen == true })
            : nodes[..<firstVisible].last(where: { $0.offscreen == true })
        guard let candidate, let element = axIndexer.element(for: candidate.id, pid: pid) else { return nil }
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
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                let what = hasMatch ? Self.describe(step.match!) : (step.elementId ?? "element")
                return StepOutcome(
                    success: false,
                    mechanism: "wait-for",
                    message: "Timed out after \(timeoutMs) ms waiting for \(what) to \(wantGone ? "go away" : "appear").",
                    node: found,
                    errorCode: "WAIT_TIMEOUT"
                )
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
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

        // 1. Walk the folders like a person would (sidebar → folders → file), selecting rows and pressing Open.
        //    Deterministic and independent of Spotlight.
        if await navigateAndPick(panel: panel, file: file, pid: pid) {
            return StepOutcome(success: true, mechanism: "nsopenpanel-navigate", message: "Selected \(fileName).\(extra)", effect: .changed)
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
                    return StepOutcome(success: true, mechanism: "nsopenpanel-search-select", message: "Selected \(fileName).\(extra)", effect: .changed)
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
                            return StepOutcome(success: true, mechanism: "nsopenpanel-search-axopen", message: "Selected \(fileName).\(extra)", effect: .changed)
                        }
                    }
                    lastCandidate = candidate
                    if Self.axBool(rowElement, kAXSelectedAttribute) != true {
                        _ = AXUIElementSetAttributeValue(rowElement, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if let open = findOpenPanel(pid: pid)?.defaultButton ?? panel.defaultButton,
                       Self.axBool(rowElement, kAXSelectedAttribute) == true,
                       Self.axBool(open, kAXEnabledAttribute) != false,
                       AXUIElementPerformAction(open, kAXPressAction as CFString) == .success {
                        pressedOpen = true
                        if await waitForPanelToClose(pid: pid) {
                            return StepOutcome(success: true, mechanism: "nsopenpanel-search-select", message: "Selected \(fileName).\(extra)", effect: .changed)
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
                    return StepOutcome(success: true, mechanism: "nsopenpanel-search-axopen", message: "Selected \(fileName).\(extra)", effect: .changed)
                }
                return StepOutcome(
                    success: false,
                    mechanism: "nsopenpanel-search",
                    message: "Found \(fileName) in the picker but could not confirm it in the background (Open stayed disabled). Rerun this step in a batch with \"foreground\": true.",
                    errorCode: "UPLOAD_FAILED"
                )
            } else if !WindowResolver.isFrontmost(pid: pid) {
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
        if let refused = frontmostGuard(targetApp, input: "keys to the file picker") {
            return refused
        }
        let frontmost = ResolvedElement(pid: pid)
        _ = performPressKey(step: ActionStep(action: .pressKey, key: "g", modifiers: ["cmd", "shift"], preferBackground: false), resolved: frontmost, targetApp: targetApp)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let typed = performType(step: ActionStep(action: .type, text: file, preferBackground: false), resolved: frontmost, targetApp: targetApp, onOverlayEvent: nil)
        guard typed.success else {
            return StepOutcome(success: false, mechanism: "nsopenpanel-goto", message: typed.message ?? "Failed to type path in Go to Folder", errorCode: typed.errorCode)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let returnKey = ActionStep(action: .pressKey, key: "return", preferBackground: false)
        _ = performPressKey(step: returnKey, resolved: frontmost, targetApp: targetApp)
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = performPressKey(step: returnKey, resolved: frontmost, targetApp: targetApp)
        let closed = await waitForPanelToClose(pid: pid)
        return StepOutcome(
            success: closed,
            mechanism: "nsopenpanel-goto",
            message: closed ? "Selected \(fileName) via ⌘⇧G.\(extra)" : "The picker is still open after ⌘⇧G.",
            errorCode: closed ? nil : "UPLOAD_FAILED",
            effect: closed ? .changed : ActionEffect.none
        )
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
    private func navigateAndPick(panel: OpenPanelParts, file: String, pid: Int32) async -> Bool {
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
        var modPrefix = ""
        if let modifiers {
            let lower = Set(modifiers.map { $0.lowercased() })
            if lower.contains("ctrl") || lower.contains("control") { modPrefix += "⌃" }
            if lower.contains("alt") || lower.contains("opt") || lower.contains("option") { modPrefix += "⌥" }
            if lower.contains("shift") { modPrefix += "⇧" }
            if lower.contains("cmd") || lower.contains("command") { modPrefix += "⌘" }
        }
        let rawKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formattedKey = rawKey.count == 1 ? rawKey.uppercased() : rawKey.capitalized
        return modPrefix + (formattedKey.isEmpty ? "Key" : formattedKey)
    }

    private func isChromiumApp(_ app: AppDescriptor?) -> Bool {
        guard let app else { return false }
        let bid = (app.bundleId ?? "").lowercased()
        let name = app.name.lowercased()
        return bid.contains("chrome")
            || bid.contains("chromium")
            || bid.contains("brave")
            || bid.contains("thebrowser")
            || name.contains("chrome")
            || name.contains("brave")
            || name.contains("arc")
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
        guard let modifiers else { return [] }
        var flags: CGEventFlags = []
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt", "opt", "option":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                break
            }
        }
        return flags
    }

    private static let keyCodeMap: [String: CGKeyCode] = [
        "return": 0x24,
        "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33,
        "backspace": 0x33,
        "escape": 0x35,
        "esc": 0x35,
        "left": 0x7B,
        "right": 0x7C,
        "down": 0x7D,
        "up": 0x7E,
        "a": 0x00,
        "s": 0x01,
        "d": 0x02,
        "f": 0x03,
        "h": 0x04,
        "g": 0x05,
        "z": 0x06,
        "x": 0x07,
        "c": 0x08,
        "v": 0x09,
        "b": 0x0B,
        "q": 0x0C,
        "w": 0x0D,
        "e": 0x0E,
        "r": 0x0F,
        "y": 0x10,
        "t": 0x11,
        "1": 0x12,
        "2": 0x13,
        "3": 0x14,
        "4": 0x15,
        "6": 0x16,
        "5": 0x17,
        "9": 0x19,
        "7": 0x1A,
        "8": 0x1C,
        "0": 0x1D,
        "o": 0x1F,
        "u": 0x20,
        "i": 0x22,
        "p": 0x23,
        "l": 0x25,
        "j": 0x26,
        "k": 0x28,
        "n": 0x2D,
        "m": 0x2E
    ]
}
