import AppKit
import UseMacEngine
import UseMacProtocol
import QuartzCore
import SwiftUI

private enum MinimalHUDPalette {
    static let ink = Color(red: 0.153, green: 0.153, blue: 0.165)          // #27272A
    static let softIcon = Color(red: 0.443, green: 0.443, blue: 0.478)     // #71717A
    static let whisper = Color(red: 0.631, green: 0.631, blue: 0.667)      // #A1A1AA
    static let softPillBg = Color(red: 0.957, green: 0.957, blue: 0.965)   // #F4F4F6
    static let softPillHover = Color(red: 0.925, green: 0.925, blue: 0.937)// #ECECEF
    static let hairline = Color.black.opacity(0.055)
    static let stopRed = Color(red: 0.863, green: 0.149, blue: 0.149)      // #DC2626
    static let liveGreen = Color(red: 0.086, green: 0.639, blue: 0.290)    // #16A34A
    static let activeSkyLight = Color(red: 0.490, green: 0.788, blue: 0.988) // #7DC9FC
    static let activeSky = Color(red: 0.231, green: 0.549, blue: 0.961)      // #3B8CF5
    static let cursorInkTop = Color(red: 0.155, green: 0.159, blue: 0.175)   // #27282D
    static let cursorInkBottom = Color(red: 0.075, green: 0.078, blue: 0.090)// #131417
}

public struct ActivityHUDView: View {
    @ObservedObject public var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Group {
            if appState.isHUDCollapsed {
                CollapsedMicroPill(appState: appState, videoSink: appState.videoSink)
            } else {
                StackedPiPDeckView(appState: appState, videoSink: appState.videoSink)
            }
        }
    }
}

// MARK: - Zero-Copy CALayer Video Surface

