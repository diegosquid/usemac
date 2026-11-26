import AppKit
import Combine
import SwiftUI
import UseMacEngine
import UseMacProtocol

private enum ApprovalPalette {
    static let ink = Color(red: 0.153, green: 0.153, blue: 0.165)          // #27272A
    static let softIcon = Color(red: 0.443, green: 0.443, blue: 0.478)     // #71717A
    static let whisper = Color(red: 0.631, green: 0.631, blue: 0.667)      // #A1A1AA
    static let softPillBg = Color(red: 0.957, green: 0.957, blue: 0.965)   // #F4F4F6
    static let hairline = Color.black.opacity(0.07)
    static let amber = Color(red: 0.859, green: 0.549, blue: 0.086)
    static let codeBg = Color(red: 0.965, green: 0.967, blue: 0.976)
}

/// Ask mode's prompt: a card docked at the HUD's corner that shows what a held request wants to do, with Deny and
/// Allow buttons only a physical click can press.
///
/// It lives in its own panel (not inside the HUD's SwiftUI tree) so that:
/// - the panel drops every pointer event some process posted before any view sees it (`ApprovalPromptPanel`);
/// - its buttons are plain NSViews that track the click themselves and refuse AXPress, so no Accessibility client
///   (System Events, another agent's AX tool) can press them;
/// - it shows even when the HUD is hidden or collapsed.
@MainActor
final class ApprovalPromptController {
    private let appState: AppState
    private let hud: ActivityHUDController
    private let panel: ApprovalPromptPanel
    private let model = ApprovalPromptModel()
    private let hostingView: NSHostingView<ApprovalPromptView>
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    private let width: CGFloat = 316
    private let gap: CGFloat = 8
    private let edgeMargin: CGFloat = 14

    init(appState: AppState, hud: ActivityHUDController) {
        self.appState = appState
        self.hud = hud
        self.panel = ApprovalPromptPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160))

        let broker = appState.engine.approvals
        let rawTimeout = UserDefaults.standard.object(forKey: ApprovalTiming.timeoutDefaultsKey) as? Int
        broker.timeoutSeconds = ApprovalTiming.clampedTimeoutSeconds(rawTimeout)

        let view = ApprovalPromptView(model: model) { [weak appState] promptId, decision, click in
            appState?.engine.approvals.decide(promptId: promptId, decision: decision, click: click)
        }
        self.hostingView = NSHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        panel.onIgnoredInput = { [weak self] sourcePid in
            guard let self, let prompt = self.model.prompt else { return }
            self.appState.engine.noteIgnoredApprovalInput(promptId: prompt.id, sourcePid: sourcePid)
        }

        broker.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        // Follow the HUD when it moves, opens, collapses or grows.
        appState.$hudCorner.map { _ in () }
            .merge(with: appState.$isHUDVisible.map { _ in () })
            .merge(with: appState.$isHUDCollapsed.map { _ in () })
            .merge(with: appState.$isHUDLarge.map { _ in () })
            .merge(with: appState.$hudDeck.map { _ in () })
            .debounce(for: .milliseconds(260), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reposition() }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reposition()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func refresh() {
        let prompt = appState.engine.approvals.currentPrompt
        if prompt?.id != model.prompt?.id {
            // A new prompt (or the next one in the queue) arms its buttons only after it has been on screen a moment,
            // so a click meant for the previous prompt or for what was under the pointer never answers it.
            model.armedAt = ProcessInfo.processInfo.systemUptime + ApprovalInputCheck.armingDelaySeconds
        }
        model.prompt = prompt
        if prompt == nil {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let wasVisible = panel.isVisible
        reposition()
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        appState.engine.setApprovalPromptFrame(nil)
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func reposition() {
        guard model.prompt != nil else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = NSSize(width: width, height: max(120, ceil(fitting.height)))
        let frame = dockedFrame(size: size)
        panel.setFrame(frame, display: true)
        appState.engine.setApprovalPromptFrame(Self.globalTopLeftRect(frame))
    }

    /// Next to the HUD when it shows (above it in a bottom corner, below it in a top corner), else in its corner.
    private func dockedFrame(size: NSSize) -> NSRect {
        let corner = appState.hudCorner
        let hudFrame = hud.isVisible ? hud.panelFrame : nil
        let screen = hudFrame.flatMap { frame in
            NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        let isTrailing = corner == .topTrailing || corner == .bottomTrailing
        let isBottom = corner == .bottomLeading || corner == .bottomTrailing

        var x: CGFloat
        var y: CGFloat
        if let hudFrame {
            x = isTrailing ? hudFrame.maxX - size.width : hudFrame.minX
            y = isBottom ? hudFrame.maxY + gap : hudFrame.minY - gap - size.height
        } else {
            x = isTrailing ? visible.maxX - edgeMargin - size.width : visible.minX + edgeMargin
            y = isBottom ? visible.minY + edgeMargin : visible.maxY - edgeMargin - size.height
        }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }

    /// Cocoa screen frame (bottom-left origin) to the global top-left coordinates CGEvents use.
    static func globalTopLeftRect(_ frame: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

@MainActor
final class ApprovalPromptModel: ObservableObject {
    @Published var prompt: ApprovalPrompt?
    /// When the buttons go live, in `ProcessInfo.systemUptime` (the clock NSEvent timestamps use).
    @Published var armedAt: TimeInterval = 0
    @Published var pressed: ApprovalBroker.Decision?
}

/// A panel that never becomes key (so no keystroke reaches it) and drops pointer events some process posted.
final class ApprovalPromptPanel: NSPanel {
    var onIgnoredInput: ((Int64) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if Self.isPointerEvent(event.type), !ApprovalInputCheck.isPhysical(event.cgEvent) {
            if Self.isPress(event.type) {
                onIgnoredInput?(ApprovalInputCheck.sourcePid(of: event.cgEvent) ?? -1)
            }
            return
        }
        super.sendEvent(event)
    }

    private static func isPointerEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel,
             .pressure, .tabletPoint, .tabletProximity:
            return true
        default:
            return false
        }
    }

    private static func isPress(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }
}

struct ApprovalPromptView: View {
    @ObservedObject var model: ApprovalPromptModel
    let onDecide: (String, ApprovalBroker.Decision, ApprovalInputCheck.PhysicalClick) -> Void

    var body: some View {
        if let prompt = model.prompt {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                card(prompt, now: context.date)
            }
            .frame(width: 316)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ prompt: ApprovalPrompt, now: Date) -> some View {
        let remaining = max(0, Int(prompt.deadline.timeIntervalSince(now).rounded(.up)))
        let armed = ProcessInfo.processInfo.systemUptime >= model.armedAt
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ApprovalPalette.amber)
                    .frame(width: 6, height: 6)
                Text("Allow this step?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ApprovalPalette.ink)
                Spacer(minLength: 6)
                Text("Denied in \(remaining) s")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(remaining <= 10 ? ApprovalPalette.amber : ApprovalPalette.whisper)
            }

            Text(prompt.target)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ApprovalPalette.softIcon)
                .lineLimit(2)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(prompt.steps.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ApprovalPalette.ink)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(ApprovalPalette.codeBg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(spacing: 6) {
                button("Deny", decision: .deny, prompt: prompt, armed: armed, primary: false)
                Spacer(minLength: 0)
                if prompt.canAllowForTask {
                    button("Allow for this task", decision: .allowForTask, prompt: prompt, armed: armed, primary: false)
                }
                button("Allow once", decision: .allowOnce, prompt: prompt, armed: armed, primary: true)
            }

            Text(footer(prompt))
                .font(.system(size: 10.5))
                .foregroundStyle(ApprovalPalette.whisper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.985), in: shape)
        .overlay(shape.strokeBorder(ApprovalPalette.amber.opacity(0.45), lineWidth: 1))
        .padding(1)
    }

    private func footer(_ prompt: ApprovalPrompt) -> String {
        var parts: [String] = []
        if prompt.waitingBehind > 0 {
            parts.append("\(prompt.waitingBehind) more waiting.")
        }
        if prompt.canAllowForTask {
            let kinds = prompt.kinds.sorted { $0.rawValue < $1.rawValue }.map(\.pluralNoun).joined(separator: " and ")
            parts.append("For this task: also allows \(kinds) here until the task ends.")
        }
        parts.append("Click with your mouse or trackpad; agents can't answer this.")
        return parts.joined(separator: " ")
    }

    private func button(
        _ title: String,
        decision: ApprovalBroker.Decision,
        prompt: ApprovalPrompt,
        armed: Bool,
        primary: Bool
    ) -> some View {
        let isPressed = model.pressed == decision
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(primary ? Color.white : ApprovalPalette.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                shape.fill(primary ? ApprovalPalette.ink.opacity(isPressed ? 0.8 : 1) : (isPressed ? ApprovalPalette.hairline : ApprovalPalette.softPillBg))
            )
            .overlay(shape.strokeBorder(ApprovalPalette.hairline, lineWidth: primary ? 0 : 0.8))
            .opacity(armed ? 1 : 0.45)
            .accessibilityHidden(true)
            .overlay(
                ApprovalClickTarget(
                    title: title,
                    armedAt: model.armedAt,
                    onPressChange: { pressing in model.pressed = pressing ? decision : nil },
                    onClick: { click in onDecide(prompt.id, decision, click) }
                )
            )
    }
}

