import Foundation
import Darwin

public enum MacUseDefaults {
    public static let version = "0.5.0"
    public static let buildNumber = "50"

    public static var defaultSocketPath: String {
        if let env = ProcessInfo.processInfo.environment["MACUSE_SOCKET"], !env.isEmpty {
            return env
        }
        return "/tmp/macuse-\(getuid()).sock"
    }

    /// Per-user private directory (inside the user's 0700 temporary directory), never the shared `/tmp`.
    public static let captureDirectory: String = {
        let base = (NSTemporaryDirectory() as NSString).standardizingPath
        return (base as NSString).appendingPathComponent("macuse-captures")
    }()
    public static let defaultExtensionPort: UInt16 = 49222
    public static let defaultAppcastURL = "https://usemac.app/appcast.xml"

    /// Set this to the 32-character Chrome Web Store ID once approved (or via Info.plist key `MacUseChromeExtensionID`).
    public static var chromeWebStoreExtensionId: String? {
        if let env = ProcessInfo.processInfo.environment["MACUSE_CHROME_EXTENSION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let plistId = Bundle.main.object(forInfoDictionaryKey: "MacUseChromeExtensionID") as? String {
            let trimmed = plistId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

public struct ScreenRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var centerX: Double { x + (width / 2.0) }
    public var centerY: Double { y + (height / 2.0) }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PermissionStatus: Codable, Equatable, Sendable {
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool

    public init(accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
    }
}

public enum GovernancePolicy: String, Codable, CaseIterable, Sendable {
    case autonomous
    case readOnly
    case confirmSensitive
    case paused
}

public struct AppDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleId: String?
    public var isActive: Bool
    public var isHidden: Bool
    public var windowTitle: String?
    public var windowBounds: ScreenRect?

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        name: String,
        bundleId: String? = nil,
        isActive: Bool = false,
        isHidden: Bool = false,
        windowTitle: String? = nil,
        windowBounds: ScreenRect? = nil
    ) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.isActive = isActive
        self.isHidden = isHidden
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
    }
}

public struct ElementNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var title: String?
    public var value: String?
    public var roleDescription: String?
    public var enabled: Bool
    public var focused: Bool
    public var frame: ScreenRect
    public var actions: [String]

    public init(
        id: String,
        role: String,
        title: String? = nil,
        value: String? = nil,
        roleDescription: String? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        frame: ScreenRect,
        actions: [String] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.roleDescription = roleDescription
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.actions = actions
    }

    public var compactLine: String {
        var parts: [String] = ["\(id) [\(role)]"]
        if let title, !title.isEmpty {
            parts.append("\"\(title.replacingOccurrences(of: "\n", with: " "))\"")
        }
        if let value, !value.isEmpty {
            let trimmed = value.replacingOccurrences(of: "\n", with: " ")
            let clipped = trimmed.count > 48 ? String(trimmed.prefix(48)) + "..." : trimmed
            parts.append("val=\"\(clipped)\"")
        }
        if focused {
            parts.append("*focused*")
        }
        if !enabled {
            parts.append("(disabled)")
        }
        parts.append("(\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)))")
        if !actions.isEmpty {
            parts.append("{\(actions.joined(separator: ","))}")
        }
        return parts.joined(separator: " ")
    }
}

public struct SnapshotDiff: Codable, Equatable, Sendable {
    public var added: [ElementNode]
    public var removedIds: [String]
    public var changed: [ElementNode]
    public var summary: String

    public init(
        added: [ElementNode] = [],
        removedIds: [String] = [],
        changed: [ElementNode] = [],
        summary: String
    ) {
        self.added = added
        self.removedIds = removedIds
        self.changed = changed
        self.summary = summary
    }
}

public struct PageBlockingOverlay: Codable, Equatable, Sendable {
    public var summary: String
    public var closeElementId: String?
    public var closeX: Double?
    public var closeY: Double?
    public var frame: ScreenRect?
    public var blocksScroll: Bool

    public init(
        summary: String,
        closeElementId: String? = nil,
        closeX: Double? = nil,
        closeY: Double? = nil,
        frame: ScreenRect? = nil,
        blocksScroll: Bool = false
    ) {
        self.summary = summary
        self.closeElementId = closeElementId
        self.closeX = closeX
        self.closeY = closeY
        self.frame = frame
        self.blocksScroll = blocksScroll
    }
}

public struct PageState: Codable, Equatable, Sendable {
    public var scrollX: Double
    public var scrollY: Double
    public var scrollHeight: Double
    public var scrollWidth: Double?
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var canScrollDown: Bool
    public var canScrollUp: Bool
    public var canScrollRight: Bool?
    public var canScrollLeft: Bool?
    public var scrollLocked: Bool
    public var blockingOverlay: PageBlockingOverlay?
    public var readableText: String?
    public var tablesMarkdown: String?
    public var scrollableContainers: [String]?

