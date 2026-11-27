import AppKit
import Combine
import UseMacProtocol
import SwiftUI

public final class ActivityHUDPanel: NSPanel {
    public var isProgrammaticSnap: Bool = false
    public var onUserDragEnded: ((CGPoint) -> Void)?
    public var onCardBodyDoubleClicked: (() -> Void)?

    private var didDragDuringMouseDown: Bool = false
    private var mouseDownScreenLoc: CGPoint = .zero
    private var mouseDownClickCount: Int = 0
    private var pendingClickCheck: Bool = false
    private var lastCleanClickUptime: TimeInterval = 0
    private var lastCleanClickLoc: CGPoint = .zero
    private var moveSamples: [(origin: CGPoint, time: TimeInterval)] = []

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        // ActivityHUDView draws its own soft shadow into a transparent margin (hudShadowInset).
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            isProgrammaticSnap = false
            didDragDuringMouseDown = false
            mouseDownScreenLoc = NSEvent.mouseLocation
            mouseDownClickCount = event.clickCount
            pendingClickCheck = true
            moveSamples.removeAll(keepingCapacity: true)
            moveSamples.append((origin: frame.origin, time: ProcessInfo.processInfo.systemUptime))

            super.sendEvent(event)

            if didDragDuringMouseDown {
                pendingClickCheck = false
                lastCleanClickUptime = 0
                let velocity = computeReleaseVelocity()
                onUserDragEnded?(velocity)
            } else if (NSEvent.pressedMouseButtons & 1) == 0, pendingClickCheck {
                pendingClickCheck = false
                handlePotentialCleanClick(at: NSEvent.mouseLocation)
            }
            return
        }

        if event.type == .leftMouseUp {
            super.sendEvent(event)
            if pendingClickCheck {
                pendingClickCheck = false
                if !didDragDuringMouseDown {
                    handlePotentialCleanClick(at: NSEvent.mouseLocation)
                }
            }
            return
        }

        super.sendEvent(event)
    }

    private func handlePotentialCleanClick(at loc: CGPoint) {
        guard hypot(loc.x - mouseDownScreenLoc.x, loc.y - mouseDownScreenLoc.y) < 4.5 else {
            lastCleanClickUptime = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let withinInterval = (now - lastCleanClickUptime) <= max(0.35, NSEvent.doubleClickInterval)
        let withinRadius = hypot(loc.x - lastCleanClickLoc.x, loc.y - lastCleanClickLoc.y) < 10.0
        if mouseDownClickCount >= 2 || (withinInterval && withinRadius) {
            lastCleanClickUptime = 0
            onCardBodyDoubleClicked?()
        } else {
            lastCleanClickUptime = now
            lastCleanClickLoc = loc
        }
    }

    @objc private func handleWindowDidMove(_ notification: Notification) {
        guard !isProgrammaticSnap else { return }
        didDragDuringMouseDown = true

        let now = ProcessInfo.processInfo.systemUptime
        moveSamples.append((origin: frame.origin, time: now))
        moveSamples = Array(
            moveSamples
                .filter { now - $0.time <= 0.18 }
                .suffix(6)
        )
    }

    private func computeReleaseVelocity() -> CGPoint {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = moveSamples.filter { now - $0.time <= 0.18 }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else {
            return .zero
        }
        let dt = last.time - first.time
        guard dt > 0.005 else {
            return .zero
        }
        let rawVX = (last.origin.x - first.origin.x) / dt
        let rawVY = (last.origin.y - first.origin.y) / dt
        let maxSpeed: CGFloat = 3600
        return CGPoint(
            x: min(max(rawVX, -maxSpeed), maxSpeed),
            y: min(max(rawVY, -maxSpeed), maxSpeed)
        )
    }
}

@MainActor
public final class ActivityHUDController {
    private let appState: AppState
    private let panel: ActivityHUDPanel
    private let hostingView: NSHostingView<ActivityHUDView>
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var transitionGeneration: UInt64 = 0

    private let edgeMargin: CGFloat = 14
    private let peekStep: CGFloat = hudDeckPeek
    private let collapsedSize: NSSize = hudCollapsedPillSize
    /// The preview's fixed sizes (16:10). The picture fills them and is cropped; the HUD never follows the page's
    /// or window's shape, and nothing ever resizes the page to fit the HUD.
    private let regularPiPSize = NSSize(width: 280, height: 175)
    private let largePiPSize = NSSize(width: 400, height: 250)

