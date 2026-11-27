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
        /// Known profiles of open tabs, kept even after a tab falls out of the recent history.
        var tabProfiles: [Int: String] = [:]
        var appPids: Set<Int32> = []
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
        /// Apps the finished task used. Like `ownTabIds`, nil means no running task and an empty set matches none.
        public var ownAppPids: Set<Int32>?

        public init(
            taskId: String?,
            protectedTabIds: Set<Int>,
            ownTabIds: Set<Int>?,
            summary: TaskSummary?,
            ownAppPids: Set<Int32>? = nil
        ) {
            self.taskId = taskId
            self.protectedTabIds = protectedTabIds
            self.ownTabIds = ownTabIds
            self.summary = summary
            self.ownAppPids = ownAppPids
        }
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
    private var pendingBrowserOpens = 0
    private var leaseWaiters: [LeaseWaiter] = []
    private let lock = NSLock()

    struct LeaseWait {
        let id: UUID
        let signals: AsyncStream<Void>
        let signal: AsyncStream<Void>.Continuation
    }

    private struct LeaseWaiter {
        let id: UUID
        let taskId: String
        let signal: AsyncStream<Void>.Continuation
        var windows: [WindowLease]
        var tabs: [Int]
    }

    public init() {}

    /// Opens a task and returns its id (the caller's, or a new one).
    @discardableResult
    public func start(taskId: String? = nil, agent: String? = nil, now: Date = Date()) -> String {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
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

    /// Distinct names of running agents active within the given interval, most recently active first.
    public func activeAgentNames(activeWithin seconds: TimeInterval, now: Date = Date()) -> [String] {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        let recent = tasks.values.sorted { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt {
                return (lhs.agent ?? "") < (rhs.agent ?? "")
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        var seen: Set<String> = []
        return recent.compactMap { task in
            guard now.timeIntervalSince(task.lastActivityAt) < seconds,
                  let agent = task.agent, seen.insert(agent).inserted else { return nil }
            return agent
        }
    }

    /// Leases the windows and tabs an acting request works in for its task, or names the running task that holds one
    /// of them. A request of no task (no `taskId`, and UseMac can't tell its task) is never refused, so callers that
    /// don't use tasks work as before. One with a `taskId` that names no running task is refused but leases nothing.
    public func claim(_ scope: Scope, windows: [WindowLease], tabs: [Int], now: Date = Date()) -> Busy? {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        return claimLocked(scope, windows: windows, tabs: tabs, now: now)
    }

    /// Claims immediately if possible; otherwise queues atomically with the first conflict check. Only
    /// overlapping waiters compete for FIFO priority, so an unrelated busy window does not stall this one.
    func claimWithWait(
        _ scope: Scope, windows: [WindowLease], tabs: [Int], wait: LeaseWait? = nil
    ) -> (busy: Busy?, wait: LeaseWait?) {
        lock.lock()
        let now = Date()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }

        let index = wait.flatMap { ticket in leaseWaiters.firstIndex { $0.id == ticket.id } } ?? leaseWaiters.endIndex
        if index != leaseWaiters.endIndex,
           leaseWaiters[index].windows != windows || leaseWaiters[index].tabs != tabs {
            leaseWaiters[index].windows = windows
            leaseWaiters[index].tabs = tabs
            signalLeaseWaiters()
        }
        let busy = claimLocked(scope, windows: windows, tabs: tabs, now: now,
                               earlierWaiters: leaseWaiters.prefix(index))
        guard let busy, wait == nil, let taskId = scope.taskId ?? Self.clean(scope.request.namedTaskId) else {
            return (busy, wait)
        }
        let id = UUID()
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        leaseWaiters.append(LeaseWaiter(id: id, taskId: taskId, signal: signal, windows: windows, tabs: tabs))
        return (busy, LeaseWait(id: id, signals: signals, signal: signal))
    }

    func finishLeaseWait(_ wait: LeaseWait) {
        lock.lock(); defer { lock.unlock() }
        guard let index = leaseWaiters.firstIndex(where: { $0.id == wait.id }) else { return }
        leaseWaiters.remove(at: index).signal.finish()
        signalLeaseWaiters()
    }

    private func signalLeaseWaiters() {
        for waiter in leaseWaiters { waiter.signal.yield(()) }
    }

    private func claimLocked(
        _ scope: Scope, windows: [WindowLease], tabs: [Int], now: Date,
        earlierWaiters: ArraySlice<LeaseWaiter> = []
    ) -> Busy? {
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
        if !earlierWaiters.isEmpty,
           let busy = earlierWaiterConflict(earlierWaiters, requester: requester, windows: windows, tabs: tabs, now: now) {
            return busy
        }
        guard let requester else { return nil }
        for window in windows {
            if tasks[requester]?.windowLeases.contains(where: { $0.pid == window.pid && $0.windowId == window.windowId }) == false {
                tasks[requester]?.windowLeases.append(window)
            }
            if window.pid > 0 {
                tasks[requester]?.appPids.insert(window.pid)
            }
        }
        for tab in tabs where tasks[requester]?.tabIds.contains(tab) == false {
            tasks[requester]?.leasedTabIds.insert(tab)
        }
        tasks[requester]?.lastActivityAt = now
        return nil
    }

    private func earlierWaiterConflict(
        _ waiters: ArraySlice<LeaseWaiter>, requester: String?, windows: [WindowLease], tabs: [Int], now: Date
    ) -> Busy? {
        let held = requester.flatMap { tasks[$0] }
        // Let a holder reuse its leases, even when another task is queued behind it.
        let newWindows = windows.filter { wanted in
            held?.windowLeases.contains { $0.pid == wanted.pid && ($0.windowId == nil || $0.windowId == wanted.windowId) } != true
        }
        let newTabs = tabs.filter { held?.tabIds.contains($0) != true && held?.leasedTabIds.contains($0) != true }
        for waiter in waiters where waiter.taskId != requester {
            let target = newWindows.first { wanted in waiter.windows.contains { $0.overlaps(wanted) } }?.label
                ?? newTabs.first(where: waiter.tabs.contains).map { "Chrome tab \($0)" }
            if let target {
                let idle = tasks[waiter.taskId].map { max(0, Int(now.timeIntervalSince($0.lastActivityAt))) } ?? 0
                return Busy(taskId: waiter.taskId, agent: tasks[waiter.taskId]?.agent, target: target, idleSeconds: idle)
            }
        }
        return nil
    }

    /// True when a running task holds a lease or owns a tab, so an acting request may have to wait.
    public var hasRunningTasks: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tasks.isEmpty
    }

    public func beginBrowserOpen() {
        lock.lock(); defer { lock.unlock() }
        pendingBrowserOpens += 1
    }

    public func endBrowserOpen() {
        lock.lock(); defer { lock.unlock() }
        if pendingBrowserOpens > 0 {
            pendingBrowserOpens -= 1
        }
    }

    /// An open may have reached Chrome before the new tab's ownership has been recorded here.
    public var hasPendingBrowserOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingBrowserOpens > 0
    }

    /// The running task a request belongs to, if UseMac can tell.
    public func resolve(taskId: String?, tabId: Int?, now: Date = Date()) -> String? {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        return resolveLocked(taskId: taskId, tabId: tabId)
    }

    /// Ties a request to its task and, when it names no tab and would otherwise go to the extension's last tab (the
    /// last tab any agent touched), aims it at the task's own last tab. Requests of no task are left as they are.
    public func scope(_ request: RPCRequest, now: Date = Date()) -> Scope {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
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

    /// Records a native app the task used, even when the request did not claim a window.
    public func recordApp(_ pid: Int32, taskId: String?, now: Date = Date()) {
        guard pid > 0 else { return }
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        guard let owner = resolveLocked(taskId: taskId, tabId: nil) else { return }
        tasks[owner]?.appPids.insert(pid)
        tasks[owner]?.lastActivityAt = now
    }

    /// Records a tab UseMac opened for the task the request belongs to (if it can tell).
    public func recordOpenedTab(_ tabId: Int, taskId: String?, profile: String? = nil, now: Date = Date()) {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        guard let owner = resolveLocked(taskId: taskId, tabId: nil) else { return }
        tasks[owner]?.tabIds.insert(tabId)
        if tasks[owner]?.openedTabIds.contains(tabId) == false {
            tasks[owner]?.openedTabIds.append(tabId)
        }
        let cleanProfile = Self.clean(profile)
        if let cleanProfile {
            tasks[owner]?.tabProfiles[tabId] = cleanProfile
        }
        tasks[owner]?.lastActivityAt = now
        touchLocked(owner, tab: TabRef(tabId: tabId, profile: cleanProfile))
    }

    /// Finishes the task a `task_complete` belongs to and says which tabs the cleanup must leave alone.
    public func complete(
        taskId: String?,
        tabId: Int?,
        keepTabIds: Set<Int> = [],
        keepTabs: Bool = false,
        now: Date = Date()
    ) -> Completion {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        if let finished = resolveLocked(taskId: taskId, tabId: tabId), let task = tasks.removeValue(forKey: finished) {
            signalLeaseWaiters()
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
            return Completion(
                taskId: finished, protectedTabIds: allTabsLocked(), ownTabIds: task.tabIds,
                summary: summary, ownAppPids: task.appPids
            )
        }
        if tasks.isEmpty {
            return Completion(taskId: nil, protectedTabIds: [], ownTabIds: nil, summary: nil)
        }
        // A task is running but we cannot match the completion: close nothing it owns or mark its cards done.
        return Completion(taskId: nil, protectedTabIds: allTabsLocked(), ownTabIds: [], summary: nil, ownAppPids: [])
    }

    /// Forgets a tab that closed: it no longer belongs to its task, and requests without `tabId` stop going there.
    public func forgetTab(_ tabId: Int) {
        lock.lock(); defer { lock.unlock() }
        for key in tasks.keys {
            if tasks[key]?.tabIds.remove(tabId) != nil {
                tasks[key]?.closedTabIds.append(tabId)
            }
            tasks[key]?.tabProfiles.removeValue(forKey: tabId)
            tasks[key]?.leasedTabIds.remove(tabId)
            tasks[key]?.recentTabs.removeAll { $0.tabId == tabId }
        }
        signalLeaseWaiters()
    }

    /// Tabs running tasks own: the cleanup after another task's `task_complete` must leave them open.
    public func protectedTabIds(now: Date = Date()) -> Set<Int> {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        return allTabsLocked()
    }

    /// Tabs running tasks opened, for restoring extension ownership after a reconnect.
    public func ownedTabIds(forProfile profile: String? = nil, now: Date = Date()) -> [Int] {
        lock.lock()
        let expiredTaskIds = expire(now: now)
        defer { unlockAndClearExpiredPins(expiredTaskIds) }
        let wantedProfile = Self.clean(profile)
        var owned: Set<Int> = []
        for task in tasks.values {
            owned.formUnion(task.tabIds.filter { tabId in
                guard let wantedProfile else { return true }
                return task.tabProfiles[tabId]?.caseInsensitiveCompare(wantedProfile) == .orderedSame
            })
        }
        return owned.sorted()
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

    private func expire(now: Date) -> [String] {
        let expired = tasks.compactMap { id, task in
            now.timeIntervalSince(task.lastActivityAt) >= Self.idleExpiry ? id : nil
        }
        for id in expired {
            tasks.removeValue(forKey: id)
        }
        if !expired.isEmpty { signalLeaseWaiters() }
        return expired
    }

    private func unlockAndClearExpiredPins(_ taskIds: [String]) {
        lock.unlock()
        // WindowResolver has its own lock; never hold the registry lock while acquiring it.
        for id in taskIds {
            WindowResolver.clearPins(forTaskId: id)
        }
    }

    private static func clean(_ id: String?) -> String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func newId() -> String {
        "task-" + UUID().uuidString.prefix(8).lowercased()
    }
}