    public init(
        scrollX: Double = 0,
        scrollY: Double = 0,
        scrollHeight: Double = 0,
        scrollWidth: Double? = nil,
        viewportWidth: Double = 1280,
        viewportHeight: Double = 800,
        canScrollDown: Bool = false,
        canScrollUp: Bool = false,
        canScrollRight: Bool? = nil,
        canScrollLeft: Bool? = nil,
        scrollLocked: Bool = false,
        blockingOverlay: PageBlockingOverlay? = nil,
        readableText: String? = nil,
        tablesMarkdown: String? = nil,
        scrollableContainers: [String]? = nil
    ) {
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.scrollHeight = scrollHeight
        self.scrollWidth = scrollWidth
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.canScrollDown = canScrollDown
        self.canScrollUp = canScrollUp
        self.canScrollRight = canScrollRight
        self.canScrollLeft = canScrollLeft
        self.scrollLocked = scrollLocked
        self.blockingOverlay = blockingOverlay
        self.readableText = readableText
        self.tablesMarkdown = tablesMarkdown
        self.scrollableContainers = scrollableContainers
    }
}

public struct AgentFeedback: Codable, Equatable, Sendable {
    public var severity: String
    public var trigger: String
    public var diagnosis: String
    public var suggestedAction: String
    public var suggestedX: Double?
    public var suggestedY: Double?
    public var suggestedElementId: String?
    public var source: String
    public var latencyMs: Double

    public init(
        severity: String = "warning",
        trigger: String,
        diagnosis: String,
        suggestedAction: String,
        suggestedX: Double? = nil,
        suggestedY: Double? = nil,
        suggestedElementId: String? = nil,
        source: String,
        latencyMs: Double = 0
    ) {
        self.severity = severity
        self.trigger = trigger
        self.diagnosis = diagnosis
        self.suggestedAction = suggestedAction
        self.suggestedX = suggestedX
        self.suggestedY = suggestedY
        self.suggestedElementId = suggestedElementId
        self.source = source
        self.latencyMs = latencyMs
    }

