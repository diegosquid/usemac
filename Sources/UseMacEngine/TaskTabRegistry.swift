import Foundation
import UseMacProtocol

/// Which running task owns which Chrome tabs UseMac opened, so one agent finishing never closes another agent's tabs.
/// It also remembers each task's last tab (a request without `tabId` goes there, not to the last tab any agent
/// touched), counts what the task did for the `task_complete` summary, and holds the task's leases: the windows and
/// tabs it acts in, which another running task's actions can't touch until it finishes (`TARGET_BUSY`).
///
/// A request is tied to a task by, in order: its explicit `taskId`, the task that owns the `tabId` it names, or the
/// only running task. An explicit `taskId` that names no running task ties the request to no task. When none of
/// those settles it (several tasks running, nothing named), UseMac keeps every tab a running task owns: leaving a tab
/// open is recoverable, closing another agent's working tab is not.
public final class TaskTabRegistry: @unchecked Sendable {
    /// A task nobody has touched for this long (no `task_complete`, no request tied to it) stops protecting its tabs.
    public static let idleExpiry: TimeInterval = 30 * 60

    struct RunningTask {
        var startedAt: Date
        var lastActivityAt: Date
        /// Tabs the task opened that are still open.
        var tabIds: Set<Int>
        /// Tabs the task opened, oldest first, and those of them that closed during the task.
        var openedTabIds: [Int] = []
        var closedTabIds: [Int] = []
        /// Tabs the task opened or named, most recent last: the last one is where a request without `tabId` goes.
        var recentTabs: [TabRef] = []
        var requests = 0
        var actions = 0
        var failedActions = 0
        var blocked = 0
        /// Shown on the task's preview cards (`task_start` `agent`, or the MCP client's name).
        var agent: String?
        /// Windows the task acted in, and tabs it acted in that it did not open (it owns those already).
        var windowLeases: [WindowLease] = []
        var leasedTabIds: Set<Int> = []
    }

    /// A window a task acts in. Without `windowId` (UseMac could not tell the window) it covers every window of the app.
    public struct WindowLease: Equatable, Sendable {
        public var pid: Int32
        public var windowId: UInt32?
        /// For messages, e.g. `TextEdit window "Untitled"`.
        public var label: String

        public init(pid: Int32, windowId: UInt32?, label: String) {
            self.pid = pid
            self.windowId = windowId
            self.label = label
        }

        func overlaps(_ other: WindowLease) -> Bool {
            pid == other.pid && (windowId == nil || other.windowId == nil || windowId == other.windowId)
        }
    }

    /// Another running task holds a window or tab the request wants to act in.
    public struct Busy: Equatable, Sendable {
        public var taskId: String
        public var agent: String?
        /// What is busy, e.g. `TextEdit window "Untitled"` or `Chrome tab 123`.
        public var target: String
        /// Seconds since the holding task last did anything.
        public var idleSeconds: Int
    }

    struct TabRef: Equatable {
        var tabId: Int
        var profile: String?
    }

    /// What `task_complete` should do.
    public struct Completion: Equatable, Sendable {
        /// The task that finished, when UseMac could tell.
        public var taskId: String?
        /// Tabs the cleanup must keep open on top of the caller's `keepTabIds`: those other running tasks own.
        public var protectedTabIds: Set<Int>
        /// The finished task's own tabs, to mark only their preview cards as done. Nil when no task is running at all,
        /// so every card belongs to whoever finished (the behavior before tasks existed).
        public var ownTabIds: Set<Int>?
        /// What the finished task did. Nil when UseMac could not tell which task finished.
        public var summary: TaskSummary?
    }

    /// A request tied to its task, with its tab filled in from that task's last tab when it named none.
    public struct Scope: Sendable {
        /// The request to run (the caller's, or the same one aimed at the task's last tab).
        public var request: RPCRequest
        /// The task the request belongs to, if UseMac can tell.
        public var taskId: String?
        /// The tab UseMac filled in, when the request named none.
        public var filledTabId: Int?
    }

    private var tasks: [String: RunningTask] = [:]
    private let lock = NSLock()

    public init() {}

    /// Opens a task and returns its id (the caller's, or a new one).
    @discardableResult
    public func start(taskId: String? = nil, agent: String? = nil, now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        let id = Self.clean(taskId) ?? Self.newId()
        if tasks[id] == nil {
            tasks[id] = RunningTask(startedAt: now, lastActivityAt: now, tabIds: [])
        } else {
            tasks[id]?.lastActivityAt = now
        }
        if let agent = Self.cleanAgent(agent) {
            tasks[id]?.agent = agent
        }
        return id
    }

    /// The name shown on the task's preview cards, if it has one.
    public func agent(of taskId: String?) -> String? {
        guard let taskId else { return nil }
        lock.lock(); defer { lock.unlock() }
        return tasks[taskId]?.agent
    }

