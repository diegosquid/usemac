import Foundation
import UseMacProtocol

/// Ties every request to its task (see TaskTabRegistry) before it runs: a browser request without `tabId` goes to
/// its task's last tab instead of the last tab any agent touched, and what the request did counts toward the task's
/// `task_complete` summary. Requests of no task run exactly as before.
extension UseMacEngineService {
    public func handle(_ request: RPCRequest) async -> RPCResponse {
        var scope = taskTabs.scope(request)
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
