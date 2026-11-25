import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

public final class ActionExecutor: @unchecked Sendable {
    private let axIndexer: AXIndexer
    private let workspaceMonitor: WorkspaceMonitor
    private let killSwitch: KillSwitch

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
        var currentApp = workspaceMonitor.resolveApp(query: request.app)
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
                    message: blockReason
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
            let outcome = await executeStep(step, targetApp: currentApp, onOverlayEvent: onOverlayEvent)
            let stepLatencyMs = Double(DispatchTime.now().uptimeNanoseconds - stepStartNs) / 1_000_000.0

            if let resolvedApp = outcome.resolvedApp {
                currentApp = resolvedApp
            }

            if step.action != .wait && step.action != .target && step.action != .hover {
                axIndexer.invalidate(pid: currentApp?.pid)
            }

            let result = ActionStepResult(
                index: index,
                action: step.action,
                success: outcome.success,
                mechanism: outcome.mechanism,
                latencyMs: stepLatencyMs,
                message: outcome.message
            )
            stepResults.append(result)

            let stepTitle = formatStepTitle(step: step, node: outcome.node, app: currentApp)
            let baseSubtitle = "\(outcome.mechanism) · \(String(format: "%.1f ms", stepLatencyMs))"
            let stepSubtitle: String
            if !outcome.success, let msg = outcome.message, !msg.isEmpty {
                stepSubtitle = "\(baseSubtitle) · \(msg)"
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
                elementId: step.elementId,
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

        let totalLatencyMs = Double(DispatchTime.now().uptimeNanoseconds - batchStartNs) / 1_000_000.0
        return (
            BatchActionResult(
                success: allSucceeded,
                totalLatencyMs: totalLatencyMs,
                stepResults: stepResults,
                observation: nil
            ),
            currentApp
        )
    }

    private struct StepOutcome {
        let success: Bool
        let mechanism: String
        let message: String?
        let node: ElementNode?
        let resolvedApp: AppDescriptor?

