import Foundation
import UseMacProtocol

public final class KillSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _isTripped: Bool = false
    private var _policy: GovernancePolicy
    private var _tripReason: String?

    public init(policy: GovernancePolicy = .autonomous) {
        self._policy = policy
    }

    public var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTripped
    }

    public var policy: GovernancePolicy {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _policy
        }
        set {
            lock.lock()
            _policy = newValue
            lock.unlock()
        }
    }

    public func getPolicy() -> GovernancePolicy {
        policy
    }

    public func setPolicy(_ newPolicy: GovernancePolicy) {
        policy = newPolicy
    }

    static func strictnessRank(of policy: GovernancePolicy) -> Int {
        switch policy {
        case .autonomous:
            return 0
        case .ask:
            return 1
        case .confirmSensitive:
            return 2
        case .readOnly:
            return 3
        case .paused:
            return 4
        }
    }

    /// Atomically applies `newPolicy` only if it keeps or increases strictness.
    /// Returns the existing policy if the change was rejected, or `nil` when applied.
    func tightenPolicy(to newPolicy: GovernancePolicy) -> GovernancePolicy? {
        lock.lock()
        defer { lock.unlock() }
        if Self.strictnessRank(of: newPolicy) < Self.strictnessRank(of: _policy) {
            return _policy
        }
        _policy = newPolicy
        return nil
    }

    // MARK: - Approval prompt

    private var _approvalPromptFrame: CGRect?

    /// Screen frame (global, top-left origin) of the Ask-mode prompt while it is on screen, nil otherwise.
    public var approvalPromptFrame: CGRect? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _approvalPromptFrame
        }
        set {
            lock.lock()
            _approvalPromptFrame = newValue
            lock.unlock()
        }
    }

    /// Why real mouse input at `point` must not be sent: it would land on the approval prompt (or right next to it).
    /// The prompt ignores posted clicks anyway; this keeps UseMac from even trying.
    func approvalPromptRefusal(at point: CGPoint) -> String? {
        guard let frame = approvalPromptFrame, frame.insetBy(dx: -24, dy: -24).contains(point) else { return nil }
        return "This input would land on UseMac's approval prompt, so nothing was sent. Only the user answers it. \(WorkspaceMonitor.selfTargetMessage)"
    }

    public func trip(_ tripped: Bool, reason: String? = nil) {
        lock.lock()
        _isTripped = tripped
        _tripReason = tripped ? (reason ?? "Emergency kill switch tripped") : nil
        lock.unlock()
    }

    public func isBlocked(forSensitiveAction: Bool = false, isMutatingAction: Bool = true) -> String? {
        lock.lock()
        let tripped = _isTripped
        let tripReason = _tripReason
        let currentPolicy = _policy
        lock.unlock()

        if tripped {
            return tripReason ?? "Emergency kill switch is tripped"
        }

        switch currentPolicy {
        case .autonomous:
            return nil
        case .ask:
            // Sensitive steps are not blocked here: the engine holds them for the user's answer (ApprovalBroker).
            return nil
        case .readOnly:
            if isMutatingAction {
                return "Mutating action blocked under readOnly policy (scroll, hover, observe, extract, and screenshot are allowed)"
            }
            return nil
        case .confirmSensitive:
            if forSensitiveAction {
                return "Sensitive action blocked under confirmSensitive policy"
            }
            return nil
        case .paused:
            return "Agent actions are paused by governance policy"
        }
    }
}