    /// Leases the windows and tabs an acting request works in for its task, or names the running task that holds one
    /// of them. A request of no task (no `taskId`, and UseMac can't tell its task) is never refused, so callers that
    /// don't use tasks work as before. One with a `taskId` that names no running task is refused but leases nothing.
    public func claim(_ scope: Scope, windows: [WindowLease], tabs: [Int], now: Date = Date()) -> Busy? {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        let requester = scope.taskId.flatMap { tasks[$0] != nil ? $0 : nil }
        guard requester != nil || Self.clean(scope.request.namedTaskId) != nil else { return nil }
        for (id, task) in tasks where id != requester {
            let idle = max(0, Int(now.timeIntervalSince(task.lastActivityAt)))
            if let window = windows.first(where: { wanted in task.windowLeases.contains { $0.overlaps(wanted) } }) {
                return Busy(taskId: id, agent: task.agent, target: window.label, idleSeconds: idle)
            }
            if let tab = tabs.first(where: { task.tabIds.contains($0) || task.leasedTabIds.contains($0) }) {
                return Busy(taskId: id, agent: task.agent, target: "Chrome tab \(tab)", idleSeconds: idle)
            }
        }
        guard let requester else { return nil }
        for window in windows where !(tasks[requester]?.windowLeases.contains { $0.pid == window.pid && $0.windowId == window.windowId } ?? true) {
            tasks[requester]?.windowLeases.append(window)
        }
        for tab in tabs where tasks[requester]?.tabIds.contains(tab) == false {
            tasks[requester]?.leasedTabIds.insert(tab)
        }
        tasks[requester]?.lastActivityAt = now
        return nil
    }

