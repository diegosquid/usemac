import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Where real (HID) input goes. The window server delivers a real mouse event to the window on top at its
/// point, and real keys to the key window of the app in front. Neither is necessarily the window UseMac works
/// in: with Chrome in front, the user's own Chrome window can sit over a window UseMac opened. These rules
/// decide, before anything is sent, whether a step may post real input at all.
public enum InputRouting {
    /// How a step whose app is in front may send a mouse event.
    public enum PointerRoute: Equatable, Sendable {
        /// The target window is on top at the point: real input lands in it.
        case foreground
        /// Another window is on top at the point (`covering`, nil when nothing of the target is on screen
        /// there): post the event to the target app and window instead, without real input.
        case background(covering: WindowResolver.WindowInfo?)
        /// Another window is on top at the point and the step has no background route: send nothing.
        case refuse(covering: WindowResolver.WindowInfo?)
    }

    /// Highest window level that takes real mouse input like a normal window (floating panels such as UseMac's
    /// activity panel, utility windows). The Dock, the menu bar, menus and click-through overlays (UseMac's
    /// highlight overlay sits at the status bar level) are above it.
    public static let maxPointerLayer = Int(CGWindowLevelForKey(.utilityWindow))

    /// The window a real mouse event at `point` lands in: the frontmost window that contains it, among normal
    /// windows and the floating levels up to `maxPointerLayer`. `windows` is front to back, as the window
    /// server lists them.
    public static func receiver(at point: CGPoint, in windows: [WindowResolver.WindowInfo]) -> WindowResolver.WindowInfo? {
        windows.first { window in
            window.layer >= 0 && window.layer <= maxPointerLayer && window.alpha > 0.01 && window.frame.contains(point)
        }
    }

    /// True when a real mouse event at `point` reaches the target. With a known target window, the window on
    /// top there must be that window, or a popup, sheet or menu of the same app sitting on it. A window
    /// `isDocumentWindow` reports as a standard window of the app (another browser or document window, such
    /// as the user's own) never counts. Without a known window, any window of the target app counts.
    public static func pointerReachesTarget(
        point: CGPoint,
        targetPid: pid_t,
        targetWindowId: CGWindowID?,
        windows: [WindowResolver.WindowInfo],
        isDocumentWindow: (CGWindowID) -> Bool = { _ in false }
    ) -> Bool {
        guard let top = receiver(at: point, in: windows) else {
            return false
        }
        guard let targetWindowId else {
            return top.pid == targetPid
        }
        if top.windowId == targetWindowId {
            return true
        }
        guard top.pid == targetPid,
              let target = windows.first(where: { $0.windowId == targetWindowId }),
              !isDocumentWindow(top.windowId) else {
            return false
        }
        return WindowResolver.isAttached(candidate(top), to: candidate(target), isStandardWindow: false)
    }

    /// Route for a mouse event of a step whose app is in front (UseMac would otherwise post real input).
    /// `backgroundAllowed` is true for events that have a background route without side effects (wheel and
    /// mouse-moved events posted to the app's window); clicks have none, because a click can make the window
    /// key and move the user's keyboard focus.
    public static func pointerRoute(
        point: CGPoint?,
        targetPid: pid_t,
        targetWindowId: CGWindowID?,
        windows: [WindowResolver.WindowInfo],
        isDocumentWindow: (CGWindowID) -> Bool = { _ in false },
        backgroundAllowed: Bool
    ) -> PointerRoute {
        if let point, pointerReachesTarget(
            point: point,
            targetPid: targetPid,
            targetWindowId: targetWindowId,
            windows: windows,
            isDocumentWindow: isDocumentWindow
        ) {
            return .foreground
        }
        let covering = point.flatMap { receiver(at: $0, in: windows) }
        return backgroundAllowed ? .background(covering: covering) : .refuse(covering: covering)
    }

    /// True when real keys reach the target window: its app is in front and the window is the app's focused
    /// (key) window. Keys always go to the key window, so another window of the same app in front (the user's)
    /// would get them. When either id is unknown, the app-level check decides.
    public static func keysReachTarget(appIsFrontmost: Bool, targetWindowId: CGWindowID?, focusedWindowId: CGWindowID?) -> Bool {
        guard appIsFrontmost else { return false }
        guard let targetWindowId, let focusedWindowId else { return true }
        return targetWindowId == focusedWindowId
    }

    private static func candidate(_ window: WindowResolver.WindowInfo) -> WindowResolver.CaptureCandidate {
        WindowResolver.CaptureCandidate(
            windowId: window.windowId,
            pid: window.pid,
            frame: window.frame,
            layer: window.layer,
            isOnScreen: window.isOnScreen,
            title: window.title
        )
    }

    // MARK: Live reads (not unit tested)

    /// The CGWindowID of the app's AX focused window, ignoring any window pin (the pin names the window UseMac
    /// works in, not the one that gets keys).
    public static func focusedWindowId(pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return WindowResolver.windowID(of: unsafeBitCast(value, to: AXUIElement.self))
    }

    /// CGWindowIDs of the app's standard (document) windows, from Accessibility.
    public static func documentWindowIds(pid: pid_t) -> Set<CGWindowID> {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AnyObject] else {
            return []
        }
        var ids: Set<CGWindowID> = []
        for item in windows where CFGetTypeID(item) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(item, to: AXUIElement.self)
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                  (subrole as? String) == (kAXStandardWindowSubrole as String),
                  let id = WindowResolver.windowID(of: element) else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// On-screen windows up to `maxPointerLayer`, front to back.
    public static func pointerWindows() -> [WindowResolver.WindowInfo] {
        WindowResolver.onScreenWindows(upToLayer: maxPointerLayer)
    }
}
