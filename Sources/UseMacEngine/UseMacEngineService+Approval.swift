import AppKit
import CoreGraphics
import Foundation
import UseMacProtocol

/// Ask mode: a request with a sensitive step (an upload, a ⌘/⌃ shortcut, a page script) waits until the user allows
/// or denies it in the HUD. Nobody answering in time denies it.
extension UseMacEngineService {
    /// Holds `request` for the user's answer when Ask mode is on and it has a sensitive step. Returns the failure to
    /// send back (APPROVAL_DENIED, APPROVAL_TIMEOUT, or POLICY_BLOCKED when the mode changed meanwhile), or nil when
    /// the request may run.
    /// `browserAct` is the request's browser_act params after URL and upload checks (canonical file paths).
    func approvalRefusal(for request: RPCRequest, startNs: UInt64, browserAct: BrowserActParams? = nil) async -> RPCResponse? {
        guard killSwitch.getPolicy() == .ask else { return nil }
        var checked = request
        if let browserAct { checked.browserAct = browserAct }
        guard let held = approvalRequest(for: checked) else { return nil }
        let ask = held.request
        let stepsText = ask.steps.joined(separator: "; ")
        onLiveActivity?(held.activity(title: "Waiting for your OK", subtitle: stepsText, success: true, inProgress: true))

        let killSwitch = self.killSwitch
        let outcome = await approvals.requestApproval(ask) {
            if killSwitch.isTripped { return "the Kill Switch was used" }
            if killSwitch.getPolicy() != .ask { return "the execution mode changed" }
            return nil
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
        switch outcome {
        case .allowedOnce, .allowedForTask, .allowedByTaskGrant:
            if request.method == .act, request.act?.foreground == true {
                // The click on Allow is the user's own input: let them settle before the burst takes the screen.
                await waitForUserToSettle()
            }
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
        }
        onLiveActivity?(held.activity(title: activityTitle, subtitle: message, success: false, inProgress: false, latencyMs: latencyMs))
        return .failure(id: request.id, code: code, message: message, latencyMs: latencyMs)
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
            success: false
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
                    grantTarget: "app:" + (targets.first ?? mainName.lowercased())
                ),
                appName: mainApp?.name ?? mainName,
                appPid: mainApp?.pid,
                bundleId: mainApp?.bundleId,
                targetGuessed: guessed
            )

        case .browserAct:
            guard let params = request.browserAct else { return nil }
            let sensitive = params.steps.compactMap { step in ApprovalText.kind(of: step).map { (step, $0) } }
            guard !sensitive.isEmpty else { return nil }
            let profile = params.profile ?? chromeBridge.connectedProfiles().first?.profileName ?? "Browser"
            return HeldRequest(
                request: ApprovalBroker.Request(
                    method: request.method.rawValue,
                    target: browserTargetLabel(profile: profile, tabId: params.tabId),
                    steps: ApprovalText.capped(sensitive.map { ApprovalText.describe($0.0) }),
                    kinds: Set(sensitive.map(\.1)),
                    taskId: taskId,
                    grantTarget: "chrome:" + profile.lowercased()
                ),
                appName: "Chrome (\(profile))",
                browserTabId: params.tabId,
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
                    grantTarget: "chrome:" + profile.lowercased()
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
        if step.action == .uploadFile { return .upload }
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
    static func capped(_ lines: [String]) -> [String] {
        guard lines.count > 4 else { return lines }
        return Array(lines.prefix(3)) + ["and \(lines.count - 3) more sensitive steps"]
    }
}
