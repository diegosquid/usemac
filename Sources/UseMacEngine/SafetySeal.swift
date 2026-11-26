import CryptoKit
import Foundation
import UseMacProtocol

/// The safety settings exactly as they are saved in UserDefaults: what the seal covers.
///
/// The raw values, not what UseMac makes of them (`state`), so the seal says whether these are the very values UseMac
/// wrote last.
public struct SavedSafetySettings: Equatable, Sendable {
    public var policy: String?
    public var policyBeforePause: String?
    public var killSwitchTripped: Bool
    public var debugCaptureEnabled: Bool

    public init(policy: String?, policyBeforePause: String?, killSwitchTripped: Bool, debugCaptureEnabled: Bool) {
        self.policy = policy
        self.policyBeforePause = policyBeforePause
        self.killSwitchTripped = killSwitchTripped
        self.debugCaptureEnabled = debugCaptureEnabled
    }

    /// What UseMac saves for `state`.
    public init(_ state: StartupSafetyState) {
        self.init(
            policy: state.policy.rawValue,
            policyBeforePause: state.policyBeforePause?.rawValue,
            killSwitchTripped: state.killSwitchTripped,
            debugCaptureEnabled: state.debugCaptureEnabled
        )
    }

    /// What UseMac starts with from these values.
    public var state: StartupSafetyState {
        StartupSafetyState.resolve(
            savedPolicy: policy,
            savedPolicyBeforePause: policyBeforePause,
            savedKillSwitchTripped: killSwitchTripped,
            savedDebugCaptureEnabled: debugCaptureEnabled
        )
    }
}

/// The seal key and how many times UseMac has saved the safety settings with it. Both live in the login Keychain.
///
/// The count is part of every seal, so an older copy of the settings and its seal (from an earlier `defaults read`,
/// or a backup) no longer matches once UseMac has saved again.
public struct SafetySealSecret: Equatable, Sendable {
    public static let keyByteCount = 32
    /// The format of `encoded`: a version byte, the key, then the count as 8 bytes, big-endian.
    static let formatVersion: UInt8 = 1
    static let encodedByteCount = 1 + keyByteCount + 8

    public var key: Data
    public var generation: UInt64

    public init(key: Data, generation: UInt64) {
        self.key = key
        self.generation = generation
    }

    /// 32 new random bytes, never used to seal anything yet.
    public static func generate() -> SafetySealSecret {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return SafetySealSecret(key: key, generation: 0)
    }

    /// What the Keychain item holds.
    public var encoded: Data {
        var data = Data([Self.formatVersion])
        data.append(key)
        withUnsafeBytes(of: generation.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Nil when `encoded` isn't a seal key this build knows.
    public init?(encoded: Data) {
        let bytes = [UInt8](encoded)
        guard bytes.count == Self.encodedByteCount, bytes[0] == Self.formatVersion else { return nil }
        let keyBytes = bytes[1...Self.keyByteCount]
        let generation = bytes[(1 + Self.keyByteCount)...].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.init(key: Data(keyBytes), generation: generation)
    }
}

/// Why the saved safety settings can't be trusted at launch.
public enum SafetySealProblem: String, CaseIterable, Equatable, Sendable {
    /// Sealing is on, but there is no seal.
    case sealMissing
    /// The seal doesn't match the saved values (or the count in the Keychain).
    case sealMismatch
    /// Sealing is on, but the seal key is gone from the Keychain.
    case keyMissing
    /// The Keychain item isn't a seal key.
    case keyInvalid
    /// The Keychain refused or failed to give the key (denied, locked, another error).
    case keyUnreadable
    /// The seal key is in the Keychain, but the marker that sealing is on is gone.
    case markerMissing
    /// The marker names a seal format this build doesn't know.
    case unknownVersion

    /// For History.
    var auditDetail: String {
        switch self {
        case .sealMissing: return "the seal is missing"
        case .sealMismatch: return "the seal doesn't match"
        case .keyMissing: return "the seal key is missing from the Keychain"
        case .keyInvalid: return "the seal key in the Keychain isn't valid"
        case .keyUnreadable: return "the seal key couldn't be read from the Keychain"
        case .markerMissing: return "the seal marker is missing"
        case .unknownVersion: return "the seal version is unknown"
        }
    }
}

/// What UseMac found when it read the seal key from the Keychain.
public enum SafetySealKeyRead: Equatable, Sendable {
    case found(SafetySealSecret)
    /// No item: nothing was ever sealed on this Mac, or someone deleted it.
    case none
    /// An item that isn't a seal key.
    case invalid
    /// The Keychain refused or failed.
    case unreadable
}

/// What the seal says about the saved safety settings at launch.
public enum SafetySealCheck: Equatable, Sendable {
    /// The seal matches: these are the values UseMac saved last.
    case verified
    /// No marker and no key: a new install, or the first launch of a version that seals. UseMac seals now.
    case firstSeal
    /// The values may have been changed outside UseMac. UseMac starts from `StartupSafetyState.tamperFallback`.
    case tampered(SafetySealProblem)

    public var problem: SafetySealProblem? {
        if case .tampered(let problem) = self { return problem }
        return nil
    }
}

/// The seal over UseMac's saved safety settings: an HMAC-SHA256 with a key only UseMac can read from the Keychain.
///
/// Agents can only make safety stricter. Without the seal, a process running as the user could loosen the saved
/// settings (`defaults write`) and relaunch UseMac. With it, values UseMac didn't write fail the check and UseMac
/// starts paused. Only `SafetySettingsStore` writes the settings and the seal.
public enum SafetySeal {
    /// What the marker holds while the settings are sealed in this format.
    public static let version = 1

    /// The bytes the seal covers. Every value has its name, and every string its length, so no two sets of values
    /// encode the same way. Changing this format changes every seal: it needs a new `version`.
    public static func canonicalEncoding(of saved: SavedSafetySettings, generation: UInt64) -> Data {
        var text = "UseMac safety seal v\(version)\n"
        text += field("policy", saved.policy)
        text += field("policyBeforePause", saved.policyBeforePause)
        text += "killSwitchTripped=\(saved.killSwitchTripped ? 1 : 0)\n"
        text += "debugCaptureEnabled=\(saved.debugCaptureEnabled ? 1 : 0)\n"
        text += "generation=\(generation)\n"
        return Data(text.utf8)
    }

    private static func field(_ name: String, _ value: String?) -> String {
        guard let value else { return "\(name)~\n" }
        return "\(name)=\(value.utf8.count):\(value)\n"
    }

    /// The seal for `saved`, base64.
    public static func seal(_ saved: SavedSafetySettings, with secret: SafetySealSecret) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: canonicalEncoding(of: saved, generation: secret.generation),
            using: SymmetricKey(data: secret.key)
        )
        return Data(code).base64EncodedString()
    }