/// The clickable area of a prompt button. It tracks the click itself and hands over a `PhysicalClick` only when
/// both the press and the release came from the HID system. It refuses AXPress.
struct ApprovalClickTarget: NSViewRepresentable {
    let title: String
    let armedAt: TimeInterval
    let onPressChange: (Bool) -> Void
    let onClick: (ApprovalInputCheck.PhysicalClick) -> Void

    func makeNSView(context: Context) -> ApprovalClickTargetView {
        let view = ApprovalClickTargetView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ApprovalClickTargetView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ApprovalClickTargetView) {
        view.title = title
        view.armedAt = armedAt
        view.onPressChange = onPressChange
        view.onClick = onClick
    }
}

final class ApprovalClickTargetView: NSView {
    var title = ""
    var armedAt: TimeInterval = .greatestFiniteMagnitude
    var onPressChange: ((Bool) -> Void)?
    var onClick: ((ApprovalInputCheck.PhysicalClick) -> Void)?

    private var downEvent: CGEvent?
    private var downTime: TimeInterval = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The panel already dropped posted events; check again here so the button never depends on the window.
        guard ApprovalInputCheck.isPhysical(event.cgEvent), event.timestamp >= armedAt else {
            downEvent = nil
            return
        }
        downEvent = event.cgEvent
        downTime = event.timestamp
        onPressChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard downEvent != nil else { return }
        onPressChange?(isInside(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downEvent = nil
            onPressChange?(false)
        }
        guard let down = downEvent, isInside(event),
              let click = ApprovalInputCheck.verifyClick(
                down: down,
                up: event.cgEvent,
                downTime: downTime,
                upTime: event.timestamp,
                armedAt: armedAt
              ) else { return }
        onClick?(click)
    }

    private func isInside(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    // Readable by VoiceOver, but not pressable: an Accessibility client must never answer the prompt.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityHelp() -> String? {
        "Click it with the mouse or trackpad. Accessibility actions can't press it."
    }
    override func accessibilityPerformPress() -> Bool { false }
}
