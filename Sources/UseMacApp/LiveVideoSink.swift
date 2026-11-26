import AppKit
import Combine
import QuartzCore
import UseMacEngine
import UseMacProtocol

@MainActor
public final class LiveVideoSink: ObservableObject {
    @Published public private(set) var hasReceivedFrame: Bool = false
    @Published public private(set) var sourceBounds: ScreenRect?
    @Published public private(set) var sourceName: String = "Agent"
    @Published public private(set) var isWindowCapture: Bool = false
    @Published public private(set) var isBrowserStream: Bool = false
    /// Window and app the shown frame comes from (nil when unknown, e.g. a Chrome extension frame).
    @Published public private(set) var sourceWindowId: UInt32?
    @Published public private(set) var sourcePid: Int32?

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
}
