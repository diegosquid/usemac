import Darwin
import Foundation
import UseMacProtocol

/// What the user sets for the audit log in the app (Settings → History).
public enum AuditLogSettings {
    public static let retentionDaysKey = "usemac.audit.retentionDays"
    public static let recordTypedTextKey = "usemac.audit.recordTypedText"
    public static let defaultRetentionDays = 30
    /// The choices the History view offers.
    public static let retentionChoices = [7, 30, 90, 365]

    /// How many days of audit files to keep (default 30).
    public static var retentionDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: retentionDaysKey)
            return stored > 0 ? min(stored, 3650) : defaultRetentionDays
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: retentionDaysKey)
        }
    }

    private static let recordsTypedTextLock = NSLock()
    nonisolated(unsafe) private static var recordsTypedTextValue = false

    /// Whether audit entries keep typed text and page scripts. Off by default: they keep only the length.
    ///
    /// Kept in memory: the app sets it at launch from the sealed settings and when the user changes it in Settings,
    /// and saves it through SafetySettingsStore. Reading the preferences each time would let a `defaults write` turn
    /// it on behind the user's back.
    public static var recordsTypedText: Bool {
        get {
            recordsTypedTextLock.lock()
            defer { recordsTypedTextLock.unlock() }
            return recordsTypedTextValue
        }
        set {
            recordsTypedTextLock.lock()
            recordsTypedTextValue = newValue
            recordsTypedTextLock.unlock()
        }
    }
}

/// Which entries to read back from the audit log. Results are newest first.
public struct AuditLogQuery: Equatable, Sendable {
    /// At most this many entries; nil reads everything that matches.
    public var limit: Int?
    public var sinceMs: Int64?
    public var taskId: String?
    /// Exact agent name.
    public var agent: String?
    /// Exact `targetApp`.
    public var app: String?
    /// `true` for entries that succeeded, `false` for failures.
    public var success: Bool?
    /// Only entries of these kinds (History's "Observations" switch); nil keeps every kind.
    public var kinds: Set<AuditEntryKind>?

    public init(
        limit: Int? = AuditLogParams.defaultLimit,
        sinceMs: Int64? = nil,
        taskId: String? = nil,
        app: String? = nil,
        success: Bool? = nil,
        kinds: Set<AuditEntryKind>? = nil,
        agent: String? = nil
    ) {
        self.limit = limit
        self.sinceMs = sinceMs
        self.taskId = taskId
        self.app = app
        self.success = success
        self.kinds = kinds
        self.agent = agent
    }

    /// The query an `audit_log` request asks for.
    public init(_ params: AuditLogParams) {
        self.init(limit: params.resolvedLimit, sinceMs: params.sinceMs, taskId: params.resolvedTaskId, agent: params.resolvedAgent)
    }

    public func matches(_ entry: AuditEntry) -> Bool {
        if let sinceMs, entry.timestampMs < sinceMs { return false }
        if let taskId, entry.taskId != taskId { return false }
        if let agent, entry.agent != agent { return false }
        if let app, entry.targetApp != app { return false }
        if let success, entry.success != success { return false }
        if let kinds, !kinds.contains(AuditEntryKind(entry)) { return false }
        return true
    }

    /// Filters entries that are already newest first.
    public func apply(to newestFirst: [AuditEntry]) -> [AuditEntry] {
        let matching = newestFirst.filter(matches)
        guard let limit else { return matching }
        return Array(matching.prefix(max(0, limit)))
    }
}

public enum AuditLogExportFormat: String, CaseIterable, Sendable {
    case jsonl
    case csv

    public var fileExtension: String { rawValue }
}

/// The audit log on disk: one append-only JSONL file per day (`audit-YYYY-MM-DD.jsonl`, local time) in
/// `~/Library/Application Support/UseMac/audit/`. Files older than the retention setting are deleted.
///
/// Writes run on a background queue, so recording an entry never slows a request down. Reads wait for the
/// writes queued before them, so they always include every entry appended so far.
public final class AuditLogStore: @unchecked Sendable {
    /// How many recent entries the engine keeps in memory (and loads back from disk at launch).
    public static let memoryLimit = 500

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(UseMacDefaults.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("audit", isDirectory: true)
    }

