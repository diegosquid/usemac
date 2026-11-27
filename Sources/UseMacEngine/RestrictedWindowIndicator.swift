import Foundation
import UseMacProtocol

public struct RestrictedWindowOverlayState: Equatable, Sendable {
    public var pid: Int32
    public var windowId: UInt32?
    public var frame: ScreenRect
    public var step: String?
    public var taskId: String?
    public var isVisibleOnScreen: Bool

    public init(
        pid: Int32,
        windowId: UInt32? = nil,
        frame: ScreenRect,
        step: String? = nil,
        taskId: String? = nil,
        isVisibleOnScreen: Bool
    ) {
        self.pid = pid
        self.windowId = windowId
        self.frame = frame
        self.step = step
        self.taskId = taskId
        self.isVisibleOnScreen = isVisibleOnScreen
    }
}

public enum RestrictedWindowIndicator {
    public static let lingerSeconds: TimeInterval = 6.0

    public enum Action: Equatable, Sendable {
        case show(step: String?)
        case clear
        case ignore
    }

    /// Shows the native overlay only while working on a restricted Chromium page.
    /// Clears when the task leaves the fallback, finishes, or automation is blocked.
    public static func decide(
        for item: LiveActivityItem,
        isChromeBridgeActivity: Bool,
        isChromiumApp: Bool,
        canAct: Bool,
        currentTaskId: String?
    ) -> Action {
        guard canAct else { return .clear }
        if item.kind == .taskComplete {
            return currentTaskId == nil || item.taskId == nil || item.taskId == currentTaskId ? .clear : .ignore
        }
        if item.kind == .policyOrSafety { return .clear }
        if let currentTaskId, item.taskId == currentTaskId,
           isChromeBridgeActivity || !isChromiumApp || item.isRestrictedPageFallback == false {
            return .clear
        }
        guard !isChromeBridgeActivity, isChromiumApp, item.isRestrictedPageFallback == true,
              item.targetGuessed != true,
              let bounds = item.windowBounds, bounds.width >= 120, bounds.height >= 120,
              (item.appPid ?? 0) > 0 else {
            return .ignore
        }

        switch item.kind {
        case .actionStart, .actionStep:
            let step = item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
            return .show(step: step.isEmpty ? nil : String(step))
        case .observe, .actionComplete:
            return .show(step: nil)
        default:
            return .ignore
        }
    }

    public static func nativeCardId(pid: Int32, windowId: UInt32?, taskId: String?) -> String {
        if let windowId {
            return "app:\(pid):win:\(windowId)"
        }
        if let taskId = taskId?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty {
            return "app:\(pid):task:\(taskId)"
        }
        return "app:\(pid)"
    }
}
