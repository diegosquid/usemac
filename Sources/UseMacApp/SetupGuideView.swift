import AppKit
import SwiftUI
import UseMacEngine
import UseMacProtocol

// MARK: - Steps

public enum SetupGuideStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case vision
    case chrome
    case agent
    case ready

    public var id: Int { rawValue }
}

// MARK: - Window

@MainActor
public final class SetupGuideWindowController: NSObject, NSWindowDelegate {
    public static let windowSize = NSSize(width: 760, height: 610)

    private let appState: AppState
    private var window: NSWindow?

    public init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    private var isAppTerminating = false
    private var terminateObserver: NSObjectProtocol?

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Where the guide opens: an explicit step, else the step saved before a relaunch, else the welcome step.
    private func resolvedStartStep(_ requested: SetupGuideStep?) -> SetupGuideStep {
        if let requested {
            return requested
        }
        if !appState.hasCompletedSetupGuide,
           let saved = appState.savedSetupGuideStep,
           let step = SetupGuideStep(rawValue: saved) {
            return step
        }
        return .welcome
    }

    public func show(startAt requestedStep: SetupGuideStep? = nil) {
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isAppTerminating = true
                }
            }
        }

        if window == nil {
            let step = resolvedStartStep(requestedStep)
            let view = SetupGuideView(
                appState: appState,
                initialStep: step,
                onRequestFocus: { [weak self] in self?.bringToFront() },
                onFinish: { [weak self] in self?.close() }
            )
            let hosting = NSHostingView(rootView: view)
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.windowSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Welcome to UseMac"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
            win.isReleasedWhenClosed = false
            win.contentView = hosting
            win.delegate = self
            win.center()
            window = win
        }

        appState.refreshPermissionFlags()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.close()
    }

    /// Brings the guide back after the user finished something in another app (System Settings, Chrome, their agent).
    public func bringToFront() {
        guard let window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // Quitting the app (for example to apply Screen Recording) keeps the guide's place;
        // only the user closing the window counts as done.
        if !isAppTerminating {
            appState.markSetupGuideCompleted()
        }
        window = nil
    }
}

// MARK: - Root View

public struct SetupGuideView: View {
    @ObservedObject var appState: AppState
    private let onFinish: () -> Void
    private let onRequestFocus: () -> Void
    private let appIconOverride: NSImage?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: SetupGuideStep
    @State private var movingForward = true
    @State private var visionChoice: SetupVisionChoice
    @State private var agentChoice: SetupAgentChoice = .claudeCode
    @State private var copiedKey: String?
    /// Chrome step on a build with a store ID: the user chose the bundled folder over the Chrome Web Store.
    @State private var chromeLoadUnpacked = false

    public init(
        appState: AppState,
        initialStep: SetupGuideStep = .welcome,
        appIcon: NSImage? = nil,
        onRequestFocus: @escaping () -> Void = {},
        onFinish: @escaping () -> Void
    ) {
        self.appState = appState
        self.onFinish = onFinish
        self.onRequestFocus = onRequestFocus
        self.appIconOverride = appIcon
        _step = State(initialValue: initialStep)
        _visionChoice = State(initialValue: SetupVisionChoice.initial(
            status: appState.visionStatus,
            installerAvailable: appState.isLocalVisionInstallerAvailable
        ))
    }

