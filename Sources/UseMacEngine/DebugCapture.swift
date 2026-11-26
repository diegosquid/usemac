import Foundation
import UseMacProtocol

/// A window of UseMac's own that the app lists for `debug_capture`: its number and what it is.
public struct DebugCaptureWindowRef: Equatable, Sendable {
    /// `NSWindow.windowNumber`, which is the window's `CGWindowID`.
    public var windowId: UInt32
    public var kind: DebugCaptureWindowKind
    public var title: String

    public init(windowId: UInt32, kind: DebugCaptureWindowKind, title: String) {
        self.windowId = windowId
        self.kind = kind
        self.title = title
    }
}

/// Whether the user turned on Debug capture, and how the engine learns which of UseMac's windows is which.
///
/// Only the app sets either one, in-process (`UseMacEngineService.setDebugCaptureEnabled`). No RPC method, MCP tool
/// or CLI command reaches them, so an agent can never turn debug capture on. A new engine starts with it off.
public final class DebugCaptureGate: @unchecked Sendable {
    public typealias WindowProvider = @Sendable () async -> [DebugCaptureWindowRef]

    private let lock = NSLock()
    private var enabled = false
    private var provider: WindowProvider?

    public init() {}

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Returns true when the value changed.
    @discardableResult
    func setEnabled(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = enabled != value
        enabled = value
        return changed
    }

    func setWindowProvider(_ provider: WindowProvider?) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    /// UseMac's windows on screen right now, as the app lists them. Empty without the app (the CLI's own engine).
    func windows() async -> [DebugCaptureWindowRef] {
        guard let provider = currentProvider() else { return [] }
        return await provider()
    }

    private func currentProvider() -> WindowProvider? {
        lock.lock(); defer { lock.unlock() }
        return provider
    }
}

/// What UseMac says about Debug capture: in Settings, in the menu bar menu, and to agents it refuses.
public enum DebugCaptureNotice {
    /// The refusal while the setting is off. The CLI exits with 4, like the other blocks only the user can lift.
    public static let offCode = "DEBUG_CAPTURE_OFF"
    public static let offMessage = "Debug capture is off, so UseMac doesn't capture its own windows. Nothing was captured."
    public static let offHint = "Ask the user to turn on Debug capture in UseMac → Settings → Developer if they want you to see UseMac's own windows. Only they can turn it on; don't look for another route."

    /// The audit method for the user turning the setting on or off (History lists it as a setting change).
    public static let settingAuditMethod = "debug_capture_setting"

    // MARK: - Settings

    public static let settingTitle = "Debug capture"
    public static let settingSubtitleOff = "For developing UseMac. Lets agents take screenshots of UseMac's own windows."
    public static let settingSubtitleOn = "On: agents can take screenshots of UseMac's windows, including the live preview and Settings. They can't click or type in them."

    /// The confirmation shown before it turns on.
    public static let confirmTitle = "Turn on Debug capture?"
    public static let confirmMessage = "Agents will be able to take screenshots of UseMac's own windows, including the live preview and Settings, and of the screen right around the live preview. They still can't click or type in UseMac's windows. Turn it on only while you develop or test UseMac, and turn it off when you're done."
    public static let confirmButton = "Turn On"
    public static let confirmFootnote = "Click with your mouse or trackpad; agents can't press this button."

    // MARK: - Menu bar

    /// The menu bar menu's line while it is on.
    public static let menuTitle = "Debug Capture: On"
    public static let menuSubtitle = "Agents can take screenshots of UseMac's windows"
    public static let menuTurnOffTitle = "Turn Off Debug Capture"

    // MARK: - Capture results

    static func nothingOnScreenMessage(label: String) -> String {
        "No UseMac window (\(label)) was on screen, so nothing was captured."
    }

    static let nothingOnScreenHint = "The live preview shows while a task runs (usemac start) or after the user presses ⌥Space; Settings and the other windows only the user can open. Open it, then retry."
}
