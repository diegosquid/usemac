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

    /// Role matching for server-side `ElementFilter`, also accepting compact short role aliases
    /// (`btn`, `input`, `select`, `text`, `img`).
    public static func matchesFilterRole(_ wanted: String, actual: String) -> Bool {
        let normWant = normalizeRole(wanted.trimmingCharacters(in: .whitespacesAndNewlines))
        let normActual = normalizeRole(actual)
        if normWant == normActual { return true }
        switch normWant {
        case "btn": return normActual == "button"
        case "input": return normActual == "textfield" || normActual == "searchfield"
        case "select": return normActual == "popupbutton" || normActual == "combobox"
        case "text": return normActual == "statictext"
        case "img": return normActual == "image"
        default: return false
        }
    }

    public static func matches(
        role: String,
        title: String?,
        description: String?,
        value: String?,
        match: ElementMatch
    ) -> Bool {
        matchesLazy(
            role: role,
            match: match,
            title: { title },
            description: { description },
            value: { value }
        )
    }

    /// Short-circuiting variant of `matches`: checks `match.role` FIRST before calling any attribute
    /// closures, and only invokes `value()` when `match.value != nil || match.text != nil`.
    public static func matchesLazy(
        role: String,
        match: ElementMatch,
        title fetchTitle: () -> String?,
        description fetchDescription: () -> String?,
        value fetchValue: () -> String?
    ) -> Bool {
        guard !match.isEmpty else { return false }
        if let wantRole = match.role, !wantRole.isEmpty,
           normalizeRole(wantRole) != normalizeRole(role) {
            return false
        }

        let exact = match.exact == true
        var cachedTitle: String??
        var cachedDesc: String??
        var cachedValue: String??

        func getTitle() -> String? {
            if let existing = cachedTitle { return existing }
            let resolved = fetchTitle()
            cachedTitle = resolved
            return resolved
        }

        func getDescription() -> String? {
            if let existing = cachedDesc { return existing }
            let resolved = fetchDescription()
            cachedDesc = resolved
            return resolved
        }

        func getValue() -> String? {
            if let existing = cachedValue { return existing }
            let resolved = fetchValue()
            cachedValue = resolved
            return resolved
        }

        func matchesCandidate(_ candidate: String?, want: String) -> Bool {
            guard let candidate, !candidate.isEmpty else { return false }
            let have = normalize(candidate)
            return exact ? have == want : have.contains(want)
        }

        if let needTitle = match.title, !needTitle.isEmpty {
            let want = normalize(needTitle)
            if !matchesCandidate(getTitle(), want: want) && !matchesCandidate(getDescription(), want: want) {
                return false
            }
        }

        if let needValue = match.value, !needValue.isEmpty {
            let want = normalize(needValue)
            if !matchesCandidate(getValue(), want: want) {
                return false
            }
        }

        if let needText = match.text, !needText.isEmpty {
            let want = normalize(needText)
            if !matchesCandidate(getTitle(), want: want)
                && !matchesCandidate(getDescription(), want: want)
                && !matchesCandidate(getValue(), want: want) {
                return false
            }
        }

        return true
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
        /// Whether offscreen elements were collected in `snapshot`.
        var includedOffscreen: Bool = false
        /// The `maxElements` budget used for `snapshot`.
        var observedMaxElements: Int = 220
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

    private struct BatchedNodeAttributes {
        var role: String
        var title: String?
        var description: String?
        var fullValue: String?
        var frame: ScreenRect?
        var focused: Bool?
        var enabled: Bool?
        var children: [AXUIElement]?
        var visibleChildren: [AXUIElement]?

        var nonEmptyTitle: String? {
            if let title, !title.isEmpty { return title }
            if let description, !description.isEmpty { return description }
            return nil
        }

        var clippedValue: String? {
            guard let fullValue, !fullValue.isEmpty else { return nil }
            if fullValue.count > 140 {
                return String(fullValue.prefix(140))
            }
            return fullValue
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
        var skippedOffscreenCount: Int = 0
        var scrollContainers: [ScrollContainer] = []
    }

    private struct ChangeWaiter {
        let id: UUID
        let sinceGeneration: UInt64
        let continuation: CheckedContinuation<Bool, Never>
        var timer: DispatchWorkItem?
    }

    public struct SnapshotContext: Equatable, Sendable {
        public var windowId: UInt32?
        public var windowTitle: String?

        public init(windowId: UInt32? = nil, windowTitle: String? = nil) {
            self.windowId = windowId
            self.windowTitle = windowTitle
        }
    }

    /// Frame deltas smaller than this (in points) are ignored in `computeDiff` to suppress layout/scroll jitter.
    static let diffFrameTolerancePx: Double = 5.0

    private static let hotCacheMaxAgeMs: Int64 = 1200
    /// Above this many remembered ids an app's registry is rebuilt from the latest observe.
    private static let maxRememberedIds = 8000
    private static let flattenRoles: Set<String> = [
        "AXGroup",
        "AXSplitGroup",
        "AXScrollArea",
        "AXLayoutArea"
    ]
    private static let visibleChildrenRoles: Set<String> = [
        "AXTable",
        "AXOutline",
        "AXScrollArea"
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

    // Batched attribute lists for `AXUIElementCopyMultipleAttributeValues` (1 Mach IPC per node;
    // intentionally excludes unused `kAXRoleDescriptionAttribute`).
    nonisolated(unsafe) private static let nodeOnlyAttributes: CFArray = [
        kAXRoleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXFocusedAttribute as CFString,
        kAXEnabledAttribute as CFString
    ] as CFArray

    nonisolated(unsafe) private static let traverseAttributesAll: CFArray = [
        kAXRoleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXFocusedAttribute as CFString,
        kAXEnabledAttribute as CFString,
        kAXChildrenAttribute as CFString
    ] as CFArray

    nonisolated(unsafe) private static let traverseAttributesWithVisible: CFArray = [
        kAXRoleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXFocusedAttribute as CFString,
        kAXEnabledAttribute as CFString,
        kAXChildrenAttribute as CFString,
        kAXVisibleChildrenAttribute as CFString
    ] as CFArray

    nonisolated(unsafe) private static let roleAndChildrenAttributes: CFArray = [
        kAXRoleAttribute as CFString,
        kAXChildrenAttribute as CFString
    ] as CFArray

    private let lock = NSLock()
    private var cache: [Int32: CachedAppState] = [:]
    private var registries: [Int32: IdRegistry] = [:]
    private var observers: [Int32: AXObserver] = [:]
    private var changeCounters: [Int32: UInt64] = [:]
    private var changeWaiters: [Int32: [ChangeWaiter]] = [:]
    private var manualAccessibilityPids: Set<Int32> = []

    /// Dedicated background thread and CFRunLoop hosting all `AXObserver` run loop sources so AX
    /// notifications never contend with the main thread.
    private let observerRunLoopLock = NSLock()
    private var observerRunLoop: CFRunLoop?
    private var observerThreadStarted = false

    public init() {}

    deinit {
        lock.lock()
        let activeObservers = Array(observers.values)
        observers.removeAll()
        let pendingWaiters = changeWaiters.values.flatMap { $0 }
        changeWaiters.removeAll()
        lock.unlock()

        for waiter in pendingWaiters {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: false)
        }

        observerRunLoopLock.lock()
        let runLoop = observerRunLoop
        observerRunLoop = nil
        observerRunLoopLock.unlock()

        if let runLoop {
            for observer in activeObservers {
                let source = AXObserverGetRunLoopSource(observer)
                CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            }
            CFRunLoopStop(runLoop)
        }
    }

    public func observe(
        app: AppDescriptor,
        maxDepth: Int = 20,
        maxElements: Int = 220,
        useCache: Bool = true,
        includeDiff: Bool = true,
        accessibilityGranted: Bool = true,
        includeOffscreen: Bool = false,
        filter: ElementFilter? = nil
    ) -> WindowSnapshot {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let checkNowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if useCache {
            lock.lock()
            let cached = cache[app.pid]
            lock.unlock()

            if let cached,
               !cached.dirty,
               (checkNowMs - cached.lastTimestampMs) < Self.hotCacheMaxAgeMs,
               (!includeOffscreen || cached.includedOffscreen) {
                let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                var snapshot = cached.snapshot
                snapshot.app = app
                snapshot.fromHotCache = true
                snapshot.latencyMs = latencyMs
                if !includeDiff {
                    snapshot.diff = nil
                }
                if !includeOffscreen {
                    let beforeCount = snapshot.elements.count
                    snapshot.elements = snapshot.elements.filter { $0.offscreen != true }
                    let removed = beforeCount - snapshot.elements.count
                    let totalOffscreen = (snapshot.offscreenCount ?? 0) + removed
                    snapshot.offscreenCount = totalOffscreen > 0 ? totalOffscreen : nil
                }
                if let filter {
                    snapshot = Self.filteringSnapshot(snapshot, with: filter)
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
                roleDescription: nil,
                enabled: true,
                focused: true,
                frame: fallbackRect,
                actions: []
            )
            let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            let completedMs = Int64(Date().timeIntervalSince1970 * 1000)
            let prevSnapshot = previousSnapshot(for: app.pid)
            let diff = includeDiff ? Self.computeDiff(previous: prevSnapshot, current: [fallbackNode]) : nil

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
                windowTitle: app.windowTitle,
                includedOffscreen: includeOffscreen,
                observedMaxElements: maxElements
            )
            lock.unlock()

            return filter != nil ? Self.filteringSnapshot(snapshot, with: filter!) : snapshot
        }

        ensureObserver(for: app.pid)

        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)

        let focusedElement = copyElementAttribute(axApp, attribute: kAXFocusedUIElementAttribute)
        var root = rootWindow(of: axApp)
        var rootFrame = root.flatMap { copyFrame($0) }
        var rootWindowId = root.flatMap { WindowResolver.windowID(of: $0) }.map { UInt32($0) }
        var rootTitle = root.flatMap { copyStringAttribute($0, attribute: kAXTitleAttribute) }

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

        traverse(element: root ?? axApp, depth: 0, rawDepth: 0, context: &ctx)

        // Electron / Chromium apps often expose an empty or stub AXWebArea until AXManualAccessibility is enabled.
        if ctx.elements.count < 5, Self.looksLikeElectronOrChromium(app: app, elements: ctx.elements) {
            let shouldEnableManualAX: Bool = {
                lock.lock()
                defer { lock.unlock() }
                if manualAccessibilityPids.contains(app.pid) {
                    return false
                }
                manualAccessibilityPids.insert(app.pid)
                return true
            }()
            if shouldEnableManualAX {
                let enableErr = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if enableErr == .success {
                    Thread.sleep(forTimeInterval: 0.04)
                    let retryFocused = copyElementAttribute(axApp, attribute: kAXFocusedUIElementAttribute) ?? focusedElement
                    root = rootWindow(of: axApp) ?? root
                    rootFrame = root.flatMap { copyFrame($0) } ?? rootFrame
                    rootWindowId = root.flatMap { WindowResolver.windowID(of: $0) }.map { UInt32($0) } ?? rootWindowId
                    rootTitle = root.flatMap { copyStringAttribute($0, attribute: kAXTitleAttribute) } ?? rootTitle
                    var retryCtx = TraversalContext(
                        maxDepth: boundedDepth,
                        maxElements: boundedElements,
                        maxOffscreen: boundedElements,
                        includeOffscreen: includeOffscreen,
                        focusedElement: retryFocused,
                        viewport: rootFrame,
                        registry: ctx.registry
                    )
                    traverse(element: root ?? axApp, depth: 0, rawDepth: 0, context: &retryCtx)
                    if retryCtx.elements.count >= ctx.elements.count {
                        ctx = retryCtx
                    }
                }
            }
        }

        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
        let completedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let prevSnapshot = previousSnapshot(for: app.pid)
        let diff = includeDiff ? Self.computeDiff(previous: prevSnapshot, current: ctx.elements) : nil

        var describedApp = app
        if describedApp.windowId == nil {
            describedApp.windowId = rootWindowId
        }
        let offscreenCount: Int? = ctx.skippedOffscreenCount > 0 ? ctx.skippedOffscreenCount : nil
        let snapshot = WindowSnapshot(
            app: describedApp,
            timestampMs: completedMs,
            latencyMs: latencyMs,
            fromHotCache: false,
            focusedElementId: ctx.focusedElementId,
            elements: ctx.elements,
            diff: diff,
            offscreenCount: offscreenCount
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
            scrollContainers: ctx.scrollContainers,
            includedOffscreen: includeOffscreen,
            observedMaxElements: boundedElements
        )
        lock.unlock()

        return filter != nil ? Self.filteringSnapshot(snapshot, with: filter!) : snapshot
    }

    /// Applies an optional server-side `ElementFilter` (`role`, `text`, `viewportOnly`) to element nodes.
    public static func applyFilter(_ elements: [ElementNode], filter: ElementFilter?) -> [ElementNode] {
        guard let filter else { return elements }
        let wantRole = filter.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantText = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normText = (wantText?.isEmpty == false) ? ElementMatcher.normalize(wantText!) : nil
        let viewportOnly = filter.viewportOnly == true

        if (wantRole == nil || wantRole?.isEmpty == true) && normText == nil && !viewportOnly {
            return elements
        }

        return elements.filter { node in
            if viewportOnly {
                if node.offscreen == true || node.frame.width < 2 || node.frame.height < 2 {
                    return false
                }
            }
            if let wantRole, !wantRole.isEmpty {
                if !ElementMatcher.matchesFilterRole(wantRole, actual: node.role) {
                    return false
                }
            }
            if let normText {
                let titleMatch = node.title.map { ElementMatcher.normalize($0).contains(normText) } ?? false
                let valueMatch = node.value.map { ElementMatcher.normalize($0).contains(normText) } ?? false
                if !titleMatch && !valueMatch {
                    return false
                }
            }
            return true
        }
    }

    private static func filteringSnapshot(_ snapshot: WindowSnapshot, with filter: ElementFilter) -> WindowSnapshot {
        var filtered = snapshot
        filtered.elements = applyFilter(snapshot.elements, filter: filter)
        if var diff = snapshot.diff {
            diff.added = applyFilter(diff.added, filter: filter)
            diff.changed = applyFilter(diff.changed, filter: filter)
            if diff.added.isEmpty && diff.removedIds.isEmpty && diff.changed.isEmpty {
                diff.summary = "no changes"
            } else {
                diff.summary = "+\(diff.added.count) added, -\(diff.removedIds.count) removed, ~\(diff.changed.count) changed"
            }
            filtered.diff = diff
        }
        return filtered
    }

    static func looksLikeElectronOrChromium(app: AppDescriptor, elements: [ElementNode]) -> Bool {
        if elements.contains(where: { $0.role == "AXWebArea" }) {
            return true
        }
        let bid = (app.bundleId ?? "").lowercased()
        let name = app.name.lowercased()
        let tokens = [
            "electron", "chromium", "chrome", "brave", "thebrowser", "edgemac", "vivaldi", "opera",
            "vscode", "slack", "discord", "notion", "linear", "figma", "obsidian", "cursor",
            "spotify", "postman", "teams", "todesktop", "whatsapp", "claude"
        ]
        if tokens.contains(where: { bid.contains($0) || name.contains($0) }) {
            return true
        }
        return elements.isEmpty || (elements.count <= 2 && elements.allSatisfy {
            $0.role == "AXWindow" || $0.role == "AXGroup" || $0.role == "AXWebArea"
        })
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

    /// Re-reads a known element's attributes now (frame, value, offscreen) in 1 batched Mach IPC instead of
    /// trusting the snapshot. Returns nil when the id is unknown or the element no longer exists.
    public func liveNode(for id: String, pid: Int32) -> (element: AXUIElement, node: ElementNode)? {
        guard let element = element(for: id, pid: pid) else { return nil }
        guard let attrs = copyBatchedAttributes(element, includeChildren: false, includeVisibleChildren: false) else {
            return nil
        }
        let actions = copyActionNames(element)
        let node = makeNode(
            id: id,
            element: element,
            attrs: attrs,
            actions: actions,
            focusedElement: nil,
            viewport: currentViewport(pid: pid)
        )
        lock.lock()
        cache[pid]?.nodeMap[id] = node
        lock.unlock()
        return (element, node)
    }

    /// Registers an element found outside an observe (e.g. by `match`) and returns its stable id and node.
    public func register(element: AXUIElement, pid: Int32) -> (id: String, node: ElementNode)? {
        guard let attrs = copyBatchedAttributes(element, includeChildren: false, includeVisibleChildren: false) else {
            return nil
        }
        lock.lock()
        var registry = registries[pid] ?? IdRegistry()
        let id = registry.id(for: element)
        registries[pid] = registry
        lock.unlock()
        let actions = copyActionNames(element)
        let node = makeNode(
            id: id,
            element: element,
            attrs: attrs,
            actions: actions,
            focusedElement: nil,
            viewport: currentViewport(pid: pid)
        )
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

    /// Finds elements matching `match` in the app's focused window right now, in tree order. Checks clean
    /// hot cache first before live traversal, and checks `match.role` FIRST before fetching text/value.
    public func find(
        pid: Int32,
        match: ElementMatch,
        maxDepth: Int = 60,
        budget: Int = 6000,
        limit: Int = 50
    ) -> [(id: String, element: AXUIElement, node: ElementNode)] {
        guard !match.isEmpty else { return [] }
        let boundedLimit = max(1, limit)

        // 1. Fast path: check clean, fresh cache before touching live AX tree.
        if let cachedHits = findInCleanCache(pid: pid, match: match, limit: boundedLimit) {
            return cachedHits
        }

        ensureObserver(for: pid)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let root = rootWindow(of: axApp) else { return [] }

        let needsTitleOrDesc = (match.title?.isEmpty == false) || (match.text?.isEmpty == false)
        let needsValue = (match.value?.isEmpty == false) || (match.text?.isEmpty == false)
        let hasRoleConstraint = (match.role?.isEmpty == false)

        var hits: [AXUIElement] = []
        var visited: Set<AXUIElement> = []
        var remaining = budget

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, remaining > 0, hits.count < boundedLimit, !visited.contains(element) else { return }
            visited.insert(element)
            remaining -= 1

            let role: String
            let children: [AXUIElement]
            if let rc = copyRoleAndChildren(element) {
                role = rc.role
                children = rc.children
            } else {
                role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? "AXUnknown"
                children = depth < maxDepth ? (copyElementArrayAttribute(element, attribute: kAXChildrenAttribute) ?? []) : []
            }

            // Check match.role FIRST before fetching title/description/value!
            let matched: Bool
            if hasRoleConstraint && ElementMatcher.normalizeRole(match.role!) != ElementMatcher.normalizeRole(role) {
                matched = false
            } else if !needsTitleOrDesc && !needsValue {
                matched = ElementMatcher.matches(role: role, title: nil, description: nil, value: nil, match: match)
            } else {
                // Only fetch the attributes actually required by `match` (never calling copyFullValue unless needed).
                matched = ElementMatcher.matchesLazy(
                    role: role,
                    match: match,
                    title: { self.copyStringAttribute(element, attribute: kAXTitleAttribute) },
                    description: { self.copyStringAttribute(element, attribute: kAXDescriptionAttribute) },
                    value: { needsValue ? self.copyFullValue(element) : nil }
                )
            }

            if matched {
                hits.append(element)
            }

            guard depth < maxDepth else { return }
            for child in children {
                walk(child, depth: depth + 1)
                if remaining <= 0 || hits.count >= boundedLimit { break }
            }
        }
        walk(root, depth: 0)

        return hits.compactMap { element in
            guard let registered = register(element: element, pid: pid) else { return nil }
            return (registered.id, element, registered.node)
        }
    }

    private func findInCleanCache(
        pid: Int32,
        match: ElementMatch,
        limit: Int
    ) -> [(id: String, element: AXUIElement, node: ElementNode)]? {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock()
        guard let state = cache[pid],
              !state.dirty,
              (nowMs - state.lastTimestampMs) < Self.hotCacheMaxAgeMs else {
            lock.unlock()
            return nil
        }
        let snapshotElements = state.snapshot.elements
        let elementMap = state.elementMap
        let completeSnapshot = snapshotElements.count < state.observedMaxElements
            && (state.snapshot.offscreenCount ?? 0) == 0
        lock.unlock()

        var results: [(id: String, element: AXUIElement, node: ElementNode)] = []
        for node in snapshotElements {
            guard ElementMatcher.matches(
                role: node.role,
                title: node.title,
                description: nil,
                value: node.value,
                match: match
            ) else { continue }
            guard elementMap[node.id] != nil else { continue }
            // Confirm element is still alive before returning from cache.
            if let live = liveNode(for: node.id, pid: pid) {
                results.append((node.id, live.element, live.node))
                if results.count >= limit {
                    return results
                }
            } else {
                // Element went stale despite clean flag; fall back to live walk.
                invalidate(pid: pid)
                return nil
            }
        }
        if !results.isEmpty && (results.count >= limit || completeSnapshot) {
            return results
        }
        return nil
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
        currentGeneration(pid: pid)
    }

    /// Current AX change generation for `pid`, ensuring an observer is installed when possible.
    public func currentGeneration(pid: pid_t) -> UInt64 {
        if pid > 0 {
            ensureObserver(for: pid)
        }
        lock.lock()
        defer { lock.unlock() }
        return changeCounters[pid] ?? 0
    }

    /// Whether an `AXObserver` is currently attached for `pid`.
    internal func hasObserver(for pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observers[pid] != nil
    }

    /// Suspends until an AX notification advances `pid`'s generation beyond `sinceGeneration`, or `timeoutMs`
    /// elapses. Woken directly by `recordChange(pid:)` via `CheckedContinuation` (2–5 ms wake latency).
    public func waitForChange(pid: pid_t, sinceGeneration: UInt64, timeoutMs: Int) async -> Bool {
        if pid > 0 {
            ensureObserver(for: pid)
        }
        if hasGenerationAdvanced(pid: pid, since: sinceGeneration) {
            return true
        }

        let clampedMs = max(0, timeoutMs)
        if clampedMs == 0 {
            return false
        }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerChangeWaiter(
                    pid: pid,
                    id: waiterId,
                    sinceGeneration: sinceGeneration,
                    timeoutMs: clampedMs,
                    cancelled: Task.isCancelled,
                    continuation: continuation
                )
            }
        } onCancel: { [weak self] in
            self?.timeoutWaiter(pid: pid, id: waiterId)
        }
    }

    private func hasGenerationAdvanced(pid: Int32, since: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (changeCounters[pid] ?? 0) != since
    }

    private func registerChangeWaiter(
        pid: Int32,
        id: UUID,
        sinceGeneration: UInt64,
        timeoutMs: Int,
        cancelled: Bool,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        var immediateResult: Bool?
        lock.lock()
        if (changeCounters[pid] ?? 0) != sinceGeneration {
            immediateResult = true
        } else if cancelled {
            immediateResult = false
        } else {
            let timer = DispatchWorkItem { [weak self] in
                self?.timeoutWaiter(pid: pid, id: id)
            }
            changeWaiters[pid, default: []].append(
                ChangeWaiter(
                    id: id,
                    sinceGeneration: sinceGeneration,
                    continuation: continuation,
                    timer: timer
                )
            )
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .milliseconds(timeoutMs),
                execute: timer
            )
        }
        lock.unlock()

        if let immediateResult {
            continuation.resume(returning: immediateResult)
        }
    }

    private func timeoutWaiter(pid: Int32, id: UUID) {
        var cont: CheckedContinuation<Bool, Never>?
        var changed = false
        lock.lock()
        if var list = changeWaiters[pid], let idx = list.firstIndex(where: { $0.id == id }) {
            let waiter = list.remove(at: idx)
            if list.isEmpty {
                changeWaiters.removeValue(forKey: pid)
            } else {
                changeWaiters[pid] = list
            }
            waiter.timer?.cancel()
            cont = waiter.continuation
            changed = (changeCounters[pid] ?? 0) != waiter.sinceGeneration
        }
        lock.unlock()
        cont?.resume(returning: changed)
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

    internal func recordChange(pid: Int32) {
        var woken: [ChangeWaiter] = []
        lock.lock()
        cache[pid]?.dirty = true
        let nextGen = (changeCounters[pid] ?? 0) &+ 1
        changeCounters[pid] = nextGen
        if let list = changeWaiters[pid] {
            var remaining: [ChangeWaiter] = []
            for waiter in list {
                if nextGen != waiter.sinceGeneration {
                    woken.append(waiter)
                } else {
                    remaining.append(waiter)
                }
            }
            if remaining.isEmpty {
                changeWaiters.removeValue(forKey: pid)
            } else {
                changeWaiters[pid] = remaining
            }
        }
        lock.unlock()

        for waiter in woken {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    internal func markDirtyAll() {
        var woken: [ChangeWaiter] = []
        lock.lock()
        for key in cache.keys {
            cache[key]?.dirty = true
            changeCounters[key, default: 0] &+= 1
        }
        for pid in Array(changeWaiters.keys) {
            let nextGen = (changeCounters[pid] ?? 0) &+ 1
            changeCounters[pid] = nextGen
            if let list = changeWaiters.removeValue(forKey: pid) {
                woken.append(contentsOf: list)
            }
        }
        lock.unlock()

        for waiter in woken {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: true)
        }
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

    private func ensureObserverRunLoop() -> CFRunLoop? {
        observerRunLoopLock.lock()
        if let rl = observerRunLoop {
            observerRunLoopLock.unlock()
            return rl
        }
        if observerThreadStarted {
            observerRunLoopLock.unlock()
            return nil
        }
        observerThreadStarted = true
        observerRunLoopLock.unlock()

        let ready = DispatchSemaphore(value: 0)
        var createdRunLoop: CFRunLoop?
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()
            var ctx = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)
            if let keepAlive {
                CFRunLoopAddSource(rl, keepAlive, .defaultMode)
            }
            createdRunLoop = rl
            ready.signal()
            CFRunLoopRun()
            if let keepAlive {
                CFRunLoopRemoveSource(rl, keepAlive, .defaultMode)
            }
        }
        thread.name = "app.usemac.ax-observer"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + .seconds(2))

        observerRunLoopLock.lock()
        observerRunLoop = createdRunLoop
        let result = observerRunLoop
        observerRunLoopLock.unlock()
        return result
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

        guard let targetRunLoop = ensureObserverRunLoop() else {
            return
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(targetRunLoop, source, .defaultMode)
        CFRunLoopWakeUp(targetRunLoop)

        lock.lock()
        if observers[pid] == nil {
            observers[pid] = observer
        } else {
            CFRunLoopRemoveSource(targetRunLoop, source, .defaultMode)
        }
        lock.unlock()
    }

    private func traverse(element: AXUIElement, depth: Int, rawDepth: Int, context: inout TraversalContext) {
        let maxRawDepth = max(context.maxDepth * 4, 80)
        guard depth <= context.maxDepth, rawDepth <= maxRawDepth, context.visibleCount < context.maxElements else {
            return
        }
        guard !context.visited.contains(element) else {
            return
        }
        context.visited.insert(element)

        guard let attrs = copyBatchedAttributes(
            element,
            includeChildren: true,
            includeVisibleChildren: !context.includeOffscreen
        ) else {
            return
        }

        let role = attrs.role
        let title = attrs.nonEmptyTitle
        let value = attrs.clippedValue
        let frame = attrs.frame
        let offscreen = Self.isOffscreen(frame: frame, viewport: context.viewport)
        let isFlattenRole = Self.flattenRoles.contains(role)

        // Skip action IPC for offscreen non-flatten nodes when includeOffscreen == false.
        let needActions = isFlattenRole || !offscreen || context.includeOffscreen
        let actions = needActions ? copyActionNames(element) : []

        let isEmptyLayoutContainer = isFlattenRole
            && (title == nil || title?.isEmpty == true)
            && (value == nil || value?.isEmpty == true)
            && !actions.contains("AXPress")

        if !isEmptyLayoutContainer {
            if offscreen && !context.includeOffscreen {
                context.skippedOffscreenCount += 1
            } else {
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
                        attrs: attrs,
                        actions: actions,
                        focusedElement: context.focusedElement,
                        viewport: context.viewport
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
                } else if offscreen && meaningful {
                    context.skippedOffscreenCount += 1
                }
            }
        }

        // Do NOT increment logical depth when stepping through flattenRoles containers.
        let nextDepth = isFlattenRole ? depth : depth + 1
        guard nextDepth <= context.maxDepth, rawDepth < maxRawDepth, context.visibleCount < context.maxElements else {
            return
        }

        let children: [AXUIElement]
        if !context.includeOffscreen && Self.visibleChildrenRoles.contains(role) {
            if let visible = attrs.visibleChildren, !visible.isEmpty {
                children = visible
                if let all = attrs.children, all.count > visible.count {
                    context.skippedOffscreenCount += (all.count - visible.count)
                }
            } else if (role == "AXTable" || role == "AXOutline"),
                      let visibleRows = copyElementArrayAttribute(element, attribute: kAXVisibleRowsAttribute),
                      !visibleRows.isEmpty {
                children = visibleRows
                if let all = attrs.children, all.count > visibleRows.count {
                    context.skippedOffscreenCount += (all.count - visibleRows.count)
                }
            } else {
                children = attrs.children ?? []
            }
        } else {
            children = attrs.children ?? []
        }

        let descendantsStart = context.elements.count
        for child in children {
            traverse(element: child, depth: nextDepth, rawDepth: rawDepth + 1, context: &context)
            if context.visibleCount >= context.maxElements {
                break
            }
        }
        if ScrollFallback.containerRoles.contains(role) {
            // Recorded even when the container itself is flattened out of the list (an unlabeled scroll area).
            context.scrollContainers.append(ScrollContainer(
                role: role,
                frame: frame,
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
        attrs: BatchedNodeAttributes,
        actions: [String],
        focusedElement: AXUIElement?,
        viewport: ScreenRect?
    ) -> ElementNode {
        let isFocusedAttr = attrs.focused ?? false
        let isFocusedRef = focusedElement.map { CFEqual(element, $0) } ?? false
        let offscreen = Self.isOffscreen(frame: attrs.frame, viewport: viewport)
        return ElementNode(
            id: id,
            role: attrs.role,
            title: attrs.nonEmptyTitle,
            value: attrs.clippedValue,
            roleDescription: nil,
            enabled: attrs.enabled ?? true,
            focused: isFocusedAttr || isFocusedRef,
            frame: attrs.frame ?? ScreenRect(x: 0, y: 0, width: 0, height: 0),
            actions: actions,
            offscreen: offscreen ? true : nil
        )
    }

    // MARK: - Batched AX Attribute Helpers

    private static func isAXErrorSentinel(_ obj: AnyObject) -> Bool {
        if obj is NSNull { return true }
        guard CFGetTypeID(obj) == AXValueGetTypeID() else { return false }
        let axVal = unsafeBitCast(obj, to: AXValue.self)
        return AXValueGetType(axVal) == .axError
    }

    private static func stringFromAX(_ obj: AnyObject?) -> String? {
        guard let obj, !isAXErrorSentinel(obj) else { return nil }
        return obj as? String
    }

    private static func valueStringFromAX(_ obj: AnyObject?) -> String? {
        guard let obj, !isAXErrorSentinel(obj) else { return nil }
        if let str = obj as? String { return str }
        if let num = obj as? NSNumber { return num.stringValue }
        return nil
    }

    private static func boolFromAX(_ obj: AnyObject?) -> Bool? {
        guard let obj, !isAXErrorSentinel(obj) else { return nil }
        return (obj as? NSNumber)?.boolValue
    }

    private static func frameFromAX(posObj: AnyObject?, sizeObj: AnyObject?) -> ScreenRect? {
        guard let posObj, let sizeObj,
              !isAXErrorSentinel(posObj), !isAXErrorSentinel(sizeObj),
              CFGetTypeID(posObj) == AXValueGetTypeID(),
              CFGetTypeID(sizeObj) == AXValueGetTypeID() else {
            return nil
        }
        let posVal = unsafeBitCast(posObj, to: AXValue.self)
        let sizeVal = unsafeBitCast(sizeObj, to: AXValue.self)
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

    private static func elementArrayFromAX(_ obj: AnyObject?) -> [AXUIElement]? {
        guard let obj, !isAXErrorSentinel(obj), let array = obj as? [AnyObject] else { return nil }
        var result: [AXUIElement] = []
        result.reserveCapacity(array.count)
        for item in array where CFGetTypeID(item) == AXUIElementGetTypeID() {
            result.append(unsafeBitCast(item, to: AXUIElement.self))
        }
        return result
    }

    /// Fetches all node attributes in 1 Mach IPC via `AXUIElementCopyMultipleAttributeValues`,
    /// falling back to single-attribute reads if the batched API fails.
    private func copyBatchedAttributes(
        _ element: AXUIElement,
        includeChildren: Bool,
        includeVisibleChildren: Bool
    ) -> BatchedNodeAttributes? {
        let attrList: CFArray
        let expectedCount: Int
        if includeChildren {
            if includeVisibleChildren {
                attrList = Self.traverseAttributesWithVisible
                expectedCount = 10
            } else {
                attrList = Self.traverseAttributesAll
                expectedCount = 9
            }
        } else {
            attrList = Self.nodeOnlyAttributes
            expectedCount = 8
        }

        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            attrList,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        )

        if err == .success, let values = valuesRef as? [AnyObject], values.count >= expectedCount {
            guard let role = Self.stringFromAX(values[0]) else {
                return nil
            }
            return BatchedNodeAttributes(
                role: role,
                title: Self.stringFromAX(values[1]),
                description: Self.stringFromAX(values[2]),
                fullValue: Self.valueStringFromAX(values[3]),
                frame: Self.frameFromAX(posObj: values[4], sizeObj: values[5]),
                focused: Self.boolFromAX(values[6]),
                enabled: Self.boolFromAX(values[7]),
                children: includeChildren ? Self.elementArrayFromAX(values[8]) : nil,
                visibleChildren: (includeChildren && includeVisibleChildren) ? Self.elementArrayFromAX(values[9]) : nil
            )
        }

        // Single-attribute fallback if batched call returned `.apiDisabled` or another error.
        guard let role = copyStringAttribute(element, attribute: kAXRoleAttribute) else {
            return nil
        }
        return BatchedNodeAttributes(
            role: role,
            title: copyStringAttribute(element, attribute: kAXTitleAttribute),
            description: copyStringAttribute(element, attribute: kAXDescriptionAttribute),
            fullValue: copyFullValue(element),
            frame: copyFrame(element),
            focused: copyBoolAttribute(element, attribute: kAXFocusedAttribute),
            enabled: copyBoolAttribute(element, attribute: kAXEnabledAttribute),
            children: includeChildren ? copyElementArrayAttribute(element, attribute: kAXChildrenAttribute) : nil,
            visibleChildren: (includeChildren && includeVisibleChildren)
                ? copyElementArrayAttribute(element, attribute: kAXVisibleChildrenAttribute)
                : nil
        )
    }

    private func copyRoleAndChildren(_ element: AXUIElement) -> (role: String, children: [AXUIElement])? {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            Self.roleAndChildrenAttributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        )
        guard err == .success, let values = valuesRef as? [AnyObject], values.count >= 2 else {
            return nil
        }
        let role = Self.stringFromAX(values[0]) ?? "AXUnknown"
        let children = Self.elementArrayFromAX(values[1]) ?? []
        return (role, children)
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

    private func copyFullValue(_ element: AXUIElement) -> String? {
        guard let ref = copyAttribute(element, attribute: kAXValueAttribute) else { return nil }
        if let str = ref as? String { return str }
        if let num = ref as? NSNumber { return num.stringValue }
        return nil
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

    static func framesWithinJitter(_ a: ScreenRect, _ b: ScreenRect, tolerance: Double = diffFrameTolerancePx) -> Bool {
        abs(a.x - b.x) < tolerance
            && abs(a.y - b.y) < tolerance
            && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    static func nodesSignificantlyDiffer(_ old: ElementNode, _ new: ElementNode, frameTolerance: Double = diffFrameTolerancePx) -> Bool {
        if old.role != new.role { return true }
        if old.title != new.title { return true }
        if old.value != new.value { return true }
        if old.enabled != new.enabled { return true }
        if old.focused != new.focused { return true }
        if old.offscreen != new.offscreen { return true }
        if old.actions != new.actions { return true }
        return !framesWithinJitter(old.frame, new.frame, tolerance: frameTolerance)
    }

    static func computeDiff(previous: WindowSnapshot?, current: [ElementNode]) -> SnapshotDiff? {
        guard let previous else { return nil }

        let oldById = Dictionary(previous.elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newById = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var added: [ElementNode] = []
        var changed: [ElementNode] = []
        var removedIds: [String] = []

        for node in current {
            if let old = oldById[node.id] {
                if nodesSignificantlyDiffer(old, node) {
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