    public var formattedBanner: String {
        var parts: [String] = [
            String(format: "⚡ usemac Feedback [%@ via %@, %.0f ms]: %@", severity.uppercased(), source, latencyMs, diagnosis)
        ]
        var actionLine = "  → Suggested recovery: \(suggestedAction)"
        if let el = suggestedElementId {
            actionLine += " [elementId=\(el)]"
        }
        if let x = suggestedX, let y = suggestedY {
            actionLine += String(format: " [click (%.1f, %.1f)]", x, y)
        }
        parts.append(actionLine)
        return parts.joined(separator: "\n")
    }
}

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var app: AppDescriptor
    public var timestampMs: Int64
    public var latencyMs: Double
    public var fromHotCache: Bool
    public var focusedElementId: String?
    public var elements: [ElementNode]
    public var diff: SnapshotDiff?
    public var screenshotPath: String?
    public var pageState: PageState?
    public var agentFeedback: AgentFeedback?

    public init(
        app: AppDescriptor,
        timestampMs: Int64,
        latencyMs: Double,
        fromHotCache: Bool = false,
        focusedElementId: String? = nil,
        elements: [ElementNode] = [],
        diff: SnapshotDiff? = nil,
        screenshotPath: String? = nil,
        pageState: PageState? = nil,
        agentFeedback: AgentFeedback? = nil
    ) {
        self.app = app
        self.timestampMs = timestampMs
        self.latencyMs = latencyMs
        self.fromHotCache = fromHotCache
        self.focusedElementId = focusedElementId
        self.elements = elements
        self.diff = diff
        self.screenshotPath = screenshotPath
        self.pageState = pageState
        self.agentFeedback = agentFeedback
    }

    public func formattedCompactSummary(maxElements: Int = 250) -> String {
        var lines: [String] = []
        let titlePart = app.windowTitle.map { " — \($0)" } ?? ""
        let cacheTag = fromHotCache ? "hot-cache" : "live-ax"
        lines.append("App: \(app.name) (pid \(app.pid))\(titlePart)")
        lines.append(String(format: "Latency: %.2f ms [%@] | Elements: %d", latencyMs, cacheTag, elements.count))
        if let focusedElementId {
            lines.append("Focused: \(focusedElementId)")
        }
        if let screenshotPath {
            lines.append("Screenshot: \(screenshotPath)")
        }
        if let page = pageState {
            let lockTag = page.scrollLocked ? " [SCROLL LOCKED]" : ""
            var horizPart = ""
            if let sw = page.scrollWidth, sw > page.viewportWidth + 8 {
                horizPart = String(
                    format: ", x=%.0f/%.0f, canRight=%@",
                    page.scrollX,
                    sw,
                    (page.canScrollRight ?? false) ? "yes" : "no"
                )
            }
            lines.append(String(
                format: "Scroll: y=%.0f/%.0f%@ (viewport %.0fx%.0f, canDown=%@, canUp=%@)%@",
                page.scrollY,
                page.scrollHeight,
                horizPart,
                page.viewportWidth,
                page.viewportHeight,
                page.canScrollDown ? "yes" : "no",
                page.canScrollUp ? "yes" : "no",
                lockTag
            ))
            if let containers = page.scrollableContainers, !containers.isEmpty {
                lines.append("ScrollContainers: " + containers.prefix(4).joined(separator: " ; "))
            }
            if let overlay = page.blockingOverlay {
                var closeHint = ""
                if let cid = overlay.closeElementId {
                    closeHint = " | close=\(cid)"
                }
                if let cx = overlay.closeX, let cy = overlay.closeY {
                    closeHint += String(format: " (%.0f,%.0f)", cx, cy)
                }
                lines.append("BlockingOverlay: \"\(overlay.summary)\"\(closeHint)")
            }
        }
        if let feedback = agentFeedback {
            lines.append(feedback.formattedBanner)
        }
        if let diff {
            lines.append("Diff: \(diff.summary)")
        }
        lines.append("---")
        for node in elements.prefix(maxElements) {
            lines.append(node.compactLine)
        }
        if elements.count > maxElements {
            lines.append("... (\(elements.count - maxElements) more elements omitted)")
        }
        if let tables = pageState?.tablesMarkdown, !tables.isEmpty {
            lines.append("--- TABLES / DATA GRIDS ---")
            lines.append(tables)
        }
        if let text = pageState?.readableText, !text.isEmpty {
            lines.append("--- READABLE TEXT ---")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}

public enum ActionStepType: String, Codable, Sendable {
    case target
    case openURL
    case navigate
    case click
    case doubleClick
    case rightClick
    case hover
    case setValue
    case type
    case pressKey
    case scroll
    case focus
    case wait
    case uploadFile
}

public struct ActionStep: Codable, Equatable, Sendable {
    public var action: ActionStepType
    public var app: String?
    public var elementId: String?
    public var selector: String?
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var files: [String]?
    public var key: String?
    public var modifiers: [String]?
    public var deltaX: Double?
    public var deltaY: Double?
    public var durationMs: Int?
    public var preferBackground: Bool?
    public var restoreCursor: Bool?
    public var url: String?
    public var newTab: Bool?

    public init(
        action: ActionStepType,
        app: String? = nil,
        elementId: String? = nil,
        selector: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        text: String? = nil,
        files: [String]? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        durationMs: Int? = nil,
        preferBackground: Bool? = true,
        restoreCursor: Bool? = true,
        url: String? = nil,
        newTab: Bool? = nil
    ) {
        self.action = action
        self.app = app
        self.elementId = elementId
        self.selector = selector
        self.x = x
        self.y = y
        self.text = text
        self.files = files
        self.key = key
        self.modifiers = modifiers
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.durationMs = durationMs
        self.preferBackground = preferBackground
        self.restoreCursor = restoreCursor
        self.url = url
        self.newTab = newTab
    }
}

public struct ActionStepResult: Codable, Equatable, Sendable {
    public var index: Int
    public var action: ActionStepType
    public var success: Bool
    public var mechanism: String
    public var latencyMs: Double
    public var message: String?
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?
    public var visualChangePercent: Double?
    public var blockedWarning: String?
    public var downloadPath: String?

    public init(
        index: Int,
        action: ActionStepType,
        success: Bool,
        mechanism: String,
        latencyMs: Double,
        message: String? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        visualChangePercent: Double? = nil,
        blockedWarning: String? = nil,
        downloadPath: String? = nil
    ) {
        self.index = index
        self.action = action
        self.success = success
        self.mechanism = mechanism
        self.latencyMs = latencyMs
        self.message = message
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.visualChangePercent = visualChangePercent
        self.blockedWarning = blockedWarning
        self.downloadPath = downloadPath
    }
}

public struct BatchActionRequest: Codable, Equatable, Sendable {
    public var app: String?
    public var steps: [ActionStep]
    public var stopOnError: Bool
    public var returnObservation: Bool
    public var returnDiffOnly: Bool
    public var includeScreenshot: Bool

    public init(
        app: String? = nil,
        steps: [ActionStep],
        stopOnError: Bool = true,
        returnObservation: Bool = true,
        returnDiffOnly: Bool = false,
        includeScreenshot: Bool = false
    ) {
        self.app = app
        self.steps = steps
        self.stopOnError = stopOnError
        self.returnObservation = returnObservation
        self.returnDiffOnly = returnDiffOnly
        self.includeScreenshot = includeScreenshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.steps = try c.decode([ActionStep].self, forKey: .steps)
        self.stopOnError = try c.decodeIfPresent(Bool.self, forKey: .stopOnError) ?? true
        self.returnObservation = try c.decodeIfPresent(Bool.self, forKey: .returnObservation) ?? true
        self.returnDiffOnly = try c.decodeIfPresent(Bool.self, forKey: .returnDiffOnly) ?? false
        self.includeScreenshot = try c.decodeIfPresent(Bool.self, forKey: .includeScreenshot) ?? false
    }
}

public struct BatchActionResult: Codable, Equatable, Sendable {
    public var success: Bool
    public var totalLatencyMs: Double
    public var stepResults: [ActionStepResult]
    public var observation: WindowSnapshot?
    public var agentFeedback: AgentFeedback?
    public var visualVerification: VisionQueryResult?
    public var screenshot: ScreenshotResult?

    public init(
        success: Bool,
        totalLatencyMs: Double,
        stepResults: [ActionStepResult],
        observation: WindowSnapshot? = nil,
        agentFeedback: AgentFeedback? = nil,
        visualVerification: VisionQueryResult? = nil,
        screenshot: ScreenshotResult? = nil
    ) {
        self.success = success
        self.totalLatencyMs = totalLatencyMs
        self.stepResults = stepResults
        self.observation = observation
        self.agentFeedback = agentFeedback
        self.visualVerification = visualVerification
        self.screenshot = screenshot
    }
}

public struct ScreenshotRequest: Codable, Equatable, Sendable {
    public var app: String?
    public var maxDimension: Int
    public var quality: Double
    public var includeBase64: Bool

    public init(
        app: String? = nil,
        maxDimension: Int = 1280,
        quality: Double = 0.78,
        includeBase64: Bool = false
    ) {
        self.app = app
        self.maxDimension = maxDimension
        self.quality = quality
        self.includeBase64 = includeBase64
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.maxDimension = try c.decodeIfPresent(Int.self, forKey: .maxDimension) ?? 1280
        self.quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.78
        self.includeBase64 = try c.decodeIfPresent(Bool.self, forKey: .includeBase64) ?? false
    }
}

public struct ScreenshotResult: Codable, Equatable, Sendable {
    public var path: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var byteCount: Int
    public var latencyMs: Double
    public var base64Data: String?

    public init(
        path: String,
        mimeType: String = "image/jpeg",
        width: Int,
        height: Int,
        byteCount: Int,
        latencyMs: Double,
        base64Data: String? = nil
    ) {
        self.path = path
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.latencyMs = latencyMs
        self.base64Data = base64Data
    }
}

public struct TelemetrySummary: Codable, Equatable, Sendable {
    public var uptimeSeconds: Double
    public var totalRequests: Int
    public var totalActions: Int
    public var lastObserveLatencyMs: Double
    public var avgObserveLatencyMs: Double
    public var hotCacheHits: Int
    public var activeClients: Int

    public init(
        uptimeSeconds: Double = 0,
        totalRequests: Int = 0,
        totalActions: Int = 0,
        lastObserveLatencyMs: Double = 0,
        avgObserveLatencyMs: Double = 0,
        hotCacheHits: Int = 0,
        activeClients: Int = 0
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.totalRequests = totalRequests
        self.totalActions = totalActions
        self.lastObserveLatencyMs = lastObserveLatencyMs
        self.avgObserveLatencyMs = avgObserveLatencyMs
        self.hotCacheHits = hotCacheHits
        self.activeClients = activeClients
    }
}

public struct BrowserProfileStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var profileName: String
    public var profileEmail: String?
    public var extensionVersion: String
    public var tabCount: Int
    public var streamingTabId: Int?
    public var streamingUrl: String?
    public var streamingTitle: String?

    public init(
        id: String,
        profileName: String,
        profileEmail: String? = nil,
        extensionVersion: String,
        tabCount: Int,
        streamingTabId: Int? = nil,
        streamingUrl: String? = nil,
        streamingTitle: String? = nil
    ) {
        self.id = id
        self.profileName = profileName
        self.profileEmail = profileEmail
        self.extensionVersion = extensionVersion
        self.tabCount = tabCount
        self.streamingTabId = streamingTabId
        self.streamingUrl = streamingUrl
        self.streamingTitle = streamingTitle
    }
}

