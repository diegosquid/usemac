import AppKit
import SwiftUI

public enum PermissionKind: Equatable, Sendable {
    case accessibility
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    public var dragPromptTitle: String {
        switch self {
        case .accessibility: return "Drag usemac into Accessibility"
        case .screenRecording: return "Drag usemac into Screen Recording"
        }
    }

    public var dragPromptSubtitle: String {
        switch self {
        case .accessibility:
            return "Drop onto System Settings. If already on after a rebuild, remove it (−) or reset below, then drag again."
        case .screenRecording:
            return "Drop onto System Settings. If already on after a rebuild, remove it (−) or reset below, then drag again."
        }
    }

    public var other: PermissionKind {
        switch self {
        case .accessibility: return .screenRecording
        case .screenRecording: return .accessibility
        }
    }
}

// MARK: - Native AppKit Draggable App Icon (Finder-compatible fileURL drag)

private final class DraggableAppIconNSView: NSView, NSDraggingSource {
    private let appURL: URL
    private let appIcon: NSImage
    private var dragOrigin: NSPoint?
    private var didStartDrag = false
    var onDragStateChanged: ((Bool) -> Void)?

    init(appURL: URL) {
        self.appURL = appURL
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 44, height: 44)
        self.appIcon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Critical for non-activating floating panels: start dragging on the very first click
    // even while System Settings remains the frontmost active app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let iconSize: CGFloat = 42
        let drawRect = NSRect(
            x: (bounds.width - iconSize) / 2.0,
            y: (bounds.height - iconSize) / 2.0,
            width: iconSize,
            height: iconSize
        )
        appIcon.draw(in: drawRect)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = hypot(current.x - origin.x, current.y - origin.y)
        guard distance >= 2.0 else { return }

        didStartDrag = true
        onDragStateChanged?(true)

        let dragItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let previewSize: CGFloat = 52
        let previewImage = NSWorkspace.shared.icon(forFile: appURL.path)
        previewImage.size = NSSize(width: previewSize, height: previewSize)
        let frame = NSRect(
            x: current.x - previewSize / 2.0,
            y: current.y - previewSize / 2.0,
            width: previewSize,
            height: previewSize
        )
        dragItem.setDraggingFrame(frame, contents: previewImage)

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        didStartDrag = false
        onDragStateChanged?(false)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragOrigin = nil
        didStartDrag = false
        onDragStateChanged?(false)
    }
}

private struct DraggableAppIconView: NSViewRepresentable {
    let appURL: URL
    @Binding var isDragging: Bool

    func makeNSView(context: Context) -> DraggableAppIconNSView {
        let view = DraggableAppIconNSView(appURL: appURL)
        view.onDragStateChanged = { dragging in
            DispatchQueue.main.async {
                isDragging = dragging
            }
        }
        return view
    }

    func updateNSView(_ nsView: DraggableAppIconNSView, context: Context) {
        nsView.onDragStateChanged = { dragging in
            DispatchQueue.main.async {
                isDragging = dragging
            }
        }
    }
}

// MARK: - Floating Helper Panel & Controller

public final class PermissionDragHelperPanel: NSPanel {
    public var onEscape: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
private final class PermissionHelperModel: ObservableObject {
    @Published var kind: PermissionKind = .accessibility
    @Published var isGranted: Bool = false
    @Published var otherMissing: Bool = false
}

@MainActor
public final class PermissionDragHelperController {
    private let appState: AppState
    private let model = PermissionHelperModel()
    private let panel: PermissionDragHelperPanel
    private let hostingView: NSHostingView<PermissionDragHelperView>
    private var pollTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?

    private let panelWidth: CGFloat = 468
    private let panelHeight: CGFloat = 88

