import Foundation
import UseMacProtocol

/// The execution mode, the mode Resume goes back to, the Emergency stop and Debug capture that UseMac starts with, read
/// from what the app saved in UserDefaults. Nothing saved (a new install), or a mode this build doesn't know, starts in
/// Autonomous with the Emergency stop and Debug capture off.
public struct StartupSafetyState: Equatable, Sendable {
    /// The UserDefaults keys the app saves the safety settings under. Only `SafetySettingsStore` writes them, always
    /// with a new seal (SafetySeal.swift).
    public enum DefaultsKey {
        public static let policy = "usemac.safety.policy"
        public static let policyBeforePause = "usemac.safety.policyBeforePause"
        public static let killSwitchTripped = "usemac.safety.killSwitchTripped"
        /// Turned on only when the user confirms in Settings → Developer (DebugCapture.swift).
        public static let debugCaptureEnabled = "usemac.safety.debugCaptureEnabled"
        /// The HMAC over the four values above and the save count kept in the Keychain, base64.
        public static let seal = "usemac.safety.seal"
        /// The seal format (`SafetySeal.version`) once the values are sealed. Its presence means a seal is expected.
        public static let sealVersion = "usemac.safety.sealVersion"
    }

    public var policy: GovernancePolicy
    /// The mode Resume restores after a pause (`GovernanceResume`). Nil when no mode other than Paused is known.
    public var policyBeforePause: GovernancePolicy?
    public var killSwitchTripped: Bool
    /// Whether agents may capture UseMac's own windows (`debug_capture`). Off unless the user turned it on.
    public var debugCaptureEnabled: Bool

    public init(policy: GovernancePolicy, policyBeforePause: GovernancePolicy?, killSwitchTripped: Bool, debugCaptureEnabled: Bool = false) {
        self.policy = policy
        self.policyBeforePause = policyBeforePause
        self.killSwitchTripped = killSwitchTripped
        self.debugCaptureEnabled = debugCaptureEnabled
    }

    /// A new install: Autonomous, nothing to resume to, Emergency stop and Debug capture off.
    public static let factoryDefault = StartupSafetyState(policy: .autonomous, policyBeforePause: nil, killSwitchTripped: false)

    /// Resolves the saved raw values. An unknown or missing mode falls back to Autonomous; the mode to resume to is
    /// the saved one unless it is Paused, else the saved mode unless that is Paused.
    public static func resolve(
        savedPolicy: String?,
        savedPolicyBeforePause: String?,
        savedKillSwitchTripped: Bool,
        savedDebugCaptureEnabled: Bool = false
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
            killSwitchTripped: savedKillSwitchTripped,
            debugCaptureEnabled: savedDebugCaptureEnabled
        )
    }

    /// Reads the saved safety settings from `defaults` without checking their seal. The app starts from
    /// `SafetySettingsStore.load()`, which does.
    public static func load(from defaults: UserDefaults) -> StartupSafetyState {
        SafetySettingsStore.readSaved(from: defaults).state
    }

    /// Puts `engine` in this state. The mode is always set, so the starting mode never depends on `KillSwitch`'s own
    /// default.
    public func apply(to engine: UseMacEngineService) {
        engine.setGovernancePolicy(policy)
        if killSwitchTripped {
            engine.tripKillSwitch(true)
        }
        // Restoring what the user chose isn't a change to record in History.
        engine.setDebugCaptureEnabled(debugCaptureEnabled, recordInHistory: false)
    }
}