public struct BrowserOpenParams: Codable, Equatable, Sendable {
    public var url: String
    public var profile: String?
    public var tabId: Int?
    public var newTab: Bool?
    public var stream: Bool?

    public init(
        url: String,
        profile: String? = nil,
        tabId: Int? = nil,
        newTab: Bool? = nil,
        stream: Bool? = nil
    ) {
        self.url = url
        self.profile = profile
        self.tabId = tabId
        self.newTab = newTab
        self.stream = stream
    }
}

public struct BrowserObserveParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var tabId: Int?
    public var maxElements: Int?
    public var includeText: Bool?
    public var includeTables: Bool?
    public var includeScreenshot: Bool?
    public var returnImageContent: Bool?
    public var viewportWidth: Int?
    public var viewportHeight: Int?
    public var deviceScaleFactor: Double?

    public init(
        profile: String? = nil,
        tabId: Int? = nil,
        maxElements: Int? = nil,
        includeText: Bool? = true,
        includeTables: Bool? = true,
        includeScreenshot: Bool? = false,
        returnImageContent: Bool? = false,
        viewportWidth: Int? = nil,
        viewportHeight: Int? = nil,
        deviceScaleFactor: Double? = nil
    ) {
        self.profile = profile
        self.tabId = tabId
        self.maxElements = maxElements
        self.includeText = includeText
        self.includeTables = includeTables
        self.includeScreenshot = includeScreenshot
        self.returnImageContent = returnImageContent
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.deviceScaleFactor = deviceScaleFactor
    }
}

