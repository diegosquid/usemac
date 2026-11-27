import Foundation

public enum RPCMethod: String, Codable, Sendable, CaseIterable {
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
    case browserBatch = "browser_batch"
    case visionStatus = "vision_status"
    case visionQuery = "vision_query"
    case appMenu = "app_menu"
    case skillSave = "skill_save"
    case skillRun = "skill_run"
    case skillList = "skill_list"
    case taskStart = "task_start"
    case taskComplete = "task_complete"
    case browserReloadExtension = "browser_reload_extension"
    case reportPrepare = "report_prepare"
    case debugCapture = "debug_capture"
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
    /// Optional server-side filter to keep only matching elements.
    public var filter: ElementFilter?
    /// When `includeScreenshot` is true, return the image inline in MCP responses.
    public var returnImageContent: Bool?

    public init(
        app: String? = nil,
        maxDepth: Int? = nil,
        maxElements: Int? = nil,
        useCache: Bool? = true,
        includeDiff: Bool? = true,
        includeScreenshot: Bool? = false,
        includeOffscreen: Bool? = nil,
        window: String? = nil,
        filter: ElementFilter? = nil,
        returnImageContent: Bool? = nil
    ) {
        self.app = app
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.useCache = useCache
        self.includeDiff = includeDiff
        self.includeScreenshot = includeScreenshot
        self.includeOffscreen = includeOffscreen
        self.window = window
        self.filter = filter
        self.returnImageContent = returnImageContent
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
    public var browserBatch: BrowserBatchParams?
    public var visionQuery: VisionQueryParams?
    public var appMenu: AppMenuParams?
    public var skillSave: SkillSaveParams?
    public var skillRun: SkillRunParams?
    public var skillList: SkillListParams?
    /// Piggybacked or standalone task lifecycle start (accepted on any request).
    public var taskStart: TaskStartParams?
    /// Piggybacked or standalone task lifecycle completion (accepted on any request).
    public var taskComplete: TaskCompleteParams?
    public var auditLog: AuditLogParams?
    /// The task this request belongs to (from `task_start`). Any method takes it; see `namedTaskId`.
    public var taskId: String?
    public var browserReloadExtension: BrowserReloadExtensionParams?
    public var reportPrepare: ReportPrepareParams?
    public var debugCapture: DebugCaptureParams?
    /// The caller's agent or client name, independent of whether a task is open.
    public var agent: String?
    /// Optional time (0...30_000 ms, default 0) to wait for another task's window/tab lease to release before returning `TARGET_BUSY`.
    public var waitForLeaseMs: Int?

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
        browserBatch: BrowserBatchParams? = nil,
        visionQuery: VisionQueryParams? = nil,
        appMenu: AppMenuParams? = nil,
        skillSave: SkillSaveParams? = nil,
        skillRun: SkillRunParams? = nil,
        skillList: SkillListParams? = nil,
        taskStart: TaskStartParams? = nil,
        taskComplete: TaskCompleteParams? = nil,
        auditLog: AuditLogParams? = nil,
        taskId: String? = nil,
        browserReloadExtension: BrowserReloadExtensionParams? = nil,
        reportPrepare: ReportPrepareParams? = nil,
        debugCapture: DebugCaptureParams? = nil,
        agent: String? = nil,
        waitForLeaseMs: Int? = nil
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
        self.browserBatch = browserBatch
        self.visionQuery = visionQuery
        self.appMenu = appMenu
        self.skillSave = skillSave
        self.skillRun = skillRun
        self.skillList = skillList
        self.taskStart = taskStart
        self.taskComplete = taskComplete
        self.auditLog = auditLog
        self.taskId = taskId
        self.browserReloadExtension = browserReloadExtension
        self.reportPrepare = reportPrepare
        self.debugCapture = debugCapture
        self.agent = agent
        self.waitForLeaseMs = waitForLeaseMs
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
        self.browserBatch = try c.decodeIfPresent(BrowserBatchParams.self, forKey: .browserBatch)
        self.visionQuery = try c.decodeIfPresent(VisionQueryParams.self, forKey: .visionQuery)
        self.appMenu = try c.decodeIfPresent(AppMenuParams.self, forKey: .appMenu)
        self.skillSave = try c.decodeIfPresent(SkillSaveParams.self, forKey: .skillSave)
        self.skillRun = try c.decodeIfPresent(SkillRunParams.self, forKey: .skillRun)
        self.skillList = try c.decodeIfPresent(SkillListParams.self, forKey: .skillList)
        self.taskStart = try c.decodeIfPresent(TaskStartParams.self, forKey: .taskStart)
        self.taskComplete = try c.decodeIfPresent(TaskCompleteParams.self, forKey: .taskComplete)
        self.auditLog = try c.decodeIfPresent(AuditLogParams.self, forKey: .auditLog)
        self.taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        self.browserReloadExtension = try c.decodeIfPresent(BrowserReloadExtensionParams.self, forKey: .browserReloadExtension)
        self.reportPrepare = try c.decodeIfPresent(ReportPrepareParams.self, forKey: .reportPrepare)
        self.debugCapture = try c.decodeIfPresent(DebugCaptureParams.self, forKey: .debugCapture)
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent)
        self.waitForLeaseMs = try c.decodeIfPresent(Int.self, forKey: .waitForLeaseMs)
    }

    public static let maxWaitForLeaseMs = 30_000

    /// Clamped lease wait budget (0...30_000 ms) from the top-level envelope or method payload.
    public var effectiveWaitForLeaseMs: Int {
        let raw: Int = {
            if let ms = waitForLeaseMs { return ms }
            if let ms = act?.waitForLeaseMs { return ms }
            if let ms = browserAct?.waitForLeaseMs { return ms }
            if let ms = browserOpen?.waitForLeaseMs { return ms }
            if let ms = appMenu?.waitForLeaseMs { return ms }
            if let ms = skillRun?.waitForLeaseMs { return ms }
            return 0
        }()
        return min(max(0, raw), Self.maxWaitForLeaseMs)
    }
}

