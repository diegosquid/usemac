import Foundation
import UseMacProtocol

/// Ties every request to its task (see TaskTabRegistry) before it runs: a browser request without `tabId` goes to
/// its task's last tab instead of the last tab any agent touched, an acting request waits (`TARGET_BUSY`) while
/// another running task holds its window or tab, what the request did counts toward the task's `task_complete`
/// summary, and its preview cards show the task's agent. Requests of no task run exactly as before.
///
/// Supports zero-ceremony piggybacked lifecycle: any non-`task_start` request may carry `taskStart` to start a task
/// inline (stamping `taskId` onto the response), and any non-`task_complete` request may carry `taskComplete` to
/// finish the task right after the request executes (attaching `taskSummary` onto the response).
extension UseMacEngineService {
    public func activeAgentNames(activeWithin seconds: TimeInterval = 60) -> [String] {
        taskTabs.activeAgentNames(activeWithin: seconds)
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        // Wrap the entire lifecycle (including piggybacked taskStart/taskComplete) in AuditRequestContext
        // so task summaries that echo typed values or skill params are scrubbed when text recording is off.
        await AuditRequestContext.$request.withValue(request) {
            var workingRequest = request
            var startedTaskId: String?
            let taskStartAgent = TaskTabRegistry.cleanAgent(workingRequest.taskStart?.agent)
            let requestAgent = TaskTabRegistry.cleanAgent(workingRequest.agent)

            // Zero-ceremony piggybacked task_start on any non-taskStart request.
            if workingRequest.method != .taskStart, var inlineStart = workingRequest.taskStart {
                inlineStart.agent = inlineStart.agent ?? requestAgent
                let taskId = TaskActivityContext.$agentName.withValue(taskStartAgent ?? requestAgent) {
                    startTaskInline(inlineStart, explicitTaskId: workingRequest.taskId)
                }
                startedTaskId = taskId
                workingRequest.taskId = taskId
                if workingRequest.method == .browserOpen, workingRequest.browserOpen?.taskId == nil {
                    workingRequest.browserOpen?.taskId = taskId
                }
            }

            let scope = taskTabs.scope(workingRequest)
            let effectiveTaskId = scope.taskId ?? startedTaskId
            let agent = taskStartAgent ?? taskTabs.agent(of: effectiveTaskId) ?? requestAgent

            var response = await AuditRequestContext.$request.withValue(workingRequest) {
                await TaskActivityContext.$agentName.withValue(agent) {
                    await TaskActivityContext.$taskId.withValue(effectiveTaskId) {
                        await handleScoped(workingRequest, scope: scope)
                    }
                }
            }

            if let startedTaskId, response.taskId == nil {
                response.taskId = startedTaskId
            }

            // Zero-ceremony piggybacked task_complete on any non-taskComplete request.
            if workingRequest.method != .taskComplete, let inlineComplete = workingRequest.taskComplete {
                let completionTaskId = inlineComplete.taskId ?? effectiveTaskId ?? workingRequest.namedTaskId
                let completion = AuditRequestContext.$request.withValue(workingRequest) {
                    TaskActivityContext.$agentName.withValue(agent) {
                        TaskActivityContext.$taskId.withValue(completionTaskId) {
                            completeTaskInline(
                                inlineComplete,
                                taskId: completionTaskId,
                                fallbackTabId: response.browserTabId ?? workingRequest.namedTabId,
                                fallbackProfile: workingRequest.namedProfile,
                                success: response.ok
                            )
                        }
                    }
                }
                if response.taskId == nil {
                    response.taskId = completion.taskId ?? completionTaskId
                }
                response.taskSummary = completion.summary
            }

            // Audit entries don't carry error codes; a problem report lists them from here.
            problemReports.record(response, of: workingRequest, taskId: effectiveTaskId)
            return response
        }
    }

    private func handleScoped(_ request: RPCRequest, scope initialScope: TaskTabRegistry.Scope) async -> RPCResponse {
        if request.method == .skillRun {
            return await handleScopedSkillRun(request, initialScope: initialScope)
        }
        var scope = initialScope
        if let busy = leaseConflict(scope) {
            let refused = targetBusyResponse(request: scope.request, busy: busy)
            taskTabs.record(scope, response: refused)
            return refused
        }
        var response = await handleRequest(scope.request)
        // UseMac aimed the request at the task's last tab, but that tab closed without UseMac hearing about it (no live
        // session was attached to it). Forget it. A read runs again on the task's previous tab, or where it would have
        // gone without a task; an action never moves to another tab on its own.
        while let staleTabId = scope.filledTabId, Self.isClosedTabError(response) {
            taskTabs.forgetTab(staleTabId)
            guard request.isReadOnlyForTask else {
                response = .failure(
                    id: request.id,
                    code: "NO_USEMAC_TAB",
                    message: "Tab \(staleTabId), the last tab this task worked in, is closed. Pass a tabId (see browser_tabs), or open a tab with browser_open.",
                    latencyMs: response.serverLatencyMs
                )
                break
            }
            scope = taskTabs.scope(request)
            response = await handleRequest(scope.request)
        }
        taskTabs.record(scope, response: response)
        return response
    }