private final class LiveVideoContainerView: NSView {
    let videoLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let containerLayer = CALayer()
        containerLayer.backgroundColor = NSColor.white.cgColor
        self.layer = containerLayer

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.magnificationFilter = .trilinear
        videoLayer.minificationFilter = .trilinear
        videoLayer.masksToBounds = true
        containerLayer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Allow native NSPanel dragging everywhere beneath interactive controls.
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct LiveVideoSurfaceView: NSViewRepresentable {
    let videoSink: LiveVideoSink

    func makeNSView(context: Context) -> LiveVideoContainerView {
        let view = LiveVideoContainerView()
        videoSink.attach(layer: view.videoLayer)
        return view
    }

    func updateNSView(_ nsView: LiveVideoContainerView, context: Context) {
        videoSink.attach(layer: nsView.videoLayer)
    }
}

// MARK: - Whisper-Subtle Ghost Control Button

private struct WhisperIconButton: View {
    let systemName: String
    let showGlassBackdrop: Bool
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(isHovered ? MinimalHUDPalette.ink : MinimalHUDPalette.ink.opacity(0.68))
                .frame(width: 19, height: 18)
                .background(
                    (isHovered
                        ? Color.black.opacity(0.07)
                        : (showGlassBackdrop ? Color.clear : Color.clear)),
                    in: Circle()
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Collapsed Micro-Pill (164 x 34, 200 x 34 while stopped)

/// Size of the collapsed pill. ActivityHUDController sizes the panel with the same values. While automation is
/// stopped the pill is wider, so "Stopped", Resume and the close button fit on one line.
let hudCollapsedPillSize = CGSize(width: 164, height: 34)
let hudStoppedPillSize = CGSize(width: 200, height: 34)

private struct CollapsedMicroPill: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseActive = false
    @State private var isResumeHovered = false

    private let resumeGreen = Color(red: 0.118, green: 0.659, blue: 0.431) // #1EA86E

    var body: some View {
        let isStopped = appState.status.killSwitchTripped
        let pillSize = isStopped ? hudStoppedPillSize : hudCollapsedPillSize

        HStack(spacing: isStopped ? 5 : 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
                .scaleEffect(isPulsing && !reduceMotion ? (pulseActive ? 1.25 : 0.85) : 1.0)

            Text(headline)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MinimalHUDPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: isStopped, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: isStopped ? 2 : 0) {
                if isStopped {
                    Button {
                        appState.markControlTap()
                        appState.toggleKillSwitch()
                    } label: {
                        Text("Resume")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isResumeHovered ? .white : resumeGreen)
                            .padding(.horizontal, 7)
                            .frame(minHeight: 24)
                            .background(
                                isResumeHovered ? resumeGreen : resumeGreen.opacity(0.12),
                                in: Capsule(style: .continuous)
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.14)) {
                            isResumeHovered = hovering
                        }
                    }
                    .help("Resume Automation (⌘⇧⎋)")
                    .accessibilityLabel("Resume")
                } else {
                    WhisperIconButton(
                        systemName: expandSymbol,
                        showGlassBackdrop: false,
                        help: "Expand Live View"
                    ) {
                        appState.markControlTap()
                        appState.toggleHUDCollapsed()
                    }
                }

                WhisperIconButton(
                    systemName: "xmark",
                    showGlassBackdrop: false,
                    help: "Hide HUD (⌥Space)"
                ) {
                    if isStopped {
                        appState.dismissAllHUDCards()
                    } else {
                        appState.dismissFrontHUDCard()
                    }
                }
            }
        }
        .padding(.leading, isStopped ? 9 : 10)
        .padding(.trailing, 5)
        .frame(width: pillSize.width, height: pillSize.height)
        .background(Color.white.opacity(0.97), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    appState.isAgentBusy && !appState.status.killSwitchTripped
                        ? MinimalHUDPalette.liveGreen.opacity(0.4)
                        : MinimalHUDPalette.hairline,
                    lineWidth: 0.5
                )
        )
        .clipShape(Capsule(style: .continuous))
        .environment(\.colorScheme, .light)
        .onAppear { updatePulse() }
        .onChange(of: appState.isAgentBusy) { _, _ in updatePulse() }
        .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    private var headline: String {
        if appState.status.killSwitchTripped { return "Stopped" }
        if let caption = appState.latestCaptionItem { return caption.title }
        return videoSink.sourceName
    }

    private var expandSymbol: String {
        switch appState.hudCorner {
        case .bottomLeading, .bottomTrailing: return "chevron.up"
        case .topLeading, .topTrailing: return "chevron.down"
        }
    }

    private var isPulsing: Bool {
        appState.isAgentBusy && !appState.status.killSwitchTripped
    }

    private var statusColor: Color {
        if appState.status.killSwitchTripped { return MinimalHUDPalette.stopRed }
        if appState.status.policy == .paused { return UseMacTheme.statusAmber }
        if appState.isAgentBusy || videoSink.hasReceivedFrame { return MinimalHUDPalette.liveGreen }
        return MinimalHUDPalette.whisper.opacity(0.7)
    }

    private func updatePulse() {
        if isPulsing && !reduceMotion {
            pulseActive = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulseActive = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                pulseActive = false
            }
        }
    }
}

// MARK: - Non-Dragging First-Mouse Click Surface for Peeking Deck Lips

private final class NonDraggingClickNSView: NSView {
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        // Consume mouseDown immediately so NSPanel.isMovableByWindowBackground cannot hijack it
        onClick?()
    }
}

private struct DeckLipClickOverlay: NSViewRepresentable {
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> NonDraggingClickNSView {
        let view = NonDraggingClickNSView()
        view.onClick = onClick
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: NonDraggingClickNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onHoverChange = onHoverChange
    }
}

// MARK: - Multi-Agent PiP Deck (front card + filmstrip)

/// Height the filmstrip adds under the front card when more than one tab/app is in the deck.
/// ActivityHUDController grows the panel by this much.
let hudFilmstripHeight: CGFloat = 46

