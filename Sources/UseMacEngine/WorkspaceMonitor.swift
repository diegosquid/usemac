import AppKit
import CoreGraphics
import Foundation
import UseMacProtocol

public final class WorkspaceMonitor: @unchecked Sendable {
    private struct WindowMetadata {
        let title: String?
        let bounds: ScreenRect?
        let layer: Int
    }

    private let lock = NSLock()
    private let selfPid: Int32 = ProcessInfo.processInfo.processIdentifier
    private var lastExternalFrontmostApp: AppDescriptor?
    private var pairedApp: AppDescriptor?

    public init() {}

    public func listRunningApps() -> [AppDescriptor] {
        let windowMap = collectWindowMetadataByPid()
        let running = NSWorkspace.shared.runningApplications

        var descriptors: [AppDescriptor] = []
        descriptors.reserveCapacity(running.count)

        for app in running {
            guard app.activationPolicy == .regular, !app.isTerminated else {
                continue
            }

            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "App-\(pid)"
            let meta = windowMap[pid]

            let descriptor = AppDescriptor(
                pid: pid,
                name: name,
                bundleId: app.bundleIdentifier,
                isActive: app.isActive,
                isHidden: app.isHidden,
                windowTitle: meta?.title,
                windowBounds: meta?.bounds
            )
            descriptors.append(descriptor)
        }

        descriptors.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if let activeExternal = descriptors.first(where: { $0.isActive && $0.pid != selfPid }) {
            lock.lock()
            lastExternalFrontmostApp = activeExternal
            lock.unlock()
        }

        return descriptors
    }

    public func currentExternalFrontmostApp() -> AppDescriptor? {
        let apps = listRunningApps()
        if let active = apps.first(where: { $0.isActive && $0.pid != selfPid }) {
            return active
        }
        return apps.first(where: { $0.pid != selfPid })
    }

    @discardableResult
    public func captureFrontmostExternalApp() -> AppDescriptor? {
        let apps = listRunningApps()
        if let active = apps.first(where: { $0.isActive && $0.pid != selfPid }) {
            lock.lock()
            lastExternalFrontmostApp = active
            lock.unlock()
            return active
        }
        lock.lock()
        let cached = lastExternalFrontmostApp
        lock.unlock()
        return cached
    }

    @discardableResult
    public func setPairedApp(_ query: String?) -> AppDescriptor? {
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lock.lock()
            pairedApp = nil
            lock.unlock()
            return nil
        }

        let resolved = matchApp(query: query, in: listRunningApps())
        lock.lock()
        pairedApp = resolved
        lock.unlock()
        return resolved
    }

    public func getPairedApp() -> AppDescriptor? {
        lock.lock()
        let currentPaired = pairedApp
        lock.unlock()

        guard let currentPaired else { return nil }
        let apps = listRunningApps()
        if let fresh = apps.first(where: { $0.pid == currentPaired.pid }) {
            lock.lock()
            pairedApp = fresh
            lock.unlock()
            return fresh
        }
        return currentPaired
    }

    /// Resolves the app an action targets and pins the exact window (AX focused window → CGWindowID), so
    /// previews, screenshots and overlay checks never guess by title.
    public func resolveApp(query: String?) -> AppDescriptor? {
        guard let app = resolveAppWithoutWindow(query: query) else { return nil }
        return Self.withTargetWindow(app)
    }

    public static func withTargetWindow(_ app: AppDescriptor) -> AppDescriptor {
        guard app.pid > 0, let windowId = WindowResolver.targetWindowID(pid: app.pid) else {
            return app
        }
        var resolved = app
        resolved.windowId = UInt32(windowId)
        if let info = WindowResolver.info(windowId: windowId) {
            if let title = info.title, !title.isEmpty {
                resolved.windowTitle = title
            }
            resolved.windowBounds = ScreenRect(
                x: Double(info.frame.origin.x),
                y: Double(info.frame.origin.y),
                width: Double(info.frame.width),
                height: Double(info.frame.height)
            )
        }
        return resolved
    }

    private func resolveAppWithoutWindow(query: String?) -> AppDescriptor? {
        let apps = listRunningApps()

        if let query {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return matchApp(query: trimmed, in: apps)
            }
        }

        lock.lock()
        let currentPaired = pairedApp
        let lastExternal = lastExternalFrontmostApp
        lock.unlock()

        if let currentPaired {
            if let fresh = apps.first(where: { $0.pid == currentPaired.pid }) {
                return fresh
            }
            if let running = NSRunningApplication(processIdentifier: currentPaired.pid), !running.isTerminated {
                return currentPaired
            }
        }

        if let lastExternal {
            if let fresh = apps.first(where: { $0.pid == lastExternal.pid }) {
                return fresh
            }
            if let running = NSRunningApplication(processIdentifier: lastExternal.pid), !running.isTerminated {
                return lastExternal
            }
        }

        return apps.first(where: { $0.isActive && $0.pid != selfPid })
            ?? apps.first(where: { $0.pid != selfPid })
            ?? apps.first
    }

    private func matchApp(query: String, in apps: [AppDescriptor]) -> AppDescriptor? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let pid = Int32(trimmed) {
            return apps.first(where: { $0.pid == pid })
        }

        let needle = trimmed.lowercased()

        // 1. Exact match on name or bundleId
        if let exact = apps.first(where: {
            $0.name.lowercased() == needle || ($0.bundleId?.lowercased() == needle)
        }) {
            return exact
        }

        // 2. Prefix match on name or bundleId
        if let prefix = apps.first(where: {
            $0.name.lowercased().hasPrefix(needle) || ($0.bundleId?.lowercased().hasPrefix(needle) ?? false)
        }) {
            return prefix
        }

        // 3. Substring match on name or bundleId
        return apps.first(where: {
            $0.name.lowercased().contains(needle) || ($0.bundleId?.lowercased().contains(needle) ?? false)
        })
    }

    private func collectWindowMetadataByPid() -> [Int32: WindowMetadata] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var result: [Int32: WindowMetadata] = [:]

        for info in windowList {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            let pid = pidNumber.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let title = info[kCGWindowName as String] as? String

            var rect: ScreenRect?
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let cgRect = CGRect(dictionaryRepresentation: boundsDict),
               cgRect.width > 1 && cgRect.height > 1 {
                rect = ScreenRect(
                    x: Double(cgRect.origin.x),
                    y: Double(cgRect.origin.y),
                    width: Double(cgRect.size.width),
                    height: Double(cgRect.size.height)
                )
            }

            guard rect != nil else { continue }

            if let existing = result[pid] {
                // Prefer standard window layer (0), especially if existing wasn't layer 0 or lacked a title
                if existing.layer != 0 && layer == 0 {
                    result[pid] = WindowMetadata(title: title, bounds: rect, layer: layer)
                } else if existing.layer == layer && (existing.title?.isEmpty ?? true) && !(title?.isEmpty ?? true) {
                    result[pid] = WindowMetadata(title: title, bounds: rect, layer: layer)
                }
            } else {
                result[pid] = WindowMetadata(title: title, bounds: rect, layer: layer)
            }
        }

        return result
    }
}
