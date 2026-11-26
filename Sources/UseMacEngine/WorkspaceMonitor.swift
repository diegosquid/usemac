import AppKit
import CoreGraphics
import Foundation
import UseMacProtocol

/// What an app query (name, bundle ID or PID) names among the running apps.
public enum AppQueryMatch: Equatable, Sendable {
    case app(AppDescriptor)
    /// The query names UseMac itself, which is never a target.
    case useMac
    case notFound
}

public final class WorkspaceMonitor: @unchecked Sendable {
    /// UseMac's bundle ID. Matching it, not only this process's PID, also covers a `--standalone` CLI,
    /// whose own PID is not the app's.
    public static let useMacBundleId = "app.usemac"
    public static let useMacAppName = "UseMac"
    /// Agents never observe or act on UseMac's own windows (Settings, the setup guide): only the user changes
    /// UseMac's settings.
    public static let selfTargetMessage = "UseMac does not automate its own windows. Stop and ask the user to change UseMac settings themselves."

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

    /// Running GUI apps an agent may target. UseMac itself is never listed.
    public func listRunningApps() -> [AppDescriptor] {
        let apps = Self.excludingUseMac(regularApps(), selfPid: selfPid)
        rememberExternalFrontmost(in: apps)
        return apps
    }

    /// Every running GUI app, UseMac included. Only target resolution reads it, to tell "names UseMac" apart
    /// from "not found"; everything an agent gets back goes through `listRunningApps()` or `resolveTarget`.
    private func regularApps(withWindowMetadata: Bool = true) -> [AppDescriptor] {
        let windowMap: [Int32: WindowMetadata] = withWindowMetadata ? collectWindowMetadataByPid() : [:]
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

        return descriptors
    }

    private func rememberExternalFrontmost(in apps: [AppDescriptor]) {
        if let activeExternal = apps.first(where: { $0.isActive && !isUseMacApp($0) }) {
            lock.lock()
            lastExternalFrontmostApp = activeExternal
            lock.unlock()
        }
    }

    // MARK: - UseMac is never a target

    /// True for this process, and for any app with UseMac's bundle ID (the app, seen from a `--standalone` CLI).
    public static func isUseMac(
        pid: Int32,
        bundleId: String?,
        selfPid: Int32,
        selfBundleId: String = WorkspaceMonitor.useMacBundleId
    ) -> Bool {
        if pid == selfPid { return true }
        guard let bundleId else { return false }
        return bundleId.lowercased() == selfBundleId.lowercased()
    }

    public static func excludingUseMac(
        _ apps: [AppDescriptor],
        selfPid: Int32,
        selfBundleId: String = WorkspaceMonitor.useMacBundleId
    ) -> [AppDescriptor] {
        apps.filter { !isUseMac(pid: $0.pid, bundleId: $0.bundleId, selfPid: selfPid, selfBundleId: selfBundleId) }
    }

    /// Resolves `query` against `apps` (which may include UseMac). A query that names UseMac, directly or
    /// because UseMac is the app it matches, is `.useMac` and never falls through to another app.
    public static func matchQuery(
        _ query: String,
        in apps: [AppDescriptor],
        selfPid: Int32,
        selfBundleId: String = WorkspaceMonitor.useMacBundleId
    ) -> AppQueryMatch {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        let isSelf: (AppDescriptor) -> Bool = {
            isUseMac(pid: $0.pid, bundleId: $0.bundleId, selfPid: selfPid, selfBundleId: selfBundleId)
        }

        if let pid = Int32(trimmed) {
            if pid == selfPid { return .useMac }
            guard let app = apps.first(where: { $0.pid == pid }) else { return .notFound }
            return isSelf(app) ? .useMac : .app(app)
        }

        // UseMac is not in `apps` while its windows are closed (it then runs as an accessory app).
        let needle = trimmed.lowercased()
        if needle == selfBundleId.lowercased() || needle == useMacAppName.lowercased() {
            return .useMac
        }

        guard let match = matchApp(query: trimmed, in: apps) else { return .notFound }
        return isSelf(match) ? .useMac : .app(match)
    }

