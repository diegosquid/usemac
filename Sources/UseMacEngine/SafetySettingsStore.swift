import Foundation
import UseMacProtocol

/// Where the seal key lives: the login Keychain in the app (SafetySealKeychain.swift), memory in tests.
public protocol SafetySealSecretStore: AnyObject {
    /// The saved bytes, nil when there is no item. Throws when the Keychain refuses or fails.
    func readSecret() throws -> Data?
    /// Saves `data`, replacing what was saved.
    func writeSecret(_ data: Data) throws
}

/// The only code that writes UseMac's safety settings: the keys in `StartupSafetyState.DefaultsKey`, the app and site
/// rules (`TargetRulesStore.Keys`) and Record typed text (`AuditLogSettings.recordTypedTextKey`). Every save writes all
/// of them with a new seal, so none can be saved unsealed by mistake (SafetySealTests scans Sources/ for other writes).
///
/// The app makes one at launch, calls `load()` once, then saves each change the user or an agent makes. Use it from
/// one thread: the app's main thread.
public final class SafetySettingsStore {
    /// What UseMac starts with, and what the seal said.
    public struct Launch: Equatable, Sendable {
        public let state: StartupSafetyState
        /// The app and site rules to enforce (`TargetRulesStore.shared`).
        public let rules: TargetRules
        /// Whether History keeps typed text (`AuditLogSettings.recordsTypedText`).
        public let recordsTypedText: Bool
        public let check: SafetySealCheck
        /// False when the Keychain didn't take the seal key: nothing is sealed until a later save works.
        public let sealed: Bool
    }

    private typealias Key = StartupSafetyState.DefaultsKey
    private typealias RuleKey = TargetRulesStore.Keys

    private let defaults: UserDefaults
    private let secretStore: SafetySealSecretStore
    /// The key and count the next save uses. Kept even when the Keychain didn't take it, so a later save can retry.
    private var secret: SafetySealSecret?
    /// What UseMac last saved (or read, when the seal matched).
    public private(set) var saved: SavedSafetySettings