    public var body: some View {
        ZStack {
            SetupBackdrop()

            VStack(spacing: 0) {
                ZStack {
                    stepContent
                        .id(step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 54)
                .clipped()

                visionInstallBanner

                footer
            }
        }
        .frame(width: SetupGuideWindowController.windowSize.width, height: SetupGuideWindowController.windowSize.height)
        .onChange(of: appState.status.permissions) { old, new in
            // Granted in System Settings: come back so the user sees the check mark.
            let newlyGranted = (new.accessibilityGranted && !old.accessibilityGranted)
                || (new.screenRecordingGranted && !old.screenRecordingGranted)
            if step == .permissions && newlyGranted {
                onRequestFocus()
            }
        }
        .onChange(of: appState.connectedBrowserProfiles.isEmpty) { wasEmpty, isEmpty in
            // Pairing finished in the Chrome extension popup.
            if step == .chrome && wasEmpty && !isEmpty {
                onRequestFocus()
            }
        }
        .onChange(of: appState.hasEverConnectedAgent) { wasConnected, isConnected in
            // The agent ran the setup prompt and reached UseMac.
            if step == .agent && !wasConnected && isConnected {
                onRequestFocus()
            }
        }
        .task(id: step) {
            guard step == .permissions else { return }
            while !Task.isCancelled {
                appState.refreshPermissionFlags()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: Navigation

    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let distance: CGFloat = 26
        return .asymmetric(
            insertion: .offset(x: movingForward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: movingForward ? -distance : distance).combined(with: .opacity)
        )
    }

    private func go(to next: SetupGuideStep) {
        appState.saveSetupGuideStep(next.rawValue)
        movingForward = next.rawValue > step.rawValue
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.88)) {
            step = next
        }
    }

    private func advance() {
        if let next = SetupGuideStep(rawValue: step.rawValue + 1) {
            go(to: next)
        } else {
            onFinish()
        }
    }

    private func goBack() {
        if let previous = SetupGuideStep(rawValue: step.rawValue - 1) {
            go(to: previous)
        }
    }

    // MARK: Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .vision: visionStep
        case .chrome: chromeStep
        case .agent: agentStep
        case .ready: readyStep
        }
    }

    private func stepHeader(symbol: String?, title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            if let symbol {
                SetupHeroTile(symbol: symbol)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.6)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .frame(maxWidth: 500)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // 1. Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            SetupAppIcon(image: appIconOverride, size: 96)
                .padding(.top, 26)
                .padding(.bottom, 22)

            Text("Welcome to UseMac")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.8)

            Text("Let your AI agents use real Mac apps and Chrome tabs, quietly in the background, while you stay in control.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 18) {
                SetupFeatureRow(
                    symbol: "macwindow.on.rectangle",
                    title: "Works in the background",
                    detail: "Agents click and type in other apps without taking over your screen."
                )
                SetupFeatureRow(
                    symbol: "eye",
                    title: "Always visible",
                    detail: "A small live preview shows what the agent is doing, as it happens."
                )
                SetupFeatureRow(
                    symbol: "hand.raised",
                    title: "You stay in charge",
                    detail: "Choose what agents may do, and stop them all with ⇧⌘⎋."
                )
            }
            .frame(width: 470, alignment: .leading)
            .padding(.top, 34)
        }
        .frame(maxWidth: .infinity)
    }

    // 2. Permissions

    private var bothPermissionsGranted: Bool {
        appState.status.permissions.accessibilityGranted && appState.status.permissions.screenRecordingGranted
    }

    private var permissionsStep: some View {
        let perms = appState.status.permissions
        let showRelaunchHint = (appState.attemptedAccessibilityGrant && !perms.accessibilityGranted)
            || (appState.attemptedScreenRecordingGrant && !perms.screenRecordingGranted)

        return VStack(spacing: 28) {
            stepHeader(
                symbol: "lock.shield",
                title: "Give UseMac access",
                subtitle: "macOS asks you to allow these once. You can change them anytime in System Settings."
            )

            VStack(spacing: 0) {
                SetupRow(
                    leading: { SetupSymbolTile(symbol: "accessibility") },
                    title: "Accessibility",
                    detail: "Lets agents read buttons and fields, and click or type in the background."
                ) {
                    permissionControl(granted: perms.accessibilityGranted) {
                        appState.triggerPermissionFlow(for: .accessibility, prompt: true)
                    }
                }
                InsetDivider(leading: 64)
                SetupRow(
                    leading: { SetupSymbolTile(symbol: "rectangle.dashed.badge.record") },
                    title: "Screen Recording",
                    detail: "Lets agents take screenshots, and shows you a live preview while they work."
                ) {
                    permissionControl(granted: perms.screenRecordingGranted) {
                        appState.triggerPermissionFlow(for: .screenRecording, prompt: true)
                    }
                }
            }
            .codexCardElevation(colorScheme, cornerRadius: 16)
            .frame(width: 540)

            if showRelaunchHint {
                HStack(spacing: 8) {
                    Text("Allowed it already? macOS may need UseMac to reopen.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Quit & Reopen") {
                        appState.relaunchApp()
                    }
                    .buttonStyle(SetupLinkButtonStyle())
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func permissionControl(granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            SetupGrantedPill(label: "Allowed")
        } else {
            Button("Allow", action: action)
                .buttonStyle(PrimaryInkButtonStyle())
        }
    }

    // 3. Local vision

    private var visionStep: some View {
        let installerAvailable = appState.isLocalVisionInstallerAvailable
        let vision = appState.visionStatus

        return VStack(spacing: 22) {
            stepHeader(
                symbol: "eye.circle",
                title: "Let agents see on your Mac",
                subtitle: "Apple's built-in OCR already reads on-screen text. Add an on-device model so agents can check what they see without sending screenshots to the cloud."
            )

            VStack(spacing: 7) {
                ForEach(SetupVisionChoice.allChoices, id: \.self) { choice in
                    SetupChoiceCard(
                        title: choice.title,
                        detail: choice.detail,
                        trailing: choice.trailingLabel(status: vision),
                        trailingIsPositive: choice.isInstalled(status: vision),
                        badge: choice.badge,
                        isSelected: visionChoice == choice,
                        isEnabled: choice == .textOnly || installerAvailable
                    ) {
                        visionChoice = choice
                    }
                }
            }
            .frame(width: 540)

            Text(installerAvailable
                 ? "Runs only on your Mac. The model downloads from Hugging Face; the runtime (about 700 MB) from PyPI."
                 : "On-device models need the free uv installer. Run brew install uv, then pick a model in Settings → General → Local Vision.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func applyVisionChoice() {
        switch visionChoice {
        case .textOnly:
            if appState.visionStatus.enabled {
                appState.setLocalVisionEnabled(false)
            }
        case .model(let preset):
            if visionChoice.isInstalled(status: appState.visionStatus) {
                appState.setLocalVisionEnabled(true)
            } else if appState.isLocalVisionInstallerAvailable && appState.visionStatus.state != "installing" {
                appState.selectLocalVisionModel(preset)
                appState.installLocalVision()
            }
        }
    }

    // 4. Chrome

    private var chromeStep: some View {
        // Release builds that know the Chrome Web Store ID offer the store first, no Developer mode needed.
        // Beta builds (no ID) and anyone who picks "Load it unpacked instead" get the bundled folder.
        let hasStoreListing = UseMacDefaults.chromeWebStoreListingURL != nil
        let useStore = hasStoreListing && !chromeLoadUnpacked

        return VStack(spacing: 26) {
            stepHeader(
                symbol: "globe",
                title: "Connect Chrome",
                subtitle: "Optional. Lets agents work in your signed-in Chrome tabs, inside their own UseMac tab group."
            )

            VStack(spacing: 0) {
                if useStore {
                    SetupRow(
                        leading: { SetupNumberBadge(number: 1) },
                        title: "Add from Chrome Web Store",
                        detail: "Opens UseMac Browser Bridge in the Chrome Web Store. Click Add to Chrome."
                    ) {
                        Button("Open Web Store") { appState.installPublishedChromeExtension() }
                            .buttonStyle(SubtleOutlineButtonStyle())
                    }
                } else {
                    SetupRow(
                        leading: { SetupNumberBadge(number: 1) },
                        title: "Open the extensions page",
                        detail: "In Chrome, turn on Developer mode at the top right."
                    ) {
                        Button("Open Chrome") { appState.openChromeExtensionsPage() }
                            .buttonStyle(SubtleOutlineButtonStyle())
                    }
                    InsetDivider(leading: 64)
                    SetupRow(
                        leading: { SetupNumberBadge(number: 2) },
                        title: "Load the UseMac extension",
                        detail: "Click Load unpacked, press ⌘⇧G, paste the path and click Select."
                    ) {
                        Button(copiedKey == "path" ? "Copied" : "Copy Path") {
                            if appState.copyChromeExtensionPath() {
                                flashCopied("path")
                            }
                        }
                        .buttonStyle(SubtleOutlineButtonStyle())
                    }
                }
                InsetDivider(leading: 64)
                SetupRow(
                    leading: { SetupNumberBadge(number: useStore ? 2 : 3) },
                    title: "Pair it with this Mac",
                    detail: "Open the extension popup and paste the pairing key."
                ) {
                    Button(copiedKey == "pairing" ? "Copied" : "Copy Key") {
                        if appState.copyBridgePairingKey() {
                            flashCopied("pairing")
                        }
                    }
                    .buttonStyle(PrimaryInkButtonStyle())
                }
            }
            .codexCardElevation(colorScheme, cornerRadius: 16)
            .frame(width: 540)

            if hasStoreListing {
                Button(chromeLoadUnpacked ? "Add from Chrome Web Store instead" : "Load it unpacked instead") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        chromeLoadUnpacked.toggle()
                    }
                }
                .buttonStyle(SetupLinkButtonStyle())
                .padding(.top, -14)
            }

            chromeStatusLine
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chromeStatusLine: some View {
        if let profile = appState.connectedBrowserProfiles.first {
            SetupStatusLine(kind: .success, text: "Connected to Chrome profile “\(profile.profileName)”")
        } else if let pending = appState.pendingBrowserPairings.first {
            SetupStatusLine(kind: .attention, text: "“\(pending)” is waiting for the pairing key")
        } else {
            SetupStatusLine(kind: .waiting, text: "Waiting for the extension…")
        }
    }

    // 5. Agent

    private var agentStep: some View {
        let prompt = agentChoice.usesMCP ? appState.mcpAgentPrompt : appState.socketAgentPrompt

        return VStack(spacing: 22) {
            stepHeader(
                symbol: "sparkles",
                title: "Connect your AI agent",
                subtitle: "Paste this setup prompt into your agent. It installs the UseMac skill and checks the connection."
            )

            CodexSegmentedControl(
                selection: $agentChoice,
                options: SetupAgentChoice.allCases.map { CodexSegmentOption(value: $0, label: $0.label) }
            )

            VStack(spacing: 0) {
                HStack {
                    Text(agentChoice.usesMCP ? "Setup prompt · MCP" : "Setup prompt · Unix socket")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedKey == "prompt" ? "Copied" : "Copy Prompt") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(prompt, forType: .string)
                        flashCopied("prompt")
                    }
                    .buttonStyle(PrimaryInkButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(UseMacTheme.hairline(colorScheme))
                    .frame(height: 0.75)

                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .frame(height: 118, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [UseMacTheme.surface(colorScheme).opacity(0), UseMacTheme.surface(colorScheme)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 44)
                        .allowsHitTesting(false)
                    }
            }
            .codexCardElevation(colorScheme, cornerRadius: 16)
            .frame(width: 540)

            if appState.hasEverConnectedAgent {
                SetupStatusLine(kind: .success, text: "An agent has connected to UseMac")
            } else {
                SetupStatusLine(kind: .waiting, text: "Waiting for your agent to connect…")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // 6. Ready

    private var readyStep: some View {
        VStack(spacing: 26) {
            VStack(spacing: 14) {
                SetupSuccessMark()
                    .padding(.bottom, 4)
                Text("You're all set")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.6)
                Text("UseMac lives in your menu bar. Ask your agent to do something on your Mac and watch it work in the corner.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2.5)
                    .frame(maxWidth: 470)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        SetupSymbolTile(symbol: "slider.horizontal.3")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("What agents may do")
                                .font(.system(size: 13.5, weight: .medium))
                            Text(ExecutionModeChoices.summary(appState.status.policy))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    ExecutionModePicker(
                        selection: Binding(
                            get: { appState.status.policy },
                            set: { appState.setPolicy($0) }
                        ),
                        placement: .setupGuide
                    )
                    .padding(.leading, 46)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                InsetDivider(leading: 64)
                SetupRow(
                    leading: { SetupSymbolTile(symbol: "stop.circle") },
                    title: "Stop every agent",
                    detail: "Works from any app. Resume from the menu bar."
                ) {
                    ShortcutText("⇧⌘⎋").fixedSize()
                }
                InsetDivider(leading: 64)
                SetupRow(
                    leading: { SetupSymbolTile(symbol: "pip") },
                    title: "Show or hide the live preview",
                    detail: "You can turn this shortcut off in Settings."
                ) {
                    ShortcutText("⌥Space").fixedSize()
                }
            }
            .codexCardElevation(colorScheme, cornerRadius: 16)
            .frame(width: 540)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Vision install banner

    @ViewBuilder
    private var visionInstallBanner: some View {
        let vision = appState.visionStatus
        if step.rawValue > SetupGuideStep.vision.rawValue {
            if vision.state == "installing" {
                HStack(spacing: 8) {
                    SetupSpinner(size: 11)
                    Text("Setting up on-device vision · \(vision.installProgress ?? "Preparing…")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.bottom, 12)
                .transition(.opacity)
            } else if let error = vision.lastError, !error.isEmpty {
                Text("On-device vision couldn't be set up: \(error). You can retry in Settings → General → Local Vision.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UseMacTheme.statusAmber)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(UseMacTheme.hairline(colorScheme))
                .frame(height: 0.75)

            HStack(spacing: 0) {
                HStack {
                    if step != .welcome {
                        Button("Back", action: goBack)
                            .buttonStyle(SetupLinkButtonStyle(prominent: false))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 220, alignment: .leading)

                Spacer(minLength: 0)

                SetupStepDots(current: step.rawValue, count: SetupGuideStep.allCases.count)

                Spacer(minLength: 0)

                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    if let skip = skipLabel {
                        Button(skip, action: advance)
                            .buttonStyle(SetupLinkButtonStyle(prominent: false))
                    }
                    Button(primaryLabel, action: primaryAction)
                        .buttonStyle(SetupPrimaryButtonStyle())
                        .disabled(!primaryEnabled)
                        .keyboardShortcut(.defaultAction)
                }
                .frame(width: 280, alignment: .trailing)
            }
            .padding(.horizontal, 26)
            .frame(height: 64)
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:
            return "Get Started"
        case .permissions, .chrome, .agent:
            return "Continue"
        case .vision:
            switch visionChoice {
            case .textOnly:
                return "Continue"
            case .model(let preset):
                if visionChoice.isInstalled(status: appState.visionStatus) || !appState.isLocalVisionInstallerAvailable {
                    return "Continue"
                }
                return "Download \(SetupVisionChoice.downloadSize(preset)) & Continue"
            }
        case .ready:
            return "Start Using UseMac"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .permissions: return bothPermissionsGranted
        default: return true
        }
    }

    private var skipLabel: String? {
        switch step {
        case .permissions where !bothPermissionsGranted: return "Skip for Now"
        default: return nil
        }
    }

    private func primaryAction() {
        switch step {
        case .vision:
            applyVisionChoice()
            advance()
        case .ready:
            onFinish()
        default:
            advance()
        }
    }

    private func flashCopied(_ key: String) {
        copiedKey = key
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedKey == key {
                copiedKey = nil
            }
        }
    }
}

// MARK: - Choices

enum SetupVisionChoice: Hashable {
    case textOnly
    case model(LocalVisionModelPreset)

    static let allChoices: [SetupVisionChoice] = [
        .textOnly,
        .model(.qwen35_08B),
        .model(.qwen25VL3B),
        .model(.holo1_3B)
    ]

    static func initial(status: VisionStatus, installerAvailable: Bool) -> SetupVisionChoice {
        let current = LocalVisionModelPreset(rawValue: status.modelId)
        if status.runtimeInstalled && status.modelDownloaded, let current {
            return status.enabled ? .model(current) : .textOnly
        }
        return installerAvailable ? .model(.qwen25VL3B) : .textOnly
    }

    static func downloadSize(_ preset: LocalVisionModelPreset) -> String {
        switch preset {
        case .qwen35_08B: return "620 MB"
        case .qwen25VL3B: return "2.1 GB"
        case .holo1_3B: return "1.9 GB"
        }
    }

    var title: String {
        switch self {
        case .textOnly: return "Text only"
        case .model(.qwen35_08B): return "Qwen3.5 0.8B"
        case .model(.qwen25VL3B): return "Qwen2.5-VL 3B"
        case .model(.holo1_3B): return "Holo1 3B"
        }
    }

    var detail: String {
        switch self {
        case .textOnly: return "Built-in Apple OCR reads text on screen."
        case .model(.qwen35_08B): return "Fastest. Good for quick visual checks."
        case .model(.qwen25VL3B): return "Best balance of speed and accuracy."
        case .model(.holo1_3B): return "Tuned for finding buttons and controls."
        }
    }

    var badge: SetupBadge? {
        switch self {
        case .textOnly: return SetupBadge(text: "Included", tint: UseMacTheme.statusGreen)
        case .model(.qwen25VL3B): return SetupBadge(text: "Recommended", tint: UseMacTheme.accentActive)
        default: return nil
        }
    }

    func isInstalled(status: VisionStatus) -> Bool {
        guard case .model(let preset) = self else { return false }
        return status.runtimeInstalled && status.modelDownloaded && status.modelId == preset.rawValue
    }

    func trailingLabel(status: VisionStatus) -> String {
        switch self {
        case .textOnly:
            return "No download"
        case .model(let preset):
            return isInstalled(status: status) ? "Installed" : Self.downloadSize(preset)
        }
    }
}

enum SetupAgentChoice: String, CaseIterable, Hashable {
    case claudeCode
    case codex
    case cursor
    case other

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .other: return "Other (MCP)"
        }
    }

    var usesMCP: Bool {
        self == .cursor || self == .other
    }
}

struct SetupBadge: Hashable {
    let text: String
    let tint: Color
}

// MARK: - Building Blocks

struct SetupBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            UseMacTheme.canvas(colorScheme)
            RadialGradient(
                colors: [UseMacTheme.accentActive.opacity(dark ? 0.22 : 0.13), .clear],
                center: UnitPoint(x: 0.5, y: -0.08),
                startRadius: 0,
                endRadius: 430
            )
            RadialGradient(
                colors: [Color(red: 0.56, green: 0.46, blue: 0.96).opacity(dark ? 0.12 : 0.07), .clear],
                center: UnitPoint(x: 0.96, y: 0.02),
                startRadius: 0,
                endRadius: 320
            )
            RadialGradient(
                colors: [Color(red: 0.36, green: 0.80, blue: 0.92).opacity(dark ? 0.07 : 0.05), .clear],
                center: UnitPoint(x: 0.02, y: 0.10),
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

struct SetupAppIcon: View {
    let image: NSImage?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private static let bundledLogo: NSImage? = Bundle.main.url(forResource: "usemac-logo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        let icon = image ?? Self.bundledLogo ?? NSApp?.applicationIconImage ?? NSImage()
        ZStack {
            Circle()
                .fill(UseMacTheme.accentActive.opacity(colorScheme == .dark ? 0.30 : 0.20))
                .frame(width: size * 1.25, height: size * 1.25)
                .blur(radius: size * 0.32)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.0), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.22), radius: 16, x: 0, y: 10)
        }
        .frame(width: size * 1.25, height: size * 1.1)
        .accessibilityHidden(true)
    }
}

struct SetupHeroTile: View {
    let symbol: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.20, blue: 0.24), Color(red: 0.07, green: 0.07, blue: 0.085)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 54, height: 54)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 12, x: 0, y: 6)
        .accessibilityHidden(true)
    }
}

struct SetupSymbolTile: View {
    let symbol: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(UseMacTheme.subtleFill(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(UseMacTheme.hairline(colorScheme), lineWidth: 0.6)
            )
            .accessibilityHidden(true)
    }
}

struct SetupNumberBadge: View {
    let number: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("\(number)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(UseMacTheme.inkForeground(colorScheme))
            .frame(width: 26, height: 26)
            .background(Circle().fill(UseMacTheme.inkBackground(colorScheme)))
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

struct SetupFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SetupSymbolTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SetupRow<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let title: String
    private let detail: String
    private let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct SetupChoiceCard: View {
    let title: String
    let detail: String
    let trailing: String
    let trailingIsPositive: Bool
    let badge: SetupBadge?
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button(action: action) {
            HStack(spacing: 13) {
                SetupRadio(isSelected: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge.text)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(badge.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(badge.tint.opacity(colorScheme == .dark ? 0.18 : 0.11)))
                        }
                    }
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(trailing)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(trailingIsPositive ? UseMacTheme.statusGreen : Color.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .contentShape(shape)
            .background(
                shape.fill(
                    isSelected
                        ? UseMacTheme.surface(colorScheme)
                        : (isHovered ? UseMacTheme.surface(colorScheme).opacity(0.75) : UseMacTheme.surface(colorScheme).opacity(0.5))
                )
                .shadow(
                    color: Color.black.opacity(isSelected ? (colorScheme == .dark ? 0.4 : 0.07) : 0),
                    radius: 8,
                    x: 0,
                    y: 3
                )
            )
            .overlay(
                shape.strokeBorder(
                    isSelected ? UseMacTheme.accentActive.opacity(0.85) : UseMacTheme.hairline(colorScheme),
                    lineWidth: isSelected ? 1.4 : 0.75
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SetupRadio: View {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? UseMacTheme.accentActive : UseMacTheme.strongHairline(colorScheme),
                    lineWidth: isSelected ? 5 : 1.2
                )
                .background(Circle().fill(isSelected ? Color.white : Color.clear))
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

struct SetupGrantedPill: View {
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(UseMacTheme.statusGreen)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(UseMacTheme.statusGreen.opacity(colorScheme == .dark ? 0.16 : 0.10)))
    }
}

struct SetupStatusLine: View {
    enum Kind {
        case success
        case attention
        case waiting
    }

    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            switch kind {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(UseMacTheme.statusGreen)
            case .attention:
                Circle()
                    .fill(UseMacTheme.statusAmber)
                    .frame(width: 7, height: 7)
            case .waiting:
                SetupSpinner(size: 11)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SetupSuccessMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(UseMacTheme.statusGreen.opacity(colorScheme == .dark ? 0.30 : 0.22))
                .frame(width: 76, height: 76)
                .blur(radius: 18)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.25, green: 0.82, blue: 0.47), Color(red: 0.07, green: 0.64, blue: 0.30)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8))
                .shadow(color: UseMacTheme.statusGreen.opacity(0.35), radius: 12, x: 0, y: 6)
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 76, height: 66)
        .accessibilityHidden(true)
    }
}

struct SetupSpinner: View {
    let size: CGFloat
    @State private var rotating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
            .accessibilityHidden(true)
    }
}

struct SetupStepDots: View {
    let current: Int
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(fill(for: index))
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }

    private func fill(for index: Int) -> Color {
        if index == current {
            return UseMacTheme.inkBackground(colorScheme)
        }
        if index < current {
            return UseMacTheme.inkBackground(colorScheme).opacity(0.38)
        }
        return UseMacTheme.strongHairline(colorScheme)
    }
}

struct SetupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(UseMacTheme.inkForeground(colorScheme))
            .padding(.horizontal, 18)
            .padding(.vertical, 8.5)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(UseMacTheme.inkBackground(colorScheme).opacity(configuration.isPressed ? 0.86 : 1.0))
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.16),
                        radius: configuration.isPressed ? 2 : 7,
                        x: 0,
                        y: configuration.isPressed ? 1 : 3
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0 : 0.10), lineWidth: 0.6)
            )
            .opacity(isEnabled ? 1 : 0.32)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SetupLinkButtonStyle: ButtonStyle {
    var prominent: Bool = true
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 12 : 13, weight: .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(UseMacTheme.accentActive) : AnyShapeStyle(isHovered ? Color.primary : Color.secondary))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { isHovered = $0 }
    }
}
