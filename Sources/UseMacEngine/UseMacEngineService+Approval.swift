import AppKit
import CoreGraphics
import Foundation
import UseMacProtocol

/// Sensitive steps in Ask mode, and mutations on targets with an Ask rule, wait for an answer in the HUD.
extension UseMacEngineService {
    /// Returns a refusal or waits for approval when required. `browserAct` supplies the validated browser steps
    /// (including canonical file paths) in place of the wire payload.
    func approvalRefusal(for request: RPCRequest, startNs: UInt64, browserAct: BrowserActParams? = nil) async -> RPCResponse? {
        let mode = killSwitch.getPolicy()
        guard !killSwitch.isTripped, mode != .paused, mode != .readOnly else { return nil }
        var checked = request
        if let browserAct { checked.browserAct = browserAct }

        let targetCheck = await targetRuleApproval(for: checked)
        let held: HeldRequest
        switch targetCheck {
        case .refuse(let error):
            return targetApprovalRefusal(error, request: checked, startNs: startNs)
        case .hold(let prompt):
            held = prompt
        case .none:
            guard mode == .ask, let prompt = approvalRequest(for: checked) else { return nil }
            held = prompt
        }
        let ask = held.request
        let stepsText = ask.steps.joined(separator: "; ")
        onLiveActivity?(held.activity(title: "Waiting for your OK", subtitle: stepsText, success: true, inProgress: true))

        let killSwitch = self.killSwitch
        let targetAsk = ask.kinds.contains(.targetRule)
        let sensitive = !ask.kinds.subtracting([.targetRule]).isEmpty
        let cancelReason: @Sendable () -> String? = {
            if killSwitch.isTripped { return "the Kill Switch was used" }
            let mode = killSwitch.getPolicy()
            if mode == .paused || mode == .readOnly || (mode == .confirmSensitive && sensitive) || (!targetAsk && mode != .ask) {
                return "the execution mode changed"
            }
            return nil
        }
        var outcome = await approvals.requestApproval(ask, cancelReason: cancelReason)
        if outcome.isAllowed {
            if request.method == .act, request.act?.foreground == true {
                // The click on Allow is the user's own input: let them settle before the burst takes the screen.
                await waitForUserToSettle()
            }
            // A tab can navigate or the native window can change while the user answers. A different target
            // cannot use that answer, even when it was a grant for the same task.
            switch await targetRuleApproval(for: checked) {
            case .refuse(let error):
                return targetApprovalRefusal(error, request: checked, startNs: startNs)
            case .hold(let current) where !targetAsk || current.request.grantTarget != ask.grantTarget:
                return targetApprovalRefusal(
                    RPCErrorPayload(code: "POLICY_BLOCKED", message: "The target changed while waiting for approval, so nothing ran. Retry to check the new target."),
                    request: checked, startNs: startNs
                )
            default:
                break
            }
            if let reason = cancelReason() { outcome = .cancelled(reason: reason) }
        }
        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        appendAudit(
            method: request.method.rawValue,
            targetApp: ask.target,
            summary: "\(Self.auditPhrase(for: outcome)): \(stepsText)",
            latencyMs: latencyMs,
            success: outcome.isAllowed
        )

        let code: String
        let message: String
        let activityTitle: String
        var hint: String?
        switch outcome {
        case .allowedOnce, .allowedForTask, .allowedByTaskGrant:
            return nil
        case .denied:
            code = "APPROVAL_DENIED"
            message = "The user denied this step in UseMac (\(stepsText) in \(ask.target)). Nothing was run."
            activityTitle = "Step denied"
        case .timedOut(let seconds, let whileQueued):
            code = "APPROVAL_TIMEOUT"
            let queued = whileQueued ? " while another approval was on screen" : ""
            message = "Nobody answered UseMac's approval prompt within \(seconds) s\(queued) (\(stepsText) in \(ask.target)), so nothing was run."
            activityTitle = "No answer: step not run"
        case .cancelled(let reason):
            code = "POLICY_BLOCKED"
            message = "This step was waiting for approval when \(reason), so nothing was run."
            activityTitle = "Approval cancelled"
            hint = ExecutionModeNotice.agentHint(policy: killSwitch.getPolicy(), killSwitchTripped: killSwitch.isTripped)
                ?? ExecutionModeNotice.modeChangedWhileWaitingHint
        }
        onLiveActivity?(held.activity(title: activityTitle, subtitle: message, success: false, inProgress: false, latencyMs: latencyMs))
        return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs, hint: hint)
    }

    /// Where the app shows the approval prompt (global coordinates, top-left origin), or nil once it is gone. UseMac
    /// refuses to post real mouse input there.
    public func setApprovalPromptFrame(_ frame: CGRect?) {
        killSwitch.approvalPromptFrame = frame
    }

    /// The prompt dropped a click some process posted. Logged once per prompt.
    public func noteIgnoredApprovalInput(promptId: String, sourcePid: Int64) {
        guard approvals.shouldAuditIgnoredInput(promptId: promptId) else { return }
        let prompt = approvals.currentPrompt
        let poster = NSRunningApplication(processIdentifier: pid_t(truncatingIfNeeded: sourcePid))?.localizedName
        let who = poster.map { "\($0), pid \(sourcePid)" } ?? "pid \(sourcePid)"
        appendAudit(
            method: prompt?.method ?? "approval",
            targetApp: prompt?.target,
            summary: "Approval prompt ignored a click posted by a process (\(who)); only a physical click answers it",
            latencyMs: 0,
            success: false,
            agent: prompt?.agentName
        )
    }

    // MARK: - What a request asks for

    struct HeldRequest {
        var request: ApprovalBroker.Request
        var appName: String?
        var appPid: Int32?
        var bundleId: String?
        var browserTabId: Int?
        var browserProfile: String?
        var targetGuessed: Bool

        func activity(title: String, subtitle: String, success: Bool, inProgress: Bool, latencyMs: Double? = nil) -> LiveActivityItem {
            LiveActivityItem(
                kind: inProgress ? .actionStep : .policyOrSafety,
                appName: appName,
                appPid: appPid,
                bundleId: bundleId,
                title: title,
                subtitle: subtitle,
                mechanism: "approval",
                latencyMs: latencyMs,
                success: success,
                isInProgress: inProgress,
                browserTabId: browserTabId,
                browserProfile: browserProfile,
                targetGuessed: targetGuessed ? true : nil
            )
        }
    }

    /// The prompt for `request`, or nil when nothing in it is sensitive.
    func approvalRequest(for request: RPCRequest) -> HeldRequest? {
        let taskId = runningNamedTaskId(of: request)
        let agentName = approvalAgent(for: request, taskId: taskId)
        switch request.method {
        case .act:
            guard let act = request.act else { return nil }
            let sensitive = act.steps.compactMap { step in ApprovalText.kind(of: step).map { (step, $0) } }
            guard !sensitive.isEmpty else { return nil }
            let mainApp = workspaceMonitor.resolveApp(query: act.app)
            let guessed = workspaceMonitor.isGuessedTarget(requestApp: act.app, stepApps: act.steps.map(\.app))
            let mainName = mainApp?.name ?? ApprovalText.clean(act.app, limit: 60) ?? "the app in front"
            var targets: Set<String> = []
            let lines = sensitive.map { step, _ -> String in
                var line = ApprovalText.describe(step)
                if let stepQuery = ApprovalText.clean(step.app, limit: 60) {
                    let stepName = workspaceMonitor.resolveApp(query: stepQuery)?.name ?? stepQuery
                    targets.insert(stepName.lowercased())
                    if stepName != mainName { line += " in \(stepName)" }
                } else {
                    targets.insert(mainName.lowercased())
                }
                return line
            }
            let target = guessed ? "\(mainName) (the app in front)" : mainName
            return HeldRequest(
                request: ApprovalBroker.Request(
                    method: request.method.rawValue,
                    target: target,
                    steps: ApprovalText.capped(lines),
                    kinds: Set(sensitive.map(\.1)),
                    // A task grant is tied to one app; a batch that spans apps is asked about every time.
                    taskId: targets.count == 1 ? taskId : nil,
                    grantTarget: "app:" + (targets.first ?? mainName.lowercased()),
                    agentName: agentName
                ),
                appName: mainApp?.name ?? mainName,
                appPid: mainApp?.pid,
                bundleId: mainApp?.bundleId,
                targetGuessed: guessed
            )

        case .browserAct, .browserOpen:
            let params = request.browserAct
            let open = request.browserOpen
            let tabId = params?.tabId ?? open?.tabId
            let sensitive = (params?.steps ?? open?.steps ?? []).compactMap { step in ApprovalText.kind(of: step).map { (step, $0) } }
            guard !sensitive.isEmpty else { return nil }
            let profile = params?.profile ?? open?.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            return HeldRequest(
                request: ApprovalBroker.Request(
                    method: request.method.rawValue,
                    target: browserTargetLabel(profile: profile, tabId: tabId),
                    steps: ApprovalText.capped(sensitive.map { ApprovalText.describe($0.0) }),
                    kinds: Set(sensitive.map(\.1)),
                    taskId: taskId,
                    grantTarget: "chrome:" + profile.lowercased(),
                    agentName: agentName
                ),
                appName: "Chrome (\(profile))",
                browserTabId: tabId,
                browserProfile: profile,
                targetGuessed: false
            )

        case .browserExtract:
            guard let params = request.browserExtract,
                  params.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "eval" else { return nil }
            let profile = params.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            return HeldRequest(
                request: ApprovalBroker.Request(
                    method: request.method.rawValue,
                    target: browserTargetLabel(profile: profile, tabId: params.tabId),
                    steps: [ApprovalText.describeScript(params.expression)],
                    kinds: [.script],
                    taskId: taskId,
                    grantTarget: "chrome:" + profile.lowercased(),
                    agentName: agentName
                ),
                appName: "Chrome (\(profile))",
                browserTabId: params.tabId,
                browserProfile: profile,
                targetGuessed: false
            )

        default:
            return nil
        }
    }

    private enum TargetRuleApproval {
        case none
        case hold(HeldRequest)
        case refuse(RPCErrorPayload)
    }

    private func targetRuleApproval(for request: RPCRequest) async -> TargetRuleApproval {
        let rules = TargetRulesStore.shared.rules
        let hasSitePolicies = !rules.askSites.isEmpty || !rules.readOnlySites.isEmpty
        let hasNativePolicies = hasSitePolicies || !rules.askApps.isEmpty || !rules.readOnlyApps.isEmpty
        switch request.method {
        case .act:
            guard hasNativePolicies, let act = request.act, act.steps.contains(where: isMutatingStepForPolicy) else {
                return .none
            }
            let mainApp = workspaceMonitor.resolveApp(query: act.app)
            let stepApps = act.steps.compactMap { step -> AppDescriptor? in
                let query = step.app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !query.isEmpty || step.action == .target else { return nil }
                return workspaceMonitor.resolveApp(query: query)
            }
            return await nativeTargetRuleApproval(
                request: request, rules: rules, apps: [mainApp].compactMap { $0 } + stepApps,
                window: act.window, windowAppPid: mainApp?.pid, steps: act.steps,
                guessed: workspaceMonitor.isGuessedTarget(requestApp: act.app, stepApps: act.steps.map(\.app))
            )
        case .appMenu:
            guard hasNativePolicies, let params = request.appMenu else { return .none }
            let path = (params.menuPath ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !path.isEmpty, let app = workspaceMonitor.resolveApp(query: params.app) else { return .none }
            return await nativeTargetRuleApproval(
                request: request, rules: rules, apps: [app],
                line: "Choose menu \(path.joined(separator: " > "))"
            )
        case .browserAct:
            guard hasSitePolicies, let params = request.browserAct,
                  params.steps.contains(where: isMutatingStepForPolicy) || params.dialogAction != nil else { return .none }
            return await browserTargetRuleApproval(
                request: request, profile: params.profile, tabId: params.tabId,
                candidateURLs: Self.navigationDestinations(in: params.steps), checksTab: true,
                steps: params.steps, extraLine: params.dialogAction == nil ? nil : "Answer a browser dialog"
            )
        case .browserOpen:
            guard hasSitePolicies, let params = request.browserOpen else { return .none }
            let steps = params.steps ?? []
            let overlays = params.autoDismissOverlays == true ? "Dismiss browser overlays" : nil
            let dialog = params.dialogAction != nil ? "Answer a browser dialog" : nil
            let extras = [overlays, dialog].compactMap { $0 }
            guard steps.contains(where: isMutatingStepForPolicy) || !extras.isEmpty else { return .none }
            return await browserTargetRuleApproval(
                request: request, profile: params.profile, tabId: params.tabId,
                candidateURLs: [params.url] + Self.navigationDestinations(in: steps),
                checksTab: params.tabId != nil || (params.newTab == false && params.newWindow != true),
                steps: steps, extraLine: extras.isEmpty ? nil : extras.joined(separator: "; ")
            )
        case .browserExtract:
            guard hasSitePolicies, let params = request.browserExtract,
                  params.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "eval" else { return .none }
            return await browserTargetRuleApproval(
                request: request, profile: params.profile, tabId: params.tabId,
                candidateURLs: [], checksTab: true, steps: [], extraLine: AuditRedactor.evalSummary(params.expression ?? "", recordText: false),
                extraKinds: [.script]
            )
        default:
            return .none
        }
    }

    private func nativeTargetRuleApproval(
        request: RPCRequest, rules: TargetRules, apps: [AppDescriptor],
        window: String? = nil, windowAppPid: Int32? = nil, steps: [ActionStep] = [], line: String? = nil,
        guessed: Bool = false
    ) async -> TargetRuleApproval {
        var seen = Set<Int32>()
        var identities: [String] = []
        var approvalApp: AppDescriptor?
        var labels: [String] = []
        var readOnlyMessage: String?
        for app in apps where seen.insert(app.pid).inserted {
            let appPolicy = rules.effectiveAppPolicy(bundleId: app.bundleId)
            if appPolicy == .block {
                return .refuse(RPCErrorPayload(code: TargetRules.errorCode, message: TargetRules.blockedAppMessage(app.name)))
            }
            let site = await withActionWindow(app.pid == windowAppPid ? window : nil, app: app) {
                await NativeBrowserSiteRules.windowSiteDecision(for: $0, rules: rules, chromeBridge: chromeBridge)
            }
            if let message = site.blockedMessage {
                return .refuse(RPCErrorPayload(code: TargetRules.errorCode, message: message))
            }
            switch appPolicy.combined(with: site.policy) {
            case .readOnly:
                if readOnlyMessage == nil {
                    readOnlyMessage = appPolicy == .readOnly
                        ? TargetRules.readOnlyAppMessage(app.name)
                        : TargetRules.readOnlySiteMessage(host: site.site?.host)
                }
            case .ask:
                if approvalApp == nil { approvalApp = app }
                let name = ApprovalText.clean(app.name, limit: 60) ?? "This app"
                let host = ApprovalText.clean(site.site?.host, limit: 48)
                labels.append(host.map { "\(name) (\($0))" } ?? name)
                let appKey = app.bundleId?.lowercased() ?? String(app.pid)
                identities.append("app:\(appKey):\(Self.siteApprovalKey(site.site))")
            default:
                break
            }
        }
        if let readOnlyMessage {
            return .refuse(RPCErrorPayload(code: "POLICY_BLOCKED", message: readOnlyMessage, hint: TargetRules.stopHint))
        }
        guard let app = approvalApp else { return .none }
        let details = Self.targetApprovalSteps(steps, extraLine: line)
        let taskId = seen.count == 1 ? runningNamedTaskId(of: request) : nil
        let target = labels.joined(separator: ", ")
        return .hold(HeldRequest(
            request: ApprovalBroker.Request(
                method: request.method.rawValue, target: guessed ? "\(target) (the app in front)" : target,
                steps: details.lines, kinds: details.kinds, taskId: taskId,
                grantTarget: identities.sorted().joined(separator: "|"), agentName: approvalAgent(for: request, taskId: taskId)
            ),
            appName: app.name, appPid: app.pid, bundleId: app.bundleId, targetGuessed: guessed
        ))
    }

    private func browserTargetRuleApproval(
        request: RPCRequest, profile: String?, tabId: Int?, candidateURLs: [String],
        checksTab: Bool, steps: [ActionStep], extraLine: String?, extraKinds: Set<ApprovalKind> = []
    ) async -> TargetRuleApproval {
        let target = await chromeBridge.governedSiteDecision(
            profile: profile, tabId: tabId, candidateURLs: candidateURLs, checksTab: checksTab
        )
        if let error = target.failure?.error { return .refuse(error) }
        if target.policy == .readOnly {
            return .refuse(RPCErrorPayload(
                code: "POLICY_BLOCKED", message: TargetRules.readOnlySiteMessage(host: target.site?.host), hint: TargetRules.stopHint
            ))
        }
        guard target.policy == .ask else { return .none }

        let profileName = target.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
        let label = checksTab
            ? browserTargetLabel(profile: profileName, tabId: target.tabId)
            : "Chrome (\(profileName)) · new tab"
        let host = ApprovalText.clean(target.site?.host, limit: 60)
        let details = Self.targetApprovalSteps(steps, extraLine: extraLine)
        // A navigation batch can reach several sites. Never reuse a grant keyed to just one of them.
        let taskId = checksTab && candidateURLs.isEmpty ? runningNamedTaskId(of: request) : nil
        let identity = "chrome:\(profileName.lowercased()):\(target.tabId.map(String.init) ?? "new"):\(Self.siteApprovalKey(target.site))"
        return .hold(HeldRequest(
            request: ApprovalBroker.Request(
                method: request.method.rawValue, target: host.map { "\(label) · \($0)" } ?? label,
                steps: details.lines, kinds: details.kinds.union(extraKinds), taskId: taskId,
                grantTarget: identity, agentName: approvalAgent(for: request, taskId: taskId)
            ),
            appName: "Chrome (\(profileName))", browserTabId: target.tabId, browserProfile: profileName, targetGuessed: false
        ))
    }

    private static func navigationDestinations(in steps: [ActionStep]) -> [String] {
        steps.compactMap { step in
            guard step.action == .navigate || step.action == .openURL, let url = step.url ?? step.text else { return nil }
            if case .success(let normalized) = NavigationPolicy.validate(url) { return normalized }
            return url
        }
    }

    private static func siteApprovalKey(_ site: TargetRules.Site?) -> String {
        guard let site else { return "" }
        return "\(site.host):\(site.port.map(String.init) ?? "")"
    }

    private static func targetApprovalSteps(
        _ steps: [ActionStep], extraLine: String?
    ) -> (lines: [String], kinds: Set<ApprovalKind>) {
        let sensitive = steps.compactMap { step in ApprovalText.kind(of: step).map { (step, $0) } }
        var lines = sensitive.map { ApprovalText.describe($0.0) }
        let other = steps.filter { ApprovalText.kind(of: $0) == nil }
        if !other.isEmpty {
            lines.append(AuditRedactor.describeSteps(other, recordText: false))
        }
        if let extraLine { lines.insert(extraLine, at: 0) }
        let cleaned = lines.compactMap { ApprovalText.clean($0, limit: 160) }
        return (ApprovalText.capped(cleaned, moreLabel: "steps"), Set(sensitive.map(\.1)).union([.targetRule]))
    }

    private func approvalAgent(for request: RPCRequest, taskId: String?) -> String? {
        TaskTabRegistry.cleanAgent(TaskActivityContext.agentName ?? request.agent ?? taskTabs.agent(of: taskId))
    }

    private func targetApprovalRefusal(_ error: RPCErrorPayload, request: RPCRequest, startNs: UInt64) -> RPCResponse {
        let latencyMs = elapsedMs(since: startNs)
        appendAudit(method: request.method.rawValue, targetApp: nil, summary: error.message, latencyMs: latencyMs, success: false)
        emitLiveActivity(LiveActivityItem(
            kind: .policyOrSafety, title: "Action blocked", subtitle: error.message,
            latencyMs: latencyMs, success: false, isInProgress: false
        ))
        return .failure(id: request.id, code: error.code, message: error.message, latencyMs: latencyMs, hint: error.hint)
    }

    /// The task the request names itself, if that task is running. Never the "only running task" guess: a grant
    /// must not leak to an agent that never said which task it belongs to.
    private func runningNamedTaskId(of request: RPCRequest) -> String? {
        guard let named = Self.namedTaskIdForApproval(request) else { return nil }
        guard taskTabs.resolve(taskId: named, tabId: nil) == named else {
            approvals.endTask(named)
            return nil
        }
        return named
    }

    /// The task id a held request carries: its own `taskId` (envelope or params), never a guess.
    static func namedTaskIdForApproval(_ request: RPCRequest) -> String? {
        request.namedTaskId
    }

    private func browserTargetLabel(profile: String, tabId: Int?) -> String {
        guard let tabId else {
            return "Chrome (\(profile)) · the tab UseMac used last"
        }
        var label = "Chrome (\(profile)) · tab \(tabId)"
        if let frame = chromeBridge.latestFrame(profileQuery: profile, tabId: tabId), frame.tabId == tabId {
            if let title = ApprovalText.clean(frame.title, limit: 48) {
                label += " · \(title)"
            }
            if let host = frame.url.flatMap({ URL(string: $0)?.host }), let cleanHost = ApprovalText.clean(host, limit: 48) {
                label += " (\(cleanHost))"
            }
        }
        return label
    }

    /// Waits (up to 5 s) until the user has left the mouse and keyboard alone long enough for a foreground burst.
    private func waitForUserToSettle() async {
        let needed = ActionExecutor.userIdleRequiredSeconds + 0.1
        for _ in 0..<50 {
            if WindowResolver.secondsSinceUserInput() >= needed { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func auditPhrase(for outcome: ApprovalBroker.Outcome) -> String {
        switch outcome {
        case .allowedOnce:
            return "Approval: allowed once"
        case .allowedForTask(let taskId):
            return "Approval: allowed for the rest of task \(taskId)"
        case .allowedByTaskGrant(let taskId):
            return "Approval: allowed by the grant for task \(taskId)"
        case .denied:
            return "Approval: denied"
        case .timedOut(let seconds, let whileQueued):
            return "Approval: timed out after \(seconds) s\(whileQueued ? " (queued behind another prompt)" : "")"
        case .cancelled(let reason):
            return "Approval: cancelled because \(reason)"
        }
    }
}

/// How Ask mode describes sensitive steps to the user. Everything an agent sent is cleaned (one line, no control
/// characters, length capped) so a request can't dress up its own prompt.
enum ApprovalText {
    /// Same set as Block sensitive (`confirmSensitive`).
    static func kind(of step: ActionStep) -> ApprovalKind? {
        if step.action == .uploadFile || step.action == .saveFile { return .upload }
        if step.action == .axAction, step.actionName?.lowercased() == "axopen" { return .upload }
        guard step.action == .pressKey else { return nil }
        // Every spelling of ⌘ and ⌃ (meta, command, control, …), the same list the policy checks use.
        return ModifierAliases.isSensitive(step.modifiers) ? .shortcut : nil
    }

    static func describe(_ step: ActionStep) -> String {
        switch step.action {
        case .pressKey:
            return "Press \(shortcut(key: step.key, modifiers: step.modifiers))"
        case .uploadFile:
            // The paths UseMac would upload: canonical when they pass the upload checks (the step fails otherwise).
            let canonical = (try? ActionExecutor.validateAndNormalizeUploadFiles(step.files).get()) ?? step.files ?? []
            let files = canonical.compactMap { displayPath($0) }
            guard let first = files.first else { return "Upload a file" }
            if files.count == 1 { return "Upload \(first)" }
            let rest = files.dropFirst().prefix(2).joined(separator: ", ")
            let more = files.count > 3 ? " and \(files.count - 3) more" : ""
            return "Upload \(files.count) files: \(first), \(rest)\(more)"
        case .saveFile:
            let dest = step.files?.first.flatMap { displayPath($0) }
            let overwriteSuffix = step.overwrite == true ? " (replace existing file)" : ""
            return dest.map { "Save file to \($0)\(overwriteSuffix)" } ?? "Save a file\(overwriteSuffix)"
        case .axAction:
            let name = clean(step.match?.text ?? step.match?.title ?? step.match?.value, limit: 60)
            return name.map { "Open \"\($0)\" in the file picker" } ?? "Open the selected file in the file picker"
        default:
            return clean(step.action.rawValue, limit: 30) ?? "A sensitive step"
        }
    }

    static func describeScript(_ expression: String?) -> String {
        let raw = expression ?? ""
        let singleLine = !raw.contains(where: \.isNewline)
        if raw.count <= 100, singleLine, let shown = clean(raw, limit: 100), shown == raw.trimmingCharacters(in: .whitespaces) {
            return "Run a page script: \(shown)"
        }
        let size = NumberFormatter.localizedString(from: NSNumber(value: raw.count), number: .decimal)
        return "Run a page script (\(size) characters)"
    }

    /// "⌃⌥⇧⌘S" in Apple's modifier order.
    static func shortcut(key: String?, modifiers: [String]?) -> String {
        ModifierAliases.symbols(modifiers) + keyName(key)
    }

    static func keyName(_ key: String?) -> String {
        guard let raw = clean(key, limit: 20) else { return "?" }
        let named: [String: String] = [
            "return": "Return", "enter": "Return", "tab": "Tab", "space": "Space", "escape": "Esc", "esc": "Esc",
            "delete": "Delete", "backspace": "Delete", "forwarddelete": "Forward Delete",
            "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "Home", "end": "End",
            "pageup": "Page Up", "pagedown": "Page Down"
        ]
        if let name = named[raw.lowercased()] { return name }
        return raw.count == 1 ? raw.uppercased() : raw.capitalized
    }

    /// A path for the prompt: ~ for the home folder, the middle cut when it is long, so the file name always shows.
    static func displayPath(_ path: String) -> String? {
        guard var shown = clean(path, limit: 4096) else { return nil }
        let home = NSHomeDirectory()
        if shown == home {
            shown = "~"
        } else if shown.hasPrefix(home + "/") {
            shown = "~" + shown.dropFirst(home.count)
        }
        let limit = 72
        guard shown.count > limit else { return shown }
        let tail = String(shown.suffix(44))
        let head = String(shown.prefix(limit - 44 - 1))
        return head + "…" + tail
    }

    /// One line, control characters removed, at most `limit` characters. Nil for nothing left.
    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || scalar.properties.generalCategory == .format {
                return " "
            }
            return Character(scalar)
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(1, limit - 1))) + "…"
    }

    /// At most four step lines; the rest are counted.
    static func capped(_ lines: [String], moreLabel: String = "sensitive steps") -> [String] {
        guard lines.count > 4 else { return lines }
        return Array(lines.prefix(3)) + ["and \(lines.count - 3) more \(moreLabel)"]
    }
}
