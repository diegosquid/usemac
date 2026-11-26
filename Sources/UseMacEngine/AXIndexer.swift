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
        indexer.recordChange(pid: pid)
    } else {
        indexer.markDirtyAll()
    }
}

/// Text matching shared by `ElementMatch` resolution (engine) and tests. Case- and diacritic-insensitive,
/// whitespace collapsed.
public enum ElementMatcher {
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func normalizeRole(_ role: String) -> String {
        let lower = role.lowercased()
        return lower.hasPrefix("ax") ? String(lower.dropFirst(2)) : lower
    }

    public static func matches(
        role: String,
        title: String?,
        description: String?,
        value: String?,
        match: ElementMatch
    ) -> Bool {
        guard !match.isEmpty else { return false }
        if let wantRole = match.role, !wantRole.isEmpty,
           normalizeRole(wantRole) != normalizeRole(role) {
            return false
        }
        let exact = match.exact == true
        func compare(_ candidates: [String?], _ needle: String?) -> Bool {
            guard let needle, !needle.isEmpty else { return true }
            let want = normalize(needle)
            return candidates.contains { candidate in
                guard let candidate, !candidate.isEmpty else { return false }
                let have = normalize(candidate)
                return exact ? have == want : have.contains(want)
            }
        }
        return compare([title, description], match.title)
            && compare([value], match.value)
            && compare([title, description, value], match.text)
    }
}

public final class AXIndexer: @unchecked Sendable {
    private struct CachedAppState {
        var snapshot: WindowSnapshot
        /// Every element id known for the app (merged across observes), so ids from a deep observe keep
        /// working after a shallow post-action observe.
        var elementMap: [String: AXUIElement]
        var nodeMap: [String: ElementNode]
        var dirty: Bool
        var lastTimestampMs: Int64
        /// Window the snapshot was taken from (for the stale-snapshot check).
        var windowId: UInt32?
        var windowTitle: String?
        /// Web areas and scroll areas of the snapshot, with the range of `snapshot.elements` inside each.
        var scrollContainers: [ScrollContainer] = []
    }

    /// Stable ids: the same AX element keeps its `@eN` id for the lifetime of the app's cache.
    private struct IdRegistry {
        var idByElement: [AXUIElement: String] = [:]
        var nextIndex: Int = 1

        mutating func id(for element: AXUIElement) -> String {
            if let existing = idByElement[element] {
                return existing
            }
            let id = "@e\(nextIndex)"
            nextIndex += 1
            idByElement[element] = id
            return id
        }
    }

    private struct TraversalContext {
        let maxDepth: Int
        let maxElements: Int
        let maxOffscreen: Int
        let includeOffscreen: Bool
        let focusedElement: AXUIElement?
        let viewport: ScreenRect?
        var registry: IdRegistry
        var elements: [ElementNode] = []
        var elementMap: [String: AXUIElement] = [:]
        var nodeMap: [String: ElementNode] = [:]
        var visited: Set<AXUIElement> = []
        var focusedElementId: String?
        var visibleCount: Int = 0
        var offscreenCount: Int = 0
        var scrollContainers: [ScrollContainer] = []
    }

    public struct SnapshotContext: Equatable, Sendable {
        public var windowId: UInt32?
        public var windowTitle: String?
    }

