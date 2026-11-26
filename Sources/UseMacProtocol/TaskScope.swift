import Foundation

/// What a task did, returned by `task_complete` (`taskSummary`).
public struct TaskSummary: Codable, Equatable, Sendable {
    public var taskId: String
    /// Requests tied to the task, not counting `task_start` and `task_complete`.
    public var requests: Int
    /// `act` and `browser_act` steps that ran.
    public var actions: Int
    /// Of those, the steps that failed.
    public var failedActions: Int
    /// Requests and steps UseMac refused for a safety reason (a `*_BLOCKED` or `POLICY_LOCKED` code).
    public var blocked: Int
    /// Tabs the task opened, oldest first.
    public var tabsOpened: [Int]
    /// Tabs the task opened that closed before `task_complete`.
    public var tabsClosed: [Int]
    /// The task's tabs UseMac closes about 2 s after `task_complete` (it never closes the tab the user is looking at
    /// or one with a running download, so a tab listed here can stay open).
    public var tabsClosing: [Int]
    /// From `task_start` to `task_complete`.
    public var durationMs: Int

    public init(
        taskId: String,
        requests: Int = 0,
        actions: Int = 0,
        failedActions: Int = 0,
        blocked: Int = 0,
        tabsOpened: [Int] = [],
        tabsClosed: [Int] = [],
        tabsClosing: [Int] = [],
        durationMs: Int = 0
    ) {
        self.taskId = taskId
        self.requests = requests
        self.actions = actions
        self.failedActions = failedActions
        self.blocked = blocked
        self.tabsOpened = tabsOpened
        self.tabsClosed = tabsClosed
        self.tabsClosing = tabsClosing
        self.durationMs = durationMs
    }
}

extension RPCRequest {
    /// The task a request names: the `taskId` inside its params (`browser_open`, `task_complete`), else the
    /// envelope's `taskId`. `task_start` names no task: its `taskId` is the id to give the new one.
    public var namedTaskId: String? {
        switch method {
        case .taskStart:
            return nil
        case .browserOpen:
            return browserOpen?.taskId ?? taskId
        case .taskComplete:
            return taskComplete?.taskId ?? taskId
        default:
            return taskId
        }
    }

    /// The Chrome tab the request names, if any.
    public var namedTabId: Int? {
        switch method {
        case .browserOpen: return browserOpen?.tabId
        case .browserObserve: return browserObserve?.tabId
        case .browserExtract: return browserExtract?.tabId
        case .browserScreenshot: return browserScreenshot?.tabId
        case .browserAct: return browserAct?.tabId
        case .visionQuery: return visionQuery?.tabId
        case .taskStart: return taskStart?.tabId
        case .taskComplete: return taskComplete?.tabId
        default: return nil
        }
    }

    /// The Chrome profile the request names, if any.
    public var namedProfile: String? {
        switch method {
        case .browserOpen: return browserOpen?.profile
        case .browserObserve: return browserObserve?.profile
        case .browserExtract: return browserExtract?.profile
        case .browserScreenshot: return browserScreenshot?.profile
        case .browserAct: return browserAct?.profile
        case .visionQuery: return visionQuery?.profile
        default: return nil
        }
    }

    /// True when the request names no tab and the extension would otherwise pick its own last tab (the last tab
    /// any agent touched): browser observe/extract/screenshot/act, same-tab `browser_open`, and a `vision_query` on
    /// the browser.
    public var fallsBackToLastTab: Bool {
        guard namedTabId == nil else { return false }
        switch method {
        case .browserObserve, .browserScreenshot, .browserAct:
            return true
        case .browserExtract:
            return browserExtract.map { $0.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "downloads" } ?? true
        case .browserOpen:
            guard let open = browserOpen else { return false }
            return open.newTab == false && open.newWindow != true
                && !open.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .visionQuery:
            guard let vision = visionQuery else { return false }
            let hasImage = vision.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return vision.app == nil && !hasImage
        default:
            return false
        }
    }

    /// The same request aimed at `tabId` (and at `profile` when it names none). Only for requests that
    /// `fallsBackToLastTab`; others come back unchanged.
    public func aimed(atTab tabId: Int, profile: String?) -> RPCRequest {
        guard fallsBackToLastTab else { return self }
        var copy = self
        switch method {
        case .browserOpen:
            copy.browserOpen?.tabId = tabId
            if copy.browserOpen?.profile == nil { copy.browserOpen?.profile = profile }
        case .browserObserve:
            copy.browserObserve = copy.browserObserve ?? BrowserObserveParams()
            copy.browserObserve?.tabId = tabId
            if copy.browserObserve?.profile == nil { copy.browserObserve?.profile = profile }
        case .browserExtract:
            copy.browserExtract = copy.browserExtract ?? BrowserExtractParams()
            copy.browserExtract?.tabId = tabId
            if copy.browserExtract?.profile == nil { copy.browserExtract?.profile = profile }
        case .browserScreenshot:
            copy.browserScreenshot = copy.browserScreenshot ?? BrowserScreenshotParams()
            copy.browserScreenshot?.tabId = tabId
            if copy.browserScreenshot?.profile == nil { copy.browserScreenshot?.profile = profile }
        case .browserAct:
            copy.browserAct?.tabId = tabId
            if copy.browserAct?.profile == nil { copy.browserAct?.profile = profile }
        case .visionQuery:
            copy.visionQuery?.tabId = tabId
            if copy.visionQuery?.profile == nil { copy.visionQuery?.profile = profile }
        default:
            break
        }
        return copy
    }

    /// Whether the request only reads (so it is safe to run again on another tab).
    public var isReadOnlyForTask: Bool {
        switch method {
        case .browserObserve, .browserScreenshot, .visionQuery:
            return true
        case .browserExtract:
            return browserExtract.map { $0.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "eval" } ?? true
        default:
            return false
        }
    }
}
