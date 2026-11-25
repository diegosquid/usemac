import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacUseProtocol
import ScreenCaptureKit

public final class LiveScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (
        _ ioSurface: AnyObject,
        _ width: Int,
        _ height: Int,
        _ sourceBounds: ScreenRect?,
        _ sourceName: String,
        _ isWindow: Bool
    ) -> Void

    private enum StreamTargetKey: Equatable {
        case window(CGWindowID)
        case display(CGDirectDisplayID, HUDStreamMode)
    }

    private struct ResolvedTarget {
        let key: StreamTargetKey
        let filter: SCContentFilter
        let sourceSize: CGSize
        let sourceBounds: ScreenRect?
        let sourceName: String
        let isWindow: Bool
    }

    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "com.macuse.livescreenstreamer.sample", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var _onFrame: FrameHandler?
    private var _onThumbnail: (@Sendable (_ cgImage: CGImage, _ pid: Int32, _ appName: String) -> Void)?
    private var _onStatusChange: (@Sendable (LiveStreamStatus) -> Void)?
    private var lastThumbnailNs: UInt64 = 0

    private var isActive: Bool = false
    private var generation: UInt64 = 0
    private var currentMode: HUDStreamMode = .autoWindow
    private var currentTargetApp: AppDescriptor?

    private var stream: SCStream?
    private var activeTargetKey: StreamTargetKey?
    private var activeSourceSize: CGSize = .zero
    private var currentSourceBounds: ScreenRect?
    private var currentSourceName: String = "Screen"
    private var currentIsWindow: Bool = false
    private var lastEmittedStatus: LiveStreamStatus = .idle

    private var setupTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    public var onFrame: FrameHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFrame
        }
        set {
            lock.lock()
            _onFrame = newValue
            lock.unlock()
        }
    }

    public var onThumbnail: (@Sendable (_ cgImage: CGImage, _ pid: Int32, _ appName: String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onThumbnail
        }
        set {
            lock.lock()
            _onThumbnail = newValue
            lock.unlock()
        }
    }

    public var onStatusChange: (@Sendable (LiveStreamStatus) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onStatusChange
        }
        set {
            lock.lock()
            _onStatusChange = newValue
            lock.unlock()
        }
    }

    public override init() {
        super.init()
    }

    public func start(mode: HUDStreamMode, targetApp: AppDescriptor?) {
        lock.lock()
        let wasActive = isActive
        currentMode = mode
        currentTargetApp = targetApp
        if !wasActive {
            isActive = true
            generation &+= 1
        }
        let gen = generation
        let hasStream = (stream != nil)
        lock.unlock()

        if !wasActive {
            emitStatus(CGPreflightScreenCaptureAccess() ? .connecting : .permissionRequired)
        } else if hasStream {
            // Already streaming; reconcile target if mode/app changed
        }
        scheduleReconcile(generation: gen)
    }

    public func updateTarget(mode: HUDStreamMode, targetApp: AppDescriptor?) {
        lock.lock()
        currentMode = mode
        currentTargetApp = targetApp
        guard isActive else {
            lock.unlock()
            return
        }
        let gen = generation
        lock.unlock()

        scheduleReconcile(generation: gen)
    }

    public func stop() {
        lock.lock()
        isActive = false
        generation &+= 1
        setupTask?.cancel()
        setupTask = nil
        permissionPollTask?.cancel()
        permissionPollTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        let oldStream = stream
        stream = nil
        activeTargetKey = nil
        activeSourceSize = .zero
        currentSourceBounds = nil
        currentSourceName = "Screen"
        currentIsWindow = false
        lock.unlock()

        if let oldStream {
            Task {
                try? await oldStream.stopCapture()
            }
        }
        emitStatus(.idle)
    }

    // MARK: - SCStreamOutput & SCStreamDelegate

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else {
            return
        }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
              let frameStatus = SCFrameStatus(rawValue: statusRaw),
              frameStatus == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        guard isActive, self.stream === stream else {
            lock.unlock()
            return
        }
        let handler = _onFrame
        let thumbHandler = _onThumbnail
        let bounds = currentSourceBounds
        let name = currentSourceName
        let isWindow = currentIsWindow
        let pid = currentTargetApp?.pid ?? 0
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let shouldEmitThumb = (thumbHandler != nil && pid > 0 && nowNs &- lastThumbnailNs >= 450_000_000)
        if shouldEmitThumb {
            lastThumbnailNs = nowNs
        }
        lock.unlock()

        handler?(surfaceRef as AnyObject, width, height, bounds, name, isWindow)

        if shouldEmitThumb, let thumbHandler {
            let ciImg = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImg = ciContext.createCGImage(ciImg, from: CGRect(x: 0, y: 0, width: width, height: height)) {
                thumbHandler(cgImg, pid, name)
            }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        guard isActive, self.stream === stream else {
            lock.unlock()
            return
        }
        self.stream = nil
        self.activeTargetKey = nil
        self.activeSourceSize = .zero
        let gen = self.generation
        lock.unlock()

        scheduleReconcile(generation: gen)
    }

    // MARK: - Stream Reconciliation

    private func scheduleReconcile(generation gen: UInt64) {
        lock.lock()
        guard isActive, self.generation == gen else {
            lock.unlock()
            return
        }
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            await self?.reconcile(generation: gen)
        }
        lock.unlock()
    }

    private func reconcile(generation gen: UInt64) async {
        guard isStillActive(generation: gen), !Task.isCancelled else { return }

        if !CGPreflightScreenCaptureAccess() {
            stopCurrentStreamIfNeeded(generation: gen)
            emitStatus(.permissionRequired)
            ensurePermissionPolling(generation: gen)
            return
        }

        cancelPermissionPolling()

        lock.lock()
        let mode = currentMode
        let targetApp = currentTargetApp
        let existingStream = stream
        let existingKey = activeTargetKey
        let existingSize = activeSourceSize
        lock.unlock()

        if existingStream == nil {
            emitStatus(.connecting)
        }

        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            guard isStillActive(generation: gen), !Task.isCancelled else { return }
            if !CGPreflightScreenCaptureAccess() {
                stopCurrentStreamIfNeeded(generation: gen)
                emitStatus(.permissionRequired)
                ensurePermissionPolling(generation: gen)
            } else if existingStream == nil {
                emitStatus(.idle)
            }
            return
        }

        guard isStillActive(generation: gen), !Task.isCancelled else { return }

        guard let resolved = resolveTarget(in: shareable, mode: mode, targetApp: targetApp) else {
            stopCurrentStreamIfNeeded(generation: gen)
            emitStatus(.idle)
            return
        }

        let config = makeConfiguration(for: resolved.sourceSize)

        if let existingStream {
            if existingKey == resolved.key {
                lock.lock()
                guard isActive, self.generation == gen, self.stream === existingStream else {
                    lock.unlock()
                    return
                }
                currentSourceBounds = resolved.sourceBounds
                currentSourceName = resolved.sourceName
                currentIsWindow = resolved.isWindow
                let needsResizeUpdate = existingSize != resolved.sourceSize
                if needsResizeUpdate {
                    activeSourceSize = resolved.sourceSize
                }
                lock.unlock()

                if needsResizeUpdate {
                    try? await existingStream.updateConfiguration(config)
                }
                emitStatus(.streaming(sourceName: resolved.sourceName, isWindow: resolved.isWindow))
                syncMetadataTask(mode: mode, generation: gen)
                return
            }

            // Target changed while stream is running: update filter & configuration smoothly
            lock.lock()
            guard isActive, self.generation == gen, self.stream === existingStream else {
                lock.unlock()
                return
            }
            activeTargetKey = resolved.key
            activeSourceSize = resolved.sourceSize
            currentSourceBounds = resolved.sourceBounds
            currentSourceName = resolved.sourceName
            currentIsWindow = resolved.isWindow
            lock.unlock()

            do {
                try await existingStream.updateContentFilter(resolved.filter)
                try await existingStream.updateConfiguration(config)
                guard isStillActive(generation: gen), !Task.isCancelled else { return }
                emitStatus(.streaming(sourceName: resolved.sourceName, isWindow: resolved.isWindow))
                syncMetadataTask(mode: mode, generation: gen)
                return
            } catch {
                // Fall back to recreating the stream if updateContentFilter fails
                lock.lock()
                if self.stream === existingStream {
                    self.stream = nil
                    self.activeTargetKey = nil
                    self.activeSourceSize = .zero
                }
                lock.unlock()
                try? await existingStream.stopCapture()
                guard isStillActive(generation: gen), !Task.isCancelled else { return }
            }
        }

        await startNewStream(resolved: resolved, config: config, mode: mode, generation: gen)
    }

    private func startNewStream(
        resolved: ResolvedTarget,
        config: SCStreamConfiguration,
        mode: HUDStreamMode,
        generation gen: UInt64
    ) async {
        let newStream = SCStream(filter: resolved.filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
        } catch {
            try? await newStream.stopCapture()
            guard isStillActive(generation: gen), !Task.isCancelled else { return }
            if !CGPreflightScreenCaptureAccess() {
                emitStatus(.permissionRequired)
                ensurePermissionPolling(generation: gen)
            } else {
                emitStatus(.idle)
            }
            return
        }

        guard isStillActive(generation: gen), !Task.isCancelled else {
            try? await newStream.stopCapture()
            return
        }

        lock.lock()
        guard isActive, self.generation == gen else {
            lock.unlock()
            try? await newStream.stopCapture()
            return
        }
        let supersededStream = self.stream
        self.stream = newStream
        self.activeTargetKey = resolved.key
        self.activeSourceSize = resolved.sourceSize
        self.currentSourceBounds = resolved.sourceBounds
        self.currentSourceName = resolved.sourceName
        self.currentIsWindow = resolved.isWindow
        lock.unlock()

        if let supersededStream, supersededStream !== newStream {
            try? await supersededStream.stopCapture()
        }

        emitStatus(.streaming(sourceName: resolved.sourceName, isWindow: resolved.isWindow))
        syncMetadataTask(mode: mode, generation: gen)
    }

    private func resolveTarget(
        in shareable: SCShareableContent,
        mode: HUDStreamMode,
        targetApp: AppDescriptor?
    ) -> ResolvedTarget? {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let excludedApps = shareable.applications.filter { $0.processID == selfPid }

        if mode == .autoWindow {
            guard let targetApp,
                  targetApp.pid != selfPid,
                  let win = selectWindow(for: targetApp, in: shareable.windows) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let bounds = ScreenRect(
                x: Double(win.frame.origin.x),
                y: Double(win.frame.origin.y),
                width: Double(win.frame.size.width),
                height: Double(win.frame.size.height)
            )
            return ResolvedTarget(
                key: .window(win.windowID),
                filter: filter,
                sourceSize: win.frame.size,
                sourceBounds: bounds,
                sourceName: targetApp.name,
                isWindow: true
            )
        }

        guard let display = shareable.displays.first else {
            return nil
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        let bounds = ScreenRect(
            x: Double(display.frame.origin.x),
            y: Double(display.frame.origin.y),
            width: Double(display.width),
            height: Double(display.height)
        )
        return ResolvedTarget(
            key: .display(display.displayID, mode),
            filter: filter,
            sourceSize: CGSize(width: display.width, height: display.height),
            sourceBounds: bounds,
            sourceName: "Screen",
            isWindow: false
        )
    }

    private func selectWindow(for app: AppDescriptor, in windows: [SCWindow]) -> SCWindow? {
        let matching = windows.filter {
            $0.owningApplication?.processID == app.pid
                && $0.frame.width > 20
                && $0.frame.height > 20
        }
        if let wantTitle = app.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !wantTitle.isEmpty {
            if let exact = matching.first(where: { $0.title == wantTitle }) {
                return exact
            }
            if let partial = matching.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(wantTitle) }) {
                return partial
            }
        }
        if let onScreenTitled = matching.first(where: { $0.isOnScreen && !($0.title?.isEmpty ?? true) }) {
            return onScreenTitled
        }
        if let onScreen = matching.first(where: { $0.isOnScreen }) {
            return onScreen
        }
        return matching.first
    }

    private func makeConfiguration(for sourceSize: CGSize) -> SCStreamConfiguration {
        let maxDim = 960.0
        let srcW = max(2.0, Double(sourceSize.width))
        let srcH = max(2.0, Double(sourceSize.height))
        let scale = min(1.0, maxDim / max(srcW, srcH))

        let width = max(2, Int((srcW * scale).rounded()) & ~1)
        let height = max(2, Int((srcH * scale).rounded()) & ~1)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        return config
    }

    private func ensurePermissionPolling(generation gen: UInt64) {
        lock.lock()
        guard isActive, self.generation == gen else {
            lock.unlock()
            return
        }
        if permissionPollTask != nil {
            lock.unlock()
            return
        }
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.isStillActive(generation: gen) else { return }
                if CGPreflightScreenCaptureAccess() {
                    self.cancelPermissionPolling()
                    self.scheduleReconcile(generation: gen)
                    return
                }
            }
        }
        lock.unlock()
    }

    private func cancelPermissionPolling() {
        lock.lock()
        permissionPollTask?.cancel()
        permissionPollTask = nil
        lock.unlock()
    }

    private func syncMetadataTask(mode: HUDStreamMode, generation gen: UInt64) {
        lock.lock()
        guard isActive, self.generation == gen else {
            lock.unlock()
            return
        }
        if mode != .autoWindow {
            metadataTask?.cancel()
            metadataTask = nil
            lock.unlock()
            return
        }
        if metadataTask != nil {
            lock.unlock()
            return
        }
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.isStillActive(generation: gen) else { return }
                await self.refreshAutoWindowMetadata(generation: gen)
            }
        }
        lock.unlock()
    }

    private func refreshAutoWindowMetadata(generation gen: UInt64) async {
        lock.lock()
        let shouldCheck = isActive && self.generation == gen && currentMode == .autoWindow && stream != nil
        let targetApp = currentTargetApp
        let existingKey = activeTargetKey
        let existingSize = activeSourceSize
        lock.unlock()

        guard shouldCheck else { return }
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return
        }
        guard isStillActive(generation: gen), !Task.isCancelled else { return }
        guard let resolved = resolveTarget(in: shareable, mode: .autoWindow, targetApp: targetApp) else {
            return
        }

        if resolved.key == existingKey && resolved.sourceSize == existingSize {
            lock.lock()
            if isActive, self.generation == gen {
                currentSourceBounds = resolved.sourceBounds
                currentSourceName = resolved.sourceName
                currentIsWindow = resolved.isWindow
            }
            lock.unlock()
        } else {
            scheduleReconcile(generation: gen)
        }
    }

    private func stopCurrentStreamIfNeeded(generation gen: UInt64) {
        lock.lock()
        guard self.generation == gen, let oldStream = stream else {
            lock.unlock()
            return
        }
        stream = nil
        activeTargetKey = nil
        activeSourceSize = .zero
        metadataTask?.cancel()
        metadataTask = nil
        lock.unlock()

        Task {
            try? await oldStream.stopCapture()
        }
    }

    private func isStillActive(generation gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive && generation == gen
    }

    private func emitStatus(_ status: LiveStreamStatus) {
        lock.lock()
        if lastEmittedStatus == status {
            lock.unlock()
            return
        }
        lastEmittedStatus = status
        let handler = _onStatusChange
        lock.unlock()

        handler?(status)
    }
}
