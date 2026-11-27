import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

extension ActionExecutor {
    static func openURLRuleRefusal(normalizedURL: String, handlerBundleId: String?, rules: TargetRules) -> String? {
        if rules.blocksURL(normalizedURL) {
            return TargetRules.blockedSiteMessage(host: TargetRules.host(ofURL: normalizedURL))
        }
        if let handlerBundleId, rules.blocksApp(bundleId: handlerBundleId) {
            return "The default app for this URL (\(handlerBundleId)) is blocked by UseMac target rules. \(TargetRules.stopHint)"
        }
        return nil
    }

    func performOpenURL(step: ActionStep) async -> StepOutcome {
        let normalizedURL: String
        switch NavigationPolicy.validate(step.url ?? step.text) {
        case .success(let validURL):
            normalizedURL = validURL
        case .failure(let blocked):
            return StepOutcome(success: false, mechanism: "open-url", message: blocked.message, errorCode: "URL_BLOCKED")
        }
        guard let parsedURL = URL(string: normalizedURL) else {
            return StepOutcome(success: false, mechanism: "open-url", message: "Invalid URL.", errorCode: "INVALID_REQUEST")
        }
        let handlerBundleId = NSWorkspace.shared.urlForApplication(toOpen: parsedURL)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        if let message = Self.openURLRuleRefusal(
            normalizedURL: normalizedURL, handlerBundleId: handlerBundleId, rules: TargetRulesStore.shared.rules
        ) {
            return StepOutcome(success: false, mechanism: "target-rules", message: message, errorCode: TargetRules.errorCode)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = (step.preferBackground == false)
        do {
            _ = try await NSWorkspace.shared.open(parsedURL, configuration: config)
            return StepOutcome(success: true, mechanism: "nsworkspace-open", message: "Opened \(normalizedURL)", effect: .unverified)
        } catch {
            return StepOutcome(success: false, mechanism: "nsworkspace-open", message: error.localizedDescription)
        }
    }

    func performFocus(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        if let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            let raiseErr = step.preferBackground == false
                ? AXUIElementPerformAction(axEl, kAXRaiseAction as CFString)
                : .apiDisabled
            let focusErr = step.preferBackground == false
                ? AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                : .apiDisabled
            if step.preferBackground == false, resolved.pid > 0 {
                _ = NSRunningApplication(processIdentifier: resolved.pid)?.activate(options: [])
            }
            if raiseErr == .success || focusErr == .success {
                return StepOutcome(success: true, mechanism: "ax-focus", node: resolved.node)
            }
            if step.preferBackground != false {
                return StepOutcome(
                    success: true,
                    mechanism: "background-noop-focus",
                    node: resolved.node,
                    effect: .unverified,
                    warning: "Focus is not moved in the background (it would pull the app forward). setValue/axAction work without focus."
                )
            }
        }

        if step.preferBackground == false,
           let pid = targetApp?.pid,
           let running = NSRunningApplication(processIdentifier: pid) {
            let ok = running.activate(options: [])
            return StepOutcome(
                success: ok,
                mechanism: "app-activate",
                message: ok ? nil : "Failed to activate app",
                node: resolved.node
            )
        }

        return StepOutcome(
            success: false,
            mechanism: "app-activate",
            message: "No target app or element to focus",
            node: resolved.node
        )
    }

