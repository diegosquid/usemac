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
    static let activeSky = Color(red: 0.231, green: 0.549, blue: 0.961)      // #3B8CF5
    static let cursorInkTop = Color(red: 0.155, green: 0.159, blue: 0.175)   // #27282D
    static let cursorInkBottom = Color(red: 0.075, green: 0.078, blue: 0.090)// #131417
}

/// One color per task in the preview (PreviewTaskColors gives the slot). Green, amber and red are left out: they mean
/// done, paused and stopped.
enum HUDTaskPalette {
    static let colors: [Color] = [
        Color(red: 0.545, green: 0.361, blue: 0.965), // #8B5CF6 violet
        Color(red: 0.078, green: 0.722, blue: 0.651), // #14B8A6 teal
        Color(red: 0.925, green: 0.282, blue: 0.600), // #EC4899 pink
        Color(red: 0.055, green: 0.647, blue: 0.914), // #0EA5E9 sky
        Color(red: 1.000, green: 0.478, blue: 0.349), // #FF7A59 coral
        Color(red: 0.310, green: 0.275, blue: 0.898)  // #4F46E5 indigo
    ]

    /// The slot's color, or the preview's blue for a card with no slot.
    static func color(slot: Int?) -> Color {
        guard let slot else { return MinimalHUDPalette.activeSky }
        return colors[((slot % colors.count) + colors.count) % colors.count]
    }

    /// How strongly a card's tag shows its task color over white: a pastel that stays at the edge of the eye.
    static let tagOpacity: Double = 0.22
    /// A tag behind the front card brightens to this for a moment when its agent does something.
    static let tagFlashOpacity: Double = 0.40
}

/// Transparent margin around the HUD that its own soft shadow draws into. The panel has no system shadow, and
/// ActivityHUDController makes the panel this much larger on every side.
let hudShadowInset: CGFloat = 18

private extension View {
    /// The HUD's shadow: a 1.5 pt contact shadow, plus a soft ambient one under the front card and the pill.
    func hudSoftShadow<S: Shape>(_ shape: S, ambient: Bool) -> some View {
        background(
            shape
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.07), radius: 0.75, x: 0, y: 0.5)
                .shadow(color: Color.black.opacity(ambient ? 0.11 : 0), radius: 8, x: 0, y: 5)
        )
    }
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
        .padding(hudShadowInset)
    }
}

// MARK: - Zero-Copy CALayer Video Surface

private final class LiveVideoContainerView: NSView {
    let videoLayer = CALayer()

    /// The size of what the frames show (the page or the window). The picture fills the card from its top-left
    /// corner at this aspect, and what does not fit is cut off (LivePreviewGeometry.displayedRect).
    var sourceSize: CGSize = .zero {
        didSet {
            if sourceSize != oldValue { needsLayout = true }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let containerLayer = CALayer()
        containerLayer.backgroundColor = NSColor.white.cgColor
        containerLayer.masksToBounds = true
        self.layer = containerLayer

        videoLayer.contentsGravity = .resizeAspectFill
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
        let shown = LivePreviewGeometry.displayedRect(sourceSize: sourceSize, in: bounds.size)
        if shown.isEmpty {
            videoLayer.frame = bounds
        } else {
            // This view is not flipped, so its layer's origin is the bottom-left corner: keep the picture's top
            // edge on the card's top edge and let the bottom run past it.
            videoLayer.frame = CGRect(
                x: shown.minX,
                y: bounds.height - shown.maxY,
                width: shown.width,
                height: shown.height
            )
        }
        CATransaction.commit()
    }
}

private struct LiveVideoSurfaceView: NSViewRepresentable {
    @ObservedObject var videoSink: LiveVideoSink

    func makeNSView(context: Context) -> LiveVideoContainerView {
        let view = LiveVideoContainerView()
        videoSink.attach(layer: view.videoLayer)
        view.sourceSize = Self.sourceSize(of: videoSink)
        return view
    }

    func updateNSView(_ nsView: LiveVideoContainerView, context: Context) {
        videoSink.attach(layer: nsView.videoLayer)
        nsView.sourceSize = Self.sourceSize(of: videoSink)
    }

