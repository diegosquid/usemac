import Foundation
import UseMacProtocol

/// What UseMac says when the execution mode, a pause or the Emergency stop limits agents: to the person (menu bar
/// icon, its menu, the live preview's caption) and to agents (the refusal's message and `error.hint`).
///
/// A mode that changed without the user noticing used to leave agents failing for no visible reason. Now every mode
/// but Autonomous shows in the menu bar, and every refusal tells the agent which mode refused it and that only the user
/// can change it.
public enum ExecutionModeNotice {
    /// The mode's name as Settings → Safety shows it. Keep it the same as `ExecutionModeChoices.name`.
    public static func name(of policy: GovernancePolicy) -> String {
        switch policy {
        case .autonomous: return "Autonomous"
        case .ask: return "Ask"
        case .confirmSensitive: return "Block sensitive"
        case .readOnly: return "Read-only"
        case .paused: return "Paused"
        }
    }

    // MARK: - Menu bar

    /// The badge on the menu bar icon. Ask and Block sensitive get none: agents still act there, and the menu line and
    /// tooltip name the mode. Read-only and Paused stop most or all of what agents do, so the icon itself shows them.
    public enum Badge: Equatable, Sendable {
        case none
        /// Read-only: an eye (agents can look, not act).
        case readOnly
        /// Paused or the Emergency stop: the pause bars.
        case paused
    }

    public static func badge(policy: GovernancePolicy, killSwitchTripped: Bool) -> Badge {
        if killSwitchTripped || policy == .paused { return .paused }
        return policy == .readOnly ? .readOnly : .none
    }

    /// The menu's "Mode: …" line, which opens Settings. Nil in Autonomous, where nothing is limited.
    public static func menuTitle(policy: GovernancePolicy) -> String? {
        policy == .autonomous ? nil : "Mode: \(name(of: policy))"
    }

    /// The line under `menuTitle`: what the mode lets agents do, in the words Settings → Safety uses.
    public static func menuSubtitle(policy: GovernancePolicy) -> String? {
        switch policy {
        case .autonomous: return nil
        case .ask: return "Uploads, page scripts and ⌘/⌃ shortcuts wait for your OK."
        case .confirmSensitive: return "Uploads, page scripts and ⌘/⌃ shortcuts are blocked."
        case .readOnly: return "Agents can look and scroll. Clicks, typing and uploads are blocked."
        case .paused: return "Agents can't read the screen or act until you resume."
        }
    }

    /// The menu bar icon's tooltip.
    public static func tooltip(policy: GovernancePolicy, killSwitchTripped: Bool, agentActing: Bool) -> String {
        if killSwitchTripped { return "UseMac (Stopped: emergency stop is on)" }
        if policy == .paused { return "UseMac (Paused)" }
        let mode = name(of: policy)
        if agentActing {
            return policy == .autonomous ? "UseMac (Agent acting)" : "UseMac (Agent acting, mode: \(mode))"
        }
        return policy == .autonomous ? "UseMac (Running)" : "UseMac (Mode: \(mode))"
    }

    // MARK: - Refusals

    /// Why a request was refused, for the person: the live preview caption's reason. Nil when nothing blocks agents.
    public static func activityReason(policy: GovernancePolicy, killSwitchTripped: Bool) -> String? {
        if killSwitchTripped { return "the emergency stop is on" }
        switch policy {
        case .autonomous, .ask: return nil
        case .confirmSensitive: return "Block sensitive mode is on"
        case .readOnly: return "Read-only mode is on"
        case .paused: return "UseMac is paused"
        }
    }

    /// What an agent should do about a refusal (`error.hint`): which setting refused it and that only the user can
    /// change it. Nil when nothing blocks agents (Autonomous, or Ask without the Emergency stop).
    public static func agentHint(policy: GovernancePolicy, killSwitchTripped: Bool) -> String? {
        if killSwitchTripped {
            return "The emergency stop (Kill Switch, ⇧⌘⎋) is on in UseMac, so agents can't read the screen or act. Stop and ask the user to resume (UseMac menu bar icon → Resume Agents); agents can't turn it off. Don't look for another route."
        }
        switch policy {
        case .autonomous, .ask:
            return nil
        case .confirmSensitive:
            return "UseMac is set to Block sensitive, so uploads, page scripts and ⌘/⌃ shortcuts are refused. Stop and tell the user; only they can change the execution mode, in UseMac → Settings → Safety (Ask lets them allow each such step). Agents can't relax it. Don't look for another route."
        case .readOnly:
            return "UseMac is set to Read-only, so agents can observe but not act. Stop and ask the user to change the execution mode in UseMac → Settings → Safety; agents can't relax it. Don't look for another route."
        case .paused:
            return "UseMac is paused, so agents can't read the screen or act. Stop and ask the user to resume (UseMac menu bar icon → Resume Agents, or UseMac → Settings → Safety); agents can't change the execution mode."
        }
    }

    /// `POLICY_LOCKED`: `set_policy` tried to relax the mode.
    public static func relaxHint(current: GovernancePolicy) -> String {
        "UseMac is set to \(name(of: current)). Only the user can relax the execution mode, in UseMac → Settings → Safety: ask them if the task needs it, and don't retry set_policy."
    }

    /// A step that was waiting for the user's OK in Ask mode, cancelled because the mode changed to one that doesn't
    /// block it.
    public static let modeChangedWhileWaitingHint = "The execution mode changed while this step waited for the user's OK, so nothing ran. Check status, then retry it once if the new mode allows it."

    /// `browser_act` with `readOnly: true`: the agent's own flag refused a mutating step, not the user's mode.
    public static let readOnlyRequestedHint = "You passed readOnly: true, which refuses mutating steps. Drop readOnly to run them."
}