public struct RPCErrorPayload: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    /// What the agent should do next, when UseMac knows more than the code says (the mode, pause or Emergency stop
    /// that refused a request). Optional: clients fall back to their own advice for the code.
    public var hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
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
    public var browserBatchResult: BrowserBatchResult?
    public var browserTabId: Int?
    public var browserUrl: String?
    public var browserTitle: String?
    public var visionStatus: VisionStatus?
    public var visionResult: VisionQueryResult?
    public var appMenuResult: AppMenuResult?
    public var skillResult: SkillRunResult?
    public var skills: SkillListResult?
    /// The task a `task_start` opened. Pass it to `browser_open` and `task_complete` so finishing this task only
    /// closes this task's tabs.
    public var taskId: String?
    /// What the task did, on `task_complete`.
    public var taskSummary: TaskSummary?
    /// The draft `report_prepare` put in UseMac's review window.
    public var problemReport: ProblemReportReceipt?
    /// The PNGs `debug_capture` saved.
    public var debugCapture: DebugCaptureResult?
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
        browserBatchResult: BrowserBatchResult? = nil,
        browserTabId: Int? = nil,
        browserUrl: String? = nil,
        browserTitle: String? = nil,
        visionStatus: VisionStatus? = nil,
        visionResult: VisionQueryResult? = nil,
        appMenuResult: AppMenuResult? = nil,
        skillResult: SkillRunResult? = nil,
        skills: SkillListResult? = nil,
        taskId: String? = nil,
        taskSummary: TaskSummary? = nil,
        error: RPCErrorPayload? = nil,
        problemReport: ProblemReportReceipt? = nil,
        debugCapture: DebugCaptureResult? = nil
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
        self.browserBatchResult = browserBatchResult
        self.browserTabId = browserTabId
        self.browserUrl = browserUrl
        self.browserTitle = browserTitle
        self.visionStatus = visionStatus
        self.visionResult = visionResult
        self.appMenuResult = appMenuResult
        self.skillResult = skillResult
        self.skills = skills
        self.taskId = taskId
        self.taskSummary = taskSummary
        self.error = error
        self.problemReport = problemReport
        self.debugCapture = debugCapture
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
        browserBatchResult: BrowserBatchResult? = nil,
        browserTabId: Int? = nil,
        browserUrl: String? = nil,
        browserTitle: String? = nil,
        visionStatus: VisionStatus? = nil,
        visionResult: VisionQueryResult? = nil,
        appMenuResult: AppMenuResult? = nil,
        skillResult: SkillRunResult? = nil,
        skills: SkillListResult? = nil,
        taskId: String? = nil,
        taskSummary: TaskSummary? = nil,
        problemReport: ProblemReportReceipt? = nil,
        debugCapture: DebugCaptureResult? = nil
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
            browserBatchResult: browserBatchResult,
            browserTabId: browserTabId,
            browserUrl: browserUrl,
            browserTitle: browserTitle,
            visionStatus: visionStatus,
            visionResult: visionResult,
            appMenuResult: appMenuResult,
            skillResult: skillResult,
            skills: skills,
            taskId: taskId,
            taskSummary: taskSummary,
            error: nil,
            problemReport: problemReport,
            debugCapture: debugCapture
        )
    }

    public static func failure(
        id: String,
        code: String,
        message: String,
        latencyMs: Double = 0,
        hint: String? = nil
    ) -> RPCResponse {
        RPCResponse(
            id: id,
            ok: false,
            serverLatencyMs: latencyMs,
            error: RPCErrorPayload(code: code, message: message, hint: hint)
        )
    }
}

public protocol UseMacServiceProtocol: AnyObject, Sendable {
    func handle(_ request: RPCRequest) async -> RPCResponse
}
