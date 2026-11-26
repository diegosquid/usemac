import Foundation

/// `debug_capture`: read-only screenshots of UseMac's own windows (the live preview, Settings, …), for developing
/// UseMac itself. It works only while the user has turned on Debug capture in UseMac → Settings → Developer. No
/// method, MCP tool or CLI command can turn it on, and it never clicks or types in UseMac's windows.
public enum DebugCaptureWindowKind: String, Codable, CaseIterable, Sendable {
    /// The floating live preview.
    case preview
    /// The Ask mode prompt next to the preview.
    case prompt
    /// Settings.
    case settings
    /// The setup guide.
    case setup
    /// The "Review problem report" window.
    case report
    /// Any other titled UseMac window (an alert, the permission helper).
    case other
}

public struct DebugCaptureParams: Codable, Equatable, Sendable {
    /// Which windows, comma-separated: `preview`, `prompt`, `settings`, `setup`, `report`, `other`, `all` (every
    /// window kind) or `context` (the screen around the preview). Default `all`.
    public var window: String?
    /// How many times to capture, for a short burst. Default 1, at most 40.
    public var frames: Int?
    /// Time between the starts of two frames, in milliseconds. Default 250, from 100 to 1000.
    public var intervalMs: Int?
    /// Also capture the screen around the preview: the display cropped to the preview's frame plus `contextMargin`,
    /// so the preview shows over what is behind it. Same as adding `context` to `window`.
    public var context: Bool?
    /// Points around the preview in a context capture. Default 48, at most 400.
    public var contextMargin: Int?

    public init(window: String? = nil, frames: Int? = nil, intervalMs: Int? = nil, context: Bool? = nil, contextMargin: Int? = nil) {
        self.window = window
        self.frames = frames
        self.intervalMs = intervalMs
        self.context = context
        self.contextMargin = contextMargin
    }

    /// The names `window` takes besides the window kinds.
    public static let allName = "all"
    public static let contextName = "context"

    public static let defaultFrames = 1
    public static let maxFrames = 40
    public static let defaultIntervalMs = 250
    public static let intervalRangeMs: ClosedRange<Int> = 100...1000
    public static let defaultContextMargin = 48
    public static let maxContextMargin = 400

    public struct InvalidWindow: Error, Equatable, Sendable {
        public let name: String
        public var message: String {
            let names = DebugCaptureWindowKind.allCases.map(\.rawValue) + [DebugCaptureParams.allName, DebugCaptureParams.contextName]
            return "Unknown window '\(name)'. Use one or more of: \(names.joined(separator: ", ")) (comma-separated)."
        }
    }

    /// The options to run with. Frames, interval and margin outside their range are brought into it, and `notes`
    /// says so. Throws `InvalidWindow` for a name it doesn't know.
    public func resolved() throws -> DebugCaptureOptions {
        var kinds: [DebugCaptureWindowKind] = []
        var wantsContext = context == true
        let names = (window ?? Self.allName)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        for name in names.isEmpty ? [Self.allName] : names {
            if name == Self.allName {
                kinds.append(contentsOf: DebugCaptureWindowKind.allCases)
            } else if name == Self.contextName {
                wantsContext = true
            } else if let kind = DebugCaptureWindowKind(rawValue: name) {
                kinds.append(kind)
            } else {
                throw InvalidWindow(name: name)
            }
        }

        var notes: [String] = []
        let wantedFrames = frames ?? Self.defaultFrames
        let usedFrames = min(max(wantedFrames, 1), Self.maxFrames)
        if usedFrames != wantedFrames {
            notes.append("frames \(wantedFrames) → \(usedFrames) (1 to \(Self.maxFrames))")
        }
        let wantedInterval = intervalMs ?? Self.defaultIntervalMs
        let usedInterval = min(max(wantedInterval, Self.intervalRangeMs.lowerBound), Self.intervalRangeMs.upperBound)
        if usedInterval != wantedInterval {
            notes.append("interval \(wantedInterval) ms → \(usedInterval) ms (\(Self.intervalRangeMs.lowerBound) to \(Self.intervalRangeMs.upperBound))")
        }
        let wantedMargin = contextMargin ?? Self.defaultContextMargin
        let usedMargin = min(max(wantedMargin, 0), Self.maxContextMargin)
        if usedMargin != wantedMargin {
            notes.append("context margin \(wantedMargin) → \(usedMargin) pt (0 to \(Self.maxContextMargin))")
        }

        let unique = DebugCaptureWindowKind.allCases.filter(Set(kinds).contains)
        return DebugCaptureOptions(
            kinds: unique,
            frames: usedFrames,
            intervalMs: usedInterval,
            context: wantsContext,
            contextMargin: usedMargin,
            notes: notes
        )
    }
}