/// The active tab/app is shown large; every other one stays visible as a live thumbnail in a strip below,
/// in a stable order, so the user can see what each agent tab is doing and bring any of them forward.
private struct StackedPiPDeckView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink

    // Front-card switch feedback: the new card rises from the strip, an accent ring flashes and a title
    // chip names the tab that just came forward.
    @State private var riseOffset: CGFloat = 0
    @State private var riseScale: CGFloat = 1
    @State private var ringOpacity: Double = 0
    @State private var switchTitle: String?
    @State private var switchGeneration = 0
    @State private var lastFrontId: String?
    /// Card ids in the order they first appeared, so thumbnails do not jump around on every switch.
    @State private var stripOrder: [String] = []

    var body: some View {
        let deck = appState.hudDeck
        let showStrip = deck.count > 1 && !appState.isHUDCollapsed
        let frontId = deck.first?.id

        GeometryReader { geo in
            let stripHeight = showStrip ? hudFilmstripHeight : 0
            let frontHeight = max(120, geo.size.height - stripHeight)
            let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

            VStack(spacing: 0) {
                FramelessLivePiPCard(appState: appState, videoSink: videoSink)
                    .frame(width: geo.size.width, height: frontHeight)
                    .overlay(
                        cardShape
                            .strokeBorder(MinimalHUDPalette.activeSky, lineWidth: 2)
                            .opacity(ringOpacity)
                            .allowsHitTesting(false)
                    )
                    .overlay(alignment: .topLeading) {
                        if let switchTitle {
                            DeckSwitchChip(title: switchTitle)
                                .padding(8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                .id(switchGeneration)
                                .allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(riseScale, anchor: .bottom)
                    .offset(y: riseOffset)
                    .zIndex(2)

                if showStrip {
                    DeckFilmstrip(
                        cards: orderedCards(deck),
                        activeId: frontId,
                        onSelect: { appState.promoteHUDCard(id: $0) }
                    )
                    .frame(width: geo.size.width, height: stripHeight)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showStrip)
            .onAppear {
                lastFrontId = frontId
                syncStripOrder(deck)
            }
            .onChange(of: deck.map(\.id)) { _ in
                syncStripOrder(appState.hudDeck)
            }
            .onChange(of: frontId) { newFront in
                let previous = lastFrontId
                lastFrontId = newFront
                guard let newFront, let previous, previous != newFront else { return }
                // A tab that was still opening getting its real id is the same card, not a switch; and a card
                // with no tab yet only has a placeholder title.
                let card = appState.hudDeck.first(where: { $0.id == newFront })
                let upgradedFromPending = newFront.hasPrefix(previous + ":")
                let isPlaceholder = card?.isBrowser == true && card?.browserTabId == nil
                guard !upgradedFromPending, !isPlaceholder else { return }
                playSwitch(title: card?.title)
            }
        }
    }

    private func orderedCards(_ deck: [HUDSessionCard]) -> [HUDSessionCard] {
        let byId = Dictionary(deck.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = stripOrder.compactMap { byId[$0] }
        let extra = deck.filter { !stripOrder.contains($0.id) }
        return known + extra
    }

    private func syncStripOrder(_ deck: [HUDSessionCard]) {
        let ids = Set(deck.map(\.id))
        var order: [String] = []
        for id in stripOrder {
            if ids.contains(id) {
                order.append(id)
            } else if let upgraded = deck.first(where: { $0.id.hasPrefix(id + ":") && !stripOrder.contains($0.id) }) {
                // A card that was still opening got its real tab id: it keeps its slot.
                order.append(upgraded.id)
            }
        }
        for card in deck where !order.contains(card.id) {
            order.append(card.id)
        }
        if order != stripOrder {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                stripOrder = order
            }
        }
    }

    private func playSwitch(title: String?) {
        switchGeneration += 1
        let generation = switchGeneration
        // Start a little below and smaller, as if lifted out of the strip, then spring into place.
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) {
            riseOffset = 18
            riseScale = 0.94
            ringOpacity = 1
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            riseOffset = 0
            riseScale = 1
        }
        withAnimation(.easeOut(duration: 0.18)) {
            switchTitle = (title?.isEmpty == false) ? title : nil
        }
        withAnimation(.easeOut(duration: 0.9).delay(0.25)) {
            ringOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard generation == switchGeneration else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                switchTitle = nil
            }
        }
    }
}

/// Shown instead of Chrome's window when it is showing one of the user's own tabs: the agent is reading
/// Chrome's interface, but the user's tabs are never put on the preview.
private struct PrivatePreviewPlaceholder: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "eye.slash")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(MinimalHUDPalette.softIcon)
            Text("Working in Chrome")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MinimalHUDPalette.ink)
            Text("Your own tabs are not shown in the preview.")
                .font(.system(size: 10.5))
                .foregroundStyle(MinimalHUDPalette.softIcon)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.975, green: 0.975, blue: 0.98))
    }
}

