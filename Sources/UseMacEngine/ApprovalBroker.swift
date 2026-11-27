import Foundation
import UseMacProtocol

/// The kinds of sensitive step Ask mode holds for the user. A task grant covers kinds, never uploads.
public enum ApprovalKind: String, Sendable, Hashable, CaseIterable {
    /// A key press with ⌘ or ⌃.
    case shortcut
    /// `uploadFile`, or `AXOpen` in a file panel (an upload in disguise).
    case upload
    /// `browser_extract` in `eval` mode.
    case script

    /// What "Allow for this task" lets through, for the prompt's caption.
    public var pluralNoun: String {
        switch self {
        case .shortcut: return "⌘/⌃ shortcuts"
        case .upload: return "uploads"
        case .script: return "page scripts"
        }
    }
}

/// What the HUD shows for one held request.
public struct ApprovalPrompt: Sendable, Equatable, Identifiable {
    public let id: String
    /// The RPC method ("act", "browser_act", "browser_extract").
    public let method: String
    /// The app or tab the steps go to, e.g. "TextEdit" or "Chrome (Default) · tab 812 · Inbox".
    public let target: String
    /// One line per sensitive step: "Press ⌘S", "Upload /Users/me/Downloads/report.pdf".
    public let steps: [String]
    public let kinds: Set<ApprovalKind>
    /// The task the request named itself; only then can the user allow the rest of the task.
    public let taskId: String?
    public let agentName: String?
    public let createdAt: Date
    /// When the request is denied with APPROVAL_TIMEOUT: its arrival plus the timeout, so a queued prompt shows what
    /// is left. A prompt that reaches the screen with less than `minimumVisibleSeconds` left gets that long.
    public internal(set) var deadline: Date
    /// How many more prompts wait behind this one.
    public internal(set) var waitingBehind: Int

    /// "Allow for this task" is offered only for a request tied to a task by its own id, and never for uploads:
    /// each file that leaves the Mac gets its own answer.
    public var canAllowForTask: Bool {
        taskId != nil && !kinds.contains(.upload)
    }
}

/// Holds sensitive requests in Ask mode until the user answers in the HUD, one prompt on screen at a time.
///
/// Nothing reaches `decide` from outside the app: there is no RPC method or MCP tool for it, and it takes a
/// `PhysicalClick`, which only `ApprovalInputCheck.verifyClick` makes from a click the window server says no
/// process posted.
public final class ApprovalBroker: @unchecked Sendable {
    public enum Decision: String, Sendable {
        case allowOnce
        case allowForTask
        case deny
    }

    public enum Outcome: Equatable, Sendable {
        case allowedOnce
        case allowedForTask(taskId: String)
        case allowedByTaskGrant(taskId: String)
        case denied
        /// Nobody answered in time. `whileQueued`: another prompt was on screen the whole time.
        case timedOut(seconds: Int, whileQueued: Bool)
        /// The request could no longer wait (the mode changed or the Kill Switch was used).
        case cancelled(reason: String)

        public var isAllowed: Bool {
            switch self {
            case .allowedOnce, .allowedForTask, .allowedByTaskGrant:
                return true
            case .denied, .timedOut, .cancelled:
                return false
            }
        }
    }

    /// What the engine asks about.
    public struct Request: Sendable {
        public var method: String
        public var target: String
        public var steps: [String]
        public var kinds: Set<ApprovalKind>
        public var taskId: String?
        /// What a task grant is tied to (the app, or the Chrome profile), so allowing ⌘S in TextEdit doesn't allow
        /// it everywhere.
        public var grantTarget: String
        public var agentName: String?

        public init(method: String, target: String, steps: [String], kinds: Set<ApprovalKind>, taskId: String?, grantTarget: String, agentName: String? = nil) {
            self.method = method
            self.target = target
            self.steps = steps
            self.kinds = kinds
            self.taskId = taskId
            self.grantTarget = grantTarget
            self.agentName = agentName
        }
    }

    private struct GrantKey: Hashable {
        let kind: ApprovalKind
        let target: String
    }

    private struct Entry {
        var prompt: ApprovalPrompt
        var grantTarget: String
        var continuation: CheckedContinuation<Outcome, Never>?
    }

    /// A queued prompt that reaches the screen gets at least this long, so the user can read it.
    public static let minimumVisibleSeconds = TimeInterval(ApprovalTiming.minimumVisibleSeconds)

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var _minimumVisible = ApprovalBroker.minimumVisibleSeconds
    private var grants: [String: Set<GrantKey>] = [:]
    private var ignoredInputAudited: Set<String> = []
    private var _timeout = TimeInterval(ApprovalTiming.defaultTimeoutSeconds)
    private var _onChange: (@Sendable () -> Void)?
    private let pollNanoseconds: UInt64

    public init(pollInterval: TimeInterval = 0.2) {
        self.pollNanoseconds = UInt64(max(0.01, pollInterval) * 1_000_000_000)
    }

