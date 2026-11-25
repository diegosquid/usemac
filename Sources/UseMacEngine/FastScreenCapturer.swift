import CoreGraphics
import Foundation
import ImageIO
import UseMacProtocol
import ScreenCaptureKit

public final class FastScreenCapturer: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case noDisplayAvailable
        case jpegEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                return "No shareable display found for screen capture"
            case .jpegEncodingFailed:
                return "Failed to encode captured image as JPEG"
            }
        }
    }

    public init() {}

    public func capture(
        _ request: ScreenshotRequest,
        targetApp: AppDescriptor? = nil
    ) async throws -> ScreenshotResult {
        let startNs = DispatchTime.now().uptimeNanoseconds

        let prepared = try await prepareCapture(targetApp: targetApp, maxDimension: request.maxDimension)

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

    /// Captures an in-memory CGImage preview of the target app window (or primary display) without writing to disk.
    public func capturePreviewCGImage(
        targetApp: AppDescriptor?,
        maxDimension: Int = 560
    ) async -> (image: CGImage, windowBounds: ScreenRect?)? {
        do {
            let prepared = try await prepareCapture(targetApp: targetApp, maxDimension: maxDimension)
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
        maxDimension: Int
    ) async throws -> (filter: SCContentFilter, config: SCStreamConfiguration, windowBounds: ScreenRect?) {
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
        } else if let display = shareable.displays.first {
            filter = SCContentFilter(display: display, excludingWindows: [])
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

    private func selectWindow(for app: AppDescriptor, in windows: [SCWindow]) -> SCWindow? {
        let matching = windows.filter {
            $0.owningApplication?.processID == app.pid
                && $0.frame.width > 10
                && $0.frame.height > 10
        }
        if let onScreenTitled = matching.first(where: { $0.isOnScreen && !($0.title?.isEmpty ?? true) }) {
            return onScreenTitled
        }
        if let onScreen = matching.first(where: { $0.isOnScreen }) {
            return onScreen
        }
        return matching.first
    }
}
