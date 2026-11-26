import Foundation
import UseMacProtocol

/// The execution mode, the mode Resume goes back to, and the Emergency stop that UseMac starts with, read from what
/// the app saved in UserDefaults. Nothing saved (a new install), or a mode this build doesn't know, starts in
/// Autonomous with the Emergency stop off.
public struct StartupSafetyState: Equatable, Sendable {
    /// The UserDefaults keys the app saves the safety settings under.
    public enum DefaultsKey {
        public static let policy = "usemac.safety.policy"
        public static let policyBeforePause = "usemac.safety.policyBeforePause"
        public static let killSwitchTripped = "usemac.safety.killSwitchTripped"
    }

    public var policy: GovernancePolicy
    /// The mode Resume restores after a pause (`GovernanceResume`). Nil when no mode other than Paused is known.
    public var policyBeforePause: GovernancePolicy?
    public var killSwitchTripped: Bool

    public init(policy: GovernancePolicy, policyBeforePause: GovernancePolicy?, killSwitchTripped: Bool) {
        self.policy = policy
        self.policyBeforePause = policyBeforePause
        self.killSwitchTripped = killSwitchTripped
    }

    /// A new install: Autonomous, nothing to resume to, Emergency stop off.
    public static let factoryDefault = StartupSafetyState(policy: .autonomous, policyBeforePause: nil, killSwitchTripped: false)

    /// Resolves the saved raw values. An unknown or missing mode falls back to Autonomous; the mode to resume to is
    /// the saved one unless it is Paused, else the saved mode unless that is Paused.
    public static func resolve(
        savedPolicy: String?,
        savedPolicyBeforePause: String?,
        savedKillSwitchTripped: Bool
    ) -> StartupSafetyState {
        let policy = savedPolicy.flatMap(GovernancePolicy.init(rawValue:))
        let beforePause = savedPolicyBeforePause.flatMap(GovernancePolicy.init(rawValue:))
        let resumeTo: GovernancePolicy?
        if let beforePause, beforePause != .paused {
            resumeTo = beforePause
        } else if let policy, policy != .paused {
            resumeTo = policy
        } else {
            resumeTo = nil
        }
        return StartupSafetyState(
            policy: policy ?? factoryDefault.policy,
            policyBeforePause: resumeTo,
            killSwitchTripped: savedKillSwitchTripped
        )
    }

    /// Reads the saved safety settings from `defaults`.
    public static func load(from defaults: UserDefaults) -> StartupSafetyState {
        resolve(
            savedPolicy: defaults.string(forKey: DefaultsKey.policy),
            savedPolicyBeforePause: defaults.string(forKey: DefaultsKey.policyBeforePause),
            savedKillSwitchTripped: defaults.bool(forKey: DefaultsKey.killSwitchTripped)
        )
    }

    /// Puts `engine` in this state. The mode is always set, so the starting mode never depends on `KillSwitch`'s own
    /// default.
    public func apply(to engine: UseMacEngineService) {
        engine.setGovernancePolicy(policy)
        if killSwitchTripped {
            engine.tripKillSwitch(true)
        }
    }
}
