import Foundation

/// Which running task owns which Chrome tabs UseMac opened, so one agent finishing never closes another agent's tabs.
///
/// A request is tied to a task by, in order: its explicit `taskId`, the task that owns the `tabId` it names, or the
/// only running task. When none of those settles it (several tasks running, nothing named), UseMac keeps every tab a
/// running task owns: leaving a tab open is recoverable, closing another agent's working tab is not.
public final class TaskTabRegistry: @unchecked Sendable {
    /// A task nobody has touched for this long (no `task_complete`, no request tied to it) stops protecting its tabs.
    public static let idleExpiry: TimeInterval = 30 * 60

    struct RunningTask {
        var lastActivityAt: Date
        var tabIds: Set<Int>
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
    }

    private var tasks: [String: RunningTask] = [:]
    private let lock = NSLock()

    public init() {}

    /// Opens a task and returns its id (the caller's, or a new one).
    @discardableResult
    public func start(taskId: String? = nil, now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        let id = Self.clean(taskId) ?? Self.newId()
        if tasks[id] == nil {
            tasks[id] = RunningTask(lastActivityAt: now, tabIds: [])
        } else {
            tasks[id]?.lastActivityAt = now
        }
        return id
    }

    /// The running task a request belongs to, if UseMac can tell.
    public func resolve(taskId: String?, tabId: Int?, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        return resolveLocked(taskId: taskId, tabId: tabId)
    }

    /// Records a tab UseMac opened for the task the request belongs to (if it can tell).
    public func recordOpenedTab(_ tabId: Int, taskId: String?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard let owner = resolveLocked(taskId: taskId, tabId: nil) else { return }
        tasks[owner]?.tabIds.insert(tabId)
        tasks[owner]?.lastActivityAt = now
    }

    /// Finishes the task a `task_complete` belongs to and says which tabs the cleanup must leave alone.
    public func complete(taskId: String?, tabId: Int?, now: Date = Date()) -> Completion {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        if let finished = resolveLocked(taskId: taskId, tabId: tabId), let task = tasks.removeValue(forKey: finished) {
            return Completion(taskId: finished, protectedTabIds: allTabsLocked(), ownTabIds: task.tabIds)
        }
        if tasks.isEmpty {
            return Completion(taskId: nil, protectedTabIds: [], ownTabIds: nil)
        }
        // Several tasks are running and nothing says which one finished: close nothing they own, mark no card done.
        return Completion(taskId: nil, protectedTabIds: allTabsLocked(), ownTabIds: [])
    }

    /// Forgets a tab that closed.
    public func forgetTab(_ tabId: Int) {
        lock.lock(); defer { lock.unlock() }
        for key in tasks.keys {
            tasks[key]?.tabIds.remove(tabId)
        }
    }

    public var runningTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tasks.count
    }

    // MARK: - Private (call with the lock held)

    private func resolveLocked(taskId: String?, tabId: Int?) -> String? {
        if let id = Self.clean(taskId), tasks[id] != nil {
            return id
        }
        if let tabId, let owner = tasks.first(where: { $0.value.tabIds.contains(tabId) })?.key {
            return owner
        }
        return tasks.count == 1 ? tasks.keys.first : nil
    }

    private func allTabsLocked() -> Set<Int> {
        tasks.values.reduce(into: Set<Int>()) { $0.formUnion($1.tabIds) }
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
