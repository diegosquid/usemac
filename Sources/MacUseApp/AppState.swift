import AppKit
import Foundation
import Combine
import ImageIO
import SwiftUI
import MacUseProtocol
import MacUseEngine
import MacUseIPC

public struct HUDSessionCard: Identifiable {
    public let id: String
    public var isBrowser: Bool
    public var browserProfile: String?
    public var browserTabId: Int?
    public var browserUrl: String?
    public var appDescriptor: AppDescriptor?
    public var title: String
    public var previewImage: CGImage?
    public var sourceBounds: ScreenRect?
    public var aspectRatio: CGFloat
    public var isBusy: Bool
    public var isCompleted: Bool
    public var caption: LiveActivityItem?
    public var cursorPoint: CGPoint?
    public var cursorLabel: String?
    public var lastActivityDate: Date

    public init(
        id: String,
        isBrowser: Bool,
        browserProfile: String? = nil,
        browserTabId: Int? = nil,
        browserUrl: String? = nil,
        appDescriptor: AppDescriptor? = nil,
        title: String,
        previewImage: CGImage? = nil,
        sourceBounds: ScreenRect? = nil,
        aspectRatio: CGFloat = 268.0 / 172.0,
        isBusy: Bool = false,
        isCompleted: Bool = false,
        caption: LiveActivityItem? = nil,
        cursorPoint: CGPoint? = nil,
        cursorLabel: String? = nil,
        lastActivityDate: Date = Date()
    ) {
        self.id = id
        self.isBrowser = isBrowser
        self.browserProfile = browserProfile
        self.browserTabId = browserTabId
        self.browserUrl = browserUrl
        self.appDescriptor = appDescriptor
        self.title = title
        self.previewImage = previewImage
        self.sourceBounds = sourceBounds
        self.aspectRatio = aspectRatio
        self.isBusy = isBusy
        self.isCompleted = isCompleted
        self.caption = caption
        self.cursorPoint = cursorPoint
        self.cursorLabel = cursorLabel
        self.lastActivityDate = lastActivityDate
    }
}

public struct OverlayPulse: Equatable, Identifiable {
    public let id: UUID
    public let x: Double
    public let y: Double
    public let label: String?

    public init(id: UUID = UUID(), x: Double, y: Double, label: String?) {
        self.id = id
        self.x = x
        self.y = y
        self.label = label
    }
}

@MainActor
public final class AppState: ObservableObject {
    private enum DefaultsKeys {
        static let hudCorner = "macuse.hud.corner"
        static let hudCollapsed = "macuse.hud.collapsed"
        static let autoShowHUDOnActivity = "macuse.hud.autoShowOnActivity"
        static let hudStreamMode = "macuse.hud.streamMode"
        static let hudIsLarge = "macuse.hud.isLarge"
        static let safetyPolicy = "macuse.safety.policy"
        static let safetyPolicyBeforePause = "macuse.safety.policyBeforePause"
        static let safetyKillSwitchTripped = "macuse.safety.killSwitchTripped"
        static let onboardingAgentConnected = "macuse.onboarding.agentConnected"
        static let onboardingDismissed = "macuse.onboarding.dismissed"
    }

    private static let browserFrameDecodeQueue = DispatchQueue(
        label: "com.macuse.app.browser-frame-decode",
        qos: .userInitiated
    )

    public let engine: MacUseEngineService
    public private(set) var server: UnixSocketServer?
    public let videoSink = LiveVideoSink()
    public let updater = UpdateController()

    @Published public var status: DaemonStatus
    @Published public var pairedApp: AppDescriptor?
    @Published public var runningApps: [AppDescriptor] = []
    @Published public var auditEntries: [AuditEntry] = []
    @Published public var isServerRunning: Bool = false
    @Published public var daemonError: String?

    // Chrome Extension bridge state
    @Published public var isBrowserStreamActive: Bool = false
    @Published public var connectedBrowserProfiles: [BrowserProfileStatus] = []
    @Published public var pendingBrowserPairings: [String] = []

    // Global shortcuts state
    @Published public var isOptionSpaceShortcutEnabled: Bool
    @Published public var failedShortcuts: [String] = []

    // Permissions & onboarding state
    @Published public var attemptedAccessibilityGrant: Bool = false
    @Published public var attemptedScreenRecordingGrant: Bool = false
    @Published public var hasEverConnectedAgent: Bool
    @Published public var isOnboardingDismissed: Bool

    // Local Vision Engine state
    @Published public var visionStatus: VisionStatus

    // Live Activity HUD & PiP Stream state
    @Published public var liveActivities: [LiveActivityItem] = []
    @Published public var hudDeck: [HUDSessionCard] = []
    @Published public var isAgentBusy: Bool = false
    @Published public var isActivityIndicatorLit: Bool = false
    @Published public var activeTargetApp: AppDescriptor?
    @Published public var streamStatus: LiveStreamStatus = .idle
    @Published public var hudCorner: HUDCorner
    @Published public var hudStreamMode: HUDStreamMode
    @Published public var isHUDCollapsed: Bool
    @Published public var isHUDLarge: Bool
    @Published public var isHUDVisible: Bool
    @Published public var autoShowHUDOnActivity: Bool
    @Published public var hasCompletedHUDAction: Bool = false
    @Published public var latestCaptionItem: LiveActivityItem?
    public var lastControlTapUptime: TimeInterval = 0

    // Virtual agent cursor & overlay state
    @Published public var highlightedRect: ScreenRect?
    @Published public var highlightLabel: String?
    @Published public var highlightRole: String?
    @Published public var pulsePoint: OverlayPulse?
    @Published public var virtualAgentPoint: CGPoint?
    @Published public var virtualAgentLabel: String?
    @Published public var virtualClickPulseId: UUID?

    // Window / coordination callbacks
    public var onOpenControlCenter: (() -> Void)?
    public var onOpenControlCenterSection: ((ControlCenterSection) -> Void)?
    public var onShowPermissionHelper: ((PermissionKind) -> Void)?
    public var onShowHUD: (() -> Void)?
    public var onHideHUD: (() -> Void)?
    public var onSnapHUDCorner: ((HUDCorner) -> Void)?
    public var onSetOptionSpaceShortcutEnabled: ((Bool) -> Void)?

    private var highlightClearTask: Task<Void, Never>?
    private var pulseClearTask: Task<Void, Never>?
    private var captionClearTask: Task<Void, Never>?
    private var virtualAgentFadeTask: Task<Void, Never>?
    private var virtualAgentMoveTask: Task<Void, Never>?
    private var activityIndicatorHoldTask: Task<Void, Never>?
    private var hudAutoHideTask: Task<Void, Never>?
    private var taskIdleSettleTask: Task<Void, Never>?
    private var isHUDManuallyPinned: Bool = false
    private var isHUDShowingStoppedPill: Bool = false
    private var wasHUDCollapsedBeforeKillSwitch: Bool = false
    private var showingFrozenBrowserFrame: Bool = false
    private var userPromotedLockUntil: Date?
    private var dismissedDuringActiveRun: Bool = false
    private var lastUserDismissDate: Date?
    private var isStreamActive: Bool = false
    private var policyBeforePause: GovernancePolicy?

