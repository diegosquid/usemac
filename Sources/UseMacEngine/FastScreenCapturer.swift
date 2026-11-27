import CoreGraphics
import Foundation
import ImageIO
import UseMacProtocol
import ScreenCaptureKit

public final class FastScreenCapturer: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case noDisplayAvailable
        case jpegEncodingFailed
        case noCapturableWindow(appName: String)
        case targetBlocked(appName: String)

        public var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                return "No shareable display found for screen capture"
            case .jpegEncodingFailed:
                return "Failed to encode captured image as JPEG"
            case .noCapturableWindow(let appName):
                return "\(appName) has no window that can be captured (no open window, or only windows smaller than \(Int(WindowResolver.minimumContentSize.width))x\(Int(WindowResolver.minimumContentSize.height))). Open or restore its window and try again."
            case .targetBlocked(let appName):
                return TargetRules.blockedAppMessage(appName)
            }
        }
    }

    public init() {}

    /// Captures the target app window (or primary display when no app is named).
    /// When `streamer` already has a live frame for the target window, reuses it in <5 ms without
    /// hitting `SCShareableContent`. When `writeToDisk` is `false`, skips creating/writing a temp file.
    public func capture(
        _ request: ScreenshotRequest,
        targetApp: AppDescriptor? = nil,
        streamer: LiveScreenStreamer? = nil,
        writeToDisk: Bool = true
    ) async throws -> ScreenshotResult {
        try await captureWindow(request, targetApp: targetApp, streamer: streamer, writeToDisk: writeToDisk)
    }

    /// Captures a window screenshot, reusing `streamer.latestFrame(forWindowID:)` when available
    /// and optionally skipping disk writes (`writeToDisk: false`).
    public func captureWindow(
        _ request: ScreenshotRequest,
        targetApp: AppDescriptor? = nil,
        streamer: LiveScreenStreamer? = nil,
        writeToDisk: Bool = true
    ) async throws -> ScreenshotResult {
        let startNs = DispatchTime.now().uptimeNanoseconds

        if let targetApp, TargetRulesStore.shared.blocksProcess(pid: targetApp.pid) {
            throw CaptureError.targetBlocked(appName: targetApp.name)
        }
        // A named app must never be replaced by the whole display, even if it could not be resolved.
        let namedApp = !(request.app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let capturedImage: CGImage
        if let liveImage = liveStreamImage(for: targetApp, streamer: streamer) {
            capturedImage = Self.applyRegionAndScale(
                liveImage,
                region: request.region,
                maxDimension: request.maxDimension
            )
        } else {
            let prepared = try await prepareCapture(
                targetApp: targetApp,
                maxDimension: request.maxDimension,
                allowDisplayFallback: !namedApp,
                requestedAppName: request.app
            )

            let rawImage = try await SCScreenshotManager.captureImage(
                contentFilter: prepared.filter,
                configuration: prepared.config
            )
            capturedImage = Self.applyRegionAndScale(
                rawImage,
                region: request.region,
                maxDimension: request.maxDimension
            )
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CaptureError.jpegEncodingFailed
        }

        let clampedQuality = min(max(request.quality, 0.1), 1.0)
        let options = [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
        CGImageDestinationAddImage(destination, capturedImage, options)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.jpegEncodingFailed
        }

        let jpegData = data as Data
        let path: String
        if writeToDisk {
            try FileManager.default.createDirectory(
                atPath: UseMacDefaults.captureDirectory,
                withIntermediateDirectories: true
            )
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let filePath = "\(UseMacDefaults.captureDirectory)/capture-\(nowMs).jpg"
            try jpegData.write(to: URL(fileURLWithPath: filePath))
            path = filePath
        } else {
            path = ""
        }

        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let base64 = request.includeBase64 ? jpegData.base64EncodedString() : nil

        return ScreenshotResult(
            path: path,
            mimeType: "image/jpeg",
            width: capturedImage.width,
            height: capturedImage.height,
            byteCount: jpegData.count,
            latencyMs: latencyMs,
            base64Data: base64
        )
    }

    /// Captures an in-memory CGImage preview of the target app window (or the primary display when no app is
    /// given) without writing to disk. Returns nil when the app has no capturable window.
    public func capturePreviewCGImage(
        targetApp: AppDescriptor?,
        maxDimension: Int = 560,
        streamer: LiveScreenStreamer? = nil
    ) async -> (image: CGImage, windowBounds: ScreenRect?)? {
        if let targetApp, TargetRulesStore.shared.blocksProcess(pid: targetApp.pid) {
            return nil
        }
        if let targetApp,
           Self.shouldAllowLiveFrameReuse(for: targetApp, rules: TargetRulesStore.shared.rules),
           let streamer,
           let windowId = targetWindowIDForLiveLookup(targetApp: targetApp, streamer: streamer),
           let live = streamer.latestFrameWithBounds(forWindowID: windowId) {
            let scaled = Self.applyRegionAndScale(live.image, region: nil, maxDimension: maxDimension)
            return (scaled, live.windowBounds ?? targetApp.windowBounds)
        }
        do {
            let prepared = try await prepareCapture(
                targetApp: targetApp,
                maxDimension: maxDimension,
                allowDisplayFallback: targetApp == nil
            )
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: prepared.filter,
                configuration: prepared.config
            )
            return (cgImage, prepared.windowBounds)
        } catch {
            return nil
        }
    }

    private func targetWindowIDForLiveLookup(targetApp: AppDescriptor, streamer: LiveScreenStreamer) -> CGWindowID? {
        guard streamer.streamedWindowID != nil else { return nil }
        if let known = targetApp.windowId, known != 0 {
            return CGWindowID(known)
        }
        if targetApp.pid > 0, let resolved = WindowResolver.targetWindowID(pid: targetApp.pid) {
            return resolved
        }
        return nil
    }

    private func liveStreamImage(for targetApp: AppDescriptor?, streamer: LiveScreenStreamer?) -> CGImage? {
        guard let targetApp, let streamer,
              Self.shouldAllowLiveFrameReuse(for: targetApp, rules: TargetRulesStore.shared.rules),
              let windowId = targetWindowIDForLiveLookup(targetApp: targetApp, streamer: streamer) else {
            return nil
        }
        return streamer.latestFrame(forWindowID: windowId)
    }

    static func shouldExcludeFromDisplayCapture(bundleId: String?, name: String?, rules: TargetRules) -> Bool {
        rules.blocksApp(bundleId: bundleId)
            || (rules.hasSiteRules && NativeBrowserSiteRules.isChromiumApp(bundleId: bundleId, name: name))
    }

    static func shouldAllowLiveFrameReuse(for app: AppDescriptor, rules: TargetRules) -> Bool {
        // Tabs in the same browser window share a window id but may have different site permissions.
        !(rules.hasSiteRules && NativeBrowserSiteRules.isChromiumApp(bundleId: app.bundleId, name: app.name))
    }

    static func requiresExactWindowID(for app: AppDescriptor, rules: TargetRules) -> Bool {
        (app.windowId ?? 0) != 0 && rules.hasSiteRules
            && NativeBrowserSiteRules.isChromiumApp(bundleId: app.bundleId, name: app.name)
    }

    private static func applyRegionAndScale(_ image: CGImage, region: ScreenRect?, maxDimension: Int) -> CGImage {
        var working = image
        if let region, region.width >= 2, region.height >= 2 {
            let imageBounds = CGRect(x: 0, y: 0, width: working.width, height: working.height)
            let cropRect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
                .integral
                .intersection(imageBounds)
            if !cropRect.isNull, cropRect.width >= 2, cropRect.height >= 2,
               let cropped = working.cropping(to: cropRect) {
                working = cropped
            }
        }

        let maxDim = max(1, maxDimension)
        let currentMax = max(working.width, working.height)
        guard currentMax > maxDim else {
            return working
        }

        let scale = Double(maxDim) / Double(currentMax)
        let targetW = max(1, Int((Double(working.width) * scale).rounded()))
        let targetH = max(1, Int((Double(working.height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return working
        }
        ctx.interpolationQuality = .high
        ctx.draw(working, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? working
    }

    private func prepareCapture(
        targetApp: AppDescriptor?,
        maxDimension: Int,
        allowDisplayFallback: Bool,
        requestedAppName: String? = nil
    ) async throws -> (filter: SCContentFilter, config: SCStreamConfiguration, windowBounds: ScreenRect?) {
        if let targetApp, TargetRulesStore.shared.blocksProcess(pid: targetApp.pid) {
            throw CaptureError.targetBlocked(appName: targetApp.name)
        }
        if !allowDisplayFallback && targetApp == nil {
            throw CaptureError.noCapturableWindow(appName: requestedAppName ?? "the target app")
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let rules = TargetRulesStore.shared.rules

        let filter: SCContentFilter
        let sourceSize: CGSize
        let windowBounds: ScreenRect?

        if let targetApp,
           let targetWindow = selectWindow(for: targetApp, in: shareable.windows, rules: rules) {
            filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            sourceSize = targetWindow.frame.size
            windowBounds = ScreenRect(
                x: Double(targetWindow.frame.origin.x),
                y: Double(targetWindow.frame.origin.y),
                width: Double(targetWindow.frame.size.width),
                height: Double(targetWindow.frame.size.height)
            )
        } else if let targetApp, !allowDisplayFallback || Self.requiresExactWindowID(for: targetApp, rules: rules) {
            throw CaptureError.noCapturableWindow(appName: targetApp.name)
        } else if let display = shareable.displays.first {
            // A display capture cannot confirm the active site in each browser window.
            let blockedApps = shareable.applications.filter {
                Self.shouldExcludeFromDisplayCapture(bundleId: $0.bundleIdentifier, name: $0.applicationName, rules: rules)
            }
            filter = SCContentFilter(display: display, excludingApplications: blockedApps, exceptingWindows: [])
            sourceSize = CGSize(width: display.width, height: display.height)
            windowBounds = nil
        } else {
            throw CaptureError.noDisplayAvailable
        }

        let maxDim = Double(max(1, maxDimension))
        let srcW = max(1.0, Double(sourceSize.width))
        let srcH = max(1.0, Double(sourceSize.height))
        let scale = min(1.0, maxDim / max(srcW, srcH))

        let config = SCStreamConfiguration()
        config.width = max(1, Int((srcW * scale).rounded()))
        config.height = max(1, Int((srcH * scale).rounded()))
        config.scalesToFit = true
        config.showsCursor = false

        return (filter, config, windowBounds)
    }

    /// Same exact-id choice as the live preview (descriptor `windowId`, else the AX focused window), so a
    /// screenshot never lands on one of Chrome's tiny helper windows.
    private func selectWindow(for app: AppDescriptor, in windows: [SCWindow], rules: TargetRules) -> SCWindow? {
        var candidates = windows.compactMap(LiveScreenStreamer.captureCandidate(from:))
        if Self.requiresExactWindowID(for: app, rules: rules), let windowId = app.windowId {
            candidates = candidates.filter { $0.windowId == windowId }
            guard !candidates.isEmpty else { return nil }
        }
        let targets = WindowResolver.targetWindows(
            pid: app.pid,
            knownWindowId: app.windowId.map { CGWindowID($0) },
            availableIds: Set(candidates.map(\.windowId))
        )
        guard let chosen = WindowResolver.chooseCaptureWindow(from: candidates, pid: app.pid, targets: targets) else {
            return nil
        }
        return windows.first { $0.windowID == chosen.windowId }
    }
}
