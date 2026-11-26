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

/// Result of a `16x10` tile-grid visual diff between two frames.
///
/// `dirtyRect` is expressed in **top-left pixel coordinates matching `after` image dimensions**
/// (`0..<imageWidth`, `0..<imageHeight`), and `normalizedDirtyRect` holds the same bounding box
/// in normalized `0...1` top-left coordinates. Both are `nil` when no tile exceeds the threshold.
public struct DirtyRegionResult: Equatable, Sendable {
    public var overallDiffPercent: Double
    public var maxTileDiffPercent: Double
    /// Bounding box of changed `16x10` tiles in pixel coordinates matching the `after` image (`0..<imageWidth`, `0..<imageHeight`, top-left origin).
    public var dirtyRect: ScreenRect?
    /// Bounding box of changed `16x10` tiles in normalized `0...1` top-left coordinates.
    public var normalizedDirtyRect: ScreenRect?
    public var imageWidth: Int
    public var imageHeight: Int
    public var changedTileCount: Int

    public init(
        overallDiffPercent: Double,
        maxTileDiffPercent: Double,
        dirtyRect: ScreenRect?,
        normalizedDirtyRect: ScreenRect? = nil,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        changedTileCount: Int = 0
    ) {
        self.overallDiffPercent = overallDiffPercent
        self.maxTileDiffPercent = maxTileDiffPercent
        self.dirtyRect = dirtyRect
        self.normalizedDirtyRect = normalizedDirtyRect
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.changedTileCount = changedTileCount
    }
}

/// On-device Apple Vision OCR and native Swift frame-diff engine (Neural Engine, zero Python/MLX sidecar).
public final class LocalVisionEngine: @unchecked Sendable {
    /// Every refusal for a too-small image starts with this, so callers can map it to an error code.
    public static let captureTooSmallPrefix = "CAPTURE_TOO_SMALL:"
    /// Shorter side, in pixels, below which an image is refused.
    public static let minimumImageSide = 64

    /// Tile grid dimensions used by `computeDirtyRegion` (4x4 grayscale samples per tile -> 64x40 total).
    public static let dirtyGridColumns = 16
    public static let dirtyGridRows = 10
    private static let tileSampleSize = 4

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

    // MARK: - Native Swift Tile Dirty-Region Diff (< 1.5 ms, 0 MB)

    /// Computes a `16x10` tile-grid visual diff between two JPEG frames (`< 1.5 ms`).
    ///
    /// Returns `overallDiffPercent`, `maxTileDiffPercent`, and `dirtyRect` in pixel coordinates
    /// matching the `afterJPEG` image dimensions (top-left origin), or `nil` when no tile exceeds
    /// `tileThresholdPercent`.
    public static func computeDirtyRegion(
        beforeJPEG: Data,
        afterJPEG: Data,
        tileThresholdPercent: Double = 0.8
    ) -> DirtyRegionResult {
        guard let imgA = decodeCGImage(fromJPEG: beforeJPEG),
              let imgB = decodeCGImage(fromJPEG: afterJPEG) else {
            return DirtyRegionResult(
                overallDiffPercent: 100.0,
                maxTileDiffPercent: 100.0,
                dirtyRect: nil,
                normalizedDirtyRect: nil,
                imageWidth: 0,
                imageHeight: 0,
                changedTileCount: 0
            )
        }
        return computeDirtyRegion(before: imgA, after: imgB, tileThresholdPercent: tileThresholdPercent)
    }