    public init(socketPath: String = MacUseDefaults.defaultSocketPath) {
        let engineService = MacUseEngineService(socketPath: socketPath)
        let defaults = UserDefaults.standard

        let savedPolicy = defaults.string(forKey: DefaultsKeys.safetyPolicy)
            .flatMap(GovernancePolicy.init(rawValue:))
        let savedBeforePause = defaults.string(forKey: DefaultsKeys.safetyPolicyBeforePause)
            .flatMap(GovernancePolicy.init(rawValue:))
        let savedKillSwitchTripped = defaults.bool(forKey: DefaultsKeys.safetyKillSwitchTripped)

        if let savedPolicy {
            engineService.setGovernancePolicy(savedPolicy)
        }
        if savedKillSwitchTripped {
            engineService.tripKillSwitch(true)
        }

        let resolvedBeforePause: GovernancePolicy?
        if let savedBeforePause, savedBeforePause != .paused {
            resolvedBeforePause = savedBeforePause
        } else if let savedPolicy, savedPolicy != .paused {
            resolvedBeforePause = savedPolicy
        } else {
            resolvedBeforePause = nil
        }

        let savedCorner = defaults.string(forKey: DefaultsKeys.hudCorner)
            .flatMap(HUDCorner.init(rawValue:)) ?? .bottomTrailing
        let savedStreamMode = defaults.string(forKey: DefaultsKeys.hudStreamMode)
            .flatMap(HUDStreamMode.init(rawValue:)) ?? .autoWindow
        let savedLarge = defaults.object(forKey: DefaultsKeys.hudIsLarge) as? Bool ?? false
        let savedAutoShow = defaults.object(forKey: DefaultsKeys.autoShowHUDOnActivity) as? Bool ?? true
        let savedOptionSpace = defaults.object(forKey: HotKeyManager.optionSpaceDefaultsKey) as? Bool ?? true
        let savedAgentConnected = defaults.bool(forKey: DefaultsKeys.onboardingAgentConnected)
        let savedOnboardingDismissed = defaults.bool(forKey: DefaultsKeys.onboardingDismissed)

        self.engine = engineService
        self.policyBeforePause = resolvedBeforePause
        self.status = engineService.currentStatus()
        self.pairedApp = engineService.getPairedApp()
        self.runningApps = engineService.listRunningApps()
        self.auditEntries = engineService.recentAuditEntries(limit: 50)
        self.connectedBrowserProfiles = engineService.chromeBridge.connectedProfiles()
        self.pendingBrowserPairings = engineService.pendingBrowserPairings()
        self.isOptionSpaceShortcutEnabled = savedOptionSpace
        self.hasEverConnectedAgent = savedAgentConnected
        self.isOnboardingDismissed = savedOnboardingDismissed
        self.visionStatus = engineService.localVision.currentStatus()
        self.hudCorner = savedCorner
        self.hudStreamMode = savedStreamMode
        self.isHUDCollapsed = false
        self.isHUDLarge = savedLarge
        self.isHUDVisible = false
        self.autoShowHUDOnActivity = savedAutoShow

        self.server = UnixSocketServer(
            socketPath: socketPath,
            service: engineService,
            onClientCountChange: { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.engine.updateActiveClientCount(count)
                    self.refreshState()
                }
            }
        )

