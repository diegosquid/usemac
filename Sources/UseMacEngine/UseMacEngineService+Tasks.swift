import Foundation
import UseMacProtocol

/// Ties every request to its task (see TaskTabRegistry) before it runs: a browser request without `tabId` goes to
/// its task's last tab instead of the last tab any agent touched, an acting request waits (`TARGET_BUSY`) while
/// another running task holds its window or tab, what the request did counts toward the task's `task_complete`
/// summary, and its preview cards show the task's agent. Requests of no task run exactly as before.
extension UseMacEngineService {
    public func handle(_ request: RPCRequest) async -> RPCResponse {
        let scope = taskTabs.scope(request)
        let agent = request.method == .taskStart ? request.taskStart?.agent : taskTabs.agent(of: scope.taskId)
        return await TaskActivityContext.$agentName.withValue(agent) {
            await handleScoped(request, scope: scope)
        }
    }

    private func handleScoped(_ request: RPCRequest, scope initialScope: TaskTabRegistry.Scope) async -> RPCResponse {
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

    /// Leases the window or tab an acting request works in for its task, or says which running task holds it. Reads
    /// never wait, requests of no task are never refused, and a Kill Switch or pause answers POLICY_BLOCKED first.
    private func leaseConflict(_ scope: TaskTabRegistry.Scope) -> TaskTabRegistry.Busy? {
        let request = scope.request
        guard request.actsOnTarget, taskTabs.hasRunningTasks,
              scope.taskId != nil || request.namedTaskId != nil,
              !isKillSwitchTripped(), getGovernancePolicy() != .paused else { return nil }
        return taskTabs.claim(scope, windows: leaseWindows(for: request), tabs: request.namedTabId.map { [$0] } ?? [])
    }

    /// The windows a native `act` works in: the target window of each app it names (the `window` it pins, else the
    /// app's focused window), or the whole app when UseMac can't tell the window.
    private func leaseWindows(for request: RPCRequest) -> [TaskTabRegistry.WindowLease] {
        guard request.method == .act, let batch = request.act else { return [] }
        var queries: [String?] = batch.steps.contains { $0.app == nil } ? [batch.app] : []
        for step in batch.steps {
            if let app = step.app, !queries.contains(app) { queries.append(app) }
        }
        var leases: [TaskTabRegistry.WindowLease] = []
        for query in queries {
            guard case .app(let app) = workspaceMonitor.resolveTarget(query: query), app.pid > 0 else { continue }
            var windowId = app.windowId
            var title = app.windowTitle
            if let wanted = batch.window?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty,
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

/// The agent of the request being handled. Every live activity item the request emits carries it, so its preview card
/// shows which agent is working there.
enum TaskActivityContext {
    @TaskLocal static var agentName: String?

    static func labeling(_ forward: @escaping @Sendable (LiveActivityItem) -> Void) -> @Sendable (LiveActivityItem) -> Void {
        { item in
            guard item.agentName == nil, let agent = agentName else { return forward(item) }
            var labeled = item
            labeled.agentName = agent
            forward(labeled)
        }
    }
}