    private static let hotCacheMaxAgeMs: Int64 = 1200
    /// Above this many remembered ids an app's registry is rebuilt from the latest observe.
    private static let maxRememberedIds = 8000
    private static let flattenRoles: Set<String> = [
        "AXGroup",
        "AXSplitGroup",
        "AXScrollArea",
        "AXLayoutArea"
    ]
    /// Roles worth listing even when scrolled out of view and unlabeled.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton", "AXCell", "AXRow", "AXTab",
        "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXSwitch", "AXToggle"
    ]
    private static let interactiveActions: Set<String> = ["AXPress", "AXConfirm", "AXOpen", "AXPick"]
    private static let observedNotifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXSheetCreatedNotification,
        kAXDrawerCreatedNotification,
        kAXValueChangedNotification,
        kAXTitleChangedNotification,
        kAXSelectedTextChangedNotification,
        kAXSelectedChildrenChangedNotification,
        kAXSelectedRowsChangedNotification,
        kAXRowCountChangedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXLayoutChangedNotification,
        "AXLoadComplete",
        "AXExpandedChanged"
    ]

    private let lock = NSLock()
    private var cache: [Int32: CachedAppState] = [:]
    private var registries: [Int32: IdRegistry] = [:]
    private var observers: [Int32: AXObserver] = [:]
    private var changeCounters: [Int32: UInt64] = [:]

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
        accessibilityGranted: Bool = true,
        includeOffscreen: Bool = true
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
                if !includeOffscreen {
                    snapshot.elements = snapshot.elements.filter { $0.offscreen != true }
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
                lastTimestampMs: completedMs,
                windowId: nil,
                windowTitle: app.windowTitle
            )
            lock.unlock()

            return snapshot
        }

        ensureObserver(for: app.pid)

        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)

        let focusedElement = copyElementAttribute(axApp, attribute: kAXFocusedUIElementAttribute)
        let root = rootWindow(of: axApp)
        let rootFrame = root.flatMap { copyFrame($0) }
        let rootWindowId = root.flatMap { WindowResolver.windowID(of: $0) }.map { UInt32($0) }
        let rootTitle = root.flatMap { copyStringAttribute($0, attribute: kAXTitleAttribute) }

        lock.lock()
        let registry = registries[app.pid] ?? IdRegistry()
        lock.unlock()

        let boundedDepth = max(1, maxDepth)
        let boundedElements = max(1, maxElements)
        var ctx = TraversalContext(
            maxDepth: boundedDepth,
            maxElements: boundedElements,
            maxOffscreen: boundedElements,
            includeOffscreen: includeOffscreen,
            focusedElement: focusedElement,
            viewport: rootFrame,
            registry: registry
        )

        traverse(element: root ?? axApp, depth: 0, context: &ctx)

        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let completedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let prevSnapshot = previousSnapshot(for: app.pid)
        let diff = includeDiff ? computeDiff(previous: prevSnapshot, current: ctx.elements) : nil

        var describedApp = app
        if describedApp.windowId == nil {
            describedApp.windowId = rootWindowId
        }
        let snapshot = WindowSnapshot(
            app: describedApp,
            timestampMs: completedMs,
            latencyMs: latencyMs,
            fromHotCache: false,
            focusedElementId: ctx.focusedElementId,
            elements: ctx.elements,
            diff: diff
        )

        lock.lock()
        var finalRegistry = ctx.registry
        var elementMap = cache[app.pid]?.elementMap ?? [:]
        var nodeMap = cache[app.pid]?.nodeMap ?? [:]
        elementMap.merge(ctx.elementMap) { _, new in new }
        nodeMap.merge(ctx.nodeMap) { _, new in new }
        if finalRegistry.idByElement.count > Self.maxRememberedIds || elementMap.count > Self.maxRememberedIds {
            // Forget elements not seen in this observe, but keep numbering going so old ids are never reused.
            var trimmed = IdRegistry()
            trimmed.nextIndex = finalRegistry.nextIndex
            for (id, element) in ctx.elementMap {
                trimmed.idByElement[element] = id
            }
            finalRegistry = trimmed
            elementMap = ctx.elementMap
            nodeMap = ctx.nodeMap
        }
        registries[app.pid] = finalRegistry
        cache[app.pid] = CachedAppState(
            snapshot: snapshot,
            elementMap: elementMap,
            nodeMap: nodeMap,
            dirty: false,
            lastTimestampMs: completedMs,
            windowId: rootWindowId,
            windowTitle: rootTitle,
            scrollContainers: ctx.scrollContainers
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

    /// Re-reads a known element's attributes now (frame, value, offscreen) instead of trusting the snapshot.
    /// Returns nil when the id is unknown or the element no longer exists.
    public func liveNode(for id: String, pid: Int32) -> (element: AXUIElement, node: ElementNode)? {
        guard let element = element(for: id, pid: pid) else { return nil }
        guard let role = copyStringAttribute(element, attribute: kAXRoleAttribute) else { return nil }
        let node = makeNode(id: id, element: element, role: role, focusedElement: nil, viewport: currentViewport(pid: pid))
        lock.lock()
        cache[pid]?.nodeMap[id] = node
        lock.unlock()
        return (element, node)
    }

    /// Registers an element found outside an observe (e.g. by `match`) and returns its stable id and node.
    public func register(element: AXUIElement, pid: Int32) -> (id: String, node: ElementNode)? {
        guard let role = copyStringAttribute(element, attribute: kAXRoleAttribute) else { return nil }
        lock.lock()
        var registry = registries[pid] ?? IdRegistry()
        let id = registry.id(for: element)
        registries[pid] = registry
        lock.unlock()
        let node = makeNode(id: id, element: element, role: role, focusedElement: nil, viewport: currentViewport(pid: pid))
        lock.lock()
        if cache[pid] != nil {
            cache[pid]?.elementMap[id] = element
            cache[pid]?.nodeMap[id] = node
        } else {
            cache[pid] = CachedAppState(
                snapshot: WindowSnapshot(app: AppDescriptor(pid: pid, name: ""), timestampMs: 0, latencyMs: 0),
                elementMap: [id: element],
                nodeMap: [id: node],
                dirty: true,
                lastTimestampMs: 0,
                windowId: nil,
                windowTitle: nil
            )
        }
        lock.unlock()
        return (id, node)
    }

    /// Finds elements matching `match` in the app's focused window right now, in tree order. Matches are
    /// registered so their ids work in later steps.
    public func find(
        pid: Int32,
        match: ElementMatch,
        maxDepth: Int = 60,
        budget: Int = 6000,
        limit: Int = 50
    ) -> [(id: String, element: AXUIElement, node: ElementNode)] {
        guard !match.isEmpty else { return [] }
        ensureObserver(for: pid)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let root = rootWindow(of: axApp) else { return [] }

        var hits: [AXUIElement] = []
        var visited: Set<AXUIElement> = []
        var remaining = budget
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, remaining > 0, hits.count < limit, !visited.contains(element) else { return }
            visited.insert(element)
            remaining -= 1
            let role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? "AXUnknown"
            if ElementMatcher.matches(
                role: role,
                title: copyStringAttribute(element, attribute: kAXTitleAttribute),
                description: copyStringAttribute(element, attribute: kAXDescriptionAttribute),
                value: copyFullValue(element),
                match: match
            ) {
                hits.append(element)
            }
            guard depth < maxDepth else { return }
            for child in copyElementArrayAttribute(element, attribute: kAXChildrenAttribute) ?? [] {
                walk(child, depth: depth + 1)
                if remaining <= 0 || hits.count >= limit { break }
            }
        }
        walk(root, depth: 0)

        return hits.compactMap { element in
            guard let registered = register(element: element, pid: pid) else { return nil }
            return (registered.id, element, registered.node)
        }
    }

    /// Elements from the last observe of `pid` (used to probe whether a scroll moved anything).
    public func latestNodes(pid: Int32) -> [ElementNode] {
        lock.lock()
        defer { lock.unlock() }
        return cache[pid]?.snapshot.elements ?? []
    }

    /// Elements from the last observe of `pid` with the web areas and scroll areas they sit in (indexes into
    /// `nodes`), read together so they always match.
    public func latestScrollLayout(pid: Int32) -> (nodes: [ElementNode], containers: [ScrollContainer]) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = cache[pid] else { return ([], []) }
        return (state.snapshot.elements, state.scrollContainers)
    }

    /// Window and title the last observe of `pid` was taken from.
    public func snapshotContext(pid: Int32) -> SnapshotContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = cache[pid] else { return nil }
        return SnapshotContext(windowId: state.windowId, windowTitle: state.windowTitle)
    }

    /// The app's current focused window id and title (for the stale-snapshot check).
    public func currentContext(pid: Int32) -> SnapshotContext? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let root = rootWindow(of: axApp) else { return nil }
        return SnapshotContext(
            windowId: WindowResolver.windowID(of: root).map { UInt32($0) },
            windowTitle: copyStringAttribute(root, attribute: kAXTitleAttribute)
        )
    }

    /// Monotonic count of AX notifications received for `pid`. Used to tell whether an action changed anything.
    public func changeCount(pid: Int32) -> UInt64 {
        ensureObserver(for: pid)
        lock.lock()
        defer { lock.unlock() }
        return changeCounters[pid] ?? 0
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

    fileprivate func recordChange(pid: Int32) {
        lock.lock()
        cache[pid]?.dirty = true
        changeCounters[pid, default: 0] &+= 1
        lock.unlock()
    }

    fileprivate func markDirtyAll() {
        lock.lock()
        for key in cache.keys {
            cache[key]?.dirty = true
            changeCounters[key, default: 0] &+= 1
        }
        lock.unlock()
    }

    private func previousSnapshot(for pid: Int32) -> WindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return cache[pid]?.snapshot
    }

    private func rootWindow(of axApp: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        if AXUIElementGetPid(axApp, &pid) == .success, let pinned = WindowResolver.pinnedTitle(pid: pid) {
            // A pinned window that is gone must not silently fall back to another window.
            return WindowResolver.window(pid: pid, titleContains: pinned)
        }
        if let focusedWindow = copyElementAttribute(axApp, attribute: kAXFocusedWindowAttribute) {
            return focusedWindow
        }
        if let windows = copyElementArrayAttribute(axApp, attribute: kAXWindowsAttribute), let first = windows.first {
            return first
        }
        return nil
    }

    private func currentViewport(pid: Int32) -> ScreenRect? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        return rootWindow(of: axApp).flatMap { copyFrame($0) }
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
        guard depth <= context.maxDepth, context.visibleCount < context.maxElements else {
            return
        }
        guard !context.visited.contains(element) else {
            return
        }
        context.visited.insert(element)

        let role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? "AXUnknown"
        let title = copyNonEmptyTitle(element)
        let value = copyClippedValueAttribute(element)
        let actions = copyActionNames(element)

        let isEmptyLayoutContainer = Self.flattenRoles.contains(role)
            && (title == nil || title?.isEmpty == true)
            && (value == nil || value?.isEmpty == true)
            && !actions.contains("AXPress")

        var knownFrame: ScreenRect?
        if !isEmptyLayoutContainer {
            let frame = copyFrame(element)
            knownFrame = frame
            let offscreen = Self.isOffscreen(frame: frame, viewport: context.viewport)
            let meaningful = title != nil || value != nil
                || Self.interactiveRoles.contains(role)
                || !Self.interactiveActions.isDisjoint(with: actions)
            let include = offscreen
                ? (context.includeOffscreen && meaningful && context.offscreenCount < context.maxOffscreen)
                : true
            if include {
                let id = context.registry.id(for: element)
                let node = makeNode(
                    id: id,
                    element: element,
                    role: role,
                    focusedElement: context.focusedElement,
                    viewport: context.viewport,
                    prefetched: (title, value, actions, frame)
                )
                context.elements.append(node)
                context.elementMap[id] = element
                context.nodeMap[id] = node
                if offscreen {
                    context.offscreenCount += 1
                } else {
                    context.visibleCount += 1
                }
                if node.focused && (context.focusedElementId == nil || role != "AXWindow") {
                    context.focusedElementId = id
                }
            }
        }

        guard depth < context.maxDepth, context.visibleCount < context.maxElements else {
            return
        }

        let descendantsStart = context.elements.count
        if let children = copyElementArrayAttribute(element, attribute: kAXChildrenAttribute) {
            for child in children {
                traverse(element: child, depth: depth + 1, context: &context)
                if context.visibleCount >= context.maxElements {
                    break
                }
            }
        }
        if ScrollFallback.containerRoles.contains(role) {
            // Recorded even when the container itself is flattened out of the list (an unlabeled scroll area).
            context.scrollContainers.append(ScrollContainer(
                role: role,
                frame: knownFrame ?? copyFrame(element),
                descendants: descendantsStart..<context.elements.count,
                depth: depth
            ))
        }
    }

    /// Chrome clips AX bounds to the visible viewport, so elements scrolled out of a list or page come back
    /// with no frame or a zero size; elements outside the window are offscreen too.
    static func isOffscreen(frame: ScreenRect?, viewport: ScreenRect?) -> Bool {
        guard let frame, frame.width >= 2, frame.height >= 2 else {
            return true
        }
        guard let viewport else {
            return false
        }
        let a = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let b = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
        return !a.intersects(b)
    }

    private func makeNode(
        id: String,
        element: AXUIElement,
        role: String,
        focusedElement: AXUIElement?,
        viewport: ScreenRect?,
        prefetched: (title: String?, value: String?, actions: [String], frame: ScreenRect?)? = nil
    ) -> ElementNode {
        let title: String?
        let value: String?
        let actions: [String]
        let frame: ScreenRect?
        if let prefetched {
            (title, value, actions, frame) = prefetched
        } else {
            title = copyNonEmptyTitle(element)
            value = copyClippedValueAttribute(element)
            actions = copyActionNames(element)
            frame = copyFrame(element)
        }
        let isFocusedAttr = copyBoolAttribute(element, attribute: kAXFocusedAttribute) ?? false
        let isFocusedRef = focusedElement.map { CFEqual(element, $0) } ?? false
        let offscreen = Self.isOffscreen(frame: frame, viewport: viewport)
        return ElementNode(
            id: id,
            role: role,
            title: title,
            value: value,
            roleDescription: copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute),
            enabled: copyBoolAttribute(element, attribute: kAXEnabledAttribute) ?? true,
            focused: isFocusedAttr || isFocusedRef,
            frame: frame ?? ScreenRect(x: 0, y: 0, width: 0, height: 0),
            actions: actions,
            offscreen: offscreen ? true : nil
        )
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

    private func copyFullValue(_ element: AXUIElement) -> String? {
        guard let ref = copyAttribute(element, attribute: kAXValueAttribute) else { return nil }
        if let str = ref as? String { return str }
        if let num = ref as? NSNumber { return num.stringValue }
        return nil
    }

    private func copyClippedValueAttribute(_ element: AXUIElement) -> String? {
        guard let text = copyFullValue(element), !text.isEmpty else { return nil }
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

        let oldById = Dictionary(previous.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newById = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

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
