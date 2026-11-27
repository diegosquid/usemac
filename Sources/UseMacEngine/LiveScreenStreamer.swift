import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UseMacProtocol
import ScreenCaptureKit

public final class LiveScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (
        _ ioSurface: AnyObject,
        _ width: Int,
        _ height: Int,
        _ sourceBounds: ScreenRect?,
        _ sourceName: String,
        _ isWindow: Bool,
        _ windowId: UInt32?,
        _ pid: Int32?
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
        let windowId: CGWindowID?
        let pid: pid_t?
    }

    private enum Resolution {
        case target(ResolvedTarget)
        /// A target app is set but none of its windows can be shown right now (closed, not open yet, or only
        /// helper windows). The last frame stays in the preview; the whole display is never shown instead.
        case waitingForWindow
        case none
    }

    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "app.usemac.livescreenstreamer.sample", qos: .userInteractive)
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
    private var currentWindowID: CGWindowID?
    /// Window the preview stays on for `pinnedPid` until the app's target window really changes.
    private var pinnedWindowID: CGWindowID?
    private var pinnedPid: pid_t?
    /// App whose window the last frames came from (nil for a display stream).
    private var lastStreamedPid: pid_t?
    /// Set while a reconcile runs, so the metadata loop does not cancel a stream that is still starting.
    private var reconcileToken: UInt64 = 0
    private var runningReconcileToken: UInt64?
    private var lastEmittedStatus: LiveStreamStatus = .idle

    private struct CachedWindowFrame {
        let windowId: CGWindowID
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bgraData: Data?
        let prebuiltImage: CGImage?
        let sourceBounds: ScreenRect?
    }

    private var setupTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var latestWindowFrame: CachedWindowFrame?

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

    /// CGWindowID of the window being streamed (nil for a display stream or when nothing streams).
    public var streamedWindowID: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return currentIsWindow ? currentWindowID : nil
    }

    /// Returns the latest live-streamed `CGImage` for `windowID` without issuing an `SCShareableContent` XPC,
    /// or `nil` if the stream is not currently capturing that window or no frame has arrived yet.
    public func latestFrame(forWindowID windowID: CGWindowID) -> CGImage? {
        latestFrameWithBounds(forWindowID: windowID)?.image
    }

    internal func latestFrameWithBounds(forWindowID windowID: CGWindowID) -> (image: CGImage, windowBounds: ScreenRect?)? {
        lock.lock()
        let cached = latestWindowFrame
        let activeMatches = (isActive && currentIsWindow && currentWindowID == windowID)
            || (cached?.prebuiltImage != nil && cached?.windowId == windowID)
        lock.unlock()

        guard activeMatches, let cached, cached.windowId == windowID else {
            return nil
        }
        if let prebuilt = cached.prebuiltImage {
            return (prebuilt, cached.sourceBounds)
        }
        guard let bgra = cached.bgraData,
              let provider = CGDataProvider(data: bgra as CFData),
              let image = CGImage(
                  width: cached.width,
                  height: cached.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: cached.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return (image, cached.sourceBounds)
    }

    internal func storeCachedFrameForTesting(windowID: CGWindowID, image: CGImage, bounds: ScreenRect? = nil) {
        lock.lock()
        isActive = true
        currentIsWindow = true
        currentWindowID = windowID
        currentSourceBounds = bounds
        latestWindowFrame = CachedWindowFrame(
            windowId: windowID,
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow,
            bgraData: nil,
            prebuiltImage: image,
            sourceBounds: bounds
        )
        lock.unlock()
    }

    public override init() {
        super.init()
        // New rules apply to a running stream right away: a display stream is rebuilt with the new exclusions
        // and a window stream of an app that is now blocked stops.
        rulesObserver = NotificationCenter.default.addObserver(
            forName: TargetRulesStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterRulesChange()
        }
    }

    deinit {
        if let rulesObserver {
            NotificationCenter.default.removeObserver(rulesObserver)
        }
    }

    private var rulesObserver: NSObjectProtocol?

    private func restartAfterRulesChange() {
        lock.lock()
        let active = isActive
        let mode = currentMode
        let target = currentTargetApp
        lock.unlock()
        guard active else { return }
        stop()
        start(mode: mode, targetApp: target)
    }

    public func start(mode: HUDStreamMode, targetApp: AppDescriptor?) {
        lock.lock()
        let wasActive = isActive
        if mode != currentMode || targetApp?.pid != pinnedPid {
            clearPinLocked()
        }
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
        let identityChanged = mode != currentMode
            || targetApp?.pid != currentTargetApp?.pid
            || targetApp?.windowId != currentTargetApp?.windowId
        if mode != currentMode || targetApp?.pid != currentTargetApp?.pid {
            clearPinLocked()
        }
        currentMode = mode
        currentTargetApp = targetApp
        guard isActive else {
            lock.unlock()
            return
        }
        let gen = generation
        lock.unlock()

        // Window titles and bounds change with every tab and step. Only a new app, window id or mode needs a
        // new window choice; the metadata loop follows focus changes inside the app and retries while waiting.
        guard identityChanged else { return }
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
        currentWindowID = nil
        lastStreamedPid = nil
        runningReconcileToken = nil
        latestWindowFrame = nil
        clearPinLocked()
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
        let windowId = currentIsWindow ? currentWindowID.map { UInt32($0) } : nil
        let pid = currentTargetApp?.pid ?? 0
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let shouldEmitThumb = (thumbHandler != nil && pid > 0 && nowNs &- lastThumbnailNs >= 450_000_000)
        if shouldEmitThumb {
            lastThumbnailNs = nowNs
        }
        let cacheWindowId = isWindow ? currentWindowID : nil
        lock.unlock()

        // Snapshot BGRA bytes cheaply (~0.05 ms memcpy) so FastScreenCapturer can reuse the latest frame
        // without retaining CVPixelBuffer from ScreenCaptureKit's buffer pool.
        if let cacheWindowId,
           CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
           CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess {
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let byteCount = bytesPerRow * height
                if byteCount > 0 {
                    let copied = Data(bytes: baseAddress, count: byteCount)
                    lock.lock()
                    if isActive && currentIsWindow && currentWindowID == cacheWindowId {
                        latestWindowFrame = CachedWindowFrame(
                            windowId: cacheWindowId,
                            width: width,
                            height: height,
                            bytesPerRow: bytesPerRow,
                            bgraData: copied,
                            prebuiltImage: nil,
                            sourceBounds: bounds
                        )
                    }
                    lock.unlock()
                }
            }
        }

        handler?(surfaceRef as AnyObject, width, height, bounds, name, isWindow, windowId, pid > 0 ? pid : nil)

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
        self.latestWindowFrame = nil
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
        reconcileToken &+= 1
        let token = reconcileToken
        runningReconcileToken = token
        setupTask = Task { [weak self] in
            await self?.reconcile(generation: gen)
            self?.finishReconcile(token: token)
        }
        lock.unlock()
    }

    private func finishReconcile(token: UInt64) {
        lock.lock()
        if runningReconcileToken == token {
            runningReconcileToken = nil
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
        let pinned = pinnedPid == targetApp?.pid ? pinnedWindowID : nil
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
                if mode == .autoWindow, targetApp != nil {
                    emitStatus(.connecting)
                    syncMetadataTask(mode: mode, generation: gen)
                } else {
                    emitStatus(.idle)
                }
            }
            return
        }

        guard isStillActive(generation: gen), !Task.isCancelled else { return }

        let resolved: ResolvedTarget
        switch resolveTarget(in: shareable, mode: mode, targetApp: targetApp, pinnedWindowId: pinned) {
        case .target(let target):
            resolved = target
        case .waitingForWindow:
            stopCurrentStreamIfNeeded(generation: gen, keepMetadataLoop: true)
            lock.lock()
            let lastFrameIsTargetApp = lastStreamedPid != nil && lastStreamedPid == targetApp?.pid
            lock.unlock()
            // Same app: keep its last frame on screen while its window comes back. Another app: clear the
            // preview rather than show the previous app's window under the new name. Either way, keep
            // retrying from the metadata loop.
            emitStatus(lastFrameIsTargetApp ? .connecting : .idle)
            syncMetadataTask(mode: mode, generation: gen)
            return
        case .none:
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
                applySourceLocked(resolved)
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
            applySourceLocked(resolved)
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
            } else if resolved.isWindow {
                // Keep the last frame and retry from the metadata loop instead of clearing the preview.
                emitStatus(.connecting)
                syncMetadataTask(mode: mode, generation: gen)
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
        applySourceLocked(resolved)
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
        targetApp: AppDescriptor?,
        pinnedWindowId: CGWindowID?
    ) -> Resolution {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        // Apps the user's rules block are never streamed: no window of theirs, and not in a display stream.
        let rules = TargetRulesStore.shared.rules
        let excludedApps = shareable.applications.filter {
            $0.processID == selfPid || rules.blocksApp(bundleId: $0.bundleIdentifier)
        }

        if mode == .autoWindow {
            guard let targetApp, targetApp.pid != selfPid, !TargetRulesStore.shared.blocksProcess(pid: targetApp.pid) else {
                return .none
            }
            guard let win = Self.selectWindow(for: targetApp, in: shareable.windows, pinnedWindowId: pinnedWindowId) else {
                return Self.isRunning(pid: targetApp.pid) ? .waitingForWindow : .none
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let bounds = ScreenRect(
                x: Double(win.frame.origin.x),
                y: Double(win.frame.origin.y),
                width: Double(win.frame.size.width),
                height: Double(win.frame.size.height)
            )
            return .target(ResolvedTarget(
                key: .window(win.windowID),
                filter: filter,
                sourceSize: win.frame.size,
                sourceBounds: bounds,
                sourceName: targetApp.name,
                isWindow: true,
                windowId: win.windowID,
                pid: targetApp.pid
            ))
        }

        guard let display = shareable.displays.first else {
            return .none
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
        return .target(ResolvedTarget(
            key: .display(display.displayID, mode),
            filter: filter,
            sourceSize: CGSize(width: display.width, height: display.height),
            sourceBounds: bounds,
            sourceName: "Screen",
            isWindow: false,
            windowId: nil,
            pid: nil
        ))
    }

    /// Exact window by CGWindowID (the descriptor's `windowId`, else the app's AX focused window), kept pinned
    /// while it exists. Titles are never compared: Chrome's AX title ("Page - Part of group X - Google Chrome -
    /// Profile") never matches ScreenCaptureKit's ("Page"), and two windows can share a frame.
    static func selectWindow(for app: AppDescriptor, in windows: [SCWindow], pinnedWindowId: CGWindowID?) -> SCWindow? {
        let candidates = windows.compactMap(captureCandidate(from:))
        let targets = WindowResolver.targetWindows(
            pid: app.pid,
            knownWindowId: app.windowId.map { CGWindowID($0) },
            availableIds: Set(candidates.map(\.windowId))
        )
        guard let chosen = WindowResolver.chooseStreamWindow(
            from: candidates,
            pid: app.pid,
            targets: targets,
            pinnedWindowId: pinnedWindowId
        ) else {
            return nil
        }
        return windows.first { $0.windowID == chosen.windowId }
    }

    static func captureCandidate(from window: SCWindow) -> WindowResolver.CaptureCandidate? {
        guard let pid = window.owningApplication?.processID else {
            return nil
        }
        return WindowResolver.CaptureCandidate(
            windowId: window.windowID,
            pid: pid,
            frame: window.frame,
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen,
            title: window.title
        )
    }

    private static func isRunning(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return !app.isTerminated
    }

    /// Caller holds `lock`.
    private func applySourceLocked(_ resolved: ResolvedTarget) {
        if currentWindowID != resolved.windowId || currentIsWindow != resolved.isWindow {
            latestWindowFrame = nil
        }
        currentSourceBounds = resolved.sourceBounds
        currentSourceName = resolved.sourceName
        currentIsWindow = resolved.isWindow
        currentWindowID = resolved.windowId
        lastStreamedPid = resolved.pid
        if let windowId = resolved.windowId, let pid = resolved.pid {
            pinnedWindowID = windowId
            pinnedPid = pid
        } else {
            clearPinLocked()
        }
    }

    /// Caller holds `lock`.
    private func clearPinLocked() {
        pinnedWindowID = nil
        pinnedPid = nil
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
        // Sheets and popovers attached to the pinned window render as part of it.
        config.includeChildWindows = true
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
        let shouldCheck = isActive && self.generation == gen && currentMode == .autoWindow
            && currentTargetApp != nil && runningReconcileToken == nil
        let targetApp = currentTargetApp
        let existingStream = stream
        let existingKey = activeTargetKey
        let existingSize = activeSourceSize
        let pinned = pinnedPid == targetApp?.pid ? pinnedWindowID : nil
        lock.unlock()

        guard shouldCheck else { return }
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return
        }
        guard isStillActive(generation: gen), !Task.isCancelled else { return }

        switch resolveTarget(in: shareable, mode: .autoWindow, targetApp: targetApp, pinnedWindowId: pinned) {
        case .target(let resolved):
            if existingStream != nil, resolved.key == existingKey, resolved.sourceSize == existingSize {
                lock.lock()
                if isActive, self.generation == gen, self.stream === existingStream {
                    applySourceLocked(resolved)
                }
                lock.unlock()
            } else {
                // The target moved to another real window, the pinned one was resized, or a window showed up
                // while waiting.
                scheduleReconcile(generation: gen)
            }
        case .waitingForWindow, .none:
            if existingStream != nil {
                scheduleReconcile(generation: gen)
            }
        }
    }

    private func stopCurrentStreamIfNeeded(generation gen: UInt64, keepMetadataLoop: Bool = false) {
        lock.lock()
        guard self.generation == gen, let oldStream = stream else {
            lock.unlock()
            return
        }
        stream = nil
        activeTargetKey = nil
        activeSourceSize = .zero
        latestWindowFrame = nil
        if !keepMetadataLoop {
            metadataTask?.cancel()
            metadataTask = nil
        }
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

// MARK: - Preview geometry (pure, used by the HUD preview overlay)

/// Maps global screen coordinates (top-left origin, the space AX frames and `sourceBounds` use) into the
/// live preview. The preview has a fixed size and never asks the page or window to change: the source fills it from
/// its top-left corner, and whatever does not fit (on the right or at the bottom) is cut off.
public enum LivePreviewGeometry {
    /// Rect the whole source occupies in a preview of `previewSize`, in preview points with y down. It starts at the
    /// preview's top-left corner and is at least as large as the preview on both axes; the part past the preview's
    /// edges is cropped.
    public static func displayedRect(sourceSize: CGSize, in previewSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, previewSize.width > 0, previewSize.height > 0 else {
            return .zero
        }
        let scale = max(previewSize.width / sourceSize.width, previewSize.height / sourceSize.height)
        return CGRect(x: 0, y: 0, width: sourceSize.width * scale, height: sourceSize.height * scale)
    }

    /// Preview position of a global point, or nil when it falls outside the source by more than `tolerance` (a
    /// fraction of the source size) or lands in the cropped part (with the same slack, as a fraction of the preview).
    public static func previewPoint(
        _ point: CGPoint,
        sourceBounds: CGRect,
        previewSize: CGSize,
        tolerance: CGFloat = 0
    ) -> CGPoint? {
        guard sourceBounds.width > 0, sourceBounds.height > 0 else { return nil }
        let relX = (point.x - sourceBounds.minX) / sourceBounds.width
        let relY = (point.y - sourceBounds.minY) / sourceBounds.height
        guard relX >= -tolerance, relX <= 1 + tolerance, relY >= -tolerance, relY <= 1 + tolerance else {
            return nil
        }
        let shown = displayedRect(sourceSize: sourceBounds.size, in: previewSize)
        guard shown.width > 0, shown.height > 0 else { return nil }
        let mapped = CGPoint(x: shown.minX + relX * shown.width, y: shown.minY + relY * shown.height)
        let slackX = tolerance * previewSize.width
        let slackY = tolerance * previewSize.height
        guard mapped.x >= -slackX, mapped.x <= previewSize.width + slackX,
              mapped.y >= -slackY, mapped.y <= previewSize.height + slackY else {
            return nil
        }
        return mapped
    }

    /// Preview rect of a global rect, clipped to the source and to the preview, or nil when nothing of it shows.
    public static func previewRect(_ rect: CGRect, sourceBounds: CGRect, previewSize: CGSize) -> CGRect? {
        guard sourceBounds.width > 0, sourceBounds.height > 0 else { return nil }
        // Zero-size rects (Chrome reports them for clipped elements) still mark a position.
        let target = CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: max(rect.height, 1))
        let clipped = target.intersection(sourceBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let shown = displayedRect(sourceSize: sourceBounds.size, in: previewSize)
        guard shown.width > 0, shown.height > 0 else { return nil }
        let scaleX = shown.width / sourceBounds.width
        let scaleY = shown.height / sourceBounds.height
        let mapped = CGRect(
            x: shown.minX + (clipped.minX - sourceBounds.minX) * scaleX,
            y: shown.minY + (clipped.minY - sourceBounds.minY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        )
        let visible = mapped.intersection(CGRect(origin: .zero, size: previewSize))
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return visible
    }

    /// Whether an overlay that belongs to window `overlayWindowId` of `overlayPid` may be drawn on the frame
    /// the preview currently shows. Without a pid the overlay keeps the old behavior (mapped onto whatever
    /// is shown). Chrome extension frames use page coordinates, so screen-space overlays never go on them.
    public static func previewShowsOverlay(
        overlayPid: Int32?,
        overlayWindowId: UInt32?,
        sourceIsBrowserFrame: Bool,
        sourceIsWindow: Bool,
        sourcePid: Int32?,
        sourceWindowId: UInt32?
    ) -> Bool {
        guard let overlayPid else { return true }
        if sourceIsBrowserFrame { return false }
        // A display stream shows every window in global coordinates.
        if !sourceIsWindow { return true }
        if let overlayWindowId, let sourceWindowId {
            return overlayWindowId == sourceWindowId
        }
        if let sourcePid {
            return sourcePid == overlayPid
        }
        return true
    }
}