public struct BrowserTabInfo: Codable, Equatable, Identifiable, Sendable {
    public var tabId: Int
    public var windowId: Int?
    public var index: Int?
    public var title: String
    public var url: String
    public var active: Bool
    public var pinned: Bool?
    public var status: String?
    public var profileName: String?

    public var id: Int { tabId }

    public init(
        tabId: Int,
        windowId: Int? = nil,
        index: Int? = nil,
        title: String,
        url: String,
        active: Bool = false,
        pinned: Bool? = nil,
        status: String? = nil,
        profileName: String? = nil
    ) {
        self.tabId = tabId
        self.windowId = windowId
        self.index = index
        self.title = title
        self.url = url
        self.active = active
        self.pinned = pinned
        self.status = status
        self.profileName = profileName
    }
}

public struct BrowserTabsParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var query: String?

    public init(profile: String? = nil, query: String? = nil) {
        self.profile = profile
        self.query = query
    }
}

public struct BrowserDownloadInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var filename: String
    public var url: String?
    public var state: String
    public var bytesReceived: Int?
    public var totalBytes: Int?
    public var mime: String?
    public var startTime: String?

    public init(
        id: Int,
        filename: String,
        url: String? = nil,
        state: String,
        bytesReceived: Int? = nil,
        totalBytes: Int? = nil,
        mime: String? = nil,
        startTime: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.mime = mime
        self.startTime = startTime
    }
}

public struct BrowserExtractParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var tabId: Int?
    public var mode: String
    public var selector: String?
    public var expression: String?
    public var scanHorizontal: Bool?
    public var maxChars: Int?

    public init(
        profile: String? = nil,
        tabId: Int? = nil,
        mode: String = "auto",
        selector: String? = nil,
        expression: String? = nil,
        scanHorizontal: Bool? = false,
        maxChars: Int? = 16000
    ) {
        self.profile = profile
        self.tabId = tabId
        self.mode = mode
        self.selector = selector
        self.expression = expression
        self.scanHorizontal = scanHorizontal
        self.maxChars = maxChars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile)
        self.tabId = try c.decodeIfPresent(Int.self, forKey: .tabId)
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "auto"
        self.selector = try c.decodeIfPresent(String.self, forKey: .selector)
        self.expression = try c.decodeIfPresent(String.self, forKey: .expression)
        self.scanHorizontal = try c.decodeIfPresent(Bool.self, forKey: .scanHorizontal)
        self.maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars)
    }
}

public struct BrowserExtractResult: Codable, Equatable, Sendable {
    public var mode: String
    public var tabId: Int?
    public var url: String?
    public var title: String?
    public var latencyMs: Double
    public var tablesMarkdown: String?
    public var rowCount: Int?
    public var columnCount: Int?
    public var scannedHorizontalSteps: Int?
    public var text: String?
    public var jsonResult: String?
    public var downloads: [BrowserDownloadInfo]?

