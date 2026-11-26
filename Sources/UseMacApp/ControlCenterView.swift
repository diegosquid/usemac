import AppKit
import SwiftUI
import UseMacProtocol

public enum ControlCenterSection: String, CaseIterable, Identifiable {
    case overview = "General"
    case connect = "Connect"
    case audit = "History"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .overview: return "slider.horizontal.3"
        case .connect: return "terminal"
        case .audit: return "clock"
        }
    }
}

@MainActor
public final class ControlCenterRouter: ObservableObject {
    @Published public var selection: ControlCenterSection = .overview

    public init() {}
}

// MARK: - Window Drag Strip for Transparent Titlebar

private final class TitlebarDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct WindowTitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitlebarDragNSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
public final class ControlCenterWindowController {
    private let appState: AppState
    private let router = ControlCenterRouter()
    private var window: NSWindow?
    private var keyObserver: NSObjectProtocol?

    public init(appState: AppState) {
        self.appState = appState
        appState.onOpenControlCenter = { [weak self] in
            self?.show(section: nil)
        }
        appState.onOpenControlCenterSection = { [weak self] section in
            self?.show(section: section)
        }
    }

    deinit {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }

    public func show(section: ControlCenterSection? = nil) {
        if let section {
            router.selection = section
        }

        if window == nil {
            let view = ControlCenterView(appState: appState, router: router)
            let hosting = NSHostingView(rootView: view)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 590),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "UseMac"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = false
            win.minSize = NSSize(width: 760, height: 500)
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = hosting
            window = win

            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.appState.refreshPermissions(promptAccessibility: false)
                }
            }
        }

        appState.refreshPermissions(promptAccessibility: false)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

public struct ControlCenterView: View {
    @ObservedObject public var appState: AppState
    @ObservedObject public var router: ControlCenterRouter
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var sidebarNamespace

    @State private var copiedKey: String?
    @State private var pairingKeyFeedback: [String: String] = [:]
    @State private var pairingKeyFeedbackTokens: [String: UUID] = [:]
    @State private var integrationTab: IntegrationTab = .socket
    @State private var auditFilter: AuditFilter = .all
    @State private var hoveredSection: ControlCenterSection?

    private enum IntegrationTab: String, CaseIterable, Identifiable {
        case socket = "Socket"
        case mcp = "MCP"
        case cli = "CLI"
        var id: String { rawValue }
    }

    private enum AuditFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case ok = "Done"
        case failed = "Failed"
        var id: String { rawValue }

        var emptyTitle: String {
            switch self {
            case .all: return "No history yet"
            case .ok: return "No completed actions yet"
            case .failed: return "No failed actions"
            }
        }

