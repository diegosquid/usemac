import AppKit
import Combine
import MacUseProtocol

@main
public struct MacUseAppEntry {
    @MainActor
    public static func main() {
        let app = NSApplication.shared
        let delegate = MacUseAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
public final class MacUseAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var appState: AppState!
    private var hudController: ActivityHUDController!
    private var overlayCoordinator: AgentOverlayCoordinator!
    private var controlCenterController: ControlCenterWindowController!
    private var permissionHelperController: PermissionDragHelperController!
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
        self.controlCenterController = ControlCenterWindowController(appState: state)
        self.permissionHelperController = PermissionDragHelperController(appState: state)

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
        observeStatusUpdates()
        state.startDaemon()

        let perms = state.status.permissions
        if !perms.accessibilityGranted || !perms.screenRecordingGranted {
            controlCenterController.show()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlCenterController.show()
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
        appState.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusIcon()
                self.statusHeaderItem?.attributedTitle = self.makeStatusHeaderAttributedTitle()
            }
            .store(in: &cancellables)

        appState.$isActivityIndicatorLit
            .removeDuplicates()
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
        let paused = appState.status.killSwitchTripped || appState.status.policy == .paused
        let active = !paused && appState.isActivityIndicatorLit
        button.image = Self.makeMenuBarIcon(paused: paused, active: active)
        button.imagePosition = .imageOnly
        if paused {
            button.toolTip = "usemac (Paused / Kill Switch Active)"
        } else if active {
            button.toolTip = "usemac (Agent Acting)"
        } else {
            button.toolTip = "usemac (Running)"
        }
    }

    private static func makeMenuBarIcon(paused: Bool, active: Bool) -> NSImage {
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

            if paused {
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
        let label: String

        if appState.status.killSwitchTripped {
            dotColor = .systemRed
            label = "Stopped"
        } else if appState.status.policy == .paused {
            dotColor = .systemOrange
            label = "Paused"
        } else if appState.isActivityIndicatorLit {
            dotColor = NSColor(srgbRed: 0.231, green: 0.549, blue: 0.961, alpha: 1.0)
            if let appName = appState.activeTargetApp?.name, !appName.isEmpty {
                label = "Acting in \(appName)"
            } else {
                label = "Agent active"
            }
        } else if appState.isServerRunning {
            dotColor = .systemGreen
            label = "Ready"
        } else {
            dotColor = .systemRed
            label = "Offline"
        }

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

    @objc private func openControlCenter() {
        controlCenterController.show()
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