    func performClick(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        // Chromium's native "New Tab" AXPress triggers BrowserWindow::Activate() and steals focus.
        // Intercept in background mode and dispatch zero-focus Cmd+T directly to the background PID.
        if let bgPid,
           let node = resolved.node,
           node.role == "AXButton",
           let title = node.title?.lowercased(),
           (title == "new tab" || title == "nova guia"),
           isChromiumApp(targetApp) {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            let shortcutStep = ActionStep(action: .pressKey, key: "t", modifiers: ["cmd"], preferBackground: true)
            var res = performPressKey(step: shortcutStep, resolved: ResolvedElement(pid: bgPid), targetApp: targetApp)
            res.mechanism = "cgevent-pid-newtab"
            res.node = node
            return res
        }

        if step.preferBackground != false,
           let axEl = resolved.element,
           let node = resolved.node,
           node.actions.contains("AXPress") {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if AXUIElementPerformAction(axEl, kAXPressAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-press", node: node)
            }
        }

        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: resolved.node?.offscreen == true
                    ? "Element \(resolved.node?.id ?? "") is scrolled out of view and could not be scrolled into view."
                    : "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point)
            ?? pointerRefusal(targetApp, at: point, input: "clicks") {
            var refusedWithNode = refused
            refusedWithNode.node = resolved.node
            return refusedWithNode
        }

        pulse(point, label: resolved.node?.id ?? "click", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let ok = postMouseClick(
            at: point,
            button: .left,
            clickCount: 1,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid,
            windowId: targetApp?.windowId
        )
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post CGEvent click",
            node: resolved.node
        )
    }