    /// Whether `seal` is the seal for `saved` (compared in constant time).
    public static func isValid(_ seal: String?, for saved: SavedSafetySettings, with secret: SafetySealSecret) -> Bool {
        guard let seal, let code = Data(base64Encoded: seal), code.count == SHA256.byteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: canonicalEncoding(of: saved, generation: secret.generation),
            using: SymmetricKey(data: secret.key)
        )
    }

    /// Decides what the saved values are worth. `marker` is the saved seal version, nil when there is none.
    ///
    /// Fails closed: anything other than a matching seal, or a clean first launch (no marker, no key), is `tampered`.
    public static func check(marker: Int?, seal: String?, saved: SavedSafetySettings, key: SafetySealKeyRead) -> SafetySealCheck {
        guard let marker else {
            switch key {
            case .none: return .firstSeal
            case .found, .invalid: return .tampered(.markerMissing)
            case .unreadable: return .tampered(.keyUnreadable)
            }
        }
        guard marker == version else { return .tampered(.unknownVersion) }
        switch key {
        case .none: return .tampered(.keyMissing)
        case .invalid: return .tampered(.keyInvalid)
        case .unreadable: return .tampered(.keyUnreadable)
        case .found(let secret):
            guard seal != nil else { return .tampered(.sealMissing) }
            return isValid(seal, for: saved, with: secret) ? .verified : .tampered(.sealMismatch)
        }
    }
}

extension StartupSafetyState {
    /// What UseMac starts with when the saved values can't be trusted: Paused, which agents can't leave, with Debug
    /// capture off and the Emergency stop on if it was saved on. Resume goes back to the saved mode, as after any
    /// pause, so the user should check it first (the notice says so).
    public var tamperFallback: StartupSafetyState {
        StartupSafetyState(
            policy: .paused,
            policyBeforePause: policyBeforePause,
            killSwitchTripped: killSwitchTripped,
            debugCaptureEnabled: false
        )
    }

    /// What UseMac seals the first time: the saved values, but with Debug capture off. The first seal also happens
    /// when someone deleted both the marker and the Keychain item, so it never turns Debug capture on.
    public var firstSealState: StartupSafetyState {
        var state = self
        state.debugCaptureEnabled = false
        return state
    }
}

/// What UseMac tells the user after it found the safety settings changed outside it.
public struct SafetySealNotice: Equatable, Sendable {
    /// The audit method for the seal check (History lists it with the setting changes).
    public static let auditMethod = "safety_settings"

    public let title: String
    public let message: String
    /// The menu bar menu's line, and the line under it.
    public let menuTitle: String
    public let menuSubtitle: String

    /// Nil unless the check found a problem.
    public init?(_ check: SafetySealCheck) {
        guard let problem = check.problem else { return nil }
        menuSubtitle = "Automation is paused. Check Settings → Safety before you resume."
        if problem == .keyUnreadable {
            title = "UseMac couldn't check its safety settings"
            message = "UseMac couldn't read its safety seal from the Keychain, so automation is paused and Debug capture is off. Check your settings in Settings → Safety before you resume."
            menuTitle = "Couldn't Check Safety Settings"
        } else {
            title = "Safety settings changed outside UseMac"
            message = "UseMac's safety settings were changed outside UseMac, so automation is paused and Debug capture is off. Check them in Settings → Safety before you resume."
            menuTitle = "Safety Settings Changed Outside UseMac"
        }
    }

    /// The History entry for a launch, nil when the seal matched.
    public static func auditSummary(check: SafetySealCheck, sealed: Bool) -> String? {
        switch check {
        case .verified:
            return nil
        case .firstSeal:
            return sealed
                ? "Sealed the safety settings (a new install, or the first launch of a version that seals them)"
                : "Couldn't seal the safety settings: the Keychain didn't save the seal key. UseMac tries again at the next change."
        case .tampered(let problem):
            let lead = problem == .keyUnreadable
                ? "Couldn't check the safety settings"
                : "Safety settings changed outside UseMac"
            return "\(lead) (\(problem.auditDetail)). Started paused with Debug capture off."
        }
    }
}