    public init(defaults: UserDefaults, secretStore: SafetySealSecretStore) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.saved = Self.readSaved(from: defaults)
    }

    /// The saved values as they are, sealed or not.
    public static func readSaved(from defaults: UserDefaults) -> SavedSafetySettings {
        SavedSafetySettings(
            policy: defaults.string(forKey: Key.policy),
            policyBeforePause: defaults.string(forKey: Key.policyBeforePause),
            killSwitchTripped: defaults.bool(forKey: Key.killSwitchTripped),
            debugCaptureEnabled: defaults.bool(forKey: Key.debugCaptureEnabled),
            rulesMode: defaults.string(forKey: RuleKey.mode),
            deniedApps: defaults.stringArray(forKey: RuleKey.deniedApps),
            deniedSites: defaults.stringArray(forKey: RuleKey.deniedSites),
            allowedApps: defaults.stringArray(forKey: RuleKey.allowedApps),
            allowedSites: defaults.stringArray(forKey: RuleKey.allowedSites),
            recordTypedText: defaults.bool(forKey: AuditLogSettings.recordTypedTextKey)
        )
    }

    // MARK: - Launch

    /// Reads the saved values and checks their seal.
    ///
    /// - A matching seal: the saved values.
    /// - No marker and no key: seals the saved values with a new key, Debug capture and Record typed text off
    ///   (`firstSealState`). The rules stay as saved: a stricter list the user made must not get looser.
    /// - A matching seal in the first format: the same, with the saved Debug capture kept (`.upgraded`).
    /// - Anything else: `tamperFallback` (Paused, Debug capture off), Record typed text off and the default rules,
    ///   sealed again so the next launch is clean.
    public func load() -> Launch {
        let current = Self.readSaved(from: defaults)
        let marker = defaults.object(forKey: Key.sealVersion) == nil ? nil : defaults.integer(forKey: Key.sealVersion)
        let keyRead = readKey()
        let check = SafetySeal.check(marker: marker, seal: defaults.string(forKey: Key.seal), saved: current, key: keyRead)

        if case .found(let found) = keyRead {
            secret = found
        } else {
            secret = .generate()
        }

        let start: StartupSafetyState
        var next: SavedSafetySettings
        switch check {
        case .verified:
            saved = current
            return Launch(state: current.state, rules: current.rules, recordsTypedText: current.recordTypedText, check: check, sealed: true)
        case .firstSeal:
            start = current.state.firstSealState
            next = current.with(state: start)
        case .upgraded:
            start = current.state
            next = current
        case .tampered:
            start = current.state.tamperFallback
            next = current.with(state: start).withDefaultRules
        }
        // Record typed text wasn't sealed before version 2, and can't be trusted after a failed check.
        next.recordTypedText = false
        let sealed = save(next)
        return Launch(state: start, rules: next.rules, recordsTypedText: false, check: check, sealed: sealed)
    }

    private func readKey() -> SafetySealKeyRead {
        let data: Data?
        do {
            data = try secretStore.readSecret()
        } catch {
            return .unreadable
        }
        guard let data else { return .none }
        return SafetySealSecret(encoded: data).map(SafetySealKeyRead.found) ?? .invalid
    }

    // MARK: - Saving

    /// Saves the execution mode (and the mode Resume goes back to). Returns the mode Resume goes back to now.
    @discardableResult
    public func savePolicy(_ policy: GovernancePolicy, previous: GovernancePolicy) -> GovernancePolicy? {
        var next = saved
        if policy != .paused {
            next.policyBeforePause = policy.rawValue
        } else if previous != .paused {
            next.policyBeforePause = previous.rawValue
        }
        next.policy = policy.rawValue
        save(next)
        return next.state.policyBeforePause
    }

    public func saveKillSwitch(_ tripped: Bool) {
        var next = saved
        next.killSwitchTripped = tripped
        save(next)
    }

    public func saveDebugCapture(_ enabled: Bool) {
        var next = saved
        next.debugCaptureEnabled = enabled
        save(next)
    }

    /// Saves the app and site rules the user set in Settings (`TargetRulesStore.update`).
    public func saveRules(_ rules: TargetRules) {
        save(saved.with(rules: rules))
    }

    public func saveRecordTypedText(_ enabled: Bool) {
        var next = saved
        next.recordTypedText = enabled
        save(next)
    }

    /// Writes every value and a new seal. The count in the Keychain goes up first: when the Keychain doesn't take it,
    /// the old seal is removed, so the next launch treats the values as unchecked rather than trusting an old seal.
    /// Returns whether the values are sealed.
    @discardableResult
    private func save(_ next: SavedSafetySettings) -> Bool {
        saved = next
        writeValues(next)

        guard var sealing = secret else {
            defaults.removeObject(forKey: Key.seal)
            return false
        }
        sealing.generation &+= 1
        secret = sealing
        do {
            try secretStore.writeSecret(sealing.encoded)
        } catch {
            // Keep the marker as it is: without one (the first seal) the next launch tries again, with one it fails
            // closed.
            defaults.removeObject(forKey: Key.seal)
            return false
        }
        defaults.set(SafetySeal.seal(next, with: sealing), forKey: Key.seal)
        defaults.set(SafetySeal.version, forKey: Key.sealVersion)
        return true
    }

    private func writeValues(_ values: SavedSafetySettings) {
        if let policy = values.policy {
            defaults.set(policy, forKey: Key.policy)
        } else {
            defaults.removeObject(forKey: Key.policy)
        }
        if let beforePause = values.policyBeforePause {
            defaults.set(beforePause, forKey: Key.policyBeforePause)
        } else {
            defaults.removeObject(forKey: Key.policyBeforePause)
        }
        defaults.set(values.killSwitchTripped, forKey: Key.killSwitchTripped)
        defaults.set(values.debugCaptureEnabled, forKey: Key.debugCaptureEnabled)
        write(values.rulesMode, forKey: RuleKey.mode)
        write(values.deniedApps, forKey: RuleKey.deniedApps)
        write(values.deniedSites, forKey: RuleKey.deniedSites)
        write(values.allowedApps, forKey: RuleKey.allowedApps)
        write(values.allowedSites, forKey: RuleKey.allowedSites)
        defaults.set(values.recordTypedText, forKey: AuditLogSettings.recordTypedTextKey)
    }

    /// Saves `value`, or removes the key for nil (never saved: the default applies).
    private func write(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
