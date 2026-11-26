import Foundation
import UseMacProtocol
import Network

/// Decides whether a Chrome window may appear in the UseMac preview: only when it is showing a UseMac tab.
public enum UsemacTabPrivacy {
    /// Chrome titles its window after the active tab (plus indicators such as a speaker emoji), so the window
    /// shows a UseMac tab when an active UseMac tab's title starts the window title.
    public static func windowShowsUsemacTab(windowTitle: String, tabs: [BrowserTabInfo]) -> Bool {
        let window = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !window.isEmpty else { return false }
        return tabs.contains { tab in
            guard tab.active, tab.usemac == true else { return false }
            let tabTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return !tabTitle.isEmpty && window.hasPrefix(tabTitle)
        }
    }
}

public final class ChromeExtensionBridge: @unchecked Sendable {
    public struct BridgeResponse: Sendable {
        public let ok: Bool
        public let tabId: Int?
        public let profileName: String?
        public let url: String?
        public let title: String?
        public let tabs: [BrowserTabInfo]?
        public let extractResult: BrowserExtractResult?
        public let screenshot: ScreenshotResult?
        public let snapshot: WindowSnapshot?
        public let actionResult: BatchActionResult?
        public let error: RPCErrorPayload?
        /// Chrome window of `tabId` (sent by `open`, including `newWindow`, and by restricted `act` answers).
        public let windowId: Int?
        /// True when the tab is on a page Chrome does not let extensions script (docs/BRIDGE-PROTOCOL.md).
        public let restricted: Bool?
        /// `close_owned_tabs`: tabs UseMac closed, and tabs it kept open with the reason.
        public let closedTabs: [OwnedTabOutcome]?
        public let keptTabs: [OwnedTabOutcome]?

        public init(
            ok: Bool,
            tabId: Int? = nil,
            profileName: String? = nil,
            url: String? = nil,
            title: String? = nil,
            tabs: [BrowserTabInfo]? = nil,
            extractResult: BrowserExtractResult? = nil,
            screenshot: ScreenshotResult? = nil,
            snapshot: WindowSnapshot? = nil,
            actionResult: BatchActionResult? = nil,
            error: RPCErrorPayload? = nil,
            windowId: Int? = nil,
            restricted: Bool? = nil,
            closedTabs: [OwnedTabOutcome]? = nil,
            keptTabs: [OwnedTabOutcome]? = nil
        ) {
            self.ok = ok
            self.tabId = tabId
            self.profileName = profileName
            self.url = url
            self.title = title
            self.tabs = tabs
            self.extractResult = extractResult
            self.screenshot = screenshot
            self.snapshot = snapshot
            self.actionResult = actionResult
            self.error = error
            self.windowId = windowId
            self.restricted = restricted
            self.closedTabs = closedTabs
            self.keptTabs = keptTabs
        }
    }

    public struct OwnedTabOutcome: Decodable, Sendable, Equatable {
        public let tabId: Int
        public let title: String?
        public let reason: String?
    }

    private enum AuthState {
        case awaitingHello
        case pairingRequired
        case challenged(clientNonce: String, serverNonce: String, timeoutTask: Task<Void, Never>)
        case ready
    }

    private final class ExtensionSession {
        let id: String
        let connection: NWConnection
        var authState: AuthState
        var profileName: String
        var extensionVersion: String
        var tabCount: Int
        var streamingTabId: Int?
        var streamingUrl: String?
        var streamingTitle: String?
        let acceptedAt = Date()
        var extensionId: String?
        var health: ChromeExtensionHealth?

        init(id: String, connection: NWConnection) {
            self.id = id
            self.connection = connection
            self.authState = .awaitingHello
            self.profileName = "Chrome"
            self.extensionVersion = "0.1.0"
            self.tabCount = 0
            self.streamingTabId = nil
            self.streamingUrl = nil
            self.streamingTitle = nil
        }

        var isReady: Bool {
            if case .ready = authState {
                return true
            }
            return false
        }

        var isPairingRequired: Bool {
            if case .pairingRequired = authState {
                return true
            }
            return false
        }

        func cancelChallengeTimeout() {
            if case .challenged(_, _, let task) = authState {
                task.cancel()
            }
        }

        var status: BrowserProfileStatus {
            BrowserProfileStatus(
                id: id,
                profileName: profileName,
                extensionVersion: extensionVersion,
                tabCount: tabCount,
                streamingTabId: streamingTabId,
                streamingUrl: streamingUrl,
                streamingTitle: streamingTitle,
                extensionId: extensionId,
                extensionSource: health?.source.rawValue,
                bundledExtensionVersion: health?.bundledVersion,
                extensionOutdated: health?.outdated,
                extensionReloadable: health?.reloadable,
                extensionNote: health?.note
            )
        }
    }

    private struct PendingRequest {
        let sessionId: String
        let continuation: CheckedContinuation<BridgeResponse, Never>
        let timeoutTask: Task<Void, Never>
    }

    private struct TabUrlPayload: Decodable {
        let tabId: Int?
        let windowId: Int?
        let url: String?
        let pendingUrl: String?
        let title: String?
        let active: Bool?
        let removed: Bool?
    }

    /// Single-pass decoder for incoming WebSocket messages (avoids decoding JSON twice per message).
    private enum IncomingMessage: Decodable {
        case hello(HelloPayload?)
        case auth(AuthPayload?)
        case profileInfo(ProfileInfoPayload?)
        case ping
        case frame(FramePayload?)
        case cursor(CursorPayload?)
        case streamStopped(StreamStoppedPayload?)
        case stopRequested(StopRequestedPayload?)
        case tabUrl(TabUrlPayload?)
        case response(ResponsePayload?)
        case unknown