    /// True when a running task holds a lease or owns a tab, so an acting request may have to wait.
    public var hasRunningTasks: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tasks.isEmpty
    }

    /// The running task a request belongs to, if UseMac can tell.
    public func resolve(taskId: String?, tabId: Int?, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        return resolveLocked(taskId: taskId, tabId: tabId)
    }

    /// Ties a request to its task and, when it names no tab and would otherwise go to the extension's last tab (the
    /// last tab any agent touched), aims it at the task's own last tab. Requests of no task are left as they are.
    public func scope(_ request: RPCRequest, now: Date = Date()) -> Scope {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard request.method != .taskStart,
              let owner = resolveLocked(taskId: request.namedTaskId, tabId: request.namedTabId) else {
            return Scope(request: request, taskId: nil, filledTabId: nil)
        }
        tasks[owner]?.lastActivityAt = now
        guard request.fallsBackToLastTab else {
            if request.method == .browserExtract, request.browserExtract?.isDownloads == true,
               Self.clean(request.namedProfile) == nil,
               let lastProfile = tasks[owner]?.recentTabs.last(where: { $0.profile != nil })?.profile {
                var copy = request
                copy.browserExtract?.profile = lastProfile
                return Scope(request: copy, taskId: owner, filledTabId: nil)
            }
            return Scope(request: request, taskId: owner, filledTabId: nil)
        }
        let wantedProfile = Self.clean(request.namedProfile)
        let last = tasks[owner]?.recentTabs.last(where: { ref in
            wantedProfile == nil || ref.profile == nil || ref.profile == wantedProfile
        })
        guard let last else {
            return Scope(request: request, taskId: owner, filledTabId: nil)
        }
        return Scope(request: request.aimed(atTab: last.tabId, profile: last.profile), taskId: owner, filledTabId: last.tabId)
    }

    /// Counts a finished request for its task's summary and remembers the tab it worked in.
    public func record(_ scope: Scope, response: RPCResponse, now: Date = Date()) {
        guard let owner = scope.taskId else { return }
        lock.lock(); defer { lock.unlock() }
        guard tasks[owner] != nil else { return }
        let method = scope.request.method
        guard method != .taskStart, method != .taskComplete else { return }
        tasks[owner]?.lastActivityAt = now
        tasks[owner]?.requests += 1
        if let steps = response.actionResult?.stepResults {
            tasks[owner]?.actions += steps.count
            tasks[owner]?.failedActions += steps.filter { !$0.success }.count
            tasks[owner]?.blocked += steps.filter { Self.isBlockedCode($0.errorCode) }.count
        }
        if !response.ok, Self.isBlockedCode(response.error?.code) {
            tasks[owner]?.blocked += 1
        }
        if response.ok, let tabId = scope.request.namedTabId, method != .taskStart {
            touchLocked(owner, tab: TabRef(tabId: tabId, profile: Self.clean(scope.request.namedProfile)))
        }
    }

    /// Records a tab UseMac opened for the task the request belongs to (if it can tell).
    public func recordOpenedTab(_ tabId: Int, taskId: String?, profile: String? = nil, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard let owner = resolveLocked(taskId: taskId, tabId: nil) else { return }
        tasks[owner]?.tabIds.insert(tabId)
        if tasks[owner]?.openedTabIds.contains(tabId) == false {
            tasks[owner]?.openedTabIds.append(tabId)
        }
        tasks[owner]?.lastActivityAt = now
        touchLocked(owner, tab: TabRef(tabId: tabId, profile: Self.clean(profile)))
    }

    /// Finishes the task a `task_complete` belongs to and says which tabs the cleanup must leave alone.
    public func complete(
        taskId: String?,
        tabId: Int?,
        keepTabIds: Set<Int> = [],
        keepTabs: Bool = false,
        now: Date = Date()
    ) -> Completion {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        if let finished = resolveLocked(taskId: taskId, tabId: tabId), let task = tasks.removeValue(forKey: finished) {
            let closing = keepTabs ? [] : task.openedTabIds.filter { task.tabIds.contains($0) && !keepTabIds.contains($0) }
            let summary = TaskSummary(
                taskId: finished,
                agent: task.agent,
                requests: task.requests,
                actions: task.actions,
                failedActions: task.failedActions,
                blocked: task.blocked,
                tabsOpened: task.openedTabIds,
                tabsClosed: task.closedTabIds,
                tabsClosing: closing,
                durationMs: max(0, Int((now.timeIntervalSince(task.startedAt) * 1000).rounded()))
            )
            return Completion(taskId: finished, protectedTabIds: allTabsLocked(), ownTabIds: task.tabIds, summary: summary)
        }
        if tasks.isEmpty {
            return Completion(taskId: nil, protectedTabIds: [], ownTabIds: nil, summary: nil)
        }
        // Several tasks are running and nothing says which one finished: close nothing they own, mark no card done.
        return Completion(taskId: nil, protectedTabIds: allTabsLocked(), ownTabIds: [], summary: nil)
    }

    /// Forgets a tab that closed: it no longer belongs to its task, and requests without `tabId` stop going there.
    public func forgetTab(_ tabId: Int) {
        lock.lock(); defer { lock.unlock() }
        for key in tasks.keys {
            if tasks[key]?.tabIds.remove(tabId) != nil {
                tasks[key]?.closedTabIds.append(tabId)
            }
            tasks[key]?.leasedTabIds.remove(tabId)
            tasks[key]?.recentTabs.removeAll { $0.tabId == tabId }
        }
    }

    /// Tabs running tasks own: the cleanup after another task's `task_complete` must leave them open.
    public func protectedTabIds(now: Date = Date()) -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        return allTabsLocked()
    }

    /// True when a running task opened or worked in this tab.
    public func knowsTab(_ tabId: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks.values.contains { $0.tabIds.contains(tabId) || $0.recentTabs.contains { $0.tabId == tabId } }
    }

    /// The tab a request of this task without `tabId` goes to.
    public func lastTab(of taskId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return tasks[taskId]?.recentTabs.last?.tabId
    }

    public var runningTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tasks.count
    }

    /// An agent name as the preview shows it: trimmed, at most 40 characters, nil when empty.
    public static func cleanAgent(_ name: String?) -> String? {
        clean(name).map { String($0.prefix(40)) }
    }

    /// A refusal for a safety reason, counted as blocked in the summary.
    static func isBlockedCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.hasSuffix("_BLOCKED") || code == "POLICY_LOCKED" || code == "TARGET_BUSY"
    }

    // MARK: - Private (call with the lock held)

    private func resolveLocked(taskId: String?, tabId: Int?) -> String? {
        if let id = Self.clean(taskId) {
            // An id that names no running task (finished, expired, or never started) belongs to no task: never
            // guess another task for it, or one agent's `done` could finish someone else's task.
            return tasks[id] != nil ? id : nil
        }
        if let tabId, let owner = tasks.first(where: { $0.value.tabIds.contains(tabId) })?.key {
            return owner
        }
        return tasks.count == 1 ? tasks.keys.first : nil
    }

    private func touchLocked(_ owner: String, tab: TabRef) {
        guard var recent = tasks[owner]?.recentTabs else { return }
        let profile = tab.profile ?? recent.first(where: { $0.tabId == tab.tabId })?.profile
        recent.removeAll { $0.tabId == tab.tabId }
        recent.append(TabRef(tabId: tab.tabId, profile: profile))
        if recent.count > 16 {
            recent.removeFirst(recent.count - 16)
        }
        tasks[owner]?.recentTabs = recent
    }

    /// Tabs running tasks opened or act in: another task's cleanup leaves them open.
    private func allTabsLocked() -> Set<Int> {
        tasks.values.reduce(into: Set<Int>()) { $0.formUnion($1.tabIds); $0.formUnion($1.leasedTabIds) }
    }

    private func expire(now: Date) {
        tasks = tasks.filter { now.timeIntervalSince($0.value.lastActivityAt) < Self.idleExpiry }
    }

    private static func clean(_ id: String?) -> String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func newId() -> String {
        "task-" + UUID().uuidString.prefix(8).lowercased()
    }
}
