import AppKit
import SwiftUI
import UseMacEngine
import UseMacProtocol

/// Tells the engine which of UseMac's windows is which, for `debug_capture`. The engine can't see the app's window
/// classes, so the app lists its visible windows by number and kind each time a capture asks.
///
/// Windows are told apart by their class or by the view they host, so no window needs a special title or
/// identifier. The agent overlay (full-screen, transparent) and untitled helper windows are left out.
@MainActor
enum DebugCaptureWindows {
    static func attach(to engine: UseMacEngineService) {
        engine.setDebugCaptureWindowProvider {
            await MainActor.run { DebugCaptureWindows.current() }
        }
    }

    static func current() -> [DebugCaptureWindowRef] {
        NSApp.windows.compactMap { window in
            guard window.isVisible, window.windowNumber > 0, let kind = kind(of: window) else { return nil }
            return DebugCaptureWindowRef(windowId: UInt32(window.windowNumber), kind: kind, title: window.title)
        }
    }

    static func kind(of window: NSWindow) -> DebugCaptureWindowKind? {
        switch window {
        case is ActivityHUDPanel:
            return .preview
        case is ApprovalPromptPanel:
            return .prompt
        case is ProblemReportWindow:
            return .report
        case is AgentOverlayPanel:
            return nil
        default:
            break
        }
        if window.contentView is NSHostingView<ControlCenterView> {
            return .settings
        }
        if window.contentView is NSHostingView<SetupGuideView> {
            return .setup
        }
        return window.styleMask.contains(.titled) ? .other : nil
    }
}