    public init(
        mode: String,
        tabId: Int? = nil,
        url: String? = nil,
        title: String? = nil,
        latencyMs: Double = 0,
        tablesMarkdown: String? = nil,
        rowCount: Int? = nil,
        columnCount: Int? = nil,
        scannedHorizontalSteps: Int? = nil,
        text: String? = nil,
        jsonResult: String? = nil,
        downloads: [BrowserDownloadInfo]? = nil
    ) {
        self.mode = mode
        self.tabId = tabId
        self.url = url
        self.title = title
        self.latencyMs = latencyMs
        self.tablesMarkdown = tablesMarkdown
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.scannedHorizontalSteps = scannedHorizontalSteps
        self.text = text
        self.jsonResult = jsonResult
        self.downloads = downloads
    }
}

public struct BrowserScreenshotParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var tabId: Int?
    public var selector: String?
    public var elementId: String?
    public var fullPage: Bool?
    public var viewportWidth: Int?
    public var viewportHeight: Int?
    public var deviceScaleFactor: Double?
    public var quality: Int?
    public var returnImageContent: Bool?

    public init(
        profile: String? = nil,
        tabId: Int? = nil,
        selector: String? = nil,
        elementId: String? = nil,
        fullPage: Bool? = false,
        viewportWidth: Int? = nil,
        viewportHeight: Int? = nil,
        deviceScaleFactor: Double? = nil,
        quality: Int? = 84,
        returnImageContent: Bool? = true
    ) {
        self.profile = profile
        self.tabId = tabId
        self.selector = selector
        self.elementId = elementId
        self.fullPage = fullPage
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.deviceScaleFactor = deviceScaleFactor
        self.quality = quality
        self.returnImageContent = returnImageContent
    }
}

public enum LocalVisionModelPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen35_08B = "mlx-community/Qwen3.5-0.8B-4bit"
    case qwen25VL3B = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
    case holo1_3B = "mlx-community/Holo1-3B-4bit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen35_08B: return "Qwen3.5 0.8B (4-bit)"
        case .qwen25VL3B: return "Qwen2.5-VL 3B (4-bit)"
        case .holo1_3B: return "Holo1 3B GUI (4-bit)"
        }
    }

    public var sizeHint: String {
        switch self {
        case .qwen35_08B: return "~620 MB · Ultra-fast"
        case .qwen25VL3B: return "~2.1 GB · Best grounding"
        case .holo1_3B: return "~1.9 GB · GUI clicks"
        }
    }
}

public struct VisionStatus: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var state: String
    public var modelId: String
    public var backend: String
    public var ocrAvailable: Bool
    public var runtimeInstalled: Bool
    public var modelDownloaded: Bool
    public var workerRunning: Bool
    public var installProgress: String?
    public var lastError: String?

    public init(
        enabled: Bool = false,
        state: String = "not_installed",
        modelId: String = LocalVisionModelPreset.qwen25VL3B.rawValue,
        backend: String = "apple-vision-ocr",
        ocrAvailable: Bool = true,
        runtimeInstalled: Bool = false,
        modelDownloaded: Bool = false,
        workerRunning: Bool = false,
        installProgress: String? = nil,
        lastError: String? = nil
    ) {
        self.enabled = enabled
        self.state = state
        self.modelId = modelId
        self.backend = backend
        self.ocrAvailable = ocrAvailable
        self.runtimeInstalled = runtimeInstalled
        self.modelDownloaded = modelDownloaded
        self.workerRunning = workerRunning
        self.installProgress = installProgress
        self.lastError = lastError
    }
}

public struct VisionInstallParams: Codable, Equatable, Sendable {
    public var modelId: String?
    public var enable: Bool?

    public init(modelId: String? = nil, enable: Bool? = true) {
        self.modelId = modelId
        self.enable = enable
    }
}

public struct VisionQueryParams: Codable, Equatable, Sendable {
    public var mode: String
    public var query: String?
    public var profile: String?
    public var tabId: Int?
    public var app: String?
    public var imagePath: String?
    public var selector: String?
    public var elementId: String?

    public init(
        mode: String = "ask",
        query: String? = nil,
        profile: String? = nil,
        tabId: Int? = nil,
        app: String? = nil,
        imagePath: String? = nil,
        selector: String? = nil,
        elementId: String? = nil
    ) {
        self.mode = mode
        self.query = query
        self.profile = profile
        self.tabId = tabId
        self.app = app
        self.imagePath = imagePath
        self.selector = selector
        self.elementId = elementId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "ask"
        self.query = try c.decodeIfPresent(String.self, forKey: .query)
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile)
        self.tabId = try c.decodeIfPresent(Int.self, forKey: .tabId)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        self.selector = try c.decodeIfPresent(String.self, forKey: .selector)
        self.elementId = try c.decodeIfPresent(String.self, forKey: .elementId)
    }
}

