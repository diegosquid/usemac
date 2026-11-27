import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import UseMacProtocol

extension ActionExecutor {
    // MARK: - Native file picker

    /// Picks a file in an open panel without Finder navigation or focus: type the file name in the panel's
    /// search field, select the result row with exactly that path and press the panel's Open button (AXOpen
    /// as a fallback). Falls back to ⌘⇧G only when the app is already in front. A file the search can never list
    /// (/tmp, $TMPDIR, hidden folders) goes straight to ⌘⇧G in front, and fails fast in the background.
    func performNativeUploadFile(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let normalized: [String]
        switch Self.validateAndNormalizeUploadFiles(step.files) {
        case .success(let paths):
            normalized = paths
        case .failure(let err):
            return StepOutcome(success: false, mechanism: "upload-guard", message: err.message, errorCode: "UPLOAD_BLOCKED")
        }
        guard let pid = targetApp?.pid, pid > 0 else {
            return StepOutcome(success: false, mechanism: "nsopenpanel", message: "uploadFile needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let previousFrontApp = frontApp?.processIdentifier == pid ? nil : frontApp

        // Open the picker first when a trigger (button or drop zone) was given.
        if resolved.element != nil || (step.x != nil && step.y != nil) {
            let trigger = performClick(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if !trigger.success {
                var failed = trigger
                failed.mechanism = "nsopenpanel-trigger"
                return failed
            }
        }

        var panel: OpenPanelParts?
        for _ in 0..<40 {
            panel = findOpenPanel(pid: pid)
            if panel != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let file = normalized[0]
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let extra = normalized.count > 1 ? " Only the first file was picked; open the picker again for the others." : ""

        guard let panel else {
            return StepOutcome(
                success: false,
                mechanism: "nsopenpanel",
                message: "No file picker opened in \(targetApp?.name ?? "the app"). Click the upload button first (pass its elementId/match on this step).",
                errorCode: "ELEMENT_NOT_FOUND"
            )
        }

        let appName = targetApp?.name ?? "the app"
        func selected(_ mechanism: String) async -> StepOutcome {
            let warning = await restoreFocusAfterBackgroundUploadIfNeeded(
                targetPid: pid, targetAppName: appName, previousApp: previousFrontApp
            )
            return StepOutcome(success: true, mechanism: mechanism, message: "Selected \(fileName).\(extra)", effect: .changed, warning: warning)
        }

        // 1. Walk the folders like a person would (sidebar → folders → file), selecting rows and pressing Open.
        //    Deterministic and independent of Spotlight.
        if await navigateAndPick(panel: panel, file: file, pid: pid) {
            return await selected("nsopenpanel-navigate")
        }

        // Spotlight never lists files in /tmp, $TMPDIR or hidden folders, and Go to Folder takes no keys in the
        // background (see OpenPanelReach). Say so now instead of searching; with the app in front, go to ⌘⇧G.
        let searchBlocker = OpenPanelReach.searchBlocker(for: file)
        if let searchBlocker, !WindowResolver.isFrontmost(pid: pid) {
            return StepOutcome(
                success: false,
                mechanism: "nsopenpanel-unreachable",
                message: OpenPanelReach.backgroundMessage(fileName: fileName, reason: searchBlocker, appName: targetApp?.name ?? "the app"),
                errorCode: "TARGET_NOT_FRONTMOST"
            )
        }

        // 2. Search by name (Spotlight) when the file's folders are not reachable from the sidebar.
        if searchBlocker == nil, let search = panel.searchField {
            // The picker search is Spotlight: index the file now so a file created seconds ago is found.
            await Self.indexForSpotlight(file)
            _ = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, fileName as CFTypeRef)
            _ = AXUIElementPerformAction(search, kAXConfirmAction as CFString)

            // Spotlight results keep streaming in for a while and the list is rebuilt as they do, which drops
            // a selection made too early. Re-find, re-select and confirm until it sticks (up to ~10 s).
            let targetPath = URL(fileURLWithPath: file).standardizedFileURL.path
            var ambiguous = false
            var sawRow = false
            var pressedOpen = false
            var lastCandidate: AXUIElement?
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if pressedOpen, findOpenPanel(pid: pid) == nil {
                    return await selected("nsopenpanel-search-select")
                }
                let rows = openableRows(in: panel.root, named: fileName)
                let exact = rows.filter { Self.rowURL($0)?.standardizedFileURL.path == targetPath }
                let candidate = exact.first ?? ((rows.count == 1 && Self.rowURL(rows[0]) == nil) ? rows[0] : nil)
                ambiguous = exact.isEmpty && rows.count > 1
                if let candidate, let rowElement = Self.enclosingRow(of: candidate) {
                    sawRow = true
                    if lastCandidate == nil {
                        // Asking the name field to open (even when it reports "unsupported") makes the panel
                        // adopt the row as its real selection, which enables Open; a bare AXSelected does not.
                        _ = AXUIElementPerformAction(candidate, "AXOpen" as CFString)
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if pressedOpen == false, findOpenPanel(pid: pid) == nil {
                            return await selected("nsopenpanel-search-axopen")
                        }
                    }
                    lastCandidate = candidate
                    if Self.axBool(rowElement, kAXSelectedAttribute) != true {
                        _ = AXUIElementSetAttributeValue(rowElement, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if let open = findOpenPanel(pid: pid)?.defaultButton ?? panel.defaultButton,
                       Self.axBool(rowElement, kAXSelectedAttribute) == true,
                       Self.axBool(open, kAXEnabledAttribute) != false {
                        if AXUIElementPerformAction(open, kAXPressAction as CFString) == .success {
                            pressedOpen = true
                            if await waitForPanelToClose(pid: pid) {
                                return await selected("nsopenpanel-search-select")
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            if sawRow {
                // Some panels open the item on AXOpen instead of Open.
                if let candidate = lastCandidate, Self.axActions(candidate).contains("AXOpen"),
                   AXUIElementPerformAction(candidate, "AXOpen" as CFString) == .success,
                   await waitForPanelToClose(pid: pid) {
                    return await selected("nsopenpanel-search-axopen")
                }
            }
            if !OpenPanelReach.shouldAttemptGoToFolderAfterSearchFailure(isFrontmost: WindowResolver.isFrontmost(pid: pid)) {
                if sawRow {
                    return StepOutcome(
                        success: false,
                        mechanism: "nsopenpanel-search",
                        message: "Found \(fileName) in the picker but could not confirm it in the background (Open stayed disabled). Rerun this step in a batch with \"foreground\": true.",
                        errorCode: "UPLOAD_FAILED"
                    )
                }
                return StepOutcome(
                    success: false,
                    mechanism: "nsopenpanel-search",
                    message: ambiguous
                        ? "Several files named \(fileName) showed up in the picker search. Give the file a unique name, or rerun this step in a batch with \"foreground\": true."
                        : "The picker could not be driven in the background: browsing its folders did not enable Open, and its search (Spotlight) did not list \(fileName) yet. Rerun this step in a batch with \"foreground\": true (UseMac types the path with ⌘⇧G and gives focus back), or retry once Spotlight has indexed the file.",
                    errorCode: "ELEMENT_NOT_FOUND"
                )
            }
        }

        // Last resort: ⌘⇧G with real keys, only when the app is in front.
        var outcome = await pickViaGoToFolder(panel: panel, file: file, fileName: fileName, extra: extra, pid: pid, targetApp: targetApp)
        if outcome.success {
            outcome.warning = await restoreFocusAfterBackgroundUploadIfNeeded(
                targetPid: pid, targetAppName: appName, previousApp: previousFrontApp
            )
        }
        return outcome
    }

    private func restoreFocusAfterBackgroundUploadIfNeeded(
        targetPid: Int32,
        targetAppName: String,
        previousApp: NSRunningApplication?
    ) async -> String? {
        guard let previousApp, !previousApp.isTerminated else { return nil }
        // Document apps can activate shortly after the open panel disappears.
        for attempt in 0..<3 {
            if WindowResolver.isFrontmost(pid: targetPid) {
                let idle = WindowResolver.secondsSinceUserInput()
                guard !previousApp.isTerminated, OpenPanelReach.shouldRestoreFocusAfterBackgroundUpload(
                    previousPid: previousApp.processIdentifier,
                    targetPid: targetPid,
                    targetBecameFrontmost: true,
                    secondsSinceUserInput: idle,
                    ownInputRecent: idleIsFromOwnInput(idle)
                ) else { return nil }
                _ = await waitForApplicationActivation(pid: previousApp.processIdentifier, timeoutMs: 400) {
                    if WindowResolver.isFrontmost(pid: targetPid) {
                        _ = previousApp.activate(options: [])
                    }
                }
                return WindowResolver.isFrontmost(pid: targetPid)
                    ? "Opening the document brought \(targetAppName) to the front and focus could not be returned automatically."
                    : nil
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        return nil
    }

    private func pickViaGoToFolder(
        panel: OpenPanelParts,
        file: String,
        fileName: String,
        extra: String,
        pid: Int32,
        targetApp: AppDescriptor?
    ) async -> StepOutcome {
        if let refused = frontmostGuard(targetApp, input: "keys to the file picker") {
            return refused
        }
        let panelRoot = findOpenPanel(pid: pid)?.root ?? panel.root
        let frontmost = ResolvedElement(pid: pid)

        func press(_ key: String, modifiers: [String] = [], in receiver: AXUIElement) -> StepOutcome {
            performPressKey(
                step: ActionStep(action: .pressKey, key: key, modifiers: modifiers, preferBackground: false),
                resolved: frontmost, targetApp: targetApp, pickerReceiver: receiver
            )
        }
        func result(closed: Bool, detectedField: Bool, failure: StepOutcome? = nil) -> StepOutcome {
            StepOutcome(
                success: closed,
                mechanism: "nsopenpanel-goto",
                message: closed ? "Selected \(fileName) via ⌘⇧G.\(extra)"
                    : failure?.message ?? OpenPanelReach.goToFolderFailureMessage(fileName: fileName, detectedField: detectedField),
                errorCode: closed ? nil : failure?.errorCode ?? "UPLOAD_FAILED",
                effect: closed ? .changed : ActionEffect.none
            )
        }
        Self.raiseAXWindow(panelRoot)
        try? await Task.sleep(for: .milliseconds(80))
        var field = findGoToFolderField(in: panelRoot, pid: pid)
        if field == nil {
            let shortcut = press("g", modifiers: ["cmd", "shift"], in: panelRoot)
            guard shortcut.success else { return result(closed: false, detectedField: false, failure: shortcut) }
            let started = ContinuousClock.now
            let retryAt = started + .milliseconds(600)
            let deadline = started + .milliseconds(1200)
            var retried = false
            while ContinuousClock.now < deadline, field == nil {
                field = findGoToFolderField(in: panelRoot, pid: pid)
                if field == nil, !retried, ContinuousClock.now >= retryAt {
                    retried = true
                    Self.raiseAXWindow(panelRoot)
                    try? await Task.sleep(for: .milliseconds(80))
                    field = findGoToFolderField(in: panelRoot, pid: pid)
                    if field != nil { break }
                    let retry = press("g", modifiers: ["cmd", "shift"], in: panelRoot)
                    guard retry.success else { return result(closed: false, detectedField: false, failure: retry) }
                }
                if field == nil { try? await Task.sleep(for: .milliseconds(80)) }
            }
        }

        guard let field else { return result(closed: false, detectedField: false) }
        if let refused = frontmostGuard(targetApp, input: "the Go to Folder path") {
            return refused
        }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, file as CFTypeRef)
        if Self.axString(field, kAXValueAttribute) != file {
            let selectAll = press("a", modifiers: ["cmd"], in: field)
            guard selectAll.success else { return result(closed: false, detectedField: true, failure: selectAll) }
            let typed = performType(
                step: ActionStep(action: .type, text: file, preferBackground: false),
                resolved: frontmost, targetApp: targetApp, onOverlayEvent: nil, pickerReceiver: field
            )
            guard typed.success else { return result(closed: false, detectedField: true, failure: typed) }
        }

        try? await Task.sleep(for: .milliseconds(150))
        let navigate = press("return", in: field)
        guard navigate.success else { return result(closed: false, detectedField: true, failure: navigate) }

        let navigationStarted = ContinuousClock.now
        let retryAt = navigationStarted + .milliseconds(800)
        let navigationDeadline = navigationStarted + .seconds(2)
        var retried = false
        while let openField = findGoToFolderField(in: panelRoot, pid: pid) {
            guard ContinuousClock.now < navigationDeadline else { return result(closed: false, detectedField: true) }
            if !retried, ContinuousClock.now >= retryAt {
                retried = true
                let retry = press("return", in: openField)
                guard retry.success else { return result(closed: false, detectedField: true, failure: retry) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            guard let currentPanel = findOpenPanel(pid: pid) else { return result(closed: true, detectedField: true) }
            if let open = currentPanel.defaultButton, Self.axBool(open, kAXEnabledAttribute) != false {
                if AXUIElementPerformAction(open, kAXPressAction as CFString) != .success {
                    let confirm = press("return", in: currentPanel.root)
                    guard confirm.success else { return result(closed: false, detectedField: true, failure: confirm) }
                }
                let closed = await waitForPanelToClose(pid: pid)
                return result(closed: closed, detectedField: true)
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return result(closed: false, detectedField: true)
    }

    private func findGoToFolderField(in panelRoot: AXUIElement, pid: Int32, savePanel: Bool = false) -> AXUIElement? {
        func field(in root: AXUIElement, isGoToFolderWindow: Bool = false) -> AXUIElement? {
            var queue = [(element: root, depth: 0, inGoToFolderContainer: isGoToFolderWindow)]
            var index = 0
            while index < queue.count {
                let (element, depth, inContainer) = queue[index]
                index += 1
                let role = Self.axString(element, kAXRoleAttribute)
                // Neither list rows nor the browser's web content can contain the path field.
                switch role {
                case "AXRow", "AXOutline", "AXTable", "AXBrowser", "AXWebArea":
                    continue
                default:
                    break
                }
                let inGoToFolderContainer = inContainer
                    || ((role == "AXSheet" || role == "AXPopover") && !CFEqual(element, panelRoot))
                if inGoToFolderContainer, role == "AXComboBox" || role == "AXTextField",
                   OpenPanelReach.isGoToFolderFieldCandidate(
                       role: role,
                       subrole: Self.axString(element, kAXSubroleAttribute),
                       inFileRow: false,
                       isSearchField: false
                   ) {
                    return element
                }
                if depth < 6 {
                    queue.append(contentsOf: Self.axChildren(element).map { ($0, depth + 1, inGoToFolderContainer) })
                }
            }
            return nil
        }

        if let pathField = field(in: panelRoot) { return pathField }

        // Some panels expose Go to Folder under the app's focused or auxiliary window instead.
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        let focused = Self.axElement(axApp, kAXFocusedWindowAttribute)
        if savePanel {
            // Do not grab editable fields in another sheet of the same app. An auxiliary
            // Go to Folder window must be the focused window and identify itself as such.
            guard let focused, !CFEqual(focused, panelRoot) else { return nil }
            let title = Self.axString(focused, kAXTitleAttribute)?.lowercased()
            let isGoToFolderWindow = title == "go to folder" || title == "ir para a pasta"
            return isGoToFolderWindow ? field(in: focused, isGoToFolderWindow: true) : nil
        }
        if let focused, !CFEqual(focused, panelRoot), let pathField = field(in: focused) {
            return pathField
        }
        for window in Self.axChildren(axApp, attribute: kAXWindowsAttribute)
            where !CFEqual(window, panelRoot) && focused.map({ !CFEqual(window, $0) }) != false {
            let role = Self.axString(window, kAXRoleAttribute)
            let subrole = Self.axString(window, kAXSubroleAttribute)
            if role == "AXSheet" || role == "AXPopover" || subrole == "AXDialog",
               let pathField = field(in: window) {
                return pathField
            }
        }
        return nil
    }

    private struct OpenPanelParts {
        let root: AXUIElement
        let searchField: AXUIElement?
        let defaultButton: AXUIElement?
    }

    /// Button titles that confirm an open panel, in the languages macOS ships most often.
    private static let openButtonTitles: Set<String> = [
        "open", "abrir", "choose", "escolher", "select", "selecionar", "upload", "carregar", "enviar",
        "insert", "inserir", "ouvrir", "öffnen", "abrir archivo", "aprire", "apri"
    ]

    /// The open panel of `pid`: a sheet on its window, a dialog, or (TextEdit, sandboxed apps) a standard
    /// window. Recognized by its own controls near the top of the tree (search field, file list, Open button),
    /// never by deep web content, so a browser window with a search box and a table does not qualify.
    private func findOpenPanel(pid: Int32) -> OpenPanelParts? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        var candidates: [AXUIElement] = []
        if let pinned = WindowResolver.pinnedTitle(pid: pid),
           let window = WindowResolver.window(pid: pid, titleContains: pinned) {
            candidates.append(window)
            candidates.append(contentsOf: Self.axChildren(window).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" })
        }
        if let focused = Self.axElement(axApp, kAXFocusedWindowAttribute) {
            candidates.append(focused)
            candidates.append(contentsOf: Self.axChildren(focused).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" })
        }
        for window in Self.axChildren(axApp, attribute: kAXWindowsAttribute) {
            candidates.append(window)
            candidates.append(contentsOf: Self.axChildren(window).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" })
        }
        for candidate in candidates {
            let role = Self.axString(candidate, kAXRoleAttribute)
            let subrole = Self.axString(candidate, kAXSubroleAttribute)
            guard role == "AXSheet" || subrole == "AXDialog" || subrole == "AXStandardWindow" else { continue }
            guard let search = Self.firstDescendant(of: candidate, maxDepth: 3, where: { element in
                Self.axString(element, kAXSubroleAttribute) == "AXSearchField"
            }) else { continue }
            let hasFileList = Self.firstDescendant(of: candidate, maxDepth: 7, where: { element in
                let r = Self.axString(element, kAXRoleAttribute)
                return r == "AXOutline" || r == "AXBrowser" || r == "AXTable"
            }) != nil
            guard hasFileList else { continue }
            let declaredDefault = Self.axElement(candidate, kAXDefaultButtonAttribute)
            let openButton = declaredDefault ?? Self.firstDescendant(of: candidate, maxDepth: 3, where: { element in
                guard Self.axString(element, kAXRoleAttribute) == "AXButton",
                      let title = Self.axString(element, kAXTitleAttribute) else { return false }
                return Self.openButtonTitles.contains(title.trimmingCharacters(in: .whitespaces).lowercased())
            })
            guard role == "AXSheet" || openButton != nil else { continue }
            return OpenPanelParts(root: candidate, searchField: search, defaultButton: openButton)
        }
        return nil
    }

    /// Result rows whose name cell shows exactly `fileName` (the text element, which carries AXURL).
    private func openableRows(in root: AXUIElement, named fileName: String) -> [AXUIElement] {
        let wanted = fileName.lowercased()
        var rows: [AXUIElement] = []
        Self.collectDescendants(of: root, maxDepth: 18, into: &rows) { element in
            let role = Self.axString(element, kAXRoleAttribute)
            guard role == "AXTextField" || role == "AXStaticText" else { return false }
            guard (Self.axString(element, kAXValueAttribute) ?? "").lowercased() == wanted else { return false }
            // Skip the path bar at the bottom of the panel: only items inside a list row count.
            return Self.enclosingRow(of: element) != nil
        }
        return rows
    }

    /// Selects the deepest sidebar location that contains `file`, then opens each folder below it and finally
    /// the file, by selecting list rows and pressing the panel's Open button. Returns true when the panel closed.
    private func navigateAndPick(
        panel: OpenPanelParts,
        file: String,
        pid: Int32
    ) async -> Bool {
        guard panel.defaultButton != nil else { return false }
        // The panel rebuilds its controls while it loads, so look the Open button up fresh each time.
        func openButton() -> AXUIElement? {
            findOpenPanel(pid: pid)?.defaultButton
        }
        let fm = FileManager.default
        let sidebar = Self.firstDescendant(of: panel.root, maxDepth: 6) { element in
            Self.axString(element, kAXRoleAttribute) == "AXOutline"
                && (Self.axString(element, kAXDescriptionAttribute) ?? "").lowercased().contains("sidebar")
        } ?? Self.firstDescendant(of: panel.root, maxDepth: 6) { Self.axString($0, kAXRoleAttribute) == "AXOutline" }
        guard let sidebar else { return false }

        // Sidebar entries by display name.
        var sidebarRows: [String: AXUIElement] = [:]
        for row in Self.axChildren(sidebar, attribute: kAXRowsAttribute) {
            var texts: [AXUIElement] = []
            Self.collectDescendants(of: row, maxDepth: 3, into: &texts) { Self.axString($0, kAXRoleAttribute) == "AXStaticText" }
            for text in texts {
                if let name = Self.axString(text, kAXValueAttribute), !name.isEmpty, sidebarRows[name] == nil {
                    sidebarRows[name] = row
                }
            }
        }

        // Deepest ancestor folder that the sidebar offers.
        var components = (file as NSString).pathComponents
        let fileComponent = components.removeLast()
        var anchorIndex: Int?
        var anchorRow: AXUIElement?
        for index in stride(from: components.count, through: 2, by: -1) {
            let folder = NSString.path(withComponents: Array(components[0..<index]))
            let display = fm.displayName(atPath: folder)
            if let row = sidebarRows[display] ?? sidebarRows[(folder as NSString).lastPathComponent] {
                anchorIndex = index
                anchorRow = row
                break
            }
        }
        guard let anchorIndex, let anchorRow else { return false }

        // The "Where" popup shows the folder on display; use it to confirm each navigation step.
        func whereValue() -> String? {
            Self.firstDescendant(of: panel.root, maxDepth: 4) { Self.axString($0, kAXIdentifierAttribute) == "where popup" }
                .flatMap { Self.axString($0, kAXValueAttribute) }
        }
        func waitForFolder(_ names: Set<String>) async -> Bool {
            for _ in 0..<20 {
                if let shown = whereValue() {
                    if names.contains(shown.lowercased()) { return true }
                } else {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    return true
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return false
        }

        let anchorPath = NSString.path(withComponents: Array(components[0..<anchorIndex]))
        guard AXUIElementSetAttributeValue(anchorRow, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success,
              await waitForFolder([fm.displayName(atPath: anchorPath).lowercased(), (anchorPath as NSString).lastPathComponent.lowercased()]) else {
            return false
        }

        var steps = Array(components[anchorIndex...])
        steps.append(fileComponent)
        var currentPath = anchorPath
        for (offset, name) in steps.enumerated() {
            currentPath = (currentPath as NSString).appendingPathComponent(name)
            let display = fm.displayName(atPath: currentPath)
            let isLast = offset == steps.count - 1

            var confirmed = false
            for _ in 0..<3 where !confirmed {
                var row: AXUIElement?
                for _ in 0..<10 {
                    row = folderListRow(in: panel.root, named: [name, display])
                    if row != nil { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                Self.panelDebug("step \(name) row=\(row != nil)")
                guard let row else { return false }
                _ = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                var open = openButton()
                for _ in 0..<15 where Self.axBool(row, kAXSelectedAttribute) != true || open.map({ Self.axBool($0, kAXEnabledAttribute) == false }) != false {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    open = openButton()
                }
                Self.panelDebug("  selected=\(String(describing: Self.axBool(row, kAXSelectedAttribute))) openEnabled=\(String(describing: open.flatMap { Self.axBool($0, kAXEnabledAttribute) })) where=\(whereValue() ?? "nil")")
                // Some panels (sandboxed apps host theirs out of process) do not enable Open for a selection
                // made through AX while browsing folders. Give up fast and let the search path try.
                guard Self.axBool(row, kAXSelectedAttribute) == true, let open, Self.axBool(open, kAXEnabledAttribute) != false else { return false }
                let pressed = AXUIElementPerformAction(open, kAXPressAction as CFString)
                Self.panelDebug("  press=\(pressed.rawValue)")
                guard pressed == .success else { continue }
                if isLast {
                    return await waitForPanelToClose(pid: pid)
                }
                confirmed = await waitForFolder([name.lowercased(), display.lowercased()])
                Self.panelDebug("  confirmed=\(confirmed) where=\(whereValue() ?? "nil")")
            }
            if !confirmed { return false }
        }
        return false
    }

    static func panelDebug(_ message: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["USEMAC_DEBUG_PANEL"] == "1" {
            FileHandle.standardError.write(Data("[panel] \(message())\n".utf8))
        }
    }

    /// A row of the panel's file list whose name is one of `names`, in the folder being shown (rows inside
    /// an expanded subfolder are skipped; rows under a date-group header count). The list is looked up again
    /// every time because the panel replaces it after each navigation.
    private func folderListRow(in root: AXUIElement, named names: [String]) -> AXUIElement? {
        let wanted = Set(names.map { $0.lowercased() })
        guard let list = Self.firstDescendant(of: root, maxDepth: 8, where: { element in
            let role = Self.axString(element, kAXRoleAttribute)
            guard role == "AXOutline" || role == "AXTable" else { return false }
            if Self.axString(element, kAXIdentifierAttribute) == "ListView" { return true }
            return !(Self.axString(element, kAXDescriptionAttribute) ?? "").lowercased().contains("sidebar")
        }) else { return nil }
        for row in Self.axChildren(list, attribute: kAXRowsAttribute) {
            guard let nameField = Self.rowNameField(row),
                  wanted.contains((Self.axString(nameField, kAXValueAttribute) ?? "").lowercased()) else { continue }
            if let owner = Self.axElement(row, "AXDisclosedByRow"), Self.rowNameField(owner) != nil {
                continue
            }
            return row
        }
        return nil
    }

    /// The editable name field of a file-list row (group headers have none).
    private static func rowNameField(_ row: AXUIElement) -> AXUIElement? {
        for cell in axChildren(row).prefix(2) {
            for child in axChildren(cell) where axString(child, kAXRoleAttribute) == "AXTextField" {
                return child
            }
        }
        return nil
    }

    /// Runs `mdimport` on a user file so Spotlight (and the open panel search) knows it right away.
    private static func indexForSpotlight(_ path: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        for _ in 0..<30 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
        }
        // Give the index a moment to answer queries.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func enclosingRow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current else { return nil }
            if axString(node, kAXRoleAttribute) == "AXRow" { return node }
            current = axElement(node, kAXParentAttribute)
        }
        return nil
    }

    private func waitForPanelToClose(pid: Int32) async -> Bool {
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if findOpenPanel(pid: pid) == nil { return true }
        }
        return false
    }

    private static func rowURL(_ element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<3 {
            guard let node = current else { return nil }
            if let url = panelItemURL(node) { return url }
            current = axElement(node, kAXParentAttribute)
        }
        return nil
    }

    private static func panelItemURL(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        return (value as? String).flatMap { URL(string: $0) }
    }

    // MARK: - Native save panel

    public static func validateAndNormalizeSaveDestination(
        _ rawFiles: [String]?, overwrite: Bool
    ) -> Result<String, UploadValidationError> {
        guard let rawFiles, rawFiles.count == 1 else {
            return .failure(UploadValidationError("saveFile requires exactly one destination path in 'files'."))
        }
        let rawPath = rawFiles[0].trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let expanded = rawPath.expandingTildeInPath
        let name = (expanded as NSString).lastPathComponent
        guard expanded.hasPrefix("/"), !expanded.hasSuffix("/"), !expanded.utf8.contains(0),
              !name.isEmpty, name != ".", name != ".." else {
            return .failure(UploadValidationError("saveFile requires an absolute destination file path."))
        }
        let systemDirectories = ["/system", "/etc", "/private/etc", "/usr", "/bin", "/sbin", "/library"]
        func isBlocked(_ url: URL) -> Bool {
            let path = url.path.lowercased()
            return isSensitiveFilePath(url) || systemDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let blocked = UploadValidationError("Blocked sensitive destination for saveFile: \(name)")
        guard !isBlocked(URL(fileURLWithPath: expanded).standardizedFileURL) else { return .failure(blocked) }

        // Resolve only the parent: a destination that is itself a symlink must not be followed.
        let parent = (expanded as NSString).deletingLastPathComponent
        guard let resolvedParent = realpath(parent, nil) else {
            return .failure(UploadValidationError("Destination parent directory does not exist or cannot be reached: \(parent)"))
        }
        defer { free(resolvedParent) }
        let directory = URL(fileURLWithPath: String(cString: resolvedParent), isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(UploadValidationError("Destination parent is not a directory: \(parent)"))
        }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        guard !isBlocked(destination) else { return .failure(blocked) }

        let path = destination.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else {
                return .failure(UploadValidationError("Could not check destination file: \(path)"))
            }
            return .success(path)
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return .failure(UploadValidationError("Destination path is an existing directory: \(path)"))
        case S_IFLNK:
            return .failure(UploadValidationError("Refusing to overwrite a symbolic link: \(path)"))
        case S_IFREG:
            guard overwrite else {
                return .failure(UploadValidationError("Destination file already exists at \(path). Pass overwrite: true to replace it."))
            }
            return .success(path)
        default:
            return .failure(UploadValidationError("Destination is not a regular file: \(path)"))
        }
    }

    private struct SavePanelParts {
        let root: AXUIElement
        let nameField: AXUIElement
        let saveButton: AXUIElement
    }

    private func findSavePanel(pid: Int32) -> SavePanelParts? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let focused = Self.axElement(app, kAXFocusedWindowAttribute)
        let pinnedTitle = WindowResolver.pinnedTitle(pid: pid)
        let windows: [AXUIElement]
        if let title = pinnedTitle {
            guard let window = WindowResolver.window(pid: pid, titleContains: title) else { return nil }
            windows = [window] + (focused.map { [$0] } ?? [])
        } else {
            windows = (focused.map { [$0] } ?? []) + Self.axChildren(app, attribute: kAXWindowsAttribute)
        }
        for window in windows {
            let sheets = Self.axChildren(window).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" }
            // Only the pinned document's sheets are eligible when another document is focused.
            let pinnedElsewhere = pinnedTitle != nil && !CFEqual(window, windows[0])
            for root in (pinnedElsewhere ? [] : sheets) + [window] {
                let role = Self.axString(root, kAXRoleAttribute)
                let subrole = Self.axString(root, kAXSubroleAttribute)
                guard role == "AXSheet" || role == "AXDialog" || subrole == "AXDialog"
                    || (role == "AXWindow" && Self.axBool(root, kAXModalAttribute) == true) else { continue }
                let controls = Self.savePanelControls(in: root)
                let namedButton = Self.savePanelButton(in: controls, titled: ["save", "export", "salvar", "exportar"])
                guard let button = namedButton ?? Self.axElement(root, kAXDefaultButtonAttribute) else { continue }
                let fields = controls.filter { element in
                    let role = Self.axString(element, kAXRoleAttribute)
                    guard role == "AXTextField" else { return false }
                    var writable = DarwinBoolean(false)
                    return OpenPanelReach.isSavePanelNameField(
                        role: role,
                        subrole: Self.axString(element, kAXSubroleAttribute),
                        editable: AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable) == .success
                            && writable.boolValue
                    )
                }
                let labeled = fields.first { field in
                    let label = Self.axElement(field, kAXTitleUIElementAttribute)
                    let captions = [Self.axString(field, kAXIdentifierAttribute), Self.axString(field, kAXTitleAttribute),
                                    Self.axString(field, kAXDescriptionAttribute), label.flatMap { Self.axString($0, kAXValueAttribute) }]
                    return captions.compactMap { $0?.lowercased() }.contains {
                        $0.contains("save as") || $0.contains("salvar como") || $0.contains("filename")
                    }
                }
                let looksLikePicker = namedButton != nil || Self.saveLocationControl(in: controls) != nil
                if let field = labeled ?? (looksLikePicker && fields.count == 1 ? fields.first : nil) {
                    return SavePanelParts(root: root, nameField: field, saveButton: button)
                }
            }
        }
        return nil
    }

    /// Controls owned by this dialog, excluding file-list cells, search fields, web content and nested sheets.
    private static func savePanelControls(in root: AXUIElement) -> [AXUIElement] {
        var controls: [AXUIElement] = []
        var queue = Self.axChildren(root).map { (element: $0, depth: 1) }
        var index = 0
        while index < queue.count, index < 200 {
            let (element, depth) = queue[index]
            index += 1
            switch Self.axString(element, kAXRoleAttribute) {
            case "AXSheet", "AXWindow", "AXDialog", "AXWebArea", "AXRow", "AXSearchField":
                continue
            case "AXOutline", "AXBrowser", "AXTable":
                controls.append(element)
                continue
            default:
                controls.append(element)
                if depth < 6 { queue.append(contentsOf: Self.axChildren(element).map { ($0, depth + 1) }) }
            }
        }
        return controls
    }

    private static func savePanelButton(in controls: [AXUIElement], titled titles: Set<String>) -> AXUIElement? {
        controls.first { element in
            guard Self.axString(element, kAXRoleAttribute) == "AXButton",
                  let title = Self.axString(element, kAXTitleAttribute) else { return false }
            return titles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    private static func saveLocationControl(in controls: [AXUIElement]) -> AXUIElement? {
        controls.first { Self.axString($0, kAXIdentifierAttribute)?.lowercased() == "where popup" }
    }

    /// Use an explicit folder URL or file-list row URLs, never a folder display name on its own.
    private static func savePanelDirectory(_ panel: SavePanelParts) -> String? {
        let controls = savePanelControls(in: panel.root)
        let location = saveLocationControl(in: controls)
        if let url = location.flatMap(panelItemURL), url.isFileURL {
            return url.resolvingSymlinksInPath().path
        }
        var parents: Set<String> = []
        for list in controls where ["AXOutline", "AXBrowser", "AXTable"].contains(Self.axString(list, kAXRoleAttribute) ?? "") {
            guard Self.axString(list, kAXIdentifierAttribute)?.lowercased().contains("sidebar") != true else { continue }
            let rows = axChildren(list, attribute: kAXRowsAttribute)
            for row in rows.prefix(20) {
                let url = panelItemURL(row) ?? axChildren(row).compactMap(panelItemURL).first
                if let url, url.isFileURL {
                    parents.insert(url.deletingLastPathComponent().resolvingSymlinksInPath().path)
                }
            }
        }
        return parents.count == 1 ? parents.first : nil
    }

    func performNativeSaveFile(
        step: ActionStep,
        resolved: ResolvedElement,
        targetApp: AppDescriptor?,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let destination: String
        switch Self.validateAndNormalizeSaveDestination(step.files, overwrite: step.overwrite == true) {
        case .success(let path):
            destination = path
        case .failure(let error):
            return StepOutcome(success: false, mechanism: "save-guard", message: error.message, errorCode: "UPLOAD_BLOCKED")
        }
        guard let targetApp, targetApp.pid > 0 else {
            return StepOutcome(success: false, mechanism: "nssavepanel", message: "saveFile needs a target app.", errorCode: "APP_NOT_FOUND")
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousFrontApp = previousApp?.processIdentifier == targetApp.pid ? nil : previousApp
        var outcome = await driveSavePanel(
            step: step, resolved: resolved, destination: destination, targetApp: targetApp, onOverlayEvent: onOverlayEvent
        )
        if outcome.success || WindowResolver.isFrontmost(pid: targetApp.pid) {
            outcome.warning = await restoreFocusAfterBackgroundUploadIfNeeded(
                targetPid: targetApp.pid, targetAppName: targetApp.name, previousApp: previousFrontApp
            )
        }
        return outcome
    }

    private func driveSavePanel(
        step: ActionStep,
        resolved: ResolvedElement,
        destination: String,
        targetApp: AppDescriptor,
        onOverlayEvent: (@Sendable (OverlayVisualEvent) -> Void)?
    ) async -> StepOutcome {
        let pid = targetApp.pid
        let url = URL(fileURLWithPath: destination)
        let folder = url.deletingLastPathComponent().path
        let filename = url.lastPathComponent
        let overwrite = step.overwrite == true
        let receiver = ResolvedElement(pid: pid)

        func failed(_ message: String, code: String = "UPLOAD_FAILED") -> StepOutcome {
            StepOutcome(success: false, mechanism: "nssavepanel", message: message, errorCode: code)
        }

        func safetyRefusal() -> StepOutcome? {
            killSwitch.isBlocked(forSensitiveAction: true).map { failed($0, code: "POLICY_BLOCKED") }
        }

        func press(_ key: String, modifiers: [ModifierAliases.Modifier] = [], in element: AXUIElement) -> StepOutcome {
            if let refusal = safetyRefusal() { return refusal }
            let app = AXUIElementCreateApplication(pid)
            guard let focused = Self.axElement(app, kAXFocusedWindowAttribute),
                  Self.isHosted(in: focused, element: element) else {
                return failed("The save panel is no longer the focused window.")
            }
            let aliases = modifiers.compactMap { ModifierAliases.names[$0]?.min() }
            var outcome = performPressKey(
                step: ActionStep(action: .pressKey, key: key, modifiers: aliases, preferBackground: false),
                resolved: receiver, targetApp: targetApp, pickerReceiver: element
            )
            // Foreground fallback must not replay a trigger after navigation may already have started.
            if outcome.errorCode == "TARGET_NOT_FRONTMOST" { outcome.errorCode = "UPLOAD_FAILED" }
            return outcome
        }

        func setField(_ field: AXUIElement, to value: String) async -> StepOutcome? {
            if let refusal = safetyRefusal() { return refusal }
            _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFTypeRef)
            if Self.axString(field, kAXValueAttribute) == value { return nil }
            guard WindowResolver.isFrontmost(pid: pid),
                  AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                return failed("Could not fill in the save panel's text field.")
            }
            let selected = press("a", modifiers: [.command], in: field)
            guard selected.success else { return selected }
            if let refusal = safetyRefusal() { return refusal }
            let typed = performType(step: ActionStep(action: .type, text: value, preferBackground: false),
                                    resolved: receiver, targetApp: targetApp, onOverlayEvent: nil, pickerReceiver: field)
            guard typed.success else { return failed(typed.message ?? "Could not type into the save panel.", code: "UPLOAD_FAILED") }
            try? await Task.sleep(for: .milliseconds(100))
            return Self.axString(field, kAXValueAttribute) == value ? nil : failed("The save panel did not accept the requested text.")
        }

        func validateBeforeConfirming() -> StepOutcome? {
            switch Self.validateAndNormalizeSaveDestination(step.files, overwrite: overwrite) {
            case .success(let current):
                return current == destination ? nil : failed("The destination directory changed while the save panel was open.", code: "UPLOAD_BLOCKED")
            case .failure(let error):
                return failed(error.message, code: "UPLOAD_BLOCKED")
            }
        }

        func showsDestination(_ current: SavePanelParts, afterGoToFolder: Bool) -> Bool {
            if let directory = Self.savePanelDirectory(current) { return directory == folder }
            // An empty folder has no row URLs. Only use the Where label after entering
            // and confirming the entire absolute path in the Go to Folder sheet.
            guard afterGoToFolder else { return false }
            let control = Self.saveLocationControl(in: Self.savePanelControls(in: current.root))
            let shown = control.flatMap { Self.axString($0, kAXValueAttribute) }
            return shown == url.deletingLastPathComponent().lastPathComponent
                || shown == FileManager.default.displayName(atPath: folder)
        }

        if let refusal = safetyRefusal() { return refusal }
        if resolved.element != nil || (step.x != nil && step.y != nil) {
            let trigger = performClick(step: step, resolved: resolved, targetApp: targetApp, onOverlayEvent: onOverlayEvent)
            if !trigger.success {
                var result = trigger
                result.mechanism = "nssavepanel-trigger"
                return result
            }
        }

        let openDeadline = ContinuousClock.now + .seconds(4)
        var found: SavePanelParts?
        repeat {
            if let refusal = safetyRefusal() { return refusal }
            found = findSavePanel(pid: pid)
            if found != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while !Task.isCancelled && ContinuousClock.now < openDeadline
        guard var panel = found else {
            return failed("No save panel opened in \(targetApp.name). Use File > Save… with menuAction, or pass the element or coordinates of the save/export button.", code: "ELEMENT_NOT_FOUND")
        }

        let usesGoToFolder = WindowResolver.isFrontmost(pid: pid)
        if usesGoToFolder {
            if let refusal = safetyRefusal() { return refusal }
            Self.raiseAXWindow(panel.root)
            try? await Task.sleep(for: .milliseconds(80))
            let opening = press("g", modifiers: [.command, .shift], in: panel.root)
            guard opening.success else { return opening }
            let fieldDeadline = ContinuousClock.now + .milliseconds(1_500)
            var pathField: AXUIElement?
            repeat {
                if let refusal = safetyRefusal() { return refusal }
                pathField = findGoToFolderField(in: panel.root, pid: pid, savePanel: true)
                if pathField != nil { break }
                try? await Task.sleep(for: .milliseconds(80))
            } while !Task.isCancelled && ContinuousClock.now < fieldDeadline
            guard let pathField else { return failed("Go to Folder did not open in the save panel.") }
            if let refusal = safetyRefusal() { return refusal }
            guard WindowResolver.isFrontmost(pid: pid) else { return failed("Go to Folder lost focus.") }
            _ = AXUIElementSetAttributeValue(pathField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if let refusal = await setField(pathField, to: folder) { return refusal }
            // Give the folder completion time to resolve before sending Return.
            try? await Task.sleep(for: .milliseconds(150))
            let navigate = press("return", in: pathField)
            guard navigate.success else { return navigate }
            let navigationDeadline = ContinuousClock.now + .seconds(2)
            var located = false
            repeat {
                if let refusal = safetyRefusal() { return refusal }
                if findGoToFolderField(in: panel.root, pid: pid, savePanel: true) == nil,
                   let updated = findSavePanel(pid: pid), CFEqual(updated.root, panel.root) {
                    panel = updated
                    located = showsDestination(updated, afterGoToFolder: true)
                    if located { break }
                }
                try? await Task.sleep(for: .milliseconds(100))
            } while !Task.isCancelled && ContinuousClock.now < navigationDeadline
            guard located else { return failed("Could not confirm that Go to Folder selected the requested directory.") }
        } else if OpenPanelReach.searchBlocker(for: destination) != nil || !showsDestination(panel, afterGoToFolder: false) {
            return StepOutcome(
                success: false, mechanism: "nssavepanel-background",
                message: OpenPanelReach.saveBackgroundMessage(appName: targetApp.name), errorCode: "TARGET_NOT_FRONTMOST"
            )
        }

        if let refusal = await setField(panel.nameField, to: filename) { return refusal }
        guard let ready = findSavePanel(pid: pid), CFEqual(ready.root, panel.root),
              Self.axString(ready.nameField, kAXValueAttribute) == filename,
              showsDestination(ready, afterGoToFolder: usesGoToFolder),
              Self.axBool(ready.saveButton, kAXEnabledAttribute) != false else {
            return failed("The save panel no longer shows the requested destination.")
        }
        if let refusal = validateBeforeConfirming() ?? safetyRefusal() { return refusal }
        guard AXUIElementPerformAction(ready.saveButton, kAXPressAction as CFString) == .success else {
            return failed("Could not press Save in the save panel.")
        }

        let confirmationDeadline = ContinuousClock.now + .seconds(3)
        var pressedReplace = false
        var panelWasClosed = false
        repeat {
            if let prompt = replacementPrompt(in: panel.root, pid: pid, filename: filename) {
                if !overwrite || (!pressedReplace && validateBeforeConfirming() != nil) {
                    let cancelled = prompt.cancel.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
                    return failed(cancelled
                        ? "The destination changed while saving; cancelled the replacement."
                        : "The destination changed while saving; UseMac did not confirm the replacement.",
                        code: "UPLOAD_BLOCKED")
                }
                if let refusal = safetyRefusal() { return refusal }
                if !pressedReplace {
                    guard AXUIElementPerformAction(prompt.replace, kAXPressAction as CFString) == .success else {
                        return failed("Could not confirm the requested replacement.")
                    }
                    pressedReplace = true
                }
                panelWasClosed = false
            } else if findSavePanel(pid: pid) == nil {
                if panelWasClosed {
                    return StepOutcome(success: true, mechanism: "nssavepanel", message: "Confirmed save for \(filename).", effect: .changed)
                }
                // A standalone replacement dialog may arrive just after the save panel disappears.
                panelWasClosed = true
            } else {
                panelWasClosed = false
            }
            if let refusal = safetyRefusal() { return refusal }
            try? await Task.sleep(for: .milliseconds(100))
        } while !Task.isCancelled && ContinuousClock.now < confirmationDeadline
        return failed("The save panel did not close after confirmation.")
    }

    private func replacementPrompt(
        in panel: AXUIElement, pid: Int32, filename: String
    ) -> (replace: AXUIElement, cancel: AXUIElement?)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let focused = Self.axElement(app, kAXFocusedWindowAttribute)
        func sheets(in root: AXUIElement) -> [AXUIElement] {
            Self.axChildren(root).filter { Self.axString($0, kAXRoleAttribute) == "AXSheet" }
        }
        let auxiliary = focused.map { sheets(in: $0) + [$0] } ?? []
        for root in sheets(in: panel) + auxiliary {
            let role = Self.axString(root, kAXRoleAttribute)
            guard role == "AXSheet" || role == "AXDialog" || Self.axString(root, kAXSubroleAttribute) == "AXDialog"
                || Self.axBool(root, kAXModalAttribute) == true else { continue }
            let controls = Self.savePanelControls(in: root)
            guard let replace = Self.savePanelButton(in: controls, titled: ["replace", "substituir"]) else { continue }
            if !Self.isHosted(in: panel, element: root) {
                // A separate alert can also say Replace; verify this one is about the file we submitted.
                guard controls.contains(where: { element in
                    Self.axString(element, kAXRoleAttribute) == "AXStaticText"
                        && [kAXTitleAttribute, kAXValueAttribute].contains {
                            Self.axString(element, $0)?.contains(filename) == true
                        }
                }) else { continue }
            }
            let cancel = Self.axElement(root, kAXCancelButtonAttribute)
                ?? Self.savePanelButton(in: controls, titled: ["cancel", "cancelar"])
            return (replace, cancel)
        }
        return nil
    }

}
