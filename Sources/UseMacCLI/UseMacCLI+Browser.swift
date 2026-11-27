import Foundation
import UseMacProtocol

extension UseMacCLI {
    static func handleBrowser(args: [String], options: GlobalOptions) async throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: usemac browser <status|tabs|open|observe|extract|batch|screenshot|act|reload-extension> ...")
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "status":
            return try await handleBrowserStatus(args: rest, options: options)
        case "tabs":
            return try await handleBrowserTabs(args: rest, options: options)
        case "open":
            return try await handleBrowserOpen(args: rest, options: options)
        case "observe":
            return try await handleBrowserObserve(args: rest, options: options)
        case "extract":
            return try await handleBrowserExtract(args: rest, options: options)
        case "batch":
            return try await handleBrowserBatch(args: rest, options: options)
        case "screenshot":
            return try await handleBrowserScreenshot(args: rest, options: options)
        case "act":
            return try await handleBrowserAct(args: rest, options: options)
        case "reload-extension":
            return try await handleBrowserReloadExtension(args: rest, options: options)
        case "help":
            return try printHelp(for: ["browser"] + rest.prefix(1))
        default:
            throw CLIError.usage("Unknown browser subcommand: '\(subcommand)'. Use: status, tabs, open, observe, extract, batch, screenshot, act, reload-extension.")
        }
    }

    private static func handleBrowserTabs(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--profile", "--query"], boolFlags: [])
        let query = parsed.values["--query"] ?? parsed.positionals.first
        let params = BrowserTabsParams(profile: parsed.values["--profile"], query: query)
        let req = RPCRequest(method: .browserTabs, browserTabs: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 20000)
        try ensureOK(res)

        if options.json {
            if let tabs = res.browserTabs {
                printEncodableJSON(tabs)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        let tabs = res.browserTabs ?? []
        print(String(format: "[%@] %d Chrome tab(s) (%.2f ms):", mode.rawValue, tabs.count, rttMs))
        for tab in tabs {
            let activeTag = tab.active ? " [ACTIVE]" : ""
            print("  • tab=\(tab.tabId)\(activeTag) | \"\(tab.title)\" | \(tab.url)")
        }
        return 0
    }

    private static func handleBrowserStatus(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: [], boolFlags: [])
        if !parsed.positionals.isEmpty {
            throw CLIError.usage("Usage: usemac browser status")
        }
        let req = RPCRequest(method: .browserStatus)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)

        if options.json {
            if let profiles = res.browserProfiles {
                printEncodableJSON(profiles)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        let profiles = res.browserProfiles ?? []
        print(String(format: "[%@] %d connected Chrome profile(s) (%.2f ms):", mode.rawValue, profiles.count, rttMs))
        if profiles.isEmpty {
            print("  (no profiles connected — load Extension/ at chrome://extensions)")
        } else {
            for profile in profiles {
                let emailPart = profile.profileEmail.map { " <\($0)>" } ?? ""
                let streamPart = profile.streamingTabId.map { tabId in
                    let urlPart = profile.streamingUrl.map { " (\($0))" } ?? ""
                    return " | stream=tab:\(tabId)\(urlPart)"
                } ?? ""
                print("  • \(profile.profileName)\(emailPart) | v\(profile.extensionVersion) | tabs=\(profile.tabCount)\(streamPart)\(extensionStatusSuffix(profile))")
                if let note = profile.extensionNote {
                    print("    \(note)")
                }
            }
        }
        return 0
    }

    /// " | outdated (app ships 0.6.0 beta 3) | from another folder", or "" when the app knows nothing more.
    private static func extensionStatusSuffix(_ profile: BrowserProfileStatus) -> String {
        var parts: [String] = []
        if profile.extensionOutdated == true {
            parts.append("outdated (app ships \(profile.bundledExtensionVersion ?? "a newer version"))")
        }
        switch profile.extensionSource {
        case "app": parts.append("from UseMac.app")
        case "web_store": parts.append("from Chrome Web Store")
        case "other_folder": parts.append("from another folder")
        default: break
        }
        return parts.map { " | \($0)" }.joined()
    }

    private static func handleBrowserReloadExtension(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--profile"], boolFlags: ["--force"])
        if !parsed.positionals.isEmpty {
            throw CLIError.usage("Usage: usemac browser reload-extension [--profile <name>] [--force]")
        }
        let params = BrowserReloadExtensionParams(
            profile: parsed.values["--profile"],
            force: parsed.flags.contains("--force") ? true : nil
        )
        let req = RPCRequest(method: .browserReloadExtension, browserReloadExtension: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 90000)
        try ensureOK(res)

        let profiles = res.browserProfiles ?? []
        if options.json {
            printEncodableJSON(profiles)
            return 0
        }
        print(String(format: "[%@] Reloaded the extension in %d Chrome profile(s) (%.0f ms):", mode.rawValue, profiles.count, rttMs))
        for profile in profiles {
            print("  • \(profile.profileName) | v\(profile.extensionVersion)\(extensionStatusSuffix(profile))")
        }
        return 0
    }

    private static func parseDialogAction(_ raw: String?) throws -> String? {
        guard let action = raw?.lowercased() else { return nil }
        guard action == "accept" || action == "dismiss" else {
            throw CLIError.usage("dialogAction must be \"accept\" or \"dismiss\".")
        }
        return action
    }

    private static func handleBrowserOpen(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--steps", "--mode", "--wait-for-lease", "--dialog-action", "--dialog-prompt"],
            boolFlags: ["--same-tab", "--new-tab", "--no-stream", "--activate", "--new-window", "--auto-dismiss", "--diff-only"]
        )
        let usage = "Usage: usemac browser open <url> [--profile <name>] [--tab <id>] [--same-tab|--new-tab] [--activate] [--new-window] [--no-stream] [--auto-dismiss] [--steps '<json>'] [--mode <m>] [--task <taskId>], or: usemac browser open --tab <id> --activate"
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let activate = parsed.flags.contains("--activate")
        let newWindow = parsed.flags.contains("--new-window")
        let obsMode = try parseObservationMode(parsed.values)
        let url = parsed.positionals.first ?? ""
        // Only "activate this existing tab" may leave out the URL (sent as "").
        if url.isEmpty, !(tabId != nil && activate) {
            throw CLIError.usage(usage)
        }
        if parsed.positionals.count > 1 {
            throw CLIError.usage("Unexpected argument '\(parsed.positionals[1])'. \(usage)")
        }
        if newWindow, tabId != nil {
            throw CLIError.usage("--new-window opens the URL in a new window and cannot be combined with --tab.")
        }
        if newWindow, parsed.flags.contains("--same-tab") {
            throw CLIError.usage("--new-window cannot be combined with --same-tab.")
        }
        var postSteps: [ActionStep]?
        if let rawSteps = parsed.values["--steps"] {
            guard let data = rawSteps.data(using: .utf8) else {
                throw CLIError.invalidJSON("--steps is not valid UTF-8.")
            }
            do {
                postSteps = try JSONDecoder().decode([ActionStep].self, from: data)
            } catch {
                throw CLIError.invalidJSON(formatDecodingError(error))
            }
        }
        let openNewTab: Bool = {
            if url.isEmpty { return false }
            if parsed.flags.contains("--same-tab") { return false }
            if parsed.flags.contains("--new-tab") { return true }
            return tabId == nil
        }()
        let returnDiffOnly = parsed.flags.contains("--diff-only")
        let params = BrowserOpenParams(
            url: url,
            profile: parsed.values["--profile"],
            tabId: tabId,
            newTab: openNewTab,
            stream: !parsed.flags.contains("--no-stream"),
            activate: activate ? true : nil,
            newWindow: newWindow ? true : nil,
            taskId: options.taskId,
            steps: postSteps,
            autoDismissOverlays: parsed.flags.contains("--auto-dismiss") ? true : nil,
            returnDiffOnly: returnDiffOnly ? true : nil,
            observationMode: obsMode,
            waitForLeaseMs: try parseOptionalInt(parsed.values, flag: "--wait-for-lease"),
            dialogAction: try parseDialogAction(parsed.values["--dialog-action"]),
            dialogPromptText: parsed.values["--dialog-prompt"]
        )
        let req = RPCRequest(method: .browserOpen, browserOpen: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: postSteps == nil ? 20000 : 45000)
        try ensureOK(res)

        if options.json {
            printEncodableJSON(res)
            return 0
        }

        let tabStr = res.browserTabId.map { "tab=\($0)" } ?? (tabId.map { "tab=\($0)" } ?? "tab=?")
        let resolvedUrl = res.browserUrl ?? url
        let titlePart = res.browserTitle.map { " — \"\($0)\"" } ?? ""
        let verb = url.isEmpty ? "Chrome tab activated" : (newWindow ? "Chrome opened in a new window" : "Chrome opened")
        print(String(format: "[%@] %@ (%@): %@%@ (%.2f ms)", mode.rawValue, verb, tabStr, resolvedUrl, titlePart, rttMs))
        if let actionResult = res.actionResult {
            print("")
            printBatchActionResult(actionResult, rttMs: rttMs, mode: mode, returnDiffOnly: returnDiffOnly || obsMode == .delta)
        } else if let snapshot = res.snapshot {
            print("")
            let effectiveDiffOnly = returnDiffOnly || obsMode == .delta || (snapshot.elements.isEmpty && snapshot.diff != nil)
            print(snapshot.formattedCompactSummary(maxElements: 250, returnDiffOnly: effectiveDiffOnly))
        }
        return 0
    }

    private static func handleBrowserObserve(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--max-elements", "--width", "--height", "--scale", "--filter-role", "--filter-text", "--selector"],
            boolFlags: ["--screenshot", "--no-text", "--no-tables"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        let vpWidth = try parseOptionalInt(parsed.values, flag: "--width", positive: true)
        let vpHeight = try parseOptionalInt(parsed.values, flag: "--height", positive: true)
        let scale = try parseOptionalDouble(parsed.values, flag: "--scale", positive: true)
        let filter: ElementFilter? = {
            let role = parsed.values["--filter-role"]
            let text = parsed.values["--filter-text"]
            let selector = parsed.values["--selector"]
            if role == nil && text == nil && selector == nil { return nil }
            return ElementFilter(role: role, text: text, selector: selector)
        }()

        let params = BrowserObserveParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            maxElements: maxElements,
            includeText: !parsed.flags.contains("--no-text"),
            includeTables: !parsed.flags.contains("--no-tables"),
            includeScreenshot: parsed.flags.contains("--screenshot"),
            filter: filter,
            viewportWidth: vpWidth,
            viewportHeight: vpHeight,
            deviceScaleFactor: scale
        )
        let req = RPCRequest(method: .browserObserve, browserObserve: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 25000)
        try ensureOK(res)

        if options.json {
            if let snapshot = res.snapshot {
                printEncodableJSON(snapshot)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        guard let snapshot = res.snapshot else {
            throw CLIError.rpcFailure(code: "empty_snapshot", message: "Response missing WindowSnapshot.")
        }
        let tabInfo = res.browserTabId.map { " | tab=\($0)" } ?? ""
        let urlInfo = res.browserUrl.map { " | \($0)" } ?? ""
        print(String(format: "[%@] RTT: %.2f ms%@%@", mode.rawValue, rttMs, tabInfo, urlInfo))
        print(snapshot.formattedCompactSummary(maxElements: maxElements ?? 250, returnDiffOnly: snapshot.elements.isEmpty && snapshot.diff != nil))
        return 0
    }

    private static func handleBrowserExtract(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--selector", "--expr", "--max-chars", "--url-filter", "--frame-index"],
            boolFlags: ["--scan-horizontal", "--scan-vertical"]
        )
        let extractMode = parsed.positionals.first ?? "auto"
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let maxChars = try parseOptionalInt(parsed.values, flag: "--max-chars", positive: true) ?? 16000
        let frameIndex = try parseOptionalInt(parsed.values, flag: "--frame-index")
        let params = BrowserExtractParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            mode: extractMode,
            selector: parsed.values["--selector"],
            expression: parsed.values["--expr"],
            scanHorizontal: parsed.flags.contains("--scan-horizontal"),
            maxChars: maxChars,
            urlFilter: parsed.values["--url-filter"],
            scanVertical: parsed.flags.contains("--scan-vertical") ? true : nil,
            frameIndex: frameIndex
        )
        let req = RPCRequest(method: .browserExtract, browserExtract: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 35000)
        try ensureOK(res)

        if options.json {
            if let ext = res.browserExtract {
                printEncodableJSON(ext)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        guard let ext = res.browserExtract else {
            throw CLIError.rpcFailure(code: "empty_extract", message: "Response missing BrowserExtractResult.")
        }
        print(String(format: "[%@] Extract [%@] (%.1f ms, rtt=%.1f ms)", mode.rawValue, ext.mode, ext.latencyMs, rttMs))
        if let tables = ext.tablesMarkdown, !tables.isEmpty {
            print("--- TABLES / DATA GRIDS ---")
            print(tables)
        }
        if let json = ext.jsonResult, !json.isEmpty {
            print(ext.mode == "network" ? "--- NETWORK RESULT ---" : "--- EVAL RESULT ---")
            print(json)
        }
        if let text = ext.text, !text.isEmpty {
            print("--- EXTRACTED TEXT ---")
            print(text)
        }
        if let downloads = ext.downloads {
            print("--- RECENT DOWNLOADS (\(downloads.count)) ---")
            for dl in downloads {
                print("  • \(dl.formattedStatus)")
            }
        }
        return 0
    }

    private static func handleBrowserBatch(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--mode", "--extract-mode", "--max-elements"],
            boolFlags: ["--auto-dismiss", "--close-after"]
        )
        guard !parsed.positionals.isEmpty else {
            throw CLIError.usage("Usage: usemac browser batch <url1> [<url2> ...] [--profile <name>] [--mode observe|extract] [--extract-mode <m>] [--max-elements <n>] [--auto-dismiss] [--close-after]")
        }
        let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        let params = BrowserBatchParams(
            profile: parsed.values["--profile"],
            urls: parsed.positionals,
            mode: parsed.values["--mode"],
            extractMode: parsed.values["--extract-mode"],
            maxElements: maxElements,
            autoDismissOverlays: parsed.flags.contains("--auto-dismiss") ? true : nil,
            closeAfter: parsed.flags.contains("--close-after") ? true : nil
        )
        let req = RPCRequest(method: .browserBatch, browserBatch: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 45_000)
        try ensureOK(res)

        if options.json {
            if let batch = res.browserBatchResult {
                printEncodableJSON(batch)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        guard let batch = res.browserBatchResult else {
            throw CLIError.rpcFailure(code: "empty_batch_result", message: "Response missing BrowserBatchResult.")
        }
        print(String(format: "[%@] Browser batch: %d URL(s) (%.1f ms, rtt=%.1f ms)", mode.rawValue, batch.results.count, batch.totalLatencyMs, rttMs))
        for (idx, item) in batch.results.enumerated() {
            let tabStr = item.tabId.map { " | tab=\($0)" } ?? ""
            let errStr = item.error.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            print(String(format: "  [%d] %@ | %@%@ (%.1f ms)%@", idx, item.success ? "OK" : "FAIL", item.url, tabStr, item.latencyMs, errStr))
            if let ext = item.extract {
                if let tables = ext.tablesMarkdown, !tables.isEmpty { print(tables) }
                if let json = ext.jsonResult, !json.isEmpty { print(json) }
                if let text = ext.text, !text.isEmpty { print(text) }
            }
            if let snap = item.snapshot {
                print(snap.formattedCompactSummary(maxElements: maxElements ?? 250, returnDiffOnly: snap.elements.isEmpty && snap.diff != nil))
            }
        }
        return batch.results.allSatisfy(\.success) ? 0 : 1
    }

    private static func handleBrowserScreenshot(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--selector", "--element", "--width", "--height", "--scale", "--quality"],
            boolFlags: ["--full-page", "--diff-crop"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let vpWidth = try parseOptionalInt(parsed.values, flag: "--width", positive: true)
        let vpHeight = try parseOptionalInt(parsed.values, flag: "--height", positive: true)
        let scale = try parseOptionalDouble(parsed.values, flag: "--scale", positive: true)
        let quality = try parseOptionalInt(parsed.values, flag: "--quality", positive: true) ?? 84
        let params = BrowserScreenshotParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            selector: parsed.values["--selector"],
            elementId: parsed.values["--element"],
            fullPage: parsed.flags.contains("--full-page"),
            viewportWidth: vpWidth,
            viewportHeight: vpHeight,
            deviceScaleFactor: scale,
            quality: quality,
            returnImageContent: false,
            diffCrop: parsed.flags.contains("--diff-crop") ? true : nil
        )
        let req = RPCRequest(method: .browserScreenshot, browserScreenshot: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 25000)
        try ensureOK(res)

        if options.json {
            if let shot = res.screenshot {
                printEncodableJSON(shot)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        guard let shot = res.screenshot else {
            throw CLIError.rpcFailure(code: "empty_screenshot", message: "Response missing ScreenshotResult.")
        }
        print(String(format: "[%@] Browser screenshot: %@ (%dx%d, %d bytes, %.1f ms)", mode.rawValue, shot.path, shot.width, shot.height, shot.byteCount, rttMs))
        if shot.truncated == true {
            print(ScreenshotResult.truncatedNote(element: params.elementId != nil || params.selector != nil))
        }
        return 0
    }

    private static func handleBrowserAct(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--verify", "--mode", "--max-elements", "--wait-for-lease", "--dialog-action", "--dialog-prompt"],
            boolFlags: ["--read-only", "--screenshot", "--diff-crop", "--diff-only"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let obsModeOverride = try parseObservationMode(parsed.values)
        let maxElementsOverride = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)

        guard let rawInput = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac browser act '<steps-or-BrowserActParams-json>' [--profile <name>] [--tab <id>] [--read-only] [--verify \"<condition>\"] [--screenshot] [--mode <m>] [--diff-crop] [--diff-only]")
        }

        let jsonString: String
        if rawInput == "-" {
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: stdinData, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.invalidJSON("Empty stdin input.")
            }
            jsonString = text
        } else {
            jsonString = rawInput
        }

        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.invalidJSON("Empty JSON input.")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw CLIError.invalidJSON("Input is not valid UTF-8.")
        }

        let decoder = JSONDecoder()
        let readOnlyFlag = parsed.flags.contains("--read-only")
        let screenshotFlag = parsed.flags.contains("--screenshot")
        let diffCropFlag = parsed.flags.contains("--diff-crop")
        let diffOnlyFlag = parsed.flags.contains("--diff-only")
        let verifyOverride = parsed.values["--verify"]
        var params: BrowserActParams
        if trimmed.hasPrefix("[") {
            do {
                let steps = try decoder.decode([ActionStep].self, from: data)
                params = BrowserActParams(
                    profile: parsed.values["--profile"],
                    tabId: tabId,
                    steps: steps,
                    returnDiffOnly: diffOnlyFlag,
                    readOnly: readOnlyFlag ? true : nil,
                    verify: verifyOverride,
                    returnImageContent: screenshotFlag ? true : nil,
                    observationMode: obsModeOverride,
                    maxElements: maxElementsOverride,
                    diffCrop: diffCropFlag ? true : nil
                )
            } catch {
                throw CLIError.invalidJSON(formatDecodingError(error))
            }
        } else {
            try validateTopLevelKeys(in: data, allowedKeys: browserActAllowedKeys)
            var decoded: BrowserActParams
            do {
                decoded = try decoder.decode(BrowserActParams.self, from: data)
            } catch {
                throw CLIError.invalidJSON(formatDecodingError(error))
            }
            if let profileOverride = parsed.values["--profile"] {
                decoded.profile = profileOverride
            }
            if let tabOverride = tabId {
                decoded.tabId = tabOverride
            }
            if readOnlyFlag {
                decoded.readOnly = true
            }
            if let verifyOverride {
                decoded.verify = verifyOverride
            }
            if screenshotFlag {
                decoded.returnImageContent = true
            }
            if let obsModeOverride {
                decoded.observationMode = obsModeOverride
            }
            if let maxElementsOverride {
                decoded.maxElements = maxElementsOverride
            }
            if diffCropFlag {
                decoded.diffCrop = true
            }
            if diffOnlyFlag {
                decoded.returnDiffOnly = true
            }
            params = decoded
        }

        params.waitForLeaseMs = try parseOptionalInt(parsed.values, flag: "--wait-for-lease") ?? params.waitForLeaseMs
        params.dialogAction = try parseDialogAction(parsed.values["--dialog-action"] ?? params.dialogAction)
        params.dialogPromptText = parsed.values["--dialog-prompt"] ?? params.dialogPromptText
        let req = RPCRequest(method: .browserAct, browserAct: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 45000)
        try ensureOK(res)

        if options.json {
            if let actionResult = res.actionResult {
                printEncodableJSON(actionResult)
                return exitCode(for: actionResult)
            }
            printEncodableJSON(res)
            return 0
        }

        guard let result = res.actionResult else {
            throw CLIError.rpcFailure(code: "empty_action_result", message: "Response missing BatchActionResult.")
        }

        var detailParts: [String] = []
        if let resTabId = res.browserTabId {
            detailParts.append("tab=\(resTabId)")
        }
        if let resUrl = res.browserUrl, !resUrl.isEmpty {
            detailParts.append(resUrl)
        }
        let headerDetail = detailParts.isEmpty ? nil : detailParts.joined(separator: " ")
        printBatchActionResult(
            result,
            rttMs: rttMs,
            mode: mode,
            headerDetail: headerDetail,
            maxElements: params.maxElements,
            returnDiffOnly: params.returnDiffOnly || params.observationMode == .delta
        )
        return exitCode(for: result)
    }
}
