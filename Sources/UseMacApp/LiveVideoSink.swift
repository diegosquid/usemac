import AppKit
import Combine
import QuartzCore
import UseMacProtocol

@MainActor
public final class LiveVideoSink: ObservableObject {
    @Published public private(set) var hasReceivedFrame: Bool = false
    @Published public private(set) var frameAspectRatio: CGFloat = 268.0 / 172.0
    @Published public private(set) var sourceBounds: ScreenRect?
    @Published public private(set) var sourceName: String = "Agent"
    @Published public private(set) var isWindowCapture: Bool = false
    @Published public private(set) var isBrowserStream: Bool = false

    private weak var targetLayer: CALayer?
    private var latestSurface: AnyObject?

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
        isWindow: Bool
    ) {
        applyFrame(
            contents: surface,
            width: width,
            height: height,
            sourceBounds: sourceBounds,
            sourceName: sourceName,
            isWindow: isWindow,
            isBrowser: false
        )
    }

    public func pushCGImage(
        _ cgImage: CGImage,
        width: Int,
        height: Int,
        sourceBounds: ScreenRect?,
        sourceName: String
    ) {
        applyFrame(
            contents: cgImage,
            width: width,
            height: height,
            sourceBounds: sourceBounds,
            sourceName: sourceName,
            isWindow: true,
            isBrowser: true
        )
    }

    private func applyFrame(
        contents: AnyObject,
        width: Int,
        height: Int,
        sourceBounds: ScreenRect?,
        sourceName: String,
        isWindow: Bool,
        isBrowser: Bool
    ) {
        self.latestSurface = contents
        if let targetLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            targetLayer.contents = contents
            CATransaction.commit()
        }
        if !hasReceivedFrame { hasReceivedFrame = true }
        if width > 0 && height > 0 {
            let clamped = min(max(CGFloat(width) / CGFloat(height), 0.62), 2.15)
            if abs(clamped - frameAspectRatio) > 0.04 {
                frameAspectRatio = clamped
            }
        }
        if self.sourceBounds != sourceBounds { self.sourceBounds = sourceBounds }
        if self.sourceName != sourceName { self.sourceName = sourceName }
        if self.isWindowCapture != isWindow { self.isWindowCapture = isWindow }
        if self.isBrowserStream != isBrowser { self.isBrowserStream = isBrowser }
    }

    public func reset() {
        latestSurface = nil
        hasReceivedFrame = false
        frameAspectRatio = 268.0 / 172.0
        sourceBounds = nil
        sourceName = "Agent"
        isWindowCapture = false
        isBrowserStream = false
        if let targetLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            targetLayer.contents = nil
            CATransaction.commit()
        }
    }
}