public struct VisionDetection: Codable, Equatable, Sendable {
    public var label: String
    public var x: Double
    public var y: Double
    public var frame: ScreenRect?
    public var confidence: Double
    public var source: String

    public init(
        label: String,
        x: Double,
        y: Double,
        frame: ScreenRect? = nil,
        confidence: Double = 1.0,
        source: String
    ) {
        self.label = label
        self.x = x
        self.y = y
        self.frame = frame
        self.confidence = confidence
        self.source = source
    }
}

public struct VisionQueryResult: Codable, Equatable, Sendable {
    public var mode: String
    public var backend: String
    public var modelId: String?
    public var latencyMs: Double
    public var answer: String
    public var verified: Bool?
    public var x: Double?
    public var y: Double?
    public var frame: ScreenRect?
    public var blockingDetected: Bool
    public var detections: [VisionDetection]
    public var imagePath: String?

    public init(
        mode: String,
        backend: String,
        modelId: String? = nil,
        latencyMs: Double,
        answer: String,
        verified: Bool? = nil,
        x: Double? = nil,
        y: Double? = nil,
        frame: ScreenRect? = nil,
        blockingDetected: Bool = false,
        detections: [VisionDetection] = [],
        imagePath: String? = nil
    ) {
        self.mode = mode
        self.backend = backend
        self.modelId = modelId
        self.latencyMs = latencyMs
        self.answer = answer
        self.verified = verified
        self.x = x
        self.y = y
        self.frame = frame
        self.blockingDetected = blockingDetected
        self.detections = detections
        self.imagePath = imagePath
    }
}

public struct BrowserActParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var tabId: Int?
    public var steps: [ActionStep]
    public var stopOnError: Bool
    public var returnObservation: Bool
    public var returnDiffOnly: Bool
    public var readOnly: Bool?
    public var verify: String?
    public var returnImageContent: Bool?

    public init(
        profile: String? = nil,
        tabId: Int? = nil,
        steps: [ActionStep],
        stopOnError: Bool = true,
        returnObservation: Bool = true,
        returnDiffOnly: Bool = false,
        readOnly: Bool? = nil,
        verify: String? = nil,
        returnImageContent: Bool? = nil
    ) {
        self.profile = profile
        self.tabId = tabId
        self.steps = steps
        self.stopOnError = stopOnError
        self.returnObservation = returnObservation
        self.returnDiffOnly = returnDiffOnly
        self.readOnly = readOnly
        self.verify = verify
        self.returnImageContent = returnImageContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile)
        self.tabId = try c.decodeIfPresent(Int.self, forKey: .tabId)
        self.steps = try c.decode([ActionStep].self, forKey: .steps)
        self.stopOnError = try c.decodeIfPresent(Bool.self, forKey: .stopOnError) ?? true
        self.returnObservation = try c.decodeIfPresent(Bool.self, forKey: .returnObservation) ?? true
        self.returnDiffOnly = try c.decodeIfPresent(Bool.self, forKey: .returnDiffOnly) ?? false
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly)
        self.verify = try c.decodeIfPresent(String.self, forKey: .verify)
        self.returnImageContent = try c.decodeIfPresent(Bool.self, forKey: .returnImageContent)
    }
}

public struct BrowserCursorEvent: Codable, Equatable, Sendable {
    public var tabId: Int?
    public var profileName: String?
    public var x: Double
    public var y: Double
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var phase: String
    public var label: String?

    public init(
        tabId: Int? = nil,
        profileName: String? = nil,
        x: Double,
        y: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        phase: String,
        label: String? = nil
    ) {
        self.tabId = tabId
        self.profileName = profileName
        self.x = x
        self.y = y
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.phase = phase
        self.label = label
    }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var version: String
    public var pid: Int32
    public var socketPath: String
    public var policy: GovernancePolicy
    public var killSwitchTripped: Bool
    public var permissions: PermissionStatus
    public var pairedApp: AppDescriptor?
    public var frontmostApp: AppDescriptor?
    public var telemetry: TelemetrySummary
    public var browserProfiles: [BrowserProfileStatus]

    public init(
        version: String = MacUseDefaults.version,
        pid: Int32,
        socketPath: String,
        policy: GovernancePolicy,
        killSwitchTripped: Bool,
        permissions: PermissionStatus,
        pairedApp: AppDescriptor? = nil,
        frontmostApp: AppDescriptor? = nil,
        telemetry: TelemetrySummary,
        browserProfiles: [BrowserProfileStatus] = []
    ) {
        self.version = version
        self.pid = pid
        self.socketPath = socketPath
        self.policy = policy
        self.killSwitchTripped = killSwitchTripped
        self.permissions = permissions
        self.pairedApp = pairedApp
        self.frontmostApp = frontmostApp
        self.telemetry = telemetry
        self.browserProfiles = browserProfiles
    }
}