/// Small chip naming the tab/app that just came to the front.
private struct DeckSwitchChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.square.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(MinimalHUDPalette.activeSky)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MinimalHUDPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.94))
                .shadow(color: Color.black.opacity(0.14), radius: 4, x: 0, y: 1)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(MinimalHUDPalette.hairline, lineWidth: 0.5))
        .frame(maxWidth: 210, alignment: .leading)
    }
}

/// Strip of live thumbnails under the front card. The active one is outlined; busy ones pulse a dot.
/// Thumbnails shrink to fit up to 8 cards; past that the rest is summarized as "+N" (titles in the tooltip).
private struct DeckFilmstrip: View {
    let cards: [HUDSessionCard]
    let activeId: String?
    let onSelect: (String) -> Void

    private let horizontalPadding: CGFloat = 8
    private let maxThumbWidth: CGFloat = 48
    private let minThumbWidth: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let layout = Self.layout(
                count: cards.count,
                available: geo.size.width - horizontalPadding * 2,
                maxThumbWidth: maxThumbWidth,
                minThumbWidth: minThumbWidth
            )
            let overflow = cards.count > layout.capacity
            let visible = overflow ? Array(cards.prefix(layout.capacity - 1)) : cards
            // Never hide the active card behind "+N".
            let shown: [HUDSessionCard] = {
                guard overflow, let activeId, !visible.contains(where: { $0.id == activeId }),
                      let active = cards.first(where: { $0.id == activeId }) else { return visible }
                return Array(visible.dropLast()) + [active]
            }()
            let hidden = cards.filter { card in !shown.contains(where: { $0.id == card.id }) }

            HStack(spacing: layout.spacing) {
                ForEach(shown) { card in
                    DeckThumbnail(
                        card: card,
                        isActive: card.id == activeId,
                        width: layout.thumbWidth,
                        height: layout.thumbHeight,
                        compact: layout.thumbWidth < 36
                    ) {
                        onSelect(card.id)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if overflow {
                    Text("+\(hidden.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MinimalHUDPalette.softIcon)
                        .frame(width: layout.thumbWidth, height: layout.thumbHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(MinimalHUDPalette.softPillBg)
                        )
                        .help(hidden.map(\.title).joined(separator: "\n"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: geo.size.width, height: geo.size.height - 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .shadow(color: Color.black.opacity(0.10), radius: 5, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MinimalHUDPalette.hairline, lineWidth: 0.5)
            )
            .offset(y: 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: shown.map(\.id))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: layout.thumbWidth)
        }
    }

    struct Layout: Equatable {
        var thumbWidth: CGFloat
        var thumbHeight: CGFloat
        var spacing: CGFloat
        /// How many slots fit (including the "+N" slot when overflowing).
        var capacity: Int
    }

    /// Fits every card when they can be at least `minThumbWidth` wide; otherwise uses the minimum size and
    /// reserves the last slot for "+N".
    static func layout(count: Int, available: CGFloat, maxThumbWidth: CGFloat, minThumbWidth: CGFloat) -> Layout {
        let n = max(1, count)
        let spacing: CGFloat = n > 5 ? 4 : 6
        let fitWidth = floor((available - spacing * CGFloat(n - 1)) / CGFloat(n))
        if fitWidth >= minThumbWidth {
            let width = min(maxThumbWidth, fitWidth)
            return Layout(thumbWidth: width, thumbHeight: round(width / 1.6), spacing: spacing, capacity: n)
        }
        let capacity = max(2, Int((available + spacing) / (minThumbWidth + spacing)))
        return Layout(thumbWidth: minThumbWidth, thumbHeight: round(minThumbWidth / 1.6), spacing: spacing, capacity: capacity)
    }
}

private struct DeckThumbnail: View {
    let card: HUDSessionCard
    let isActive: Bool
    let width: CGFloat
    let height: CGFloat
    var compact = false
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color(red: 0.95, green: 0.95, blue: 0.96)
                if let cgImage = card.previewImage {
                    Image(decorative: cgImage, scale: 2.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height, alignment: .top)
                        .clipped()
                } else {
                    Image(systemName: card.isBrowser ? "globe" : "macwindow")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(MinimalHUDPalette.whisper)
                }
                // Inactive thumbnails sit back a little so the active one reads first.
                Color.white.opacity(isActive || isHovered ? 0 : 0.18)
            }
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    isActive ? MinimalHUDPalette.activeSky : Color.black.opacity(isHovered ? 0.22 : 0.10),
                    lineWidth: isActive ? 1.6 : 0.6
                )
            )