    /// Called (on any thread) whenever the prompt on screen or the queue behind it changes. Read `currentPrompt`.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); _onChange = newValue; lock.unlock() }
    }

    /// Seconds a request waits for an answer, from its arrival. Clamped to `ApprovalTiming.timeoutRangeSeconds`.
    public var timeoutSeconds: Int {
        get { Int(timeoutInterval.rounded(.up)) }
        set { timeoutInterval = TimeInterval(ApprovalTiming.clampedTimeoutSeconds(newValue)) }
    }

    /// How long a queued prompt that reaches the screen stays at least (tests shorten it).
    var minimumVisibleInterval: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _minimumVisible }
        set { lock.lock(); _minimumVisible = max(0, newValue); lock.unlock() }
    }

    /// The same, unclamped (tests use fractions of a second).
    var timeoutInterval: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _timeout }
        set { lock.lock(); _timeout = max(0.05, newValue); lock.unlock() }
    }

    /// The prompt on screen: the oldest request still waiting.
    public var currentPrompt: ApprovalPrompt? {
        lock.lock(); defer { lock.unlock() }
        return headPromptLocked()
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Waits for the user's answer. `cancelReason` is polled while the request waits; when it returns a reason, the
    /// request stops waiting and the outcome is `.cancelled`.
    public func requestApproval(
        _ request: Request,
        now: Date = Date(),
        cancelReason: @escaping @Sendable () -> String? = { nil }
    ) async -> Outcome {
        if let taskId = request.taskId, coveredByGrant(taskId: taskId, kinds: request.kinds, target: request.grantTarget) {
            return .allowedByTaskGrant(taskId: taskId)
        }
        let timeout = timeoutInterval
        let prompt = ApprovalPrompt(
            id: "approval-" + UUID().uuidString.prefix(8).lowercased(),
            method: request.method,
            target: request.target,
            steps: request.steps,
            kinds: request.kinds,
            taskId: request.taskId,
            agentName: request.agentName,
            createdAt: now,
            deadline: now.addingTimeInterval(timeout),
            waitingBehind: 0
        )
        let id = prompt.id
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            lock.lock()
            entries.append(Entry(prompt: prompt, grantTarget: request.grantTarget, continuation: continuation))
            let notify = _onChange
            lock.unlock()
            notify?()
            startWatchdog(id: id, timeout: timeout, cancelReason: cancelReason)
        }
        return outcome
    }

    /// The user's answer, from a physical click on a button of the prompt on screen. Returns false when that
    /// prompt is no longer the one on screen (answered, timed out) or the decision doesn't apply to it.
    @discardableResult
    public func decide(promptId: String, decision: Decision, click: ApprovalInputCheck.PhysicalClick) -> Bool {
        _ = click
        lock.lock()
        guard let head = entries.first, head.prompt.id == promptId else {
            lock.unlock()
            return false
        }
        let outcome: Outcome
        switch decision {
        case .allowOnce:
            outcome = .allowedOnce
        case .deny:
            outcome = .denied
        case .allowForTask:
            guard head.prompt.canAllowForTask, let taskId = head.prompt.taskId else {
                lock.unlock()
                return false
            }
            outcome = .allowedForTask(taskId: taskId)
        }
        lock.unlock()
        return finish(id: promptId, outcome: outcome)
    }

    /// Forgets the task's grants (the task finished).
    public func endTask(_ taskId: String?) {
        guard let taskId else { return }
        lock.lock()
        grants.removeValue(forKey: taskId)
        lock.unlock()
    }

    /// True the first time a prompt ignores posted input, so the audit log gets one entry per prompt, not one per
    /// event.
    public func shouldAuditIgnoredInput(promptId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ignoredInputAudited.insert(promptId).inserted
    }

    func hasGrant(taskId: String, kind: ApprovalKind, target: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return grants[taskId]?.contains(GrantKey(kind: kind, target: target)) == true
    }

    // MARK: - Private

    private func coveredByGrant(taskId: String, kinds: Set<ApprovalKind>, target: String) -> Bool {
        guard !kinds.isEmpty, !kinds.contains(.upload) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let granted = grants[taskId] else { return false }
        return kinds.allSatisfy { granted.contains(GrantKey(kind: $0, target: target)) }
    }

    private func startWatchdog(id: String, timeout: TimeInterval, cancelReason: @escaping @Sendable () -> String?) {
        let pollNs = pollNanoseconds
        let arrivedAt = Date()
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: pollNs)
                guard let self else { return }
                guard let (index, deadline, headDeadline) = self.position(of: id) else { return }
                if let reason = cancelReason() {
                    self.finish(id: id, outcome: .cancelled(reason: reason))
                    return
                }
                let now = Date()
                // A queued request times out only while the prompt on screen is still live (it got extra time);
                // when that one is about to time out too, wait for it, then get the time on screen.
                if now >= deadline, index == 0 || headDeadline > now {
                    let waited = max(timeout, Date().timeIntervalSince(arrivedAt))
                    self.finish(id: id, outcome: .timedOut(seconds: Int(waited.rounded()), whileQueued: index > 0))
                    return
                }
            }
        }
    }

    private func position(of id: String) -> (index: Int, deadline: Date, headDeadline: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.prompt.id == id }) else { return nil }
        return (index, entries[index].prompt.deadline, entries[0].prompt.deadline)
    }

    @discardableResult
    private func finish(id: String, outcome: Outcome) -> Bool {
        lock.lock()
        guard let index = entries.firstIndex(where: { $0.prompt.id == id }) else {
            lock.unlock()
            return false
        }
        let entry = entries.remove(at: index)
        ignoredInputAudited.remove(id)
        if case .allowedForTask(let taskId) = outcome {
            var granted = grants[taskId] ?? []
            for kind in entry.prompt.kinds where kind != .upload {
                granted.insert(GrantKey(kind: kind, target: entry.grantTarget))
            }
            grants[taskId] = granted
        }
        if index == 0, !entries.isEmpty {
            // The next prompt reaches the screen: give it time to be read.
            let earliest = Date().addingTimeInterval(_minimumVisible)
            if entries[0].prompt.deadline < earliest {
                entries[0].prompt.deadline = earliest
            }
        }
        let notify = _onChange
        lock.unlock()
        entry.continuation?.resume(returning: outcome)
        notify?()
        return true
    }

    private func headPromptLocked() -> ApprovalPrompt? {
        guard var head = entries.first?.prompt else { return nil }
        head.waitingBehind = entries.count - 1
        return head
    }
}
