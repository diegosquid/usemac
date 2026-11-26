import Foundation

public enum RPCMethod: String, Codable, Sendable {
    case ping
    case status
    case listApps = "list_apps"
    case observe
    case act
    case screenshot
    case setPolicy = "set_policy"
    case pairApp = "pair_app"
    case auditLog = "audit_log"
    case highlight
    case browserStatus = "browser_status"
    case browserTabs = "browser_tabs"
    case browserOpen = "browser_open"
    case browserObserve = "browser_observe"
    case browserExtract = "browser_extract"
    case browserScreenshot = "browser_screenshot"
    case browserAct = "browser_act"
    case visionStatus = "vision_status"
    case visionInstall = "vision_install"
    case visionQuery = "vision_query"
    case taskStart = "task_start"
    case taskComplete = "task_complete"
}

public struct ObserveParams: Codable, Equatable, Sendable {
    public var app: String?
    public var maxDepth: Int?
    public var maxElements: Int?
    public var useCache: Bool?
    public var includeDiff: Bool?
    public var includeScreenshot: Bool?
    /// Include elements scrolled out of view, flagged `offscreen`. Default true.
    public var includeOffscreen: Bool?
    /// Observe the app window whose title contains this text instead of the focused one (e.g. a Chrome
    /// window UseMac opened in the background). Later acts without `window` keep using it. Omit to observe
    /// the focused window again.
    public var window: String?

    public init(
        app: String? = nil,
        maxDepth: Int? = nil,
        maxElements: Int? = nil,
        useCache: Bool? = true,
        includeDiff: Bool? = true,
        includeScreenshot: Bool? = false,
        includeOffscreen: Bool? = nil,
        window: String? = nil
    ) {
        self.app = app
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.useCache = useCache
        self.includeDiff = includeDiff
        self.includeScreenshot = includeScreenshot
        self.includeOffscreen = includeOffscreen
        self.window = window
    }
}

public struct RPCRequest: Codable, Sendable {
    public var id: String
    public var method: RPCMethod
    public var observe: ObserveParams?
    public var act: BatchActionRequest?
    public var screenshot: ScreenshotRequest?
    public var policy: GovernancePolicy?
    public var appTarget: String?
    public var elementId: String?
    public var durationMs: Int?
    public var browserTabs: BrowserTabsParams?
    public var browserOpen: BrowserOpenParams?
    public var browserObserve: BrowserObserveParams?
    public var browserExtract: BrowserExtractParams?
    public var browserScreenshot: BrowserScreenshotParams?
    public var browserAct: BrowserActParams?
    public var visionInstall: VisionInstallParams?
    public var visionQuery: VisionQueryParams?
    public var taskStart: TaskStartParams?
    public var taskComplete: TaskCompleteParams?
    /// The task this request belongs to (from `task_start`). Any method takes it; see `namedTaskId`.
    public var taskId: String?

    public init(
        id: String = UUID().uuidString,
        method: RPCMethod,
        observe: ObserveParams? = nil,
        act: BatchActionRequest? = nil,
        screenshot: ScreenshotRequest? = nil,
        policy: GovernancePolicy? = nil,
        appTarget: String? = nil,
        elementId: String? = nil,
        durationMs: Int? = nil,
        browserTabs: BrowserTabsParams? = nil,
        browserOpen: BrowserOpenParams? = nil,
        browserObserve: BrowserObserveParams? = nil,
        browserExtract: BrowserExtractParams? = nil,
        browserScreenshot: BrowserScreenshotParams? = nil,
        browserAct: BrowserActParams? = nil,
        visionInstall: VisionInstallParams? = nil,
        visionQuery: VisionQueryParams? = nil,
        taskStart: TaskStartParams? = nil,
        taskComplete: TaskCompleteParams? = nil,
        taskId: String? = nil
    ) {
        self.id = id
        self.method = method
        self.observe = observe
        self.act = act
        self.screenshot = screenshot
        self.policy = policy
        self.appTarget = appTarget
        self.elementId = elementId
        self.durationMs = durationMs
        self.browserTabs = browserTabs
        self.browserOpen = browserOpen
        self.browserObserve = browserObserve
        self.browserExtract = browserExtract
        self.browserScreenshot = browserScreenshot
        self.browserAct = browserAct
        self.visionInstall = visionInstall
        self.visionQuery = visionQuery
        self.taskStart = taskStart
        self.taskComplete = taskComplete
        self.taskId = taskId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.method = try c.decode(RPCMethod.self, forKey: .method)
        self.observe = try c.decodeIfPresent(ObserveParams.self, forKey: .observe)
        self.act = try c.decodeIfPresent(BatchActionRequest.self, forKey: .act)
        self.screenshot = try c.decodeIfPresent(ScreenshotRequest.self, forKey: .screenshot)
        self.policy = try c.decodeIfPresent(GovernancePolicy.self, forKey: .policy)
        self.appTarget = try c.decodeIfPresent(String.self, forKey: .appTarget)
        self.elementId = try c.decodeIfPresent(String.self, forKey: .elementId)
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        self.browserTabs = try c.decodeIfPresent(BrowserTabsParams.self, forKey: .browserTabs)
        self.browserOpen = try c.decodeIfPresent(BrowserOpenParams.self, forKey: .browserOpen)
        self.browserObserve = try c.decodeIfPresent(BrowserObserveParams.self, forKey: .browserObserve)
        self.browserExtract = try c.decodeIfPresent(BrowserExtractParams.self, forKey: .browserExtract)
        self.browserScreenshot = try c.decodeIfPresent(BrowserScreenshotParams.self, forKey: .browserScreenshot)
        self.browserAct = try c.decodeIfPresent(BrowserActParams.self, forKey: .browserAct)
        self.visionInstall = try c.decodeIfPresent(VisionInstallParams.self, forKey: .visionInstall)
        self.visionQuery = try c.decodeIfPresent(VisionQueryParams.self, forKey: .visionQuery)
        self.taskStart = try c.decodeIfPresent(TaskStartParams.self, forKey: .taskStart)
        self.taskComplete = try c.decodeIfPresent(TaskCompleteParams.self, forKey: .taskComplete)
        self.taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
    }
}

