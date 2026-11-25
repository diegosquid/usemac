import AppKit
import Combine
import QuartzCore
import UseMacEngine
import UseMacProtocol

@MainActor
public final class LiveVideoSink: ObservableObject {
    public static let defaultAspectRatio: CGFloat = 268.0 / 172.0

    @Published public private(set) var hasReceivedFrame: Bool = false
    /// Aspect ratio the HUD sizes itself to. Follows the frames only through `aspectStabilizer`, so it does
    /// not jump on every small change, on a source that flips for a moment, or while an action batch runs.
    @Published public private(set) var frameAspectRatio: CGFloat = LiveVideoSink.defaultAspectRatio
    @Published public private(set) var sourceBounds: ScreenRect?
    @Published public private(set) var sourceName: String = "Agent"
    @Published public private(set) var isWindowCapture: Bool = false
    @Published public private(set) var isBrowserStream: Bool = false
    /// Window and app the shown frame comes from (nil when unknown, e.g. a Chrome extension frame).
    @Published public private(set) var sourceWindowId: UInt32?
    @Published public private(set) var sourcePid: Int32?

    private weak var targetLayer: CALayer?
    private var latestSurface: AnyObject?
    private var aspectStabilizer = PreviewAspectRatioStabilizer()
    private var holdsAspectRatio = false
    private var aspectSettleTask: Task<Void, Never>?

    public init() {}

    public func attach(layer: CALayer) {
        self.targetLayer = layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = latestSurface
        CATransaction.commit()
    }

    public func pushFrame(
        surface: AnyObject,
        width: Int,
        height: Int,
        sourceBounds: ScreenRect?,
        sourceName: String,
        isWindow: Bool,
        windowId: UInt32? = nil,
        pid: Int32? = nil
    ) {
        applyFrame(
            contents: surface,
            width: width,
            height: height,
            sourceBounds: sourceBounds,
            sourceName: sourceName,
            isWindow: isWindow,
            isBrowser: false,
            windowId: windowId,
            pid: pid
        )
    }

    /// Shows a still image. `isBrowser` marks a Chrome extension frame (page coordinates); pass false for a
    /// cached native window thumbnail.
    public func pushCGImage(
        _ cgImage: CGImage,
        width: Int,
        height: Int,
        sourceBounds: ScreenRect?,
        sourceName: String,
        isBrowser: Bool = true,
        pid: Int32? = nil
    ) {
        applyFrame(
            contents: cgImage,
            width: width,
            height: height,
            sourceBounds: sourceBounds,
            sourceName: sourceName,
            isWindow: true,
            isBrowser: isBrowser,
            windowId: nil,
            pid: pid
        )
    }

    /// While held, the HUD keeps its size; a pending aspect change applies when the hold ends.
    public func setAspectRatioHold(_ hold: Bool) {
        guard hold != holdsAspectRatio else { return }
        holdsAspectRatio = hold
        if !hold {
            settlePendingAspectRatio()
            scheduleAspectSettleIfNeeded()
        }
    }

    private func applyFrame(
        contents: AnyObject,
        width: Int,
        height: Int,
        sourceBounds: ScreenRect?,
        sourceName: String,
        isWindow: Bool,
        isBrowser: Bool,
        windowId: UInt32?,
        pid: Int32?
    ) {
        self.latestSurface = contents
        if let targetLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            targetLayer.contents = contents
            CATransaction.commit()
        }
        if width > 0 && height > 0 {
            let clamped = min(max(CGFloat(width) / CGFloat(height), 0.62), 2.15)
            if let applied = aspectStabilizer.observe(Double(clamped), at: Self.now(), hold: holdsAspectRatio) {
                setAspectRatio(CGFloat(applied))
            }
            scheduleAspectSettleIfNeeded()
        }
        if !hasReceivedFrame { hasReceivedFrame = true }
        if self.sourceBounds != sourceBounds { self.sourceBounds = sourceBounds }
        if self.sourceName != sourceName { self.sourceName = sourceName }
        if self.isWindowCapture != isWindow { self.isWindowCapture = isWindow }
        if self.isBrowserStream != isBrowser { self.isBrowserStream = isBrowser }
        if self.sourceWindowId != windowId { self.sourceWindowId = windowId }
        if self.sourcePid != pid { self.sourcePid = pid }
    }

    public func reset() {
        latestSurface = nil
        hasReceivedFrame = false
        aspectSettleTask?.cancel()
        aspectSettleTask = nil
        aspectStabilizer.reset()
        frameAspectRatio = Self.defaultAspectRatio
        sourceBounds = nil
        sourceName = "Agent"
        isWindowCapture = false
        isBrowserStream = false
        sourceWindowId = nil
        sourcePid = nil
        if let targetLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            targetLayer.contents = nil
            CATransaction.commit()
        }
    }

    private func setAspectRatio(_ ratio: CGFloat) {
        if abs(ratio - frameAspectRatio) > 0.001 {
            frameAspectRatio = ratio
        }
    }

    private func settlePendingAspectRatio() {
        if let applied = aspectStabilizer.settle(at: Self.now(), hold: holdsAspectRatio) {
            setAspectRatio(CGFloat(applied))
        }
    }

    /// A static window stops sending frames, so a pending change is re-checked on a timer instead of
    /// waiting for the next frame.
    private func scheduleAspectSettleIfNeeded() {
        guard aspectStabilizer.hasPending, !holdsAspectRatio, aspectSettleTask == nil else { return }
        let delay = UInt64((aspectStabilizer.settleSeconds + 0.05) * 1_000_000_000)
        aspectSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.aspectSettleTask = nil
            self.settlePendingAspectRatio()
            self.scheduleAspectSettleIfNeeded()
        }
    }

    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
