import UseMacProtocol

public enum GovernanceResume {
    /// Policy to apply when the user resumes agents.
    public static func policyAfterResume(current: GovernancePolicy, beforePause: GovernancePolicy?) -> GovernancePolicy {
        guard current == .paused else {
            return current
        }
        if let beforePause, beforePause != .paused {
            return beforePause
        }
        return .autonomous
    }
}
