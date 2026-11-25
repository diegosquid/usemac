import AppKit
import MacUseProtocol
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

// MARK: - Collapsed Micro-Pill (164 x 34)

private struct CollapsedMicroPill: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseActive = false
    @State private var isResumeHovered = false

    private let resumeGreen = Color(red: 0.118, green: 0.659, blue: 0.431) // #1EA86E

    var body: some View {
        let isStopped = appState.status.killSwitchTripped

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
        .frame(width: 164, height: 34)
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
        if appState.status.policy == .paused { return MacUseTheme.statusAmber }
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

// MARK: - ChatGPT-Style Stacked Multi-Agent PiP Deck

private struct StackedPiPDeckView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var videoSink: LiveVideoSink

    private let peekStep: CGFloat = 24

    var body: some View {
        let behindCards = Array(appState.hudDeck.dropFirst().prefix(2))
        let peekingUpward = (appState.hudCorner == .bottomLeading || appState.hudCorner == .bottomTrailing)

        GeometryReader { geo in
            let frontHeight = max(120, geo.size.height - CGFloat(behindCards.count) * peekStep)
            let cardWidth = geo.size.width

            ZStack(alignment: peekingUpward ? .bottom : .top) {
                ForEach(Array(behindCards.enumerated().reversed()), id: \.element.id) { idx, card in
                    let depth = idx + 1
                    PeekingDeckCardView(
                        card: card,
                        depth: depth,
                        peekingUpward: peekingUpward,
                        width: cardWidth,
                        height: frontHeight,
                        peekStep: peekStep
                    ) {
                        appState.promoteHUDCard(id: card.id)
                    }
                    .padding(peekingUpward ? .bottom : .top, CGFloat(depth) * peekStep)
                    .zIndex(Double(10 - depth))
                }

                FramelessLivePiPCard(appState: appState, videoSink: videoSink)
                    .frame(width: cardWidth, height: frontHeight)
                    .zIndex(20)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: peekingUpward ? .bottom : .top)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: appState.hudDeck.map(\.id))
        }
    }
}

private struct PeekingDeckCardView: View {
    let card: HUDSessionCard
    let depth: Int
    let peekingUpward: Bool
    let width: CGFloat
    let height: CGFloat
    let peekStep: CGFloat
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let insetScale = 1.0 - CGFloat(depth) * 0.045
        let effectiveWidth = round(width * insetScale)
        let veilOpacity = isHovered ? 0.08 : (depth == 1 ? 0.20 : 0.36)
        let dotColor: Color = card.isBusy
            ? MinimalHUDPalette.activeSky
            : Color(red: 0.24, green: 0.76, blue: 0.52)

        ZStack(alignment: peekingUpward ? .topLeading : .bottomLeading) {
            Color.white

            if let cgImage = card.previewImage {
                Image(decorative: cgImage, scale: 2.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: effectiveWidth, height: height)
                    .clipped()
            }

            Color.white.opacity(veilOpacity)

            // Visible clickable tab lip with title & hover affordance
            ZStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)

                    Text(card.title)
                        .font(.system(size: 10, weight: isHovered ? .semibold : .medium))
                        .foregroundStyle(isHovered ? MinimalHUDPalette.ink : Color(red: 0.28, green: 0.28, blue: 0.32))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if isHovered {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(MinimalHUDPalette.ink.opacity(0.65))
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: peekStep)
                .background(Color.white.opacity(isHovered ? 0.96 : 0.90))

                DeckLipClickOverlay(
                    onClick: onSelect,
                    onHoverChange: { hovering in
                        withAnimation(.easeOut(duration: 0.14)) {
                            isHovered = hovering
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: peekStep)
            }
            .frame(height: peekStep)
        }
        .frame(width: effectiveWidth, height: height)
        .clipShape(cardShape)
        .overlay(
            cardShape
                .strokeBorder(
                    Color.black.opacity(isHovered ? 0.18 : 0.095),
                    lineWidth: isHovered ? 0.85 : 0.65
                )
        )
        .shadow(
            color: Color.black.opacity(0.12),
            radius: 5,
            x: 0,
            y: peekingUpward ? -1 : 1
        )
        .offset(y: isHovered ? (peekingUpward ? -2 : 2) : 0)
        .help("Click to view \(card.title)")
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

            if videoSink.hasReceivedFrame {
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
                let bw = CGFloat(bounds.width)
                let bh = CGFloat(bounds.height)
                let scale = min(geo.size.width / bw, geo.size.height / bh)
                let fittedW = bw * scale
                let fittedH = bh * scale
                let originX = (geo.size.width - fittedW) / 2
                let originY = (geo.size.height - fittedH) / 2

                ZStack(alignment: .topLeading) {
                    if let rect = appState.highlightedRect {
                        highlightBox(
                            rect: rect,
                            bounds: bounds,
                            originX: originX,
                            originY: originY,
                            fittedW: fittedW,
                            fittedH: fittedH
                        )
                    }

                    if let point = appState.virtualAgentPoint {
                        virtualPointer(
                            point: point,
                            bounds: bounds,
                            originX: originX,
                            originY: originY,
                            fittedW: fittedW,
                            fittedH: fittedH
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func highlightBox(
        rect: ScreenRect,
        bounds: ScreenRect,
        originX: CGFloat,
        originY: CGFloat,
        fittedW: CGFloat,
        fittedH: CGFloat
    ) -> some View {
        let relX = (rect.x - bounds.x) / bounds.width
        let relY = (rect.y - bounds.y) / bounds.height
        let relW = rect.width / bounds.width
        let relH = rect.height / bounds.height

        if relX < 1, relY < 1, relX + relW > 0, relY + relH > 0 {
            let boxX = originX + CGFloat(relX) * fittedW
            let boxY = originY + CGFloat(relY) * fittedH
            let boxW = max(4, CGFloat(relW) * fittedW)
            let boxH = max(4, CGFloat(relH) * fittedH)

            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.0)
                )
                .frame(width: boxW, height: boxH)
                .position(x: boxX + boxW / 2, y: boxY + boxH / 2)
                .animation(.easeOut(duration: 0.14), value: rect)
        }
    }

    @ViewBuilder
    private func virtualPointer(
        point: CGPoint,
        bounds: ScreenRect,
        originX: CGFloat,
        originY: CGFloat,
        fittedW: CGFloat,
        fittedH: CGFloat
    ) -> some View {
        let relX = (Double(point.x) - bounds.x) / bounds.width
        let relY = (Double(point.y) - bounds.y) / bounds.height

        if relX >= -0.05, relX <= 1.05, relY >= -0.05, relY <= 1.05 {
            let px = originX + CGFloat(relX) * fittedW
            let py = originY + CGFloat(relY) * fittedH

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
