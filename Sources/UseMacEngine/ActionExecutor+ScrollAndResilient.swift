import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

extension ActionExecutor {
    func performScroll(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        var bgPid = backgroundPid(for: step, targetApp: targetApp)
        let dy = Int32(step.deltaY ?? 0)
        let dx = Int32(step.deltaX ?? 0)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            return StepOutcome(success: false, mechanism: "cgevent-scroll", message: "Failed to create scroll CGEvent", node: resolved.node)
        }

        // Where to scroll: the visible part of the element, the given point, or the middle of the window.
        // Wheel events are routed by location, so a scroll without one (or with a point off screen, like the
        // center of a 5000 px text view) is silently dropped.
        let point = scrollPoint(step: step, node: resolved.node, targetApp: targetApp)
        let pid = resolved.pid > 0 ? resolved.pid : (targetApp?.pid ?? 0)

        // 1. Native scroll views: move the scroll bar through AX. No events, works in the background.
        if pid > 0, let shift = scrollViaScrollBar(pid: pid, point: point, element: resolved.element, dx: Double(dx), dy: Double(dy)) {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            let atEdge = shift.x == 0 && shift.y == 0
            return StepOutcome(
                success: true,
                mechanism: "ax-scrollbar",
                node: resolved.node,
                effect: atEdge ? ActionEffect.none : .changed,
                warning: atEdge ? "Already at the end of the scroll view." : nil,
                scrollDeltaY: shift.y
            )
        }

        let probes = scrollProbes(pid: pid, near: point)

        // The app is in front, but a real wheel event goes to the window on top at the point, which may not be
        // the target window (the user's own window of the same app, or another app's): scroll it in the
        // background then.
        if bgPid == nil {
            if let refused = frontmostGuard(targetApp, input: "scrolling", at: point) {
                return refused
            }
            switch pointerRoute(targetApp, at: point, backgroundAllowed: step.preferBackground != false) {
            case .foreground:
                break
            case .background:
                bgPid = targetApp?.pid
            case .refuse(let covering):
                var refused = coveredWindowOutcome(targetApp: targetApp, covering: covering, input: "scrolling")
                refused.node = resolved.node
                return refused
            }
        }

        if let bgPid {
            if let point {
                scrollEvent.location = point
            }
            Self.routeToWindow(scrollEvent, windowId: targetApp?.windowId)
            scrollEvent.postToPid(bgPid)
            let moved = await measureScroll(probes: probes)
            if moved.map({ abs($0) >= 1 }) != true, dy != 0,
               let fallback = await scrollToNextOffscreen(
                   pid: pid,
                   down: dy < 0,
                   point: point,
                   elementId: resolved.node?.id,
                   targetApp: targetApp,
                   onOverlayEvent: onOverlayEvent
               ) {
                return fallback
            }
            return StepOutcome(success: true, mechanism: "cgevent-pid-scroll", node: resolved.node, scrollDeltaY: moved)
        }

