import AppKit
import Combine
import UseMacEngine
import UseMacProtocol

@main
public struct UseMacAppEntry {
    @MainActor
    public static func main() {
        let app = NSApplication.shared
        let delegate = UseMacAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
public final class UseMacAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var appState: AppState!
    private var hudController: ActivityHUDController!
    private var overlayCoordinator: AgentOverlayCoordinator!
    private var approvalPromptController: ApprovalPromptController!
    private var controlCenterController: ControlCenterWindowController!
    private var permissionHelperController: PermissionDragHelperController!
    private var setupGuideController: SetupGuideWindowController!
    private var hotKeyManager: HotKeyManager!

    private var statusItem: NSStatusItem!
    private weak var statusHeaderItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOlderInstances()

        let state = AppState()
        self.appState = state
        self.hudController = ActivityHUDController(appState: state)
        self.overlayCoordinator = AgentOverlayCoordinator(appState: state)
        self.approvalPromptController = ApprovalPromptController(appState: state, hud: hudController)
        self.controlCenterController = ControlCenterWindowController(appState: state)
        self.permissionHelperController = PermissionDragHelperController(appState: state)
        self.setupGuideController = SetupGuideWindowController(appState: state)

        state.onShowPermissionHelper = { [weak self] kind in
            self?.permissionHelperController.show(for: kind)
        }

        let hotKeys = HotKeyManager()
        hotKeys.onToggleHUD = { [weak self] in
            self?.appState.toggleHUD()
        }
        hotKeys.onToggleKillSwitch = { [weak self] in
            self?.appState.toggleKillSwitch()
        }
        hotKeys.onStateChanged = { [weak self, weak hotKeys] in
            guard let self, let hotKeys else { return }
            self.appState.updateShortcutState(
                optionSpaceEnabled: hotKeys.isOptionSpaceEnabled,
                failedShortcuts: hotKeys.failedShortcuts
            )
        }
        state.onSetOptionSpaceShortcutEnabled = { [weak hotKeys] enabled in
            hotKeys?.setOptionSpaceEnabled(enabled)
        }
        state.updateShortcutState(
            optionSpaceEnabled: hotKeys.isOptionSpaceEnabled,
            failedShortcuts: hotKeys.failedShortcuts
        )
        self.hotKeyManager = hotKeys

        setupStatusItem()
        setupMainMenu()
        observeStatusUpdates()
        observeWindowsForDockPresence()
        state.startDaemon()

        let perms = state.status.permissions
        if !state.hasCompletedSetupGuide {
            setupGuideController.show()
        } else if !perms.accessibilityGranted || !perms.screenRecordingGranted {
            controlCenterController.show()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if setupGuideController.isVisible {
            setupGuideController.show()
        } else {
            controlCenterController.show()
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appState?.stopDaemon()
    }

    private func terminateOlderInstances() {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "app.usemac"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != currentPid }
        for app in others {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func observeStatusUpdates() {
        Publishers.CombineLatest4(
            appState.$status,
            appState.$isActivityIndicatorLit.removeDuplicates(),
            appState.$activeAgentNames.removeDuplicates(),
            appState.$activeTargetApp.map { $0?.name }.removeDuplicates()
        )
            .combineLatest(appState.$isServerRunning.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusIcon()
                self.statusHeaderItem?.attributedTitle = self.makeStatusHeaderAttributedTitle()
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let policy = appState.status.policy
        let tripped = appState.status.killSwitchTripped
        // Read-only, Paused and the Emergency stop badge the icon; the tooltip names any mode but Autonomous.
        let badge = ExecutionModeNotice.badge(policy: policy, killSwitchTripped: tripped)
        let acting = !tripped && policy != .paused && appState.isActivityIndicatorLit
        let active = acting && badge == .none
        button.image = Self.makeMenuBarIcon(badge: badge, active: active)
        button.imagePosition = .imageOnly
        button.toolTip = ExecutionModeNotice.tooltip(
            policy: policy,
            killSwitchTripped: tripped,
            agentActing: acting,
            activeAgents: appState.activeAgentNames
        )
    }

    private static func makeMenuBarIcon(badge: ExecutionModeNotice.Badge, active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)

            let fgColor: NSColor
            if active {
                let isDarkBar = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                fgColor = isDarkBar ? NSColor.white : NSColor.black.withAlphaComponent(0.92)
            } else {
                fgColor = NSColor.black
            }
            cg.setStrokeColor(fgColor.cgColor)
            cg.setFillColor(fgColor.cgColor)

            // Continuous geometric Command Knot (⌘) mark centered in 18x18 (flipped: false => +Y is up)
            let cx: CGFloat = 9.0
            let cy: CGFloat = 9.0
            let d: CGFloat = 2.35
            let r: CGFloat = 2.15
            let cmdPath = CGMutablePath()
            cmdPath.move(to: CGPoint(x: cx - d, y: cy + d + r))
            // Top-left loop (270 deg CCW from 0 to 3pi/2)
            cmdPath.addArc(center: CGPoint(x: cx - d - r, y: cy + d + r), radius: r, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            // Top rail -> top-right loop (270 deg CCW from 3pi/2 to pi)
            cmdPath.addLine(to: CGPoint(x: cx + d + r, y: cy + d))
            cmdPath.addArc(center: CGPoint(x: cx + d + r, y: cy + d + r), radius: r, startAngle: .pi * 1.5, endAngle: .pi, clockwise: false)
            // Right rail -> bottom-right loop (270 deg CCW from pi to pi/2)
            cmdPath.addLine(to: CGPoint(x: cx + d, y: cy - d - r))
            cmdPath.addArc(center: CGPoint(x: cx + d + r, y: cy - d - r), radius: r, startAngle: .pi, endAngle: .pi * 0.5, clockwise: false)
            // Bottom rail -> bottom-left loop (270 deg CCW from pi/2 to 0)
            cmdPath.addLine(to: CGPoint(x: cx - d - r, y: cy - d))
            cmdPath.addArc(center: CGPoint(x: cx - d - r, y: cy - d - r), radius: r, startAngle: .pi * 0.5, endAngle: 0, clockwise: false)
            cmdPath.closeSubpath()

            cg.addPath(cmdPath)
            cg.setLineWidth(1.65)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.strokePath()

            if badge == .paused {
                // Crisp negative-space badge with two-bar pause indicator at bottom-right
                let badgeRect = CGRect(x: 10.4, y: 1.4, width: 6.4, height: 6.4)
                cg.saveGState()
                cg.setBlendMode(.clear)
                cg.addEllipse(in: badgeRect.insetBy(dx: -0.9, dy: -0.9))
                cg.fillPath()
                cg.restoreGState()

                let bar1 = CGPath(roundedRect: CGRect(x: 11.7, y: 2.6, width: 1.45, height: 4.0), cornerWidth: 0.55, cornerHeight: 0.55, transform: nil)
                let bar2 = CGPath(roundedRect: CGRect(x: 14.05, y: 2.6, width: 1.45, height: 4.0), cornerWidth: 0.55, cornerHeight: 0.55, transform: nil)
                cg.addPath(bar1)
                cg.addPath(bar2)
                cg.fillPath()
            } else if badge == .readOnly {
                // Read-only: an eye (agents can look, not act) in the same negative-space badge
                let badgeRect = CGRect(x: 10.4, y: 1.4, width: 6.4, height: 6.4)
                cg.saveGState()
                cg.setBlendMode(.clear)
                cg.addEllipse(in: badgeRect.insetBy(dx: -0.9, dy: -0.9))
                cg.fillPath()
                cg.restoreGState()

                let eyeCenter = CGPoint(x: badgeRect.midX, y: badgeRect.midY)
                let eye = CGMutablePath()
                eye.move(to: CGPoint(x: eyeCenter.x - 3.3, y: eyeCenter.y))
                eye.addQuadCurve(to: CGPoint(x: eyeCenter.x + 3.3, y: eyeCenter.y), control: CGPoint(x: eyeCenter.x, y: eyeCenter.y + 2.75))
                eye.addQuadCurve(to: CGPoint(x: eyeCenter.x - 3.3, y: eyeCenter.y), control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - 2.75))
                eye.closeSubpath()
                cg.addPath(eye)
                cg.setLineWidth(1.0)
                cg.strokePath()
                cg.addEllipse(in: CGRect(x: eyeCenter.x - 1.0, y: eyeCenter.y - 1.0, width: 2.0, height: 2.0))
                cg.fillPath()
            } else if active {
                // Crisp calm glacier-sky live activity dot with tight negative-space halo at bottom-right
                let dotCenter = CGPoint(x: 14.8, y: 3.4)
                let cutoutRadius: CGFloat = 3.0
                let dotRadius: CGFloat = 2.15

                cg.saveGState()
                cg.setBlendMode(.clear)
                cg.addEllipse(in: CGRect(
                    x: dotCenter.x - cutoutRadius,
                    y: dotCenter.y - cutoutRadius,
                    width: cutoutRadius * 2,
                    height: cutoutRadius * 2
                ))
                cg.fillPath()
                cg.restoreGState()

                let activeSky = NSColor(srgbRed: 0.231, green: 0.549, blue: 0.961, alpha: 1.0) // #3B8CF5
                cg.setFillColor(activeSky.cgColor)
                cg.addEllipse(in: CGRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
                cg.fillPath()
            }

            return true
        }
        image.isTemplate = !active
        return image
    }

    private func makeStatusHeaderAttributedTitle() -> NSAttributedString {
        let dotColor: NSColor
        if appState.status.killSwitchTripped {
            dotColor = .systemRed
        } else if appState.status.policy == .paused {
            dotColor = .systemOrange
        } else if appState.isActivityIndicatorLit {
            dotColor = NSColor(srgbRed: 0.231, green: 0.549, blue: 0.961, alpha: 1.0)
        } else {
            dotColor = appState.isServerRunning ? .systemGreen : .systemRed
        }
        let label = ExecutionModeNotice.menuBarStatusLabel(
            policy: appState.status.policy,
            killSwitchTripped: appState.status.killSwitchTripped,
            isServerRunning: appState.isServerRunning,
            agentActing: appState.isActivityIndicatorLit,
            activeAgents: appState.activeAgentNames,
            targetAppName: appState.activeTargetApp?.name
        )

        let result = NSMutableAttributedString(
            string: "●  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: dotColor,
                .baselineOffset: 1.0
            ]
        )
        result.append(NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        return result
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        appState.refreshState()

        let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerItem.attributedTitle = makeStatusHeaderAttributedTitle()
        headerItem.isEnabled = false
        statusHeaderItem = headerItem
        menu.addItem(headerItem)

        // Once after the safety settings were changed outside UseMac (it started paused), until the user resumes or
        // dismisses it in Settings → Safety.
        if let notice = appState.safetySealNotice {
            let noticeItem = NSMenuItem(title: notice.menuTitle, action: #selector(openSafetySettings), keyEquivalent: "")
            noticeItem.subtitle = notice.menuSubtitle
            noticeItem.target = self
            menu.addItem(noticeItem)
        }

        // "Mode: Read-only" while the mode isn't Autonomous, so a mode the user didn't mean to keep can't hide.
        let policy = appState.status.policy
        if let modeTitle = ExecutionModeNotice.menuTitle(policy: policy) {
            let modeItem = NSMenuItem(title: modeTitle, action: #selector(openSafetySettings), keyEquivalent: "")
            modeItem.subtitle = ExecutionModeNotice.menuSubtitle(policy: policy)
            modeItem.toolTip = "Change it in Settings → Safety"
            modeItem.target = self
            menu.addItem(modeItem)
        }

        // "Debug Capture: On" while agents may capture UseMac's own windows, with a way to turn it off right here.
        if appState.isDebugCaptureEnabled {
            let debugItem = NSMenuItem(title: DebugCaptureNotice.menuTitle, action: #selector(openDeveloperSettings), keyEquivalent: "")
            debugItem.subtitle = DebugCaptureNotice.menuSubtitle
            debugItem.toolTip = "Open Settings → Developer"
            debugItem.target = self
            menu.addItem(debugItem)

            let debugOffItem = NSMenuItem(title: DebugCaptureNotice.menuTurnOffTitle, action: #selector(turnOffDebugCapture), keyEquivalent: "")
            debugOffItem.target = self
            menu.addItem(debugOffItem)
        }

        let perms = appState.status.permissions
        if !perms.accessibilityGranted || !perms.screenRecordingGranted {
            let permsItem = NSMenuItem(
                title: "Allow Permissions…",
                action: #selector(openControlCenter),
                keyEquivalent: ""
            )
            permsItem.target = self
            menu.addItem(permsItem)
        }

        menu.addItem(.separator())

        let pauseTitle = appState.isAutomationPaused ? "Resume Agents" : "Stop All Agents"
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(toggleKillSwitch),
            keyEquivalent: "\u{1b}"
        )
        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        pauseItem.target = self
        menu.addItem(pauseItem)

        let previewItem = NSMenuItem(
            title: appState.isHUDVisible ? "Hide Live Preview" : "Show Live Preview",
            action: #selector(toggleHUD),
            keyEquivalent: ""
        )
        previewItem.target = self
        menu.addItem(previewItem)

        let setupGuideItem = NSMenuItem(
            title: "Setup Guide…",
            action: #selector(openSetupGuide),
            keyEquivalent: ""
        )
        setupGuideItem.target = self
        menu.addItem(setupGuideItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openControlCenter),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        if appState.updater.isConfiguredForRelease {
            let updateItem = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            updateItem.target = self
            updateItem.isEnabled = appState.updater.canCheckForUpdates
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Dock presence while a window is open

    /// UseMac normally lives only in the menu bar. While the setup guide or Settings is open it also
    /// shows in the Dock and in ⌘Tab, so the window can't get lost behind Chrome or System Settings.
    private func observeWindowsForDockPresence() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateActivationPolicy()
            }
        }
        center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The closing window is still visible here; re-check once it is gone.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateActivationPolicy()
                }
            }
        }
    }

    private func hasOpenStandardWindow() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
        }
    }

    private func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = hasOpenStandardWindow() ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Minimal menu bar menus for while UseMac is in the Dock: About, Settings, Quit, editing and Close (⌘W).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "UseMac")
        appMenu.addItem(withTitle: "About UseMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let guideItem = appMenu.addItem(withTitle: "Setup Guide…", action: #selector(openSetupGuide), keyEquivalent: "")
        guideItem.target = self
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openControlCenter), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide UseMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit UseMac", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSetupGuide() {
        setupGuideController.show()
    }

    @objc private func openControlCenter() {
        controlCenterController.show()
    }

    @objc private func openSafetySettings() {
        controlCenterController.show(section: .overview, scrollTo: .safety)
    }

    @objc private func openDeveloperSettings() {
        controlCenterController.show(section: .overview, scrollTo: .developer)
    }

    @objc private func turnOffDebugCapture() {
        appState.turnOffDebugCapture()
    }

    @objc private func checkForUpdates() {
        appState.updater.checkForUpdates()
    }

    @objc private func toggleKillSwitch() {
        appState.toggleKillSwitch()
    }

    @objc private func toggleHUD() {
        appState.toggleHUD()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
