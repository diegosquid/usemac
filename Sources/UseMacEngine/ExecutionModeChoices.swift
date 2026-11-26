import UseMacProtocol

/// The execution modes the app offers and the words it uses for them, kept in one place so Settings and
/// the Setup guide can't drift apart.
public enum ExecutionModeChoices {
    /// Settings → Safety offers every mode, from the most permissive to the most restrictive.
    public static let settings: [GovernancePolicy] = [.autonomous, .ask, .confirmSensitive, .readOnly, .paused]

    /// The Setup guide offers the modes agents can work in. Paused is left out: it stops every agent until
    /// the user resumes, which would leave a fresh setup doing nothing. The guide teaches the stop shortcut
    /// on the next row instead, and Paused stays in Settings.
    public static let setupGuide: [GovernancePolicy] = settings.filter { $0 != .paused }

    /// The mode's label in the app, as the README's execution modes table shows it.
    public static func name(_ policy: GovernancePolicy) -> String {
        switch policy {
        case .autonomous: return "Autonomous"
        case .ask: return "Ask"
        case .confirmSensitive: return "Block sensitive"
        case .readOnly: return "Read-only"
        case .paused: return "Paused"
        }
    }

    /// One line on what agents may do in the mode.
    public static func summary(_ policy: GovernancePolicy) -> String {
        switch policy {
        case .autonomous: return "Agents can read and act without asking."
        case .ask: return "Uploads, page scripts and ⌘/⌃ shortcuts wait for your OK."
        case .confirmSensitive: return "Uploads, page scripts and ⌘/⌃ shortcuts are blocked."
        case .readOnly: return "Agents can look and scroll. Clicks, typing and uploads are blocked."
        case .paused: return "Agents can't read the screen or act until you resume."
        }
    }
}
