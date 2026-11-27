import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UseMacProtocol

extension ActionExecutor {
    // MARK: - Preconditions

    /// Stale-snapshot and expected-title checks. Returns a refusal when the batch must not run.
    func preflightRefusal(_ request: BatchActionRequest, targetApp: AppDescriptor?) -> Refusal? {
        // The app the batch resolved to, named or not (the app in front), may be one the user's rules block.
        if let blocked = TargetRulesStore.shared.blockedMessage(for: targetApp) {
            return Refusal(mechanism: "target-rules", errorCode: TargetRules.errorCode, message: blocked)
        }
        guard let pid = targetApp?.pid, pid > 0 else { return nil }
        if let pinned = WindowResolver.pinnedTitle(pid: pid), WindowResolver.window(pid: pid, titleContains: pinned) == nil {
            return Refusal(
                mechanism: "window-pin",
                errorCode: "ELEMENT_NOT_FOUND",
                message: "No \(targetApp?.name ?? "app") window has a title containing \"\(pinned)\" anymore. Observe again (without `window` for the focused window)."
            )
        }
        let stepsSwitchApps = request.steps.contains { step in
            guard let app = step.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return false }
            return workspaceMonitor.resolveApp(query: app)?.pid != pid
        }
        if stepsSwitchApps { return nil }

        let usesSnapshotIds = request.allowStaleSnapshot != true && request.steps.contains { step in
            guard step.optional != true else { return false }
            let stepHasId = (step.elementId?.isEmpty == false) && (step.match == nil || step.match?.isEmpty == true)
            let destinationHasId = step.action == .drag && step.toElementId?.isEmpty == false && step.toMatch?.isEmpty != false
            let formHasId = step.fields?.contains(where: { ($0.elementId?.isEmpty == false) && ($0.match == nil || $0.match?.isEmpty == true) }) == true
            return stepHasId || destinationHasId || formHasId
        }
        let expected = request.expectWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usesSnapshotIds || (expected?.isEmpty == false) else { return nil }

        let current = axIndexer.currentContext(pid: pid)

        if usesSnapshotIds, let snapshot = axIndexer.snapshotContext(pid: pid), let current {
            let decision = Self.evaluateStaleSnapshot(
                snapshot: snapshot,
                current: current,
                elementsAlive: { self.allReferencedElementsAlive(in: request.steps, pid: pid) }
            )
            if decision.shouldRefuse {
                if decision.windowChanged {
                    return Refusal(
                        mechanism: "stale-check",
                        errorCode: "STALE_SNAPSHOT",
                        message: "The \(targetApp?.name ?? "app") window changed since the last observe (now \"\(current.windowTitle ?? "untitled")\"). Element ids would hit the wrong place: observe again, or use `match`."
                    )
                }
                return Refusal(
                    mechanism: "stale-check",
                    errorCode: "STALE_SNAPSHOT",
                    message: "The window now shows \"\(current.windowTitle ?? "")\" but the last observe saw \"\(snapshot.windowTitle ?? "")\". Observe again, or use `match`, or pass allowStaleSnapshot if this is expected."
                )
            }
        }