    public init(appState: AppState) {
        self.appState = appState
        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        self.panel = PermissionDragHelperPanel(contentRect: rect)

        var controllerRef: PermissionDragHelperController?
        let view = PermissionDragHelperView(
            model: model,
            appURL: Self.resolvedAppBundleURL(),
            onRevealInFinder: {
                let url = Self.resolvedAppBundleURL()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            onOpenSettings: { [weak appState] kind in
                switch kind {
                case .accessibility:
                    appState?.openAccessibilitySettings()
                case .screenRecording:
                    appState?.openScreenRecordingSettings()
                }
            },
            onResetStaleEntry: { [weak appState] kind in
                guard let appState else { return }
                switch kind {
                case .accessibility:
                    _ = appState.engine.resetAccessibilityPermissionEntry()
                    appState.refreshPermissions(promptAccessibility: true)
                    appState.openAccessibilitySettings()
                case .screenRecording:
                    _ = appState.engine.resetScreenRecordingPermissionEntry()
                    appState.requestScreenRecording()
                    appState.openScreenRecordingSettings()
                }
            },
            onNextPermission: { nextKind in
                controllerRef?.switchToNext(nextKind)
            },
            onDismiss: {
                controllerRef?.hide()
            }
        )

        self.hostingView = NSHostingView(rootView: view)
        self.hostingView.wantsLayer = true
        self.hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.panel.contentView = hostingView
        self.panel.onEscape = { [weak self] in
            self?.hide()
        }

        controllerRef = self
    }

    public func show(for kind: PermissionKind) {
        autoHideTask?.cancel()
        model.kind = kind
        syncStatus()

        positionAtBottomCenter()
        panel.orderFrontRegardless()
        startPolling()
    }

    public func hide() {
        pollTask?.cancel()
        pollTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        panel.orderOut(nil)
    }

    private func switchToNext(_ nextKind: PermissionKind) {
        appState.triggerPermissionFlow(for: nextKind, prompt: true)
    }

    private func syncStatus() {
        appState.refreshPermissions(promptAccessibility: false)
        let perms = appState.status.permissions
        let nowGranted: Bool
        let otherIsMissing: Bool

        switch model.kind {
        case .accessibility:
            nowGranted = perms.accessibilityGranted
            otherIsMissing = !perms.screenRecordingGranted
        case .screenRecording:
            nowGranted = perms.screenRecordingGranted
            otherIsMissing = !perms.accessibilityGranted
        }

        let previouslyGranted = model.isGranted
        model.isGranted = nowGranted
        model.otherMissing = otherIsMissing

        if nowGranted && !previouslyGranted {
            pollTask?.cancel()
            pollTask = nil
            autoHideTask?.cancel()
            let delaySeconds: UInt64 = otherIsMissing ? 5 : 1
            autoHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                if self?.model.isGranted == true && self?.model.otherMissing == false {
                    self?.hide()
                }
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { break }
                guard self.panel.isVisible else { break }
                self.syncStatus()
            }
        }
    }

    private func positionAtBottomCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let x = visible.midX - (panelWidth / 2.0)
        let y = visible.minY + 28.0
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private static func resolvedAppBundleURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension.lowercased() == "app" {
            return bundleURL
        }
        return Bundle.main.executableURL ?? bundleURL
    }
}

// MARK: - Helper Widget UI

private struct PermissionDragHelperView: View {
    @ObservedObject var model: PermissionHelperModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var isHoveringIcon = false
    @State private var nudgeUp = false

    let appURL: URL
    let onRevealInFinder: () -> Void
    let onOpenSettings: (PermissionKind) -> Void
    let onResetStaleEntry: (PermissionKind) -> Void
    let onNextPermission: (PermissionKind) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if model.isGranted {
                grantedIconWell
            } else {
                draggableIconWell
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.isGranted ? "\(model.kind.title) Granted" : model.kind.dragPromptTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(
                    model.isGranted
                        ? (model.otherMissing ? "You're one step away — grant \(model.kind.other.title) next." : "usemac is ready to inspect and control native apps.")
                        : model.kind.dragPromptSubtitle
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 4)

            if model.isGranted && model.otherMissing {
                Button("Next") {
                    onNextPermission(model.kind.other)
                }
                .buttonStyle(PrimaryInkButtonStyle())
            } else if !model.isGranted {
                Menu {
                    Button("Already enabled? Reset stale entry") {
                        onResetStaleEntry(model.kind)
                    }
                    Divider()
                    Button("Open \(model.kind.title) Settings") {
                        onOpenSettings(model.kind)
                    }
                    Button("Reveal usemac in Finder") {
                        onRevealInFinder()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(MacUseTheme.subtleFill(colorScheme), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(MacUseTheme.subtleFill(colorScheme), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.68)
                            : Color.white.opacity(0.76)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    model.isGranted
                        ? MacUseTheme.statusGreen.opacity(0.42)
                        : MacUseTheme.strongHairline(colorScheme),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18),
            radius: 22,
            x: 0,
            y: 10
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onAppear {
            updateNudgeAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateNudgeAnimation()
        }
    }

    private func updateNudgeAnimation() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) {
                nudgeUp = false
            }
        } else {
            nudgeUp = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                nudgeUp = true
            }
        }
    }

    private var draggableIconWell: some View {
        ZStack(alignment: .topTrailing) {
            DraggableAppIconView(appURL: appURL, isDragging: $isDragging)
                .frame(width: 48, height: 48)
                .padding(3)
                .background(
                    MacUseTheme.recessed(colorScheme),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isDragging || isHoveringIcon ? Color.primary.opacity(0.35) : MacUseTheme.strongHairline(colorScheme),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
                .scaleEffect(isDragging ? 0.94 : (isHoveringIcon ? 1.03 : 1.0))
                .animation(.easeOut(duration: 0.14), value: isDragging)
                .animation(.easeOut(duration: 0.14), value: isHoveringIcon)
                .onHover { hovering in
                    isHoveringIcon = hovering
                }
                .help("Drag usemac into System Settings")

            Image(systemName: "arrow.up.left")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(MacUseTheme.inkForeground(colorScheme))
                .frame(width: 17, height: 17)
                .background(MacUseTheme.inkBackground(colorScheme), in: Circle())
                .offset(x: (!reduceMotion && nudgeUp) ? 2 : 5, y: (!reduceMotion && nudgeUp) ? -5 : -2)
                .allowsHitTesting(false)
        }
    }

    private var grantedIconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MacUseTheme.statusGreen.opacity(0.14))
                .frame(width: 52, height: 52)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(MacUseTheme.statusGreen)
        }
    }
}