    public let directory: URL
    private let retentionDays: @Sendable () -> Int
    private let queue = DispatchQueue(label: "app.usemac.audit-log", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// The day of the last write, so the first write of a new day also prunes old files. Queue-confined.
    private var lastWrittenDay: String?

    public init(
        directory: URL = AuditLogStore.defaultDirectory,
        retentionDays: @escaping @Sendable () -> Int = { AuditLogSettings.retentionDays }
    ) {
        self.directory = directory
        self.retentionDays = retentionDays
        queue.async { [self] in
            pruneOnQueue(now: Date())
        }
    }

    /// Queues the entry for writing and returns at once.
    public func append(_ entry: AuditEntry) {
        queue.async { [self] in
            write(entry)
        }
    }

    /// Waits until every queued write is on disk.
    public func flush() {
        queue.sync {}
    }

    /// Entries matching the query, newest first.
    public func entries(matching query: AuditLogQuery) -> [AuditEntry] {
        queue.sync { readOnQueue(query) }
    }

    /// The most recent entries, oldest first (the order the engine keeps them in memory).
    public func recentEntries(limit: Int = AuditLogStore.memoryLimit) -> [AuditEntry] {
        Array(entries(matching: AuditLogQuery(limit: limit)).reversed())
    }

    /// Deletes the day files older than the retention setting.
    public func prune(now: Date = Date()) {
        queue.sync { pruneOnQueue(now: now) }
    }

    /// The day files on disk, newest first.
    public func dayFiles() -> [URL] {
        queue.sync { dayFilesOnQueue().map(\.url) }
    }

    public func fileURL(forDay day: String) -> URL {
        directory.appendingPathComponent("audit-\(day).jsonl", isDirectory: false)
    }

    /// The file an entry with this timestamp goes to.
    public func fileURL(forTimestampMs timestampMs: Int64) -> URL {
        fileURL(forDay: Self.dayString(forTimestampMs: timestampMs))
    }

    // MARK: - Export

    /// Entries in the export format, oldest first. CSV cells that a spreadsheet would run as a formula are
    /// prefixed with an apostrophe.
    public static func export(_ newestFirst: [AuditEntry], as format: AuditLogExportFormat) -> Data {
        let chronological = newestFirst.reversed()
        switch format {
        case .jsonl:
            let encoder = JSONEncoder()
            var data = Data()
            for entry in chronological {
                guard let line = try? encoder.encode(entry) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            return data
        case .csv:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = .current
            var lines = ["time,timestampMs,taskId,agent,method,app,result,latencyMs,summary,id"]
            for entry in chronological {
                let time = formatter.string(from: Date(timeIntervalSince1970: Double(entry.timestampMs) / 1000))
                let cells = [
                    time,
                    String(entry.timestampMs),
                    entry.taskId ?? "",
                    entry.agent ?? "",
                    entry.method,
                    entry.targetApp ?? "",
                    entry.success ? "ok" : "failed",
                    String(format: "%.2f", entry.latencyMs),
                    entry.summary,
                    entry.id
                ]
                lines.append(cells.map(csvCell).joined(separator: ","))
            }
            return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        }
    }

    static func csvCell(_ raw: String) -> String {
        var value = raw
        if let first = value.first, "=+-@\t\r".contains(first) {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Days

    static func dayString(forTimestampMs timestampMs: Int64) -> String {
        dayString(for: Date(timeIntervalSince1970: Double(timestampMs) / 1000))
    }

    static func dayString(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// `audit-2026-11-25.jsonl` → `2026-11-25`; nil for any other file name.
    static func day(fromFileName name: String) -> String? {
        guard name.hasPrefix("audit-"), name.hasSuffix(".jsonl") else { return nil }
        let day = String(name.dropFirst("audit-".count).dropLast(".jsonl".count))
        let isDay = day.count == 10 && day.enumerated().allSatisfy { index, char in
            (index == 4 || index == 7) ? char == "-" : char.isASCII && char.isNumber
        }
        return isDay ? day : nil
    }

    // MARK: - Queue-confined

    private func write(_ entry: AuditEntry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let day = Self.dayString(forTimestampMs: entry.timestampMs)
        if lastWrittenDay != day {
            lastWrittenDay = day
            pruneOnQueue(now: Date())
        }
        let path = fileURL(forDay: day).path
        var fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0, errno == ENOENT {
            createDirectory()
            fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        // One write per line: with O_APPEND, lines from another UseMac process never interleave.
        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    private func createDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func dayFilesOnQueue() -> [(day: String, url: URL)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .compactMap { name in Self.day(fromFileName: name).map { ($0, directory.appendingPathComponent(name)) } }
            .sorted { $0.day > $1.day }
    }

    private func readOnQueue(_ query: AuditLogQuery) -> [AuditEntry] {
        if let limit = query.limit, limit <= 0 { return [] }
        let sinceDay = query.sinceMs.map(Self.dayString(forTimestampMs:))
        var result: [AuditEntry] = []
        for file in dayFilesOnQueue() {
            if let sinceDay, file.day < sinceDay { continue }
            guard let data = try? Data(contentsOf: file.url) else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                // A line cut short (the disk filled up, the process died mid-write) is skipped, not fatal.
                guard let entry = try? decoder.decode(AuditEntry.self, from: Data(line)), query.matches(entry) else { continue }
                result.append(entry)
                if let limit = query.limit, result.count >= limit { return result }
            }
        }
        return result
    }

    private func pruneOnQueue(now: Date) {
        let days = max(1, retentionDays())
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let cutoffDay = Self.dayString(for: cutoff)
        for file in dayFilesOnQueue() where file.day < cutoffDay {
            try? FileManager.default.removeItem(at: file.url)
        }
    }
}

extension UseMacEngineService {
    /// `audit_log`: newest first. Without parameters it returns the 50 most recent entries from memory, as before
    /// (loaded back from disk at launch); with them it reads the persisted log.
    public func auditLog(_ params: AuditLogParams?) -> [AuditEntry] {
        guard let params else {
            return recentAuditEntries(limit: AuditLogParams.defaultLimit)
        }
        let query = AuditLogQuery(params)
        if let auditStore {
            return auditStore.entries(matching: query)
        }
        return query.apply(to: recentAuditEntries(limit: AuditLogStore.memoryLimit))
    }
}