    /// Computes a `16x10` tile-grid visual diff between two `CGImage` frames (`< 1.5 ms`).
    ///
    /// `dirtyRect` uses top-left pixel coordinates matching `after.width` x `after.height`.
    public static func computeDirtyRegion(
        before: CGImage,
        after: CGImage,
        tileThresholdPercent: Double = 0.8
    ) -> DirtyRegionResult {
        let cols = dirtyGridColumns
        let rows = dirtyGridRows
        let cell = tileSampleSize
        let w = cols * cell // 64
        let h = rows * cell // 40
        let totalSamples = w * h
        let afterW = max(1, after.width)
        let afterH = max(1, after.height)

        guard let bufA = downsampleGrayscale(before, width: w, height: h),
              let bufB = downsampleGrayscale(after, width: w, height: h) else {
            return DirtyRegionResult(
                overallDiffPercent: 100.0,
                maxTileDiffPercent: 100.0,
                dirtyRect: ScreenRect(x: 0, y: 0, width: Double(afterW), height: Double(afterH)),
                normalizedDirtyRect: ScreenRect(x: 0, y: 0, width: 1.0, height: 1.0),
                imageWidth: afterW,
                imageHeight: afterH,
                changedTileCount: cols * rows
            )
        }

        let samplesPerTile = cell * cell
        let tileDenom = Double(samplesPerTile * 255)
        var totalDiff = 0
        var maxTilePct = 0.0
        var minCol = cols
        var maxCol = -1
        var minRow = rows
        var maxRow = -1
        var changedTiles = 0

        for row in 0..<rows {
            let baseY = row * cell
            for col in 0..<cols {
                let baseX = col * cell
                var tileDiff = 0
                for dy in 0..<cell {
                    let rowOffset = (baseY + dy) * w + baseX
                    for dx in 0..<cell {
                        let idx = rowOffset + dx
                        tileDiff += abs(Int(bufA[idx]) - Int(bufB[idx]))
                    }
                }
                totalDiff += tileDiff
                let tilePct = (Double(tileDiff) / tileDenom) * 100.0
                if tilePct > maxTilePct {
                    maxTilePct = tilePct
                }
                if tilePct >= tileThresholdPercent {
                    changedTiles += 1
                    if col < minCol { minCol = col }
                    if col > maxCol { maxCol = col }
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                }
            }
        }

        let overallPct = ((Double(totalDiff) / Double(totalSamples * 255)) * 100.0 * 100.0).rounded() / 100.0
        let roundedMaxTile = (maxTilePct * 100.0).rounded() / 100.0

        let dirtyRect: ScreenRect?
        let normalizedDirtyRect: ScreenRect?
        if changedTiles > 0, minCol <= maxCol, minRow <= maxRow {
            let normX0 = Double(minCol) / Double(cols)
            let normY0 = Double(minRow) / Double(rows)
            let normX1 = Double(maxCol + 1) / Double(cols)
            let normY1 = Double(maxRow + 1) / Double(rows)
            normalizedDirtyRect = ScreenRect(
                x: (normX0 * 10000).rounded() / 10000,
                y: (normY0 * 10000).rounded() / 10000,
                width: ((normX1 - normX0) * 10000).rounded() / 10000,
                height: ((normY1 - normY0) * 10000).rounded() / 10000
            )
            let pxX0 = max(0.0, floor(normX0 * Double(afterW)))
            let pxY0 = max(0.0, floor(normY0 * Double(afterH)))
            let pxX1 = min(Double(afterW), ceil(normX1 * Double(afterW)))
            let pxY1 = min(Double(afterH), ceil(normY1 * Double(afterH)))
            dirtyRect = ScreenRect(
                x: pxX0,
                y: pxY0,
                width: max(1.0, pxX1 - pxX0),
                height: max(1.0, pxY1 - pxY0)
            )
        } else {
            dirtyRect = nil
            normalizedDirtyRect = nil
        }

        return DirtyRegionResult(
            overallDiffPercent: overallPct,
            maxTileDiffPercent: roundedMaxTile,
            dirtyRect: dirtyRect,
            normalizedDirtyRect: normalizedDirtyRect,
            imageWidth: afterW,
            imageHeight: afterH,
            changedTileCount: changedTiles
        )
    }

    public static func computeFrameDiffPercent(beforeJPEG: Data, afterJPEG: Data) -> Double? {
        guard let imgA = decodeCGImage(fromJPEG: beforeJPEG),
              let imgB = decodeCGImage(fromJPEG: afterJPEG) else {
            return nil
        }
        return computeDirtyRegion(before: imgA, after: imgB).overallDiffPercent
    }

