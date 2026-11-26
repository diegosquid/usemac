import Foundation

/// How long a request may wait for the user's answer in Ask mode, shared by the app (the prompt's deadline) and
/// the clients (the CLI and the MCP server wait that much longer for the methods that can be held).
public enum ApprovalTiming {
    /// A held request is denied with `APPROVAL_TIMEOUT` when nobody answers within this many seconds of its arrival.
    /// 45 s leaves an allowed step about 15 s to run inside the 60 s tool-call limit many MCP hosts use.
    public static let defaultTimeoutSeconds = 45
    /// The app-only setting (`usemac.safety.approvalTimeoutSeconds`) is clamped to this range.
    public static let timeoutRangeSeconds: ClosedRange<Int> = 5...60
    /// A prompt that waited behind another one gets at least this long on screen, on top of its timeout.
    public static let minimumVisibleSeconds = 10
    /// Extra time a client allows on top of its usual timeout for a method that can wait for an approval: the
    /// longest possible wait (the longest timeout plus the minimum time on screen), plus a margin for the
    /// foreground-idle wait after an allowed step.
    public static let clientAllowanceMs = 75_000

    /// The UserDefaults key the app reads the timeout from (no UI; for tests and support).
    public static let timeoutDefaultsKey = "usemac.safety.approvalTimeoutSeconds"

    public static func clampedTimeoutSeconds(_ raw: Int?) -> Int {
        guard let raw, raw > 0 else { return defaultTimeoutSeconds }
        return min(max(raw, timeoutRangeSeconds.lowerBound), timeoutRangeSeconds.upperBound)
    }

    /// Methods whose sensitive steps wait for the user in Ask mode.
    public static func canWaitForApproval(_ method: RPCMethod) -> Bool {
        switch method {
        case .act, .browserAct, .browserExtract:
            return true
        default:
            return false
        }
    }

    /// What a client adds to its timeout for `method`.
    public static func clientAllowanceMs(for method: RPCMethod) -> Int {
        canWaitForApproval(method) ? clientAllowanceMs : 0
    }
}
