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

    public func capture(
        _ request: ScreenshotRequest,
        targetApp: AppDescriptor? = nil
    ) async throws -> ScreenshotResult {
        let startNs = DispatchTime.now().uptimeNanoseconds

        // A capture for a named app must show that app. Falling back to the whole display would hand the
        // agent the user's screen labeled as the app.
        let namedApp = !(request.app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let prepared = try await prepareCapture(
            targetApp: targetApp,
            maxDimension: request.maxDimension,
            allowDisplayFallback: !namedApp
        )

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: prepared.filter,
            configuration: prepared.config
        )

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CaptureError.jpegEncodingFailed
        }

        let clampedQuality = min(max(request.quality, 0.1), 1.0)
        let options = [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.jpegEncodingFailed
        }

        try FileManager.default.createDirectory(
            atPath: UseMacDefaults.captureDirectory,
            withIntermediateDirectories: true
        )

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let path = "\(UseMacDefaults.captureDirectory)/capture-\(nowMs).jpg"
        let jpegData = data as Data
        try jpegData.write(to: URL(fileURLWithPath: path))

        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let base64 = request.includeBase64 ? jpegData.base64EncodedString() : nil

        return ScreenshotResult(
            path: path,
            mimeType: "image/jpeg",
            width: cgImage.width,
            height: cgImage.height,
            byteCount: jpegData.count,
            latencyMs: latencyMs,
            base64Data: base64
        )
    }

    /// Captures an in-memory CGImage preview of the target app window (or the primary display when no app is
    /// given) without writing to disk. Returns nil when the app has no capturable window.
    public func capturePreviewCGImage(
        targetApp: AppDescriptor?,
        maxDimension: Int = 560
    ) async -> (image: CGImage, windowBounds: ScreenRect?)? {
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

    private func prepareCapture(
        targetApp: AppDescriptor?,
        maxDimension: Int,
        allowDisplayFallback: Bool
    ) async throws -> (filter: SCContentFilter, config: SCStreamConfiguration, windowBounds: ScreenRect?) {
        if let targetApp, TargetRulesStore.shared.blocksProcess(pid: targetApp.pid) {
            throw CaptureError.targetBlocked(appName: targetApp.name)
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let filter: SCContentFilter
        let sourceSize: CGSize
        let windowBounds: ScreenRect?

        if let targetApp,
           let targetWindow = selectWindow(for: targetApp, in: shareable.windows) {
            filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            sourceSize = targetWindow.frame.size
            windowBounds = ScreenRect(
                x: Double(targetWindow.frame.origin.x),
                y: Double(targetWindow.frame.origin.y),
                width: Double(targetWindow.frame.size.width),
                height: Double(targetWindow.frame.size.height)
            )
        } else if let targetApp, !allowDisplayFallback {
            throw CaptureError.noCapturableWindow(appName: targetApp.name)
        } else if let display = shareable.displays.first {
            // A whole-display capture leaves out the windows of apps the user's rules block.
            let rules = TargetRulesStore.shared.rules
            let blockedApps = shareable.applications.filter { rules.blocksApp(bundleId: $0.bundleIdentifier) }
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
    private func selectWindow(for app: AppDescriptor, in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.compactMap(LiveScreenStreamer.captureCandidate(from:))
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