        var emptySubtitle: String {
            switch self {
            case .all: return "Actions performed by your agents will appear here."
            case .ok: return "Successful requests will appear here."
            case .failed: return "Blocked and failed requests will appear here."
            }
        }
    }

    public init(appState: AppState, router: ControlCenterRouter) {
        self.appState = appState
        self.router = router
    }

    public var body: some View {
        ZStack(alignment: .top) {
            UseMacTheme.shellBackground(colorScheme)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                codexSidebarRail
                    .frame(width: 204)

                floatingWorkspaceSheet
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .padding(.trailing, 10)
            }

            WindowTitlebarDragArea()
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(true)
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    // MARK: - Minimal Codex Left Sidebar Rail

    private var codexSidebarRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if let logo = Self.sidebarBrandImage {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
                } else {
                    UseMacGlyph(size: 18)
                }

                Text("UseMac")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 38)
            .padding(.bottom, 12)

            VStack(spacing: 3) {
                ForEach(ControlCenterSection.allCases) { section in
                    sidebarPillButton(for: section)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            sidebarQuietFooter
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
    }

    private static let sidebarBrandImage: NSImage? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("usemac-logo.png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }()

    private func sidebarPillButton(for section: ControlCenterSection) -> some View {
        let isSelected = router.selection == section
        let isHovered = hoveredSection == section

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                router.selection = section
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 18)

                Text(section.rawValue)
                    .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7.5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                        .fill(UseMacTheme.surface(colorScheme))
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.048),
                            radius: 1.5,
                            x: 0,
                            y: 1
                        )
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.06),
                            radius: 6,
                            x: 0,
                            y: 2.5
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                                .strokeBorder(UseMacTheme.hairline(colorScheme), lineWidth: 0.65)
                        )
                        .matchedGeometryEffect(id: "sidebarActivePill", in: sidebarNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                        .fill(UseMacTheme.subtleFill(colorScheme))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSection = hovering ? section : (hoveredSection == section ? nil : hoveredSection)
        }
    }

    private var sidebarQuietFooter: some View {
        let isActing = appState.isActivityIndicatorLit && !appState.status.killSwitchTripped && appState.status.policy != .paused
        let dotColor = isActing ? UseMacTheme.accentActive : daemonStatusColor
        let labelText = isActing ? "Agent active" : daemonStatusLabel

        return HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6.5, height: 6.5)

            Text(labelText)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text("v\(appState.status.version)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Right Floating Workspace Sheet

    private var floatingWorkspaceSheet: some View {
        Group {
            switch router.selection {
            case .overview:
                generalSection
            case .connect:
                connectSection
            case .audit:
                historySection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .codexSheetElevation(colorScheme, cornerRadius: 18)
    }

    // MARK: - General Preferences Section (Pure Codex Style, Zero Dashboard)

    private var generalSection: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("General")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)

                    Text("Background computer control and live window preview.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                if let daemonError = appState.daemonError {
                    daemonErrorBanner(daemonError)
                }

                if appState.shouldShowOnboarding {
                    getStartedGroup
                }

                livePreviewGroup
                shortcutsGroup
                chromeExtensionGroup
                localVisionGroup
                permissionsGroup
                safetyGroup
                SoftwareUpdatesGroupView(updater: appState.updater)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 34)
        }
    }

    private func daemonErrorBanner(_ errorMessage: String) -> some View {
        SettingsGroup {
            EmptyView()
        } content: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2.5) {
                    Text("UseMac couldn't start")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(UseMacTheme.statusRed)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(UseMacTheme.statusRed.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Button("Retry") {
                    appState.startDaemon()
                }
                .buttonStyle(SubtleOutlineButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(UseMacTheme.statusRed.opacity(0.06))
        }
    }

    private var getStartedGroup: some View {
        let perms = appState.status.permissions
        let accessibilityDone = perms.accessibilityGranted
        let screenRecordingDone = perms.screenRecordingGranted
        let chromeDone = !appState.connectedBrowserProfiles.isEmpty
        let agentDone = appState.hasEverConnectedAgent

        return SettingsGroup(title: "Get started") {
            if accessibilityDone && screenRecordingDone {
                Button {
                    appState.dismissOnboarding()
                } label: {
                    Text("Hide")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } content: {
            onboardingRow(
                title: "Allow Accessibility",
                subtitle: nil,
                done: accessibilityDone
            ) {
                if !accessibilityDone {
                    Button("Allow") {
                        appState.triggerPermissionFlow(for: .accessibility, prompt: true)
                    }
                    .buttonStyle(PrimaryInkButtonStyle())
                }
            }

            InsetDivider(leading: 18)

            onboardingRow(
                title: "Allow Screen Recording",
                subtitle: nil,
                done: screenRecordingDone
            ) {
                if !screenRecordingDone {
                    Button("Allow") {
                        appState.triggerPermissionFlow(for: .screenRecording, prompt: true)
                    }
                    .buttonStyle(PrimaryInkButtonStyle())
                }
            }

            InsetDivider(leading: 18)

            onboardingRow(
                title: "Pair the Chrome extension",
                subtitle: "Optional. Needed to control Chrome tabs.",
                done: chromeDone
            ) {
                if !chromeDone {
                    Button(pairingKeyButtonLabel(for: "onboarding-pairing-key")) {
                        copyPairingKey(feedbackKey: "onboarding-pairing-key")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }
            }

            InsetDivider(leading: 18)

            onboardingRow(
                title: "Connect your agent",
                subtitle: nil,
                done: agentDone
            ) {
                if !agentDone {
                    Button("Open Connect") {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            router.selection = .connect
                        }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }
            }
        }
    }

    private func onboardingRow<Trailing: View>(
        title: String,
        subtitle: String?,
        done: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(done ? UseMacTheme.statusGreen : Color.secondary)
                .accessibilityLabel(done ? "Completed" : "Not completed")

            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(done ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var livePreviewGroup: some View {
        SettingsGroup(title: "Live Preview") {
            EmptyView()
        } content: {
            codexRow(
                title: "Show when agent is active",
                subtitle: "Automatically pops up while an agent interacts with an app, and disappears when idle."
            ) {
                CodexToggle(
                    isOn: Binding(
                        get: { appState.autoShowHUDOnActivity },
                        set: { appState.setAutoShowHUDOnActivity($0) }
                    ),
                    accessibilityLabel: "Show when agent is active"
                )
            }

            InsetDivider(leading: 18)

            codexRow(
                title: "Preview source",
                subtitle: "Stream only the background target window or the entire screen."
            ) {
                CodexSegmentedControl(
                    selection: Binding(
                        get: { appState.hudStreamMode },
                        set: { appState.setHUDStreamMode($0) }
                    ),
                    options: [
                        CodexSegmentOption(value: HUDStreamMode.autoWindow, label: "Window"),
                        CodexSegmentOption(value: HUDStreamMode.fullDisplay, label: "Full Screen")
                    ]
                )
            }

            InsetDivider(leading: 18)

            codexRow(
                title: "Snap corner",
                subtitle: "Drag and flick the preview window to snap magnetically."
            ) {
                CodexSegmentedControl(
                    selection: Binding(
                        get: { appState.hudCorner },
                        set: { appState.setHUDCorner($0, snapWindow: appState.isHUDVisible) }
                    ),
                    options: HUDCorner.allCases.map {
                        CodexSegmentOption(
                            value: $0,
                            symbolName: $0.symbolName,
                            helpText: $0.displayName,
                            accessibilityLabel: hudCornerAccessibilityLabel($0)
                        )
                    }
                )
            }

            InsetDivider(leading: 18)

            codexRow(
                title: "Larger preview",
                subtitle: "Expand the floating preview width from 280 pt to 400 pt."
            ) {
                CodexToggle(
                    isOn: Binding(
                        get: { appState.isHUDLarge },
                        set: { appState.setHUDLarge($0) }
                    ),
                    accessibilityLabel: "Larger preview"
                )
            }
        }
    }

    private func hudCornerAccessibilityLabel(_ corner: HUDCorner) -> String {
        switch corner {
        case .topLeading: return "Top left"
        case .topTrailing: return "Top right"
        case .bottomLeading: return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }

    private var shortcutsGroup: some View {
        let optionSpaceFailed = appState.isOptionSpaceShortcutEnabled && appState.failedShortcuts.contains("⌥Space")
        let killSwitchFailed = appState.failedShortcuts.contains("⌘⇧⎋")

        return SettingsGroup(title: "Shortcuts") {
            EmptyView()
        } content: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Show or hide preview")
                            .font(.system(size: 13.5, weight: .medium))
                        ShortcutText("⌥Space")
                    }
                    Text(
                        optionSpaceFailed
                            ? "⌥Space is in use by another app."
                            : "Turn off if another app uses ⌥Space. ⌃⌥Space always works."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(optionSpaceFailed ? UseMacTheme.statusAmber : Color.secondary)
                }

                Spacer(minLength: 16)

                CodexToggle(
                    isOn: Binding(
                        get: { appState.isOptionSpaceShortcutEnabled },
                        set: { appState.setOptionSpaceShortcutEnabled($0) }
                    ),
                    accessibilityLabel: "Show or hide preview"
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            InsetDivider(leading: 18)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Emergency stop")
                            .font(.system(size: 13.5, weight: .medium))
                        ShortcutText("⌘⇧⎋")
                    }
                    Text(
                        killSwitchFailed
                            ? "⌘⇧⎋ couldn't be registered. Use the menu bar item instead."
                            : "Works from any app."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(killSwitchFailed ? UseMacTheme.statusAmber : Color.secondary)
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private var chromeExtensionGroup: some View {
        let hasProfilesOrPending = !appState.connectedBrowserProfiles.isEmpty || !appState.pendingBrowserPairings.isEmpty

        return SettingsGroup(title: "Chrome Extension") {
            if hasProfilesOrPending {
                Button {
                    copyWithFeedback(feedbackKey: "extension-path-header") { appState.copyChromeExtensionPath() }
                } label: {
                    Text(feedbackLabel(for: "extension-path-header", default: "Copy Extension Path"))
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy the extension folder path, for Load unpacked (⌘⇧G) in chrome://extensions")
            }
        } content: {
            codexRow(
                title: "Pairing key",
                subtitle: "Paste this key into the UseMac extension popup in each Chrome profile."
            ) {
                HStack(spacing: 8) {
                    Button(pairingKeyButtonLabel(for: "chrome-pairing-key")) {
                        copyPairingKey(feedbackKey: "chrome-pairing-key")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())

                    Button("Reset…") {
                        appState.confirmAndResetBridgePairingKey()
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }
            }

            if !hasProfilesOrPending {
                InsetDivider(leading: 18)

                codexRow(
                    title: "UseMac Browser Bridge",
                    subtitle: appState.chromeWebStoreExtensionId != nil
                        ? "One-click install from Chrome Web Store for zero-focus background tabs."
                        : "In chrome://extensions, turn on Developer mode, click Load unpacked, press ⌘⇧G and paste the path."
                ) {
                    HStack(spacing: 8) {
                        if appState.chromeWebStoreExtensionId != nil {
                            Button("Install Extension") {
                                appState.installPublishedChromeExtension()
                            }
                            .buttonStyle(SubtleOutlineButtonStyle())
                        } else {
                            Button(feedbackLabel(for: "extension-path", default: "Copy Path")) {
                                copyWithFeedback(feedbackKey: "extension-path") { appState.copyChromeExtensionPath() }
                            }
                            .buttonStyle(SubtleOutlineButtonStyle())

                            Button("Open Chrome") {
                                appState.openChromeExtensionsPage()
                            }
                            .buttonStyle(SubtleOutlineButtonStyle())
                        }
                    }
                }
            } else {
                ForEach(Array(appState.pendingBrowserPairings.enumerated()), id: \.offset) { _, pendingName in
                    InsetDivider(leading: 18)
                    codexRow(
                        title: pendingName,
                        subtitle: "Waiting for the pairing key"
                    ) {
                        StatusDot(color: UseMacTheme.statusAmber, label: "Not paired")
                    }
                }

                ForEach(Array(appState.connectedBrowserProfiles.enumerated()), id: \.element.id) { _, profile in
                    InsetDivider(leading: 18)
                    codexRow(
                        title: profile.profileName,
                        subtitle: "\(profile.tabCount) open \(profile.tabCount == 1 ? "tab" : "tabs")"
                    ) {
                        StatusDot(color: UseMacTheme.statusGreen, label: "Connected")
                    }
                }
            }
        }
    }

    private var localVisionGroup: some View {
        let vision = appState.visionStatus
        let selectedPreset = LocalVisionModelPreset(rawValue: vision.modelId) ?? .qwen25VL3B
        let isReady = vision.runtimeInstalled && vision.modelDownloaded
        let isInstalling = vision.state == "installing"

        return SettingsGroup(title: "Local Vision") {
            HStack(spacing: 5) {
                Circle()
                    .fill(isReady && vision.enabled ? UseMacTheme.statusGreen : UseMacTheme.accentActive)
                    .frame(width: 6, height: 6)
                Text(isReady && vision.enabled ? "MLX Ready" : (isInstalling ? "Installing…" : "Apple OCR Active"))
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        } content: {
            codexRow(
                title: "On-device GUI model",
                subtitle: vision.installProgress
                    ?? vision.lastError
                    ?? (isReady
                        ? "Offline Apple Silicon MLX grounding for popups, icons, and cross-origin overlays."
                        : "Optional local MLX model (\(selectedPreset.sizeHint)) on top of built-in Apple Vision OCR.")
            ) {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                } else if isReady {
                    CodexToggle(
                        isOn: Binding(
                            get: { appState.visionStatus.enabled },
                            set: { appState.setLocalVisionEnabled($0) }
                        ),
                        accessibilityLabel: "On-device GUI model"
                    )
                } else {
                    Button("Install & Enable") {
                        appState.installLocalVision()
                    }
                    .buttonStyle(PrimaryInkButtonStyle())
                }
            }

            InsetDivider(leading: 18)

            codexRow(
                title: "Model preset",
                subtitle: "Choose balance between grounding accuracy and speed on Apple Silicon."
            ) {
                CodexSegmentedControl(
                    selection: Binding(
                        get: { LocalVisionModelPreset(rawValue: appState.visionStatus.modelId) ?? .qwen25VL3B },
                        set: { appState.selectLocalVisionModel($0) }
                    ),
                    options: [
                        CodexSegmentOption(value: LocalVisionModelPreset.qwen35_08B, label: "Qwen3.5 0.8B"),
                        CodexSegmentOption(value: LocalVisionModelPreset.qwen25VL3B, label: "Qwen2.5 3B"),
                        CodexSegmentOption(value: LocalVisionModelPreset.holo1_3B, label: "Holo 3B")
                    ]
                )
            }
        }
    }

    private var permissionsGroup: some View {
        let perms = appState.status.permissions
        let needsRepair = !perms.accessibilityGranted || !perms.screenRecordingGranted

        return SettingsGroup(title: "Permissions") {
            if needsRepair {
                Button {
                    appState.resetStalePermissions()
                } label: {
                    Text("Reset stale entries")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } content: {
            permissionRow(
                title: "Accessibility",
                subtitle: "Inspect UI elements and run clicks or typing in the background.",
                granted: perms.accessibilityGranted,
                showRestartHint: !perms.accessibilityGranted && appState.attemptedAccessibilityGrant,
                onGrant: { appState.triggerPermissionFlow(for: .accessibility, prompt: true) },
                onSettings: { appState.triggerPermissionFlow(for: .accessibility, prompt: false) }
            )

            InsetDivider(leading: 18)

            permissionRow(
                title: "Screen Recording",
                subtitle: "Stream live previews and take screenshots that your connected agent can see.",
                granted: perms.screenRecordingGranted,
                showRestartHint: !perms.screenRecordingGranted && appState.attemptedScreenRecordingGrant,
                onGrant: { appState.triggerPermissionFlow(for: .screenRecording, prompt: true) },
                onSettings: { appState.triggerPermissionFlow(for: .screenRecording, prompt: false) }
            )
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        showRestartHint: Bool,
        onGrant: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            codexRow(title: title, subtitle: subtitle) {
                if granted {
                    Button(action: onSettings) {
                        HStack(spacing: 5.5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12.5))
                                .foregroundStyle(UseMacTheme.statusGreen)
                            Text("Allowed")
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open System Settings")
                } else {
                    HStack(spacing: 8) {
                        Button("Allow", action: onGrant)
                            .buttonStyle(PrimaryInkButtonStyle())

                        Button("Settings", action: onSettings)
                            .buttonStyle(SubtleOutlineButtonStyle())
                    }
                }
            }

            if showRestartHint {
                HStack(spacing: 12) {
                    Text("Already allowed in System Settings? macOS may need UseMac to restart.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Quit & Reopen") {
                        appState.relaunchApp()
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }

    private var executionModeSubtitle: String {
        switch appState.status.policy {
        case .autonomous:
            return "Agents can read and act without asking."
        case .ask:
            return "Agents can act, but uploads, page scripts and ⌘/⌃ shortcuts wait for your OK in the live preview."
        case .confirmSensitive:
            return "Agents can act, but uploads, page scripts and ⌘/⌃ shortcuts are blocked."
        case .readOnly:
            return "Agents can look and scroll. Clicks, typing and uploads are blocked."
        case .paused:
            return "Agents can't read the screen or act until you resume."
        }
    }

    private var safetyGroup: some View {
        SettingsGroup(title: "Safety") {
            EmptyView()
        } content: {
            codexRow(
                title: "Execution mode",
                subtitle: executionModeSubtitle,
                subtitleLineLimit: nil
            ) {
                CodexSegmentedControl(
                    selection: Binding(
                        get: { appState.status.policy },
                        set: { appState.setPolicy($0) }
                    ),
                    options: [
                        CodexSegmentOption(value: GovernancePolicy.autonomous, label: "Autonomous"),
                        CodexSegmentOption(value: GovernancePolicy.ask, label: "Ask"),
                        CodexSegmentOption(value: GovernancePolicy.confirmSensitive, label: "Block sensitive"),
                        CodexSegmentOption(value: GovernancePolicy.readOnly, label: "Read-only"),
                        CodexSegmentOption(value: GovernancePolicy.paused, label: "Paused")
                    ]
                )
            }

            InsetDivider(leading: 18)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Emergency stop")
                            .font(.system(size: 13.5, weight: .medium))
                        ShortcutText("⌘⇧⎋")
                    }
                    Text("Stops every agent now: cancels running actions and blocks reading and acting until you resume.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                CodexToggle(
                    isOn: Binding(
                        get: { appState.status.killSwitchTripped },
                        set: { appState.setKillSwitch($0) }
                    ),
                    activeColor: UseMacTheme.statusRed,
                    accessibilityLabel: "Emergency stop"
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(appState.status.killSwitchTripped ? UseMacTheme.statusRed.opacity(0.05) : Color.clear)
        }
    }

    private func codexRow<Trailing: View>(
        title: String,
        subtitle: String,
        subtitleLineLimit: Int? = 2,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
                    .fixedSize(horizontal: false, vertical: subtitleLineLimit == nil)
            }

            Spacer(minLength: 16)

            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Connect Section (Plug & Play Agent Prompts + Bundled Skill)

    private var connectSection: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect")
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(-0.4)
                        Text("Copy and paste straight into your agent — it installs the skill and connects itself.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    CodexSegmentedControl(
                        selection: $integrationTab,
                        options: IntegrationTab.allCases.map {
                            CodexSegmentOption(value: $0, label: $0.rawValue)
                        }
                    )
                }

                switch integrationTab {
                case .socket:
                    agentPromptCard(
                        key: "socket-prompt",
                        subtitle: "Fastest path (~0.1 ms, zero MCP token overhead). Installs the skill and connects directly via Unix socket.",
                        headerLabel: "Agent Prompt · Unix Socket + Skill (Recommended)",
                        prompt: socketAgentPrompt
                    )
                case .mcp:
                    agentPromptCard(
                        key: "mcp-prompt",
                        subtitle: "Instructs your agent to register the MCP server and install the background skill.",
                        headerLabel: "Agent Prompt · MCP + Skill",
                        prompt: mcpAgentPrompt
                    )
                case .cli:
                    agentPromptCard(
                        key: "cli-prompt",
                        subtitle: "Instructs any terminal agent to use the UseMac CLI right away with zero config.",
                        headerLabel: "Agent Prompt · CLI + Skill",
                        prompt: cliAgentPrompt
                    )
                }

                bundledSkillFilesGroup
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 34)
        }
    }

    private func agentPromptCard(
        key: String,
        subtitle: String,
        headerLabel: String,
        prompt: String
    ) -> some View {
        SettingsGroup {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                InsetDivider(leading: 0)

                HStack(spacing: 8) {
                    Text(headerLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        copyToPasteboard(prompt, key: key)
                    } label: {
                        HStack(spacing: 5.5) {
                            Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10.5, weight: .medium))
                            Text(copiedKey == key ? "Copied to Pasteboard" : "Copy Prompt")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(copiedKey == key ? UseMacTheme.statusGreen : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .codexPillElevation(colorScheme, cornerRadius: 7)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(UseMacTheme.recessed(colorScheme))

                InsetDivider(leading: 0)

                Text(prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UseMacTheme.codeBackground(colorScheme))
            }
        }
    }

    private var bundledSkillFilesGroup: some View {
        let skillPath = "\(appState.resolvedAgentDocsDir)/skills/usemac/SKILL.md"
        return SettingsGroup(title: "Agent Files") {
            EmptyView()
        } content: {
            codexRow(
                title: "Skill & Agent Guide",
                subtitle: "The usemac skill (SKILL.md) and the agent guide (AGENTS.md), bundled inside UseMac."
            ) {
                HStack(spacing: 8) {
                    Button {
                        copyToPasteboard(skillPath, key: "skill-path")
                    } label: {
                        Text(copiedKey == "skill-path" ? "Copied" : "Copy Path")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())

                    Button("Show in Finder") {
                        appState.revealAgentDocsInFinder()
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }
            }
        }
    }

    private var socketAgentPrompt: String { appState.socketAgentPrompt }

    private var mcpAgentPrompt: String { appState.mcpAgentPrompt }

    private var cliAgentPrompt: String { appState.cliAgentPrompt }

    // MARK: - History Section

    private var filteredAuditEntries: [AuditEntry] {
        switch auditFilter {
        case .all: return appState.auditEntries
        case .ok: return appState.auditEntries.filter { $0.success }
        case .failed: return appState.auditEntries.filter { !$0.success }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)
                    Text("Recent background observations and actions.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                CodexSegmentedControl(
                    selection: $auditFilter,
                    options: AuditFilter.allCases.map {
                        CodexSegmentOption(value: $0, label: $0.rawValue)
                    }
                )
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 22)

            if filteredAuditEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text(auditFilter.emptyTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(auditFilter.emptySubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    SettingsGroup {
                        EmptyView()
                    } content: {
                        ForEach(Array(filteredAuditEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                InsetDivider(leading: 34)
                            }
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(entry.success ? UseMacTheme.statusGreen : UseMacTheme.statusRed)
                                    .frame(width: 6, height: 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        if let app = entry.targetApp, !app.isEmpty {
                                            Text(app)
                                                .font(.system(size: 13, weight: .medium))
                                        } else {
                                            Text(entry.method.capitalized)
                                                .font(.system(size: 13, weight: .medium))
                                        }
                                    }

                                    Text(entry.summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 12)

                                Text(Self.formatTimestamp(entry.timestampMs))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.bottom, 34)
                }
            }
        }
    }

    // MARK: - Helpers

    private var daemonStatusColor: Color {
        if appState.status.killSwitchTripped { return UseMacTheme.statusRed }
        if appState.status.policy == .paused { return UseMacTheme.statusAmber }
        return appState.isServerRunning ? UseMacTheme.statusGreen : UseMacTheme.statusRed
    }

    private var daemonStatusLabel: String {
        if appState.status.killSwitchTripped { return "Stopped" }
        if appState.status.policy == .paused { return "Paused" }
        if appState.status.policy == .readOnly { return "Read-only" }
        if appState.status.policy == .confirmSensitive { return "Block sensitive" }
        return appState.isServerRunning ? "Ready" : "Offline"
    }

    private func pairingKeyButtonLabel(for key: String) -> String {
        feedbackLabel(for: key, default: "Copy key")
    }

    private func feedbackLabel(for key: String, default defaultLabel: String) -> String {
        pairingKeyFeedback[key] ?? defaultLabel
    }

    private func copyPairingKey(feedbackKey: String) {
        copyWithFeedback(feedbackKey: feedbackKey) { appState.copyBridgePairingKey() }
    }

    /// Runs a copy action and shows "Copied" (or "Unavailable") on its button for 1.5 s.
    private func copyWithFeedback(feedbackKey: String, _ copy: () -> Bool) {
        let copied = copy()
        let token = UUID()
        pairingKeyFeedback[feedbackKey] = copied ? "Copied" : "Unavailable"
        pairingKeyFeedbackTokens[feedbackKey] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if pairingKeyFeedbackTokens[feedbackKey] == token {
                pairingKeyFeedback.removeValue(forKey: feedbackKey)
                pairingKeyFeedbackTokens.removeValue(forKey: feedbackKey)
            }
        }
    }

    private func copyToPasteboard(_ string: String, key: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        copiedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedKey == key {
                copiedKey = nil
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter
    }()

    private static func formatTimestamp(_ timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return dateTimeFormatter.string(from: date)
    }
}

private struct SoftwareUpdatesGroupView: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        SettingsGroup(title: "Software Updates") {
            Text("v\(updater.currentVersion) (\(updater.buildNumber))")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } content: {
            if updater.isConfiguredForRelease {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("Automatic updates")
                            .font(.system(size: 13.5, weight: .medium))
                        Text("Check silently for signed Sparkle 2 updates in the background.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 16)

                    CodexToggle(
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticallyChecks($0) }
                        ),
                        accessibilityLabel: "Automatic updates"
                    )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                InsetDivider(leading: 18)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("Beta updates")
                            .font(.system(size: 13.5, weight: .medium))
                        Text("Also offer pre-release versions. They get new features first and may have rough edges.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 16)

                    CodexToggle(
                        isOn: Binding(
                            get: { updater.receivesBetaUpdates },
                            set: { updater.setReceivesBetaUpdates($0) }
                        ),
                        accessibilityLabel: "Beta updates"
                    )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                InsetDivider(leading: 18)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("Check for updates")
                            .font(.system(size: 13.5, weight: .medium))
                        Text("Checks \(updater.feedURL) with EdDSA verification.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 16)

                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("Updates")
                            .font(.system(size: 13.5, weight: .medium))
                        Text("This is a development build. Updates are available in release builds.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
    }
}
