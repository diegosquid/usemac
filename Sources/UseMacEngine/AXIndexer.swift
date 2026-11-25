import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

private func axObserverNotificationCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let indexer = Unmanaged<AXIndexer>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    if AXUIElementGetPid(element, &pid) == .success, pid > 0 {
        indexer.markDirty(pid: pid)
    } else {
        indexer.markDirtyAll()
    }
}

public final class AXIndexer: @unchecked Sendable {
    private struct CachedAppState {
        var snapshot: WindowSnapshot
        var elementMap: [String: AXUIElement]
        var nodeMap: [String: ElementNode]
        var dirty: Bool
        var lastTimestampMs: Int64
    }

    private struct TraversalContext {
        let maxDepth: Int
        let maxElements: Int
        let focusedElement: AXUIElement?
        var elements: [ElementNode] = []
        var elementMap: [String: AXUIElement] = [:]
        var nodeMap: [String: ElementNode] = [:]
        var visited: Set<AXUIElement> = []
        var focusedElementId: String?
        var nextIndex: Int = 1
    }

    private static let hotCacheMaxAgeMs: Int64 = 1200
    private static let flattenRoles: Set<String> = [
        "AXGroup",
        "AXSplitGroup",
        "AXScrollArea",
        "AXLayoutArea"
    ]
    private static let observedNotifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXValueChangedNotification,
        kAXUIElementDestroyedNotification
    ]

    private let lock = NSLock()
    private var cache: [Int32: CachedAppState] = [:]
    private var observers: [Int32: AXObserver] = [:]

    public init() {}

    deinit {
        lock.lock()
        let activeObservers = Array(observers.values)
        observers.removeAll()
        lock.unlock()

        for observer in activeObservers {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    public func observe(
        app: AppDescriptor,
        maxDepth: Int = 10,
        maxElements: Int = 220,
        useCache: Bool = true,
        includeDiff: Bool = true,
        accessibilityGranted: Bool = true
    ) -> WindowSnapshot {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let checkNowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if useCache {
            lock.lock()
            let cached = cache[app.pid]
            lock.unlock()

            if let cached, !cached.dirty, (checkNowMs - cached.lastTimestampMs) < Self.hotCacheMaxAgeMs {
                let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                var snapshot = cached.snapshot
                snapshot.app = app
                snapshot.fromHotCache = true
                snapshot.latencyMs = latencyMs
                if !includeDiff {
                    snapshot.diff = nil
                }
                return snapshot
            }
        }

        if !accessibilityGranted {
            let fallbackRect = app.windowBounds ?? ScreenRect(x: 0, y: 0, width: 800, height: 600)
            let fallbackNode = ElementNode(
                id: "@e1",
                role: "AXWindow",
                title: app.windowTitle ?? app.name,
                value: nil,
                roleDescription: "window",
                enabled: true,
                focused: true,
                frame: fallbackRect,
                actions: []
            )
            let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            let completedMs = Int64(Date().timeIntervalSince1970 * 1000)
            let prevSnapshot = previousSnapshot(for: app.pid)
            let diff = includeDiff ? computeDiff(previous: prevSnapshot, current: [fallbackNode]) : nil

            let snapshot = WindowSnapshot(
                app: app,
                timestampMs: completedMs,
                latencyMs: latencyMs,
                fromHotCache: false,
                focusedElementId: "@e1",
                elements: [fallbackNode],
                diff: diff
            )

            lock.lock()
            cache[app.pid] = CachedAppState(
                snapshot: snapshot,
                elementMap: [:],
                nodeMap: ["@e1": fallbackNode],
                dirty: false,
                lastTimestampMs: completedMs
            )
            lock.unlock()

            return snapshot
        }

        ensureObserver(for: app.pid)

        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)

        let focusedElement = copyElementAttribute(axApp, attribute: kAXFocusedUIElementAttribute)
        var roots: [AXUIElement] = []

        if let focusedWindow = copyElementAttribute(axApp, attribute: kAXFocusedWindowAttribute) {
            roots.append(focusedWindow)
        } else if let windows = copyElementArrayAttribute(axApp, attribute: kAXWindowsAttribute),
                  let firstWindow = windows.first {
            roots.append(firstWindow)
        } else {
            roots.append(axApp)
        }

        let boundedDepth = max(1, maxDepth)
        let boundedElements = max(1, maxElements)
        var ctx = TraversalContext(
            maxDepth: boundedDepth,
            maxElements: boundedElements,
            focusedElement: focusedElement
        )

        for root in roots {
            traverse(element: root, depth: 0, context: &ctx)
            if ctx.elements.count >= ctx.maxElements {
                break
            }
        }

        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let completedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let prevSnapshot = previousSnapshot(for: app.pid)
        let diff = includeDiff ? computeDiff(previous: prevSnapshot, current: ctx.elements) : nil

        let snapshot = WindowSnapshot(
            app: app,
            timestampMs: completedMs,
            latencyMs: latencyMs,
            fromHotCache: false,
            focusedElementId: ctx.focusedElementId,
            elements: ctx.elements,
            diff: diff
        )

        lock.lock()
        cache[app.pid] = CachedAppState(
            snapshot: snapshot,
            elementMap: ctx.elementMap,
            nodeMap: ctx.nodeMap,
            dirty: false,
            lastTimestampMs: completedMs
        )
        lock.unlock()

        return snapshot
    }

    public func element(for id: String, pid: Int32) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return cache[pid]?.elementMap[id]
    }

    public func node(for id: String, pid: Int32) -> ElementNode? {
        lock.lock()
        defer { lock.unlock() }
        return cache[pid]?.nodeMap[id]
    }

    public func node(for id: String) -> (pid: Int32, node: ElementNode)? {
        lock.lock()
        defer { lock.unlock() }
        for (pid, state) in cache {
            if let node = state.nodeMap[id] {
                return (pid, node)
            }
        }
        return nil
    }

    public func invalidate(pid: Int32? = nil) {
        lock.lock()
        if let pid {
            cache[pid]?.dirty = true
        } else {
            for key in cache.keys {
                cache[key]?.dirty = true
            }
        }
        lock.unlock()
    }

    fileprivate func markDirty(pid: Int32) {
        lock.lock()
        cache[pid]?.dirty = true
        lock.unlock()
    }

    fileprivate func markDirtyAll() {
        lock.lock()
        for key in cache.keys {
            cache[key]?.dirty = true
        }
        lock.unlock()
    }

    private func previousSnapshot(for pid: Int32) -> WindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return cache[pid]?.snapshot
    }

    private func ensureObserver(for pid: Int32) {
        lock.lock()
        let alreadyRegistered = observers[pid] != nil
        lock.unlock()
        if alreadyRegistered { return }

        var observerRef: AXObserver?
        let createErr = AXObserverCreate(pid, axObserverNotificationCallback, &observerRef)
        guard createErr == .success, let observer = observerRef else {
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for notification in Self.observedNotifications {
            _ = AXObserverAddNotification(observer, axApp, notification as CFString, refcon)
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        lock.lock()
        if observers[pid] == nil {
            observers[pid] = observer
        } else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        lock.unlock()
    }

    private func traverse(element: AXUIElement, depth: Int, context: inout TraversalContext) {
        guard depth <= context.maxDepth, context.elements.count < context.maxElements else {
            return
        }
        guard !context.visited.contains(element) else {
            return
        }
        context.visited.insert(element)

        let role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? "AXUnknown"
        let title = copyNonEmptyTitle(element)
        let value = copyClippedValueAttribute(element)
        let roleDescription = copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute)
        let enabled = copyBoolAttribute(element, attribute: kAXEnabledAttribute) ?? true
        let isFocusedAttr = copyBoolAttribute(element, attribute: kAXFocusedAttribute) ?? false
        let isFocusedRef = context.focusedElement.map { CFEqual(element, $0) } ?? false
        let focused = isFocusedAttr || isFocusedRef
        let frame = copyFrame(element)
        let actions = copyActionNames(element)

        let isEmptyLayoutContainer = Self.flattenRoles.contains(role)
            && (title == nil || title?.isEmpty == true)
            && (value == nil || value?.isEmpty == true)
            && !actions.contains("AXPress")

        if !isEmptyLayoutContainer, let frame, frame.width >= 2, frame.height >= 2 {
            let id = "@e\(context.nextIndex)"
            context.nextIndex += 1

            let node = ElementNode(
                id: id,
                role: role,
                title: title,
                value: value,
                roleDescription: roleDescription,
                enabled: enabled,
                focused: focused,
                frame: frame,
                actions: actions
            )

            context.elements.append(node)
            context.elementMap[id] = element
            context.nodeMap[id] = node

            if focused && (context.focusedElementId == nil || role != "AXWindow") {
                context.focusedElementId = id
            }
        }

        guard depth < context.maxDepth, context.elements.count < context.maxElements else {
            return
        }

        if let children = copyElementArrayAttribute(element, attribute: kAXChildrenAttribute) {
            for child in children {
                traverse(element: child, depth: depth + 1, context: &context)
                if context.elements.count >= context.maxElements {
                    break
                }
            }
        }
    }

    private func copyAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        guard let ref = copyAttribute(element, attribute: attribute) else { return nil }
        return ref as? String
    }

    private func copyNonEmptyTitle(_ element: AXUIElement) -> String? {
        if let title = copyStringAttribute(element, attribute: kAXTitleAttribute), !title.isEmpty {
            return title
        }
        if let desc = copyStringAttribute(element, attribute: kAXDescriptionAttribute), !desc.isEmpty {
            return desc
        }
        return nil
    }

    private func copyClippedValueAttribute(_ element: AXUIElement) -> String? {
        guard let ref = copyAttribute(element, attribute: kAXValueAttribute) else { return nil }
        let raw: String?
        if let str = ref as? String {
            raw = str
        } else if let num = ref as? NSNumber {
            raw = num.stringValue
        } else {
            raw = nil
        }

        guard let text = raw, !text.isEmpty else { return nil }
        if text.count > 140 {
            return String(text.prefix(140))
        }
        return text
    }

    private func copyBoolAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        guard let ref = copyAttribute(element, attribute: attribute) else { return nil }
        if let num = ref as? NSNumber {
            return num.boolValue
        }
        return nil
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let ref = copyAttribute(element, attribute: attribute) else { return nil }
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        guard let ref = copyAttribute(element, attribute: attribute) else { return nil }
        guard let array = ref as? [AnyObject] else { return nil }
        var result: [AXUIElement] = []
        result.reserveCapacity(array.count)
        for item in array {
            if CFGetTypeID(item) == AXUIElementGetTypeID() {
                result.append(unsafeBitCast(item, to: AXUIElement.self))
            }
        }
        return result
    }

    private func copyFrame(_ element: AXUIElement) -> ScreenRect? {
        guard let posRef = copyAttribute(element, attribute: kAXPositionAttribute),
              let sizeRef = copyAttribute(element, attribute: kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let posVal = unsafeBitCast(posRef, to: AXValue.self)
        let sizeVal = unsafeBitCast(sizeRef, to: AXValue.self)

        var point = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posVal, .cgPoint, &point),
              AXValueGetValue(sizeVal, .cgSize, &size) else {
            return nil
        }

        return ScreenRect(
            x: Double(point.x),
            y: Double(point.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        let err = AXUIElementCopyActionNames(element, &namesRef)
        guard err == .success, let names = namesRef as? [String] else {
            return []
        }
        return names
    }

    private func computeDiff(previous: WindowSnapshot?, current: [ElementNode]) -> SnapshotDiff? {
        guard let previous else { return nil }

        let oldById = Dictionary(uniqueKeysWithValues: previous.elements.map { ($0.id, $0) })
        let newById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        var added: [ElementNode] = []
        var changed: [ElementNode] = []
        var removedIds: [String] = []

        for node in current {
            if let old = oldById[node.id] {
                if old != node {
                    changed.append(node)
                }
            } else {
                added.append(node)
            }
        }

        for oldNode in previous.elements where newById[oldNode.id] == nil {
            removedIds.append(oldNode.id)
        }

        let summary: String
        if added.isEmpty && removedIds.isEmpty && changed.isEmpty {
            summary = "no changes"
        } else {
            summary = "+\(added.count) added, -\(removedIds.count) removed, ~\(changed.count) changed"
        }

        return SnapshotDiff(
            added: added,
            removedIds: removedIds,
            changed: changed,
            summary: summary
        )
    }
}
