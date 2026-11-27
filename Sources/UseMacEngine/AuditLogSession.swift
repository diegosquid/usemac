import Foundation
import UseMacProtocol

/// A task or a burst of ad-hoc activity. This is a view of the log, not a change to its stored entries.
public struct AuditSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskId: String?
    public let agentName: String?
    public let title: String
    public let apps: [String]
    public let firstTimestampMs: Int64
    public let lastTimestampMs: Int64
    public let entries: [AuditEntry]
    public let runs: [AuditEntryRun]
    public let actionCount: Int
    public let observationCount: Int
    public let failureCount: Int
    public let isExplicitTask: Bool
    public let isCompleted: Bool

    public var durationMs: Int64 {
        let (duration, overflow) = lastTimestampMs.subtractingReportingOverflow(firstTimestampMs)
        return overflow ? .max : max(0, duration)
    }

    public var totalCount: Int { entries.count }
    public var primaryApp: String? { apps.first }
    public var hasFailures: Bool { failureCount > 0 }

    public var summaryLine: String {
        var parts: [String] = []
        if actionCount > 0 { parts.append("\(actionCount) \(actionCount == 1 ? "action" : "actions")") }
        if observationCount > 0 { parts.append("\(observationCount) \(observationCount == 1 ? "read" : "reads")") }
        if hasFailures { parts.append("\(failureCount) failed") }
        if parts.isEmpty { parts.append("\(totalCount) \(totalCount == 1 ? "event" : "events")") }
        let displayApps = apps.compactMap { AuditRedactor.sanitizeTitle($0) }
        if !displayApps.isEmpty { parts.append(displayApps.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    fileprivate init(entries: [AuditEntry]) {
        self.entries = entries
        let newest = entries[0]
        taskId = newest.taskId
        let timestamps = entries.map(\.timestampMs)
        let earliest = timestamps.min() ?? newest.timestampMs
        firstTimestampMs = earliest
        lastTimestampMs = timestamps.max() ?? newest.timestampMs
        let oldest = entries.last { $0.timestampMs == earliest } ?? newest
        id = newest.taskId.map { "task:\($0)" } ?? "adhoc:\(oldest.id)"
        agentName = entries.lazy.compactMap { $0.agent?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        var seenApps = Set<String>()
        let distinctApps = entries.compactMap { entry -> String? in
            guard let name = entry.targetApp?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  seenApps.insert(name).inserted else { return nil }
            return name
        }
        apps = distinctApps.count > 1 ? distinctApps.filter { $0.lowercased() != "agent" } : distinctApps
        title = AuditLogSessionGrouper.makeTitle(entries: entries, apps: apps)
        runs = AuditLogFolding.fold(entries)
        let kinds = entries.map { AuditEntryKind($0) }
        actionCount = kinds.count { $0 == .action }
        observationCount = kinds.count { $0 == .observation }
        failureCount = entries.count { !$0.success }
        isExplicitTask = taskId != nil
        isCompleted = entries.contains { $0.method == RPCMethod.taskComplete.rawValue }
    }
}

public enum AuditLogSessionGrouper {
    public static let defaultAdHocGapMs: Int64 = 120_000

    private enum AdHocKey: Hashable {
        case agent(String)
        case app(String)

        init(_ entry: AuditEntry) {
            if let agent = entry.agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty {
                self = .agent(agent.lowercased())
            } else {
                self = .app(entry.targetApp?.lowercased() ?? "")
            }
        }
    }

    /// Explicit tasks are grouped by ID across the whole input. Only ad-hoc sessions split at idle gaps.
    public static func group(_ newestFirst: [AuditEntry], adHocGapMs: Int64 = defaultAdHocGapMs) -> [AuditSession] {
        var tasks: [String: Int] = [:]
        var latestAdHoc: [AdHocKey: Int] = [:]
        var groups: [[AuditEntry]] = []

        for entry in newestFirst {
            if let taskId = entry.taskId {
                let index = tasks[taskId, default: groups.count]
                if index == groups.count {
                    tasks[taskId] = index
                    groups.append([entry])
                } else {
                    groups[index].append(entry)
                }
            } else {
                let key = AdHocKey(entry)
                if let index = latestAdHoc[key], let neighbor = groups[index].last,
                   withinGap(neighbor.timestampMs, entry.timestampMs, limit: adHocGapMs) {
                    groups[index].append(entry)
                } else {
                    latestAdHoc[key] = groups.count
                    groups.append([entry])
                }
            }
        }

        return groups.map { AuditSession(entries: $0) }.sorted {
            if $0.lastTimestampMs == $1.lastTimestampMs { return $0.id < $1.id }
            return $0.lastTimestampMs > $1.lastTimestampMs
        }
    }

    private static func withinGap(_ lhs: Int64, _ rhs: Int64, limit: Int64) -> Bool {
        let (gap, overflow) = max(lhs, rhs).subtractingReportingOverflow(min(lhs, rhs))
        return !overflow && gap <= limit
    }

    public static func makeTitle(entries: [AuditEntry], apps: [String]) -> String {
        for method in [RPCMethod.taskStart, .taskComplete] {
            for entry in entries where entry.method == method.rawValue {
                if let title = AuditRedactor.sanitizeTitle(entry.summary) { return title }
            }
        }

        var counts: [TitleVerb: Int] = [:]
        for entry in entries {
            for verb in TitleVerb.verbs(for: entry) {
                counts[verb, default: 0] += 1
            }
        }
        let verbs = TitleVerb.allCases.compactMap { verb in counts[verb].map(verb.label(count:)) }.prefix(2)
        let app = apps.first.flatMap { AuditRedactor.sanitizeTitle($0) }
        guard let first = verbs.first else { return app.map { "Activity in \($0)" } ?? "Agent activity" }
        var title = first
        if let second = verbs.dropFirst().first {
            title += " & " + second.prefix(1).lowercased() + second.dropFirst()
        }
        if let app, app.lowercased() != "agent" { title += " in \(app)" }
        return title
    }

    /// Ordered by relevance, so common clicks or reads don't hide a form submission or an eval.
    private enum TitleVerb: CaseIterable {
        case form, upload, open, type, eval, click, menu, shortcut, scroll, skill, extract, inspect, settings

        func label(count: Int) -> String {
            switch self {
            case .form: return "Filled form"
            case .upload: return "Uploaded files"
            case .open: return count == 1 ? "Opened page" : "Opened pages"
            case .type: return "Entered text"
            case .eval: return count == 1 ? "Ran page script" : "Ran page scripts"
            case .click: return "Clicked"
            case .menu: return "Used app menu"
            case .shortcut: return "Pressed shortcuts"
            case .scroll: return "Scrolled"
            case .skill: return "Ran skill"
            case .extract: return "Extracted data"
            case .inspect: return "Inspected"
            case .settings: return "Settings & safety"
            }
        }

        static func verbs(for entry: AuditEntry) -> [Self] {
            switch RPCMethod(rawValue: entry.method) {
            case .act, .browserAct: return stepVerbs(in: entry.summary)
            case .browserOpen: return [.open]
            case .browserExtract: return entry.summary.hasPrefix("Eval (") ? [.eval] : [.extract]
            case .appMenu: return [.menu]
            case .skillRun: return [.skill]
            case .browserBatch: return [.extract]
            case .observe, .browserObserve, .browserTabs, .screenshot, .browserScreenshot, .visionQuery: return [.inspect]
            case .setPolicy, .pairApp, .browserReloadExtension, .reportPrepare: return [.settings]
            default: return []
            }
        }

        // Action summaries are steps separated by ", " after the optional "Executed ... · " prefix.
        // Skip quoted values, and read only the step name, never its arguments.
        private static let stepPattern = try! NSRegularExpression(
            pattern: #""(?:\\.|[^"\\])*"|(?:^|,\h+| · )([A-Za-z][A-Za-z0-9]*)(?=[\s,]|$)"#
        )

        private static func stepVerbs(in summary: String) -> [Self] {
            let source = summary as NSString
            let matches = stepPattern.matches(in: summary, range: NSRange(location: 0, length: source.length))
            return matches.compactMap { match in
                let name = match.range(at: 1)
                guard name.location != NSNotFound else { return nil }
                switch ActionStepType(rawValue: source.substring(with: name)) {
                case .fillForm: return .form
                case .uploadFile, .saveFile: return .upload
                case .openURL, .navigate: return .open
                case .type, .setValue: return .type
                case .click, .doubleClick, .rightClick, .drag: return .click
                case .menuAction: return .menu
                case .pressKey: return .shortcut
                case .scroll, .scrollUntil: return .scroll
                default: return nil
                }
            }
        }
    }
}
