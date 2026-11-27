import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Private but long-stable SPI (used by yabai, AltTab, Rectangle) that returns the CGWindowID behind an
/// AX window element. It is the only exact link between the accessibility tree and the window server.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Shared answers to "which window is the agent working on, and can the user see it?".
/// Everything that captures, previews or highlights a window must go through here instead of guessing by
/// window title, because titles change with every tab and two windows can have identical frames.
public enum WindowResolver {
    public struct WindowInfo: Equatable, Sendable {
        public var windowId: CGWindowID
        public var pid: pid_t
        /// Global coordinates, top-left origin (same space as AX frames).
        public var frame: CGRect
        public var layer: Int
        public var isOnScreen: Bool
        public var title: String?
        public var alpha: Double
    }

    /// Smallest window UseMac treats as a real content window (filters Chrome's helper strips, tooltips).
    public static let minimumContentSize = CGSize(width: 120, height: 120)

    /// CGWindowID backing an AX window element.
    public static func windowID(of axWindow: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &id) == .success, id != 0 else {
            return nil
        }
        return id
    }

    // MARK: Window pin

    private static let pinLock = NSLock()
    nonisolated(unsafe) private static var pinnedTitles: [pid_t: String] = [:]

    /// Pins `pid`'s target window to the one whose title contains `title` (nil or empty clears the pin).
    /// Observe/act use it to work in a window that is not focused, e.g. a Chrome window UseMac opened.
    public static func pin(pid: pid_t, title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pinLock.lock()
        pinnedTitles[pid] = trimmed.isEmpty ? nil : trimmed
        pinLock.unlock()
    }

    public static func pinnedTitle(pid: pid_t) -> String? {
        pinLock.lock()
        defer { pinLock.unlock() }
        return pinnedTitles[pid]
    }

    /// The window of `pid` whose title contains `title` (case- and accent-insensitive), if any.
    public static func window(pid: pid_t, titleContains title: String) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        let wanted = ElementMatcher.normalize(title)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AnyObject] else { return nil }
        for item in windows where CFGetTypeID(item) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(item, to: AXUIElement.self)
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
               let windowTitle = titleRef as? String,
               ElementMatcher.normalize(windowTitle).contains(wanted) {
                return element
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let focusedMainWindowAttrs: CFArray = [
        kAXFocusedWindowAttribute as CFString,
        kAXMainWindowAttribute as CFString
    ] as CFArray

    /// The app's target AX window: the pinned window when a pin is set (nil if it is gone), otherwise the
    /// focused window (or its first window), with the CGWindowID behind it.
    public static func focusedWindow(pid: pid_t) -> (element: AXUIElement, windowId: CGWindowID?)? {
        if let pinned = pinnedTitle(pid: pid) {
            guard let element = window(pid: pid, titleContains: pinned) else { return nil }
            return (element, windowID(of: element))
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        var valuesRef: CFArray?
        if AXUIElementCopyMultipleAttributeValues(
            axApp,
            focusedMainWindowAttrs,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        ) == .success, let values = valuesRef as? [AnyObject], values.count >= 2 {
            for item in values where CFGetTypeID(item) == AXUIElementGetTypeID() {
                let win = unsafeBitCast(item, to: AXUIElement.self)
                return (win, windowID(of: win))
            }
        } else {
            if let focused = copyElement(axApp, kAXFocusedWindowAttribute) {
                return (focused, windowID(of: focused))
            }
            if let main = copyElement(axApp, kAXMainWindowAttribute) {
                return (main, windowID(of: main))
            }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AnyObject] {
            for item in windows where CFGetTypeID(item) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(item, to: AXUIElement.self)
                return (element, windowID(of: element))
            }
        }
        return nil
    }

    /// CGWindowID of the window UseMac should treat as the app's target window.
    public static func targetWindowID(pid: pid_t) -> CGWindowID? {
        focusedWindow(pid: pid)?.windowId
    }

    /// Info for one window, whether or not it is on the current Space.
    public static func info(windowId: CGWindowID) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]],
              let raw = list.first else {
            return nil
        }
        return parse(raw)
    }

    /// Normal (layer 0) windows on the current Space, front to back.
    public static func onScreenWindows() -> [WindowInfo] {
        onScreenWindows(upToLayer: 0)
    }

    /// Windows on the current Space at layers 0 through `maxLayer`, front to back.
    public static func onScreenWindows(upToLayer maxLayer: Int) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap(parse).filter { $0.layer >= 0 && $0.layer <= maxLayer && $0.alpha > 0.01 }
    }

    /// True when `point` (global, top-left origin) is on screen and the topmost normal window there is the
    /// target window (`windowId` when known, otherwise any window of `pid`). False when the window is in
    /// another Space, minimized, or covered by another app at that point.
    public static func isPointVisible(_ point: CGPoint, pid: pid_t, windowId: CGWindowID? = nil) -> Bool {
        guard let top = onScreenWindows().first(where: { $0.frame.contains(point) }) else {
            return false
        }
        if let windowId {
            return top.windowId == windowId
        }
        return top.pid == pid
    }

    /// True when any part of `rect` is visible for the target window (checks the center and inset corners).
    public static func isRectVisible(_ rect: CGRect, pid: pid_t, windowId: CGWindowID? = nil) -> Bool {
        let inset = rect.insetBy(dx: min(4, rect.width / 4), dy: min(4, rect.height / 4))
        let probes = [
            CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: inset.minX, y: inset.minY),
            CGPoint(x: inset.maxX, y: inset.minY),
            CGPoint(x: inset.minX, y: inset.maxY),
            CGPoint(x: inset.maxX, y: inset.maxY)
        ]
        let windows = onScreenWindows()
        for probe in probes {
            guard let top = windows.first(where: { $0.frame.contains(probe) }) else { continue }
            if let windowId, top.windowId == windowId { return true }
            if windowId == nil, top.pid == pid { return true }
        }
        return false
    }

    public static func frontmostPid() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public static func isFrontmost(pid: pid_t) -> Bool {
        frontmostPid() == pid
    }

    /// Seconds since the last keyboard or mouse event from the user's hardware.
    public static func secondsSinceUserInput() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private static func parse(_ raw: [String: Any]) -> WindowInfo? {
        guard let number = raw[kCGWindowNumber as String] as? NSNumber,
              let owner = raw[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDict = raw[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return WindowInfo(
            windowId: CGWindowID(number.uint32Value),
            pid: pid_t(owner.int32Value),
            frame: frame,
            layer: (raw[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            isOnScreen: (raw[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            title: raw[kCGWindowName as String] as? String,
            alpha: (raw[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        )
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

// MARK: - Choosing the window to capture (shared by the live preview and screenshots)

extension WindowResolver {
    /// A capturable window reduced to what the choice needs, so the rules can be tested without
    /// ScreenCaptureKit. Build it from `SCWindow` (see `LiveScreenStreamer` / `FastScreenCapturer`).
    public struct CaptureCandidate: Equatable, Sendable {
        public var windowId: CGWindowID
        public var pid: pid_t
        /// Global coordinates, top-left origin.
        public var frame: CGRect
        public var layer: Int
        public var isOnScreen: Bool
        public var title: String?

        public init(
            windowId: CGWindowID,
            pid: pid_t,
            frame: CGRect,
            layer: Int = 0,
            isOnScreen: Bool = true,
            title: String? = nil
        ) {
            self.windowId = windowId
            self.pid = pid
            self.frame = frame
            self.layer = layer
            self.isOnScreen = isOnScreen
            self.title = title
        }
    }

    /// The window the agent targets, as seen through Accessibility.
    public struct TargetWindow: Equatable, Sendable {
        public var windowId: CGWindowID
        /// AX subrole is AXStandardWindow (a real document window, not a dialog, panel or popup).
        /// nil when unknown.
        public var isStandardWindow: Bool?

        public init(windowId: CGWindowID, isStandardWindow: Bool? = nil) {
            self.windowId = windowId
            self.isStandardWindow = isStandardWindow
        }
    }

    /// The app's AX focused window with its subrole, used to tell a new document window from a dialog.
    public static func targetWindow(pid: pid_t) -> TargetWindow? {
        guard let focused = focusedWindow(pid: pid), let windowId = focused.windowId else {
            return nil
        }
        var value: CFTypeRef?
        var isStandard: Bool?
        if AXUIElementCopyAttributeValue(focused.element, kAXSubroleAttribute as CFString, &value) == .success,
           let subrole = value as? String {
            isStandard = subrole == (kAXStandardWindowSubrole as String)
        }
        return TargetWindow(windowId: windowId, isStandardWindow: isStandard)
    }

    /// Target windows to look for, in order: the id the caller already knows (e.g. `AppDescriptor.windowId`),
    /// then, only when that id is missing or not among `availableIds`, the app's AX focused window.
    public static func targetWindows(
        pid: pid_t,
        knownWindowId: CGWindowID?,
        availableIds: Set<CGWindowID>
    ) -> [TargetWindow] {
        var result: [TargetWindow] = []
        if let knownWindowId, knownWindowId != 0 {
            result.append(TargetWindow(windowId: knownWindowId))
            if availableIds.contains(knownWindowId) {
                return result
            }
        }
        if let focused = targetWindow(pid: pid), !result.contains(where: { $0.windowId == focused.windowId }) {
            result.append(focused)
        }
        return result
    }

    /// Normal (layer 0) window at least `minimumContentSize` on both sides.
    public static func isContentWindow(_ candidate: CaptureCandidate) -> Bool {
        candidate.layer == 0
            && candidate.frame.width >= minimumContentSize.width
            && candidate.frame.height >= minimumContentSize.height
    }

    /// True when `window` looks like a sheet, dialog or popup sitting on `parent` rather than a window of its
    /// own: same app, and either not a normal content window or smaller and almost entirely inside `parent`.
    /// A window AX reports as a standard window never counts as attached.
    public static func isAttached(
        _ window: CaptureCandidate,
        to parent: CaptureCandidate,
        isStandardWindow: Bool? = nil
    ) -> Bool {
        guard window.pid == parent.pid, window.windowId != parent.windowId else {
            return false
        }
        if !isContentWindow(window) {
            return true
        }
        if isStandardWindow == true {
            return false
        }
        let windowArea = window.frame.width * window.frame.height
        let parentArea = parent.frame.width * parent.frame.height
        guard windowArea < parentArea else {
            return false
        }
        let overlap = window.frame.intersection(parent.frame)
        guard !overlap.isNull else {
            return false
        }
        return overlap.width * overlap.height >= windowArea * 0.8
    }

    /// Window to capture for `pid`, matched by exact window id. `targets` are tried in order. When a
    /// target is a small dialog or popup, the content window under it is used instead. Only when no target
    /// resolves does it guess: the largest content window of the app (never helper strips or overlays).
    public static func chooseCaptureWindow(
        from candidates: [CaptureCandidate],
        pid: pid_t,
        targets: [TargetWindow]
    ) -> CaptureCandidate? {
        let owned = candidates.filter { $0.pid == pid }
        for target in targets {
            guard let exact = owned.first(where: { $0.windowId == target.windowId }) else {
                continue
            }
            if isContentWindow(exact) {
                return exact
            }
            let center = CGPoint(x: exact.frame.midX, y: exact.frame.midY)
            if let host = largestContentWindow(in: owned.filter { $0.frame.contains(center) }) {
                return host
            }
        }
        return largestContentWindow(in: owned)
    }

    /// Window a running preview should show. Keeps `pinnedWindowId` while it still exists unless the target
    /// moved to a different real window of the app; sheets, dialogs and popups over the pinned window do not
    /// move it. Without a pin (or when the pinned window is gone) it is `chooseCaptureWindow`.
    public static func chooseStreamWindow(
        from candidates: [CaptureCandidate],
        pid: pid_t,
        targets: [TargetWindow],
        pinnedWindowId: CGWindowID?
    ) -> CaptureCandidate? {
        let owned = candidates.filter { $0.pid == pid }
        guard let pinnedWindowId, let pinned = owned.first(where: { $0.windowId == pinnedWindowId }) else {
            return chooseCaptureWindow(from: owned, pid: pid, targets: targets)
        }
        // First target that ScreenCaptureKit lists. A target it does not list tells nothing new: keep the pin.
        guard let target = targets.first(where: { target in owned.contains { $0.windowId == target.windowId } }),
              target.windowId != pinnedWindowId,
              let targetWindow = owned.first(where: { $0.windowId == target.windowId }) else {
            return pinned
        }
        if isAttached(targetWindow, to: pinned, isStandardWindow: target.isStandardWindow) {
            return pinned
        }
        return chooseCaptureWindow(from: owned, pid: pid, targets: [target]) ?? pinned
    }

    /// Largest content window; equal sizes prefer the one on the current Space, then a titled one, then
    /// list order (front to back).
    private static func largestContentWindow(in candidates: [CaptureCandidate]) -> CaptureCandidate? {
        var best: CaptureCandidate?
        for candidate in candidates where isContentWindow(candidate) {
            guard let current = best else {
                best = candidate
                continue
            }
            let area = candidate.frame.width * candidate.frame.height
            let bestArea = current.frame.width * current.frame.height
            if area > bestArea * 1.01 {
                best = candidate
            } else if area >= bestArea * 0.99 {
                if candidate.isOnScreen != current.isOnScreen {
                    if candidate.isOnScreen { best = candidate }
                } else if !(candidate.title ?? "").isEmpty && (current.title ?? "").isEmpty {
                    best = candidate
                }
            }
        }
        return best
    }
}