    public static func computeFrameDiffPercent(before: CGImage, after: CGImage) -> Double {
        computeDirtyRegion(before: before, after: after).overallDiffPercent
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

    // MARK: - JPEG Decode / Crop / Encode

    public static func decodeCGImage(fromJPEG data: Data) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func encodeJPEG(_ image: CGImage, quality: Double = 0.80) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let clampedQuality = min(max(quality, 0.1), 1.0)
        let opts = [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
        CGImageDestinationAddImage(dest, image, opts)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Crops `image` to `rect` (top-left pixel coordinates) expanded by `padding` on all sides,
    /// clamping to image bounds and downscaling if either side exceeds `maxDimension`.
    public static func cropCGImage(
        from image: CGImage,
        rect: ScreenRect,
        padding: Double = 24,
        maxDimension: Int = 1024
    ) -> CGImage? {
        let imgW = image.width
        let imgH = image.height
        guard imgW > 0, imgH > 0, rect.width > 0, rect.height > 0 else { return nil }

        let pad = max(0.0, padding)
        let x0 = max(0, min(imgW - 1, Int(floor(rect.x - pad))))
        let y0 = max(0, min(imgH - 1, Int(floor(rect.y - pad))))
        let x1 = max(x0 + 1, min(imgW, Int(ceil(rect.x + rect.width + pad))))
        let y1 = max(y0 + 1, min(imgH, Int(ceil(rect.y + rect.height + pad))))
        let cropW = x1 - x0
        let cropH = y1 - y0
        guard cropW >= 1, cropH >= 1 else { return nil }

        // CGImage.cropping(to:) uses top-left pixel coordinates.
        guard let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: cropW, height: cropH)) else {
            return nil
        }

        guard maxDimension > 0, max(cropped.width, cropped.height) > maxDimension else {
            return cropped
        }

        let scale = Double(maxDimension) / Double(max(cropped.width, cropped.height))
        let targetW = max(1, Int((Double(cropped.width) * scale).rounded()))
        let targetH = max(1, Int((Double(cropped.height) * scale).rounded()))
        let colorSpace = cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return cropped
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? cropped
    }

    /// Crops a JPEG image to `rect` (top-left pixel coordinates) with optional `padding`,
    /// downscaling if larger than `maxDimension`, and re-encoding as JPEG.
    public static func cropJPEG(
        fromJPEG data: Data,
        rect: ScreenRect,
        padding: Double = 24,
        maxDimension: Int = 1024,
        quality: Double = 0.80
    ) -> Data? {
        guard let cgImage = decodeCGImage(fromJPEG: data),
              let cropped = cropCGImage(from: cgImage, rect: rect, padding: padding, maxDimension: maxDimension) else {
            return nil
        }
        return encodeJPEG(cropped, quality: quality)
    }

    // MARK: - Negation-Safe Assertion Verification

    private static let negationCueTokens: Set<String> = [
        // English
        "no", "not", "without", "absent", "gone", "missing", "never",
        "neither", "nor", "none", "disappeared", "dismissed", "hidden",
        "closed", "removed", "cannot",
        // English contraction stems after splitting apostrophes ("isn't" -> "isn")
        "isn", "aren", "wasn", "weren", "doesn", "don", "didn", "won",
        "couldn", "shouldn", "wouldn", "hasn", "haven", "hadn", "mustn", "ain",
        // Portuguese (normalized, diacritic-free)
        "nenhum", "nenhuma", "sem", "nao", "nunca", "ausente",
        "sumiu", "desapareceu", "fechado", "fechada"
    ]

    private static let assertionStopWords: Set<String> = [
        // English filler & UI chrome words
        "is", "are", "was", "were", "be", "been", "being", "the", "an", "on", "in", "at",
        "of", "to", "for", "with", "from", "by", "that", "this", "there", "it", "should",
        "must", "any", "all", "still", "anymore", "longer", "visible", "shown", "showing",
        "displayed", "displaying", "appears", "appearing", "present", "screen", "page",
        "window", "view", "ui", "banner", "toast", "modal", "dialog", "popup", "message",
        "text", "label", "button", "field", "element", "indicator", "icon", "alert", "box",
        "section", "panel", "bar", "card", "has", "have", "does", "do", "did", "can",
        // Portuguese filler & UI chrome words (normalized)
        "os", "as", "um", "uma", "uns", "umas", "de", "do", "da", "dos", "das", "em",
        "na", "nos", "nas", "por", "para", "com", "que", "esta", "este", "esse", "essa",
        "isso", "estao", "foi", "ser", "ha", "existe", "visivel", "visiveis", "aparece",
        "aparecendo", "mostrando", "exibido", "exibida", "tela", "pagina", "janela",
        "texto", "mensagem", "botao", "campo", "elemento", "alerta", "aviso",
        "notificacao", "dialogo", "barra", "cartao", "secao", "painel", "mais"
    ]

