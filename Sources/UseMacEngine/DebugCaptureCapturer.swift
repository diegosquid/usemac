import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UseMacProtocol

/// Takes the PNGs for `debug_capture`, read-only, with ScreenCaptureKit:
/// - each of UseMac's windows on its own (`SCContentFilter(desktopIndependentWindow:)`), keeping its transparency and
///   window shadow, so the live preview's soft shadow and transparent margin show;
/// - for `context`, the display cropped to the preview's frame plus a margin, so the preview shows over what is
///   behind it. Apps the user's rules block are left out, like a whole-display `screenshot`.
///
/// Only windows of this process that the app listed are captured, whatever the list says.
struct DebugCaptureCapturer {
    enum Failure: Error {
        case nothingOnScreen
        case captureFailed(String)
    }

    struct Output {
        var images: [DebugCaptureImage]
        /// Kinds that were asked for by name and never showed up.
        var missingKinds: [DebugCaptureWindowKind]
        var contextMissing: Bool
    }

    let directory: String
    let ownPid: pid_t

    init(directory: String = UseMacDefaults.captureDirectory, ownPid: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.directory = directory
        self.ownPid = ownPid
    }

    func run(options: DebugCaptureOptions, windows: () async -> [DebugCaptureWindowRef]) async throws -> Output {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let burstStart = DispatchTime.now().uptimeNanoseconds
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        var pending: [Task<DebugCaptureImage?, Never>] = []
        var seenKinds: Set<DebugCaptureWindowKind> = []
        var sawContext = false
        var lastError: Error?

        for frameIndex in 0..<options.frames {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            // Windows move, resize and appear during an animation, so both lists are read again every frame.
            let refs = await windows()
            let wanted = refs.filter { options.kinds.contains($0.kind) }
            let previewRef = options.context ? refs.first(where: { $0.kind == .preview }) : nil
            if wanted.isEmpty && previewRef == nil {
                await Self.wait(untilNextFrameAfter: frameStart, index: frameIndex, options: options)
                continue
            }
            let shareable: SCShareableContent
            do {
                shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                throw Failure.captureFailed(error.localizedDescription)
            }
            let ownWindows = shareable.windows.filter { $0.isOnScreen && $0.owningApplication?.processID == ownPid }
            let byId = Dictionary(ownWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

            for ref in wanted {
                guard let window = byId[CGWindowID(ref.windowId)] else { continue }
                do {
                    let image = try await captureWindow(window)
                    seenKinds.insert(ref.kind)
                    let name = "debug-\(stamp)-\(Self.twoDigits(frameIndex))-\(ref.kind.rawValue)-\(ref.windowId).png"
                    let item = DebugCaptureImage(
                        path: (directory as NSString).appendingPathComponent(name),
                        kind: ref.kind.rawValue,
                        title: ref.title,
                        windowId: Int(ref.windowId),
                        frame: Self.screenRect(window.frame),
                        width: image.width,
                        height: image.height,
                        byteCount: 0,
                        frameIndex: frameIndex,
                        offsetMs: Self.ms(since: burstStart)
                    )
                    pending.append(Self.write(image, as: item))
                } catch {
                    // The window closed between the listing and the capture; the next frame tries again.
                    lastError = error
                }
            }

            if let previewRef, let preview = byId[CGWindowID(previewRef.windowId)] {
                do {
                    if let (image, region) = try await captureContext(around: preview, margin: CGFloat(options.contextMargin), in: shareable) {
                        sawContext = true
                        let name = "debug-\(stamp)-\(Self.twoDigits(frameIndex))-context.png"
                        let item = DebugCaptureImage(
                            path: (directory as NSString).appendingPathComponent(name),
                            kind: DebugCaptureParams.contextName,
                            title: nil,
                            windowId: nil,
                            frame: Self.screenRect(region),
                            width: image.width,
                            height: image.height,
                            byteCount: 0,
                            frameIndex: frameIndex,
                            offsetMs: Self.ms(since: burstStart)
                        )
                        pending.append(Self.write(image, as: item))
                    }
                } catch {
                    lastError = error
                }
            }

            await Self.wait(untilNextFrameAfter: frameStart, index: frameIndex, options: options)
        }

        var images: [DebugCaptureImage] = []
        for task in pending {
            if let image = await task.value {
                images.append(image)
            }
        }
        if images.isEmpty {
            if !pending.isEmpty {
                throw Failure.captureFailed("The captures were taken but couldn't be saved in \(directory).")
            }
            if let lastError {
                throw Failure.captureFailed(lastError.localizedDescription)
            }
            throw Failure.nothingOnScreen
        }
        return Output(
            images: images,
            missingKinds: options.kinds.filter { !seenKinds.contains($0) },
            contextMissing: options.context && !sawContext
        )
    }

    /// Sleeps until the next frame is due, measured from the start of this one. Nothing after the last frame.
    private static func wait(untilNextFrameAfter frameStart: UInt64, index: Int, options: DebugCaptureOptions) async {
        guard index < options.frames - 1 else { return }
        let nextStart = frameStart + UInt64(options.intervalMs) * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        if nextStart > now {
            try? await Task.sleep(nanoseconds: nextStart - now)
        }
    }

    // MARK: - Capturing

    private func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        let rect = filter.contentRect.isEmpty ? window.frame : filter.contentRect
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best
        config.showsCursor = false
        // Keep what the window really looks like: its shadow, and transparent areas as transparent pixels.
        config.ignoreShadowsSingleWindow = false
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The display under the preview, cropped to the preview's frame plus `margin`. Nil when the preview is on no display.
    private func captureContext(
        around preview: SCWindow,
        margin: CGFloat,
        in shareable: SCShareableContent
    ) async throws -> (CGImage, CGRect)? {
        guard let display = Self.display(containing: preview.frame, in: shareable.displays) else { return nil }
        let region = Self.contextRegion(windowFrame: preview.frame, margin: margin, displayFrame: display.frame)
        guard !region.isEmpty else { return nil }

        // Like a whole-display screenshot: the windows of apps the user's rules block are left out.
        let rules = TargetRulesStore.shared.rules
        let blockedApps = shareable.applications.filter { rules.blocksApp(bundleId: $0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: blockedApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        config.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = max(1, Int((region.width * scale).rounded()))
        config.height = max(1, Int((region.height * scale).rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, region)
    }

    /// The display that shows most of `frame` (global points, top-left origin).
    static func display(containing frame: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        let best = displays.max { Self.overlapArea($0.frame, frame) < Self.overlapArea($1.frame, frame) }
        guard let best, Self.overlapArea(best.frame, frame) > 0 else { return nil }
        return best
    }

    /// The region a context capture covers: the window's frame grown by `margin` on every side, kept on its display.
    static func contextRegion(windowFrame: CGRect, margin: CGFloat, displayFrame: CGRect) -> CGRect {
        windowFrame.insetBy(dx: -max(0, margin), dy: -max(0, margin)).intersection(displayFrame).integral
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    // MARK: - Writing

    /// Encodes and writes the PNG off the capture loop, so a burst keeps its pace.
    private static func write(_ image: CGImage, as item: DebugCaptureImage) -> Task<DebugCaptureImage?, Never> {
        Task.detached(priority: .userInitiated) {
            guard let byteCount = writePNG(image, to: item.path) else { return nil }
            var written = item
            written.byteCount = byteCount
            return written
        }
    }

    /// Writes `image` as a PNG with its alpha channel, never over an existing file. Returns the size, or nil on failure.
    static func writePNG(_ image: CGImage, to path: String) -> Int? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            try (data as Data).write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
        } catch {
            return nil
        }
        return data.length
    }

    static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func ms(since start: UInt64) -> Double {
        (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000).rounded()
    }
}