    func performHover(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        var bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil {
            if let refused = frontmostGuard(targetApp, input: "mouse movement", at: point) {
                return refused
            }
            switch pointerRoute(targetApp, at: point, backgroundAllowed: step.preferBackground != false) {
            case .foreground:
                break
            case .background:
                bgPid = targetApp?.pid
            case .refuse(let covering):
                return coveredWindowOutcome(targetApp: targetApp, covering: covering, input: "mouse movement")
            }
        }

        if resolved.node != nil {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        } else {
            pulse(point, label: "hover", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return StepOutcome(success: false, mechanism: "cgevent-hover", message: "Failed to construct CGEvent mouseMoved", node: resolved.node)
        }
        if let bgPid {
            Self.routeToWindow(moveEvent, windowId: targetApp?.windowId)
            moveEvent.postToPid(bgPid)
        } else {
            moveEvent.post(tap: .cghidEventTap)
            noteSyntheticInput()
        }
        return StepOutcome(
            success: true,
            mechanism: bgPid != nil ? "cgevent-pid-hover" : "cgevent-hover",
            node: resolved.node,
            effect: .unverified
        )
    }

    func performDoubleClick(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        // Rows in file pickers, Finder-like lists and tables open with AXOpen: no events, no focus needed.
        if step.preferBackground != false,
           let element = resolved.element,
           let node = resolved.node,
           node.actions.contains("AXOpen") {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if AXUIElementPerformAction(element, "AXOpen" as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-open", node: node)
            }
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point)
            ?? pointerRefusal(targetApp, at: point, input: "clicks") {
            return refused
        }

        pulse(point, label: resolved.node?.id ?? "doubleClick", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let ok = postMouseClick(
            at: point,
            button: .left,
            clickCount: 2,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid,
            windowId: targetApp?.windowId
        )
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post double click",
            node: resolved.node
        )
    }

    func performRightClick(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) -> StepOutcome {
        if step.preferBackground != false,
           let element = resolved.element,
           let node = resolved.node,
           node.actions.contains("AXShowMenu") {
            highlight(node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-show-menu", node: node)
            }
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        guard let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp) else {
            return StepOutcome(
                success: false,
                mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
                message: "Missing coordinates or element",
                node: resolved.node,
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "clicks", at: point)
            ?? pointerRefusal(targetApp, at: point, input: "clicks") {
            return refused
        }

        pulse(point, label: resolved.node?.id ?? "rightClick", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        let ok = postMouseClick(
            at: point,
            button: .right,
            clickCount: 1,
            restoreCursor: step.restoreCursor != false,
            targetPid: bgPid,
            windowId: targetApp?.windowId
        )
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-click" : "cgevent-hid",
            message: ok ? nil : "Failed to post right click",
            node: resolved.node
        )
    }

    func performSetValue(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let text = step.text ?? ""
        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        let omniboxWarning = isChromiumApp(targetApp) && Self.isAddressBar(resolved.node)
            ? "Typing into Chrome's address bar acts on whichever tab is active at that moment. To navigate, use browser_open with tabId (works on Web Store and chrome:// pages too)."
            : nil

        if step.preferBackground != false, let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            // IMPORTANT: Never set kAXFocusedAttribute while app is in background!
            // In Chromium/Electron, kAXFocusedAttribute calls Widget::Activate() and steals focus/Spaces.
            // The same goes for a window of the app in front that is not its focused window (one UseMac opened
            // behind the user's): focusing it would bring it over the user's window and take their keys.
            if bgPid == nil, keyWindowGuard(targetApp, input: "typing") == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            let beforeValue = resolved.node?.value ?? Self.axString(axEl, kAXValueAttribute)
            let genBefore = resolved.pid > 0 ? axIndexer.currentGeneration(pid: resolved.pid) : 0
            if AXUIElementSetAttributeValue(axEl, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                var readBack = Self.axString(axEl, kAXValueAttribute)
                let isToggle = ["AXCheckBox", "AXRadioButton", "AXSwitch"].contains(resolved.node?.role ?? "")
                let isSecure = Self.axString(axEl, kAXSubroleAttribute) == "AXSecureTextField"
                // Chromium sets the value in the page and updates its accessibility tree a moment later: wait
                // briefly via AXObserver before inspecting readback.
                if !isToggle, !isSecure, let current = readBack,
                   ElementMatcher.normalize(current) != ElementMatcher.normalize(text) {
                    var waitedMs = 0
                    var lastGen = genBefore
                    while waitedMs < 300 {
                        if resolved.pid > 0 {
                            _ = await axIndexer.waitForChange(pid: resolved.pid, sinceGeneration: lastGen, timeoutMs: 50)
                            lastGen = axIndexer.currentGeneration(pid: resolved.pid)
                        } else {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        waitedMs += 50
                        readBack = Self.axString(axEl, kAXValueAttribute)
                        if let rb = readBack,
                           ElementMatcher.normalize(rb) == ElementMatcher.normalize(text)
                           || ElementMatcher.normalize(rb) != ElementMatcher.normalize(beforeValue ?? "") {
                            break
                        }
                    }
                }
                let eval = Self.evaluateSetValueReadBack(
                    requested: text,
                    before: beforeValue,
                    readBack: readBack,
                    isToggle: isToggle,
                    isSecure: isSecure,
                    isChromiumBackground: bgPid != nil && isChromiumApp(targetApp)
                )
                return StepOutcome(
                    success: true,
                    mechanism: "ax-set-value",
                    message: eval.message,
                    node: resolved.node,
                    effect: eval.effect,
                    warning: eval.warning ?? omniboxWarning
                )
            }
        }

        if bgPid == nil {
            let point = resolvePoint(step: step, node: resolved.node, targetApp: targetApp)
            if let refused = frontmostGuard(targetApp, input: "typing", at: point)
                ?? keyWindowGuard(targetApp, input: "typing")
                ?? point.flatMap({ pointerRefusal(targetApp, at: $0, input: "clicks") }) {
                return refused
            }
            if let point {
                pulse(point, label: resolved.node?.id ?? "setValue", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                _ = postMouseClick(at: point, button: .left, clickCount: 1, restoreCursor: step.restoreCursor != false, targetPid: nil)
            }
        }

        let ok = typeUnicodeString(text, targetPid: bgPid)
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-unicode" : "cgevent-unicode",
            message: ok ? nil : "Failed to type text",
            node: resolved.node,
            warning: omniboxWarning ?? (resolved.element != nil ? "AXValue could not be set; typed the text instead." : nil)
        )
    }

    /// Evaluates `AXValue` readback after `setValue`: if the app reformatted the text (so `readBack != before`),
    /// reports `effect: .changed` with an informational message instead of a false `effect: .none` warning.
    static func evaluateSetValueReadBack(
        requested: String,
        before: String?,
        readBack: String?,
        isToggle: Bool,
        isSecure: Bool,
        isChromiumBackground: Bool = false
    ) -> (effect: ActionEffect, message: String?, warning: String?) {
        if isToggle || isSecure {
            return (.changed, nil, nil)
        }
        guard let readBack else {
            return (.changed, nil, nil)
        }
        let normReq = ElementMatcher.normalize(requested)
        let normRead = ElementMatcher.normalize(readBack)
        if normRead == normReq {
            return (.changed, nil, nil)
        }
        let normBefore = ElementMatcher.normalize(before ?? "")
        if normRead != normBefore {
            return (
                .changed,
                "Field value updated and formatted as \"\(readBack.prefix(80))\".",
                nil
            )
        }
        if isChromiumBackground {
            return (
                ActionEffect.none,
                nil,
                "The field still reads back \"\(readBack.prefix(60))\" instead of the text you set: web fields in background Chrome/Chromium windows (such as RESTRICTED_PAGE windows) often ignore AXValue without focus. Retry this batch with \"foreground\": true."
            )
        }
        return (
            ActionEffect.none,
            nil,
            "The field still reads back \"\(readBack.prefix(60))\" instead of the text you set: the app may have rejected it."
        )
    }

    private static func isAddressBar(_ node: ElementNode?) -> Bool {
        guard let node, node.role == "AXTextField" else { return false }
        let title = (node.title ?? "").lowercased()
        return title.contains("address") || title.contains("endereço") || title.contains("omnibox")
    }

    func performType(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?,
        pickerReceiver: AXUIElement? = nil
    ) -> StepOutcome {
        let text = step.text ?? ""
        let bgPid = backgroundPid(for: step, targetApp: targetApp)

        // Where a real click places the caret first (an element or explicit coordinates).
        let clickPoint: CGPoint? = bgPid == nil && (resolved.node != nil || (step.x != nil && step.y != nil))
            ? resolvePoint(step: step, node: resolved.node, targetApp: targetApp)
            : nil
        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "typing", at: resolvePoint(step: step, node: resolved.node, targetApp: targetApp))
            ?? keyWindowGuard(targetApp, input: "typing", pickerReceiver: pickerReceiver)
            ?? clickPoint.flatMap({ pointerRefusal(targetApp, at: $0, input: "clicks") }) {
            return refused
        }

        if let axEl = resolved.element {
            highlight(resolved.node, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            // Only set kAXFocusedAttribute if already frontmost; otherwise it activates background Chromium/Electron windows.
            if bgPid == nil {
                _ = AXUIElementSetAttributeValue(axEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        if let point = clickPoint {
            pulse(point, label: resolved.node?.id ?? "type", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            _ = postMouseClick(at: point, button: .left, clickCount: 1, restoreCursor: step.restoreCursor != false, targetPid: nil)
        }

        let ok = typeUnicodeString(text, targetPid: bgPid)
        if bgPid == nil { noteSyntheticInput() }
        return StepOutcome(
            success: ok,
            mechanism: bgPid != nil ? "cgevent-pid-unicode" : "cgevent-unicode",
            message: ok ? nil : "Failed to type text",
            node: resolved.node
        )
    }

    func performPressKey(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        pickerReceiver: AXUIElement? = nil
    ) -> StepOutcome {
        guard let keyName = step.key?.trimmingCharacters(in: .whitespacesAndNewlines),
              let keyCode = NativeKeyMap.keyCode(for: step.key) else {
            return StepOutcome(
                success: false,
                mechanism: "cgevent-key",
                message: NativeKeyMap.unsupportedKeyMessage(for: step.key),
                errorCode: "INVALID_REQUEST"
            )
        }

        let bgPid = backgroundPid(for: step, targetApp: targetApp)
        var warning: String?
        if bgPid != nil,
           (keyName.lowercased() == "return" || keyName.lowercased() == "enter"),
           (step.modifiers?.isEmpty ?? true),
           let axEl = resolved.element {
            if AXUIElementPerformAction(axEl, kAXConfirmAction as CFString) == .success {
                return StepOutcome(success: true, mechanism: "ax-confirm", node: resolved.node)
            }
            warning = "AXConfirm failed on \(resolved.node?.id ?? "the element"); sent a key event instead."
        }

        if bgPid == nil, let refused = frontmostGuard(targetApp, input: "key presses")
            ?? keyWindowGuard(targetApp, input: "key presses", pickerReceiver: pickerReceiver) {
            return refused
        }

        let flags = modifierFlags(from: step.modifiers)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return StepOutcome(success: false, mechanism: "cgevent-key", message: "Failed to construct key CGEvent")
        }

        down.flags = flags
        up.flags = flags
        if let bgPid {
            down.postToPid(bgPid)
            up.postToPid(bgPid)
            return StepOutcome(success: true, mechanism: "cgevent-pid-key", node: resolved.node, warning: warning)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        noteSyntheticInput()
        return StepOutcome(success: true, mechanism: "cgevent-key", node: resolved.node, warning: warning)
    }

    /// AppKit routes mouse and wheel events to a window by these fields; events posted straight to a pid
    /// arrive without them, so a background app has no window to deliver them to.
    static func routeToWindow(_ event: CGEvent, windowId: UInt32?) {
        guard let windowId else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowId))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowId))
    }

    private func postMouseClick(
        at point: CGPoint,
        button: CGMouseButton,
        clickCount: Int,
        restoreCursor: Bool,
        targetPid: pid_t? = nil,
        windowId: UInt32? = nil
    ) -> Bool {
        let savedCursor = targetPid == nil ? CGEvent(source: nil)?.location : nil
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp

        for clickState in 1...max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                return false
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            if let targetPid {
                Self.routeToWindow(down, windowId: windowId)
                Self.routeToWindow(up, windowId: windowId)
                down.postToPid(targetPid)
                up.postToPid(targetPid)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }

        if targetPid == nil, restoreCursor, let savedCursor {
            _ = CGWarpMouseCursorPosition(savedCursor)
        }
        return true
    }

    private func typeUnicodeString(_ text: String, targetPid: pid_t? = nil) -> Bool {
        guard !text.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let utf16 = Array(text.utf16)
        // Post in small chunks to avoid exceeding CGEvent unicode string buffer limits
        let chunkSize = 16
        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var slice = Array(utf16[index..<end])

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }

            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            if let targetPid {
                down.postToPid(targetPid)
                up.postToPid(targetPid)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }

            index = end
        }
        return true
    }

