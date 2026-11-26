import Foundation
import UseMacProtocol

/// What an audit entry was: an action that changed an app or a page, an observation that only read, or task and
/// settings bookkeeping. Settings → History styles each kind differently and can hide observations.
public enum AuditEntryKind: String, CaseIterable, Hashable, Sendable {
    /// Changed something: `act`, `browser_act`, `browser_open`, and `browser_extract` in `eval` mode.
    case action
    /// Only read: observe, screenshots (`debug_capture` too), tab lists, extracts, vision queries, status.
    case observation
    /// Neither: tasks starting and ending, policy and pairing changes, approvals, installs, problem reports. A
    /// method UseMac doesn't know lands here too, so a new kind of request is never hidden with the observations.
    case other

    public init(_ entry: AuditEntry) {
        self.init(method: entry.method, summary: entry.summary)
    }

    /// `summary` matters only for `browser_extract`, whose `eval` mode runs a script in the page.
    public init(method: String, summary: String = "") {
        guard let known = RPCMethod(rawValue: method) else {
            self = .other
            return
        }
        switch known {
        case .act, .browserAct, .browserOpen:
            self = .action
        case .browserExtract:
            // `AuditRedactor.evalSummary` starts every eval entry this way; the other modes only read the page.
            self = summary.hasPrefix("Eval (") ? .action : .observation
        case .observe, .screenshot, .listApps, .highlight, .browserStatus, .browserTabs, .browserObserve,
             .browserScreenshot, .visionStatus, .visionQuery, .status, .ping, .auditLog, .debugCapture:
            self = .observation
        case .setPolicy, .pairApp, .visionInstall, .taskStart, .taskComplete, .browserReloadExtension, .reportPrepare:
            self = .other
        }
    }
}

/// Consecutive audit entries that say the same thing, shown as one row with a count and a time range.
public struct AuditEntryRun: Identifiable, Equatable, Sendable {
    /// In the order they were given (newest first in History). Never empty.
    public let entries: [AuditEntry]
    public let kind: AuditEntryKind
    /// The earliest and latest timestamps in the run.
    public let firstTimestampMs: Int64
    public let lastTimestampMs: Int64

    /// The oldest entry's id, so a run keeps its id while newer entries join it at the top of the list.
    public var id: String { entries[entries.count - 1].id }
    /// The entry the row shows: the first one given (the newest in History).
    public var representative: AuditEntry { entries[0] }
    public var count: Int { entries.count }
    public var isFolded: Bool { entries.count > 1 }

    init(entries: [AuditEntry]) {
        precondition(!entries.isEmpty, "a run has at least one entry")
        self.entries = entries
        self.kind = AuditEntryKind(entries[0])
        let timestamps = entries.map(\.timestampMs)
        self.firstTimestampMs = timestamps.min() ?? entries[0].timestampMs
        self.lastTimestampMs = timestamps.max() ?? entries[0].timestampMs
    }
}

/// Folds runs of repeated audit entries for display. An agent polling `browser_tabs` twice a second would
/// otherwise fill History with identical rows. Display only: the log on disk and its export keep every entry.
public enum AuditLogFolding {
    /// Whether two entries say the same thing: same app, method, task, result and summary. Time, latency and id
    /// don't count. A failure never folds with a success.
    public static func sameEvent(_ lhs: AuditEntry, _ rhs: AuditEntry) -> Bool {
        lhs.success == rhs.success
            && lhs.method == rhs.method
            && lhs.taskId == rhs.taskId
            && lhs.targetApp == rhs.targetApp
            && lhs.summary == rhs.summary
    }

    /// Groups neighbouring entries that say the same thing, keeping the order given. Every entry lands in exactly
    /// one run; entries that repeat with something else between them stay apart.
    public static func fold(_ entries: [AuditEntry]) -> [AuditEntryRun] {
        var runs: [AuditEntryRun] = []
        var current: [AuditEntry] = []
        for entry in entries {
            if let last = current.last, !sameEvent(last, entry) {
                runs.append(AuditEntryRun(entries: current))
                current.removeAll(keepingCapacity: true)
            }
            current.append(entry)
        }
        if !current.isEmpty {
            runs.append(AuditEntryRun(entries: current))
        }
        return runs
    }
}
