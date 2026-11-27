import Foundation

/// A reusable, parameterized automation macro persisted by `SkillStore`.
public struct SkillRecord: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var description: String?
    /// `"browser"` or `"native"` (optional; inferred from `app`/`urlPattern` when omitted).
    public var target: String?
    public var app: String?
    public var urlPattern: String?
    /// Declared `{{param}}` parameter names used by `steps`.
    public var params: [String]?
    public var steps: [ActionStep]
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var runCount: Int
    public var lastSuccessAtMs: Int64?

    public var id: String { name }

    public init(
        name: String,
        description: String? = nil,
        target: String? = nil,
        app: String? = nil,
        urlPattern: String? = nil,
        params: [String]? = nil,
        steps: [ActionStep],
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        updatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        runCount: Int = 0,
        lastSuccessAtMs: Int64? = nil
    ) {
        self.name = name
        self.description = description
        self.target = target
        self.app = app
        self.urlPattern = urlPattern
        self.params = params
        self.steps = steps
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.runCount = runCount
        self.lastSuccessAtMs = lastSuccessAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.target = try c.decodeIfPresent(String.self, forKey: .target)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.urlPattern = try c.decodeIfPresent(String.self, forKey: .urlPattern)
        self.params = try c.decodeIfPresent([String].self, forKey: .params)
        self.steps = try c.decode([ActionStep].self, forKey: .steps)
        self.createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? nowMs
        self.updatedAtMs = try c.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? self.createdAtMs
        self.runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        self.lastSuccessAtMs = try c.decodeIfPresent(Int64.self, forKey: .lastSuccessAtMs)
    }
}

public struct SkillSaveParams: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var target: String?
    public var app: String?
    public var urlPattern: String?
    public var params: [String]?
    public var steps: [ActionStep]
    /// When true, removes the named skill instead of saving it.
    public var delete: Bool?

    public init(
        name: String,
        description: String? = nil,
        target: String? = nil,
        app: String? = nil,
        urlPattern: String? = nil,
        params: [String]? = nil,
        steps: [ActionStep] = [],
        delete: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.target = target
        self.app = app
        self.urlPattern = urlPattern
        self.params = params
        self.steps = steps
        self.delete = delete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.target = try c.decodeIfPresent(String.self, forKey: .target)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.urlPattern = try c.decodeIfPresent(String.self, forKey: .urlPattern)
        self.params = try c.decodeIfPresent([String].self, forKey: .params)
        self.steps = try c.decodeIfPresent([ActionStep].self, forKey: .steps) ?? []
        self.delete = try c.decodeIfPresent(Bool.self, forKey: .delete)
    }
}

public struct SkillRunParams: Codable, Equatable, Sendable {
    public var name: String
    public var params: [String: String]?
    public var app: String?
    public var profile: String?
    public var tabId: Int?
    public var stopOnError: Bool?
    public var returnObservation: Bool?
    public var returnDiffOnly: Bool?
    public var observationMode: ObservationMode?
    public var waitForLeaseMs: Int?

    public init(
        name: String,
        params: [String: String]? = nil,
        app: String? = nil,
        profile: String? = nil,
        tabId: Int? = nil,
        stopOnError: Bool? = nil,
        returnObservation: Bool? = nil,
        returnDiffOnly: Bool? = nil,
        observationMode: ObservationMode? = nil,
        waitForLeaseMs: Int? = nil
    ) {
        self.name = name
        self.params = params
        self.app = app
        self.profile = profile
        self.tabId = tabId
        self.stopOnError = stopOnError
        self.returnObservation = returnObservation
        self.returnDiffOnly = returnDiffOnly
        self.observationMode = observationMode
        self.waitForLeaseMs = waitForLeaseMs
    }
}

public struct SkillListParams: Codable, Equatable, Sendable {
    public var query: String?
    public var target: String?
    public var app: String?
    public var url: String?

    public init(
        query: String? = nil,
        target: String? = nil,
        app: String? = nil,
        url: String? = nil
    ) {
        self.query = query
        self.target = target
        self.app = app
        self.url = url
    }
}

public struct SkillRunResult: Codable, Equatable, Sendable {
    public var name: String
    public var success: Bool
    public var actionResult: BatchActionResult?
    public var totalLatencyMs: Double
    public var message: String?
    public var skill: SkillRecord?

    public init(
        name: String,
        success: Bool,
        actionResult: BatchActionResult? = nil,
        totalLatencyMs: Double = 0,
        message: String? = nil,
        skill: SkillRecord? = nil
    ) {
        self.name = name
        self.success = success
        self.actionResult = actionResult
        self.totalLatencyMs = totalLatencyMs
        self.message = message
        self.skill = skill
    }
}

public struct SkillListResult: Codable, Equatable, Sendable {
    public var skills: [SkillRecord]
    public var saved: SkillRecord?

    public init(
        skills: [SkillRecord] = [],
        saved: SkillRecord? = nil
    ) {
        self.skills = skills
        self.saved = saved
    }
}