    private func modifierFlags(from modifiers: [String]?) -> CGEventFlags {
        ModifierAliases.eventFlags(modifiers)
    }

    func performDrag(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let hasSource = step.elementId?.isEmpty == false || step.match?.isEmpty == false || (step.x != nil && step.y != nil)
        guard hasSource else {
            return StepOutcome(success: false, mechanism: "drag",
                               message: "drag needs a source elementId, match, or x/y coordinates.", errorCode: "INVALID_REQUEST")
        }
        let end: CGPoint
        let destination: ElementNode?
        switch await resolveDragDestination(step: step, targetApp: targetApp) {
        case .success(let result):
            (end, destination) = result
        case .failure(let refusal):
            return StepOutcome(success: false, mechanism: refusal.mechanism, message: refusal.message, errorCode: refusal.errorCode)
        }
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(success: false, mechanism: "drag", message: "drag needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        guard resolved.pid == targetApp.pid else {
            return StepOutcome(success: false, mechanism: "drag", message: "The drag source is not in the target app.", errorCode: "ELEMENT_NOT_FOUND")
        }
        // Resolving an offscreen destination can scroll the source out of view or move its center.
        let sourceNode = resolved.node.flatMap { axIndexer.liveNode(for: $0.id, pid: resolved.pid)?.node }
        guard let start = resolvePoint(step: step, node: sourceNode, targetApp: targetApp) else {
            return StepOutcome(success: false, mechanism: "drag", message: "The drag source has no visible point.", errorCode: "ELEMENT_NOT_FOUND")
        }
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else {
            return StepOutcome(success: false, mechanism: "drag", message: "drag coordinates must be finite.", errorCode: "INVALID_REQUEST")
        }
        for point in [start, end] {
            if let refusal = frontmostGuard(targetApp, input: "drag", at: point)
                ?? pointerRefusal(targetApp, at: point, input: "drag") {
                return refusal
            }
        }
        if let windowId = targetApp.windowId {
            let windows = InputRouting.pointerWindows()
            for point in [start, end] {
                let covering = InputRouting.receiver(at: point, in: windows)
                if covering?.windowId != windowId {
                    return coveredWindowOutcome(targetApp: targetApp, covering: covering, input: "drag")
                }
            }
        }

        let savedCursor = step.restoreCursor != false ? CGEvent(source: nil)?.location : nil
        let flags = modifierFlags(from: step.modifiers)
        func event(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            if step.modifiers != nil { event?.flags = flags }
            if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
            return event
        }
        let stepsCount = 10
        let durationMs = min(2_000, max(80, step.durationMs ?? 200))
        let motion = (1...stepsCount).compactMap { index -> CGEvent? in
            let fraction = CGFloat(index) / CGFloat(stepsCount)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            return event(.leftMouseDragged, at: point)
        }
        guard let move = event(.mouseMoved, at: start), let down = event(.leftMouseDown, at: start),
              let up = event(.leftMouseUp, at: start), motion.count == stepsCount else {
            return StepOutcome(success: false, mechanism: "drag", message: "Failed to construct the drag events.", errorCode: "INVALID_REQUEST")
        }
        highlight(sourceNode, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        pulse(start, label: sourceNode?.id ?? "drag", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
        if let reason = killSwitch.isBlocked() {
            return StepOutcome(success: false, mechanism: "drag", message: reason, errorCode: "POLICY_BLOCKED")
        }
        if !WindowResolver.isFrontmost(pid: targetApp.pid) {
            return notFrontmostOutcome(targetApp: targetApp, input: "drag")
        }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        var lastPoint = start
        var completed = false
        defer {
            // Always release the button at the last delivered point, including after an emergency stop.
            up.location = lastPoint
            up.post(tap: .cghidEventTap)
            noteSyntheticInput()
            if let savedCursor { _ = CGWarpMouseCursorPosition(savedCursor) }
            if completed {
                highlight(destination, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
                pulse(end, label: destination?.id ?? "drop", targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            }
        }
        let started = ContinuousClock.now
        for (index, drag) in motion.enumerated() {
            let deadline = started + .milliseconds(durationMs * (index + 1) / stepsCount)
            try? await Task.sleep(until: deadline)
            if let reason = killSwitch.isBlocked() {
                return StepOutcome(success: false, mechanism: "drag", message: reason, errorCode: "POLICY_BLOCKED")
            }
            guard !Task.isCancelled, WindowResolver.isFrontmost(pid: targetApp.pid) else {
                // The gesture already started; never replay it through foreground fallback.
                return StepOutcome(success: false, mechanism: "drag", message: "The drag was interrupted.", errorCode: "USER_ACTIVE")
            }
            drag.post(tap: .cghidEventTap)
            lastPoint = drag.location
        }
        completed = true
        return StepOutcome(success: true, mechanism: "drag", node: sourceNode)
    }

    func resolveDragDestination(
        step: ActionStep, targetApp: AppDescriptor?
    ) async -> Result<(point: CGPoint, node: ElementNode?), Refusal> {
        if step.toMatch?.isEmpty == false || step.toElementId?.isEmpty == false {
            let destination = ActionStep(action: .drag, app: step.app, elementId: step.toElementId, match: step.toMatch)
            switch await resolve(step: destination, targetApp: targetApp, scrollOffscreenIntoView: true) {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(let resolved):
                guard resolved.pid == targetApp?.pid,
                      let point = resolvePoint(step: destination, node: resolved.node, targetApp: targetApp) else {
                    return .failure(Refusal(mechanism: "drag", errorCode: "ELEMENT_NOT_FOUND", message: "The drag destination is not visible in the target app."))
                }
                return .success((point, resolved.node))
            }
        }
        if let toX = step.toX, let toY = step.toY {
            return .success((CGPoint(x: toX, y: toY), nil))
        }
        return .failure(Refusal(mechanism: "drag", errorCode: "INVALID_REQUEST",
                                message: "drag needs a destination: pass toElementId, toMatch, or toX and toY."))
    }
}