    private static func sourceSize(of sink: LiveVideoSink) -> CGSize {
        guard let bounds = sink.sourceBounds else { return .zero }
        return CGSize(width: bounds.width, height: bounds.height)
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

// MARK: - Collapsed Micro-Pill (164 x 34)

/// Size of the collapsed pill. ActivityHUDController sizes the panel with the same values. The pill only shows what is
/// happening: stopping and resuming are in the UseMac menu and on ⌘⇧⎋.
let hudCollapsedPillSize = CGSize(width: 164, height: 34)

private struct CollapsedMicroPill: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseActive = false

    var body: some View {
        let isStopped = appState.status.killSwitchTripped
        let pillSize = hudCollapsedPillSize

        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
                .scaleEffect(isPulsing && !reduceMotion ? (pulseActive ? 1.25 : 0.85) : 1.0)

            Text(headline)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MinimalHUDPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                WhisperIconButton(
                    systemName: expandSymbol,
                    showGlassBackdrop: false,
                    help: "Expand Live View"
                ) {
                    appState.markControlTap()
                    appState.toggleHUDCollapsed()
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
        .padding(.leading, 10)
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
        .hudSoftShadow(Capsule(style: .continuous), ambient: true)
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

// MARK: - Multi-Agent PiP Deck (a stack that shuffles itself)

/// Edge of each card behind the front one that shows above (or below) it. ActivityHUDController grows the panel by
/// this much per card behind.
let hudDeckPeek: CGFloat = 7
/// Most cards drawn behind the front one.
let hudDeckMaxBehind = 2
/// The soft task-color tag along the top of the front card. ActivityHUDController adds it to the panel's height so
/// the live picture keeps its size.
let hudTagHeight: CGFloat = 7

/// The front card is the live preview under a thin tag in its task's color; up to two more cards sit behind it, each
/// with a 7 pt edge showing. They are only there to show that more work is going on: no titles, no pictures, no click
/// targets. Their edge is a soft tag in their task's color that brightens for a moment when their agent does
/// something, and the deck shuffles them forward in turn (AppState+DeckShuffle). The stack grows up from a bottom
/// corner and down from a top corner.
private struct StackedPiPDeckView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink

    var body: some View {
        let deck = appState.hudDeck
        let depth = min(max(deck.count - 1, 0), hudDeckMaxBehind)
        let growsUp = appState.hudCorner == .bottomLeading || appState.hudCorner == .bottomTrailing
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        GeometryReader { geo in
            let cardHeight = max(120, geo.size.height - CGFloat(depth) * hudDeckPeek)
            let frontY = growsUp ? CGFloat(depth) * hudDeckPeek : 0

            ZStack(alignment: .topLeading) {
                if deck.isEmpty {
                    // Nothing in the deck yet (a pinned preview, the full display): the live card on its own.
                    FramelessLivePiPCard(appState: appState, videoSink: videoSink, accent: HUDTaskPalette.color(slot: nil), tag: nil)
                        .hudSoftShadow(cardShape, ambient: true)
                        .frame(width: geo.size.width, height: cardHeight)
                }
                ForEach(Array(deck.enumerated()), id: \.element.id) { index, card in
                    let step = CGFloat(min(index, hudDeckMaxBehind))
                    let dips = index == 0 && appState.isDeckFrontDipping
                    DeckCardView(
                        appState: appState,
                        videoSink: videoSink,
                        card: card,
                        position: index,
                        accent: HUDTaskPalette.color(slot: appState.taskColorSlot(for: card))
                    )
                    .frame(width: geo.size.width, height: cardHeight)
                    .scaleEffect(dips ? 0.97 : 1 - 0.06 * step, anchor: growsUp ? .top : .bottom)
                    .offset(y: frontY + (growsUp ? -1 : 1) * step * hudDeckPeek + (dips ? (growsUp ? 10 : -10) : 0))
                    .opacity(index > hudDeckMaxBehind ? 0 : 1)
                    .zIndex(Double(deck.count - index))
                    .allowsHitTesting(index == 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onHover { hovering in
                appState.isHUDHovered = hovering
            }
        }
    }
}

/// One card of the deck: the live preview in front, a soft tag in its task's color behind.
private struct DeckCardView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink
    let card: HUDSessionCard
    let position: Int
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false
    @State private var frontFade: Double = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let isFront = position == 0

        ZStack {
            if isFront {
                FramelessLivePiPCard(appState: appState, videoSink: videoSink, accent: accent, tag: accent)
                    .opacity(frontFade)
            } else {
                backFace(shape: shape, depth: min(position, hudDeckMaxBehind))
            }
        }
        .hudSoftShadow(shape, ambient: isFront)
        .onChange(of: card.backgroundStepCount) { _, _ in
            guard !isFront else { return }
            var start = Transaction()
            start.disablesAnimations = true
            withTransaction(start) { flash = true }
            withAnimation(.easeOut(duration: 0.6).delay(0.09)) { flash = false }
        }
        .onChange(of: isFront) { _, nowFront in
            // With Reduce Motion the cards change places without moving; the new front fades in instead.
            guard nowFront, reduceMotion else { return }
            var start = Transaction()
            start.disablesAnimations = true
            withTransaction(start) { frontFade = 0 }
            withAnimation(.easeInOut(duration: 0.25)) { frontFade = 1 }
        }
    }

    /// A card behind the front one: only its edge shows, as a soft tag in its task's color. The card further back is a
    /// little paler.
    private func backFace(shape: RoundedRectangle, depth: Int) -> some View {
        let base = HUDTaskPalette.tagOpacity * (depth <= 1 ? 1 : 0.75)
        return ZStack {
            Color.white
            accent.opacity(flash ? HUDTaskPalette.tagFlashOpacity : base)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.75))
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

// MARK: - Frameless Edge-to-Edge Live PiP Card (280px / 400px)

private struct FramelessLivePiPCard: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink
    /// The card's task color: the click ripple uses it.
    let accent: Color
    /// The color of the soft tag along the card's top, or nil for no tag (a preview with no task).
    let tag: Color?

    @State private var isHovering = false
    @State private var isEnableHovered = false
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

        VStack(spacing: 0) {
            if let tag {
                taskTag(tag)
            }
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

    /// The card's task color as a thin pastel band along its top, so cards of different tasks tell apart at a glance
    /// without coloring the picture.
    private func taskTag(_ color: Color) -> some View {
        ZStack(alignment: .bottom) {
            Color.white
            color.opacity(HUDTaskPalette.tagOpacity)
            color.opacity(0.16)
                .frame(height: 0.5)
        }
        .frame(height: hudTagHeight)
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

            // Only what is happening: stopping and resuming are in the UseMac menu and on ⌘⇧⎋.
            HStack(spacing: 6) {
                if !isCompleted, let caption = appState.latestCaptionItem {
                    captionPill(caption)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer(minLength: 0)
            }
        }
        .padding(7)
    }

    private func captionPill(_ caption: LiveActivityItem) -> some View {
        // A failed caption is finished work: a failure mark and its reason, never a spinner (ActivityCaption.mark).
        let mark = ActivityCaption.mark(
            isInProgress: caption.isInProgress,
            success: caption.success,
            agentBusy: appState.isAgentBusy,
            stopped: appState.status.killSwitchTripped
        )
        let reason = mark == .failed ? caption.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return HStack(spacing: 5) {
            switch mark {
            case .progress:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MinimalHUDPalette.stopRed)
            case .done:
                Circle()
                    .fill(MinimalHUDPalette.liveGreen)
                    .frame(width: 4.5, height: 4.5)
            }

            // The agent working here, when its task named one (several agents can share the preview).
            if let agent = caption.agentName {
                Text(agent)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MinimalHUDPalette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("·")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MinimalHUDPalette.whisper)
            }

            Text(caption.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MinimalHUDPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(MinimalHUDPalette.ink.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(reason.map { "\(caption.title): \($0)" } ?? caption.title)
        .padding(.horizontal, 7.5)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.88), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 3, x: 0, y: 1)
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
                        .stroke(accent, lineWidth: 1.25)
                        .frame(width: 13, height: 13)
                        .scaleEffect(outerRippleScale)
                        .opacity(outerRippleOpacity)
                        .offset(x: -6.5, y: -6.5)
                }

                if innerRippleOpacity > 0.01 {
                    Circle()
                        .fill(accent.opacity(0.20))
                        .overlay(
                            Circle()
                                .stroke(accent.opacity(0.55), lineWidth: 1.0)
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