        if let expected, !expected.isEmpty {
            let have = current?.windowTitle ?? targetApp?.windowTitle ?? ""
            if !Self.comparableTitle(have).contains(Self.comparableTitle(expected)) {
                return Refusal(
                    mechanism: "expect-title",
                    errorCode: "STALE_SNAPSHOT",
                    message: "Expected the window title to contain \"\(expected)\", but it is \"\(have)\". Nothing was sent."
                )
            }
        }
        return nil
    }

    /// Evaluates whether snapshot ids are stale. Always refuses when `windowId` changed; when `windowId` is
    /// unchanged and only `comparableTitle` drifted, verifies per-element liveness instead of aborting blindly.
    static func evaluateStaleSnapshot(
        snapshot: AXIndexer.SnapshotContext,
        current: AXIndexer.SnapshotContext,
        elementsAlive: () -> Bool
    ) -> (shouldRefuse: Bool, windowChanged: Bool) {
        if let before = snapshot.windowId, let now = current.windowId, before != now {
            return (true, true)
        }
        if let before = snapshot.windowTitle, let now = current.windowTitle,
           comparableTitle(before) != comparableTitle(now) {
            let sameWindow = (snapshot.windowId != nil && snapshot.windowId == current.windowId)
            if sameWindow && elementsAlive() {
                return (false, false)
            }
            return (true, false)
        }
        return (false, false)
    }

    private func allReferencedElementsAlive(in steps: [ActionStep], pid: pid_t) -> Bool {
        var ids: [String] = []
        for step in steps where step.optional != true {
            if let id = step.elementId, !id.isEmpty, (step.match == nil || step.match?.isEmpty == true) {
                ids.append(id)
            }
            if step.action == .drag, let id = step.toElementId, !id.isEmpty, step.toMatch?.isEmpty != false {
                ids.append(id)
            }
            if let fields = step.fields {
                for field in fields {
                    if let id = field.elementId, !id.isEmpty, (field.match == nil || field.match?.isEmpty == true) {
                        ids.append(id)
                    }
                }
            }
        }
        guard !ids.isEmpty else { return true }
        for id in ids {
            let cachedRole = axIndexer.node(for: id, pid: pid)?.role
            guard let live = axIndexer.liveNode(for: id, pid: pid) else {
                return false
            }
            if let cachedRole,
               ElementMatcher.normalizeRole(live.node.role) != ElementMatcher.normalizeRole(cachedRole) {
                return false
            }
        }
        return true
    }

    /// Letters only, folded: unread counters, emoji and punctuation do not make a window "different".
    static func comparableTitle(_ title: String) -> String {
        let letters = title.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return ElementMatcher.normalize(String(letters))
    }

    // MARK: - Foreground burst

    static func remainingBudgetMs(nowNs: UInt64, deadlineNs: UInt64) -> Int {
        guard nowNs < deadlineNs else { return 0 }
        return Int((deadlineNs - nowNs) / 1_000_000)
    }

    func beginForegroundBurst(targetApp: AppDescriptor?, waitForIdleMs: Int? = nil) async -> Result<ForegroundBurst, Refusal> {
        guard let app = targetApp, app.pid > 0,
              let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            return .failure(Refusal(mechanism: "foreground-burst", errorCode: "APP_NOT_FOUND", message: "A foreground burst needs a running target app."))
        }
        let idleWaitBudgetMs = min(max(0, waitForIdleMs ?? 2000), 60_000)
        var idle = WindowResolver.secondsSinceUserInput()
        if idle < Self.userIdleRequiredSeconds && !idleIsFromOwnInput(idle) && idleWaitBudgetMs > 0 {
            let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(idleWaitBudgetMs) * 1_000_000
            while true {
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let remainingMs = Self.remainingBudgetMs(nowNs: nowNs, deadlineNs: deadlineNs)
                guard remainingMs > 0 else { break }
                let toIdleMs = Int(max(40, (Self.userIdleRequiredSeconds - idle) * 1000.0))
                let sliceMs = min(150, toIdleMs, remainingMs)
                try? await Task.sleep(nanoseconds: UInt64(sliceMs) * 1_000_000)
                idle = WindowResolver.secondsSinceUserInput()
                if idle >= Self.userIdleRequiredSeconds || idleIsFromOwnInput(idle) {
                    break
                }
            }
        }
        if idle < Self.userIdleRequiredSeconds && !idleIsFromOwnInput(idle) {
            return .failure(Refusal(
                mechanism: "foreground-burst",
                errorCode: "USER_ACTIVE",
                message: String(format: "The user used the keyboard or mouse %.1f s ago. UseMac will not take over the screen while they are active; retry in a moment or stay in the background.", idle)
            ))
        }

        let previous = NSWorkspace.shared.frontmostApplication
        let cursor = CGEvent(source: nil)?.location
        if !WindowResolver.isFrontmost(pid: app.pid) {
            let activated = await waitForApplicationActivation(pid: app.pid, timeoutMs: 1500) {
                _ = running.activate(options: [])
            }
            guard activated && WindowResolver.isFrontmost(pid: app.pid) else {
                return .failure(Refusal(
                    mechanism: "foreground-burst",
                    errorCode: "TARGET_NOT_FRONTMOST",
                    message: "\(app.name) did not come to the front, so nothing was sent."
                ))
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        var previousWindow: AXUIElement?
        var borrowedWindowId: CGWindowID?
        if let pinned = WindowResolver.pinnedTitle(pid: app.pid),
           let pinnedWindow = WindowResolver.window(pid: app.pid, titleContains: pinned),
           let pinnedID = WindowResolver.windowID(of: pinnedWindow),
           InputRouting.focusedWindowId(pid: app.pid) != pinnedID {
            let axApp = AXUIElementCreateApplication(app.pid)
            if let focusedWindow = Self.axElement(axApp, kAXFocusedWindowAttribute),
               !CFEqual(focusedWindow, pinnedWindow) {
                previousWindow = focusedWindow
            }
            Self.raiseAXWindow(pinnedWindow)
            borrowedWindowId = pinnedID
            let deadline = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < deadline, WindowResolver.isFrontmost(pid: app.pid),
                  InputRouting.focusedWindowId(pid: app.pid) != pinnedID {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return .success(ForegroundBurst(
            targetPid: app.pid,
            previousApp: previous?.processIdentifier == app.pid ? nil : previous,
            previousWindow: previousWindow,
            borrowedWindowId: borrowedWindowId,
            savedCursor: cursor
        ))
    }

    private final class ActivationWaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var observer: NSObjectProtocol?
        private var timeoutItem: DispatchWorkItem?
        private let continuation: CheckedContinuation<Bool, Never>

        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func attach(observer: NSObjectProtocol, timeoutItem: DispatchWorkItem) {
            var alreadyDone = false
            lock.lock()
            if resumed {
                alreadyDone = true
            } else {
                self.observer = observer
                self.timeoutItem = timeoutItem
            }
            lock.unlock()
            if alreadyDone {
                timeoutItem.cancel()
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }

        func complete(_ ok: Bool) {
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            resumed = true
            let obs = observer
            observer = nil
            let item = timeoutItem
            timeoutItem = nil
            lock.unlock()
            item?.cancel()
            if let obs {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
            continuation.resume(returning: ok)
        }
    }

    func waitForApplicationActivation(
        pid: pid_t,
        timeoutMs: Int,
        activate: @escaping () -> Void
    ) async -> Bool {
        if WindowResolver.isFrontmost(pid: pid) { return true }
        return await withCheckedContinuation { continuation in
            let state = ActivationWaitState(continuation: continuation)
            let obs = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { note in
                if let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   activated.processIdentifier == pid {
                    state.complete(true)
                }
            }
            let item = DispatchWorkItem {
                state.complete(WindowResolver.isFrontmost(pid: pid))
            }
            state.attach(observer: obs, timeoutItem: item)

            activate()

            if WindowResolver.isFrontmost(pid: pid) {
                state.complete(true)
                return
            }

            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .milliseconds(max(1, timeoutMs)),
                execute: item
            )
        }
    }

    static func shouldRestorePreviousWindow(
        appIsFrontmost: Bool,
        borrowedWindowId: CGWindowID?,
        currentFocusedWindowId: CGWindowID?,
        secondsSinceUserInput: Double,
        ownInputRecent: Bool
    ) -> Bool {
        appIsFrontmost
            && (borrowedWindowId == nil || currentFocusedWindowId == borrowedWindowId)
            && (secondsSinceUserInput >= userIdleRequiredSeconds || ownInputRecent)
    }

    func endForegroundBurst(_ burst: ForegroundBurst) async {
        if let cursor = burst.savedCursor {
            _ = CGWarpMouseCursorPosition(cursor)
        }
        if let previousWindow = burst.previousWindow {
            let idle = WindowResolver.secondsSinceUserInput()
            if Self.shouldRestorePreviousWindow(
                appIsFrontmost: WindowResolver.isFrontmost(pid: burst.targetPid),
                borrowedWindowId: burst.borrowedWindowId,
                currentFocusedWindowId: InputRouting.focusedWindowId(pid: burst.targetPid),
                secondsSinceUserInput: idle,
                ownInputRecent: idleIsFromOwnInput(idle)
            ) {
                Self.raiseAXWindow(previousWindow)
            }
        }
        if let previous = burst.previousApp, !previous.isTerminated, WindowResolver.isFrontmost(pid: burst.targetPid) {
            _ = previous.activate(options: [])
        }
    }

    func noteSyntheticInput() {
        syntheticInputLock.lock()
        lastSyntheticInputAt = Date()
        syntheticInputLock.unlock()
    }

    /// True when the most recent HID event is one UseMac posted itself.
    func idleIsFromOwnInput(_ idle: Double) -> Bool {
        syntheticInputLock.lock()
        let last = lastSyntheticInputAt
        syntheticInputLock.unlock()
        let sinceOwn = Date().timeIntervalSince(last)
        return abs(sinceOwn - idle) < 0.25
    }

    /// Real (HID) input goes to whatever app is in front. Refuse unless that is the target.
    /// `point` is where a mouse event would land, for the check that it is not a UseMac window.
    func frontmostGuard(_ targetApp: AppDescriptor?, input: String, at point: CGPoint? = nil) -> StepOutcome? {
        if let point, let refusal = killSwitch.approvalPromptRefusal(at: point) {
            return StepOutcome(success: false, mechanism: "self-target", message: refusal, errorCode: "SELF_TARGET_BLOCKED")
        }
        if let pid = targetApp?.pid, pid > 0, !WindowResolver.isFrontmost(pid: pid) {
            return notFrontmostOutcome(targetApp: targetApp, input: input)
        }
        return ownWindowGuard(targetApp, at: point)
    }

    /// Real input lands in whichever window the window server picks, which can be a UseMac window (Settings)
    /// even when the target is another app. Refuse before sending anything when it would.
    private func ownWindowGuard(_ targetApp: AppDescriptor?, at point: CGPoint?) -> StepOutcome? {
        var receivers: [pid_t] = []
        // Topmost normal window at the point. UseMac's overlays sit above layer 0 and let clicks through.
        if let point, let top = WindowResolver.onScreenWindows().first(where: { $0.frame.contains(point) }) {
            receivers.append(top.pid)
        }
        // Without a target app, keys and clicks go to whatever app is in front.
        if (targetApp?.pid ?? 0) <= 0, let front = WindowResolver.frontmostPid() {
            receivers.append(front)
        }
        if receivers.contains(where: { !workspaceMonitor.isUseMacProcess(pid: $0) && TargetRulesStore.shared.blocksProcess(pid: $0) }) {
            return StepOutcome(
                success: false,
                mechanism: "target-rules",
                message: "This input would land in a window of an app the user's UseMac rules block, so nothing was sent. \(TargetRules.stopHint)",
                errorCode: TargetRules.errorCode
            )
        }
        guard receivers.contains(where: { workspaceMonitor.isUseMacProcess(pid: $0) }) else { return nil }
        return StepOutcome(
            success: false,
            mechanism: "self-target",
            message: "This input would land in a UseMac window, so nothing was sent. \(WorkspaceMonitor.selfTargetMessage)",
            errorCode: "SELF_TARGET_BLOCKED"
        )
    }

    func notFrontmostOutcome(targetApp: AppDescriptor?, input: String) -> StepOutcome {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
        return StepOutcome(
            success: false,
            mechanism: "hid-guard",
            message: "\(targetApp?.name ?? "The target app") is not in front (\(front) is), so UseMac did not send real \(input): it would have landed in the wrong app. Use background steps, or run the batch with \"foreground\": true.",
            errorCode: "TARGET_NOT_FRONTMOST"
        )
    }

    /// The window a step must reach when the batch names one (`window`, which pins it): UseMac works in that
    /// window even when another window of the app is in front. Without a pin the target is whichever window
    /// of the app is in front, which can change during the batch (⌘N opens one), so no id is enforced.
    func pinnedWindowId(_ targetApp: AppDescriptor?) -> CGWindowID? {
        guard let pid = targetApp?.pid, pid > 0, WindowResolver.pinnedTitle(pid: pid) != nil else { return nil }
        return targetApp?.windowId.map { CGWindowID($0) }
    }

    /// Real mouse input lands in the window on top at the point. With the target app in front, that can still be
    /// another window: the user's own Chrome window over the one UseMac works in, or another app's window.
    /// Decides how a step that would post real input sends it. `backgroundAllowed`: the event has a background
    /// route without side effects (wheel and mouse-moved events, not clicks).
    func pointerRoute(_ targetApp: AppDescriptor?, at point: CGPoint?, backgroundAllowed: Bool) -> InputRouting.PointerRoute {
        guard let pid = targetApp?.pid, pid > 0 else { return .foreground }
        var documentIds: Set<CGWindowID>?
        return InputRouting.pointerRoute(
            point: point,
            targetPid: pid,
            targetWindowId: pinnedWindowId(targetApp),
            windows: InputRouting.pointerWindows(),
            isDocumentWindow: { id in
                if documentIds == nil { documentIds = InputRouting.documentWindowIds(pid: pid) }
                return documentIds?.contains(id) == true
            },
            backgroundAllowed: backgroundAllowed
        )
    }

    /// Refuses real mouse input (clicks) that would land in another window than the target.
    func pointerRefusal(_ targetApp: AppDescriptor?, at point: CGPoint?, input: String) -> StepOutcome? {
        switch pointerRoute(targetApp, at: point, backgroundAllowed: false) {
        case .foreground:
            return nil
        case .background(let covering), .refuse(let covering):
            return coveredWindowOutcome(targetApp: targetApp, covering: covering, input: input)
        }
    }

    func coveredWindowOutcome(targetApp: AppDescriptor?, covering: WindowResolver.WindowInfo?, input: String) -> StepOutcome {
        let app = targetApp?.name ?? "the target app"
        let place: String
        if let covering {
            place = covering.pid == targetApp?.pid
                ? "another \(app) window is on top of it there"
                : "a \(NSRunningApplication(processIdentifier: covering.pid)?.localizedName ?? "another app") window is on top of it there"
        } else {
            place = "it is not on screen there"
        }
        return StepOutcome(
            success: false,
            mechanism: "hid-guard",
            message: "The \(app) window UseMac works in would not get real \(input): \(place). Nothing was sent. Use a background step (setValue, axAction, scrollIntoView, or click an element with AXPress), or wait until that window is in front.",
            errorCode: "TARGET_NOT_FRONTMOST"
        )
    }

    /// Real keys go to the focused (key) window of the app in front. Refuses when that is not the window UseMac
    /// works in, e.g. a window it opened that sits behind the user's own window of the same app.
    func keyWindowGuard(_ targetApp: AppDescriptor?, input: String, pickerReceiver: AXUIElement? = nil) -> StepOutcome? {
        guard let pid = targetApp?.pid, pid > 0, let target = pinnedWindowId(targetApp) else { return nil }
        let keysReach = InputRouting.keysReachTarget(
            appIsFrontmost: WindowResolver.isFrontmost(pid: pid),
            targetWindowId: target,
            focusedWindowId: InputRouting.focusedWindowId(pid: pid)
        )
        if keysReach { return nil }
        // A picker opened by the pinned window can take keys in its own AX window.
        if let pickerReceiver,
           let focusedWindow = Self.axElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
           Self.isHosted(in: focusedWindow, element: pickerReceiver) {
            return nil
        }
        let app = targetApp?.name ?? "the target app"
        return StepOutcome(
            success: false,
            mechanism: "hid-guard",
            message: "The \(app) window UseMac works in is not \(app)'s focused window, so real \(input) would go to the window in front (probably the user's). Nothing was sent. Use setValue or axAction, which work without focus.",
            errorCode: "TARGET_NOT_FRONTMOST"
        )
    }
}
