import Foundation
import Darwin
import Dispatch
import UseMacProtocol
import UseMacEngine
import UseMacIPC

extension UseMacCLI {
    // MARK: - Commands

    static func handlePing(options: GlobalOptions) async throws -> Int32 {
        let req = RPCRequest(method: .ping)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)

        if options.json {
            let payload: [String: Any] = [
                "ok": res.ok,
                "mode": mode.rawValue,
                "pong": res.pong ?? "pong",
                "roundTripMs": rttMs,
                "roundTripUs": rttMs * 1000.0,
                "serverLatencyMs": res.serverLatencyMs
            ]
            printJSONObject(payload)
            return 0
        }

        let rttUs = rttMs * 1000.0
        let pong = res.pong ?? "pong"
        print(String(format: "[%@] %@ | rtt: %.1f µs (%.3f ms) | server: %.3f ms", mode.rawValue, pong, rttUs, rttMs, res.serverLatencyMs))
        return 0
    }

    static func handleStatus(options: GlobalOptions) async throws -> Int32 {
        let req = RPCRequest(method: .status)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)

        if options.json {
            if let status = res.status {
                printEncodableJSON(status)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        guard let s = res.status else {
            throw CLIError.rpcFailure(code: "empty_status", message: "Empty status response.")
        }

        let modeNote = mode == .inProcess
            ? "[in-process] (daemon not detected at \(options.socketPath))"
            : "[daemon] (\(s.socketPath))"
        print("UseMac v\(s.version) \(modeNote)")
        print("PID: \(s.pid) | Policy: \(s.policy.rawValue) | Kill Switch: \(s.killSwitchTripped ? "TRIPPED" : "normal")")
        print("Permissions: Accessibility=\(s.permissions.accessibilityGranted ? "ok" : "denied"), Screen Recording=\(s.permissions.screenRecordingGranted ? "ok" : "denied")")
        if let paired = s.pairedApp {
            print("Paired app: \(paired.name) (pid \(paired.pid))")
        }
        if let front = s.frontmostApp {
            let title = front.windowTitle.map { " — \($0)" } ?? ""
            print("Frontmost app: \(front.name) (pid \(front.pid))\(title)")
        }
        if !s.browserProfiles.isEmpty {
            let names = s.browserProfiles.map(\.profileName).joined(separator: ", ")
            print("Chrome Bridge: \(s.browserProfiles.count) connected profile(s) (\(names))")
        }
        print(String(
            format: "Telemetry: reqs=%d | actions=%d | hot-cache=%d | clients=%d | avg-observe=%.2f ms | rtt=%.2f ms",
            s.telemetry.totalRequests,
            s.telemetry.totalActions,
            s.telemetry.hotCacheHits,
            s.telemetry.activeClients,
            s.telemetry.avgObserveLatencyMs,
            rttMs
        ))
        return 0
    }

    static func handleApps(options: GlobalOptions) async throws -> Int32 {
        let req = RPCRequest(method: .listApps)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)

        if options.json {
            if let apps = res.apps {
                printEncodableJSON(apps)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        let apps = res.apps ?? []
        print(String(format: "[%@] %d application(s) (%.2f ms):", mode.rawValue, apps.count, rttMs))
        for app in apps {
            let activeTag = app.isActive ? "*ACTIVE*" : "        "
            let bundle = app.bundleId ?? "-"
            let title = app.windowTitle.map { " | \"\($0)\"" } ?? ""
            print("  \(activeTag) pid=\(app.pid)\t\(app.name) (\(bundle))\(title)")
        }
        return 0
    }

    static func handleObserve(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--app", "--max-depth", "--max-elements", "--role", "--text", "--filter-role", "--filter-text", "--window"],
            boolFlags: ["--no-cache", "--diff", "--no-diff", "--diff-only", "--screenshot", "--include-offscreen", "--no-offscreen"]
        )
        if let extra = parsed.positionals.first {
            throw CLIError.usage("Unexpected argument '\(extra)'. Run 'usemac help observe'.")
        }

        let maxDepth = try parseOptionalInt(parsed.values, flag: "--max-depth", positive: true)
        let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        let useCache = !parsed.flags.contains("--no-cache")
        let includeDiff = parsed.flags.contains("--diff") || parsed.flags.contains("--diff-only") || !parsed.flags.contains("--no-diff")
        let includeScreenshot = parsed.flags.contains("--screenshot")
        let filter = ElementMatch(role: parsed.values["--role"], text: parsed.values["--text"])
        let serverFilter: ElementFilter? = {
            let role = parsed.values["--filter-role"]
            let text = parsed.values["--filter-text"]
            return (role == nil && text == nil) ? nil : ElementFilter(role: role, text: text)
        }()

        let params = ObserveParams(
            app: parsed.values["--app"],
            maxDepth: maxDepth,
            maxElements: maxElements,
            useCache: useCache,
            includeDiff: includeDiff,
            includeScreenshot: includeScreenshot,
            includeOffscreen: parsed.flags.contains("--include-offscreen")
                ? true
                : (parsed.flags.contains("--no-offscreen") ? false : nil),
            window: parsed.values["--window"],
            filter: serverFilter
        )
        let req = RPCRequest(method: .observe, observe: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)

        guard var snapshot = res.snapshot else {
            if options.json {
                printEncodableJSON(res)
                return 0
            }
            throw CLIError.rpcFailure(code: "empty_snapshot", message: "Response missing WindowSnapshot.")
        }

        // --role/--text only narrow what is printed; the daemon still indexes (and keeps ids for) the whole window.
        let totalElements = snapshot.elements.count
        if !filter.isEmpty {
            snapshot.elements = ClientElementFilter.filter(snapshot.elements, filter)
        }

        if options.json {
            printEncodableJSON(snapshot)
            return 0
        }

        print(String(format: "[%@] RTT: %.2f ms", mode.rawValue, rttMs))
        if !filter.isEmpty {
            print("Filter: \(describeMatch(filter)) → \(snapshot.elements.count) of \(totalElements) elements")
        }
        let diffOnly = parsed.flags.contains("--diff-only") || (snapshot.elements.isEmpty && snapshot.diff != nil)
        print(snapshot.formattedCompactSummary(maxElements: maxElements ?? 250, returnDiffOnly: diffOnly))
        return 0
    }

    private struct FindOutput: Encodable {
        let app: AppDescriptor
        let count: Int
        let matches: [ElementNode]
    }

    static func handleFind(args: [String], options: GlobalOptions) async throws -> Int32 {
        let usage = "Usage: usemac find --app <name|pid> [--window <title>] [--role <role>] [--text <t>] [--title <t>] [--value <v>] [--exact] [--first] [--max-depth <n>] [--max-elements <n>]"
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--app", "--role", "--text", "--title", "--value", "--max-depth", "--max-elements", "--window"],
            boolFlags: ["--exact", "--first"]
        )
        if let extra = parsed.positionals.first {
            throw CLIError.usage("Unexpected argument '\(extra)'. \(usage)")
        }
        guard let app = parsed.values["--app"], !app.isEmpty else {
            throw CLIError.usage("find needs --app. \(usage)")
        }
        let match = ElementMatch(
            role: parsed.values["--role"],
            title: parsed.values["--title"],
            value: parsed.values["--value"],
            text: parsed.values["--text"],
            exact: parsed.flags.contains("--exact") ? true : nil
        )
        guard [match.role, match.title, match.value, match.text].contains(where: { !($0 ?? "").isEmpty }) else {
            throw CLIError.usage("find needs at least one of --role, --text, --title or --value. \(usage)")
        }
        let onlyFirst = parsed.flags.contains("--first")

        // Always read the live tree: a cached tree could hide the element the agent is about to act on.
        let params = ObserveParams(
            app: app,
            maxDepth: try parseOptionalInt(parsed.values, flag: "--max-depth", positive: true),
            maxElements: try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true),
            useCache: false,
            includeDiff: false,
            includeScreenshot: false,
            window: parsed.values["--window"]
        )
        let (res, rttMs, mode) = try await executeRPC(RPCRequest(method: .observe, observe: params), options: options)
        try ensureOK(res)
        guard let snapshot = res.snapshot else {
            throw CLIError.rpcFailure(code: "empty_snapshot", message: "Response missing WindowSnapshot.")
        }

        var matches = ClientElementFilter.filter(snapshot.elements, match)
        if onlyFirst {
            matches = Array(matches.prefix(1))
        }

        if options.json {
            printEncodableJSON(FindOutput(app: snapshot.app, count: matches.count, matches: matches))
            return matches.isEmpty ? 1 : 0
        }

        if onlyFirst {
            guard let first = matches.first else {
                writeStderr("No element in \(snapshot.app.name) matches \(describeMatch(match)).\n")
                return 1
            }
            print(first.id)
            return 0
        }

        let titlePart = snapshot.app.windowTitle.map { " — \($0)" } ?? ""
        print(String(
            format: "[%@] %d match(es) of %d element(s) in %@%@ (%.2f ms)",
            mode.rawValue,
            matches.count,
            snapshot.elements.count,
            snapshot.app.name,
            titlePart,
            rttMs
        ))
        for node in matches {
            print(node.compactLine)
        }
        if matches.isEmpty {
            writeStderr("No element matches \(describeMatch(match)). Raise --max-depth/--max-elements, scroll the list into view, or loosen the filters.\n")
            return 1
        }
        return 0
    }

    private static func describeMatch(_ match: ElementMatch) -> String {
        var parts: [String] = []
        if let role = match.role, !role.isEmpty { parts.append("role=\(role)") }
        if let title = match.title, !title.isEmpty { parts.append("title=\"\(title)\"") }
        if let value = match.value, !value.isEmpty { parts.append("value=\"\(value)\"") }
        if let text = match.text, !text.isEmpty { parts.append("text=\"\(text)\"") }
        if match.exact == true { parts.append("exact") }
        return parts.joined(separator: " ")
    }

    private static func parseMenuPathString(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        for sep in [" → ", " -> ", " > ", ">", "→", "/"] {
            if trimmed.contains(sep) {
                let parts = trimmed.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty { return parts }
            }
        }
        return trimmed.isEmpty ? [] : [trimmed]
    }

    static func handleMenu(args: [String], options: GlobalOptions) async throws -> Int32 {
        let usage = "Usage: usemac menu [--app <name|pid>] [--query <text>] [--invoke \"File > Save\"] | usemac menu invoke --app <name> <Menu> <Item>..."
        var effectiveArgs = args
        var isInvokeSub = false
        if let first = args.first {
            if first == "invoke" {
                isInvokeSub = true
                effectiveArgs = Array(args.dropFirst())
            } else if first == "list" || first == "search" {
                effectiveArgs = Array(args.dropFirst())
            }
        }

        let parsed = try parseAppAndExtras(
            args: effectiveArgs,
            valueFlags: ["--app", "--query", "--invoke", "--wait-for-lease"],
            boolFlags: []
        )
        var menuPath: [String]?
        if let rawInvoke = parsed.values["--invoke"] {
            let parts = parseMenuPathString(rawInvoke)
            guard !parts.isEmpty else {
                throw CLIError.usage("--invoke expects a menu path like \"File > Export as PDF…\".")
            }
            menuPath = parts
        } else if isInvokeSub {
            guard !parsed.positionals.isEmpty else {
                throw CLIError.usage("menu invoke needs menu path segments. \(usage)")
            }
            menuPath = parsed.positionals
        }

        let query = menuPath == nil ? (parsed.values["--query"] ?? parsed.positionals.first) : nil
        let params = AppMenuParams(
            app: parsed.values["--app"],
            query: query,
            menuPath: menuPath,
            waitForLeaseMs: try parseOptionalInt(parsed.values, flag: "--wait-for-lease")
        )
        let req = RPCRequest(method: .appMenu, appMenu: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 20_000)
        try ensureOK(res)

        if options.json {
            if let menu = res.appMenuResult {
                printEncodableJSON(menu)
                return 0
            }
            printEncodableJSON(res)
            return 0
        }

        guard let menu = res.appMenuResult else {
            throw CLIError.rpcFailure(code: "empty_menu_result", message: "Response missing AppMenuResult.")
        }
        if let invoked = menu.invokedPath, !invoked.isEmpty {
            let msg = menu.message.map { " — \($0)" } ?? ""
            print(String(format: "[%@] Menu [%@]: invoked %@%@ (%.2f ms)", mode.rawValue, menu.app, invoked.joined(separator: " → "), msg, rttMs))
            return 0
        }
        let items = menu.items ?? []
        print(String(format: "[%@] Menu [%@]: %d item(s) (%.2f ms)", mode.rawValue, menu.app, items.count, rttMs))
        for item in items {
            let shortcut = item.shortcut.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let disabled = item.enabled ? "" : " [disabled]"
            print("  • \(item.path.joined(separator: " → "))\(shortcut)\(disabled)")
        }
        return 0
    }

    private static func parseBatchArgs(_ args: [String]) throws -> (values: [String: String], flags: Set<String>, positionals: [String]) {
        let parsed = try parseAppAndExtras(args: args, valueFlags: batchValueFlags, boolFlags: batchBoolFlags)
        if let title = parsed.values["--expect-title"], title.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CLIError.usage("--expect-title expects the text the window title must contain.")
        }
        _ = try parseObservationMode(parsed.values)
        _ = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        return parsed
    }

    /// Flags win over the same keys in the JSON, so a caller can add a precondition to a saved batch.
    private static func applyBatchFlags(_ parsed: (values: [String: String], flags: Set<String>, positionals: [String]), to batch: inout BatchActionRequest) throws {
        if parsed.flags.contains("--foreground") {
            batch.foreground = true
        }
        if parsed.flags.contains("--foreground-fallback") {
            batch.foregroundFallback = true
        }
        if parsed.flags.contains("--allow-stale") {
            batch.allowStaleSnapshot = true
        }
        if parsed.flags.contains("--diff-crop") {
            batch.diffCrop = true
        }
        if parsed.flags.contains("--diff-only") {
            batch.returnDiffOnly = true
        }
        if let title = parsed.values["--expect-title"] {
            batch.expectWindowTitle = title
        }
        if let window = parsed.values["--window"] {
            batch.window = window
        }
        if let obsMode = try parseObservationMode(parsed.values) {
            batch.observationMode = obsMode
        }
        if let verify = parsed.values["--verify"] {
            batch.verify = verify
        }
        if let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true) {
            batch.maxElements = maxElements
        }
        if let waitForLeaseMs = try parseOptionalInt(parsed.values, flag: "--wait-for-lease") {
            batch.waitForLeaseMs = waitForLeaseMs
        }
    }

    static func handleAct(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseBatchArgs(args)
        guard let rawInput = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac act '<json>' | - [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]. Run 'usemac help act'.")
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
        var batch: BatchActionRequest
        if trimmed.hasPrefix("[") {
            do {
                let steps = try decoder.decode([ActionStep].self, from: data)
                batch = BatchActionRequest(app: parsed.values["--app"], steps: steps)
            } catch {
                throw CLIError.invalidJSON(formatDecodingError(error))
            }
        } else {
            try validateTopLevelKeys(in: data, allowedKeys: batchActionAllowedKeys)
            do {
                batch = try decoder.decode(BatchActionRequest.self, from: data)
            } catch {
                throw CLIError.invalidJSON(formatDecodingError(error))
            }
            if batch.app == nil, let appOverride = parsed.values["--app"] {
                batch.app = appOverride
            }
        }

        try applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    static func handleClick(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseBatchArgs(args)
        guard let elementId = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac click <@eID> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]")
        }
        let app = parsed.values["--app"]
        var batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .click, app: app, elementId: elementId)]
        )
        try applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    static func handleSet(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseBatchArgs(args)
        guard parsed.positionals.count >= 2 else {
            throw CLIError.usage("Usage: usemac set <@eID> <text> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]")
        }
        let elementId = parsed.positionals[0]
        let text = parsed.positionals.dropFirst().joined(separator: " ")
        let app = parsed.values["--app"]
        var batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .setValue, app: app, elementId: elementId, text: text)]
        )
        try applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    static func handleType(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseBatchArgs(args)
        guard !parsed.positionals.isEmpty else {
            throw CLIError.usage("Usage: usemac type <text> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]")
        }
        let text = parsed.positionals.joined(separator: " ")
        let app = parsed.values["--app"]
        var batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .type, app: app, text: text)]
        )
        try applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    static func handleKey(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseBatchArgs(args)
        guard let chord = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac key <chord> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]")
        }
        let (modifiers, key) = parseKeyChord(chord)
        let app = parsed.values["--app"]
        var batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .pressKey, app: app, key: key, modifiers: modifiers.isEmpty ? nil : modifiers)]
        )
        try applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    private static func sendBatchAction(_ batch: BatchActionRequest, options: GlobalOptions) async throws -> Int32 {
        let req = RPCRequest(method: .act, act: batch)
        // Same budget as the MCP server: an uploadFile step alone can wait ~15 s for Spotlight.
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 60_000)
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

        printBatchActionResult(
            result,
            rttMs: rttMs,
            mode: mode,
            maxElements: batch.maxElements,
            returnDiffOnly: batch.returnDiffOnly || batch.observationMode == .delta
        )
        return exitCode(for: result)
    }

    static func printBatchActionResult(
        _ result: BatchActionResult,
        rttMs: Double,
        mode: ExecutionMode,
        headerDetail: String? = nil,
        maxElements: Int? = nil,
        returnDiffOnly: Bool = false
    ) {
        let detailPart = headerDetail.map { " | \($0)" } ?? ""
        print(String(
            format: "[%@] Action %@ | total: %.2f ms | rtt: %.2f ms%@",
            mode.rawValue,
            result.success ? "OK" : "FAILED",
            result.totalLatencyMs,
            rttMs,
            detailPart
        ))
        for step in result.stepResults {
            var extras: [String] = []
            if let effect = step.effect, effect != .none {
                extras.append("effect=\(effect.rawValue)")
            }
            if let d = step.scrollDeltaY {
                extras.append(String(format: "scrollDeltaY=%.0fpx", d))
            }
            if let v = step.visualChangePercent {
                extras.append(String(format: "visualDiff=%.2f%%", v))
            }
            if let dl = step.downloadPath, !dl.isEmpty {
                extras.append("download=\(dl)")
            }
            if let warn = step.blockedWarning, !warn.isEmpty {
                extras.append("⚠️ \(warn)")
            } else if let m = step.message, !m.isEmpty {
                extras.append(m)
            }
            let msg = extras.isEmpty ? "" : " — " + extras.joined(separator: " | ")
            var status = step.skipped == true ? "skipped" : (step.success ? "ok" : "error")
            if let code = step.errorCode, !code.isEmpty {
                status += " [\(code)]"
            }
            let target = step.resolvedElementId.flatMap { $0.isEmpty ? nil : " → \($0)" } ?? ""
            print(String(
                format: "  #%d [%@] %@ via %@ (%.2f ms)%@%@",
                step.index,
                step.action.rawValue,
                status,
                step.mechanism,
                step.latencyMs,
                target,
                msg
            ))
            let warning = step.warning.flatMap { $0.isEmpty ? nil : $0 }
            if step.effect == ActionEffect.none {
                print("     ⚠ no visible effect\(warning.map { ": \($0)" } ?? ""). Observe before continuing.")
            } else if let warning {
                print("     ⚠ \(warning)")
            }
        }
        if let code = firstFailureCode(result), let hint = UseMacErrorGuide.hint(for: code) {
            print("Next: \(hint)")
        }
        if let dialogs = result.dialogs, !dialogs.isEmpty {
            print("Dialogs (\(dialogs.count)):")
            for dialog in dialogs {
                print("  [\(dialog.type)] \(dialog.message.debugDescription) -> \(dialog.accepted ? "accepted" : "dismissed")")
            }
        }
        if let netErrors = result.networkErrors, !netErrors.isEmpty {
            print("NetworkErrors (\(netErrors.count)):")
            for err in netErrors.prefix(10) {
                print("  ! \(err)")
            }
        }
        if let rect = result.dirtyRect {
            print(String(format: "DirtyRect: (%.0f,%.0f %.0fx%.0f)", rect.x, rect.y, rect.width, rect.height))
        }
        if let deltaOCR = result.visualDeltaOCR, !deltaOCR.isEmpty {
            print("VisualDeltaOCR: \(deltaOCR)")
        }
        if let verification = result.visualVerification {
            print("")
            let badge = verification.verified == true ? "PASS" : (verification.verified == false ? "FAIL" : "INFO")
            print(String(
                format: "Local Visual Verification [%@ via %@, %.0f ms]: %@",
                badge,
                verification.backend,
                verification.latencyMs,
                verification.answer
            ))
        }
        if let feedback = result.agentFeedback {
            print("")
            print(feedback.formattedBanner)
        }
        if let shot = result.screenshot {
            print("")
            print(String(format: "Screenshot: %@ (%dx%d, %d bytes)", shot.path, shot.width, shot.height, shot.byteCount))
        }
        if let obs = result.observation {
            print("")
            let effectiveDiffOnly = returnDiffOnly || (obs.elements.isEmpty && obs.diff != nil)
            print(obs.formattedCompactSummary(maxElements: maxElements ?? 250, returnDiffOnly: effectiveDiffOnly))
        }
    }

    static func handleVision(args: [String], options: GlobalOptions) async throws -> Int32 {
        guard let sub = args.first else {
            throw CLIError.usage("Usage: usemac vision <status|ask|verify|describe|locate|diagnose|ocr> ...")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "status":
            let req = RPCRequest(method: .visionStatus)
            let (res, rttMs, mode) = try await executeRPC(req, options: options)
            try ensureOK(res)
            if options.json {
                if let vs = res.visionStatus {
                    printEncodableJSON(vs)
                    return 0
                }
                printEncodableJSON(res)
                return 0
            }
            guard let vs = res.visionStatus else {
                throw CLIError.rpcFailure(code: "empty_vision_status", message: "Empty vision status response.")
            }
            print(String(format: "[%@] Local Vision: %@ | backend=%@ | enabled=%@ | rtt=%.2f ms", mode.rawValue, vs.state, vs.backend, vs.enabled ? "yes" : "no", rttMs))
            print("Apple Vision OCR: \(vs.ocrAvailable ? "ok" : "unavailable")")
            if let err = vs.lastError, !err.isEmpty {
                print("Last error: \(err)")
            }
            return 0

        case "ask", "verify", "describe", "locate", "diagnose", "ocr":
            let parsed = try parseAppAndExtras(
                args: rest,
                valueFlags: ["--profile", "--tab", "--app", "--image", "--prompt", "--selector", "--element"]
            )
            let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
            let queryText = parsed.values["--prompt"] ?? (parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "))
            let params = VisionQueryParams(
                mode: sub,
                query: queryText,
                profile: parsed.values["--profile"],
                tabId: tabId,
                app: parsed.values["--app"],
                imagePath: parsed.values["--image"],
                selector: parsed.values["--selector"],
                elementId: parsed.values["--element"]
            )
            let req = RPCRequest(method: .visionQuery, visionQuery: params)
            let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 90_000)
            try ensureOK(res)
            if options.json {
                if let vr = res.visionResult {
                    printEncodableJSON(vr)
                    return 0
                }
                printEncodableJSON(res)
                return 0
            }
            guard let vr = res.visionResult else {
                throw CLIError.rpcFailure(code: "empty_vision_result", message: "Response missing VisionQueryResult.")
            }
            let modelTag = vr.modelId.map { " (\($0))" } ?? ""
            print(String(format: "[%@] Vision %@ [%@%@] | inference: %.1f ms | rtt: %.1f ms", mode.rawValue, vr.mode, vr.backend, modelTag, vr.latencyMs, rttMs))
            print("Answer: \(vr.answer)")
            if let verified = vr.verified {
                print("Verified: \(verified ? "YES" : "NO")")
            }
            if let x = vr.x, let y = vr.y {
                print(String(format: "Point: (%.1f, %.1f)", x, y))
            }
            if vr.blockingDetected {
                print("Blocking overlay detected: YES")
            }
            if let img = vr.imagePath {
                print("Image: \(img)")
            }
            if !vr.detections.isEmpty {
                for det in vr.detections.prefix(20) {
                    print(String(format: "  - \"%@\" (%.1f, %.1f) [%@]", det.label, det.x, det.y, det.source))
                }
            }
            return 0

        case "help":
            return try printHelp(for: ["vision"] + rest.prefix(1))
        default:
            throw CLIError.usage("Unknown vision subcommand: '\(sub)'. Use: status, ask, verify, describe, locate, diagnose, or ocr.")
        }
    }

    static func handleTaskStart(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--app", "--summary", "--agent"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let summary = parsed.values["--summary"] ?? (parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "))
        let params = TaskStartParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            app: parsed.values["--app"],
            summary: summary,
            taskId: options.taskFlag,
            agent: parsed.values["--agent"] ?? options.agentName
        )
        let req = RPCRequest(method: .taskStart, taskStart: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)
        if options.json {
            printEncodableJSON(res)
            return 0
        }
        print(String(format: "[%@] Session started (%@) | rtt: %.2f ms", mode.rawValue, summary ?? "Working…", rttMs))
        if let taskId = res.taskId {
            print("taskId: \(taskId)  (pass --task \(taskId) to every command, or export USEMAC_TASK=\(taskId): your requests without --tab then go to this task's own last tab, and 'done' only closes this task's tabs)")
        }
        return 0
    }

    static func handleTaskComplete(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--app", "--summary", "--keep-tab"],
            boolFlags: ["--keep-tabs"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let summary = parsed.values["--summary"] ?? (parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "))
        var keepTabIds: [Int]?
        if let raw = parsed.values["--keep-tab"] {
            let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !ids.isEmpty, ids.allSatisfy({ Int($0) != nil }) else {
                throw CLIError.usage("--keep-tab expects tab ids separated by commas, e.g. --keep-tab 123,456.")
            }
            keepTabIds = ids.compactMap { Int($0) }
        }
        let params = TaskCompleteParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            app: parsed.values["--app"],
            summary: summary,
            keepTabs: parsed.flags.contains("--keep-tabs") ? true : nil,
            keepTabIds: keepTabIds,
            taskId: options.taskId
        )
        let req = RPCRequest(method: .taskComplete, taskComplete: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)
        if options.json {
            printEncodableJSON(res)
            return 0
        }
        print(String(format: "[%@] Task marked as complete (%@) | rtt: %.2f ms", mode.rawValue, summary ?? "Task completed", rttMs))
        if let done = res.taskSummary {
            let tabs = { (ids: [Int]) in ids.isEmpty ? "none" : ids.map(String.init).joined(separator: ",") }
            print("Task \(done.taskId): \(done.requests) requests, \(done.actions) actions (\(done.failedActions) failed), \(done.blocked) blocked, "
                + String(format: "%.1f s", Double(done.durationMs) / 1000)
                + " | tabs opened: \(tabs(done.tabsOpened)), closed: \(tabs(done.tabsClosed)), closing now: \(tabs(done.tabsClosing))")
        }
        return 0
    }

    static func handleAudit(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--limit", "--since", "--task"])
        if let extra = parsed.positionals.first {
            throw CLIError.usage("Unexpected argument '\(extra)'. Run 'usemac help audit'.")
        }
        let limit = try parseOptionalInt(parsed.values, flag: "--limit", positive: true)
        var sinceMs: Int64?
        if let rawSince = parsed.values["--since"] {
            guard let parsedSince = AuditLogParams.parseSince(rawSince) else {
                throw CLIError.usage("--since expects a duration (30m, 2h, 7d), a date (2026-11-25 or ISO 8601) or milliseconds since 1970.")
            }
            sinceMs = parsedSince
        }
        // The global option parser takes `--task` before this command sees it, so read it from there too.
        let taskId = parsed.values["--task"] ?? options.taskFlag
        let filtered = limit != nil || sinceMs != nil || taskId != nil
        let req = RPCRequest(
            method: .auditLog,
            auditLog: filtered ? AuditLogParams(limit: limit, sinceMs: sinceMs, taskId: taskId) : nil
        )
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)
        let entries = res.auditEntries ?? []
        if options.json {
            printEncodableJSON(entries)
            return 0
        }
        print(String(format: "[%@] %d audit entr%@, newest first (%.2f ms):", mode.rawValue, entries.count, entries.count == 1 ? "y" : "ies", rttMs))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for entry in entries {
            let time = formatter.string(from: Date(timeIntervalSince1970: Double(entry.timestampMs) / 1000))
            let result = entry.success ? "ok    " : "FAILED"
            let task = entry.taskId.map { " [\($0)]" } ?? ""
            print("  \(time)  \(result)  \(entry.method)  \(entry.targetApp ?? "-")\(task)  \(entry.summary)")
        }
        return 0
    }

    static func handleReport(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--summary", "--title"])
        let summary = parsed.values["--summary"] ?? (parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "))
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("report needs --summary \"<what you tried, what you expected, what happened>\". Run 'usemac help report'.")
        }
        let req = RPCRequest(
            method: .reportPrepare,
            reportPrepare: ReportPrepareParams(summary: summary, title: parsed.values["--title"], taskId: options.taskId)
        )
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)
        guard let receipt = res.problemReport else {
            throw CLIError.rpcFailure(code: "INTERNAL", message: "Response missing problemReport.")
        }
        if options.json {
            printEncodableJSON(receipt)
            return 0
        }
        let scope = receipt.taskId.map { "task \($0)" } ?? "recent activity"
        let codes = receipt.errorCodes.isEmpty ? "no error codes" : receipt.errorCodes.joined(separator: ", ")
        print(String(format: "[%@] Report %@ (%@, %d audit entr%@, %@) | rtt: %.2f ms", mode.rawValue, receipt.status, scope, receipt.entryCount, receipt.entryCount == 1 ? "y" : "ies", codes, rttMs))
        print(receipt.message)
        return 0
    }

    static func handleDebug(args: [String], options: GlobalOptions) async throws -> Int32 {
        switch args.first {
        case "capture":
            return try await handleDebugCapture(args: Array(args.dropFirst()), options: options)
        case "help":
            return try printHelp(for: ["debug"] + args.dropFirst().prefix(1))
        case nil:
            throw CLIError.usage("Usage: usemac debug capture [--window <kinds>] [--frames <n>] [--interval <ms>] [--context] [--out <dir>]")
        case let other?:
            throw CLIError.usage("Unknown debug subcommand: '\(other)'. Use: capture.")
        }
    }

    /// `debug capture`: PNGs of UseMac's own windows, for developing UseMac. Needs the user to turn on Debug capture.
    private static func handleDebugCapture(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--window", "--frames", "--interval", "--margin", "--out"],
            boolFlags: ["--context"]
        )
        if let extra = parsed.positionals.first {
            throw CLIError.usage("Unexpected argument '\(extra)'. Run 'usemac help debug capture'.")
        }
        let params = DebugCaptureParams(
            window: parsed.values["--window"],
            frames: try parseOptionalInt(parsed.values, flag: "--frames", positive: true),
            intervalMs: try parseOptionalInt(parsed.values, flag: "--interval", positive: true),
            context: parsed.flags.contains("--context") ? true : nil,
            contextMargin: try parseOptionalInt(parsed.values, flag: "--margin")
        )
        let resolved: DebugCaptureOptions
        do {
            resolved = try params.resolved()
        } catch let invalid as DebugCaptureParams.InvalidWindow {
            throw CLIError.usage(invalid.message)
        }

        let req = RPCRequest(method: .debugCapture, debugCapture: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: resolved.clientTimeoutMs)
        try ensureOK(res)
        guard var result = res.debugCapture else {
            throw CLIError.rpcFailure(code: "INTERNAL", message: "Response missing debugCapture.")
        }
        if let out = parsed.values["--out"] {
            do {
                result = try result.copied(to: out)
            } catch {
                throw CLIError.rpcFailure(code: "INTERNAL", message: "Couldn't copy the PNGs to \(out): \(error.localizedDescription). They are still in \(result.directory).")
            }
        }

        if options.json {
            printEncodableJSON(result)
            return 0
        }
        let frames = result.frames == 1 ? "1 frame" : "\(result.frames) frames, \(result.intervalMs) ms apart"
        print(String(format: "[%@] Debug capture: %d PNG(s) of %@ (%@) in %@ | %.0f ms | rtt: %.2f ms", mode.rawValue, result.images.count, result.window, frames, result.directory, result.latencyMs, rttMs))
        for image in result.images {
            let f = image.frame
            let title = image.title.map { $0.isEmpty ? "" : " \"\($0)\"" } ?? ""
            let window = image.windowId.map { " window \($0)\(title)" } ?? ""
            print(String(
                format: "  #%d +%.0f ms  %@%@  frame (%.0f, %.0f, %.0f×%.0f)  %d×%d px  %@",
                image.frameIndex, image.offsetMs, image.kind, window, f.x, f.y, f.width, f.height, image.width, image.height, image.path
            ))
        }
        if !result.notes.isEmpty {
            print("Notes: \(result.notes.joined(separator: "; "))")
        }
        return 0
    }

    static func handleSkill(args: [String], options: GlobalOptions) async throws -> Int32 {
        guard let sub = args.first else {
            throw CLIError.usage("Usage: usemac skill <list|save|run|delete> ...")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            let parsed = try parseAppAndExtras(
                args: rest,
                valueFlags: ["--query", "--kind", "--target", "--app", "--url"]
            )
            let params = SkillListParams(
                query: parsed.values["--query"] ?? parsed.positionals.first,
                target: parsed.values["--kind"] ?? parsed.values["--target"],
                app: parsed.values["--app"],
                url: parsed.values["--url"]
            )
            let req = RPCRequest(method: .skillList, skillList: params)
            let (res, rttMs, mode) = try await executeRPC(req, options: options)
            try ensureOK(res)
            if options.json {
                if let skills = res.skills { printEncodableJSON(skills); return 0 }
                printEncodableJSON(res)
                return 0
            }
            let skills = res.skills?.skills ?? []
            print(String(format: "[%@] %d skill(s) (%.2f ms):", mode.rawValue, skills.count, rttMs))
            for s in skills {
                let target = s.target ?? "auto"
                let paramsStr = (s.params?.isEmpty == false) ? " params=[\(s.params!.joined(separator: ","))]" : ""
                let desc = s.description.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
                print("  • \(s.name) [\(target)] | \(s.steps.count) steps | runs=\(s.runCount)\(paramsStr)\(desc)")
            }
            return 0

        case "delete":
            let parsed = try parseAppAndExtras(args: rest, valueFlags: [], boolFlags: [])
            guard let name = parsed.positionals.first, !name.isEmpty else {
                throw CLIError.usage("Usage: usemac skill delete <name>")
            }
            let req = RPCRequest(method: .skillSave, skillSave: SkillSaveParams(name: name, delete: true))
            let (res, rttMs, mode) = try await executeRPC(req, options: options)
            try ensureOK(res)
            if options.json {
                printEncodableJSON(res)
                return 0
            }
            print(String(format: "[%@] Deleted skill '%@' (%.2f ms)", mode.rawValue, name, rttMs))
            return 0

        case "save":
            let parsed = try parseAppAndExtras(
                args: rest,
                valueFlags: ["--description", "--kind", "--target", "--app", "--url-pattern"],
                boolFlags: ["--delete"]
            )
            let usage = "Usage: usemac skill save <name> '<steps-json>'|- [--description <text>] [--kind browser|native] [--app <name>] [--url-pattern <glob>] [--delete]"
            let deleteFlag = parsed.flags.contains("--delete")
            let params: SkillSaveParams
            if deleteFlag {
                guard let name = parsed.positionals.first, !name.isEmpty else {
                    throw CLIError.usage(usage)
                }
                params = SkillSaveParams(name: name, delete: true)
            } else if parsed.positionals.count == 1,
                      parsed.positionals[0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                guard let data = parsed.positionals[0].data(using: .utf8) else {
                    throw CLIError.invalidJSON("Input is not valid UTF-8.")
                }
                do {
                    params = try JSONDecoder().decode(SkillSaveParams.self, from: data)
                } catch {
                    throw CLIError.invalidJSON(formatDecodingError(error))
                }
            } else {
                guard parsed.positionals.count >= 2 else {
                    throw CLIError.usage(usage)
                }
                let name = parsed.positionals[0]
                let rawSteps: String
                if parsed.positionals[1] == "-" {
                    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
                    guard let text = String(data: stdinData, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CLIError.invalidJSON("Empty stdin input.")
                    }
                    rawSteps = text
                } else {
                    rawSteps = parsed.positionals[1]
                }
                guard let data = rawSteps.data(using: .utf8) else {
                    throw CLIError.invalidJSON("Steps JSON is not valid UTF-8.")
                }
                let steps: [ActionStep]
                do {
                    steps = try JSONDecoder().decode([ActionStep].self, from: data)
                } catch {
                    throw CLIError.invalidJSON(formatDecodingError(error))
                }
                params = SkillSaveParams(
                    name: name,
                    description: parsed.values["--description"],
                    target: parsed.values["--kind"] ?? parsed.values["--target"],
                    app: parsed.values["--app"],
                    urlPattern: parsed.values["--url-pattern"],
                    steps: steps
                )
            }
            let req = RPCRequest(method: .skillSave, skillSave: params)
            let (res, rttMs, mode) = try await executeRPC(req, options: options)
            try ensureOK(res)
            if options.json {
                if let skills = res.skills { printEncodableJSON(skills); return 0 }
                printEncodableJSON(res)
                return 0
            }
            if deleteFlag {
                print(String(format: "[%@] Deleted skill '%@' (%.2f ms)", mode.rawValue, params.name, rttMs))
            } else if let saved = res.skills?.saved {
                print(String(format: "[%@] Saved skill '%@' (%d steps, %.2f ms)", mode.rawValue, saved.name, saved.steps.count, rttMs))
            } else {
                print(String(format: "[%@] Saved skill '%@' (%.2f ms)", mode.rawValue, params.name, rttMs))
            }
            return 0

        case "run":
            let parsed = try parseAppAndExtras(
                args: rest,
                valueFlags: ["--params", "--app", "--profile", "--tab", "--mode", "--wait-for-lease"],
                boolFlags: ["--diff-only", "--no-observation"]
            )
            guard let name = parsed.positionals.first, !name.isEmpty else {
                throw CLIError.usage("Usage: usemac skill run <name> [--params '{\"k\":\"v\"}'] [--app <name>] [--profile <name>] [--tab <id>] [--mode <m>] [--diff-only]")
            }
            let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
            let obsMode = try parseObservationMode(parsed.values)
            var paramValues: [String: String]?
            if let rawParams = parsed.values["--params"] {
                guard let data = rawParams.data(using: .utf8) else {
                    throw CLIError.invalidJSON("--params is not valid UTF-8.")
                }
                do {
                    paramValues = try JSONDecoder().decode([String: String].self, from: data)
                } catch {
                    throw CLIError.invalidJSON(formatDecodingError(error))
                }
            }
            let diffOnly = parsed.flags.contains("--diff-only")
            let params = SkillRunParams(
                name: name,
                params: paramValues,
                app: parsed.values["--app"],
                profile: parsed.values["--profile"],
                tabId: tabId,
                returnObservation: parsed.flags.contains("--no-observation") ? false : nil,
                returnDiffOnly: diffOnly ? true : nil,
                observationMode: obsMode,
                waitForLeaseMs: try parseOptionalInt(parsed.values, flag: "--wait-for-lease")
            )
            let req = RPCRequest(method: .skillRun, skillRun: params)
            let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 60_000)
            try ensureOK(res)
            if options.json {
                if let sr = res.skillResult {
                    printEncodableJSON(sr)
                    return sr.success ? 0 : (sr.actionResult.map(exitCode(for:)) ?? 1)
                }
                printEncodableJSON(res)
                return 0
            }
            guard let sr = res.skillResult else {
                throw CLIError.rpcFailure(code: "empty_skill_result", message: "Response missing SkillRunResult.")
            }
            let msg = sr.message.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            print(String(format: "[%@] Skill '%@' %@ (%.1f ms, rtt=%.1f ms)%@", mode.rawValue, sr.name, sr.success ? "OK" : "FAILED", sr.totalLatencyMs, rttMs, msg))
            if let actionResult = sr.actionResult {
                printBatchActionResult(actionResult, rttMs: rttMs, mode: mode, returnDiffOnly: diffOnly || obsMode == .delta)
                return exitCode(for: actionResult)
            }
            return sr.success ? 0 : 1

        case "help":
            return try printHelp(for: ["skill"] + rest.prefix(1))
        default:
            throw CLIError.usage("Unknown skill subcommand: '\(sub)'. Use: list, save, run, delete.")
        }
    }

    static func handleScreenshot(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--app", "--max-dim"],
            boolFlags: ["--base64", "--diff-crop"]
        )

        let maxDim = try parseOptionalInt(parsed.values, flag: "--max-dim", positive: true) ?? 1280

        let includeBase64 = parsed.flags.contains("--base64")
        let req = RPCRequest(
            method: .screenshot,
            screenshot: ScreenshotRequest(
                app: parsed.values["--app"],
                maxDimension: maxDim,
                quality: 0.78,
                includeBase64: includeBase64,
                diffCrop: parsed.flags.contains("--diff-crop") ? true : nil
            )
        )
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
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

        print(String(
            format: "[%@] Screenshot: %@ | %dx%d | %d bytes | capture: %.2f ms | rtt: %.2f ms",
            mode.rawValue,
            shot.path,
            shot.width,
            shot.height,
            shot.byteCount,
            shot.latencyMs,
            rttMs
        ))
        if includeBase64, let b64 = shot.base64Data {
            print("base64 (\(b64.count) chars): \(b64)")
        }
        return 0
    }

    static func handleServe(options: GlobalOptions) async throws -> Int32 {
        let service = UseMacEngineService(socketPath: options.socketPath, auditStore: AuditLogStore())
        let server = UnixSocketServer(socketPath: options.socketPath, service: service, onClientCountChange: nil)
        try server.start()

        print("READY socket=\(options.socketPath) pid=\(getpid())")
        fflush(stdout)

        let gate = SignalGate()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigIntSource.setEventHandler { gate.trigger() }
        sigTermSource.setEventHandler { gate.trigger() }
        sigIntSource.resume()
        sigTermSource.resume()

        await gate.wait()

        sigIntSource.cancel()
        sigTermSource.cancel()
        server.stop()
        return 0
    }

    static func handleMCP(options: GlobalOptions) async -> Int32 {
        let fallback: UseMacServiceProtocol?
        if options.standalone {
            fallback = UseMacEngineService(socketPath: options.socketPath)
        } else if options.requireDaemon {
            fallback = nil
        } else {
            fallback = ReadOnlyFallbackService(socketPath: options.socketPath)
        }
        let mcp = MCPStdioServer(socketPath: options.socketPath, fallbackService: fallback)
        await mcp.runStdioLoop()
        return 0
    }
}
