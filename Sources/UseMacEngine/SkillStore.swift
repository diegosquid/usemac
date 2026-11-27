import Foundation
import UseMacProtocol

public enum SkillStoreError: Error, LocalizedError, Equatable {
    case invalidName
    case emptySteps
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Skill name must not be empty."
        case .emptySteps:
            return "Skill must contain at least one action step."
        case .notFound(let name):
            return "No saved skill named \"\(name)\"."
        }
    }
}

/// Thread-safe JSON-backed repository for reusable, parameterized automation skills.
public final class SkillStore: @unchecked Sendable {
    public static var defaultStorageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(UseMacDefaults.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("skills.json")
    }

    public let storageURL: URL
    private let lock = NSLock()
    private var records: [String: SkillRecord] = [:]

    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)

    public init(storageURL: URL = SkillStore.defaultStorageURL) {
        self.storageURL = storageURL
        self.records = Self.loadFromDisk(url: storageURL)
    }

    // MARK: - CRUD

    @discardableResult
    public func save(
        _ params: SkillSaveParams,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> SkillRecord {
        let cleanName = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw SkillStoreError.invalidName
        }
        guard !params.steps.isEmpty else {
            throw SkillStoreError.emptySteps
        }

        let declaredParams: [String]? = {
            if let explicit = params.params {
                return explicit
            }
            let extracted = Self.extractParamNames(from: params.steps)
            return extracted.isEmpty ? nil : extracted
        }()

        lock.lock()
        defer { lock.unlock() }

        let existing = records[cleanName]
        let record = SkillRecord(
            name: cleanName,
            description: params.description,
            target: params.target,
            app: params.app,
            urlPattern: params.urlPattern,
            params: declaredParams,
            steps: params.steps,
            createdAtMs: existing?.createdAtMs ?? nowMs,
            updatedAtMs: nowMs,
            runCount: existing?.runCount ?? 0,
            lastSuccessAtMs: existing?.lastSuccessAtMs
        )
        var candidate = records
        candidate[cleanName] = record
        try persistLocked(candidate)
        records = candidate
        return record
    }

    @discardableResult
    public func save(_ record: SkillRecord) throws -> SkillRecord {
        let cleanName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw SkillStoreError.invalidName
        }
        guard !record.steps.isEmpty else {
            throw SkillStoreError.emptySteps
        }
        var normalized = record
        normalized.name = cleanName

        lock.lock()
        defer { lock.unlock() }
        var candidate = records
        candidate[cleanName] = normalized
        try persistLocked(candidate)
        records = candidate
        return normalized
    }

    public func get(name: String) -> SkillRecord? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return records[cleanName]
    }

    @discardableResult
    public func delete(name: String) throws -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        var candidate = records
        guard candidate.removeValue(forKey: cleanName) != nil else {
            return false
        }
        try persistLocked(candidate)
        records = candidate
        return true
    }

    public func list(filter: SkillListParams? = nil) -> [SkillRecord] {
        lock.lock()
        let all = Array(records.values)
        lock.unlock()

        let filtered = all.filter { record in
            if let target = filter?.target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
                guard let recTarget = record.target, recTarget.caseInsensitiveCompare(target) == .orderedSame else {
                    return false
                }
            }
            if let app = filter?.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
                guard let recApp = record.app, recApp.localizedCaseInsensitiveContains(app) else {
                    return false
                }
            }
            if let url = filter?.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                guard let pattern = record.urlPattern, !pattern.isEmpty, Self.url(url, matchesPattern: pattern) else {
                    return false
                }
            }
            if let query = filter?.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                let haystacks = [record.name, record.description ?? "", record.app ?? "", record.urlPattern ?? ""]
                guard haystacks.contains(where: { $0.localizedCaseInsensitiveContains(query) }) else {
                    return false
                }
            }
            return true
        }

        return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func recordRun(
        name: String,
        success: Bool,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> SkillRecord? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var existing = records[cleanName] else { return nil }
        existing.runCount += 1
        existing.updatedAtMs = nowMs
        if success {
            existing.lastSuccessAtMs = nowMs
        }
        var candidate = records
        candidate[cleanName] = existing
        try? persistLocked(candidate)
        records = candidate
        return existing
    }

    public func reload() {
        let loaded = Self.loadFromDisk(url: storageURL)
        lock.lock()
        records = loaded
        lock.unlock()
    }

    // MARK: - Interpolation

    /// Replaces `{{param}}` placeholders in `steps` across `text`, `url`, `match.{title,text,value}`,
    /// `fields.{value,label}`, `expectText`, `expectNotText`, `expectUrl`, `expectTitle`, `menuPath`, and `files`.
    public static func interpolate(steps: [ActionStep], with params: [String: String]) -> [ActionStep] {
        guard !params.isEmpty else { return steps }
        return steps.map { step in
            var copy = step
            copy.text = interpolateString(copy.text, with: params)
            copy.url = interpolateString(copy.url, with: params)
            if var match = copy.match {
                match.title = interpolateString(match.title, with: params)
                match.text = interpolateString(match.text, with: params)
                match.value = interpolateString(match.value, with: params)
                copy.match = match
            }
            copy.selector = interpolateString(copy.selector, with: params)
            copy.toSelector = interpolateString(copy.toSelector, with: params)
            if var toMatch = copy.toMatch {
                toMatch.title = interpolateString(toMatch.title, with: params)
                toMatch.text = interpolateString(toMatch.text, with: params)
                toMatch.value = interpolateString(toMatch.value, with: params)
                copy.toMatch = toMatch
            }
            if var submitMatch = copy.submitMatch {
                submitMatch.title = interpolateString(submitMatch.title, with: params)
                submitMatch.text = interpolateString(submitMatch.text, with: params)
                submitMatch.value = interpolateString(submitMatch.value, with: params)
                copy.submitMatch = submitMatch
            }
            if let fields = copy.fields {
                copy.fields = fields.map { field in
                    var f = field
                    f.value = interpolateString(f.value, with: params)
                    f.label = interpolateString(f.label, with: params)
                    if var fm = f.match {
                        fm.title = interpolateString(fm.title, with: params)
                        fm.text = interpolateString(fm.text, with: params)
                        fm.value = interpolateString(fm.value, with: params)
                        f.match = fm
                    }
                    return f
                }
            }
            copy.expectText = interpolateString(copy.expectText, with: params)
            copy.expectNotText = interpolateString(copy.expectNotText, with: params)
            copy.expectUrl = interpolateString(copy.expectUrl, with: params)
            copy.expectTitle = interpolateString(copy.expectTitle, with: params)
            if let menuPath = copy.menuPath {
                copy.menuPath = menuPath.map { interpolateString($0, with: params) ?? $0 }
            }
            if let files = copy.files {
                copy.files = files.map { interpolateString($0, with: params) ?? $0 }
            }
            return copy
        }
    }

    /// Extracts unique `{{param}}` placeholder names referenced across `steps`, preserving order of first appearance.
    public static func extractParamNames(from steps: [ActionStep]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        func scan(_ text: String?) {
            guard let text, text.contains("{{") else { return }
            let ns = text as NSString
            let matches = placeholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, seen.insert(raw).inserted else { continue }
                ordered.append(raw)
            }
        }

        for step in steps {
            scan(step.text)
            scan(step.url)
            scan(step.match?.title)
            scan(step.match?.text)
            scan(step.match?.value)
            scan(step.submitMatch?.title)
            scan(step.submitMatch?.text)
            scan(step.submitMatch?.value)
            for field in step.fields ?? [] {
                scan(field.value)
                scan(field.label)
                scan(field.match?.title)
                scan(field.match?.text)
                scan(field.match?.value)
            }
            scan(step.expectText)
            scan(step.expectNotText)
            scan(step.expectUrl)
            scan(step.expectTitle)
            for item in step.menuPath ?? [] { scan(item) }
            for file in step.files ?? [] { scan(file) }
            scan(step.selector)
            scan(step.toSelector)
            scan(step.toMatch?.title)
            scan(step.toMatch?.text)
            scan(step.toMatch?.value)
        }
        return ordered
    }

    private static func interpolateString(_ value: String?, with params: [String: String]) -> String? {
        guard let value, value.contains("{{") else { return value }
        let ns = value as NSString
        let matches = placeholderRegex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }

        var result = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range
            if fullRange.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let key = ns.substring(with: match.range(at: 1))
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if let replacement = params[key] ?? params[trimmedKey] {
                result += replacement
            } else {
                result += ns.substring(with: fullRange)
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    // MARK: - Persistence & Matching

    private static func url(_ url: String, matchesPattern pattern: String) -> Bool {
        if pattern.contains("*") {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
            if let regex = try? NSRegularExpression(pattern: escaped, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (url as NSString).length)
                return regex.firstMatch(in: url, range: range) != nil
            }
        }
        return url.localizedCaseInsensitiveContains(pattern)
    }

    private static func loadFromDisk(url: URL) -> [String: SkillRecord] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SkillRecord].self, from: data) else {
            return [:]
        }
        var map: [String: SkillRecord] = [:]
        for record in decoded {
            let key = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                map[key] = record
            }
        }
        return map
    }

    private func persistLocked(_ snapshot: [String: SkillRecord]) throws {
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sorted = snapshot.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        try data.write(to: storageURL, options: .atomic)
    }
}