    private static func normalizeForMatching(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func tokenizePreservingTwoChar(_ normalized: String) -> [String] {
        normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func hasNegationContraction(_ normalized: String) -> Bool {
        normalized.contains("n't") || normalized.contains("n’t") || normalized.contains("cannot")
    }

    private static func extractQuotedPhrases(from raw: String) -> [String] {
        var phrases: [String] = []
        for quote: Character in ["\"", "“", "'"] {
            let closing: Character = quote == "“" ? "”" : quote
            var cursor = raw.startIndex
            while cursor < raw.endIndex, let start = raw[cursor...].firstIndex(of: quote) {
                let afterStart = raw.index(after: start)
                guard afterStart < raw.endIndex, let end = raw[afterStart...].firstIndex(of: closing) else {
                    break
                }
                let candidate = String(raw[afterStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.count >= 2 && !candidate.contains(quote) {
                    phrases.append(candidate)
                }
                cursor = raw.index(after: end)
            }
        }
        return phrases
    }

    /// Returns true when the assertion expresses absence/negation (EN or PT).
    public static func isNegatedAssertion(_ assertion: String) -> Bool {
        let folded = normalizeForMatching(assertion)
        if hasNegationContraction(folded) { return true }
        let tokens = tokenizePreservingTwoChar(folded)
        return tokens.contains(where: { negationCueTokens.contains($0) })
    }

    /// Verifies a natural-language assertion against OCR or DOM/AX text with full EN/PT negation handling.
    ///
    /// Preserves 2-character negation cues such as `"no"` and flips polarity cleanly so
    /// `"No error banner visible"` returns `verified: true` when `"error"` is absent and
    /// `verified: false` when `"error"` is present.
    public static func verifyAssertion(
        _ assertion: String,
        againstOCRText text: String
    ) -> (verified: Bool, evidence: String) {
        let trimmedAssertion = assertion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAssertion.isEmpty else {
            return (false, "Empty verification assertion.")
        }

        let foldedAssertion = normalizeForMatching(trimmedAssertion)
        let foldedText = normalizeForMatching(text)
        let textWords = Set(tokenizePreservingTwoChar(foldedText))

        let rawTokens = tokenizePreservingTwoChar(foldedAssertion)
        let negated = hasNegationContraction(foldedAssertion)
            || rawTokens.contains(where: { negationCueTokens.contains($0) })

        // Quoted phrases get exact substring priority when present (e.g. `No "404 Not Found" visible`).
        let quotedPhrases = extractQuotedPhrases(from: trimmedAssertion)
            .map(normalizeForMatching)
            .filter { !$0.isEmpty }
        if !quotedPhrases.isEmpty {
            let matchedPhrases = quotedPhrases.filter { foldedText.contains($0) }
            let anyFound = !matchedPhrases.isEmpty
            let allFound = matchedPhrases.count == quotedPhrases.count
            if negated {
                let verified = !anyFound
                let evidence = verified
                    ? "Verified absence: \"\(quotedPhrases.joined(separator: "\", \""))\" not found in visible text."
                    : "Negated assertion failed: forbidden text \"\(matchedPhrases.joined(separator: "\", \""))\" is visible."
                return (verified, evidence)
            } else {
                let verified = allFound
                let evidence = verified
                    ? "Verified presence: matched \"\(matchedPhrases.joined(separator: "\", \""))\" in visible text."
                    : "Assertion failed: expected \"\(quotedPhrases.joined(separator: "\", \""))\" not found in visible text."
                return (verified, evidence)
            }
        }

        let nonNegationTokens = rawTokens.filter { !negationCueTokens.contains($0) }
        var subjectTokens = nonNegationTokens.filter { !assertionStopWords.contains($0) }
        if subjectTokens.isEmpty {
            subjectTokens = nonNegationTokens
        }
        // Deduplicate while preserving order
        var seen: Set<String> = []
        subjectTokens = subjectTokens.filter { seen.insert($0).inserted }

        guard !subjectTokens.isEmpty else {
            return (false, "Assertion \"\(trimmedAssertion)\" contained no searchable subject terms.")
        }

        let matchedTokens = subjectTokens.filter { tok in
            if tok.count <= 3 {
                return textWords.contains(tok)
            }
            return foldedText.contains(tok)
        }
        let matchRatio = Double(matchedTokens.count) / Double(subjectTokens.count)

        if negated {
            // For multi-token forbidden subjects (e.g. "No invalid email"), require >= 60% match
            // so partial benign overlap ("Email saved") does not trigger a false failure.
            let threshold = subjectTokens.count <= 1 ? 1.0 : 0.6
            let forbiddenPresent = matchRatio >= threshold
            let verified = !forbiddenPresent
            let evidence: String
            if verified {
                evidence = "Verified absence (negated): [\(subjectTokens.joined(separator: ", "))] not present in visible text."
            } else {
                evidence = "Negated assertion failed: found forbidden term(s) [\(matchedTokens.joined(separator: ", "))] in visible text."
            }
            return (verified, evidence)
        } else {
            let verified = matchRatio >= 0.5
            let evidence: String
            if verified {
                evidence = "Verified presence: matched [\(matchedTokens.joined(separator: ", "))] in visible text."
            } else {
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = preview.count > 160 ? String(preview.prefix(160)) + "..." : preview
                evidence = clipped.isEmpty
                    ? "Assertion failed: expected [\(subjectTokens.joined(separator: ", "))], but no readable text was detected."
                    : "Assertion failed: expected [\(subjectTokens.joined(separator: ", "))] not found. Visible text: \(clipped)"
            }
            return (verified, evidence)
        }
    }

    // MARK: - Native Apple Vision OCR (Neural Engine, ~5-25 ms, 0 MB)

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

    /// Dirty-rect cropped Apple Vision OCR (~5–15 ms on Apple Neural Engine).
    ///
    /// When `region` is provided (top-left pixel coordinates matching the image), only that cropped
    /// region is OCR'd; otherwise the full image is scanned.
    public static func recognizeText(
        inJPEG data: Data,
        region: ScreenRect? = nil,
        fast: Bool = true
    ) -> (text: String, lines: [String]) {
        guard let cgImage = decodeCGImage(fromJPEG: data) else {
            return ("", [])
        }
        return recognizeText(in: cgImage, region: region, fast: fast)
    }

    /// Dirty-rect cropped Apple Vision OCR directly from an in-memory `CGImage`.
    public static func recognizeText(
        in cgImage: CGImage,
        region: ScreenRect? = nil,
        fast: Bool = true
    ) -> (text: String, lines: [String]) {
        let targetImage: CGImage
        if let region,
           let cropped = cropCGImage(from: cgImage, rect: region, padding: 16, maxDimension: 1280),
           cropped.width >= 16,
           cropped.height >= 16 {
            targetImage = cropped
        } else {
            targetImage = cgImage
        }

        let raw = recognizeText(
            in: targetImage,
            viewportWidth: Double(targetImage.width),
            viewportHeight: Double(targetImage.height),
            fast: fast
        )
        let sorted = sortInReadingOrder(raw)
        let lines = sorted.map(\.label)
        return (lines.joined(separator: " | "), lines)
    }

    /// Converts visible screen text detected by Apple Vision OCR into clickable `@v1..@vN`
    /// `ElementNode` entries anchored in global screen coordinates matching `windowBounds`.
    public static func ocrElementNodes(
        fromJPEG data: Data,
        windowBounds: ScreenRect,
        maxElements: Int = 80
    ) -> [ElementNode] {
        guard let cgImage = decodeCGImage(fromJPEG: data) else {
            return []
        }
        return ocrElementNodes(from: cgImage, windowBounds: windowBounds, maxElements: maxElements)
    }

    /// Converts visible screen text in `cgImage` into clickable `@v1..@vN` `ElementNode` entries
    /// anchored in global screen coordinates matching `windowBounds`.
    public static func ocrElementNodes(
        from cgImage: CGImage,
        windowBounds: ScreenRect,
        maxElements: Int = 80
    ) -> [ElementNode] {
        guard windowBounds.width > 0, windowBounds.height > 0, maxElements > 0 else { return [] }
        let raw = recognizeText(
            in: cgImage,
            viewportWidth: windowBounds.width,
            viewportHeight: windowBounds.height,
            fast: true
        )
        let sorted = sortInReadingOrder(raw).prefix(maxElements)
        return sorted.enumerated().map { idx, det in
            let local = det.frame ?? ScreenRect(x: det.x, y: det.y, width: 1, height: 1)
            let globalFrame = ScreenRect(
                x: ((windowBounds.x + local.x) * 10).rounded() / 10,
                y: ((windowBounds.y + local.y) * 10).rounded() / 10,
                width: max(1.0, local.width),
                height: max(1.0, local.height)
            )
            return ElementNode(
                id: "@v\(idx + 1)",
                role: "AXStaticText",
                title: det.label,
                value: nil,
                roleDescription: "ocr-text",
                enabled: true,
                focused: false,
                frame: globalFrame,
                actions: []
            )
        }
    }

    private static func sortInReadingOrder(_ detections: [VisionDetection]) -> [VisionDetection] {
        detections.sorted { a, b in
            let rowA = Int(a.y / 14.0)
            let rowB = Int(b.y / 14.0)
            if rowA != rowB { return rowA < rowB }
            return a.x < b.x
        }
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
            let detections = Self.sortInReadingOrder(rawDetections)
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

            if mode == "verify" {
                let trimmedQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let allText = detections.map(\.label).joined(separator: " | ")
                guard !trimmedQuery.isEmpty else {
                    return VisionQueryResult(
                        mode: "verify",
                        backend: "apple-vision-ocr",
                        modelId: nil,
                        latencyMs: (latencyMs * 100).rounded() / 100,
                        answer: detections.isEmpty ? "No readable text detected." : "Visible screen text: \(allText)",
                        verified: nil,
                        blockingDetected: false,
                        detections: Array(detections.prefix(20)),
                        imagePath: imagePath
                    )
                }
                let check = Self.verifyAssertion(trimmedQuery, againstOCRText: allText)
                let foldedQ = Self.normalizeForMatching(trimmedQuery)
                let tokens = Self.tokenizePreservingTwoChar(foldedQ).filter { !Self.negationCueTokens.contains($0) && !Self.assertionStopWords.contains($0) }
                let matched = detections.filter { det in
                    let lower = Self.normalizeForMatching(det.label)
                    return tokens.contains(where: { lower.contains($0) })
                }
                return VisionQueryResult(
                    mode: "verify",
                    backend: "apple-vision-ocr",
                    modelId: nil,
                    latencyMs: (latencyMs * 100).rounded() / 100,
                    answer: check.evidence,
                    verified: check.verified,
                    blockingDetected: false,
                    detections: Array((matched.isEmpty ? detections : matched).prefix(20)),
                    imagePath: imagePath
                )
            }

            if mode == "ask" {
                let q = Self.normalizeForMatching(query ?? "")
                let tokens = Self.tokenizePreservingTwoChar(q).filter { $0.count >= 3 }
                let matched = detections.filter { det in
                    let lower = Self.normalizeForMatching(det.label)
                    return tokens.contains(where: { lower.contains($0) })
                }
                let matchedPreview = matched.prefix(12).map(\.label).joined(separator: " | ")
                let allPreview = detections.prefix(20).map(\.label).joined(separator: " | ")
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

            // Smart OCR matching for locate/diagnose
            let q = Self.normalizeForMatching(query ?? "")
            let tokens = Self.tokenizePreservingTwoChar(q)
            let dismissKeywords = ["fechar", "close", "nao", "agora nao", "recusar", "rejeitar", "no thanks", "not now", "x", "×"]
            let popupKeywords = ["notificac", "cookies", "permitir", "eu quero", "newsletter", "assine"]

            let hasPopupHint = detections.contains { det in
                let lower = Self.normalizeForMatching(det.label)
                return popupKeywords.contains(where: { lower.contains($0) })
            }

            var best: VisionDetection?
            var bestScore = 0
            for det in detections {
                let lower = Self.normalizeForMatching(det.label)
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