            if card.isBusy && !isActive {
                Circle()
                    .fill(MinimalHUDPalette.activeSky)
                    .frame(width: compact ? 4.5 : 6, height: compact ? 4.5 : 6)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 1 : 0.6)
                    .offset(x: 2, y: -2)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            } else if card.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: compact ? 7 : 9, weight: .bold))
                    .foregroundStyle(MinimalHUDPalette.liveGreen, Color.white)
                    .offset(x: 3, y: -3)
            }

            DeckLipClickOverlay(
                onClick: onSelect,
                onHoverChange: { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                }
            )
            .frame(width: width, height: height)
        }
        .scaleEffect(isHovered && !isActive ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isActive)
        .help(card.title)
    }
}

// MARK: - Frameless Edge-to-Edge Live PiP Card (280px / 400px)

private struct FramelessLivePiPCard: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink

    @State private var isHovering = false
    @State private var isEnableHovered = false
    @State private var isStopHovered = false
    @State private var completionReveal: Bool = false
    @State private var completionRingScale: CGFloat = 0.65
    @State private var completionRingOpacity: Double = 0.0
    @State private var cursorPressScale: CGFloat = 1.0
    @State private var outerRippleScale: CGFloat = 0.25
    @State private var outerRippleOpacity: Double = 0.0
    @State private var innerRippleScale: CGFloat = 0.20
    @State private var innerRippleOpacity: Double = 0.0

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let isStopped = appState.status.killSwitchTripped
        let isBusy = appState.isAgentBusy && !isStopped
        let isCompleted = appState.hasCompletedHUDAction && !isStopped && !isBusy

        ZStack {
            Color.white

            if appState.chromePreviewHidden && !appState.isBrowserStreamActive {
                PrivatePreviewPlaceholder()
                    .transition(.opacity)
            } else if videoSink.hasReceivedFrame {
                LiveVideoSurfaceView(videoSink: videoSink)
                    .transition(.opacity)

                if !isCompleted {
                    videoSpatialOverlay
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            } else {
                softOnboardingState
                    .transition(.opacity)
            }

            // Keep active preview frameless and calm; only show a soft red aura when Emergency Stop is tripped
            if isStopped {
                cardShape
                    .stroke(MinimalHUDPalette.stopRed.opacity(0.20), lineWidth: 4.0)
                    .blur(radius: 3.5)
                    .clipShape(cardShape)
                    .allowsHitTesting(false)
            }

            // OpenAI-style airy translucent white frosted completion overlay + soft light-green check
            if isCompleted {
                completionVeilOverlay
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            whisperFloatingChrome(isCompleted: isCompleted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(cardShape)
        .overlay(
            Group {
                if isStopped {
                    cardShape
                        .strokeBorder(MinimalHUDPalette.stopRed.opacity(0.75), lineWidth: 1.75)
                } else {
                    cardShape
                        .strokeBorder(
                            Color.black.opacity(isHovering ? 0.13 : 0.085),
                            lineWidth: 0.75
                        )
                }
            }
            .allowsHitTesting(false)
        )
        .environment(\.colorScheme, .light)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.18), value: videoSink.hasReceivedFrame)
        .animation(.easeInOut(duration: 0.16), value: appState.latestCaptionItem?.id)
        .animation(.easeOut(duration: 0.28), value: isCompleted)
        .onAppear {
            guard isCompleted else { return }
            completionReveal = false
            completionRingScale = 0.65
            completionRingOpacity = 0.85
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                completionReveal = true
            }
            withAnimation(.easeOut(duration: 0.65)) {
                completionRingScale = 1.65
                completionRingOpacity = 0.0
            }
        }
        .onChange(of: isCompleted) { _, completed in
            guard completed else {
                completionReveal = false
                completionRingScale = 0.65
                completionRingOpacity = 0.0
                return
            }
            completionReveal = false
            completionRingScale = 0.65
            completionRingOpacity = 0.85
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                completionReveal = true
            }
            withAnimation(.easeOut(duration: 0.65)) {
                completionRingScale = 1.65
                completionRingOpacity = 0.0
            }
        }
        .onChange(of: appState.virtualClickPulseId) { _, pulseId in
            guard pulseId != nil else { return }
            withAnimation(.spring(response: 0.14, dampingFraction: 0.65)) {
                cursorPressScale = 0.85
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                    cursorPressScale = 1.0
                }
            }

            outerRippleScale = 0.25
            outerRippleOpacity = 0.92
            innerRippleScale = 0.20
            innerRippleOpacity = 0.78
            withAnimation(.easeOut(duration: 0.50)) {
                outerRippleScale = 2.6
                outerRippleOpacity = 0.0
            }
            withAnimation(.easeOut(duration: 0.38).delay(0.04)) {
                innerRippleScale = 1.75
                innerRippleOpacity = 0.0
            }
        }
    }

    // MARK: - OpenAI-Style Frosted White Completion Veil

    private var completionVeilOverlay: some View {
        let mintSurface = Color(red: 0.902, green: 0.980, blue: 0.941) // #E6FAF0
        let mintBorder = Color(red: 0.235, green: 0.773, blue: 0.533)  // #3CC588
        let mintCheck = Color(red: 0.118, green: 0.659, blue: 0.431)   // #1EA86E
        let labelText: String = {
            if let title = appState.latestCaptionItem?.title.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               title.count <= 34 {
                return title
            }
            return "Done"
        }()

        return ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.62)

            Color.white.opacity(0.72)

            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(mintBorder.opacity(0.32), lineWidth: 1.5)
                        .frame(width: 46, height: 46)
                        .scaleEffect(completionRingScale)
                        .opacity(completionRingOpacity)

                    Circle()
                        .fill(mintSurface)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Circle()
                                .strokeBorder(mintBorder.opacity(0.28), lineWidth: 1.0)
                        )
                        .shadow(color: mintCheck.opacity(0.10), radius: 10, x: 0, y: 3)

                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(mintCheck)
                }
                .scaleEffect(completionReveal ? 1.0 : 0.62)
                .opacity(completionReveal ? 1.0 : 0.0)

                Text(labelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinimalHUDPalette.ink.opacity(0.74))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .offset(y: completionReveal ? 0 : 5)
                    .opacity(completionReveal ? 1.0 : 0.0)
            }
        }
    }

    // MARK: - Whisper-Quiet Floating Chrome (No Screen Pill, Nearly Invisible CTAs)

    private func whisperFloatingChrome(isCompleted: Bool) -> some View {
        let controlsOpacity: Double = {
            if isHovering { return 1.0 }
            if isCompleted { return 0.0 }
            if !videoSink.hasReceivedFrame { return 0.55 }
            if !appState.isAgentBusy { return 0.80 }
            return 0.0
        }()
        let controlsInteractive = isHovering || (!isCompleted && (!videoSink.hasReceivedFrame || !appState.isAgentBusy))

        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                Spacer(minLength: 0)

                HStack(spacing: 1) {
                    WhisperIconButton(
                        systemName: "minus",
                        showGlassBackdrop: false,
                        help: "Minimize to Pill"
                    ) {
                        appState.markControlTap()
                        appState.toggleHUDCollapsed()
                    }

                    WhisperIconButton(
                        systemName: "xmark",
                        showGlassBackdrop: false,
                        help: appState.hudDeck.count > 1 ? "Close Front Card" : "Close Preview (⌥Space)"
                    ) {
                        appState.dismissFrontHUDCard()
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(
                    Color.white.opacity(isHovering ? 0.96 : 0.86),
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.14), radius: 4, x: 0, y: 1.5)
                .opacity(controlsOpacity)
                .allowsHitTesting(controlsInteractive)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if !isCompleted, let caption = appState.latestCaptionItem {
                    captionPill(caption)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer(minLength: 4)

                if appState.isAgentBusy || appState.status.killSwitchTripped {
                    stopPill
                        .transition(.opacity)
                }
            }
        }
        .padding(7)
    }

    private func captionPill(_ caption: LiveActivityItem) -> some View {
        HStack(spacing: 5) {
            if (caption.isInProgress || appState.isAgentBusy) && !appState.status.killSwitchTripped {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else {
                Circle()
                    .fill(caption.success ? MinimalHUDPalette.liveGreen : MinimalHUDPalette.stopRed)
                    .frame(width: 4.5, height: 4.5)
            }

            Text(caption.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MinimalHUDPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7.5)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.88), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 3, x: 0, y: 1)
    }

    private var stopPill: some View {
        let tripped = appState.status.killSwitchTripped
        let resumeGreen = Color(red: 0.118, green: 0.659, blue: 0.431) // #1EA86E
        let fgColor: Color = {
            if tripped { return isStopHovered ? .white : resumeGreen }
            return isStopHovered ? .white : MinimalHUDPalette.ink.opacity(0.80)
        }()
        let bgColor: Color = {
            if tripped { return isStopHovered ? resumeGreen : Color.white.opacity(0.92) }
            return isStopHovered ? MinimalHUDPalette.cursorInkBottom : Color.white.opacity(0.90)
        }()
        let borderColor: Color = {
            if tripped { return resumeGreen.opacity(isStopHovered ? 0.0 : 0.24) }
            return Color.black.opacity(isStopHovered ? 0.0 : 0.07)
        }()

        return Button {
            appState.markControlTap()
            appState.toggleKillSwitch()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tripped ? "play.fill" : "stop.fill")
                    .font(.system(size: 7.5, weight: .semibold))
                Text(tripped ? "Resume" : "Stop")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(fgColor)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(bgColor, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.07), radius: 3, x: 0, y: 1)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isStopHovered = hovering
            }
        }
        .help(tripped ? "Resume Automation (⌘⇧⎋)" : "Stop Automation (⌘⇧⎋)")
        .accessibilityLabel(tripped ? "Resume" : "Stop")
    }

    // MARK: - Soft, Gentle Onboarding State

    @ViewBuilder
    private var softOnboardingState: some View {
        if appState.streamStatus == .permissionRequired || !appState.status.permissions.screenRecordingGranted {
            VStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(MinimalHUDPalette.whisper)

                Text("Screen Recording required")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(MinimalHUDPalette.whisper)

                Button {
                    appState.triggerPermissionFlow(for: .screenRecording, prompt: true)
                } label: {
                    Text("Enable Live View")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MinimalHUDPalette.ink.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            isEnableHovered ? MinimalHUDPalette.softPillHover : MinimalHUDPalette.softPillBg,
                            in: Capsule(style: .continuous)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isEnableHovered = $0 }
            }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(0.42)
                }
            }

    // MARK: - Proportional Spatial Overlays

    private var videoSpatialOverlay: some View {
        GeometryReader { geo in
            if let bounds = videoSink.sourceBounds, bounds.width > 0, bounds.height > 0 {
                let source = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)

                ZStack(alignment: .topLeading) {
                    if let rect = appState.highlightedRect, previewShowsOverlay(for: appState.highlightTarget) {
                        highlightBox(rect: rect, source: source, previewSize: geo.size)
                    }

                    if let point = appState.virtualAgentPoint {
                        let target = appState.virtualAgentTarget
                        if previewShowsOverlay(for: target) {
                            virtualPointer(
                                point: point,
                                source: source,
                                previewSize: geo.size,
                                // Events without a window identity keep the old 5% slack around the edges.
                                tolerance: target == nil ? 0.05 : 0
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    /// Only draw a window's highlight or cursor on the preview when the preview shows that window.
    private func previewShowsOverlay(for target: OverlayTargetWindow?) -> Bool {
        LivePreviewGeometry.previewShowsOverlay(
            overlayPid: target?.pid,
            overlayWindowId: target?.windowId,
            sourceIsBrowserFrame: videoSink.isBrowserStream,
            sourceIsWindow: videoSink.isWindowCapture,
            sourcePid: videoSink.sourcePid,
            sourceWindowId: videoSink.sourceWindowId
        )
    }

    @ViewBuilder
    private func highlightBox(
        rect: ScreenRect,
        source: CGRect,
        previewSize: CGSize
    ) -> some View {
        if let mapped = LivePreviewGeometry.previewRect(
            CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
            sourceBounds: source,
            previewSize: previewSize
        ) {
            let boxW = max(4, mapped.width)
            let boxH = max(4, mapped.height)

            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.0)
                )
                .frame(width: boxW, height: boxH)
                .position(x: mapped.minX + boxW / 2, y: mapped.minY + boxH / 2)
                .animation(.easeOut(duration: 0.14), value: rect)
        }
    }

    @ViewBuilder
    private func virtualPointer(
        point: CGPoint,
        source: CGRect,
        previewSize: CGSize,
        tolerance: CGFloat
    ) -> some View {
        if let mapped = LivePreviewGeometry.previewPoint(
            point,
            sourceBounds: source,
            previewSize: previewSize,
            tolerance: tolerance
        ) {
            let relX = (point.x - source.minX) / source.width
            let relY = (point.y - source.minY) / source.height
            let px = mapped.x
            let py = mapped.y

            ZStack(alignment: .topLeading) {
                if outerRippleOpacity > 0.01 {
                    Circle()
                        .stroke(MinimalHUDPalette.activeSky, lineWidth: 1.25)
                        .frame(width: 13, height: 13)
                        .scaleEffect(outerRippleScale)
                        .opacity(outerRippleOpacity)
                        .offset(x: -6.5, y: -6.5)
                }

                if innerRippleOpacity > 0.01 {
                    Circle()
                        .fill(MinimalHUDPalette.activeSkyLight.opacity(0.20))
                        .overlay(
                            Circle()
                                .stroke(MinimalHUDPalette.activeSkyLight.opacity(0.85), lineWidth: 1.0)
                        )
                        .frame(width: 10, height: 10)
                        .scaleEffect(innerRippleScale)
                        .opacity(innerRippleOpacity)
                        .offset(x: -5, y: -5)
                }

                ZStack {
                    AgentCursorShape()
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: Color.black.opacity(0.24), radius: 2.5, x: 0, y: 1.0)

                    AgentCursorShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    MinimalHUDPalette.cursorInkTop,
                                    MinimalHUDPalette.cursorInkBottom
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 11.5, height: 14)
                .scaleEffect(cursorPressScale, anchor: .topLeading)

                if let label = appState.virtualAgentLabel, !label.isEmpty {
                    let displayLabel = label.count > 22 ? String(label.prefix(21)) + "…" : label
                    let flipLeft = relX > 0.62
                    let flipUp = relY > 0.80
                    ZStack(alignment: flipLeft ? .topTrailing : .topLeading) {
                        Text(displayLabel)
                            .font(.system(size: 8.0, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(
                                LinearGradient(
                                    colors: [
                                        MinimalHUDPalette.cursorInkTop,
                                        MinimalHUDPalette.cursorInkBottom
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: Capsule(style: .continuous)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.18), radius: 2.5, x: 0, y: 1)
                    }
                    .frame(width: 0, height: 0, alignment: flipLeft ? .topTrailing : .topLeading)
                    .offset(x: flipLeft ? -4 : 9, y: flipUp ? -14 : 10)
                }
            }
            .frame(width: 0, height: 0, alignment: .topLeading)
            .position(x: px, y: py)
            .animation(.spring(response: 0.20, dampingFraction: 0.82), value: point)
        }
    }
}

private struct AgentCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 17.0
        let sy = rect.height / 21.0
        var path = Path()
        path.move(to: CGPoint(x: 0.0 * sx, y: 0.0 * sy))
        path.addLine(to: CGPoint(x: 0.0 * sx, y: 17.2 * sy))
        path.addLine(to: CGPoint(x: 4.6 * sx, y: 13.6 * sy))
        path.addLine(to: CGPoint(x: 7.8 * sx, y: 20.4 * sy))
        path.addLine(to: CGPoint(x: 10.4 * sx, y: 19.3 * sy))
        path.addLine(to: CGPoint(x: 7.2 * sx, y: 12.5 * sy))
        path.addLine(to: CGPoint(x: 13.8 * sx, y: 12.2 * sy))
        path.closeSubpath()
        return path
    }
}
