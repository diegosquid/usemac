import AppKit
import SwiftUI
import UseMacProtocol

public final class AgentOverlayPanel: NSPanel {
    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

@MainActor
public final class AgentOverlayCoordinator {
    private let appState: AppState
    private var panels: [AgentOverlayPanel] = []
    private var screenObserver: NSObjectProtocol?

    public init(appState: AppState) {
        self.appState = appState
        rebuildPanels()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanels()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func rebuildPanels() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()

        let screens = NSScreen.screens
        let primaryScreen = screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 0

        for screen in screens {
            let panel = AgentOverlayPanel(screen: screen)
            let view = AgentOverlayView(
                appState: appState,
                screenFrame: screen.frame,
                primaryHeight: primaryHeight > 0 ? primaryHeight : screen.frame.height
            )
            let hosting = NSHostingView(rootView: view)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}

public struct AgentOverlayView: View {
    @ObservedObject public var appState: AppState
    public let screenFrame: CGRect
    public let primaryHeight: CGFloat

    @State private var pulseExpanded = false

    public init(
        appState: AppState,
        screenFrame: CGRect,
        primaryHeight: CGFloat
    ) {
        self.appState = appState
        self.screenFrame = screenFrame
        self.primaryHeight = primaryHeight
    }

    private var screenCGTopY: Double {
        Double(primaryHeight - (screenFrame.origin.y + screenFrame.height))
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // The panels sit above every app on every Space, so only draw where the target window is really
            // visible. Otherwise the HUD preview shows the highlight on the window itself.
            if let rect = appState.highlightedRect,
               appState.highlightTarget?.isVisibleOnScreen ?? true,
               rectIntersectsScreen(rect) {
                highlightBox(for: rect)
            }

            if let pulse = appState.pulsePoint, pulse.isVisibleOnScreen, pointInsideScreen(x: pulse.x, y: pulse.y) {
                rippleView(for: pulse)
                    .id(pulse.id)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: appState.highlightedRect)
    }

    @ViewBuilder
    private func highlightBox(for rect: ScreenRect) -> some View {
        let localX = rect.x - Double(screenFrame.origin.x)
        let localY = rect.y - screenCGTopY
        let boxWidth = max(4, rect.width)
        let boxHeight = max(4, rect.height)
        let pillText = formattedHighlightLabel()

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                )
                .frame(width: boxWidth, height: boxHeight)
                .offset(x: localX, y: localY)

            if let pillText {
                let pillY = localY >= 26 ? localY - 24 : localY + boxHeight + 4
                Text(pillText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.92), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 4, x: 0, y: 1)
                    .offset(x: max(6, localX), y: max(6, pillY))
            }
        }
    }

    private func rippleView(for pulse: OverlayPulse) -> some View {
        let localX = pulse.x - Double(screenFrame.origin.x)
        let localY = pulse.y - screenCGTopY

        return ZStack {
            Circle()
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: pulseExpanded ? 44 : 10, height: pulseExpanded ? 44 : 10)
                .opacity(pulseExpanded ? 0.0 : 0.9)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .opacity(pulseExpanded ? 0.2 : 1.0)

            if let label = pulse.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.9), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(y: -24)
            }
        }
        .position(x: localX, y: localY)
        .onAppear {
            pulseExpanded = false
            withAnimation(.easeOut(duration: 0.65)) {
                pulseExpanded = true
            }
        }
    }

    private func formattedHighlightLabel() -> String? {
        guard let label = appState.highlightLabel, !label.isEmpty else { return nil }
        if let role = appState.highlightRole, !role.isEmpty {
            let shortRole = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return "\(label) · \(shortRole)"
        }
        return label
    }

    private func rectIntersectsScreen(_ rect: ScreenRect) -> Bool {
        let cgFrame = CGRect(
            x: Double(screenFrame.origin.x),
            y: screenCGTopY,
            width: Double(screenFrame.width),
            height: Double(screenFrame.height)
        )
        let target = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        return cgFrame.intersects(target)
    }

    private func pointInsideScreen(x: Double, y: Double) -> Bool {
        let cgFrame = CGRect(
            x: Double(screenFrame.origin.x),
            y: screenCGTopY,
            width: Double(screenFrame.width),
            height: Double(screenFrame.height)
        )
        return cgFrame.contains(CGPoint(x: x, y: y))
    }
}