public struct AuditEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var timestampMs: Int64
    public var method: String
    public var targetApp: String?
    public var summary: String
    public var latencyMs: Double
    public var success: Bool

    public init(
        id: String = UUID().uuidString,
        timestampMs: Int64,
        method: String,
        targetApp: String? = nil,
        summary: String,
        latencyMs: Double,
        success: Bool
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.method = method
        self.targetApp = targetApp
        self.summary = summary
        self.latencyMs = latencyMs
        self.success = success
    }
}

public enum OverlayVisualEvent: Codable, Equatable, Sendable {
    case highlightElement(rect: ScreenRect, label: String, role: String?, durationMs: Int)
    case pulsePoint(x: Double, y: Double, label: String?)
    case agentBanner(appName: String, message: String, active: Bool)
    case clear
}

public enum HUDCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topTrailing: return "Top Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }

    public var symbolName: String {
        switch self {
        case .topLeading: return "inset.filled.topleft.rectangle"
        case .topTrailing: return "inset.filled.topright.rectangle"
        case .bottomLeading: return "inset.filled.bottomleft.rectangle"
        case .bottomTrailing: return "inset.filled.bottomright.rectangle"
        }
    }
}

public struct TaskStartParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var tabId: Int?
    public var app: String?
    public var summary: String?

    public init(
        profile: String? = nil,
        tabId: Int? = nil,
        app: String? = nil,
        summary: String? = nil
    ) {
        self.profile = profile
        self.tabId = tabId
        self.app = app
        self.summary = summary
    }
}

public struct TaskCompleteParams: Codable, Equatable, Sendable {
    public var profile: String?
    public var tabId: Int?
    public var app: String?
    public var summary: String?

    public init(
        profile: String? = nil,
        tabId: Int? = nil,
        app: String? = nil,
        summary: String? = nil
    ) {
        self.profile = profile
        self.tabId = tabId
        self.app = app
        self.summary = summary
    }
}

public enum LiveActivityKind: String, Codable, Equatable, Sendable {
    case observe
    case taskStart
    case actionStart
    case actionStep
    case actionComplete
    case taskComplete
    case screenshot
    case highlight
    case policyOrSafety
}

public struct LiveActivityItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var timestampMs: Int64
    public var kind: LiveActivityKind
    public var appName: String?
    public var appPid: Int32?
    public var bundleId: String?
    public var windowTitle: String?
    public var windowBounds: ScreenRect?
    public var title: String
    public var subtitle: String?
    public var elementId: String?
    public var elementFrame: ScreenRect?
    public var mechanism: String?
    public var latencyMs: Double?
    public var success: Bool
    public var isInProgress: Bool
    public var browserTabId: Int?
    public var browserProfile: String?

    public init(
        id: String = UUID().uuidString,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        kind: LiveActivityKind,
        appName: String? = nil,
        appPid: Int32? = nil,
        bundleId: String? = nil,
        windowTitle: String? = nil,
        windowBounds: ScreenRect? = nil,
        title: String,
        subtitle: String? = nil,
        elementId: String? = nil,
        elementFrame: ScreenRect? = nil,
        mechanism: String? = nil,
        latencyMs: Double? = nil,
        success: Bool = true,
        isInProgress: Bool = false,
        browserTabId: Int? = nil,
        browserProfile: String? = nil
    ) {
        self.id = id
        self.timestampMs = timestampMs
        self.kind = kind
        self.appName = appName
        self.appPid = appPid
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
        self.title = title
        self.subtitle = subtitle
        self.elementId = elementId
        self.elementFrame = elementFrame
        self.mechanism = mechanism
        self.latencyMs = latencyMs
        self.success = success
        self.isInProgress = isInProgress
        self.browserTabId = browserTabId
        self.browserProfile = browserProfile
    }
}

public enum HUDStreamMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case autoWindow
    case fullDisplay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoWindow: return "Target Window"
        case .fullDisplay: return "Full Screen"
        }
    }

    public var symbolName: String {
        switch self {
        case .autoWindow: return "macwindow"
        case .fullDisplay: return "display"
        }
    }
}

public enum LiveStreamStatus: Equatable, Sendable {
    case idle
    case connecting
    case streaming(sourceName: String, isWindow: Bool)
    case permissionRequired
}