public struct RPCErrorPayload: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var serverLatencyMs: Double
    public var pong: String?
    public var status: DaemonStatus?
    public var apps: [AppDescriptor]?
    public var snapshot: WindowSnapshot?
    public var actionResult: BatchActionResult?
    public var screenshot: ScreenshotResult?
    public var auditEntries: [AuditEntry]?
    public var browserProfiles: [BrowserProfileStatus]?
    public var browserTabs: [BrowserTabInfo]?
    public var browserExtract: BrowserExtractResult?
    public var browserTabId: Int?
    public var browserUrl: String?
    public var browserTitle: String?
    public var visionStatus: VisionStatus?
    public var visionResult: VisionQueryResult?
    /// The task a `task_start` opened. Pass it to `browser_open` and `task_complete` so finishing this task only
    /// closes this task's tabs.
    public var taskId: String?
    /// What the task did, on `task_complete`.
    public var taskSummary: TaskSummary?
    public var error: RPCErrorPayload?

    public init(
        id: String,
        ok: Bool,
        serverLatencyMs: Double,
        pong: String? = nil,
        status: DaemonStatus? = nil,
        apps: [AppDescriptor]? = nil,
        snapshot: WindowSnapshot? = nil,
        actionResult: BatchActionResult? = nil,
        screenshot: ScreenshotResult? = nil,
        auditEntries: [AuditEntry]? = nil,
        browserProfiles: [BrowserProfileStatus]? = nil,
        browserTabs: [BrowserTabInfo]? = nil,
        browserExtract: BrowserExtractResult? = nil,
        browserTabId: Int? = nil,
        browserUrl: String? = nil,
        browserTitle: String? = nil,
        visionStatus: VisionStatus? = nil,
        visionResult: VisionQueryResult? = nil,
        taskId: String? = nil,
        taskSummary: TaskSummary? = nil,
        error: RPCErrorPayload? = nil
    ) {
        self.id = id
        self.ok = ok
        self.serverLatencyMs = serverLatencyMs
        self.pong = pong
        self.status = status
        self.apps = apps
        self.snapshot = snapshot
        self.actionResult = actionResult
        self.screenshot = screenshot
        self.auditEntries = auditEntries
        self.browserProfiles = browserProfiles
        self.browserTabs = browserTabs
        self.browserExtract = browserExtract
        self.browserTabId = browserTabId
        self.browserUrl = browserUrl
        self.browserTitle = browserTitle
        self.visionStatus = visionStatus
        self.visionResult = visionResult
        self.taskId = taskId
        self.taskSummary = taskSummary
        self.error = error
    }

    public static func success(
        id: String,
        latencyMs: Double,
        pong: String? = nil,
        status: DaemonStatus? = nil,
        apps: [AppDescriptor]? = nil,
        snapshot: WindowSnapshot? = nil,
        actionResult: BatchActionResult? = nil,
        screenshot: ScreenshotResult? = nil,
        auditEntries: [AuditEntry]? = nil,
        browserProfiles: [BrowserProfileStatus]? = nil,
        browserTabs: [BrowserTabInfo]? = nil,
        browserExtract: BrowserExtractResult? = nil,
        browserTabId: Int? = nil,
        browserUrl: String? = nil,
        browserTitle: String? = nil,
        visionStatus: VisionStatus? = nil,
        visionResult: VisionQueryResult? = nil,
        taskId: String? = nil,
        taskSummary: TaskSummary? = nil
    ) -> RPCResponse {
        RPCResponse(
            id: id,
            ok: true,
            serverLatencyMs: latencyMs,
            pong: pong,
            status: status,
            apps: apps,
            snapshot: snapshot,
            actionResult: actionResult,
            screenshot: screenshot,
            auditEntries: auditEntries,
            browserProfiles: browserProfiles,
            browserTabs: browserTabs,
            browserExtract: browserExtract,
            browserTabId: browserTabId,
            browserUrl: browserUrl,
            browserTitle: browserTitle,
            visionStatus: visionStatus,
            visionResult: visionResult,
            taskId: taskId,
            taskSummary: taskSummary,
            error: nil
        )
    }

    public static func failure(
        id: String,
        code: String,
        message: String,
        latencyMs: Double = 0
    ) -> RPCResponse {
        RPCResponse(
            id: id,
            ok: false,
            serverLatencyMs: latencyMs,
            error: RPCErrorPayload(code: code, message: message)
        )
    }
}

public protocol UseMacServiceProtocol: AnyObject, Sendable {
    func handle(_ request: RPCRequest) async -> RPCResponse
}