        init(
            success: Bool,
            mechanism: String,
            message: String? = nil,
            node: ElementNode? = nil,
            resolvedApp: AppDescriptor? = nil
        ) {
            self.success = success
            self.mechanism = mechanism
            self.message = message
            self.node = node
            self.resolvedApp = resolvedApp
        }
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
        case .target, .scroll, .hover, .wait:
            return false
        case .openURL, .navigate, .click, .doubleClick, .rightClick, .setValue, .type, .pressKey, .focus, .uploadFile:
            return true
        }
    }

    private func isSensitiveStep(_ step: ActionStep) -> Bool {
        if step.action == .uploadFile {
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

    private func executeStep(
        _ step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        switch step.action {
        case .target:
            guard let app = workspaceMonitor.resolveApp(query: step.app) ?? targetApp else {
                return StepOutcome(success: false, mechanism: "workspace-target", message: "Target app not found")
            }
            if step.preferBackground == false {
                _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [])
            }
            return StepOutcome(success: true, mechanism: "workspace-target", message: "Targeted \(app.name)", resolvedApp: app)

        case .focus:
            return performFocus(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .openURL, .navigate:
            let normalizedURL: String
            switch NavigationPolicy.validate(step.url ?? step.text) {
            case .success(let validURL):
                normalizedURL = validURL
            case .failure(let blocked):
                return StepOutcome(
                    success: false,
                    mechanism: "open-url",
                    message: blocked.message
                )
            }
            guard let parsedURL = URL(string: normalizedURL) else {
                return StepOutcome(
                    success: false,
                    mechanism: "open-url",
                    message: "Invalid URL."
                )
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = (step.preferBackground == false)
            do {
                _ = try await NSWorkspace.shared.open(parsedURL, configuration: config)
                return StepOutcome(success: true, mechanism: "nsworkspace-open", message: "Opened \(normalizedURL)")
            } catch {
                return StepOutcome(success: false, mechanism: "nsworkspace-open", message: error.localizedDescription)
            }

        case .click:
            return performClick(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .doubleClick:
            return performDoubleClick(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .rightClick:
            return performRightClick(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .hover:
            return performHover(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .setValue:
            return performSetValue(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .type:
            return performType(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)

        case .pressKey:
            return performPressKey(step: step, targetApp: targetApp)

        case .scroll:
            return performScroll(step: step, targetApp: targetApp)

        case .wait:
            let ms = max(0, step.durationMs ?? 250)
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return StepOutcome(success: true, mechanism: "sleep", message: "Waited \(ms)ms")

        case .uploadFile:
            return await performNativeUploadFile(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        }
    }

    private func performNativeUploadFile(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let normalized: [String]
        switch Self.validateAndNormalizeUploadFiles(step.files) {
        case .success(let paths):
            normalized = paths
        case .failure(let err):
            return StepOutcome(success: false, mechanism: "upload-guard", message: err.message)
        }

        // If a trigger button elementId/coordinates were provided, click it first to open NSOpenPanel
        if step.elementId != nil || (step.x != nil && step.y != nil) {
            let clickRes = performClick(step: step, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if !clickRes.success {
                return StepOutcome(success: false, mechanism: "nsopenpanel-trigger", message: clickRes.message)
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        // Deterministic macOS NSOpenPanel flow: Cmd+Shift+G ("Go to Folder") -> absolute path -> Return -> Return
        let firstFile = normalized[0]
        let goShortcut = ActionStep(action: .pressKey, key: "g", modifiers: ["cmd", "shift"], preferBackground: step.preferBackground)
        _ = performPressKey(step: goShortcut, targetApp: targetApp)
        try? await Task.sleep(nanoseconds: 240_000_000)

        let typeStep = ActionStep(action: .type, text: firstFile, preferBackground: step.preferBackground)
        let typed = performType(step: typeStep, targetApp: targetApp, onOverlayEvent: nil)
        guard typed.success else {
            return StepOutcome(success: false, mechanism: "nsopenpanel-goto", message: typed.message ?? "Failed to type path in Go to Folder")
        }
        try? await Task.sleep(nanoseconds: 180_000_000)

        let retStep = ActionStep(action: .pressKey, key: "return", preferBackground: step.preferBackground)
        _ = performPressKey(step: retStep, targetApp: targetApp)
        try? await Task.sleep(nanoseconds: 260_000_000)
        _ = performPressKey(step: retStep, targetApp: targetApp)

        let name = URL(fileURLWithPath: firstFile).lastPathComponent
        return StepOutcome(success: true, mechanism: "nsopenpanel-goto", message: "Selected \(name) via Cmd+Shift+G")
    }

    private func resolveElement(
        elementId: String?,
        targetApp: AppDescriptor?
    ) -> (pid: Int32, axElement: AXUIElement?, node: ElementNode?) {
        guard let elementId else {
            return (targetApp?.pid ?? 0, nil, nil)
        }
        if let pid = targetApp?.pid {
            let axEl = axIndexer.element(for: elementId, pid: pid)
            let node = axIndexer.node(for: elementId, pid: pid)
            if axEl != nil || node != nil {
                return (pid, axEl, node)
            }
        }
        if let found = axIndexer.node(for: elementId) {
            let axEl = axIndexer.element(for: elementId, pid: found.pid)
            return (found.pid, axEl, found.node)
        }
        return (targetApp?.pid ?? 0, nil, nil)
    }

    private func resolvePoint(step: ActionStep, node: ElementNode?) -> CGPoint? {
        if let x = step.x, let y = step.y {
            return CGPoint(x: x, y: y)
        }
        if let node {
            return CGPoint(x: node.frame.centerX, y: node.frame.centerY)
        }
        return nil
    }

    private func performFocus(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        if let axEl = resolved.axElement {
            if let node = resolved.node {
                onOverlayEvent?(.highlightElement(rect: node.frame, label: node.id, role: node.role, durationMs: 600))
            }
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
                return StepOutcome(success: true, mechanism: "background-noop-focus", node: resolved.node)
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
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        // Chromium's native "New Tab" AXPress triggers BrowserWindow::Activate() and steals focus.
        // Intercept in background mode and dispatch zero-focus Cmd+T directly to the background PID.
        if let bgPid,
           let node = resolved.node,
           node.role == "AXButton",
           let title = node.title?.lowercased(),
           (title == "new tab" || title == "nova guia"),
           isChromiumApp(targetApp) {
            onOverlayEvent?(.highlightElement(rect: node.frame, label: node.id, role: node.role, durationMs: 600))
            let shortcutStep = ActionStep(action: .pressKey, key: "t", modifiers: ["cmd"], preferBackground: true)
            let res = performPressKey(step: shortcutStep, targetApp: targetApp)
            return StepOutcome(success: res.success, mechanism: "cgevent-pid-newtab", message: res.message, node: node)
        }

        if step.preferBackground != false,
           let axEl = resolved.axElement,
           let node = resolved.node,
           node.actions.contains("AXPress") {
            onOverlayEvent?(.highlightElement(rect: node.frame, label: node.id, role: node.role, durationMs: 600))
            if AXUIElementPerformAction(axEl, kAXPressAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-press", node: node)
            }
        }

        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or cached element \(step.elementId ?? "")",
                node: resolved.node
            )
        }

        onOverlayEvent?(.pulsePoint(x: Double(point.x), y: Double(point.y), label: step.elementId ?? "click"))
        let ok = postMouseClick(
            at: point,
            button: .left,
            clickCount: 1,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid
        )
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post CGEvent click",
            node: resolved.node
        )
    }

    private func performHover(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
                message: "Missing coordinates or cached element \(step.elementId ?? "")",
                node: resolved.node
            )
        }

        if let node = resolved.node {
            onOverlayEvent?(.highlightElement(rect: node.frame, label: node.id, role: node.role, durationMs: 600))
        } else {
            onOverlayEvent?(.pulsePoint(x: Double(point.x), y: Double(point.y), label: "hover"))
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return StepOutcome(success: false, mechanism: "cgevent-hover", message: "Failed to construct CGEvent mouseMoved", node: resolved.node)
        }
        if let bgPid {
            moveEvent.postToPid(bgPid)
        } else {
            moveEvent.post(tap: .cghidEventTap)
        }
        return StepOutcome(
            success: true,
            mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
            message: nil,
            node: resolved.node
        )
    }

    private func performDoubleClick(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or cached element \(step.elementId ?? "")",
                node: resolved.node
            )
        }

        onOverlayEvent?(.pulsePoint(x: Double(point.x), y: Double(point.y), label: step.elementId ?? "doubleClick"))
        let ok = postMouseClick(
            at: point,
            button: .left,
            clickCount: 2,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid
        )
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post double click",
            node: resolved.node
        )
    }

    private func performRightClick(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or cached element \(step.elementId ?? "")",
                node: resolved.node
            )
        }

        onOverlayEvent?(.pulsePoint(x: Double(point.x), y: Double(point.y), label: step.elementId ?? "rightClick"))
        let ok = postMouseClick(
            at: point,
            button: .right,
            clickCount: 1,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid
        )
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post right click",
            node: resolved.node
        )
    }

    private func performSetValue(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let text = step.text ?? ""
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        if step.preferBackground != false, let axEl = resolved.axElement {
            if let node = resolved.node {
                onOverlayEvent?(.highlightElement(rect: node.frame, label: node.id, role: node.role, durationMs: 600))
            }
            // IMPORTANT: Never set kAXFocusedAttribute while app is in background!
            // In Chromium/Electron, kAXFocusedAttribute calls Widget::Activate() and steals focus/Spaces.
            if bgPid == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            if AXUIElementSetAttributeValue(axEl, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                return StepOutcome(success: true, mechanism: "ax-set-value", node: resolved.node)
            }
        }

        if bgPid == nil {
            if let point = resolvePoint(step: step, node: resolved.node) {
                onOverlayEvent?(.pulsePoint(x: Double(point.x), y: Double(point.y), label: step.elementId ?? "setValue"))
                _ = postMouseClick(at: point, button: .left, clickCount: 1, restoreCursor: step.restoreCursor != false, targetPid: nil)
            } else if step.elementId != nil && resolved.axElement == nil {
                return StepOutcome(
                    success: false,
                    mechanism: "ax-set-value",
                    message: "Cached element \(step.elementId ?? "") not found",
                    node: resolved.node
                )
            }
        } else if step.elementId != nil && resolved.axElement == nil {
            return StepOutcome(
                success: false,
                mechanism: "ax-set-value",
                message: "Cached element \(step.elementId ?? "") not found",
                node: resolved.node
            )
        }

        let ok = typeUnicodeString(text, targetPid: bgPid)
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-unicode" : "cgevent-unicode",
            message: ok ? nil : "Failed to type text",
            node: resolved.node
        )
    }

    private func performType(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let text = step.text ?? ""
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        if let axEl = resolved.axElement {
            if let node = resolved.node {
                onOverlayEvent?(.highlightElement(rect: node.frame, label: node.id, role: node.role, durationMs: 600))
            }
            // Only set kAXFocusedAttribute if already frontmost; otherwise it activates background Chromium/Electron windows.
            if bgPid == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        if bgPid == nil,
           let point = resolvePoint(step: step, node: resolved.node),
           step.elementId != nil || (step.x != nil && step.y != nil) {
            onOverlayEvent?(.pulsePoint(x: Double(point.x), y: Double(point.y), label: step.elementId ?? "type"))
            _ = postMouseClick(at: point, button: .left, clickCount: 1, restoreCursor: step.restoreCursor != false, targetPid: nil)
        }

        let ok = typeUnicodeString(text, targetPid: bgPid)
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-unicode" : "cgevent-unicode",
            message: ok ? nil : "Failed to type text",
            node: resolved.node
        )
    }

    private func performPressKey(step: ActionStep, targetApp: AppDescriptor?) -> StepOutcome {
        guard let keyName = step.key?.trimmingCharacters(in: .whitespacesAndNewlines),
              let keyCode = Self.keyCodeMap[keyName.lowercased()] else {
            return StepOutcome(
                success: false,
                mechanism: "cgevent-key",
                message: "Unsupported or missing key: \(step.key ?? "<nil>")"
            )
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        if bgPid != nil,
           (keyName.lowercased() == "return" || keyName.lowercased() == "enter"),
           (step.modifiers?.isEmpty ?? true),
           let elementId = step.elementId {
            let resolved = resolveElement(elementId: elementId, targetApp: targetApp)
            if let axEl = resolved.axElement,
               AXUIElementPerformAction(axEl, kAXConfirmAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-confirm", node: resolved.node)
            }
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
            return StepOutcome(success: true, mechanism: "cgevent-pid-key", message: nil)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return StepOutcome(success: true, mechanism: "cgevent-key", message: nil)
    }

    private func performScroll(step: ActionStep, targetApp: AppDescriptor?) -> StepOutcome {
        let resolved = resolveElement(elementId: step.elementId, targetApp: targetApp)
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
            return StepOutcome(
                success: false,
                mechanism: "cgevent-scroll",
                message: "Failed to create scroll CGEvent",
                node: resolved.node
            )
        }

        if let bgPid {
            scrollEvent.postToPid(bgPid)
            return StepOutcome(success: true, mechanism: "cgevent-pid-scroll", node: resolved.node)
        }

        let savedCursor = CGEvent(source: nil)?.location
        var movedCursor = false

        if let point = resolvePoint(step: step, node: resolved.node),
           let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
            movedCursor = true
        }

        scrollEvent.post(tap: .cghidEventTap)

        if movedCursor && step.restoreCursor != false, let savedCursor {
            _ = CGWarpMouseCursorPosition(savedCursor)
        }

        return StepOutcome(success: true, mechanism: "cgevent-scroll", node: resolved.node)
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

    private func postMouseClick(
        at point: CGPoint,
        button: CGMouseButton,
        clickCount: Int,
        restoreCursor: Bool,
        targetPid: pid_t? = nil
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
