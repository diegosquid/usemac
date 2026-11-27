import ApplicationServices
import Foundation
import UseMacProtocol

/// Background macOS Menu Bar search & direct invocation via `kAXMenuBarAttribute`.
/// Traverses `AXMenuBarItem -> AXMenu -> AXMenuItem` and executes `AXPress` directly without stealing focus.
public enum MenuBarController {
    private static let cmdCharAttribute = "AXMenuItemCmdChar"
    private static let cmdModifiersAttribute = "AXMenuItemCmdModifiers"
    private static let cmdVirtualKeyAttribute = "AXMenuItemCmdVirtualKey"

    nonisolated(unsafe) private static let menuItemAttributes: CFArray = [
        kAXRoleAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXEnabledAttribute as CFString,
        "AXMenuItemCmdChar" as CFString,
        "AXMenuItemCmdModifiers" as CFString,
        "AXMenuItemCmdVirtualKey" as CFString,
        kAXChildrenAttribute as CFString
    ] as CFArray

    /// Searches (or lists) accessible menu bar items for `pid` without focusing the app.
    public static func search(
        pid: pid_t,
        appName: String,
        query: String? = nil,
        maxItems: Int = 80
    ) -> AppMenuResult {
        guard pid > 0 else {
            return AppMenuResult(app: appName, items: [], message: "Invalid target PID.")
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let menuBar = copyElement(axApp, kAXMenuBarAttribute) else {
            return AppMenuResult(
                app: appName,
                items: [],
                message: "\(appName) has no accessible menu bar."
            )
        }

        var collected: [AppMenuItemInfo] = []
        var visited: Set<AXUIElement> = []
        var budget = 1500
        let topBarItems = copyElementArray(menuBar, kAXChildrenAttribute)

        for (barIndex, barItem) in topBarItems.enumerated() {
            guard budget > 0 else { break }
            let barTitle = (copyString(barItem, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip Apple system menu unless the caller explicitly searched for it.
            if barIndex == 0 && (barTitle.isEmpty || barTitle.lowercased() == "apple") {
                if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty,
                   ElementMatcher.normalize(q).contains("apple") {
                    // allow
                } else {
                    continue
                }
            }
            let effectiveBarTitle = barTitle.isEmpty ? "App" : barTitle
            let menus = copyElementArray(barItem, kAXChildrenAttribute)
            for menu in menus {
                collectMenuItems(
                    from: menu,
                    prefixPath: [effectiveBarTitle],
                    depth: 0,
                    maxDepth: 5,
                    visited: &visited,
                    budget: &budget,
                    into: &collected
                )
            }
        }

        let limit = max(1, maxItems)
        let filtered = filterItems(collected, query: query, limit: limit)
        let message: String
        if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            message = filtered.isEmpty
                ? "No menu items in \(appName) matched \"\(q)\"."
                : "Found \(filtered.count) menu item\(filtered.count == 1 ? "" : "s") matching \"\(q)\"."
        } else {
            message = "Listed \(filtered.count) of \(collected.count) menu items in \(appName)."
        }
        return AppMenuResult(app: appName, items: filtered, message: message)
    }

    /// Invokes a menu bar item by path (e.g. `["File", "Export as PDF…"]`) in the background via `AXPress`.
    public static func invoke(
        pid: pid_t,
        appName: String,
        path: [String]
    ) -> (success: Bool, result: AppMenuResult, errorCode: String?, message: String?) {
        let segments = normalizePathSegments(path)
        guard !segments.isEmpty else {
            let msg = "menuPath must be a non-empty array of menu item titles (e.g. [\"File\", \"New Window\"])."
            return (false, AppMenuResult(app: appName, message: msg), "INVALID_REQUEST", msg)
        }
        guard pid > 0 else {
            let msg = "Target app \(appName) is not running."
            return (false, AppMenuResult(app: appName, message: msg), "APP_NOT_FOUND", msg)
        }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let menuBar = copyElement(axApp, kAXMenuBarAttribute) else {
            let msg = "\(appName) has no accessible menu bar."
            return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
        }

        let topBarItems = copyElementArray(menuBar, kAXChildrenAttribute)

        // Single-segment convenience: if caller passed ["Save"] without ["File", "Save"], search leaf items.
        if segments.count == 1 {
            if let direct = findSingleSegmentLeaf(in: topBarItems, wanted: segments[0]) {
                return pressMenuItem(direct.element, resolvedPath: direct.path, enabled: direct.enabled, appName: appName)
            }
            let msg = "No menu item matching \"\(segments[0])\" was found in \(appName)."
            return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
        }

        // Hierarchical traversal: top-level AXMenuBarItem -> AXMenu -> AXMenuItem -> ...
        let topCandidates: [(title: String, element: AXUIElement)] = topBarItems.compactMap { item in
            guard let title = copyString(item, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            return (title, item)
        }

        guard let topMatch = matchBestSegment(segments[0], in: topCandidates) else {
            let available = topCandidates.map(\.title).joined(separator: ", ")
            let msg = "Menu \"\(segments[0])\" not found in \(appName). Available menus: \(available)."
            return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
        }

        var currentContainer = topMatch.element
        var resolvedPath: [String] = [topMatch.title]
        var finalItem: AXUIElement?
        var finalEnabled: Bool = true

        for segIndex in 1..<segments.count {
            let wantSeg = segments[segIndex]
            let isLast = (segIndex == segments.count - 1)
            let menus = copyElementArray(currentContainer, kAXChildrenAttribute)
            guard let submenu = menus.first(where: { copyString($0, kAXRoleAttribute) == "AXMenu" }) ?? menus.first else {
                let msg = "Menu \"\(resolvedPath.joined(separator: " → "))\" has no submenu items in \(appName)."
                return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
            }

            let menuItems = copyElementArray(submenu, kAXChildrenAttribute)
            var candidates: [(title: String, element: AXUIElement, enabled: Bool)] = []
            for item in menuItems {
                let parsed = readMenuItem(item)
                let title = (parsed.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                candidates.append((title, item, parsed.enabled))
            }

            guard let matched = matchBestSegment(wantSeg, in: candidates.map { ($0.title, $0.element) }) else {
                let sample = candidates.prefix(12).map(\.title).joined(separator: ", ")
                let msg = "Menu item \"\(wantSeg)\" not found under \"\(resolvedPath.joined(separator: " → "))\" in \(appName). Available: \(sample)."
                return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
            }

            resolvedPath.append(matched.title)
            if isLast {
                finalItem = matched.element
                finalEnabled = candidates.first(where: { CFEqual($0.element, matched.element) })?.enabled ?? true
            } else {
                currentContainer = matched.element
            }
        }

        guard let target = finalItem else {
            let msg = "Menu path \"\(segments.joined(separator: " → "))\" did not resolve to an item in \(appName)."
            return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
        }

        return pressMenuItem(target, resolvedPath: resolvedPath, enabled: finalEnabled, appName: appName)
    }

    private static func pressMenuItem(
        _ element: AXUIElement,
        resolvedPath: [String],
        enabled: Bool,
        appName: String
    ) -> (success: Bool, result: AppMenuResult, errorCode: String?, message: String?) {
        let label = resolvedPath.joined(separator: " → ")
        if !enabled {
            let msg = "Menu item \"\(label)\" in \(appName) is currently disabled."
            return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
        }
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard err == .success else {
            let msg = "AXPress failed on menu item \"\(label)\" in \(appName) (AXError \(err.rawValue))."
            return (false, AppMenuResult(app: appName, message: msg), "ELEMENT_NOT_FOUND", msg)
        }
        let msg = "Invoked \(label)"
        return (true, AppMenuResult(app: appName, invokedPath: resolvedPath, message: msg), nil, msg)
    }

    // MARK: - Pure Helpers (unit-testable without Accessibility)

    /// Strips trailing ellipsis (`…` or `...`) and normalizes case, diacritics, and whitespace.
    internal static func normalizeMenuTitle(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("…") {
            trimmed.removeLast()
        }
        while trimmed.hasSuffix("...") {
            trimmed.removeLast(3)
        }
        return ElementMatcher.normalize(trimmed)
    }

    /// Splits single-string breadcrumb paths like `["File > Export"]` or `["File → Save"]` into segments.
    internal static func normalizePathSegments(_ rawPath: [String]) -> [String] {
        var segments: [String] = []
        for entry in rawPath {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if rawPath.count == 1 {
                if trimmed.contains("→") {
                    segments.append(contentsOf: trimmed.components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    continue
                }
                if trimmed.contains(" > ") {
                    segments.append(contentsOf: trimmed.components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    continue
                }
            }
            segments.append(trimmed)
        }
        return segments
    }

    /// Ranks and filters menu items against an optional query string (exact title -> prefix -> substring -> path).
    internal static func filterItems(_ items: [AppMenuItemInfo], query: String?, limit: Int) -> [AppMenuItemInfo] {
        guard let rawQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines), !rawQuery.isEmpty else {
            return Array(items.prefix(max(1, limit)))
        }
        let want = normalizeMenuTitle(rawQuery)
        guard !want.isEmpty else {
            return Array(items.prefix(max(1, limit)))
        }

        var scored: [(rank: Int, index: Int, item: AppMenuItemInfo)] = []
        for (idx, item) in items.enumerated() {
            let normTitle = normalizeMenuTitle(item.title)
            let normPath = normalizeMenuTitle(item.path.joined(separator: " "))
            let normShortcut = item.shortcut.map { ElementMatcher.normalize($0) } ?? ""

            let rank: Int?
            if normTitle == want {
                rank = 0
            } else if normTitle.hasPrefix(want) {
                rank = 1
            } else if normTitle.contains(want) {
                rank = 2
            } else if normPath.contains(want) {
                rank = 3
            } else if !normShortcut.isEmpty && normShortcut.contains(want) {
                rank = 4
            } else {
                rank = nil
            }
            if let rank {
                scored.append((rank, idx, item))
            }
        }
        scored.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.index < b.index
        }
        return Array(scored.prefix(max(1, limit)).map(\.item))
    }

    /// Picks the best matching item title in a menu level (exact -> prefix -> substring).
    internal static func matchBestTitle(_ wanted: String, in titles: [String]) -> Int? {
        let want = normalizeMenuTitle(wanted)
        guard !want.isEmpty else { return nil }
        let normalized = titles.map(normalizeMenuTitle)
        if let exact = normalized.firstIndex(of: want) {
            return exact
        }
        if let prefix = normalized.firstIndex(where: { $0.hasPrefix(want) }) {
            return prefix
        }
        return normalized.firstIndex(where: { $0.contains(want) })
    }

    private static func matchBestSegment<T>(_ wanted: String, in candidates: [(title: String, element: T)]) -> (title: String, element: T)? {
        guard let idx = matchBestTitle(wanted, in: candidates.map(\.title)) else { return nil }
        return candidates[idx]
    }

    /// Formats `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers` (+ optional `AXMenuItemCmdVirtualKey`)
    /// into standard macOS shortcut notation (e.g. `⇧⌘S`, `⌥⌘I`, `⌘N`).
    internal static func formatShortcut(cmdChar: String?, modifiers: Int?, virtualKey: Int? = nil) -> String? {
        let keyLabel: String?
        if let raw = cmdChar?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            keyLabel = raw.uppercased()
        } else if let vk = virtualKey {
            keyLabel = virtualKeySymbol(vk)
        } else {
            keyLabel = nil
        }
        guard let keyLabel, !keyLabel.isEmpty else { return nil }

        let mask = modifiers ?? 0
        let hasShift = (mask & (1 << 0)) != 0
        let hasOption = (mask & (1 << 1)) != 0
        let hasControl = (mask & (1 << 2)) != 0
        let noCommand = (mask & (1 << 3)) != 0

        var prefix = ""
        if hasControl { prefix += "⌃" }
        if hasOption { prefix += "⌥" }
        if hasShift { prefix += "⇧" }
        if !noCommand { prefix += "⌘" }
        return prefix + keyLabel
    }

    private static func virtualKeySymbol(_ code: Int) -> String? {
        switch code {
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }

    // MARK: - AX Traversal Helpers

    private struct ParsedMenuItem {
        var role: String?
        var title: String?
        var enabled: Bool
        var cmdChar: String?
        var cmdModifiers: Int?
        var cmdVirtualKey: Int?
        var children: [AXUIElement]
    }

    private static func collectMenuItems(
        from menu: AXUIElement,
        prefixPath: [String],
        depth: Int,
        maxDepth: Int,
        visited: inout Set<AXUIElement>,
        budget: inout Int,
        into out: inout [AppMenuItemInfo]
    ) {
        guard depth <= maxDepth, budget > 0, !visited.contains(menu) else { return }
        visited.insert(menu)

        let children = copyElementArray(menu, kAXChildrenAttribute)
        for child in children {
            guard budget > 0 else { return }
            budget -= 1
            let parsed = readMenuItem(child)
            let title = (parsed.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let itemPath = prefixPath + [title]
            let submenus = parsed.children.filter { copyString($0, kAXRoleAttribute) == "AXMenu" }
            if !submenus.isEmpty && depth < maxDepth {
                for sub in submenus {
                    collectMenuItems(
                        from: sub,
                        prefixPath: itemPath,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        visited: &visited,
                        budget: &budget,
                        into: &out
                    )
                }
            } else {
                let shortcut = formatShortcut(
                    cmdChar: parsed.cmdChar,
                    modifiers: parsed.cmdModifiers,
                    virtualKey: parsed.cmdVirtualKey
                )
                out.append(AppMenuItemInfo(
                    path: itemPath,
                    title: title,
                    shortcut: shortcut,
                    enabled: parsed.enabled
                ))
            }
        }
    }

    private static func findSingleSegmentLeaf(
        in topBarItems: [AXUIElement],
        wanted: String
    ) -> (element: AXUIElement, path: [String], enabled: Bool)? {
        let wantNorm = normalizeMenuTitle(wanted)
        guard !wantNorm.isEmpty else { return nil }

        var bestMatch: (rank: Int, element: AXUIElement, path: [String], enabled: Bool)?
        var visited: Set<AXUIElement> = []
        var budget = 1200

        func scan(menu: AXUIElement, prefix: [String], depth: Int) {
            guard depth <= 4, budget > 0, !visited.contains(menu) else { return }
            visited.insert(menu)
            for child in copyElementArray(menu, kAXChildrenAttribute) {
                guard budget > 0 else { return }
                budget -= 1
                let parsed = readMenuItem(child)
                let title = (parsed.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let itemPath = prefix + [title]
                let submenus = parsed.children.filter { copyString($0, kAXRoleAttribute) == "AXMenu" }
                if !submenus.isEmpty {
                    for sub in submenus {
                        scan(menu: sub, prefix: itemPath, depth: depth + 1)
                    }
                    continue
                }
                let norm = normalizeMenuTitle(title)
                let rank: Int?
                if norm == wantNorm { rank = 0 }
                else if norm.hasPrefix(wantNorm) { rank = 1 }
                else if norm.contains(wantNorm) { rank = 2 }
                else { rank = nil }
                if let rank {
                    if bestMatch == nil || rank < bestMatch!.rank || (rank == bestMatch!.rank && parsed.enabled && !bestMatch!.enabled) {
                        bestMatch = (rank, child, itemPath, parsed.enabled)
                        if rank == 0 && parsed.enabled { return }
                    }
                }
            }
        }

        for (idx, barItem) in topBarItems.enumerated() {
            let barTitle = (copyString(barItem, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if idx == 0 && (barTitle.isEmpty || barTitle.lowercased() == "apple") { continue }
            let prefix = [barTitle.isEmpty ? "App" : barTitle]
            for menu in copyElementArray(barItem, kAXChildrenAttribute) {
                scan(menu: menu, prefix: prefix, depth: 0)
                if bestMatch?.rank == 0 && bestMatch?.enabled == true { break }
            }
            if bestMatch?.rank == 0 && bestMatch?.enabled == true { break }
        }

        return bestMatch.map { ($0.element, $0.path, $0.enabled) }
    }

    private static func readMenuItem(_ element: AXUIElement) -> ParsedMenuItem {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            menuItemAttributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        )
        if err == .success, let values = valuesRef as? [AnyObject], values.count >= 7 {
            return ParsedMenuItem(
                role: axString(values[0]),
                title: axString(values[1]),
                enabled: axBool(values[2]) ?? true,
                cmdChar: axString(values[3]),
                cmdModifiers: axInt(values[4]),
                cmdVirtualKey: axInt(values[5]),
                children: axElementArray(values[6])
            )
        }
        return ParsedMenuItem(
            role: copyString(element, kAXRoleAttribute),
            title: copyString(element, kAXTitleAttribute),
            enabled: copyBool(element, kAXEnabledAttribute) ?? true,
            cmdChar: copyString(element, cmdCharAttribute),
            cmdModifiers: copyInt(element, cmdModifiersAttribute),
            cmdVirtualKey: copyInt(element, cmdVirtualKeyAttribute),
            children: copyElementArray(element, kAXChildrenAttribute)
        )
    }

    private static func isErrorSentinel(_ obj: AnyObject) -> Bool {
        if obj is NSNull { return true }
        guard CFGetTypeID(obj) == AXValueGetTypeID() else { return false }
        return AXValueGetType(unsafeBitCast(obj, to: AXValue.self)) == .axError
    }

    private static func axString(_ obj: AnyObject) -> String? {
        guard !isErrorSentinel(obj) else { return nil }
        return obj as? String
    }

    private static func axBool(_ obj: AnyObject) -> Bool? {
        guard !isErrorSentinel(obj) else { return nil }
        return (obj as? NSNumber)?.boolValue
    }

    private static func axInt(_ obj: AnyObject) -> Int? {
        guard !isErrorSentinel(obj) else { return nil }
        return (obj as? NSNumber)?.intValue
    }

    private static func axElementArray(_ obj: AnyObject) -> [AXUIElement] {
        guard !isErrorSentinel(obj), let array = obj as? [AnyObject] else { return [] }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
        }
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else {
            return []
        }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
        }
    }
}
