import Foundation

/// Optional filters for `audit_log`. Without them it returns the 50 most recent entries, newest first.
public struct AuditLogParams: Codable, Equatable, Sendable {
    /// How many entries to return, newest first. Default 50, at most 1000.
    public var limit: Int?
    /// Only entries at or after this time, in milliseconds since 1970 (like `timestampMs`).
    public var sinceMs: Int64?
    /// Only entries of this task (the `taskId` from `task_start`).
    public var taskId: String?
    /// Only entries from this agent (exact name).
    public var agent: String?

    public static let defaultLimit = 50
    public static let maxLimit = 1000

    public init(limit: Int? = nil, sinceMs: Int64? = nil, taskId: String? = nil, agent: String? = nil) {
        self.limit = limit
        self.sinceMs = sinceMs
        self.taskId = taskId
        self.agent = agent
    }

    /// The limit to apply: the default when omitted, clamped to 1...maxLimit.
    public var resolvedLimit: Int {
        min(max(limit ?? Self.defaultLimit, 1), Self.maxLimit)
    }

    /// The task filter, or nil when it is missing or blank.
    public var resolvedTaskId: String? {
        guard let trimmed = taskId?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The agent filter, or nil when it is missing or blank.
    public var resolvedAgent: String? {
        guard let trimmed = agent?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Reads a `since` value as milliseconds since 1970: a duration back from now (`90s`, `30m`, `2h`, `7d`),
    /// a local date (`2026-11-25`), an ISO 8601 date and time, or a number of milliseconds. Nil when unreadable.
    public static func parseSince(_ raw: String, now: Date = Date()) -> Int64? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.allSatisfy(\.isNumber) {
            return Int64(text)
        }
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604_800]
        if let unit = text.last, let seconds = units[unit], let amount = Double(text.dropLast()), amount >= 0 {
            return Int64((now.timeIntervalSince1970 - amount * seconds) * 1000)
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let iso = ISO8601DateFormatter()
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: original) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}