    /// True when `query` names UseMac itself. Cheap: it skips window metadata.
    public func namesUseMac(_ query: String?) -> Bool {
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return Self.matchQuery(query, in: regularApps(withWindowMetadata: false), selfPid: selfPid) == .useMac
    }

    /// Whether a request's target app was guessed. That is the case when neither the request nor any of its steps
    /// named an app and no app is paired, so UseMac fell back to the app in front, which is usually the user's own.
    /// The live preview never shows work on a guessed target.
    public static func isGuessedTarget(requestApp: String?, stepApps: [String?] = [], hasPairedApp: Bool) -> Bool {
        let names: (String?) -> Bool = { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        if names(requestApp) || stepApps.contains(where: names) { return false }
        return !hasPairedApp
    }

    public func isGuessedTarget(requestApp: String?, stepApps: [String?] = []) -> Bool {
        Self.isGuessedTarget(requestApp: requestApp, stepApps: stepApps, hasPairedApp: getPairedApp() != nil)
    }

    /// True when `pid` is UseMac (this process, or the app seen from a `--standalone` CLI).
    public func isUseMacProcess(pid: Int32) -> Bool {
        Self.isUseMac(
            pid: pid,
            bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            selfPid: selfPid
        )
    }

    private func isUseMacApp(_ app: AppDescriptor) -> Bool {
        Self.isUseMac(pid: app.pid, bundleId: app.bundleId, selfPid: selfPid)
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

        var resolved: AppDescriptor?
        if case .app(let app) = Self.matchQuery(query, in: regularApps(), selfPid: selfPid) {
            resolved = app
        }
        lock.lock()
        pairedApp = resolved
        lock.unlock()
        return resolved
    }

    public func getPairedApp() -> AppDescriptor? {
        lock.lock()
        let currentPaired = pairedApp
        lock.unlock()

        guard let currentPaired, !isUseMacApp(currentPaired) else { return nil }
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
    /// Never returns UseMac itself; use `resolveTarget(query:)` to tell that case apart from "not found".
    public func resolveApp(query: String?) -> AppDescriptor? {
        guard case .app(let app) = resolveTarget(query: query) else { return nil }
        return app
    }

    /// Like `resolveApp(query:)`, but reports `.useMac` when the query names UseMac itself.
    public func resolveTarget(query: String?) -> AppQueryMatch {
        let match = resolveTargetWithoutWindow(query: query)
        guard case .app(let app) = match else { return match }
        // Belt and braces: whatever path produced it, UseMac is never handed out as a target.
        if isUseMacApp(app) { return .useMac }
        return .app(Self.withTargetWindow(app))
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

    private func resolveTargetWithoutWindow(query: String?) -> AppQueryMatch {
        if let query {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let apps = regularApps()
                rememberExternalFrontmost(in: apps)
                return Self.matchQuery(trimmed, in: apps, selfPid: selfPid)
            }
        }
        guard let app = fallbackApp() else { return .notFound }
        return .app(app)
    }

    /// The target when the agent names no app: the paired app, else the last external frontmost app, else
    /// the frontmost app. Only ever picks from `listRunningApps()`, which leaves UseMac out.
    private func fallbackApp() -> AppDescriptor? {
        let apps = listRunningApps()

        lock.lock()
        let currentPaired = pairedApp
        let lastExternal = lastExternalFrontmostApp
        lock.unlock()

        if let currentPaired, !isUseMacApp(currentPaired) {
            if let fresh = apps.first(where: { $0.pid == currentPaired.pid }) {
                return fresh
            }
            if let running = NSRunningApplication(processIdentifier: currentPaired.pid), !running.isTerminated {
                return currentPaired
            }
        }

        if let lastExternal, !isUseMacApp(lastExternal) {
            if let fresh = apps.first(where: { $0.pid == lastExternal.pid }) {
                return fresh
            }
            if let running = NSRunningApplication(processIdentifier: lastExternal.pid), !running.isTerminated {
                return lastExternal
            }
        }

        return apps.first(where: { $0.isActive }) ?? apps.first
    }

    private static func matchApp(query: String, in apps: [AppDescriptor]) -> AppDescriptor? {
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