    public var isVisible: Bool {
        panel.isVisible
    }

    /// Where the HUD is on screen, without the transparent shadow margin (the Ask-mode prompt docks next to it).
    public var panelFrame: NSRect {
        panel.frame.insetBy(dx: hudShadowInset, dy: hudShadowInset)
    }

    public init(appState: AppState) {
        self.appState = appState

        let initialBehind = appState.isHUDCollapsed ? 0 : Self.cardsBehind(appState.hudDeck.count)
        let initialSize = Self.sizeFor(
            collapsed: appState.isHUDCollapsed,
            isLarge: appState.isHUDLarge,
            stackBehindCount: initialBehind,
            peekStep: peekStep,
            collapsedSize: collapsedSize,
            regularPiPSize: regularPiPSize,
            largePiPSize: largePiPSize
        )
        let initialScreen = NSScreen.main ?? NSScreen.screens.first
        let initialRect: NSRect
        if let initialScreen {
            initialRect = Self.frame(
                for: appState.hudCorner,
                size: initialSize,
                on: initialScreen,
                margin: edgeMargin
            )
        } else {
            initialRect = NSRect(origin: .zero, size: initialSize)
        }

        self.panel = ActivityHUDPanel(contentRect: initialRect)
        let rootView = ActivityHUDView(appState: appState)
        self.hostingView = NSHostingView(rootView: rootView)
        self.hostingView.wantsLayer = true
        self.hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.panel.contentView = hostingView

        self.panel.onUserDragEnded = { [weak self] velocity in
            self?.handleUserDragEnded(velocity: velocity)
        }
        self.panel.onCardBodyDoubleClicked = { [weak appState] in
            guard let appState else { return }
            if ProcessInfo.processInfo.systemUptime - appState.lastControlTapUptime > 0.25 {
                appState.activateFrontHUDTarget(dismissAfter: true)
            }
        }

        appState.onShowHUD = { [weak self] in
            self?.show()
        }
        appState.onHideHUD = { [weak self] in
            self?.hide()
        }
        appState.onSnapHUDCorner = { [weak self] corner in
            self?.snap(to: corner, animated: true)
        }

        // Each card behind the front one (two at most) grows the panel by its visible edge, and a deck with a card
        // adds the front card's task tag. The picture never changes the panel's size.
        let deckBehindPublisher = appState.$hudDeck
            .map { Self.cardsBehind($0.count) }
            .removeDuplicates()

        Publishers.CombineLatest4(
            appState.$isHUDCollapsed.removeDuplicates(),
            appState.$isHUDLarge.removeDuplicates(),
            appState.$hudDeck.map(\.isEmpty).removeDuplicates(),
            deckBehindPublisher
        )
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.snap(to: self.appState.hudCorner, animated: self.panel.isVisible)
        }
        .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snap(to: self.appState.hudCorner, animated: false)
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public func show() {
        transitionGeneration &+= 1
        let wasVisible = panel.isVisible
        if !wasVisible {
            if let screen = currentScreen() {
                let targetFrame = Self.frame(
                    for: appState.hudCorner,
                    size: currentTargetSize(),
                    on: screen,
                    margin: edgeMargin
                )
                setPanelFrame(targetFrame, animated: false)
            }
            panel.alphaValue = 0.0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasVisible ? 0.12 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
        if !appState.isHUDVisible {
            appState.isHUDVisible = true
        }
    }

    public func hide() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        if appState.isHUDVisible {
            appState.isHUDVisible = false
        }
        guard panel.isVisible else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.transitionGeneration == generation, !self.appState.isHUDVisible else {
                    return
                }
                self.panel.orderOut(nil)
            }
        })
    }

    public func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    public func snap(to corner: HUDCorner, animated: Bool = true) {
        guard let screen = currentScreen() else { return }
        let targetFrame = Self.frame(
            for: corner,
            size: currentTargetSize(),
            on: screen,
            margin: edgeMargin
        )
        setPanelFrame(targetFrame, animated: animated)
    }

    // MARK: - Drag & Geometry

    private func handleUserDragEnded(velocity: CGPoint) {
        let projectedCenter = CGPoint(
            x: panel.frame.midX + velocity.x * 0.14,
            y: panel.frame.midY + velocity.y * 0.14
        )
        let currentCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(projectedCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(currentCenter) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let size = currentTargetSize()
        var bestCorner = appState.hudCorner
        var bestDistSq = CGFloat.greatestFiniteMagnitude
        var bestFrame = Self.frame(for: bestCorner, size: size, on: screen, margin: edgeMargin)

        for corner in HUDCorner.allCases {
            let candidate = Self.frame(for: corner, size: size, on: screen, margin: edgeMargin)
            let dx = projectedCenter.x - candidate.midX
            let dy = projectedCenter.y - candidate.midY
            let distSq = dx * dx + dy * dy
            if distSq < bestDistSq {
                bestDistSq = distSq
                bestCorner = corner
                bestFrame = candidate
            }
        }

        appState.setHUDCorner(bestCorner, snapWindow: false)
        setPanelFrame(bestFrame, animated: true)
    }

    private func setPanelFrame(_ targetFrame: NSRect, animated: Bool) {
        let current = panel.frame
        let unchanged = abs(current.origin.x - targetFrame.origin.x) < 0.5
            && abs(current.origin.y - targetFrame.origin.y) < 0.5
            && abs(current.width - targetFrame.width) < 0.5
            && abs(current.height - targetFrame.height) < 0.5
        guard !unchanged else { return }

        panel.isProgrammaticSnap = true
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.panel.isProgrammaticSnap = false
                }
            })
        } else {
            panel.setFrame(targetFrame, display: true)
            panel.isProgrammaticSnap = false
        }
    }

    private func currentTargetSize() -> NSSize {
        let behind = appState.isHUDCollapsed ? 0 : Self.cardsBehind(appState.hudDeck.count)
        return Self.sizeFor(
            collapsed: appState.isHUDCollapsed,
            isLarge: appState.isHUDLarge,
            stackBehindCount: behind,
            peekStep: peekStep,
            collapsedSize: collapsedSize,
            regularPiPSize: regularPiPSize,
            largePiPSize: largePiPSize
        )
    }

    /// Cards drawn behind the front one for a deck of `count` cards.
    private static func cardsBehind(_ count: Int) -> Int {
        min(max(count - 1, 0), hudDeckMaxBehind)
    }

    private func currentScreen() -> NSScreen? {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        if let matched = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return matched
        }
        return panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The size of what the HUD shows (the pill, or the deck), without the shadow margin.
    private static func sizeFor(
        collapsed: Bool,
        isLarge: Bool,
        stackBehindCount: Int,
        peekStep: CGFloat,
        collapsedSize: NSSize,
        regularPiPSize: NSSize,
        largePiPSize: NSSize
    ) -> NSSize {
        if collapsed {
            return collapsedSize
        }
        let baseSize = isLarge ? largePiPSize : regularPiPSize
        // The cards behind show an edge each; the front picture keeps its original size.
        let extraHeight = CGFloat(max(stackBehindCount, 0)) * peekStep
        return NSSize(width: baseSize.width, height: baseSize.height + extraHeight)
    }

    /// The panel's frame for a HUD of `size` in `corner`: the HUD sits `margin` from the screen's edges, and the panel
    /// reaches `hudShadowInset` past it on every side for the shadow.
    private static func frame(
        for corner: HUDCorner,
        size: NSSize,
        on screen: NSScreen,
        margin: CGFloat
    ) -> NSRect {
        let visible = screen.visibleFrame
        let x: CGFloat
        let y: CGFloat

        switch corner {
        case .topLeading:
            x = visible.minX + margin
            y = visible.maxY - margin - size.height
        case .topTrailing:
            x = visible.maxX - margin - size.width
            y = visible.maxY - margin - size.height
        case .bottomLeading:
            x = visible.minX + margin
            y = visible.minY + margin
        case .bottomTrailing:
            x = visible.maxX - margin - size.width
            y = visible.minY + margin
        }

        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
            .insetBy(dx: -hudShadowInset, dy: -hudShadowInset)
    }
}