        hookEngineCallbacks()
    }

    public var resolvedCliPath: String {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let helper = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/macuse")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper.path
        }
        let sibling = executableURL.deletingLastPathComponent().appendingPathComponent("macuse")
        if FileManager.default.isExecutableFile(atPath: sibling.path) && sibling.lastPathComponent == "macuse" && sibling.path != executableURL.path {
            return sibling.path
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/macuse") {
            return "/usr/local/bin/macuse"
        }
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/macuse") {
            return "/opt/homebrew/bin/macuse"
        }
        return "macuse"
    }

    public var resolvedAgentDocsDir: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("agent"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundleResources = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/agent")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            return bundleResources.path
        }
        let repoAgents = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agents")
        return repoAgents.path
    }

    public var resolvedChromeExtensionDir: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundleResources = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/chrome-extension")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            return bundleResources.path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Extension")
            .path
    }

    public func revealAgentDocsInFinder() {
        let dirURL = URL(fileURLWithPath: resolvedAgentDocsDir, isDirectory: true)
        let skillURL = dirURL.appendingPathComponent("skills/macuse/SKILL.md")
        if FileManager.default.fileExists(atPath: skillURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([skillURL])
        } else {
            NSWorkspace.shared.open(dirURL)
        }
    }

    public func revealChromeExtensionInFinder() {
        let dirURL = URL(fileURLWithPath: resolvedChromeExtensionDir, isDirectory: true)
        let manifestURL = dirURL.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([manifestURL])
        } else {
            NSWorkspace.shared.open(dirURL)
        }
    }

    public func openChromeExtensionsPage() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? process.run()
    }

    public var chromeWebStoreExtensionId: String? {
        MacUseDefaults.chromeWebStoreExtensionId
    }

    private static func isValidChromeExtensionId(_ extId: String) -> Bool {
        let scalars = extId.unicodeScalars
        guard scalars.count == 32 else { return false }
        return scalars.allSatisfy { scalar in
            scalar.value >= 97 && scalar.value <= 112 // 'a'...'p'
        }
    }

    /// Registers Chrome's official External Extension JSON so Chrome installs the published
    /// Chrome Web Store extension automatically on next launch, and opens its store page.
    @discardableResult
    public func installPublishedChromeExtension() -> Bool {
        guard let extId = chromeWebStoreExtensionId,
              Self.isValidChromeExtensionId(extId) else {
            return false
        }
        let externalDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/External Extensions", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
            let jsonURL = externalDir.appendingPathComponent("\(extId).json")
            let payload = #"{"external_update_url":"https://clients2.google.com/service/update2/crx"}"# + "\n"
            try payload.write(to: jsonURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        if let storeURL = URL(string: "https://chromewebstore.google.com/detail/\(extId)") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Google Chrome", storeURL.absoluteString]
            try? process.run()
        }
        return true
    }

    public func copyBridgePairingKey() -> Bool {
        guard let key = engine.bridgePairingKeyText(), !key.isEmpty else {
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(key, forType: .string)
        return true
    }

    public func confirmAndResetBridgePairingKey() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the pairing key?"
        alert.informativeText = "Every Chrome profile will disconnect until you paste the new key into its extension popup."
        alert.addButton(withTitle: "Reset key")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = engine.resetBridgePairingKey()
            refreshState()
        }
    }

    public func updateShortcutState(optionSpaceEnabled: Bool, failedShortcuts: [String]) {
        self.isOptionSpaceShortcutEnabled = optionSpaceEnabled
        self.failedShortcuts = failedShortcuts
    }

    public func setOptionSpaceShortcutEnabled(_ enabled: Bool) {
        isOptionSpaceShortcutEnabled = enabled
        if let handler = onSetOptionSpaceShortcutEnabled {
            handler(enabled)
        } else {
            UserDefaults.standard.set(enabled, forKey: HotKeyManager.optionSpaceDefaultsKey)
        }
    }

    public var shouldShowOnboarding: Bool {
        if isOnboardingDismissed { return false }
        let perms = status.permissions
        return !(perms.accessibilityGranted && perms.screenRecordingGranted && hasEverConnectedAgent)
    }

    public func dismissOnboarding() {
        isOnboardingDismissed = true
        UserDefaults.standard.set(true, forKey: DefaultsKeys.onboardingDismissed)
    }

    public func relaunchApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func hookEngineCallbacks() {
        engine.onOverlayEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleOverlayEvent(event)
            }
        }
        engine.onStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }
        engine.onLiveActivity = { [weak self] item in
            Task { @MainActor [weak self] in
                self?.handleLiveActivity(item)
            }
        }
        engine.liveStreamer.onFrame = { [weak self] surface, width, height, sourceBounds, sourceName, isWindow in
            Task { @MainActor [weak self] in
                guard let self, !self.isBrowserStreamActive && !self.showingFrozenBrowserFrame else { return }
                self.videoSink.pushFrame(
                    surface: surface,
                    width: width,
                    height: height,
                    sourceBounds: sourceBounds,
                    sourceName: sourceName,
                    isWindow: isWindow
                )
            }
        }
        engine.liveStreamer.onThumbnail = { [weak self] cgImage, pid, appName in
            Task { @MainActor [weak self] in
                guard let self, let idx = self.hudDeck.firstIndex(where: { $0.id == "app:\(pid)" }) else { return }
                self.hudDeck[idx].previewImage = cgImage
                if self.hudDeck[idx].title.isEmpty {
                    self.hudDeck[idx].title = appName
                }
            }
        }
        engine.liveStreamer.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.streamStatus = status
                if case .idle = status, !self.isBrowserStreamActive && !self.showingFrozenBrowserFrame {
                    self.videoSink.reset()
                    if self.hudStreamMode == .autoWindow && !self.isHUDManuallyPinned && !self.isAgentBusy && self.isHUDVisible && !self.hasCompletedHUDAction && self.hudDeck.isEmpty && !self.status.killSwitchTripped {
                        self.hideHUD(userInitiated: false)
                    }
                }
                if case .streaming = status, !self.status.permissions.screenRecordingGranted {
                    self.refreshState()
                }
            }
        }

        engine.chromeBridge.onProfilesChanged = { [weak self] profiles in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectedBrowserProfiles = profiles
                self.refreshState()
            }
        }

        engine.localVision.onStatusChanged = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.visionStatus = status
            }
        }

        let decodeQueue = Self.browserFrameDecodeQueue
        engine.chromeBridge.onBrowserFrame = { [weak self] tabId, jpegData, viewportWidth, viewportHeight, profileName, title in
            decodeQueue.async {
                let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                guard let source = CGImageSourceCreateWithData(jpegData as CFData, options as CFDictionary),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleDecodedBrowserFrame(
                        tabId: tabId,
                        cgImage: cgImage,
                        width: viewportWidth,
                        height: viewportHeight,
                        profileName: profileName,
                        title: title
                    )
                }
            }
        }

        engine.chromeBridge.onBrowserCursor = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let profile = event.profileName ?? self.hudDeck.first(where: { $0.isBrowser })?.browserProfile ?? self.connectedBrowserProfiles.first?.profileName ?? "Chrome"
                let cardId = Self.browserCardId(profile: profile, tabId: event.tabId)
                let label: String?
                switch event.phase {
                case "click":
                    label = event.label ?? "Clicking"
                    self.virtualClickPulseId = UUID()
                case "type":
                    label = "Typing…"
                case "scroll":
                    label = "Scrolling"
                default:
                    label = event.label
                }
                let pt = CGPoint(x: event.x, y: event.y)
                self.upsertHUDCard(
                    id: cardId,
                    isBrowser: true,
                    browserProfile: profile,
                    browserTabId: event.tabId,
                    title: self.hudDeck.first(where: { $0.id == cardId })?.title ?? "Chrome (\(profile))",
                    cursorPoint: pt,
                    cursorLabel: label,
                    promote: true
                )
                if self.hudDeck.first?.id == cardId {
                    self.virtualAgentMoveTask?.cancel()
                    self.virtualAgentPoint = pt
                    self.virtualAgentLabel = label
                }
                self.scheduleVirtualAgentFade()
            }
        }

        engine.chromeBridge.onBrowserStreamStopped = { [weak self] profileName, tabId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let tabId {
                    let resolvedProfile = profileName.isEmpty
                        ? (self.hudDeck.first(where: { $0.isBrowser && $0.browserTabId == tabId })?.browserProfile ?? self.connectedBrowserProfiles.first?.profileName ?? "Chrome")
                        : profileName
                    let cardId = Self.browserCardId(profile: resolvedProfile, tabId: tabId)
                    // Keep the sole card briefly only while displaying its frosted completion overlay
                    let preservingCompletion = self.hasCompletedHUDAction && self.hudDeck.count == 1 && (self.hudDeck.first?.id == cardId || self.hudDeck.first?.browserTabId == tabId)
                    if !preservingCompletion {
                        let beforeCount = self.hudDeck.count
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            self.hudDeck.removeAll { $0.id == cardId || ($0.isBrowser && $0.browserTabId == tabId) }
                        }
                        if self.hudDeck.count != beforeCount {
                            if self.hudDeck.isEmpty {
                                self.isBrowserStreamActive = false
                                self.showingFrozenBrowserFrame = false
                                if !self.isHUDManuallyPinned && self.isHUDVisible && !self.hasCompletedHUDAction && !self.status.killSwitchTripped {
                                    self.hideHUD(userInitiated: false)
                                }
                            } else {
                                self.syncFrontCardToUI()
                            }
                            return
                        }
                    }
                }
                self.isBrowserStreamActive = self.hudDeck.contains { $0.isBrowser && $0.isBusy }
                if !self.showingFrozenBrowserFrame {
                    self.syncLiveStream()
                }
            }
        }
    }

    private static func browserCardId(profile: String, tabId: Int?) -> String {
        if let tabId {
            return "browser:\(profile):\(tabId)"
        }
        return "browser:\(profile)"
    }

    private func handleDecodedBrowserFrame(
        tabId: Int?,
        cgImage: CGImage,
        width: Int,
        height: Int,
        profileName: String,
        title: String
    ) {
        let cardId = Self.browserCardId(profile: profileName, tabId: tabId)
        let displayTitle = title.isEmpty ? "Chrome (\(profileName))" : title
        let bounds = ScreenRect(x: 0, y: 0, width: Double(width), height: Double(height))
        let aspect = width > 0 && height > 0 ? min(max(CGFloat(width) / CGFloat(height), 0.62), 2.15) : (268.0 / 172.0)

        // Attach to pending placeholder card for same profile without tabId yet, if any
        if let tabId,
           let pendingIdx = hudDeck.firstIndex(where: { $0.isBrowser && $0.browserTabId == nil && $0.browserProfile?.caseInsensitiveCompare(profileName) == .orderedSame }) {
            let existing = hudDeck[pendingIdx]
            hudDeck[pendingIdx] = HUDSessionCard(
                id: cardId,
                isBrowser: true,
                browserProfile: profileName,
                browserTabId: tabId,
                browserUrl: existing.browserUrl,
                title: displayTitle,
                previewImage: cgImage,
                sourceBounds: bounds,
                aspectRatio: aspect,
                isBusy: existing.isBusy,
                isCompleted: existing.isCompleted,
                caption: existing.caption,
                cursorPoint: existing.cursorPoint,
                cursorLabel: existing.cursorLabel,
                lastActivityDate: Date()
            )
        } else {
            let isNew = !hudDeck.contains(where: { $0.id == cardId })
            upsertHUDCard(
                id: cardId,
                isBrowser: true,
                browserProfile: profileName,
                browserTabId: tabId,
                title: displayTitle,
                previewImage: cgImage,
                sourceBounds: bounds,
                aspectRatio: aspect,
                isBusy: isNew ? (!status.killSwitchTripped) : nil,
                promote: isNew
            )
        }

        if hudDeck.first?.id == cardId {
            showingFrozenBrowserFrame = true
            if !isBrowserStreamActive {
                isBrowserStreamActive = true
                syncLiveStream()
            }
            videoSink.pushCGImage(
                cgImage,
                width: width,
                height: height,
                sourceBounds: bounds,
                sourceName: displayTitle
            )
        }

        if autoShowHUDOnActivity && !isHUDVisible && !engine.isKillSwitchTripped() && status.policy != .paused {
            showHUD(manual: false)
        }
        pulseActivityIndicator()
    }

    public func startDaemon() {
        guard let server else { return }
        if !server.isRunning {
            do {
                try server.start()
                daemonError = nil
            } catch {
                daemonError = error.localizedDescription
            }
        } else {
            daemonError = nil
        }
        engine.chromeBridge.start()
        isServerRunning = server.isRunning
        refreshState()
        syncLiveStream()
    }

    public func stopDaemon() {
        isAgentBusy = false
        isBrowserStreamActive = false
        if !isHUDManuallyPinned && isHUDVisible {
            hideHUD(userInitiated: false)
        }
        engine.chromeBridge.stop()
        server?.stop()
        isServerRunning = server?.isRunning ?? false
        syncLiveStream()
        clearOverlay()
    }

    public func refreshState() {
        let previousPolicy = status.policy
        let newStatus = engine.currentStatus()
        if newStatus.policy != previousPolicy {
            persistSafetyPolicy(newStatus.policy, previous: previousPolicy)
        }
        status = newStatus
        pairedApp = engine.getPairedApp()
        runningApps = engine.listRunningApps()
        auditEntries = engine.recentAuditEntries(limit: 50)
        connectedBrowserProfiles = engine.chromeBridge.connectedProfiles()
        pendingBrowserPairings = engine.pendingBrowserPairings()
        isServerRunning = server?.isRunning ?? false
        if !hasEverConnectedAgent && (newStatus.telemetry.activeClients > 0 || newStatus.telemetry.totalRequests > 0) {
            hasEverConnectedAgent = true
            UserDefaults.standard.set(true, forKey: DefaultsKeys.onboardingAgentConnected)
        }
    }

    private func persistSafetyPolicy(_ policy: GovernancePolicy, previous: GovernancePolicy) {
        let defaults = UserDefaults.standard
        if policy != .paused {
            policyBeforePause = policy
            defaults.set(policy.rawValue, forKey: DefaultsKeys.safetyPolicyBeforePause)
        } else if previous != .paused {
            policyBeforePause = previous
            defaults.set(previous.rawValue, forKey: DefaultsKeys.safetyPolicyBeforePause)
        }
        defaults.set(policy.rawValue, forKey: DefaultsKeys.safetyPolicy)
    }

    public func refreshPermissions(promptAccessibility: Bool = false) {
        _ = engine.currentPermissions(promptAccessibility: promptAccessibility)
        refreshState()
    }

    public func requestScreenRecording() {
        _ = engine.requestScreenRecordingPermission()
        refreshState()
    }

    public func openAccessibilitySettings() {
        engine.openAccessibilitySettings()
    }

    public func openScreenRecordingSettings() {
        engine.openScreenRecordingSettings()
    }

    public func triggerPermissionFlow(for kind: PermissionKind, prompt: Bool) {
        switch kind {
        case .accessibility:
            attemptedAccessibilityGrant = true
            if prompt {
                refreshPermissions(promptAccessibility: true)
            } else {
                refreshPermissions(promptAccessibility: false)
            }
            openAccessibilitySettings()
            if !status.permissions.accessibilityGranted {
                onShowPermissionHelper?(.accessibility)
            }

        case .screenRecording:
            attemptedScreenRecordingGrant = true
            if prompt {
                requestScreenRecording()
            } else {
                refreshPermissions(promptAccessibility: false)
            }
            openScreenRecordingSettings()
            if !status.permissions.screenRecordingGranted {
                onShowPermissionHelper?(.screenRecording)
            }
        }
    }

    public func resetStalePermissions() {
        let perms = engine.currentPermissions(promptAccessibility: false)
        let resetAccessibility = !perms.accessibilityGranted
        let resetScreenRecording = !perms.screenRecordingGranted
        guard resetAccessibility || resetScreenRecording else {
            refreshState()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset permission entries?"
        alert.informativeText = "usemac will be removed from the missing permission lists in System Settings so you can add it again."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            if resetAccessibility {
                _ = engine.resetAccessibilityPermissionEntry()
            }
            if resetScreenRecording {
                _ = engine.resetScreenRecordingPermissionEntry()
            }
            await MainActor.run { [weak self] in
                self?.refreshPermissions(promptAccessibility: false)
            }
        }
    }

    public func setPolicy(_ policy: GovernancePolicy) {
        let previous = engine.getGovernancePolicy()
        persistSafetyPolicy(policy, previous: previous)
        engine.setGovernancePolicy(policy)
        if policy == .paused {
            isAgentBusy = false
            clearActivityIndicator()
            scheduleCaptionClearIfIdle()
            if !isHUDManuallyPinned && isHUDVisible && !engine.isKillSwitchTripped() {
                hideHUD(userInitiated: false)
            }
        }
        refreshState()
    }

    public func setKillSwitch(_ tripped: Bool) {
        UserDefaults.standard.set(tripped, forKey: DefaultsKeys.safetyKillSwitchTripped)
        engine.tripKillSwitch(tripped)
        if tripped {
            hudAutoHideTask?.cancel()
            hudAutoHideTask = nil
            taskIdleSettleTask?.cancel()
            taskIdleSettleTask = nil
            isAgentBusy = false
            isBrowserStreamActive = false
            showingFrozenBrowserFrame = false
            hasCompletedHUDAction = false
            clearActivityIndicator()
            scheduleCaptionClearIfIdle()
            clearOverlay()
            if !isHUDShowingStoppedPill {
                wasHUDCollapsedBeforeKillSwitch = isHUDCollapsed
            }
            hudDeck.removeAll()
            isHUDShowingStoppedPill = true
            isHUDCollapsed = true
            isHUDVisible = true
            refreshState()
            onShowHUD?()
            syncLiveStream()
        } else {
            refreshState()
            if isHUDShowingStoppedPill {
                isHUDShowingStoppedPill = false
                if isHUDManuallyPinned {
                    isHUDCollapsed = wasHUDCollapsedBeforeKillSwitch
                    syncLiveStream()
                } else {
                    hideHUD(userInitiated: false)
                }
            }
        }
    }

    public var isAutomationPaused: Bool {
        status.killSwitchTripped || status.policy == .paused
    }

    public func toggleKillSwitch() {
        if isAutomationPaused {
            if engine.isKillSwitchTripped() {
                setKillSwitch(false)
            }
            let current = engine.getGovernancePolicy()
            if current == .paused {
                let restored = GovernanceResume.policyAfterResume(
                    current: current,
                    beforePause: policyBeforePause
                )
                setPolicy(restored)
            }
        } else {
            setKillSwitch(true)
        }
    }

    public func pairApp(_ query: String?) {
        pairedApp = engine.setPairedApp(query)
        refreshState()
        syncLiveStream()
    }

    @discardableResult
    public func captureFrontmostExternalApp() -> AppDescriptor? {
        let app = engine.captureFrontmostExternalApp()
        refreshState()
        return app
    }

    // MARK: - Live Activity HUD Controls

    public func markControlTap() {
        lastControlTapUptime = ProcessInfo.processInfo.systemUptime
    }

    public func showHUD(manual: Bool = true) {
        hudAutoHideTask?.cancel()
        hudAutoHideTask = nil
        dismissedDuringActiveRun = false

        if status.killSwitchTripped {
            isHUDShowingStoppedPill = true
            isHUDCollapsed = true
            isHUDVisible = true
            onShowHUD?()
            syncLiveStream()
            return
        }

        if manual {
            if hudStreamMode == .autoWindow && pairedApp == nil && activeTargetApp == nil && !isBrowserStreamActive && hudDeck.isEmpty {
                activeTargetApp = engine.captureFrontmostExternalApp()
            }
            guard hudStreamMode == .fullDisplay || pairedApp != nil || activeTargetApp != nil || isBrowserStreamActive || !hudDeck.isEmpty else {
                return
            }
            isHUDManuallyPinned = true
        }

        isHUDVisible = true
        onShowHUD?()
        syncLiveStream()
    }

    public func hideHUD(userInitiated: Bool = true) {
        hudAutoHideTask?.cancel()
        hudAutoHideTask = nil
        isHUDManuallyPinned = false
        isHUDShowingStoppedPill = false
        showingFrozenBrowserFrame = false
        hasCompletedHUDAction = false
        isBrowserStreamActive = false
        if userInitiated {
            dismissedDuringActiveRun = isAgentBusy
            lastUserDismissDate = Date()
        }
        engine.chromeBridge.stopActiveStreams()
        hudDeck.removeAll()
        isHUDVisible = false
        isHUDCollapsed = false
        onHideHUD?()
        videoSink.reset()
        syncLiveStream()
    }

    public func promoteHUDCard(id: String) {
        markControlTap()
        guard let idx = hudDeck.firstIndex(where: { $0.id == id }) else { return }
        userPromotedLockUntil = Date().addingTimeInterval(8.0)
        if idx > 0 {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                let card = hudDeck.remove(at: idx)
                hudDeck.insert(card, at: 0)
            }
        }
        syncFrontCardToUI()
    }

    public func dismissFrontHUDCard() {
        markControlTap()
        guard !hudDeck.isEmpty else {
            hideHUD(userInitiated: true)
            return
        }
        let removed: HUDSessionCard = withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            hudDeck.removeFirst()
        }
        if removed.isBrowser {
            engine.chromeBridge.stopStream(profileQuery: removed.browserProfile, tabId: removed.browserTabId)
        }
        if hudDeck.isEmpty {
            hideHUD(userInitiated: true)
        } else {
            syncFrontCardToUI()
        }
    }

    public func dismissAllHUDCards() {
        markControlTap()
        hideHUD(userInitiated: true)
    }

    public func activateFrontHUDTarget(dismissAfter: Bool = true) {
        guard isHUDVisible else { return }
        if let front = hudDeck.first {
            if front.isBrowser {
                let profile = front.browserProfile
                let tabId = front.browserTabId
                let url = front.browserUrl
                let title = front.title
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let focusedByExt = await self.engine.chromeBridge.focusTab(profileQuery: profile, tabId: tabId)
                    if focusedByExt {
                        NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
                            .first?
                            .activate(options: [])
                        // Re-focus once Chrome is active so macOS raises the exact window & tab across Spaces.
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        _ = await self.engine.chromeBridge.focusTab(profileQuery: profile, tabId: tabId)
                    } else {
                        let focusedByScript = await Task.detached(priority: .userInitiated) {
                            Self.focusChromeTabViaAppleScript(tabId: tabId, url: url, title: title)
                        }.value
                        if !focusedByScript {
                            NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
                                .first?
                                .activate(options: [])
                        }
                    }
                    if dismissAfter {
                        self.dismissFrontHUDCard()
                    }
                }
                return
            }
            if let pid = front.appDescriptor?.pid ?? activeTargetApp?.pid,
               let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
                if dismissAfter {
                    dismissFrontHUDCard()
                }
                return
            }
        }
        if let pid = pairedApp?.pid ?? activeTargetApp?.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            if dismissAfter {
                dismissFrontHUDCard()
            }
        }
    }

    private nonisolated static func focusChromeTabViaAppleScript(tabId: Int?, url: String?, title: String?) -> Bool {
        let script = """
        on run argv
            set targetTabId to item 1 of argv
            set targetUrl to item 2 of argv
            set targetTitle to item 3 of argv
            tell application "Google Chrome"
                if targetTabId is not "" then
                    set targetIdNum to targetTabId as integer
                    repeat with w in windows
                        set tabIndex to 0
                        repeat with t in tabs of w
                            set tabIndex to tabIndex + 1
                            if (id of t as integer) is targetIdNum then
                                set active tab index of w to tabIndex
                                if minimized of w then set minimized of w to false
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end if
                if targetUrl is not "" then
                    repeat with w in windows
                        set tabIndex to 0
                        repeat with t in tabs of w
                            set tabIndex to tabIndex + 1
                            if (URL of t as text) is targetUrl or ((URL of t as text) starts with targetUrl) then
                                set active tab index of w to tabIndex
                                if minimized of w then set minimized of w to false
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end if
                if targetTitle is not "" then
                    repeat with w in windows
                        set tabIndex to 0
                        repeat with t in tabs of w
                            set tabIndex to tabIndex + 1
                            if (title of t as text) contains targetTitle then
                                set active tab index of w to tabIndex
                                if minimized of w then set minimized of w to false
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end if
            end tell
            return "not_found"
        end run
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = [
            "-e", script,
            tabId.map(String.init) ?? "",
            url ?? "",
            title ?? ""
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return false }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output == "ok"
        } catch {
            return false
        }
    }

    private func upsertHUDCard(
        id: String,
        isBrowser: Bool,
        browserProfile: String? = nil,
        browserTabId: Int? = nil,
        browserUrl: String? = nil,
        appDescriptor: AppDescriptor? = nil,
        title: String? = nil,
        previewImage: CGImage? = nil,
        sourceBounds: ScreenRect? = nil,
        aspectRatio: CGFloat? = nil,
        isBusy: Bool? = nil,
        isCompleted: Bool? = nil,
        caption: LiveActivityItem? = nil,
        cursorPoint: CGPoint? = nil,
        cursorLabel: String? = nil,
        promote: Bool
    ) {
        let canPromote = promote && (userPromotedLockUntil.map { Date() >= $0 } ?? true)
        if let existingIdx = hudDeck.firstIndex(where: { $0.id == id }) {
            var card = hudDeck[existingIdx]
            if let browserProfile { card.browserProfile = browserProfile }
            if let browserTabId { card.browserTabId = browserTabId }
            if let browserUrl, !browserUrl.isEmpty { card.browserUrl = browserUrl }
            if let appDescriptor { card.appDescriptor = appDescriptor }
            if let title, !title.isEmpty { card.title = title }
            if let previewImage { card.previewImage = previewImage }
            if let sourceBounds { card.sourceBounds = sourceBounds }
            if let aspectRatio { card.aspectRatio = aspectRatio }
            if let isBusy { card.isBusy = isBusy }
            if let isCompleted { card.isCompleted = isCompleted }
            if let caption { card.caption = caption }
            if let cursorPoint { card.cursorPoint = cursorPoint }
            if let cursorLabel { card.cursorLabel = cursorLabel }
            card.lastActivityDate = Date()

            if canPromote && existingIdx > 0 {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    hudDeck.remove(at: existingIdx)
                    hudDeck.insert(card, at: 0)
                }
                syncFrontCardToUI()
            } else {
                hudDeck[existingIdx] = card
            }
        } else if isBrowser,
                  let browserTabId,
                  let pendingIdx = hudDeck.firstIndex(where: { card in
                      card.isBrowser && card.browserTabId == nil && (
                          browserProfile == nil ||
                          card.browserProfile == nil ||
                          card.browserProfile?.caseInsensitiveCompare("Browser") == .orderedSame ||
                          card.browserProfile?.caseInsensitiveCompare(browserProfile!) == .orderedSame
                      )
                  }) {
            let existing = hudDeck[pendingIdx]
            let upgraded = HUDSessionCard(
                id: id,
                isBrowser: true,
                browserProfile: browserProfile ?? existing.browserProfile,
                browserTabId: browserTabId,
                browserUrl: (browserUrl?.isEmpty == false) ? browserUrl : existing.browserUrl,
                appDescriptor: appDescriptor ?? existing.appDescriptor,
                title: (title?.isEmpty == false) ? title! : existing.title,
                previewImage: previewImage ?? existing.previewImage,
                sourceBounds: sourceBounds ?? existing.sourceBounds,
                aspectRatio: aspectRatio ?? existing.aspectRatio,
                isBusy: isBusy ?? existing.isBusy,
                isCompleted: isCompleted ?? existing.isCompleted,
                caption: caption ?? existing.caption,
                cursorPoint: cursorPoint ?? existing.cursorPoint,
                cursorLabel: cursorLabel ?? existing.cursorLabel,
                lastActivityDate: Date()
            )
            if canPromote && pendingIdx > 0 {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    hudDeck.remove(at: pendingIdx)
                    hudDeck.insert(upgraded, at: 0)
                }
                syncFrontCardToUI()
            } else {
                hudDeck[pendingIdx] = upgraded
                if pendingIdx == 0 {
                    syncFrontCardToUI()
                }
            }
        } else {
            let newCard = HUDSessionCard(
                id: id,
                isBrowser: isBrowser,
                browserProfile: browserProfile,
                browserTabId: browserTabId,
                browserUrl: browserUrl,
                appDescriptor: appDescriptor,
                title: (title?.isEmpty == false) ? title! : (browserProfile.map { "Chrome (\($0))" } ?? appDescriptor?.name ?? "Agent"),
                previewImage: previewImage,
                sourceBounds: sourceBounds,
                aspectRatio: aspectRatio ?? (268.0 / 172.0),
                isBusy: isBusy ?? false,
                isCompleted: isCompleted ?? false,
                caption: caption,
                cursorPoint: cursorPoint,
                cursorLabel: cursorLabel,
                lastActivityDate: Date()
            )
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                hudDeck.insert(newCard, at: 0)
                if hudDeck.count > 6 {
                    hudDeck.removeLast(hudDeck.count - 6)
                }
            }
            syncFrontCardToUI()
        }
    }

    private func syncFrontCardToUI() {
        guard let front = hudDeck.first else {
            showingFrozenBrowserFrame = false
            isBrowserStreamActive = false
            isAgentBusy = false
            hasCompletedHUDAction = false
            return
        }

        isAgentBusy = front.isBusy
        hasCompletedHUDAction = front.isCompleted && !status.killSwitchTripped
        latestCaptionItem = front.caption
        virtualAgentPoint = front.cursorPoint
        virtualAgentLabel = front.cursorLabel

        if front.isBrowser {
            showingFrozenBrowserFrame = true
            isBrowserStreamActive = front.isBusy || isBrowserStreamActive
            syncLiveStream()
            if let cgImage = front.previewImage {
                let w = Int(front.sourceBounds?.width ?? 1280)
                let h = Int(front.sourceBounds?.height ?? 800)
                videoSink.pushCGImage(
                    cgImage,
                    width: max(1, w),
                    height: max(1, h),
                    sourceBounds: front.sourceBounds,
                    sourceName: front.title
                )
            }
        } else {
            showingFrozenBrowserFrame = false
            isBrowserStreamActive = false
            if let app = front.appDescriptor {
                activeTargetApp = app
            }
            if let cgImage = front.previewImage {
                let w = cgImage.width
                let h = cgImage.height
                videoSink.pushCGImage(
                    cgImage,
                    width: max(1, w),
                    height: max(1, h),
                    sourceBounds: front.appDescriptor?.windowBounds ?? front.sourceBounds,
                    sourceName: front.title
                )
            }
            syncLiveStream()
        }
    }

    public func toggleHUD() {
        if isHUDVisible {
            hideHUD(userInitiated: true)
        } else {
            showHUD(manual: true)
        }
    }

    public func setHUDCorner(_ corner: HUDCorner, snapWindow: Bool = true) {
        hudCorner = corner
        UserDefaults.standard.set(corner.rawValue, forKey: DefaultsKeys.hudCorner)
        if snapWindow {
            onSnapHUDCorner?(corner)
        }
    }

    public func setHUDCollapsed(_ collapsed: Bool) {
        isHUDCollapsed = collapsed
        UserDefaults.standard.set(collapsed, forKey: DefaultsKeys.hudCollapsed)
        syncLiveStream()
    }

    public func toggleHUDCollapsed() {
        setHUDCollapsed(!isHUDCollapsed)
    }

    public func setHUDStreamMode(_ mode: HUDStreamMode) {
        hudStreamMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKeys.hudStreamMode)
        syncLiveStream()
    }

    public func toggleHUDStreamMode() {
        setHUDStreamMode(hudStreamMode == .autoWindow ? .fullDisplay : .autoWindow)
    }

    public func setHUDLarge(_ large: Bool) {
        isHUDLarge = large
        UserDefaults.standard.set(large, forKey: DefaultsKeys.hudIsLarge)
    }

    public func toggleHUDLarge() {
        setHUDLarge(!isHUDLarge)
    }

    public func setAutoShowHUDOnActivity(_ enabled: Bool) {
        autoShowHUDOnActivity = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.autoShowHUDOnActivity)
        if !enabled && isHUDVisible && !isHUDManuallyPinned && !status.killSwitchTripped {
            hideHUD(userInitiated: false)
        }
    }

    public func setLocalVisionEnabled(_ enabled: Bool) {
        engine.localVision.setEnabled(enabled)
        visionStatus = engine.localVision.currentStatus()
    }

    public func selectLocalVisionModel(_ preset: LocalVisionModelPreset) {
        engine.localVision.setModelId(preset.rawValue)
        visionStatus = engine.localVision.currentStatus()
    }

    public func installLocalVision() {
        let modelId = visionStatus.modelId
        Task { @MainActor [weak self] in
            guard let self else { return }
            let updated = await self.engine.localVision.install(modelId: modelId, enable: true)
            self.visionStatus = updated
        }
    }

    private func scheduleCompletionAutoClose(delaySeconds: Double = 1.85) {
        hudAutoHideTask?.cancel()
        hudAutoHideTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(0.2, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            guard !self.isHUDManuallyPinned else { return }

            // Remove completed cards while preserving any other parallel card still actively working
            let remainingActive = self.hudDeck.filter { $0.isBusy }
            if remainingActive.isEmpty {
                if !self.isAgentBusy && self.isHUDVisible && !self.status.killSwitchTripped {
                    self.hideHUD(userInitiated: false)
                }
            } else {
                let finishedBrowserCards = self.hudDeck.filter { !$0.isBusy && $0.isBrowser }
                for card in finishedBrowserCards {
                    self.engine.chromeBridge.stopStream(profileQuery: card.browserProfile, tabId: card.browserTabId)
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    self.hudDeck = remainingActive
                }
                self.syncFrontCardToUI()
            }
        }
    }

    private func scheduleTaskIdleSettle() {
        taskIdleSettleTask?.cancel()
        taskIdleSettleTask = Task { @MainActor [weak self] in
            // Generous 5-minute anti-zombie failsafe: never close or fake completion while an LLM
            // is thinking between steps; only quietly clean up if an agent crashes/forgets task_complete.
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.isHUDManuallyPinned else { return }
            self.isAgentBusy = false
            self.hasCompletedHUDAction = false
            if self.isHUDVisible && !self.status.killSwitchTripped {
                self.hideHUD(userInitiated: false)
            }
        }
    }

    public func clearLiveActivities() {
        captionClearTask?.cancel()
        captionClearTask = nil
        liveActivities.removeAll()
        latestCaptionItem = nil
        clearOverlay()
    }

    public func openControlCenter() {
        onOpenControlCenter?()
    }

    public func syncLiveStream() {
        if isBrowserStreamActive || showingFrozenBrowserFrame {
            if isStreamActive {
                isStreamActive = false
                engine.liveStreamer.stop()
            }
            return
        }

        let shouldStream = isServerRunning && isHUDVisible && !isHUDCollapsed
        let target = pairedApp ?? activeTargetApp
        if shouldStream {
            if isStreamActive {
                engine.liveStreamer.updateTarget(mode: hudStreamMode, targetApp: target)
            } else {
                isStreamActive = true
                engine.liveStreamer.start(mode: hudStreamMode, targetApp: target)
            }
        } else if isStreamActive {
            isStreamActive = false
            engine.liveStreamer.stop()
            videoSink.reset()
        }
    }

    // MARK: - Live Activity Stream Handling

    private func handleLiveActivity(_ item: LiveActivityItem) {
        liveActivities.append(item)
        if liveActivities.count > 80 {
            liveActivities.removeFirst(liveActivities.count - 80)
        }

        switch item.kind {
        case .taskStart:
            if !engine.isKillSwitchTripped() && status.policy != .paused {
                // Explicit task session start: open preview once and keep it steady across all iterations
                // until explicit task_complete is called.
                isAgentBusy = true
                hasCompletedHUDAction = false
                isHUDManuallyPinned = false
                dismissedDuringActiveRun = false
                lastUserDismissDate = nil
                hudAutoHideTask?.cancel()
                hudAutoHideTask = nil
                scheduleTaskIdleSettle()
                pulseActivityIndicator()
            }
        case .actionStart, .actionStep, .actionComplete, .observe, .screenshot:
            if !engine.isKillSwitchTripped() && status.policy != .paused {
                // Keep steady calm active rim across multi-step LLM turns until explicit task_complete.
                isAgentBusy = true
                hasCompletedHUDAction = false
                isHUDManuallyPinned = false
                hudAutoHideTask?.cancel()
                hudAutoHideTask = nil
                scheduleTaskIdleSettle()
                pulseActivityIndicator()
            }
        case .taskComplete:
            taskIdleSettleTask?.cancel()
            taskIdleSettleTask = nil
            isAgentBusy = false
            hasCompletedHUDAction = item.success && !engine.isKillSwitchTripped()
            pulseActivityIndicator()
            if hasCompletedHUDAction {
                scheduleCompletionAutoClose(delaySeconds: 1.85)
            }
        case .policyOrSafety:
            if engine.isKillSwitchTripped() || status.policy == .paused || !item.success {
                taskIdleSettleTask?.cancel()
                isAgentBusy = false
                hasCompletedHUDAction = false
                clearActivityIndicator()
            }
        case .highlight:
            if !engine.isKillSwitchTripped() && status.policy != .paused {
                pulseActivityIndicator()
            }
        }

        latestCaptionItem = item
        scheduleCaptionClearIfIdle()

        let friendlyLabel = friendlyActionLabel(for: item)
        if let frame = item.elementFrame {
            let targetPoint = CGPoint(x: frame.centerX, y: frame.centerY)
            if virtualAgentPoint == nil, let bounds = item.windowBounds ?? activeTargetApp?.windowBounds {
                virtualAgentPoint = CGPoint(x: bounds.centerX, y: bounds.centerY)
                virtualAgentLabel = friendlyLabel
                virtualAgentMoveTask?.cancel()
                virtualAgentMoveTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 24_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.virtualAgentPoint = targetPoint
                }
            } else {
                virtualAgentMoveTask?.cancel()
                virtualAgentPoint = targetPoint
                virtualAgentLabel = friendlyLabel
            }
            scheduleVirtualAgentFade()
        } else if item.kind == .actionComplete && virtualAgentPoint != nil {
            scheduleVirtualAgentFade(delaySeconds: 1.15)
        } else if (item.kind == .observe || item.kind == .screenshot || item.kind == .taskComplete) && virtualAgentPoint != nil {
            clearVirtualPointerSmoothly()
        }

        if item.kind == .actionStep && shouldEmitClickPulse(for: item) {
            virtualClickPulseId = UUID()
        }

        let isChromeBridgeActivity = item.browserTabId != nil || item.browserProfile != nil || (item.appPid == nil && (item.bundleId == "com.google.Chrome" || (item.appName?.hasPrefix("Chrome (") == true)))
        var cardId: String?
        var cardProfile = item.browserProfile
        var cardAppDescriptor: AppDescriptor?

        if isChromeBridgeActivity {
            let prof = cardProfile ?? item.appName?
                .replacingOccurrences(of: "Chrome (", with: "")
                .replacingOccurrences(of: ")", with: "") ?? connectedBrowserProfiles.first?.profileName ?? "Chrome"
            cardProfile = prof
            cardId = Self.browserCardId(profile: prof, tabId: item.browserTabId)
        } else {
            showingFrozenBrowserFrame = false
            // Drop any empty browser placeholder created by a generic task_start before targeting a native app
            hudDeck.removeAll { $0.isBrowser && $0.browserTabId == nil && $0.previewImage == nil }
            if let resolvedTarget = resolveTargetApp(from: item) {
                cardAppDescriptor = resolvedTarget
                if activeTargetApp != resolvedTarget {
                    activeTargetApp = resolvedTarget
                    if isHUDVisible {
                        syncLiveStream()
                    }
                }
            } else if activeTargetApp == nil {
                activeTargetApp = engine.captureFrontmostExternalApp()
                cardAppDescriptor = activeTargetApp
            } else {
                cardAppDescriptor = activeTargetApp
            }
            if let pid = cardAppDescriptor?.pid, pid > 0 {
                cardId = "app:\(pid)"
            }
        }

        if item.kind == .taskComplete {
            var matchedAny = false
            for idx in hudDeck.indices {
                let matchBrowser: Bool = {
                    guard hudDeck[idx].isBrowser else { return false }
                    if let targetTab = item.browserTabId, hudDeck[idx].browserTabId != targetTab {
                        return false
                    }
                    if let targetProf = item.browserProfile, !targetProf.isEmpty,
                       hudDeck[idx].browserProfile?.caseInsensitiveCompare(targetProf) != .orderedSame {
                        return false
                    }
                    return true
                }()
                let matchNative: Bool = {
                    guard !hudDeck[idx].isBrowser else { return false }
                    if let pid = item.appPid, hudDeck[idx].appDescriptor?.pid == pid {
                        return true
                    }
                    return item.browserProfile == nil && item.browserTabId == nil
                }()
                if matchBrowser || matchNative || (item.browserTabId == nil && item.appPid == nil && idx == 0) {
                    hudDeck[idx].isBusy = false
                    hudDeck[idx].isCompleted = item.success && !engine.isKillSwitchTripped()
                    hudDeck[idx].caption = item
                    matchedAny = true
                }
            }
            if !matchedAny, !hudDeck.isEmpty {
                hudDeck[0].isBusy = false
                hudDeck[0].isCompleted = item.success && !engine.isKillSwitchTripped()
                hudDeck[0].caption = item
            }
            syncFrontCardToUI()
        } else if let cardId {
            let busyState: Bool? = {
                switch item.kind {
                case .taskStart, .actionStart, .actionStep, .actionComplete, .observe, .screenshot:
                    return !engine.isKillSwitchTripped() && status.policy != .paused
                case .taskComplete, .policyOrSafety:
                    return false
                case .highlight:
                    return nil
                }
            }()
            let completedState: Bool? = {
                switch item.kind {
                case .taskStart, .actionStart, .actionStep, .actionComplete, .observe, .screenshot, .policyOrSafety:
                    return false
                case .taskComplete:
                    return item.success && !engine.isKillSwitchTripped()
                case .highlight:
                    return nil
                }
            }()
            let shouldPromote: Bool = {
                switch item.kind {
                case .taskStart, .actionStart, .actionStep, .observe, .screenshot:
                    return true
                case .actionComplete, .taskComplete, .highlight, .policyOrSafety:
                    return false
                }
            }()
            let cardTitle: String? = {
                if let wt = item.windowTitle, !wt.isEmpty { return wt }
                return cardAppDescriptor?.name ?? item.appName
            }()
            let cardUrl: String? = {
                guard isChromeBridgeActivity, let sub = item.subtitle,
                      sub.hasPrefix("http://") || sub.hasPrefix("https://") else {
                    return nil
                }
                return sub
            }()
            upsertHUDCard(
                id: cardId,
                isBrowser: isChromeBridgeActivity,
                browserProfile: cardProfile,
                browserTabId: item.browserTabId,
                browserUrl: cardUrl,
                appDescriptor: cardAppDescriptor,
                title: cardTitle,
                isBusy: busyState,
                isCompleted: completedState,
                caption: item,
                promote: shouldPromote
            )
            if hudDeck.first?.id == cardId {
                syncFrontCardToUI()
            }
        }

        let hasStreamTarget = (pairedApp != nil || activeTargetApp != nil || hudStreamMode == .fullDisplay || isBrowserStreamActive || showingFrozenBrowserFrame || !hudDeck.isEmpty)
        if autoShowHUDOnActivity && !isHUDVisible && hasStreamTarget && !engine.isKillSwitchTripped() && status.policy != .paused {
            let recentlyDismissed = lastUserDismissDate.map { Date().timeIntervalSince($0) < 4.0 } ?? false
            switch item.kind {
            case .taskStart:
                showHUD(manual: false)
            case .observe, .actionStart, .screenshot:
                if !recentlyDismissed {
                    showHUD(manual: false)
                }
            case .actionStep, .actionComplete, .taskComplete:
                if !dismissedDuringActiveRun && !recentlyDismissed {
                    showHUD(manual: false)
                }
            case .highlight, .policyOrSafety:
                break
            }
        }

        if item.kind == .taskComplete {
            dismissedDuringActiveRun = false
        }
    }

    private func friendlyActionLabel(for item: LiveActivityItem) -> String? {
        let title = item.title
        if title.hasPrefix("Double-clicked") { return "Double-clicking" }
        if title.hasPrefix("Right-clicked") { return "Right-clicking" }
        if title.hasPrefix("Clicked") { return "Clicking" }
        if title.hasPrefix("Set ") || title.hasPrefix("Typed") { return "Typing…" }
        if title.hasPrefix("Pressed") { return "Pressing key" }
        if title.hasPrefix("Scrolled") { return "Scrolling" }
        if title.hasPrefix("Focused") { return "Focusing" }
        if item.kind == .observe { return "Observing" }
        if item.kind == .highlight { return "Inspecting" }
        return nil
    }

    private func friendlyCursorLabel(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("@") else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("double") { return "Double-clicking" }
        if lower.contains("right") { return "Right-clicking" }
        if lower.contains("click") { return "Clicking" }
        if lower.contains("type") || lower.contains("set") { return "Typing…" }
        if lower.contains("scroll") { return "Scrolling" }
        return trimmed
    }

    private func scheduleHUDAutoHide(delayNanoseconds: UInt64 = 4_000_000_000) {
        hudAutoHideTask?.cancel()
        guard isHUDVisible, !isAgentBusy, !isHUDManuallyPinned else { return }
        hudAutoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            if !self.isAgentBusy && !self.isHUDManuallyPinned && self.isHUDVisible && !self.status.killSwitchTripped {
                self.hideHUD(userInitiated: false)
            }
        }
    }

    private func shouldEmitClickPulse(for item: LiveActivityItem) -> Bool {
        let prefixes = ["Clicked", "Double-clicked", "Right-clicked", "Set ", "Typed "]
        return prefixes.contains(where: { item.title.hasPrefix($0) })
    }

    private func pulseActivityIndicator() {
        activityIndicatorHoldTask?.cancel()
        isActivityIndicatorLit = true
        guard !isAgentBusy else { return }
        activityIndicatorHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.isAgentBusy {
                self.isActivityIndicatorLit = false
            }
        }
    }

    private func clearActivityIndicator() {
        activityIndicatorHoldTask?.cancel()
        activityIndicatorHoldTask = nil
        isActivityIndicatorLit = false
    }

    private func scheduleCaptionClearIfIdle() {
        captionClearTask?.cancel()
        guard !isAgentBusy, let currentId = latestCaptionItem?.id else { return }
        captionClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.isAgentBusy && self.latestCaptionItem?.id == currentId {
                self.latestCaptionItem = nil
            }
        }
    }

    private func clearVirtualPointerSmoothly() {
        virtualAgentFadeTask?.cancel()
        virtualAgentFadeTask = nil
        virtualAgentMoveTask?.cancel()
        virtualAgentMoveTask = nil
        withAnimation(.easeOut(duration: 0.25)) {
            self.virtualAgentPoint = nil
            self.virtualAgentLabel = nil
            for idx in self.hudDeck.indices {
                self.hudDeck[idx].cursorPoint = nil
                self.hudDeck[idx].cursorLabel = nil
            }
        }
    }

    private func scheduleVirtualAgentFade(delaySeconds: Double = 1.65) {
        virtualAgentFadeTask?.cancel()
        virtualAgentFadeTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(0.25, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.clearVirtualPointerSmoothly()
        }
    }

    private func resolveTargetApp(from item: LiveActivityItem) -> AppDescriptor? {
        if let pid = item.appPid,
           let matched = runningApps.first(where: { $0.pid == pid }) {
            return AppDescriptor(
                pid: matched.pid,
                name: item.appName ?? matched.name,
                bundleId: item.bundleId ?? matched.bundleId,
                isActive: matched.isActive,
                isHidden: matched.isHidden,
                windowTitle: item.windowTitle ?? matched.windowTitle,
                windowBounds: item.windowBounds ?? matched.windowBounds
            )
        }

        guard let appName = item.appName, !appName.isEmpty else {
            return nil
        }

        return AppDescriptor(
            pid: item.appPid ?? 0,
            name: appName,
            bundleId: item.bundleId,
            isActive: true,
            isHidden: false,
            windowTitle: item.windowTitle,
            windowBounds: item.windowBounds
        )
    }

    // MARK: - Overlay Events

    public func handleOverlayEvent(_ event: OverlayVisualEvent) {
        switch event {
        case .highlightElement(let rect, let label, let role, let durationMs):
            highlightClearTask?.cancel()
            highlightedRect = rect
            highlightLabel = label
            highlightRole = role
            virtualAgentMoveTask?.cancel()
            virtualAgentPoint = CGPoint(x: rect.centerX, y: rect.centerY)
            virtualAgentLabel = friendlyCursorLabel(from: label) ?? "Inspecting"
            scheduleVirtualAgentFade()

            let clampedMs = max(200, durationMs)
            highlightClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(clampedMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.highlightedRect = nil
                self?.highlightLabel = nil
                self?.highlightRole = nil
            }

        case .pulsePoint(let x, let y, let label):
            pulseClearTask?.cancel()
            let pulse = OverlayPulse(x: x, y: y, label: label)
            pulsePoint = pulse
            virtualAgentMoveTask?.cancel()
            virtualAgentPoint = CGPoint(x: x, y: y)
            virtualAgentLabel = friendlyCursorLabel(from: label)
            virtualClickPulseId = UUID()
            scheduleVirtualAgentFade()

            pulseClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 950_000_000)
                guard !Task.isCancelled else { return }
                if self?.pulsePoint?.id == pulse.id {
                    self?.pulsePoint = nil
                }
            }

        case .agentBanner:
            break

        case .clear:
            clearOverlay()
        }
    }

    public func clearOverlay() {
        highlightClearTask?.cancel()
        pulseClearTask?.cancel()
        virtualAgentFadeTask?.cancel()
        virtualAgentMoveTask?.cancel()
        highlightedRect = nil
        highlightLabel = nil
        highlightRole = nil
        pulsePoint = nil
        virtualAgentPoint = nil
        virtualAgentLabel = nil
        virtualClickPulseId = nil
    }
}
