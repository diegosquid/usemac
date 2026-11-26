import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UseMacProtocol
import Vision

public enum LocalVisionError: Error, LocalizedError, Equatable {
    /// The image is too small to read anything from (e.g. a 52x20 helper window was captured).
    case captureTooSmall(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .captureTooSmall(let width, let height):
            return "\(LocalVisionEngine.captureTooSmallPrefix) the captured image is \(width)x\(height) px; local vision needs at least \(LocalVisionEngine.minimumImageSide) px on the shorter side. The capture probably hit a helper window instead of the app's main window: make sure the window is open and not minimized, then capture again."
        }
    }
}

/// On-device Apple Vision OCR and native Swift frame-diff engine (Neural Engine, zero Python/MLX sidecar).
public final class LocalVisionEngine: @unchecked Sendable {
    /// Every refusal for a too-small image starts with this, so callers can map it to an error code.
    public static let captureTooSmallPrefix = "CAPTURE_TOO_SMALL:"
    /// Shorter side, in pixels, below which an image is refused.
    public static let minimumImageSide = 64

    public var onStatusChanged: (@Sendable (VisionStatus) -> Void)?

    public init() {}

    // MARK: - Legacy Directory Helper

    @discardableResult
    public static func migrateLegacyDirectory(from legacy: URL, to current: URL) -> Bool {
        var legacyPath = legacy.path
        while legacyPath.count > 1 && legacyPath.hasSuffix("/") {
            legacyPath.removeLast()
        }
        var currentPath = current.path
        while currentPath.count > 1 && currentPath.hasSuffix("/") {
            currentPath.removeLast()
        }

        var legacyStat = stat()
        guard Darwin.lstat(legacyPath, &legacyStat) == 0,
              (legacyStat.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }

        let fm = FileManager.default
        var currentStat = stat()
        if Darwin.lstat(currentPath, &currentStat) == 0 || fm.fileExists(atPath: currentPath) {
            return false
        }

        do {
            try fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: current)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Status

    public func currentStatus() -> VisionStatus {
        VisionStatus(
            enabled: true,
            state: "ready",
            modelId: "apple-vision-ocr",
            backend: "apple-vision-ocr",
            ocrAvailable: true,
            runtimeInstalled: false,
            modelDownloaded: false,
            workerRunning: false,
            installProgress: nil,
            lastError: nil
        )
    }

    // MARK: - Native Swift Frame-Diff (< 2 ms, 0 MB)

    public static func computeFrameDiffPercent(beforeJPEG: Data, afterJPEG: Data) -> Double? {
        guard let imgA = decodeCGImage(fromJPEG: beforeJPEG),
              let imgB = decodeCGImage(fromJPEG: afterJPEG) else {
            return nil
        }
        return computeFrameDiffPercent(before: imgA, after: imgB)
    }

    public static func computeFrameDiffPercent(before: CGImage, after: CGImage) -> Double {
        let w = 64
        let h = 40
        let count = w * h
        guard let bufA = downsampleGrayscale(before, width: w, height: h),
              let bufB = downsampleGrayscale(after, width: w, height: h) else {
            return 100.0
        }
        var totalDiff: Int = 0
        for i in 0..<count {
            totalDiff += abs(Int(bufA[i]) - Int(bufB[i]))
        }
        let pct = (Double(totalDiff) / Double(count * 255)) * 100.0
        return (pct * 100.0).rounded() / 100.0
    }

    private static func downsampleGrayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    public static func decodeCGImage(fromJPEG data: Data) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Native Apple Vision OCR (Neural Engine, ~25 ms, 0 MB)

    public static func recognizeText(
        in cgImage: CGImage,
        viewportWidth: Double,
        viewportHeight: Double,
        fast: Bool = false
    ) -> [VisionDetection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        request.recognitionLanguages = ["pt-BR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }
        var detections: [VisionDetection] = []
        detections.reserveCapacity(observations.count)

        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = obs.boundingBox // normalized bottom-left origin
            let x = (Double(box.minX) * viewportWidth * 10).rounded() / 10
            let y = ((1.0 - Double(box.maxY)) * viewportHeight * 10).rounded() / 10
            let w = (Double(box.width) * viewportWidth * 10).rounded() / 10
            let h = (Double(box.height) * viewportHeight * 10).rounded() / 10
            let cx = ((x + w / 2.0) * 10).rounded() / 10
            let cy = ((y + h / 2.0) * 10).rounded() / 10
            detections.append(VisionDetection(
                label: text,
                x: cx,
                y: cy,
                frame: ScreenRect(x: x, y: y, width: w, height: h),
                confidence: Double(top.confidence),
                source: "apple-vision-ocr"
            ))
        }
        return detections
    }

    /// Throws `LocalVisionError.captureTooSmall` when the image's shorter side is under `minimumImageSide`.
    /// Reads only the image header. An unreadable file passes, so the normal error paths report it.
    public static func validateImageSize(atPath imagePath: String) throws {
        let url = URL(fileURLWithPath: imagePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return
        }
        if min(width, height) < minimumImageSide {
            throw LocalVisionError.captureTooSmall(width: width, height: height)
        }
    }

    public func query(
        mode: String,
        query: String?,
        imagePath: String,
        viewportWidth: Double,
        viewportHeight: Double
    ) async -> VisionQueryResult {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let normalizedMode = mode.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveMode = normalizedMode.isEmpty ? "ask" : normalizedMode

        // Never answer from a sliver: a confident answer from a 52x20 capture is worse than none.
        do {
            try Self.validateImageSize(atPath: imagePath)
        } catch {
            let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            return VisionQueryResult(
                mode: effectiveMode,
                backend: "size-check",
                modelId: nil,
                latencyMs: (latencyMs * 100).rounded() / 100,
                answer: error.localizedDescription,
                verified: effectiveMode == "verify" ? false : nil,
                blockingDetected: false,
                detections: [],
                imagePath: imagePath
            )
        }

        return await runOCRQuery(
            mode: effectiveMode,
            query: query,
            imagePath: imagePath,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            startNs: startNs
        )
    }

    private func runOCRQuery(
        mode: String,
        query: String?,
        imagePath: String,
        viewportWidth: Double,
        viewportHeight: Double,
        startNs: UInt64
    ) async -> VisionQueryResult {
        await Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath))
            let cgImage = data.flatMap { Self.decodeCGImage(fromJPEG: $0) }
            let rawDetections = cgImage.map {
                Self.recognizeText(in: $0, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            } ?? []
            let detections = rawDetections.sorted { a, b in
                let rowA = Int(a.y / 14.0)
                let rowB = Int(b.y / 14.0)
                if rowA != rowB { return rowA < rowB }
                return a.x < b.x
            }
            let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0

            if mode == "ocr" || mode == "describe" {
                let preview = detections.prefix(32).map(\.label).joined(separator: " | ")
                let prefix = mode == "describe"
                    ? "Visible screen text (Apple Vision OCR, \(detections.count) blocks): "
                    : "Detected \(detections.count) text blocks: "
                return VisionQueryResult(
                    mode: mode,
                    backend: "apple-vision-ocr",
                    modelId: nil,
                    latencyMs: (latencyMs * 100).rounded() / 100,
                    answer: detections.isEmpty ? "No readable text detected." : prefix + preview,
                    blockingDetected: false,
                    detections: Array(detections.prefix(32)),
                    imagePath: imagePath
                )
            }

            if mode == "ask" || mode == "verify" {
                let q = (query ?? "").lowercased()
                let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
                let matched = detections.filter { det in
                    let lower = det.label.lowercased()
                    return tokens.contains(where: { lower.contains($0) })
                }
                let matchedPreview = matched.prefix(12).map(\.label).joined(separator: " | ")
                let allPreview = detections.prefix(20).map(\.label).joined(separator: " | ")
                if mode == "verify" {
                    let matchRatio = tokens.isEmpty ? 0.0 : Double(tokens.filter { tok in
                        detections.contains(where: { $0.label.lowercased().contains(tok) })
                    }.count) / Double(tokens.count)
                    let isVerified: Bool? = tokens.isEmpty ? nil : (matchRatio >= 0.5)
                    let ans = matched.isEmpty
                        ? "Apple Vision OCR did not find matching text for \"\(query ?? "")\". Visible text: \(allPreview)"
                        : "Apple Vision OCR matched: \(matchedPreview)"
                    return VisionQueryResult(
                        mode: "verify",
                        backend: "apple-vision-ocr",
                        modelId: nil,
                        latencyMs: (latencyMs * 100).rounded() / 100,
                        answer: ans,
                        verified: isVerified,
                        blockingDetected: false,
                        detections: Array((matched.isEmpty ? detections : matched).prefix(20)),
                        imagePath: imagePath
                    )
                } else {
                    let ans = matched.isEmpty
                        ? "Visible screen text (Apple Vision OCR): \(allPreview)"
                        : "Relevant screen text (Apple Vision OCR): \(matchedPreview) | Context: \(allPreview)"
                    return VisionQueryResult(
                        mode: "ask",
                        backend: "apple-vision-ocr",
                        modelId: nil,
                        latencyMs: (latencyMs * 100).rounded() / 100,
                        answer: detections.isEmpty ? "No readable text detected on screen." : ans,
                        blockingDetected: false,
                        detections: Array((matched.isEmpty ? detections : matched).prefix(20)),
                        imagePath: imagePath
                    )
                }
            }

            // Smart OCR matching for locate/diagnose
            let q = (query ?? "").lowercased()
            let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
            let dismissKeywords = ["fechar", "close", "não", "nao", "agora não", "recusar", "rejeitar", "no thanks", "not now", "x", "×"]
            let popupKeywords = ["notificaç", "notificac", "cookies", "permitir", "eu quero", "newsletter", "assine"]

            let hasPopupHint = detections.contains { det in
                let lower = det.label.lowercased()
                return popupKeywords.contains(where: { lower.contains($0) })
            }

            var best: VisionDetection?
            var bestScore = 0
            for det in detections {
                let lower = det.label.lowercased()
                var score = 0
                if !q.isEmpty && lower == q { score += 20 }
                if !q.isEmpty && lower.contains(q) { score += 12 }
                for tok in tokens where lower.contains(tok) {
                    score += 4
                }
                if mode == "diagnose" || q.contains("fechar") || q.contains("close") || q.contains("x") {
                    if dismissKeywords.contains(where: { lower == $0 || lower.contains($0) }) {
                        score += 8
                    }
                }
                if score > bestScore {
                    bestScore = score
                    best = det
                }
            }

            let answer: String
            if let best {
                answer = "Apple Vision OCR matched \"\(best.label)\" at (\(Int(best.x)), \(Int(best.y)))."
            } else if hasPopupHint {
                answer = "Apple Vision OCR detected popup/notification text on screen, but no text close button. Use observe or screenshot to inspect non-text controls."
            } else {
                answer = "Apple Vision OCR scanned \(detections.count) text blocks; no exact match for \"\(query ?? "")\"."
            }

            return VisionQueryResult(
                mode: mode,
                backend: "apple-vision-ocr",
                modelId: nil,
                latencyMs: (latencyMs * 100).rounded() / 100,
                answer: answer,
                x: best?.x,
                y: best?.y,
                frame: best?.frame,
                blockingDetected: hasPopupHint,
                detections: Array(detections.prefix(30)),
                imagePath: imagePath
            )
        }.value
    }
}