        let savedCursor = CGEvent(source: nil)?.location
        var movedCursor = false
        if let point,
           let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
            movedCursor = true
        }
        scrollEvent.post(tap: .cghidEventTap)
        noteSyntheticInput()
        if movedCursor && step.restoreCursor != false, let savedCursor {
            _ = CGWarpMouseCursorPosition(savedCursor)
        }
        let moved = await measureScroll(probes: probes)
        return StepOutcome(success: true, mechanism: "cgevent-scroll", node: resolved.node, scrollDeltaY: moved)
    }

    /// A point inside both the element and its window (the middle of their overlap).
    private func scrollPoint(step: ActionStep, node: ElementNode?, targetApp: AppDescriptor?) -> CGPoint? {
        if let x = step.x, let y = step.y {
            return CGPoint(x: x, y: y)
        }
        let window = targetWindowFrame(targetApp)
        if let node, node.offscreen != true, node.frame.width > 0, node.frame.height > 0 {
            let rect = CGRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
            if let window {
                let visible = rect.intersection(window)
                if !visible.isNull, visible.width > 1, visible.height > 1 {
                    return CGPoint(x: visible.midX, y: visible.midY)
                }
            } else {
                return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        return window.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Scrolls the AXScrollArea under `element`/`point` by setting its scroll bar values. Returns the content
    /// shift in points (0 when already at the edge), or nil when there is no settable scroll bar.
    private func scrollViaScrollBar(pid: Int32, point: CGPoint?, element: AXUIElement?, dx: Double, dy: Double) -> (x: Double, y: Double)? {
        var start = element
        if start == nil, let point {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &hit) == .success {
                start = hit
            }
        }
        guard var current = start else { return nil }
        var scrollArea: AXUIElement?
        for _ in 0..<12 {
            if Self.axString(current, kAXRoleAttribute) == "AXScrollArea" {
                scrollArea = current
                break
            }
            guard let parent = Self.axElement(current, kAXParentAttribute) else { break }
            current = parent
        }
        guard let area = scrollArea, let areaFrame = Self.axFrame(area) else { return nil }
        let content = Self.axChildren(area, attribute: kAXContentsAttribute).first
            ?? Self.axChildren(area).first { Self.axString($0, kAXRoleAttribute) != "AXScrollBar" }
        guard let contentFrame = content.flatMap({ Self.axFrame($0) }) else { return nil }

        func move(_ barAttribute: String, delta: Double, contentLength: Double, visibleLength: Double) -> Double? {
            guard delta != 0, let bar = Self.axElement(area, barAttribute) else { return nil }
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return nil }
            let range = contentLength - visibleLength
            guard range > 1, let before = Self.axDouble(bar, kAXValueAttribute) else { return nil }
            let target = min(1, max(0, before + (-delta) / range))
            if abs(target - before) < 0.000001 { return 0 }
            guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target)) == .success else { return nil }
            let after = Self.axDouble(bar, kAXValueAttribute) ?? target
            return -(after - before) * range
        }

        let y = move(kAXVerticalScrollBarAttribute, delta: dy, contentLength: Double(contentFrame.height), visibleLength: Double(areaFrame.height))
        let x = move(kAXHorizontalScrollBarAttribute, delta: dx, contentLength: Double(contentFrame.width), visibleLength: Double(areaFrame.width))
        if x == nil && y == nil { return nil }
        return (x ?? 0, y ?? 0)
    }

    /// Web content exposes no scroll bars and may ignore background wheel events. Scrolling the next element
    /// that is out of view into view (AXScrollToVisible) pages through it without any events. The candidate is
    /// taken from the web area or scroll area under `point` (or holding `elementId`), never from the rest of the
    /// window: Chrome lists its infobar and tab strip after the page.
    private func scrollToNextOffscreen(
        pid: Int32,
        down: Bool,
        point: CGPoint?,
        elementId: String?,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome? {
        var layout = axIndexer.latestScrollLayout(pid: pid)
        var elementIndex = elementId.flatMap { id in layout.nodes.firstIndex(where: { $0.id == id }) }
        var index = ScrollFallback.nextOffscreenIndex(
            nodes: layout.nodes,
            containers: layout.containers,
            at: point,
            down: down,
            elementIndex: elementIndex
        )
        if index == nil, !layout.nodes.contains(where: { $0.offscreen == true }), let app = targetApp {
            // Default observes omit offscreen elements; index them on demand before giving up on the fallback.
            _ = axIndexer.observe(
                app: app,
                maxDepth: 40,
                maxElements: 600,
                useCache: false,
                includeDiff: false,
                accessibilityGranted: true,
                includeOffscreen: true
            )
            layout = axIndexer.latestScrollLayout(pid: pid)
            elementIndex = elementId.flatMap { id in layout.nodes.firstIndex(where: { $0.id == id }) }
            index = ScrollFallback.nextOffscreenIndex(
                nodes: layout.nodes,
                containers: layout.containers,
                at: point,
                down: down,
                elementIndex: elementIndex
            )
        }
        guard let index else { return nil }
        let candidate = layout.nodes[index]
        guard let element = axIndexer.element(for: candidate.id, pid: pid) else { return nil }
        guard AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) == .success else { return nil }
        try? await Task.sleep(nanoseconds: 180_000_000)
        let refreshed = axIndexer.liveNode(for: candidate.id, pid: pid)?.node
        guard refreshed?.offscreen != true else { return nil }
        highlight(refreshed, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        return StepOutcome(
            success: true,
            mechanism: "ax-scroll-to-next",
            message: "Scrolled \(down ? "down" : "up") to \(candidate.id) (the next element out of view).",
            node: refreshed,
            effect: .changed,
            warning: "The page ignored the wheel event; UseMac scrolled the next out-of-view element into view instead. Observe again for the new positions."
        )
    }

    private func windowCenter(_ app: AppDescriptor?) -> CGPoint? {
        if let windowId = app?.windowId, let info = WindowResolver.info(windowId: CGWindowID(windowId)) {
            return CGPoint(x: info.frame.midX, y: info.frame.midY)
        }
        if let bounds = app?.windowBounds {
            return CGPoint(x: bounds.centerX, y: bounds.centerY)
        }
        return nil
    }

    private struct ScrollProbe {
        let element: AXUIElement
        let y: Double
    }

    /// A few visible elements near the scroll point whose movement tells whether the scroll worked.
    private func scrollProbes(pid: Int32, near point: CGPoint?) -> [ScrollProbe] {
        guard pid > 0 else { return [] }
        let candidates = axIndexer.latestNodes(pid: pid).filter { node in
            node.offscreen != true && node.role != "AXWindow" && node.role != "AXWebArea"
                && node.frame.height > 4 && node.frame.height < 400
        }
        let sorted = candidates.sorted { a, b in
            guard let point else { return false }
            return abs(a.frame.centerY - point.y) + abs(a.frame.centerX - point.x)
                < abs(b.frame.centerY - point.y) + abs(b.frame.centerX - point.x)
        }
        var probes: [ScrollProbe] = []
        for node in sorted.prefix(12) {
            guard let element = axIndexer.element(for: node.id, pid: pid),
                  let frame = Self.axFrame(element) else { continue }
            probes.append(ScrollProbe(element: element, y: Double(frame.origin.y)))
            if probes.count >= 6 { break }
        }
        return probes
    }

    /// Median vertical shift of the probes after the scroll (nil when nothing could be measured).
    private func measureScroll(probes: [ScrollProbe]) async -> Double? {
        guard !probes.isEmpty else { return nil }
        var best: Double = 0
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 60_000_000)
            var shifts: [Double] = []
            for probe in probes {
                if let frame = Self.axFrame(probe.element) {
                    shifts.append(Double(frame.origin.y) - probe.y)
                } else {
                    shifts.append(.infinity)
                }
            }
            let finite = shifts.filter { $0.isFinite }.sorted()
            if finite.count < shifts.count {
                // Probes disappeared (scrolled out and pruned): the content moved.
                return finite.isEmpty ? -1 : (finite[finite.count / 2] == 0 ? -1 : finite[finite.count / 2])
            }
            if let median = finite.isEmpty ? nil : finite[finite.count / 2], abs(median) >= 1 {
                best = median
                break
            }
        }
        return best
    }

    func performScrollIntoView(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        guard let element = resolved.element, let id = resolved.node?.id else {
            return StepOutcome(success: false, mechanism: "ax-scroll-to-visible", message: "scrollIntoView needs elementId or match.", errorCode: "INVALID_REQUEST")
        }
        let before = Self.axFrame(element)
        let err = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        guard err == .success else {
            return StepOutcome(
                success: false,
                mechanism: "ax-scroll-to-visible",
                message: "The element does not support AXScrollToVisible (\(err.rawValue)). Use scroll with deltaY near it instead.",
                node: resolved.node
            )
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        let refreshed = axIndexer.liveNode(for: id, pid: resolved.pid)?.node ?? resolved.node
        highlight(refreshed, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let after = Self.axFrame(element)
        let moved: Double? = {
            guard let before, let after else { return nil }
            return Double(after.origin.y - before.origin.y)
        }()
        let alreadyVisible = resolved.node?.offscreen != true && (moved ?? 0) == 0
        return StepOutcome(
            success: true,
            mechanism: "ax-scroll-to-visible",
            message: alreadyVisible ? "Already in view" : nil,
            node: refreshed,
            effect: alreadyVisible ? .unverified : (refreshed?.offscreen == true ? ActionEffect.none : .changed),
            warning: refreshed?.offscreen == true ? "The element is still reported out of view." : nil,
            scrollDeltaY: moved
        )
    }

    func performAXAction(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        guard let name = step.actionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return StepOutcome(success: false, mechanism: "ax-action", message: "axAction needs actionName (e.g. \"AXOpen\").", errorCode: "INVALID_REQUEST")
        }
        guard let element = resolved.element else {
            return StepOutcome(success: false, mechanism: "ax-action", message: "axAction needs elementId or match.", errorCode: "INVALID_REQUEST")
        }
        let actionName = name.hasPrefix("AX") ? name : "AX" + name.prefix(1).uppercased() + name.dropFirst()
        let supported = resolved.node?.actions ?? []
        highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let err = AXUIElementPerformAction(element, actionName as CFString)
        guard err == .success else {
            return StepOutcome(
                success: false,
                mechanism: "ax-action",
                message: "\(actionName) failed (\(err.rawValue)). The element supports: \(supported.isEmpty ? "no actions" : supported.joined(separator: ", ")).",
                node: resolved.node
            )
        }
        return StepOutcome(
            success: true,
            mechanism: "ax-action",
            node: resolved.node,
            warning: supported.contains(actionName) ? nil : "\(actionName) is not in the element's advertised actions (\(supported.joined(separator: ", "))); check the result."
        )
    }

    func performWaitFor(step: ActionStep, targetApp: AppDescriptor?) async -> StepOutcome {
        guard let pid = targetApp?.pid, pid > 0 else {
            return StepOutcome(success: false, mechanism: "wait-for", message: "waitFor needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let hasMatch = step.match?.isEmpty == false
        guard hasMatch || step.elementId?.isEmpty == false else {
            return StepOutcome(success: false, mechanism: "wait-for", message: "waitFor needs match or elementId.", errorCode: "INVALID_REQUEST")
        }
        let timeoutMs = min(30_000, max(100, step.timeoutMs ?? step.durationMs ?? 5000))
        let wantGone = step.gone == true
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000

        while true {
            let genBeforeCheck = axIndexer.currentGeneration(pid: pid)
            var found: ElementNode?
            if hasMatch, let match = step.match {
                let index = max(0, match.index ?? 0)
                let hits = axIndexer.find(pid: pid, match: match, limit: index + 1)
                found = hits.count > index ? hits[index].node : nil
            } else if let id = step.elementId {
                found = axIndexer.liveNode(for: id, pid: pid)?.node
            }
            if wantGone ? (found == nil) : (found != nil) {
                return StepOutcome(success: true, mechanism: "wait-for", node: found, effect: .unverified)
            }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= deadline {
                let what = hasMatch ? Self.describe(step.match!) : (step.elementId ?? "element")
                return StepOutcome(
                    success: false,
                    mechanism: "wait-for",
                    message: "Timed out after \(timeoutMs) ms waiting for \(what) to \(wantGone ? "go away" : "appear").",
                    node: found,
                    errorCode: "WAIT_TIMEOUT"
                )
            }
            let remainingMs = Int((deadline - nowNs) / 1_000_000)
            let sliceMs = min(500, max(1, remainingMs))
            let woke = await axIndexer.waitForChange(pid: pid, sinceGeneration: genBeforeCheck, timeoutMs: sliceMs)
            if !woke {
                axIndexer.invalidate(pid: pid)
            }
        }
    }

    // MARK: - Resilient SOTA Steps (assert, scrollUntil, fillForm, menuAction)

    func performAssert(step: ActionStep, targetApp: AppDescriptor?) -> StepOutcome {
        let hasExpectTitle = !(step.expectTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasExpectText = !(step.expectText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasExpectNotText = !(step.expectNotText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasMatch = step.match?.isEmpty == false
        let hasElementId = !(step.elementId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard hasExpectTitle || hasExpectText || hasExpectNotText || hasMatch || hasElementId else {
            return StepOutcome(
                success: false,
                mechanism: "assert",
                message: "assert requires at least one of expectTitle, expectText, expectNotText, match, or elementId.",
                errorCode: "INVALID_REQUEST"
            )
        }
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(
                success: false,
                mechanism: "assert",
                message: "assert needs a target app.",
                errorCode: "APP_NOT_FOUND"
            )
        }
        let pid = targetApp.pid
        let windowTitle = axIndexer.currentContext(pid: pid)?.windowTitle ?? targetApp.windowTitle ?? ""

        let eval = Self.evaluateAssert(
            step: step,
            appName: targetApp.name,
            windowTitle: windowTitle,
            findMatch: { match in
                let idx = max(0, match.index ?? 0)
                let hits = self.axIndexer.find(pid: pid, match: match, limit: idx + 1)
                return hits.count > idx ? hits[idx].node : nil
            },
            findElementById: { id in
                self.axIndexer.liveNode(for: id, pid: pid)?.node
            }
        )
        return StepOutcome(
            success: eval.passed,
            mechanism: "assert",
            message: eval.message,
            node: eval.node,
            errorCode: eval.passed ? nil : "ASSERTION_FAILED",
            effect: .unverified
        )
    }

    internal static func evaluateAssert(
        step: ActionStep,
        appName: String,
        windowTitle: String,
        findMatch: (ElementMatch) -> ElementNode?,
        findElementById: (String) -> ElementNode?
    ) -> (passed: Bool, message: String, node: ElementNode?) {
        var matchedNode: ElementNode?

        if let expectedTitle = step.expectTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !expectedTitle.isEmpty {
            let normHave = ElementMatcher.normalize(windowTitle)
            let normWant = ElementMatcher.normalize(expectedTitle)
            if !normHave.contains(normWant) {
                return (false, "Expected window title to contain \"\(expectedTitle)\", but got \"\(windowTitle)\".", nil)
            }
        }

        if let expectText = step.expectText?.trimmingCharacters(in: .whitespacesAndNewlines), !expectText.isEmpty {
            let found = findMatch(ElementMatch(text: expectText))
            let titleContains = ElementMatcher.normalize(windowTitle).contains(ElementMatcher.normalize(expectText))
            if found == nil && !titleContains {
                return (false, "Expected text \"\(expectText)\" was not found in \(appName).", nil)
            }
            matchedNode = matchedNode ?? found
        }

        if let expectNotText = step.expectNotText?.trimmingCharacters(in: .whitespacesAndNewlines), !expectNotText.isEmpty {
            let found = findMatch(ElementMatch(text: expectNotText))
            let titleContains = ElementMatcher.normalize(windowTitle).contains(ElementMatcher.normalize(expectNotText))
            if found != nil || titleContains {
                return (false, "Text \"\(expectNotText)\" was unexpectedly present in \(appName).", found)
            }
        }

        let wantGone = step.gone == true
        if let match = step.match, !match.isEmpty {
            let found = findMatch(match)
            if wantGone {
                if found != nil {
                    return (false, "Expected element matching \(describe(match)) to be gone, but it is still present.", found)
                }
            } else {
                guard let found else {
                    return (false, "Expected element matching \(describe(match)) was not found in \(appName).", nil)
                }
                matchedNode = matchedNode ?? found
            }
        } else if let id = step.elementId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let found = findElementById(id)
            if wantGone {
                if found != nil {
                    return (false, "Expected element \(id) to be gone, but it is still present.", found)
                }
            } else {
                guard let found else {
                    return (false, "Expected element \(id) was not found in \(appName).", nil)
                }
                matchedNode = matchedNode ?? found
            }
        }

        return (true, "Assertion passed", matchedNode)
    }

    func performScrollUntil(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(success: false, mechanism: "scroll-until", message: "scrollUntil needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let effectiveMatch: ElementMatch? = {
            if let m = step.match, !m.isEmpty { return m }
            if let txt = step.expectText?.trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty {
                return ElementMatch(text: txt)
            }
            return nil
        }()
        let hasElementId = !(step.elementId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard effectiveMatch != nil || hasElementId else {
            return StepOutcome(
                success: false,
                mechanism: "scroll-until",
                message: "scrollUntil requires match, expectText, or elementId.",
                errorCode: "INVALID_REQUEST"
            )
        }

        let pid = targetApp.pid
        let maxScrolls = min(30, max(1, step.maxScrolls ?? 8))
        let deltaY = step.deltaY ?? -360
        let deltaX = step.deltaX ?? 0

        func lookupTarget() -> (element: AXUIElement, node: ElementNode)? {
            if let match = effectiveMatch {
                let idx = max(0, match.index ?? 0)
                let hits = axIndexer.find(pid: pid, match: match, limit: idx + 1)
                guard hits.count > idx else { return nil }
                return (hits[idx].element, hits[idx].node)
            }
            if let id = step.elementId {
                return axIndexer.liveNode(for: id, pid: pid)
            }
            return nil
        }

        for attempt in 0...maxScrolls {
            if let found = lookupTarget() {
                if found.node.offscreen != true {
                    highlight(found.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                    return StepOutcome(
                        success: true,
                        mechanism: "scroll-until",
                        message: attempt == 0 ? "Target already visible" : "Found after \(attempt) scroll\(attempt == 1 ? "" : "s")",
                        node: found.node,
                        effect: attempt == 0 ? .unverified : .changed
                    )
                }
                // Found offscreen: try direct AXScrollToVisible before scrolling manually.
                if AXUIElementPerformAction(found.element, "AXScrollToVisible" as CFString) == .success {
                    let gen = axIndexer.currentGeneration(pid: pid)
                    _ = await axIndexer.waitForChange(pid: pid, sinceGeneration: gen, timeoutMs: 150)
                    if let refreshed = axIndexer.liveNode(for: found.node.id, pid: pid), refreshed.node.offscreen != true {
                        highlight(refreshed.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                        return StepOutcome(
                            success: true,
                            mechanism: "scroll-until",
                            message: "Scrolled target into view",
                            node: refreshed.node,
                            effect: .changed
                        )
                    }
                }
            }

            if attempt == maxScrolls { break }

            let genBeforeScroll = axIndexer.currentGeneration(pid: pid)
            let scrollStep = ActionStep(
                action: .scroll,
                x: step.x,
                y: step.y,
                deltaX: deltaX,
                deltaY: deltaY,
                preferBackground: step.preferBackground,
                restoreCursor: step.restoreCursor
            )
            let scrollOutcome = await performScroll(
                step: scrollStep,
                resolved: ResolvedElement(pid: pid),
                targetApp: targetApp,
                onOverlayEvent: onOverlayEvent
            )
            if !scrollOutcome.success {
                return scrollOutcome
            }
            axIndexer.invalidate(pid: pid)
            if scrollOutcome.warning == "Already at the end of the scroll view." {
                break
            }
            _ = await axIndexer.waitForChange(pid: pid, sinceGeneration: genBeforeScroll, timeoutMs: 120)
        }

        let targetDesc = effectiveMatch.map(Self.describe) ?? (step.elementId ?? "target")
        return StepOutcome(
            success: false,
            mechanism: "scroll-until",
            message: "Could not find visible \(targetDesc) after \(maxScrolls) scroll\(maxScrolls == 1 ? "" : "s").",
            errorCode: "ELEMENT_NOT_FOUND"
        )
    }

    func performFillForm(
        step: ActionStep,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(success: false, mechanism: "fill-form", message: "fillForm needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        guard let fields = step.fields, !fields.isEmpty else {
            return StepOutcome(success: false, mechanism: "fill-form", message: "fillForm requires a non-empty fields array.", errorCode: "INVALID_REQUEST")
        }

        var filledCount = 0
        var lastNode: ElementNode?

        for (fieldIdx, field) in fields.enumerated() {
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
                let hint = ExecutionModeNotice.agentHint(policy: killSwitch.policy, killSwitchTripped: killSwitch.isTripped)
                return StepOutcome(
                    success: false,
                    mechanism: "blocked",
                    message: hint.map { "\(blockReason) \($0)" } ?? blockReason,
                    node: lastNode,
                    errorCode: "POLICY_BLOCKED"
                )
            }
            let fieldDesc = field.label ?? field.elementId ?? field.match.map(Self.describe) ?? "field #\(fieldIdx + 1)"
            let fieldMatch: ElementMatch? = {
                if let m = field.match, !m.isEmpty { return m }
                if field.elementId?.isEmpty != false,
                   let label = field.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !label.isEmpty {
                    return ElementMatch(title: label)
                }
                return nil
            }()
            var probeStep = ActionStep(
                action: .setValue,
                elementId: field.elementId,
                preferBackground: step.preferBackground,
                restoreCursor: step.restoreCursor,
                match: fieldMatch
            )

            var fieldResolved: ResolvedElement?
            switch await resolve(step: probeStep, targetApp: targetApp, scrollOffscreenIntoView: true) {
            case .success(let found):
                fieldResolved = found
            case .failure:
                // Fallback for label matching against text (value/title/description) if title-only missed.
                if field.match == nil, field.elementId == nil,
                   let label = field.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    probeStep.match = ElementMatch(text: label)
                    if case .success(let fallbackFound) = await resolve(step: probeStep, targetApp: targetApp, scrollOffscreenIntoView: true) {
                        fieldResolved = fallbackFound
                    }
                }
            }

            guard let resolved = fieldResolved, let axEl = resolved.element else {
                return StepOutcome(
                    success: false,
                    mechanism: "fill-form",
                    message: "Could not locate form field \(fieldDesc).",
                    errorCode: "FORM_FILL_FAILED"
                )
            }

            let role = resolved.node?.role ?? ""
            let isToggleRole = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"].contains(role)

            if field.checked != nil || isToggleRole {
                let wantChecked = field.checked ?? {
                    let v = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return v == "true" || v == "1" || v == "yes" || v == "on"
                }()
                let currentChecked = Self.axBool(axEl, kAXValueAttribute)
                    ?? (resolved.node?.value == "1" || resolved.node?.value?.lowercased() == "true")
                if currentChecked != wantChecked {
                    let toggleRes = performClick(
                        step: ActionStep(action: .click, preferBackground: step.preferBackground, restoreCursor: step.restoreCursor),
                        resolved: resolved,
                        targetApp: targetApp,
                        onOverlayEvent: onOverlayEvent
                    )
                    if !toggleRes.success {
                        return StepOutcome(
                            success: false,
                            mechanism: "fill-form",
                            message: "Failed to toggle \(fieldDesc): \(toggleRes.message ?? toggleRes.errorCode ?? "unknown error")",
                            node: resolved.node,
                            errorCode: "FORM_FILL_FAILED"
                        )
                    }
                }
            } else if role == "AXPopUpButton", let desired = field.value {
                let selected = await selectPopUpOption(
                    element: axEl,
                    desired: desired,
                    pid: resolved.pid,
                    node: resolved.node,
                    targetApp: targetApp,
                    onOverlayEvent: onOverlayEvent
                )
                if !selected {
                    return StepOutcome(
                        success: false,
                        mechanism: "fill-form",
                        message: "Failed to select \"\(desired)\" in \(fieldDesc).",
                        node: resolved.node,
                        errorCode: "FORM_FILL_FAILED"
                    )
                }
            } else if let textValue = field.value {
                let setRes = await performSetValue(
                    step: ActionStep(action: .setValue, text: textValue, preferBackground: step.preferBackground, restoreCursor: step.restoreCursor),
                    resolved: resolved,
                    targetApp: targetApp,
                    onOverlayEvent: onOverlayEvent
                )
                if !setRes.success {
                    return StepOutcome(
                        success: false,
                        mechanism: "fill-form",
                        message: "Failed to set \(fieldDesc): \(setRes.message ?? setRes.errorCode ?? "unknown error")",
                        node: resolved.node,
                        errorCode: "FORM_FILL_FAILED"
                    )
                }
            }

            filledCount += 1
            lastNode = resolved.node
            axIndexer.invalidate(pid: targetApp.pid)
        }

        if let submitMatch = step.submitMatch, !submitMatch.isEmpty {
            if let blockReason = killSwitch.isBlocked(forSensitiveAction: false, isMutatingAction: true) {
                let hint = ExecutionModeNotice.agentHint(policy: killSwitch.policy, killSwitchTripped: killSwitch.isTripped)
                return StepOutcome(
                    success: false,
                    mechanism: "blocked",
                    message: hint.map { "\(blockReason) \($0)" } ?? blockReason,
                    node: lastNode,
                    errorCode: "POLICY_BLOCKED"
                )
            }
            let submitStep = ActionStep(
                action: .click,
                preferBackground: step.preferBackground,
                restoreCursor: step.restoreCursor,
                match: submitMatch
            )
            switch await resolve(step: submitStep, targetApp: targetApp, scrollOffscreenIntoView: true) {
            case .success(let submitResolved):
                let clickRes = performClick(
                    step: submitStep,
                    resolved: submitResolved,
                    targetApp: targetApp,
                    onOverlayEvent: onOverlayEvent
                )
                if !clickRes.success {
                    return StepOutcome(
                        success: false,
                        mechanism: "fill-form",
                        message: "Filled \(filledCount) field(s), but submit failed: \(clickRes.message ?? clickRes.errorCode ?? "click failed")",
                        node: submitResolved.node,
                        errorCode: "FORM_FILL_FAILED"
                    )
                }
                lastNode = submitResolved.node
            case .failure(let refusal):
                return StepOutcome(
                    success: false,
                    mechanism: "fill-form",
                    message: "Filled \(filledCount) field(s), but submit button was not found: \(refusal.message)",
                    errorCode: "FORM_FILL_FAILED"
                )
            }
        }

        let submitNote = (step.submitMatch?.isEmpty == false) ? " and submitted" : ""
        return StepOutcome(
            success: true,
            mechanism: "fill-form",
            message: "Filled \(filledCount) field\(filledCount == 1 ? "" : "s")\(submitNote)",
            node: lastNode,
            effect: .changed
        )
    }

    private func selectPopUpOption(
        element: AXUIElement,
        desired: String,
        pid: pid_t,
        node: ElementNode?,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> Bool {
        highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        // First try direct AXValue assignment if the popup supports it.
        if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, desired as CFTypeRef) == .success {
            if let rb = Self.axString(element, kAXValueAttribute),
               ElementMatcher.normalize(rb).contains(ElementMatcher.normalize(desired)) {
                return true
            }
        }
        // Otherwise open its AXMenu via AXPress, locate matching AXMenuItem, and press it.
        let gen = axIndexer.currentGeneration(pid: pid)
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            return false
        }
        _ = await axIndexer.waitForChange(pid: pid, sinceGeneration: gen, timeoutMs: 250)
        let wantNorm = ElementMatcher.normalize(desired)
        let children = Self.axChildren(element)
        let menus = children.filter { Self.axString($0, kAXRoleAttribute) == "AXMenu" }
        for menu in menus {
            let items = Self.axChildren(menu)
            if let exact = items.first(where: {
                guard let title = Self.axString($0, kAXTitleAttribute) else { return false }
                return ElementMatcher.normalize(title) == wantNorm
            }) ?? items.first(where: {
                guard let title = Self.axString($0, kAXTitleAttribute) else { return false }
                return ElementMatcher.normalize(title).contains(wantNorm)
            }) {
                return AXUIElementPerformAction(exact, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    func performMenuAction(
        step: ActionStep,
        targetApp: AppDescriptor?,
        siteRuleGuard: (@Sendable (AppDescriptor) async -> String?)?
    ) async -> StepOutcome {
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(
                success: false,
                mechanism: "ax-menu-action",
                message: "menuAction needs a target app.",
                errorCode: "APP_NOT_FOUND"
            )
        }
        guard let menuPath = step.menuPath, !menuPath.isEmpty else {
            return StepOutcome(
                success: false,
                mechanism: "ax-menu-action",
                message: "menuAction requires a non-empty menuPath (e.g. [\"File\", \"Save\"]).",
                errorCode: "INVALID_REQUEST"
            )
        }
        let pid = targetApp.pid
        let hasPin = WindowResolver.pinnedTitle(pid: pid) != nil
        let chromiumGuard = isChromiumApp(targetApp) ? siteRuleGuard : nil
        let focusedWindowId = (hasPin || chromiumGuard != nil) ? InputRouting.focusedWindowId(pid: pid) : nil
        if hasPin {
            let pinnedId = pinnedWindowId(WorkspaceMonitor.withTargetWindow(targetApp))
            guard let pinnedId, focusedWindowId == pinnedId else {
                return StepOutcome(
                    success: false,
                    mechanism: "ax-menu-action",
                    message: "Menus act on \(targetApp.name)'s key window, not the pinned window. Make the pinned window the key window before using menuAction.",
                    errorCode: "TARGET_NOT_FRONTMOST"
                )
            }
        }
        if let chromiumGuard {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            let focusedWindow = Self.axElement(axApp, kAXFocusedWindowAttribute)
            var focusedApp = targetApp
            focusedApp.windowId = focusedWindowId
            focusedApp.windowTitle = focusedWindow.flatMap { Self.axString($0, kAXTitleAttribute) }
            focusedApp.windowBounds = focusedWindow.flatMap(Self.axFrame).map {
                .init(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
            }
            if let message = await chromiumGuard(focusedApp) {
                return StepOutcome(success: false, mechanism: "target-rules", message: message, errorCode: TargetRules.errorCode)
            }
            guard InputRouting.focusedWindowId(pid: pid) == focusedWindowId else {
                return StepOutcome(
                    success: false,
                    mechanism: "ax-menu-action",
                    message: "\(targetApp.name)'s key window changed while checking the site. No menu action was sent.",
                    errorCode: "TARGET_NOT_FRONTMOST"
                )
            }
        }
        let inv = MenuBarController.invoke(pid: pid, appName: targetApp.name, path: menuPath)
        return StepOutcome(
            success: inv.success,
            mechanism: "ax-menu-action",
            message: inv.message ?? inv.result.message,
            errorCode: inv.errorCode,
            effect: inv.success ? .changed : nil
        )
    }
}
