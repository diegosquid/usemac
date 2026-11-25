import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacUseProtocol

public final class PermissionManager: @unchecked Sendable {
    public init() {}

    public func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        if !prompt {
            return AXIsProcessTrusted()
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func resetTCCEntry(service: String) -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "app.usemac"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", service, bundleId]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    public func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func currentStatus(promptAccessibility: Bool = false) -> PermissionStatus {
        PermissionStatus(
            accessibilityGranted: isAccessibilityGranted(prompt: promptAccessibility),
            screenRecordingGranted: isScreenRecordingGranted()
        )
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            _ = NSWorkspace.shared.open(url)
        }
    }
}