    /// Expands a `skill_run` into its underlying `.browserAct`/`.act` BEFORE task scoping and window/tab leasing,
    /// so saved skills obey task tab isolation and `TARGET_BUSY` locks identically to direct actions and are
    /// accounted for once in the task summary.
    private func handleScopedSkillRun(_ request: RPCRequest, initialScope: TaskTabRegistry.Scope) async -> RPCResponse {
        let startNs = DispatchTime.now().uptimeNanoseconds
        switch prepareSkillRun(request, startNs: startNs) {
        case .failure(let errorResponse):
            taskTabs.record(initialScope, response: errorResponse)
            return errorResponse
        case .success(let prepared):
            let expandedScope = taskTabs.scope(prepared.delegatedRequest)
            if let busy = leaseConflict(expandedScope) {
                let refused = targetBusyResponse(request: expandedScope.request, busy: busy)
                taskTabs.record(expandedScope, response: refused)
                return refused
            }
            var execResp = await handleRequest(expandedScope.request)
            if let staleTabId = expandedScope.filledTabId, Self.isClosedTabError(execResp) {
                taskTabs.forgetTab(staleTabId)
                execResp = .failure(
                    id: request.id,
                    code: "NO_USEMAC_TAB",
                    message: "Tab \(staleTabId), the last tab this task worked in, is closed. Pass a tabId (see browser_tabs), or open a tab with browser_open.",
                    latencyMs: execResp.serverLatencyMs
                )
            }
            let finalResponse = finalizeSkillRun(
                request: request,
                prepared: prepared,
                execResp: execResp,
                startNs: startNs
            )
            taskTabs.record(expandedScope, response: finalResponse)
            return finalResponse
        }
    }

    /// Leases the window or tab an acting request works in for its task, or says which running task holds it. Reads
    /// never wait, requests of no task are never refused, and a Kill Switch or pause answers POLICY_BLOCKED first.
    private func leaseConflict(_ scope: TaskTabRegistry.Scope) -> TaskTabRegistry.Busy? {
        let request = scope.request
        guard request.actsOnTarget, taskTabs.hasRunningTasks,
              scope.taskId != nil || request.namedTaskId != nil,
              !isKillSwitchTripped(), getGovernancePolicy() != .paused else { return nil }
        return taskTabs.claim(scope, windows: leaseWindows(for: request), tabs: request.namedTabId.map { [$0] } ?? [])
    }

    /// The windows a native `act` or mutating `app_menu` works in: the target window of each app it names (the `window`
    /// it pins, else the app's focused window), or the whole app when UseMac can't tell the window.
    private func leaseWindows(for request: RPCRequest) -> [TaskTabRegistry.WindowLease] {
        var queries: [String?] = []
        var pinnedWindow: String?
        if request.method == .act, let batch = request.act {
            if batch.steps.contains(where: { $0.app == nil }) {
                queries.append(batch.app)
            }
            for step in batch.steps {
                if let app = step.app, !queries.contains(app) { queries.append(app) }
            }
            pinnedWindow = batch.window
        } else if request.method == .appMenu, let menu = request.appMenu,
                  menu.menuPath?.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
            queries.append(menu.app)
        } else {
            return []
        }

        var leases: [TaskTabRegistry.WindowLease] = []
        for query in queries {
            guard case .app(let app) = workspaceMonitor.resolveTarget(query: query), app.pid > 0 else { continue }
            var windowId = app.windowId
            var title = app.windowTitle
            if let wanted = pinnedWindow?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty,
               let element = WindowResolver.window(pid: app.pid, titleContains: wanted) {
                windowId = WindowResolver.windowID(of: element).map { UInt32($0) }
                title = wanted
            }
            let label = (title?.isEmpty == false) ? "\(app.name) window \"\(title!)\"" : "\(app.name) window"
            leases.append(TaskTabRegistry.WindowLease(pid: app.pid, windowId: windowId, label: label))
        }
        return leases
    }

    /// The extension stopped a tab's stream. A closed tab no longer belongs to its task. "idle" and "evicted" tabs are
    /// still open; for any other reason (or none, from extensions before 0.6) UseMac asks Chrome whether the tab is gone.
    func tabStreamEnded(profile: String, tabId: Int, reason: String?) {
        guard taskTabs.knowsTab(tabId) else { return }
        switch reason {
        case "closed":
            taskTabs.forgetTab(tabId)
        case "idle", "evicted":
            return
        default:
            Task { [chromeBridge, taskTabs] in
                let listing = await chromeBridge.tabs(BrowserTabsParams(profile: profile))
                guard listing.ok, let tabs = listing.tabs, !tabs.contains(where: { $0.tabId == tabId }) else { return }
                taskTabs.forgetTab(tabId)
            }
        }
    }

    /// Chrome's answer for a tab id that no longer exists.
    static func isClosedTabError(_ response: RPCResponse) -> Bool {
        guard !response.ok, let message = response.error?.message else { return false }
        return message.localizedCaseInsensitiveContains("No tab with id")
    }
}

/// The agent and task of the request being handled. Every live activity item the request emits carries them, so its
/// preview card shows which agent is working there.
enum TaskActivityContext {
    @TaskLocal static var agentName: String?
    @TaskLocal static var taskId: String?

    static func labeling(_ forward: @escaping @Sendable (LiveActivityItem) -> Void) -> @Sendable (LiveActivityItem) -> Void {
        { item in
            let agent = item.agentName == nil ? agentName : nil
            let task = item.taskId == nil ? taskId : nil
            guard agent != nil || task != nil else { return forward(item) }
            var labeled = item
            if let agent { labeled.agentName = agent }
            if let task { labeled.taskId = task }
            forward(labeled)
        }
    }
}