        private enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "hello":
                self = .hello(try? HelloPayload(from: decoder))
            case "auth":
                self = .auth(try? AuthPayload(from: decoder))
            case "profile_info":
                self = .profileInfo(try? ProfileInfoPayload(from: decoder))
            case "ping":
                self = .ping
            case "frame":
                self = .frame(try? FramePayload(from: decoder))
            case "cursor":
                self = .cursor(try? CursorPayload(from: decoder))
            case "stream_stopped":
                self = .streamStopped(try? StreamStoppedPayload(from: decoder))
            case "stop_requested":
                self = .stopRequested(try? StopRequestedPayload(from: decoder))
            case "tab_url":
                self = .tabUrl(try? TabUrlPayload(from: decoder))
            case "response":
                self = .response(try? ResponsePayload(from: decoder))
            default:
                self = .unknown
            }
        }
    }

    private struct HelloPayload: Decodable {
        let `protocol`: Int?
        let extensionVersion: String?
        /// `chrome.runtime.id`. Extensions that send it also accept `reload_extension`.
        let extensionId: String?
        let profileName: String?
        let clientNonce: String?
        let hasKey: Bool?

        private enum CodingKeys: String, CodingKey {
            case `protocol`, extensionVersion, extensionId, profileName, clientNonce, hasKey
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.protocol = try c.decodeIfPresent(Int.self, forKey: .protocol)
            self.extensionVersion = try c.decodeIfPresent(String.self, forKey: .extensionVersion)
            // Optional and informational: a malformed value must never cost the extension its handshake.
            self.extensionId = try? c.decodeIfPresent(String.self, forKey: .extensionId)
            self.profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
            self.clientNonce = try c.decodeIfPresent(String.self, forKey: .clientNonce)
            self.hasKey = try c.decodeIfPresent(Bool.self, forKey: .hasKey)
        }
    }

    private struct AuthPayload: Decodable {
        let clientProof: String?
    }

    private struct ProfileInfoPayload: Decodable {
        let profileName: String?
        let tabCount: Int?
    }

    private struct FramePayload: Decodable {
        let tabId: Int?
        let profileName: String?
        let url: String?
        let title: String?
        let viewportWidth: Int?
        let viewportHeight: Int?
        let jpegBase64: String?
        /// True while the tab indicator (#27) is on screen in this frame; older extensions never send it.
        let indicator: Bool?
    }

    private struct CursorPayload: Decodable {
        let tabId: Int?
        let x: Double?
        let y: Double?
        let viewportWidth: Double?
        let viewportHeight: Double?
        let phase: String?
        let label: String?
    }

    private struct StreamStoppedPayload: Decodable {
        let tabId: Int?
        /// "closed", "stopped", "detached" (the tab is gone or the user stopped it) or "idle", "evicted" (the
        /// tab is still open; only its live stream stopped). Older extensions send no reason.
        let reason: String?
    }

    public struct CachedBrowserFrame: Sendable {
        public let jpegData: Data
        public let viewportWidth: Int
        public let viewportHeight: Int
        public let profileName: String
        public let tabId: Int?
        public let url: String?
        public let title: String
        public let capturedAt: Date
        /// The frame shows UseMac's tab indicator (border and pill), so agents must not get it as a screenshot.
        public var showsIndicator: Bool = false
    }

    private struct ResponsePayload: Decodable {
        let id: String
        let ok: Bool
        let tabId: Int?
        let profileName: String?
        let url: String?
        let title: String?
        let tabs: [BrowserTabInfo]?
        let extractResult: BrowserExtractResult?
        let snapshot: WindowSnapshot?
        let screenshotBase64: String?
        let screenshotWidth: Int?
        let screenshotHeight: Int?
        let screenshotLatencyMs: Double?
        let screenshotTruncated: Bool?
        let actionResult: BatchActionResult?
        let error: RPCErrorPayload?
        let windowId: Int?
        let restricted: Bool?
        let closedTabs: [OwnedTabOutcome]?
        let keptTabs: [OwnedTabOutcome]?
    }

    private struct PairingRequiredWireMessage: Encodable {
        let type = "pairing_required"
    }

    private struct ChallengeWireMessage: Encodable {
        let type = "challenge"
        let serverNonce: String
        let serverProof: String
    }

    private struct ReadyWireMessage: Encodable {
        let type = "ready"
        /// Omitted when nil. What the app knows about this extension, for the extension popup.
        var extensionStatus: ReadyExtensionStatus? = nil
    }

    private struct ReadyExtensionStatus: Encodable {
        let source: String
        let bundledVersion: String?
        let outdated: Bool?
        let reloadable: Bool
        let note: String?
    }

    private struct ReloadExtensionWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "reload_extension"
    }

    private struct AuthFailedWireMessage: Encodable {
        let type = "auth_failed"
        let reason: String
    }

    private struct CancelWireMessage: Encodable {
        let type = "cancel"
        let tabId: Int?

        private enum CodingKeys: String, CodingKey {
            case type
            case tabId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            if let tabId {
                try container.encode(tabId, forKey: .tabId)
            } else {
                try container.encodeNil(forKey: .tabId)
            }
        }
    }

    private struct CloseOwnedTabsWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "close_owned_tabs"
        let keepTabIds: [Int]
        /// Close only these (the finished task's own tabs). Omitted: every owned tab not kept, as before.
        let closeTabIds: [Int]?
    }

    private struct TabsWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "tabs"
        let query: String?
    }

    private struct OpenWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "open"
        let url: String
        let tabId: Int?
        let newTab: Bool
        let stream: Bool
        /// Omitted when nil. With `tabId` and an empty `url`, the extension only activates the tab.
        let activate: Bool?
        /// Omitted when nil. Opens the URL in a new unfocused Chrome window owned by UseMac.
        let newWindow: Bool?
        /// Omitted when nil. Inline steps to run immediately after page load.
        let steps: [ActionStep]?
        /// Omitted when nil. Automatically dismiss high-confidence cookie/consent overlays after load.
        let autoDismissOverlays: Bool?
        let returnDiffOnly: Bool?
        let observationMode: ObservationMode?
    }

    private struct ObserveWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "observe"
        let tabId: Int?
        let maxElements: Int?
        let includeText: Bool
        let includeTables: Bool
        let includeScreenshot: Bool
        let filter: ElementFilter?
        let viewportWidth: Int?
        let viewportHeight: Int?
        let deviceScaleFactor: Double?
    }

    private struct ExtractWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "extract"
        let tabId: Int?
        let mode: String
        let selector: String?
        let expression: String?
        let scanHorizontal: Bool
        let scanVertical: Bool?
        let urlFilter: String?
        let frameIndex: Int?
        let maxChars: Int
    }

    private struct ScreenshotWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "screenshot"
        let tabId: Int?
        let selector: String?
        let elementId: String?
        let fullPage: Bool
        let viewportWidth: Int?
        let viewportHeight: Int?
        let deviceScaleFactor: Double?
        let quality: Int
    }

    private struct ActWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "act"
        let tabId: Int?
        let steps: [ActionStep]
        let stopOnError: Bool
        let returnObservation: Bool
        let returnDiffOnly: Bool
        let includeScreenshot: Bool
        let observationMode: ObservationMode?
        let maxElements: Int?
        let includeText: Bool?
        let includeTables: Bool?
    }

    private struct StopStreamWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "stop_stream"
        let tabId: Int?
    }

    private struct FocusTabWireCommand: Encodable {
        let type = "request"
        let id: String
        let command = "focus_tab"
        let tabId: Int?
    }

    private struct PongWireMessage: Encodable {
        let type = "pong"
    }

    private static let maxUnreadySessions = 8
    private static let challengeTimeoutSeconds: UInt64 = 10
    private static let maxActTimeoutSeconds: UInt64 = 120
    private static let notPairedMessage = "A Chrome profile is connected but not paired. Open the UseMac extension popup and paste the pairing key from UseMac → Settings → General → Chrome Extension."

    private let configuredPort: UInt16
    private let pairingStore: BridgePairingStore
    private let queue = DispatchQueue(label: "app.usemac.chrome-bridge", qos: .userInitiated)
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var listener: NWListener?
    private var activeKey: BridgeKey?
    private var sessions: [String: ExtensionSession] = [:]
    private var sessionOrder: [String] = []
    private var pendingRequests: [String: PendingRequest] = [:]
    private var cachedFramesByTab: [String: CachedBrowserFrame] = [:]
    private var latestCachedFrame: CachedBrowserFrame?
    /// Live `lowercased(profileName) -> [tabId: url]` cache populated by `tab_url` push events and `tabs`/`open` responses.
    private var tabUrlsByProfile: [String: [Int: String]] = [:]
    /// Lowercased profile names whose active session has pushed at least one `tab_url` event.
    private var tabUrlPushProfiles: Set<String> = []
    private let originLog = ExtensionOriginLog()
    /// The extension copy inside UseMac.app: its version and the ID Chrome gives that folder when loaded unpacked.
    public let bundledExtension: BundledChromeExtension?

    private var _listeningPort: UInt16 = 0
    private var _baseCommandTimeoutSeconds: UInt64 = 15
    private var _onBrowserFrame: (@Sendable (_ tabId: Int?, _ jpegData: Data, _ viewportWidth: Int, _ viewportHeight: Int, _ profileName: String, _ title: String) -> Void)?
    private var _onBrowserCursor: (@Sendable (BrowserCursorEvent) -> Void)?
    private var _onBrowserStreamStopped: (@Sendable (_ profileName: String, _ tabId: Int?) -> Void)?
    private var _onBrowserStreamPaused: (@Sendable (_ profileName: String, _ tabId: Int) -> Void)?
    private var _onProfilesChanged: (@Sendable ([BrowserProfileStatus]) -> Void)?
    private var _onPairingStateChanged: (@Sendable () -> Void)?
    private var _onTabStreamEnded: (@Sendable (_ profileName: String, _ tabId: Int, _ reason: String?) -> Void)?

    internal var baseCommandTimeoutSeconds: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _baseCommandTimeoutSeconds
        }
        set {
            lock.lock()
            _baseCommandTimeoutSeconds = newValue
            lock.unlock()
        }
    }

    public var listeningPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return _listeningPort
    }

    public var onBrowserFrame: (@Sendable (_ tabId: Int?, _ jpegData: Data, _ viewportWidth: Int, _ viewportHeight: Int, _ profileName: String, _ title: String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onBrowserFrame
        }
        set {
            lock.lock()
            _onBrowserFrame = newValue
            lock.unlock()
        }
    }

    public var onBrowserCursor: (@Sendable (BrowserCursorEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onBrowserCursor
        }
        set {
            lock.lock()
            _onBrowserCursor = newValue
            lock.unlock()
        }
    }

    /// The tab is still open but its live stream stopped (idle timeout, or another tab took its streaming slot).
    public var onBrowserStreamPaused: (@Sendable (_ profileName: String, _ tabId: Int) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onBrowserStreamPaused
        }
        set {
            lock.lock()
            _onBrowserStreamPaused = newValue
            lock.unlock()
        }
    }

    public var onBrowserStreamStopped: (@Sendable (_ profileName: String, _ tabId: Int?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onBrowserStreamStopped
        }
        set {
            lock.lock()
            _onBrowserStreamStopped = newValue
            lock.unlock()
        }
    }

    /// Every `stream_stopped` that names a tab, with the extension's reason ("closed" when the tab is gone; older
    /// extensions send none). The engine forgets closed tabs with it; the preview uses onBrowserStreamStopped/Paused.
    public var onTabStreamEnded: (@Sendable (_ profileName: String, _ tabId: Int, _ reason: String?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onTabStreamEnded
        }
        set {
            lock.lock()
            _onTabStreamEnded = newValue
            lock.unlock()
        }
    }

    public var onProfilesChanged: (@Sendable ([BrowserProfileStatus]) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onProfilesChanged
        }
        set {
            lock.lock()
            _onProfilesChanged = newValue
            lock.unlock()
        }
    }

    public var onPairingStateChanged: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPairingStateChanged
        }
        set {
            lock.lock()
            _onPairingStateChanged = newValue
            lock.unlock()
        }
    }

    public init(
        port: UInt16 = UseMacDefaults.defaultExtensionPort,
        pairingStore: BridgePairingStore = BridgePairingStore(),
        bundledExtension: BundledChromeExtension? = BundledChromeExtension.locate()
    ) {
        self.configuredPort = port
        self.pairingStore = pairingStore
        self.bundledExtension = bundledExtension
    }

    deinit {
        stop()
    }

    public func pairingKeyText() -> String? {
        lock.lock()
        if let key = activeKey {
            lock.unlock()
            return key.text
        }
        lock.unlock()

        guard let loaded = try? pairingStore.loadOrCreateKey() else {
            return nil
        }

        lock.lock()
        if activeKey == nil {
            activeKey = loaded
        }
        let resolved = activeKey ?? loaded
        lock.unlock()
        return resolved.text
    }

    public func resetPairingKey() -> String? {
        guard let newKey = try? pairingStore.resetKey() else {
            return nil
        }

        lock.lock()
        activeKey = newKey
        let hadReadyProfiles = !readySessionsLocked().isEmpty
        let hadPendingPairing = !pendingPairingProfilesLocked().isEmpty
        let activeSessions = Array(sessions.values)
        let streamingSessions = activeSessions.filter { $0.isReady && $0.streamingTabId != nil }
        sessions.removeAll()
        sessionOrder.removeAll()
        tabUrlsByProfile.removeAll()
        tabUrlPushProfiles.removeAll()

        let pending = pendingRequests
        pendingRequests.removeAll()
        let profilesHandler = _onProfilesChanged
        let pairingHandler = _onPairingStateChanged
        let stoppedHandler = _onBrowserStreamStopped
        lock.unlock()

        for session in activeSessions {
            session.cancelChallengeTimeout()
            session.connection.cancel()
        }
        for entry in pending.values {
            entry.timeoutTask.cancel()
            entry.continuation.resume(returning: BridgeResponse(
                ok: false,
                error: RPCErrorPayload(
                    code: "EXTENSION_NOT_CONNECTED",
                    message: "Chrome extension pairing key was reset"
                )
            ))
        }
        for session in streamingSessions {
            stoppedHandler?(session.profileName, session.streamingTabId)
        }
        if hadReadyProfiles {
            profilesHandler?([])
        }
        if hadPendingPairing {
            pairingHandler?()
        }
        return newKey.text
    }

    public func pendingPairingProfiles() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingPairingProfilesLocked()
    }

    public func start() {
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let loadedKey = try? pairingStore.loadOrCreateKey() else {
            return
        }

        let originLog = self.originLog
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 32 * 1024 * 1024
        wsOptions.setClientRequestHandler(queue) { _, headers in
            guard let originHeader = headers.first(where: { $0.name.caseInsensitiveCompare("Origin") == .orderedSame })?.value else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [("Connection", "close")])
            }
            guard let extId = BridgeOriginPolicy.extensionId(fromOrigin: originHeader) else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [("Connection", "close")])
            }

            // Store builds accept the store ID and the app's own unpacked folder; beta builds accept any extension.
            let allowed = BridgeOriginPolicy.allowedExtensionIds()
            if !allowed.isEmpty && !allowed.contains(extId) {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [("Connection", "close")])
            }
            if ChromeExtensionID.isValid(extId) {
                originLog.record(extId)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let nwPort: NWEndpoint.Port = configuredPort == 0
            ? .any
            : (NWEndpoint.Port(rawValue: configuredPort) ?? .any)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: nwPort
        )

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            return
        }

        lock.lock()
        if listener != nil {
            lock.unlock()
            newListener.cancel()
            return
        }
        self.activeKey = loadedKey
        self.listener = newListener
        self._listeningPort = configuredPort
        lock.unlock()

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            switch state {
            case .ready:
                let assigned = newListener.port?.rawValue ?? self.configuredPort
                self.lock.lock()
                if self.listener === newListener {
                    self._listeningPort = assigned
                }
                self.lock.unlock()
            case .failed, .cancelled:
                self.lock.lock()
                if self.listener === newListener {
                    self.listener = nil
                    self._listeningPort = 0
                }
                self.lock.unlock()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }

        newListener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let activeListener = listener
        listener = nil
        _listeningPort = 0

        let hadPendingPairing = !pendingPairingProfilesLocked().isEmpty
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        sessionOrder.removeAll()
        tabUrlsByProfile.removeAll()
        tabUrlPushProfiles.removeAll()

        let pending = pendingRequests
        pendingRequests.removeAll()
        let profilesHandler = _onProfilesChanged
        let pairingHandler = _onPairingStateChanged
        lock.unlock()

        activeListener?.cancel()
        for session in activeSessions {
            session.cancelChallengeTimeout()
            session.connection.cancel()
        }
        for entry in pending.values {
            entry.timeoutTask.cancel()
            entry.continuation.resume(returning: BridgeResponse(
                ok: false,
                error: RPCErrorPayload(
                    code: "EXTENSION_NOT_CONNECTED",
                    message: "Chrome extension bridge stopped"
                )
            ))
        }
        profilesHandler?([])
        if hadPendingPairing {
            pairingHandler?()
        }
    }

    public func connectedProfiles() -> [BrowserProfileStatus] {
        lock.lock()
        defer { lock.unlock() }
        return readySessionsLocked().map(\.status)
    }

    public func cancelActiveCommands(tabId: Int? = nil) {
        lock.lock()
        let targets = readySessionsLocked().map(\.connection)
        lock.unlock()

        let cancelMsg = CancelWireMessage(tabId: tabId)
        for connection in targets {
            sendEncodable(cancelMsg, on: connection)
        }
    }

    // MARK: - Tab Control (the tab indicator)

    // The extension draws a blue border and a pill on a Chrome tab an agent controls while the user can see it (#27).
    // The daemon tells it when that control stops or ends (`tab_control`); the pill's Stop button comes back as
    // `stop_requested`. See docs/BRIDGE-PROTOCOL.md.

    private struct TabControlWireMessage: Encodable {
        let type = "tab_control"
        let state: String
        let keepTabIds: [Int]?

        private enum CodingKeys: String, CodingKey {
            case type
            case state
            case keepTabIds
        }
    }

    private struct StopRequestedPayload: Decodable {
        let tabId: Int?
    }

    private var _onUserStopRequested: (@Sendable (_ profileName: String, _ tabId: Int?) -> Void)?

    /// The user pressed Stop in the pill on a controlled tab. The app handles it like its emergency stop (⌘⇧⎋).
    public var onUserStopRequested: (@Sendable (_ profileName: String, _ tabId: Int?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUserStopRequested
        }
        set {
            lock.lock()
            _onUserStopRequested = newValue
            lock.unlock()
        }
    }

    /// The kill switch or Pause stopped the agent: every controlled tab's pill says "Stopped" for a few seconds.
    public func sendTabControlStopped() {
        broadcastTabControl(TabControlWireMessage(state: "stopped", keepTabIds: nil))
    }

    /// A task completed: the indicator goes away on every tab except those other running tasks still own.
    public func sendTabControlEnded(keepTabIds: [Int]) {
        broadcastTabControl(TabControlWireMessage(state: "ended", keepTabIds: Array(Set(keepTabIds)).sorted()))
    }

    private func broadcastTabControl(_ message: TabControlWireMessage) {
        lock.lock()
        let targets = readySessionsLocked().map(\.connection)
        lock.unlock()
        for connection in targets {
            sendEncodable(message, on: connection)
        }
    }

    private func handleStopRequested(_ payload: StopRequestedPayload?, sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId], session.isReady else {
            lock.unlock()
            return
        }
        let profileName = session.profileName
        let handler = _onUserStopRequested
        lock.unlock()
        handler?(profileName, payload?.tabId)
    }

    public func stopActiveStreams() {
        lock.lock()
        var targets: [NWConnection] = []
        var changed = false
        for session in readySessionsLocked() {
            if session.streamingTabId != nil {
                session.streamingTabId = nil
                session.streamingUrl = nil
                session.streamingTitle = nil
                changed = true
            }
            targets.append(session.connection)
        }
        let snapshot = readySessionsLocked().map(\.status)
        let profilesHandler = _onProfilesChanged
        let stoppedHandler = _onBrowserStreamStopped
        lock.unlock()

        for connection in targets {
            sendEncodable(StopStreamWireCommand(id: UUID().uuidString, tabId: nil), on: connection)
        }
        if changed {
            profilesHandler?(snapshot)
            stoppedHandler?("", nil)
        }
    }

    public func stopStream(profileQuery: String? = nil, tabId: Int? = nil) {
        lock.lock()
        guard let session = resolveSessionLocked(profileQuery: profileQuery) else {
            lock.unlock()
            return
        }
        let connection = session.connection
        let profileName = session.profileName
        var changed = false
        if tabId == nil || session.streamingTabId == tabId {
            if session.streamingTabId != nil {
                session.streamingTabId = nil
                session.streamingUrl = nil
                session.streamingTitle = nil
                changed = true
            }
        }
        let snapshot = readySessionsLocked().map(\.status)
        let profilesHandler = _onProfilesChanged
        let stoppedHandler = _onBrowserStreamStopped
        lock.unlock()

        sendEncodable(StopStreamWireCommand(id: UUID().uuidString, tabId: tabId), on: connection)
        if changed {
            profilesHandler?(snapshot)
            stoppedHandler?(profileName, tabId)
        }
    }

    @discardableResult
    public func focusTab(profileQuery: String? = nil, tabId: Int?) async -> Bool {
        let resp = await sendCommand(profileQuery: profileQuery) { requestId in
            FocusTabWireCommand(id: requestId, tabId: tabId)
        }
        return resp.ok
    }

    public func open(_ params: BrowserOpenParams) async -> BridgeResponse {
        let url = params.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let blocked = await targetRulesPreflight(profile: params.profile, tabId: params.tabId, url: url.isEmpty ? nil : url, checksTab: params.tabId != nil) {
            return blocked
        }
        if let steps = params.steps {
            for step in steps where step.action == .openURL || step.action == .navigate {
                if let blocked = await targetRulesPreflight(profile: params.profile, tabId: nil, url: step.url ?? step.text, checksTab: false) {
                    return blocked
                }
            }
        }
        let hasInlineSteps = !(params.steps?.isEmpty ?? true)
        let timeoutSec: UInt64? = hasInlineSteps ? computeStepsTimeoutSeconds(params.steps ?? []) : nil
        return await sendCommand(
            profileQuery: params.profile,
            timeoutSeconds: timeoutSec,
            sendCancelOnTimeout: hasInlineSteps,
            cancelTabId: params.tabId
        ) { requestId in
            OpenWireCommand(
                id: requestId,
                url: params.url,
                tabId: params.tabId,
                newTab: params.newTab ?? (params.tabId == nil),
                stream: params.stream ?? true,
                activate: params.activate,
                newWindow: params.newWindow,
                steps: params.steps,
                autoDismissOverlays: params.autoDismissOverlays,
                returnDiffOnly: params.returnDiffOnly,
                observationMode: params.observationMode
            )
        }
    }

    private func computeStepsTimeoutSeconds(_ steps: [ActionStep]) -> UInt64 {
        let totalWaitMs: UInt64 = steps.reduce(0) { partial, step in
            guard step.action == .wait, let ms = step.durationMs, ms > 0 else {
                return partial
            }
            let (sum, overflow) = partial.addingReportingOverflow(UInt64(ms))
            return overflow ? UInt64.max : sum
        }
        let waitSeconds: UInt64
        if totalWaitMs == 0 {
            waitSeconds = 0
        } else if totalWaitMs >= Self.maxActTimeoutSeconds * 1000 {
            waitSeconds = Self.maxActTimeoutSeconds
        } else {
            waitSeconds = (totalWaitMs + 999) / 1000
        }
        let base = baseCommandTimeoutSeconds
        let (combined, overflow) = base.addingReportingOverflow(waitSeconds)
        return min(Self.maxActTimeoutSeconds, overflow ? Self.maxActTimeoutSeconds : combined)
    }

    /// Returns the live cached URL for `tabId` in the matched profile when that session pushes `tab_url` events.
    /// Returns nil on cache miss or for older extensions that do not push `tab_url` updates.
    func liveCachedTabURL(profileQuery: String?, tabId: Int) -> (url: String, profileName: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = resolveSessionLocked(profileQuery: profileQuery) else { return nil }
        let key = session.profileName.lowercased()
        guard tabUrlPushProfiles.contains(key),
              let url = tabUrlsByProfile[key]?[tabId] else {
            return nil
        }
        return (url, session.profileName)
    }

    /// Snapshot of cached `tabId -> url` entries for the matched profile (diagnostics & tests).
    func cachedTabURLs(profileQuery: String? = nil) -> [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let session = resolveSessionLocked(profileQuery: profileQuery) else { return [:] }
        return tabUrlsByProfile[session.profileName.lowercased()] ?? [:]
    }

    /// The freshest cached frame for the tab or profile, never one of a page the user's rules block.
    public func latestFrame(profileQuery: String? = nil, tabId: Int? = nil) -> CachedBrowserFrame? {
        guard let frame = cachedFrame(profileQuery: profileQuery, tabId: tabId),
              !Self.targetRulesBlockFrame(url: frame.url) else { return nil }
        return frame
    }

    private func cachedFrame(profileQuery: String?, tabId: Int?) -> CachedBrowserFrame? {
        lock.lock()
        defer { lock.unlock() }
        if let tabId {
            if let profileQuery, !profileQuery.isEmpty {
                let exactKey = "\(profileQuery.lowercased()):\(tabId)"
                if let match = cachedFramesByTab[exactKey] {
                    return match
                }
            }
            if let anyTabMatch = cachedFramesByTab.values.first(where: { $0.tabId == tabId }) {
                return anyTabMatch
            }
        }
        if let profileQuery, !profileQuery.isEmpty {
            let lower = profileQuery.lowercased()
            let matching = cachedFramesByTab.values
                .filter { $0.profileName.lowercased().contains(lower) }
                .sorted { $0.capturedAt > $1.capturedAt }
            if let freshest = matching.first {
                return freshest
            }
        }
        return latestCachedFrame
    }

    /// Closes the tabs UseMac opened itself (never the user's own tabs), keeping `keepTabIds`, the tab the
    /// user is looking at and tabs with a running download. With `closeTabIds`, extensions 0.6+ close only those;
    /// older ones ignore it and go by `keepTabIds`.
    public func closeOwnedTabs(profile: String?, keepTabIds: [Int], closeTabIds: [Int]? = nil) async -> BridgeResponse {
        await sendCommand(profileQuery: profile) { requestId in
            CloseOwnedTabsWireCommand(id: requestId, keepTabIds: keepTabIds, closeTabIds: closeTabIds)
        }
    }

    /// Every tab except those on sites the user's rules block.
    public func tabs(_ params: BrowserTabsParams) async -> BridgeResponse {
        let response = await sendCommand(profileQuery: params.profile) { requestId in
            TabsWireCommand(id: requestId, query: params.query)
        }
        return Self.hidingBlockedTabs(response)
    }

    /// Every tab, blocked ones included: only the rules check reads it, to find the tab a command would run on.
    func unfilteredTabs(profile: String?, timeoutSeconds: UInt64) async -> BridgeResponse {
        await sendCommand(profileQuery: profile, timeoutSeconds: timeoutSeconds) { requestId in
            TabsWireCommand(id: requestId, query: nil)
        }
    }

    public func observe(_ params: BrowserObserveParams) async -> BridgeResponse {
        if let blocked = await targetRulesPreflight(profile: params.profile, tabId: params.tabId) {
            return blocked
        }
        return await sendCommand(profileQuery: params.profile) { requestId in
            ObserveWireCommand(
                id: requestId,
                tabId: params.tabId,
                maxElements: params.maxElements,
                includeText: params.includeText ?? true,
                includeTables: params.includeTables ?? true,
                includeScreenshot: (params.includeScreenshot ?? false) || (params.returnImageContent ?? false),
                filter: params.filter,
                viewportWidth: params.viewportWidth,
                viewportHeight: params.viewportHeight,
                deviceScaleFactor: params.deviceScaleFactor
            )
        }
    }

    public func extract(_ params: BrowserExtractParams) async -> BridgeResponse {
        if let blocked = await targetRulesPreflight(profile: params.profile, tabId: params.tabId) {
            return blocked
        }
        let timeoutSec: UInt64 = (params.scanHorizontal == true || params.scanVertical == true) ? 30 : 18
        return await sendCommand(profileQuery: params.profile, timeoutSeconds: timeoutSec) { requestId in
            ExtractWireCommand(
                id: requestId,
                tabId: params.tabId,
                mode: params.mode,
                selector: params.selector,
                expression: params.expression,
                scanHorizontal: params.scanHorizontal ?? false,
                scanVertical: params.scanVertical,
                urlFilter: params.urlFilter,
                frameIndex: params.frameIndex,
                maxChars: params.maxChars ?? 16000
            )
        }
    }

    public func screenshot(_ params: BrowserScreenshotParams) async -> BridgeResponse {
        if let blocked = await targetRulesPreflight(profile: params.profile, tabId: params.tabId) {
            return blocked
        }
        return await sendCommand(profileQuery: params.profile, timeoutSeconds: 20) { requestId in
            ScreenshotWireCommand(
                id: requestId,
                tabId: params.tabId,
                selector: params.selector,
                elementId: params.elementId,
                fullPage: params.fullPage ?? false,
                viewportWidth: params.viewportWidth,
                viewportHeight: params.viewportHeight,
                deviceScaleFactor: params.deviceScaleFactor,
                quality: params.quality ?? 84
            )
        }
    }

    public func act(_ params: BrowserActParams) async -> BridgeResponse {
        // A batch that opens or navigates to a blocked site never runs, nor one on a tab that is on one.
        for step in params.steps where step.action == .openURL || step.action == .navigate {
            if let blocked = await targetRulesPreflight(profile: params.profile, tabId: nil, url: step.url ?? step.text, checksTab: false) {
                return blocked
            }
        }
        if let blocked = await targetRulesPreflight(profile: params.profile, tabId: params.tabId) {
            return blocked
        }
        let timeoutSec = computeStepsTimeoutSeconds(params.steps)

        return await sendCommand(
            profileQuery: params.profile,
            timeoutSeconds: timeoutSec,
            sendCancelOnTimeout: true,
            cancelTabId: params.tabId
        ) { requestId in
            ActWireCommand(
                id: requestId,
                tabId: params.tabId,
                steps: params.steps,
                stopOnError: params.stopOnError,
                returnObservation: params.returnObservation,
                returnDiffOnly: params.returnDiffOnly,
                includeScreenshot: (params.returnImageContent ?? false) || (params.diffCrop ?? false),
                observationMode: params.observationMode,
                maxElements: params.maxElements,
                includeText: params.includeText,
                includeTables: params.includeTables
            )
        }
    }

    // MARK: - Extension Reload

    public struct ReloadOutcome: Sendable {
        public let ok: Bool
        /// Each reloaded profile as it reconnected (its new extension version).
        public let profiles: [BrowserProfileStatus]
        public let error: RPCErrorPayload?
    }

    /// Makes the extension answer, then call `chrome.runtime.reload()`, so Chrome runs the code now in its folder.
    /// Waits until it has reconnected and paired again. `sessionId` (a `BrowserProfileStatus.id`) or `profile` picks
    /// one profile; with neither, every connected profile reloads. Nothing reloads when a target cannot do it, or,
    /// without `force`, while agents still have Chrome commands running in it.
    public func reloadExtension(
        profile: String? = nil,
        sessionId: String? = nil,
        force: Bool = false,
        reconnectTimeoutSeconds: Double = 15
    ) async -> ReloadOutcome {
        let (plans, waitingForKey) = reloadPlans(profile: profile, sessionId: sessionId)

        func failure(_ code: String, _ message: String) -> ReloadOutcome {
            ReloadOutcome(ok: false, profiles: [], error: RPCErrorPayload(code: code, message: message))
        }

        guard !plans.isEmpty else {
            if waitingForKey && profile == nil && sessionId == nil {
                return failure("EXTENSION_NOT_PAIRED", Self.notPairedMessage)
            }
            return failure("EXTENSION_NOT_CONNECTED", profile.map { "No Chrome extension profile matched '\($0)'" }
                ?? "No Chrome extension is connected.")
        }
        if let old = plans.first(where: { !$0.reloadable }) {
            return failure("EXTENSION_RELOAD_UNSUPPORTED", Self.reloadUnsupportedMessage(profile: old.name, version: old.version))
        }
        if !force, let busy = plans.first(where: { $0.running > 0 }) {
            return failure(
                "BROWSER_BUSY",
                "Agents have \(busy.running) Chrome command(s) running in profile '\(busy.name)'. Reloading the extension would stop them. Wait until they finish, or pass force."
            )
        }

        var reloaded: [BrowserProfileStatus] = []
        for plan in plans {
            let startedAt = Date()
            let resp = await sendCommand(profileQuery: nil, timeoutSeconds: 5, targetSessionId: plan.id) { requestId in
                ReloadExtensionWireCommand(id: requestId)
            }
            // The socket can close before the answer arrives: the extension is already reloading.
            if !resp.ok && resp.error?.code != "EXTENSION_NOT_CONNECTED" {
                if resp.error?.code == "UNKNOWN_COMMAND" {
                    return failure("EXTENSION_RELOAD_UNSUPPORTED", Self.reloadUnsupportedMessage(profile: plan.name, version: plan.version))
                }
                return ReloadOutcome(ok: false, profiles: reloaded, error: RPCErrorPayload(
                    code: resp.error?.code ?? "EXTENSION_ERROR",
                    message: "Profile '\(plan.name)': \(resp.error?.message ?? "the extension did not reload")"
                ))
            }
            guard let status = await waitForReloadedSession(
                profileName: plan.name,
                acceptedAfter: startedAt,
                timeoutSeconds: reconnectTimeoutSeconds
            ) else {
                return ReloadOutcome(ok: false, profiles: reloaded, error: RPCErrorPayload(
                    code: "EXTENSION_RELOAD_TIMEOUT",
                    message: "Chrome reloaded the extension in profile '\(plan.name)', but it did not reconnect within \(Int(reconnectTimeoutSeconds)) s. Open chrome://extensions in that profile and check UseMac Browser Bridge for errors."
                ))
            }
            reloaded.append(status)
        }
        return ReloadOutcome(ok: true, profiles: reloaded, error: nil)
    }

    private struct ReloadPlan {
        let id: String
        let name: String
        let version: String
        let reloadable: Bool
        /// Commands still waiting for this session's answer.
        let running: Int
    }

    private func reloadPlans(profile: String?, sessionId: String?) -> (plans: [ReloadPlan], waitingForKey: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let targets: [ExtensionSession]
        if let sessionId {
            targets = sessions[sessionId].map { $0.isReady ? [$0] : [] } ?? []
        } else if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targets = resolveSessionLocked(profileQuery: profile).map { [$0] } ?? []
        } else {
            targets = readySessionsLocked()
        }
        let plans = targets.map { session in
            ReloadPlan(
                id: session.id,
                name: session.profileName,
                version: session.extensionVersion,
                reloadable: session.health?.reloadable ?? false,
                running: pendingRequests.values.filter { $0.sessionId == session.id }.count
            )
        }
        return (plans, sessions.values.contains { $0.isPairingRequired })
    }

    private static func reloadUnsupportedMessage(profile: String, version: String) -> String {
        "The UseMac extension in Chrome profile '\(profile)' (v\(version)) predates remote reload. Open chrome://extensions in that profile and click the reload button on UseMac Browser Bridge once. After that, UseMac can reload it for you."
    }

    private func waitForReloadedSession(profileName: String, acceptedAfter startedAt: Date, timeoutSeconds: Double) async -> BrowserProfileStatus? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let name = profileName.lowercased()
        while true {
            if let match = readySessionStatus(profileName: name, acceptedAfter: startedAt) { return match }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func readySessionStatus(profileName lowercasedName: String, acceptedAfter startedAt: Date) -> BrowserProfileStatus? {
        lock.lock()
        defer { lock.unlock() }
        return readySessionsLocked().first { $0.acceptedAt >= startedAt && $0.profileName.lowercased() == lowercasedName }?.status
    }

    // MARK: - Connection Management

    private func acceptConnection(_ connection: NWConnection) {
        let sessionId = UUID().uuidString
        let session = ExtensionSession(id: sessionId, connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                let prevPending = self.pendingPairingProfilesLocked()
                var evictedSessions: [ExtensionSession] = []
                if self.sessions[sessionId] == nil {
                    self.sessions[sessionId] = session
                    self.sessionOrder.append(sessionId)

                    var unreadyIds = self.sessionOrder.filter { id in
                        guard let candidate = self.sessions[id] else { return false }
                        return !candidate.isReady
                    }
                    while unreadyIds.count > Self.maxUnreadySessions {
                        let oldestId = unreadyIds.removeFirst()
                        if let evicted = self.sessions.removeValue(forKey: oldestId) {
                            self.sessionOrder.removeAll { $0 == oldestId }
                            evictedSessions.append(evicted)
                        }
                    }
                }
                let pairingChanged = prevPending != self.pendingPairingProfilesLocked()
                let pairingHandler = pairingChanged ? self._onPairingStateChanged : nil
                self.lock.unlock()

                for evicted in evictedSessions {
                    evicted.cancelChallengeTimeout()
                    evicted.connection.cancel()
                }
                pairingHandler?()
                self.receiveNext(on: connection, sessionId: sessionId)
            case .failed(let error):
                self.handleDisconnect(sessionId: sessionId, reason: error.localizedDescription)
            case .cancelled:
                self.handleDisconnect(sessionId: sessionId, reason: "Connection cancelled")
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveNext(on connection: NWConnection, sessionId: String) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.handleDisconnect(sessionId: sessionId, reason: error.localizedDescription)
                return
            }

            let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let wsMeta {
                switch wsMeta.opcode {
                case .close:
                    self.handleDisconnect(sessionId: sessionId, reason: "WebSocket closed")
                    return
                case .ping:
                    self.sendPongFrame(on: connection)
                case .text, .binary, .cont:
                    if let data, !data.isEmpty {
                        self.handleIncomingMessage(data, sessionId: sessionId)
                    }
                case .pong:
                    break
                @unknown default:
                    if let data, !data.isEmpty {
                        self.handleIncomingMessage(data, sessionId: sessionId)
                    }
                }
            } else if let data, !data.isEmpty {
                self.handleIncomingMessage(data, sessionId: sessionId)
            }

            if self.isSessionActive(sessionId) {
                self.receiveNext(on: connection, sessionId: sessionId)
            }
        }
    }

    private func handleDisconnect(sessionId: String, reason: String) {
        lock.lock()
        let prevPending = pendingPairingProfilesLocked()
        let removedSession = sessions.removeValue(forKey: sessionId)
        sessionOrder.removeAll { $0 == sessionId }

        var failedRequests: [PendingRequest] = []
        let keysToRemove = pendingRequests.compactMap { key, value in
            value.sessionId == sessionId ? key : nil
        }
        for key in keysToRemove {
            if let req = pendingRequests.removeValue(forKey: key) {
                failedRequests.append(req)
            }
        }

        let wasReady = removedSession?.isReady ?? false
        let wasStreaming = wasReady && removedSession?.streamingTabId != nil
        let removedTabId = removedSession?.streamingTabId
        let removedProfile = removedSession?.profileName ?? ""
        if wasReady, !removedProfile.isEmpty {
            let profileKey = removedProfile.lowercased()
            let stillHasProfile = readySessionsLocked().contains { $0.profileName.lowercased() == profileKey }
            if !stillHasProfile {
                tabUrlsByProfile.removeValue(forKey: profileKey)
                tabUrlPushProfiles.remove(profileKey)
            }
        }
        let snapshot = readySessionsLocked().map(\.status)
        let pairingChanged = prevPending != pendingPairingProfilesLocked()
        let profilesHandler = wasReady ? _onProfilesChanged : nil
        let pairingHandler = pairingChanged ? _onPairingStateChanged : nil
        let stoppedHandler = _onBrowserStreamStopped
        lock.unlock()

        guard let removedSession else { return }
        removedSession.cancelChallengeTimeout()
        removedSession.connection.cancel()

        for req in failedRequests {
            req.timeoutTask.cancel()
            req.continuation.resume(returning: BridgeResponse(
                ok: false,
                error: RPCErrorPayload(
                    code: "EXTENSION_NOT_CONNECTED",
                    message: "Chrome extension disconnected: \(reason)"
                )
            ))
        }

        if wasStreaming {
            stoppedHandler?(removedProfile, removedTabId)
        }
        profilesHandler?(snapshot)
        pairingHandler?()
    }

    private func expireChallenge(sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId],
              case .challenged = session.authState else {
            lock.unlock()
            return
        }
        sessions.removeValue(forKey: sessionId)
        sessionOrder.removeAll { $0 == sessionId }
        let connection = session.connection
        lock.unlock()

        connection.cancel()
    }

    private func isSessionActive(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId] != nil
    }

    // MARK: - Message Handling

    private func handleIncomingMessage(_ data: Data, sessionId: String) {
        guard let message = try? decoder.decode(IncomingMessage.self, from: data) else {
            return
        }

        switch message {
        case .hello(let payload):
            handleHello(payload, sessionId: sessionId)

        case .auth(let payload):
            handleAuth(payload, sessionId: sessionId)

        case .profileInfo(let payload):
            guard let payload else { return }
            handleProfileInfo(payload, sessionId: sessionId)

        case .ping:
            lock.lock()
            let conn = sessions[sessionId]?.connection
            lock.unlock()
            if let conn {
                sendEncodable(PongWireMessage(), on: conn)
            }

        case .frame(let payload):
            guard let payload else { return }
            handleFrame(payload, sessionId: sessionId)

        case .cursor(let payload):
            guard let payload else { return }
            handleCursor(payload, sessionId: sessionId)

        case .streamStopped(let payload):
            handleStreamStopped(payload, sessionId: sessionId)

        case .stopRequested(let payload):
            handleStopRequested(payload, sessionId: sessionId)

        case .tabUrl(let payload):
            guard let payload else { return }
            handleTabUrl(payload, sessionId: sessionId)

        case .response(let payload):
            guard let payload else { return }
            handleResponse(payload, sessionId: sessionId)

        case .unknown:
            break
        }
    }

    private func handleTabUrl(_ payload: TabUrlPayload, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionId], session.isReady else {
            return
        }
        let profileKey = session.profileName.lowercased()
        tabUrlPushProfiles.insert(profileKey)
        guard let tabId = payload.tabId else { return }
        if payload.removed == true {
            tabUrlsByProfile[profileKey]?.removeValue(forKey: tabId)
        } else {
            let resolved = (payload.url?.isEmpty == false ? payload.url : payload.pendingUrl) ?? ""
            tabUrlsByProfile[profileKey, default: [:]][tabId] = resolved
        }
    }

    private func handleHello(_ payload: HelloPayload?, sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId] else {
            lock.unlock()
            return
        }

        switch session.authState {
        case .ready:
            lock.unlock()
            return
        case .challenged:
            let connection = session.connection
            sessions.removeValue(forKey: sessionId)
            sessionOrder.removeAll { $0 == sessionId }
            lock.unlock()
            session.cancelChallengeTimeout()
            sendAuthFailedAndClose(reason: "bad_hello", on: connection)
            return
        case .awaitingHello, .pairingRequired:
            break
        }

        let prevPending = pendingPairingProfilesLocked()

        guard let payload,
              payload.protocol == 2,
              let clientNonce = payload.clientNonce,
              BridgeAuth.isNonceHex(clientNonce) else {
            let connection = session.connection
            sessions.removeValue(forKey: sessionId)
            sessionOrder.removeAll { $0 == sessionId }
            let pairingChanged = prevPending != pendingPairingProfilesLocked()
            let pairingHandler = pairingChanged ? _onPairingStateChanged : nil
            lock.unlock()
            sendAuthFailedAndClose(reason: "bad_hello", on: connection)
            pairingHandler?()
            return
        }

        if let rawName = payload.profileName {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            session.profileName = trimmed.isEmpty ? "Chrome" : trimmed
        }
        if let version = payload.extensionVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            session.extensionVersion = version
        }
        let helloId = payload.extensionId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reportsId = helloId.map(ChromeExtensionID.isValid) ?? false
        session.extensionId = reportsId ? helloId : originLog.unambiguousId(since: session.acceptedAt)
        session.health = ChromeExtensionHealth.evaluate(
            extensionVersion: session.extensionVersion,
            extensionId: session.extensionId,
            reloadable: reportsId,
            bundled: bundledExtension,
            webStoreId: UseMacDefaults.chromeWebStoreExtensionId
        )

        let connection = session.connection
        let hasKey = payload.hasKey ?? false

        if !hasKey {
            session.authState = .pairingRequired
            let pairingChanged = prevPending != pendingPairingProfilesLocked()
            let pairingHandler = pairingChanged ? _onPairingStateChanged : nil
            lock.unlock()

            sendEncodable(PairingRequiredWireMessage(), on: connection)
            pairingHandler?()
            return
        }

        guard let key = activeKey else {
            sessions.removeValue(forKey: sessionId)
            sessionOrder.removeAll { $0 == sessionId }
            let pairingChanged = prevPending != pendingPairingProfilesLocked()
            let pairingHandler = pairingChanged ? _onPairingStateChanged : nil
            lock.unlock()

            connection.cancel()
            pairingHandler?()
            return
        }

        let serverNonce = BridgeAuth.randomNonceHex()
        let serverProof = BridgeAuth.serverProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        let timeoutSeconds = Self.challengeTimeoutSeconds
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.expireChallenge(sessionId: sessionId)
        }
        session.authState = .challenged(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            timeoutTask: timeoutTask
        )
        let pairingChanged = prevPending != pendingPairingProfilesLocked()
        let pairingHandler = pairingChanged ? _onPairingStateChanged : nil
        lock.unlock()

        sendEncodable(ChallengeWireMessage(serverNonce: serverNonce, serverProof: serverProof), on: connection)
        pairingHandler?()
    }

    private func handleAuth(_ payload: AuthPayload?, sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId] else {
            lock.unlock()
            return
        }

        guard case .challenged(let clientNonce, let serverNonce, let timeoutTask) = session.authState else {
            lock.unlock()
            return
        }

        let connection = session.connection
        guard let key = activeKey,
              let clientProof = payload?.clientProof else {
            sessions.removeValue(forKey: sessionId)
            sessionOrder.removeAll { $0 == sessionId }
            lock.unlock()
            timeoutTask.cancel()
            sendAuthFailedAndClose(reason: "bad_proof", on: connection)
            return
        }

        let expectedProof = BridgeAuth.clientProof(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        guard BridgeAuth.constantTimeEquals(clientProof, expectedProof) else {
            sessions.removeValue(forKey: sessionId)
            sessionOrder.removeAll { $0 == sessionId }
            lock.unlock()
            timeoutTask.cancel()
            sendAuthFailedAndClose(reason: "bad_proof", on: connection)
            return
        }

        session.authState = .ready
        let snapshot = readySessionsLocked().map(\.status)
        let profilesHandler = _onProfilesChanged
        let readyMessage = ReadyWireMessage(extensionStatus: session.health.map {
            ReadyExtensionStatus(source: $0.source.rawValue, bundledVersion: $0.bundledVersion, outdated: $0.outdated, reloadable: $0.reloadable, note: $0.note)
        })
        lock.unlock()

        timeoutTask.cancel()
        sendEncodable(readyMessage, on: connection)
        profilesHandler?(snapshot)
    }

    private func handleProfileInfo(_ payload: ProfileInfoPayload, sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId], session.isReady else {
            lock.unlock()
            return
        }

        var changed = false
        if let rawName = payload.profileName {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmed.isEmpty ? "Chrome" : trimmed
            if session.profileName != resolvedName {
                let oldKey = session.profileName.lowercased()
                let newKey = resolvedName.lowercased()
                if oldKey != newKey {
                    if let existingUrls = tabUrlsByProfile.removeValue(forKey: oldKey) {
                        var merged = tabUrlsByProfile[newKey] ?? [:]
                        for (tid, url) in existingUrls where merged[tid] == nil {
                            merged[tid] = url
                        }
                        tabUrlsByProfile[newKey] = merged
                    }
                    if tabUrlPushProfiles.remove(oldKey) != nil {
                        tabUrlPushProfiles.insert(newKey)
                    }
                }
                session.profileName = resolvedName
                changed = true
            }
        }
        if let count = payload.tabCount {
            let sanitized = max(0, count)
            if session.tabCount != sanitized {
                session.tabCount = sanitized
                changed = true
            }
        }

        let snapshot = changed ? readySessionsLocked().map(\.status) : []
        let profilesHandler = changed ? _onProfilesChanged : nil
        lock.unlock()

        if changed {
            profilesHandler?(snapshot)
        }
    }

    private func handleFrame(_ payload: FramePayload, sessionId: String) {
        guard let b64 = payload.jpegBase64,
              let jpegData = Data(base64Encoded: b64) else {
            return
        }
        // A page the user's rules block is never cached or previewed, and its stream stops.
        if Self.targetRulesBlockFrame(url: payload.url) {
            lock.lock()
            let profileName = sessions[sessionId]?.profileName
            lock.unlock()
            if let profileName {
                stopStream(profileQuery: profileName, tabId: payload.tabId)
            }
            return
        }

        lock.lock()
        guard let session = sessions[sessionId], session.isReady else {
            lock.unlock()
            return
        }
        let changed = session.streamingTabId != payload.tabId
            || session.streamingUrl != payload.url
            || session.streamingTitle != payload.title
        session.streamingTabId = payload.tabId
        session.streamingUrl = payload.url
        session.streamingTitle = payload.title

        let profileName = (payload.profileName?.isEmpty == false ? payload.profileName! : session.profileName)
        let title = payload.title ?? session.streamingTitle ?? ""
        let width = max(1, payload.viewportWidth ?? 1280)
        let height = max(1, payload.viewportHeight ?? 800)

        let cached = CachedBrowserFrame(
            jpegData: jpegData,
            viewportWidth: width,
            viewportHeight: height,
            profileName: profileName,
            tabId: payload.tabId,
            url: payload.url ?? session.streamingUrl,
            title: title,
            capturedAt: Date(),
            showsIndicator: payload.indicator == true
        )
        let frameKey = "\(profileName.lowercased()):\(payload.tabId ?? -1)"
        cachedFramesByTab[frameKey] = cached
        if cachedFramesByTab.count > 12 {
            let oldestKey = cachedFramesByTab.min { $0.value.capturedAt < $1.value.capturedAt }?.key
            if let oldestKey { cachedFramesByTab.removeValue(forKey: oldestKey) }
        }
        latestCachedFrame = cached

        let frameHandler = _onBrowserFrame
        let profilesHandler = changed ? _onProfilesChanged : nil
        let snapshot = changed ? readySessionsLocked().map(\.status) : []
        lock.unlock()

        if changed {
            profilesHandler?(snapshot)
        }
        frameHandler?(payload.tabId, jpegData, width, height, profileName, title)
    }

    private func handleCursor(_ payload: CursorPayload, sessionId: String) {
        guard let x = payload.x, let y = payload.y else { return }
        lock.lock()
        guard let session = sessions[sessionId], session.isReady else {
            lock.unlock()
            return
        }
        let resolvedTabId = payload.tabId ?? session.streamingTabId
        let profileName = session.profileName
        let handler = _onBrowserCursor
        lock.unlock()

        let event = BrowserCursorEvent(
            tabId: resolvedTabId,
            profileName: profileName,
            x: x,
            y: y,
            viewportWidth: payload.viewportWidth ?? 1280,
            viewportHeight: payload.viewportHeight ?? 800,
            phase: payload.phase ?? "move",
            label: payload.label
        )
        handler?(event)
    }

    private func handleStreamStopped(_ payload: StreamStoppedPayload?, sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId], session.isReady else {
            lock.unlock()
            return
        }
        let stoppedTabId = payload?.tabId ?? session.streamingTabId
        let profileName = session.profileName
        if payload?.tabId == nil || session.streamingTabId == payload?.tabId {
            session.streamingTabId = nil
            session.streamingUrl = nil
            session.streamingTitle = nil
        }
        let snapshot = readySessionsLocked().map(\.status)
        let profilesHandler = _onProfilesChanged
        let stoppedHandler = _onBrowserStreamStopped
        let pausedHandler = _onBrowserStreamPaused
        let endedHandler = _onTabStreamEnded
        lock.unlock()

        profilesHandler?(snapshot)
        if let tabId = payload?.tabId {
            endedHandler?(profileName, tabId, payload?.reason)
        }
        let stillOpen = payload?.reason == "idle" || payload?.reason == "evicted"
        if stillOpen, let stoppedTabId, let pausedHandler {
            pausedHandler(profileName, stoppedTabId)
        } else {
            stoppedHandler?(profileName, stoppedTabId)
        }
    }

    private func handleResponse(_ payload: ResponsePayload, sessionId: String) {
        lock.lock()
        guard let session = sessions[sessionId],
              session.isReady,
              pendingRequests[payload.id]?.sessionId == sessionId else {
            lock.unlock()
            return
        }
        let sessionProfileKey = (payload.profileName?.isEmpty == false ? payload.profileName! : session.profileName).lowercased()
        if let listedTabs = payload.tabs {
            var map = tabUrlsByProfile[sessionProfileKey] ?? [:]
            for tab in listedTabs {
                map[tab.tabId] = tab.url
            }
            tabUrlsByProfile[sessionProfileKey] = map
        } else if let respTabId = payload.tabId,
                  let respUrl = payload.url ?? payload.extractResult?.url,
                  !respUrl.isEmpty {
            tabUrlsByProfile[sessionProfileKey, default: [:]][respTabId] = respUrl
        }
        lock.unlock()

        // A result from a page the user's rules block is dropped before its screenshot is written or cached.
        if let blocked = Self.targetRulesResultRefusal(
            url: payload.url ?? payload.extractResult?.url,
            tabId: payload.tabId,
            profileName: payload.profileName
        ) {
            completePendingRequest(id: payload.id, sessionId: sessionId, response: blocked)
            return
        }

        var resolvedSnapshot = payload.snapshot
        var resolvedScreenshot: ScreenshotResult?
        if let b64 = payload.screenshotBase64,
           let jpegData = Data(base64Encoded: b64) {
            let dir = UseMacDefaults.captureDirectory
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let tabSuffix = payload.tabId.map(String.init) ?? "tab"
            let fileName = "browser-\(tabSuffix)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            let path = (dir as NSString).appendingPathComponent(fileName)
            if (try? jpegData.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil {
                resolvedSnapshot?.screenshotPath = path
            }
            let width = payload.screenshotWidth ?? Int(resolvedSnapshot?.pageState?.viewportWidth ?? 1280)
            let height = payload.screenshotHeight ?? Int(resolvedSnapshot?.pageState?.viewportHeight ?? 800)
            resolvedScreenshot = ScreenshotResult(
                path: path,
                mimeType: "image/jpeg",
                width: width,
                height: height,
                byteCount: jpegData.count,
                latencyMs: payload.screenshotLatencyMs ?? resolvedSnapshot?.latencyMs ?? 0,
                base64Data: b64,
                truncated: payload.screenshotTruncated == true ? true : nil
            )
            lock.lock()
            let cached = CachedBrowserFrame(
                jpegData: jpegData,
                viewportWidth: width,
                viewportHeight: height,
                profileName: payload.profileName ?? "Browser",
                tabId: payload.tabId,
                url: payload.url,
                title: payload.title ?? "",
                capturedAt: Date()
            )
            let frameKey = "\(cached.profileName.lowercased()):\(payload.tabId ?? -1)"
            cachedFramesByTab[frameKey] = cached
            latestCachedFrame = cached
            lock.unlock()
        }

        let response = BridgeResponse(
            ok: payload.ok,
            tabId: payload.tabId,
            profileName: payload.profileName,
            url: payload.url,
            title: payload.title,
            tabs: payload.tabs,
            extractResult: payload.extractResult,
            screenshot: resolvedScreenshot,
            snapshot: resolvedSnapshot,
            actionResult: payload.actionResult,
            error: payload.error,
            windowId: payload.windowId,
            restricted: payload.restricted,
            closedTabs: payload.closedTabs,
            keptTabs: payload.keptTabs
        )
        completePendingRequest(id: payload.id, sessionId: sessionId, response: response)
    }

    // MARK: - Profile Matching & Command Dispatch

    private func readySessionsLocked() -> [ExtensionSession] {
        sessionOrder.compactMap { id in
            guard let session = sessions[id], session.isReady else { return nil }
            return session
        }
    }

    private func pendingPairingProfilesLocked() -> [String] {
        sessionOrder.compactMap { id in
            guard let session = sessions[id], session.isPairingRequired else { return nil }
            return session.profileName
        }
    }

    private func resolveSessionLocked(profileQuery: String?) -> ExtensionSession? {
        let ordered = readySessionsLocked()
        guard !ordered.isEmpty else { return nil }

        let trimmed = profileQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = trimmed, !query.isEmpty else {
            return ordered.first
        }

        let lower = query.lowercased()

        // 1. Exact case-insensitive match on profileName
        if let exact = ordered.first(where: { $0.profileName.lowercased() == lower }) {
            return exact
        }

        // 2. Substring match on profileName
        if let partial = ordered.first(where: { $0.profileName.lowercased().contains(lower) }) {
            return partial
        }

        // 3. Fallback if only 1 ready session is connected
        if ordered.count == 1 {
            return ordered.first
        }

        return nil
    }

    private func sendCommand<Command: Encodable>(
        profileQuery: String?,
        timeoutSeconds: UInt64? = nil,
        sendCancelOnTimeout: Bool = false,
        cancelTabId: Int? = nil,
        targetSessionId: String? = nil,
        buildCommand: (String) -> Command
    ) async -> BridgeResponse {
        let requestId = UUID().uuidString
        let command = buildCommand(requestId)

        guard let payloadData = try? encoder.encode(command) else {
            return BridgeResponse(
                ok: false,
                error: RPCErrorPayload(code: "ENCODING_FAILED", message: "Failed to encode browser command")
            )
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            let effectiveTimeout = timeoutSeconds ?? _baseCommandTimeoutSeconds
            let target: ExtensionSession?
            if let targetSessionId {
                target = sessions[targetSessionId].flatMap { $0.isReady ? $0 : nil }
            } else {
                target = resolveSessionLocked(profileQuery: profileQuery)
            }
            guard let session = target else {
                let readyCount = readySessionsLocked().count
                let hasPairingRequired = sessions.values.contains { $0.isPairingRequired }
                let port = _listeningPort == 0 ? configuredPort : _listeningPort
                lock.unlock()

                if readyCount == 0 && hasPairingRequired {
                    continuation.resume(returning: BridgeResponse(
                        ok: false,
                        error: RPCErrorPayload(
                            code: "EXTENSION_NOT_PAIRED",
                            message: Self.notPairedMessage
                        )
                    ))
                    return
                }

                let msg: String
                if readyCount == 0 {
                    msg = "No Chrome extension connected on 127.0.0.1:\(port). Install/load UseMac Browser Bridge in Chrome."
                } else {
                    msg = "No Chrome extension profile matched '\(profileQuery ?? "")'"
                }
                continuation.resume(returning: BridgeResponse(
                    ok: false,
                    error: RPCErrorPayload(code: "EXTENSION_NOT_CONNECTED", message: msg)
                ))
                return
            }

            let connection = session.connection
            let sessionId = session.id
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: effectiveTimeout * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.handleCommandTimeout(
                    requestId: requestId,
                    sessionId: sessionId,
                    timeoutSeconds: effectiveTimeout,
                    sendCancel: sendCancelOnTimeout,
                    cancelTabId: cancelTabId
                )
            }
            pendingRequests[requestId] = PendingRequest(
                sessionId: sessionId,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            lock.unlock()

            sendTextData(payloadData, on: connection)
        }
    }

    private func handleCommandTimeout(
        requestId: String,
        sessionId: String,
        timeoutSeconds: UInt64,
        sendCancel: Bool,
        cancelTabId: Int?
    ) {
        lock.lock()
        let entry = pendingRequests.removeValue(forKey: requestId)
        let cancelConnection: NWConnection?
        if entry != nil && sendCancel, let session = sessions[sessionId], session.isReady {
            cancelConnection = session.connection
        } else {
            cancelConnection = nil
        }
        lock.unlock()

        guard let entry else { return }
        if let cancelConnection {
            sendEncodable(CancelWireMessage(tabId: cancelTabId), on: cancelConnection)
        }
        entry.timeoutTask.cancel()
        entry.continuation.resume(returning: BridgeResponse(
            ok: false,
            error: RPCErrorPayload(
                code: "EXTENSION_TIMEOUT",
                message: "Chrome extension did not respond within \(timeoutSeconds)s"
            )
        ))
    }

    private func completePendingRequest(id: String, sessionId: String, response: BridgeResponse) {
        lock.lock()
        guard pendingRequests[id]?.sessionId == sessionId,
              let entry = pendingRequests.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()

        entry.timeoutTask.cancel()
        entry.continuation.resume(returning: response)
    }

    private func sendAuthFailedAndClose(reason: String, on connection: NWConnection) {
        guard let data = try? encoder.encode(AuthFailedWireMessage(reason: reason)) else {
            connection.cancel()
            return
        }
        let textMetadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let textContext = NWConnection.ContentContext(identifier: "usemac-ws-auth-failed", metadata: [textMetadata])
        connection.send(content: data, contentContext: textContext, isComplete: true, completion: .contentProcessed { _ in
            let closeMetadata = NWProtocolWebSocket.Metadata(opcode: .close)
            closeMetadata.closeCode = .protocolCode(.policyViolation)
            let closeContext = NWConnection.ContentContext(
                identifier: "usemac-ws-close",
                expiration: 0,
                priority: 0.5,
                isFinal: true,
                metadata: [closeMetadata]
            )
            connection.send(content: nil, contentContext: closeContext, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        })
        queue.asyncAfter(deadline: .now() + 2) {
            connection.cancel()
        }
    }

    private func sendEncodable<T: Encodable>(_ value: T, on connection: NWConnection) {
        guard let data = try? encoder.encode(value) else { return }
        sendTextData(data, on: connection)
    }

    private func sendTextData(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "usemac-ws-text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendPongFrame(on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        let context = NWConnection.ContentContext(identifier: "usemac-ws-pong", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
