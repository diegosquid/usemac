import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UseMacProtocol
import Vision

public final class LocalVisionEngine: @unchecked Sendable {
    private enum DefaultsKeys {
        static let enabled = "usemac.vision.enabled"
        static let modelId = "usemac.vision.modelId"
    }

    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "app.usemac.vision-worker-io", qos: .userInitiated)

    private var _enabled: Bool
    private var _modelId: String
    private var _installing: Bool = false
    private var _installProgress: String?
    private var _lastError: String?

    private var workerProcess: Process?
    private var workerStdin: FileHandle?
    private var workerStdout: FileHandle?
    private var workerReadBuffer = Data()
    private var workerLoadedModel: String?
    private var idleUnloadWorkItem: DispatchWorkItem?

    public var onStatusChanged: (@Sendable (VisionStatus) -> Void)?

    public init() {
        let savedModel = UserDefaults.standard.string(forKey: DefaultsKeys.modelId)
        if let savedModel, !savedModel.isEmpty {
            self._modelId = savedModel
        } else if Self.isModelCached(LocalVisionModelPreset.qwen35_08B.rawValue) {
            self._modelId = LocalVisionModelPreset.qwen35_08B.rawValue
        } else {
            self._modelId = LocalVisionModelPreset.qwen25VL3B.rawValue
        }
        let runtimeReady = Self.isRuntimeInstalled()
        let modelReady = Self.isModelCached(self._modelId)
        if UserDefaults.standard.object(forKey: DefaultsKeys.enabled) != nil {
            self._enabled = UserDefaults.standard.bool(forKey: DefaultsKeys.enabled)
        } else {
            self._enabled = runtimeReady && modelReady
        }
    }

    deinit {
        stopWorker()
    }

    // MARK: - Paths & Discovery

    private static var applicationSupportBaseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

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

    private static let performLegacyVisionMigrationOnce: Void = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let base = applicationSupportBaseDir
        let legacy = base
            .appendingPathComponent("MacUse", isDirectory: true) // Legacy folder name, kept for one-time migration.
            .appendingPathComponent("vision-venv", isDirectory: true)
        let current = base
            .appendingPathComponent(UseMacDefaults.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("vision-venv", isDirectory: true)
        _ = migrateLegacyDirectory(from: legacy, to: current)
    }()

    public static var appSupportDir: URL {
        _ = performLegacyVisionMigrationOnce
        return applicationSupportBaseDir.appendingPathComponent(UseMacDefaults.applicationSupportFolderName, isDirectory: true)
    }

    public static var venvDir: URL {
        appSupportDir.appendingPathComponent("vision-venv", isDirectory: true)
    }

    public static var venvPythonURL: URL {
        venvDir.appendingPathComponent("bin/python")
    }

    public static func isRuntimeInstalled() -> Bool {
        let py = venvPythonURL.path
        guard FileManager.default.isExecutableFile(atPath: py) else { return false }
        let sitePackages = venvDir.appendingPathComponent("lib").path
        guard let enumerator = FileManager.default.enumerator(atPath: sitePackages) else { return false }
        while let item = enumerator.nextObject() as? String {
            if item.hasSuffix("mlx_vlm") || item.contains("mlx_vlm/") {
                return true
            }
        }
        return false
    }

    public static func isModelCached(_ modelId: String) -> Bool {
        let sanitized = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let hfCache = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub/\(sanitized)/snapshots", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hfCache.path),
              let first = entries.first else {
            return false
        }
        let snapshotDir = hfCache.appendingPathComponent(first, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: snapshotDir.path) else {
            return false
        }
        return files.contains(where: { $0.hasSuffix(".safetensors") })
    }

    public static func resolveWorkerScriptPath() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("vision/worker.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        if let execURL = Bundle.main.executableURL {
            let bundledFallback = execURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/vision/worker.py")
            if FileManager.default.fileExists(atPath: bundledFallback.path) {
                return bundledFallback.path
            }
        }
        return nil
    }

    /// True when the `uv` installer the optional MLX runtime needs is present on this Mac.
    public static var isInstallerAvailable: Bool {
        resolveUVPath() != nil
    }

    private static func resolveUVPath() -> String? {
        let candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/uv"),
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "/usr/bin/uv"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // MARK: - Status & Configuration

    public func currentStatus() -> VisionStatus {
        lock.lock()
        let enabled = _enabled
        let modelId = _modelId
        let installing = _installing
        let progress = _installProgress
        let lastError = _lastError
        let running = workerProcess?.isRunning == true
        lock.unlock()

        let runtimeInstalled = Self.isRuntimeInstalled()
        let modelDownloaded = Self.isModelCached(modelId)

        let state: String
        if installing {
            state = "installing"
        } else if !runtimeInstalled || !modelDownloaded {
            state = "not_installed"
        } else if !enabled {
            state = "disabled"
        } else {
            state = "ready"
        }

        let backend = (enabled && runtimeInstalled && modelDownloaded) ? "mlx-vlm" : "apple-vision-ocr"
        return VisionStatus(
            enabled: enabled,
            state: state,
            modelId: modelId,
            backend: backend,
            ocrAvailable: true,
            runtimeInstalled: runtimeInstalled,
            modelDownloaded: modelDownloaded,
            workerRunning: running,
            installProgress: progress,
            lastError: lastError
        )
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        _enabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.enabled)
        lock.unlock()
        if !enabled {
            stopWorker()
        }
        notifyStatusChanged()
    }

    public func setModelId(_ modelId: String) {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        let changed = _modelId != trimmed
        _modelId = trimmed
        UserDefaults.standard.set(trimmed, forKey: DefaultsKeys.modelId)
        if Self.isRuntimeInstalled() && Self.isModelCached(trimmed) {
            _enabled = true
            UserDefaults.standard.set(true, forKey: DefaultsKeys.enabled)
        }
        lock.unlock()
        if changed {
            stopWorker()
        }
        notifyStatusChanged()
    }

    private func notifyStatusChanged() {
        let status = currentStatus()
        onStatusChanged?(status)
    }

    // MARK: - Phase 1: Native Swift Frame-Diff (< 2 ms, 0 MB)

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

    // MARK: - Phase 1: Native Apple Vision OCR (Neural Engine, ~25 ms, 0 MB)

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

    // MARK: - Phase 2: One-Click Install (MLX-VLM + Model Weights)

    public func install(modelId requestedModel: String? = nil, enable: Bool = true) async -> VisionStatus {
        let targetModel = (requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? requestedModel!.trimmingCharacters(in: .whitespacesAndNewlines)
            : currentStatus().modelId

        let alreadyInstalling = lock.withLock { () -> Bool in
            if _installing { return true }
            _installing = true
            _modelId = targetModel
            UserDefaults.standard.set(targetModel, forKey: DefaultsKeys.modelId)
            _lastError = nil
            _installProgress = "Checking Apple Silicon MLX runtime…"
            return false
        }
        if alreadyInstalling {
            return currentStatus()
        }
        notifyStatusChanged()

        defer {
            lock.withLock {
                _installing = false
                _installProgress = nil
            }
            notifyStatusChanged()
        }

        do {
            try FileManager.default.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)

            if !Self.isRuntimeInstalled() {
                guard let uvPath = Self.resolveUVPath() else {
                    throw NSError(
                        domain: "UseMacVision",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "uv not found (~/.local/bin/uv or /opt/homebrew/bin/uv). Install uv first."]
                    )
                }

                updateProgress("Creating isolated MLX Python 3.12 runtime…")
                if !FileManager.default.isExecutableFile(atPath: Self.venvPythonURL.path) {
                    try await runShell(
                        executable: uvPath,
                        arguments: ["venv", "--python", "3.12", Self.venvDir.path]
                    )
                }

                updateProgress("Installing Apple Silicon mlx-vlm packages…")
                try await runShell(
                    executable: uvPath,
                    arguments: ["pip", "install", "--python", Self.venvPythonURL.path, "mlx-vlm>=0.1.24", "pillow", "huggingface_hub"]
                )
            }

            if !Self.isModelCached(targetModel) {
                updateProgress("Downloading \(targetModel)…")
                let script = "from huggingface_hub import snapshot_download; print(snapshot_download(\(Self.pythonStringLiteral(targetModel))))"
                try await runShell(
                    executable: Self.venvPythonURL.path,
                    arguments: ["-c", script]
                )
            }

            lock.withLock {
                if enable {
                    _enabled = true
                    UserDefaults.standard.set(true, forKey: DefaultsKeys.enabled)
                }
                _lastError = nil
            }
        } catch {
            lock.withLock {
                _lastError = error.localizedDescription
            }
        }

        return currentStatus()
    }

    private func updateProgress(_ text: String) {
        lock.lock()
        _installProgress = text
        lock.unlock()
        notifyStatusChanged()
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func runShell(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let errPipe = Pipe()
                proc.standardOutput = Pipe()
                proc.standardError = errPipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let tail = errStr.split(separator: "\n").suffix(4).joined(separator: " | ")
                        cont.resume(throwing: NSError(
                            domain: "UseMacVision",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: tail.isEmpty ? "Command failed with exit \(proc.terminationStatus)" : tail]
                        ))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Unified Vision Query (MLX-VLM + Apple Vision OCR Hybrid)

    private static func extractCompactOCRContext(
        imagePath: String,
        viewportWidth: Double,
        viewportHeight: Double,
        maxChars: Int = 1800
    ) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
                  let cgImage = Self.decodeCGImage(fromJPEG: data) else {
                return ""
            }
            let detections = Self.recognizeText(in: cgImage, viewportWidth: viewportWidth, viewportHeight: viewportHeight, fast: true)
            guard !detections.isEmpty else { return "" }
            // Sort top-to-bottom (row buckets of ~14px), then left-to-right for natural reading order
            let sorted = detections.sorted { a, b in
                let rowA = Int(a.y / 14.0)
                let rowB = Int(b.y / 14.0)
                if rowA != rowB { return rowA < rowB }
                return a.x < b.x
            }
            var lines: [String] = []
            var totalChars = 0
            var currentRow = Int.min
            var rowBuffer: [String] = []

            func flushRow() {
                guard !rowBuffer.isEmpty else { return }
                let joined = rowBuffer.joined(separator: " | ")
                if totalChars + joined.count + 1 <= maxChars {
                    lines.append(joined)
                    totalChars += joined.count + 1
                }
                rowBuffer.removeAll(keepingCapacity: true)
            }

            for det in sorted {
                let row = Int(det.y / 14.0)
                if row != currentRow {
                    flushRow()
                    currentRow = row
                }
                if totalChars >= maxChars { break }
                rowBuffer.append(det.label)
            }
            flushRow()
            return lines.joined(separator: "\n")
        }.value
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

        // Direct OCR mode
        if effectiveMode == "ocr" {
            return await runOCRQuery(
                mode: "ocr",
                query: query,
                imagePath: imagePath,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                startNs: startNs
            )
        }

        // Try Local MLX VLM if enabled, installed, and cached
        let status = currentStatus()
        if status.enabled && status.runtimeInstalled && status.modelDownloaded {
            // Hybrid boost: attach ~25ms Apple Vision OCR text for exact literal fidelity on hostnames, codes, errors & numbers
            let needsOCRContext = (effectiveMode == "ask" || effectiveMode == "verify" || effectiveMode == "describe" || effectiveMode == "diagnose")
            let ocrContext = needsOCRContext
                ? await Self.extractCompactOCRContext(
                    imagePath: imagePath,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
                : ""

            if let mlxResult = await queryMLXWorker(
                modelId: status.modelId,
                mode: effectiveMode,
                query: query ?? "",
                ocrContext: ocrContext,
                imagePath: imagePath,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight
            ) {
                return mlxResult
            }
        }

        // Seamless Apple Vision OCR fallback (always works with 0 MB extra)
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
                    ? "Visible screen text (Apple Vision OCR fallback, \(detections.count) blocks): "
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

            // Smart OCR matching for locate/diagnose fallback
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
                answer = "Apple Vision OCR detected popup/notification text on screen, but no text close button. Enable Local MLX Vision for icon-level grounding (e.g. 'X' buttons)."
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

    // MARK: - Persistent MLX Worker Process

    /// Silently pre-warms the local MLX-VLM worker and loads model weights in the background
    /// (called on `task_start` so the very first visual query has zero cold-start delay).
    public func warmupIfReady() {
        // Avoid spawning a real MLX Python worker during XCTest runs
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let status = currentStatus()
        guard status.enabled && status.runtimeInstalled && status.modelDownloaded else { return }
        let targetModel = status.modelId

        workerQueue.async { [weak self] in
            guard let self else { return }
            if let proc = self.workerProcess, proc.isRunning, self.workerLoadedModel == targetModel {
                self.scheduleIdleUnload()
                return
            }
            guard self.ensureWorkerRunningLocked(),
                  let stdin = self.workerStdin,
                  let stdout = self.workerStdout else {
                return
            }
            let payload: [String: Any] = [
                "id": UUID().uuidString,
                "cmd": "load",
                "model": targetModel
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var lineData = jsonData
            lineData.append(0x0A)
            do {
                try stdin.write(contentsOf: lineData)
            } catch {
                self.stopWorker()
                return
            }
            self.scheduleIdleUnload()
            if let respLine = self.readNextLine(from: stdout),
               let respData = respLine.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               (json["ok"] as? Bool) == true {
                self.workerLoadedModel = targetModel
                self.notifyStatusChanged()
            }
        }
    }

    private func queryMLXWorker(
        modelId: String,
        mode: String,
        query: String,
        ocrContext: String,
        imagePath: String,
        viewportWidth: Double,
        viewportHeight: Double
    ) async -> VisionQueryResult? {
        await withCheckedContinuation { cont in
            workerQueue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: nil)
                    return
                }
                let result = self.performSyncMLXQuery(
                    modelId: modelId,
                    mode: mode,
                    query: query,
                    ocrContext: ocrContext,
                    imagePath: imagePath,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
                cont.resume(returning: result)
            }
        }
    }

    private func performSyncMLXQuery(
        modelId: String,
        mode: String,
        query: String,
        ocrContext: String,
        imagePath: String,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> VisionQueryResult? {
        guard ensureWorkerRunningLocked() else { return nil }
        guard let stdin = workerStdin, let stdout = workerStdout else { return nil }

        let reqId = UUID().uuidString
        var payload: [String: Any] = [
            "id": reqId,
            "cmd": "query",
            "model": modelId,
            "mode": mode,
            "query": query,
            "imagePath": imagePath,
            "viewportWidth": viewportWidth,
            "viewportHeight": viewportHeight
        ]
        if !ocrContext.isEmpty {
            payload["ocrContext"] = ocrContext
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var lineData = jsonData
        lineData.append(0x0A)
        do {
            try stdin.write(contentsOf: lineData)
        } catch {
            stopWorker()
            return nil
        }

        scheduleIdleUnload()

        guard let respLine = readNextLine(from: stdout),
              let respData = respLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            stopWorker()
            return nil
        }

        guard (json["ok"] as? Bool) == true else {
            let errMsg = json["error"] as? String ?? "MLX worker error"
            lock.lock()
            _lastError = errMsg
            lock.unlock()
            notifyStatusChanged()
            return nil
        }

        workerLoadedModel = modelId
        let xVal = json["x"] as? Double
        let yVal = json["y"] as? Double
        var frameRect: ScreenRect?
        if let f = json["frame"] as? [String: Any],
           let fx = f["x"] as? Double,
           let fy = f["y"] as? Double,
           let fw = f["width"] as? Double,
           let fh = f["height"] as? Double {
            frameRect = ScreenRect(x: fx, y: fy, width: fw, height: fh)
        }

        var detections: [VisionDetection] = []
        if let rawDets = json["detections"] as? [[String: Any]] {
            for d in rawDets {
                if let label = d["label"] as? String,
                   let dx = d["x"] as? Double,
                   let dy = d["y"] as? Double {
                    var df: ScreenRect?
                    if let f = d["frame"] as? [String: Any],
                       let fx = f["x"] as? Double,
                       let fy = f["y"] as? Double,
                       let fw = f["width"] as? Double,
                       let fh = f["height"] as? Double {
                        df = ScreenRect(x: fx, y: fy, width: fw, height: fh)
                    }
                    detections.append(VisionDetection(
                        label: label,
                        x: dx,
                        y: dy,
                        frame: df,
                        confidence: d["confidence"] as? Double ?? 0.9,
                        source: d["source"] as? String ?? "mlx-vlm"
                    ))
                }
            }
        }

        return VisionQueryResult(
            mode: json["mode"] as? String ?? mode,
            backend: "mlx-vlm",
            modelId: json["modelId"] as? String ?? modelId,
            latencyMs: json["latencyMs"] as? Double ?? 0,
            answer: json["answer"] as? String ?? "",
            verified: json["verified"] as? Bool,
            x: xVal,
            y: yVal,
            frame: frameRect,
            blockingDetected: json["blockingDetected"] as? Bool ?? false,
            detections: detections,
            imagePath: imagePath
        )
    }

    private func ensureWorkerRunningLocked() -> Bool {
        if let proc = workerProcess, proc.isRunning {
            return true
        }
        guard let scriptPath = Self.resolveWorkerScriptPath(),
              FileManager.default.isExecutableFile(atPath: Self.venvPythonURL.path) else {
            return false
        }

        let proc = Process()
        proc.executableURL = Self.venvPythonURL
        proc.arguments = ["-u", scriptPath]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            lock.lock()
            _lastError = error.localizedDescription
            lock.unlock()
            return false
        }

        workerProcess = proc
        workerStdin = inPipe.fileHandleForWriting
        workerStdout = outPipe.fileHandleForReading
        workerReadBuffer.removeAll(keepingCapacity: true)

        // Read ready banner
        if let readyLine = readNextLine(from: outPipe.fileHandleForReading),
           readyLine.contains("\"ready\"") {
            notifyStatusChanged()
            return true
        }
        stopWorker()
        return false
    }

    private func readNextLine(from handle: FileHandle) -> String? {
        while true {
            if let range = workerReadBuffer.range(of: Data([0x0A])) {
                let lineData = workerReadBuffer.subdata(in: 0..<range.lowerBound)
                workerReadBuffer.removeSubrange(0..<range.upperBound)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                return nil
            }
            workerReadBuffer.append(chunk)
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stopWorker()
        }
        idleUnloadWorkItem = item
        workerQueue.asyncAfter(deadline: .now() + 300, execute: item)
    }

    public func stopWorker() {
        idleUnloadWorkItem?.cancel()
        idleUnloadWorkItem = nil
        if let proc = workerProcess {
            if proc.isRunning {
                proc.terminate()
            }
        }
        workerProcess = nil
        workerStdin = nil
        workerStdout = nil
        workerLoadedModel = nil
        workerReadBuffer.removeAll(keepingCapacity: false)
        notifyStatusChanged()
    }
}