/// `DebugCaptureParams` after `resolved()`: every value in range.
public struct DebugCaptureOptions: Equatable, Sendable {
    /// The window kinds to capture, in `DebugCaptureWindowKind.allCases` order. Empty when only `context` was asked.
    public var kinds: [DebugCaptureWindowKind]
    public var frames: Int
    public var intervalMs: Int
    public var context: Bool
    public var contextMargin: Int
    /// What was brought into range, for the agent.
    public var notes: [String]

    public init(kinds: [DebugCaptureWindowKind], frames: Int, intervalMs: Int, context: Bool, contextMargin: Int, notes: [String] = []) {
        self.kinds = kinds
        self.frames = frames
        self.intervalMs = intervalMs
        self.context = context
        self.contextMargin = contextMargin
        self.notes = notes
    }

    /// The longest a burst can take between its first and last frame, in milliseconds.
    public var spanMs: Int { (frames - 1) * intervalMs }

    /// How long a client should wait for the answer: the burst, plus up to a second per frame for the captures.
    public var clientTimeoutMs: Int { 15_000 + spanMs + frames * 1_000 }

    /// What `window` named, for messages and the audit entry: "preview, settings" or "preview, context".
    public var label: String {
        let names = kinds.map(\.rawValue) + (context ? [DebugCaptureParams.contextName] : [])
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }
}

/// One PNG `debug_capture` saved.
public struct DebugCaptureImage: Codable, Equatable, Sendable {
    public var path: String
    /// A `DebugCaptureWindowKind` raw value, or `context` for the screen around the preview.
    public var kind: String
    /// The window's title (often empty for panels such as the preview).
    public var title: String?
    /// The window's number (`CGWindowID`); nil for a context capture.
    public var windowId: Int?
    /// The window's frame, or the captured region for `context`, in screen points with the origin at the top-left
    /// of the main display (the coordinates `observe` uses).
    public var frame: ScreenRect
    /// Image size in pixels.
    public var width: Int
    public var height: Int
    public var byteCount: Int
    /// The frame of the burst it belongs to, from 0.
    public var frameIndex: Int
    /// When it was taken, in milliseconds after the burst started.
    public var offsetMs: Double

    public init(
        path: String,
        kind: String,
        title: String?,
        windowId: Int?,
        frame: ScreenRect,
        width: Int,
        height: Int,
        byteCount: Int,
        frameIndex: Int,
        offsetMs: Double
    ) {
        self.path = path
        self.kind = kind
        self.title = title
        self.windowId = windowId
        self.frame = frame
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.frameIndex = frameIndex
        self.offsetMs = offsetMs
    }
}

/// What `debug_capture` answers.
public struct DebugCaptureResult: Codable, Equatable, Sendable {
    /// What was captured: "preview, settings, context".
    public var window: String
    public var frames: Int
    public var intervalMs: Int
    /// The folder the PNGs are in: the same private temp folder `screenshot` uses, pruned after 30 minutes.
    public var directory: String
    /// Every PNG, in the order taken.
    public var images: [DebugCaptureImage]
    public var latencyMs: Double
    /// Values brought into range ("frames 80 → 40 (1 to 40)") and windows that weren't on screen.
    public var notes: [String]

    public init(window: String, frames: Int, intervalMs: Int, directory: String, images: [DebugCaptureImage], latencyMs: Double, notes: [String] = []) {
        self.window = window
        self.frames = frames
        self.intervalMs = intervalMs
        self.directory = directory
        self.images = images
        self.latencyMs = latencyMs
        self.notes = notes
    }

    /// Copies every image into `directory` (created if needed) and returns the result with the new paths. An existing
    /// file there is never replaced: the copy gets a number instead.
    public func copied(to directory: String, fileManager: FileManager = .default) throws -> DebugCaptureResult {
        let target = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var copy = self
        copy.directory = target.path
        for index in copy.images.indices {
            let source = URL(fileURLWithPath: copy.images[index].path)
            let destination = Self.freeURL(in: target, name: source.lastPathComponent, fileManager: fileManager)
            try fileManager.copyItem(at: source, to: destination)
            copy.images[index].path = destination.path
        }
        return copy
    }

    private static func freeURL(in folder: URL, name: String, fileManager: FileManager) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
