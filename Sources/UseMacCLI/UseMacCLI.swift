import Foundation
import Darwin
import Dispatch
import MachO
import UseMacProtocol
import UseMacEngine
import UseMacIPC

@main
struct UseMacCLI {
    static func main() async {
        let exitCode = await run(arguments: Array(CommandLine.arguments.dropFirst()))
        if exitCode != 0 {
            exit(exitCode)
        }
    }

    // MARK: - Types

    private enum ExecutionMode: String {
        case daemon
        case inProcess = "in-process"
    }

    private struct GlobalOptions {
        var socketPath: String = UseMacDefaults.defaultSocketPath
        var json: Bool = false
        var standalone: Bool = false
        var requireDaemon: Bool = false
    }

    private enum CLIError: Error {
        case usage(String)
        case daemonRequired(String)
        case invalidJSON(String)
        case rpcFailure(code: String, message: String)
    }

    private struct CLIErrorEnvelope: Encodable {
        struct ErrorBody: Encodable {
            let code: String
            let message: String
        }

        let ok: Bool = false
        let error: ErrorBody
    }

    private struct InstallSkillTargetResult: Encodable {
        let path: String
        let status: String
    }

    private struct InstallSkillOutput: Encodable {
        let ok: Bool
        let binary: String
        let targets: [InstallSkillTargetResult]
    }

    private final class ReadOnlyFallbackService: UseMacServiceProtocol {
        private let engine: UseMacEngineService

        init(socketPath: String) {
            self.engine = UseMacEngineService(socketPath: socketPath)
        }

        func handle(_ request: RPCRequest) async -> RPCResponse {
            if UseMacCLI.isActionMethod(request.method) {
                return RPCResponse.failure(
                    id: request.id,
                    code: "DAEMON_REQUIRED",
                    message: "The UseMac app is not running, so actions are disabled. Open UseMac and try again."
                )
            }
            return await engine.handle(request)
        }
    }

    private final class SignalGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var fired = false

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if fired {
                    lock.unlock()
                    cont.resume()
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }

        func trigger() {
            lock.lock()
            fired = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume()
        }
    }

    private static let actionMethods: Set<RPCMethod> = [
        .act,
        .browserAct,
        .browserOpen,
        .visionInstall,
        .setPolicy,
        .pairApp
    ]

    private static let policyBlockCodes: Set<String> = [
        "POLICY_BLOCKED",
        "POLICY_LOCKED",
        "URL_BLOCKED",
        "UPLOAD_BLOCKED"
    ]

    private static let batchActionAllowedKeys: [String] = [
        "app",
        "includeScreenshot",
        "returnDiffOnly",
        "returnObservation",
        "steps",
        "stopOnError"
    ]

    private static let browserActAllowedKeys: [String] = [
        "profile",
        "readOnly",
        "returnDiffOnly",
        "returnImageContent",
        "returnObservation",
        "steps",
        "stopOnError",
        "tabId",
        "verify"
    ]

    private static func isActionMethod(_ method: RPCMethod) -> Bool {
        actionMethods.contains(method)
    }

    // MARK: - Dispatch

    private static func run(arguments: [String]) async -> Int32 {
        var options = GlobalOptions()
        do {
            let positionalAndSubFlags = try extractGlobalOptions(from: arguments, into: &options)
            guard let command = positionalAndSubFlags.first else {
                printUsage()
                return 0
            }

            let rest = Array(positionalAndSubFlags.dropFirst())

            switch command {
            case "help", "--help", "-h":
                printUsage()
                return 0
            case "--version", "-v", "version":
                print(UseMacDefaults.version)
                return 0
            case "ping":
                return try await handlePing(options: options)
            case "status":
                return try await handleStatus(options: options)
            case "apps":
                return try await handleApps(options: options)
            case "observe":
                return try await handleObserve(args: rest, options: options)
            case "act":
                return try await handleAct(args: rest, options: options)
            case "click":
                return try await handleClick(args: rest, options: options)
            case "set":
                return try await handleSet(args: rest, options: options)
            case "type":
                return try await handleType(args: rest, options: options)
            case "key":
                return try await handleKey(args: rest, options: options)
            case "screenshot":
                return try await handleScreenshot(args: rest, options: options)
            case "browser":
                return try await handleBrowser(args: rest, options: options)
            case "vision":
                return try await handleVision(args: rest, options: options)
            case "start":
                return try await handleTaskStart(args: rest, options: options)
            case "done", "complete", "stop":
                return try await handleTaskComplete(args: rest, options: options)
            case "serve":
                return try await handleServe(options: options)
            case "mcp":
                return await handleMCP(options: options)
            case "install-skill", "skill":
                return try handleInstallSkill(args: rest, options: options)
            case "bench":
                return try await handleBench(args: rest, options: options)
            default:
                throw CLIError.usage("Unknown command: '\(command)'. Run 'usemac --help' to see available commands.")
            }
        } catch let error as CLIError {
            return emitCLIError(error, json: options.json)
        } catch {
            return emitUnexpectedError(error, json: options.json)
        }
    }

    private static func emitCLIError(_ error: CLIError, json: Bool) -> Int32 {
        let exitCode: Int32
        let code: String
        let message: String
        let includeCodeInText: Bool

        switch error {
        case .usage(let msg):
            exitCode = 2
            code = "USAGE"
            message = msg
            includeCodeInText = false
        case .invalidJSON(let msg):
            exitCode = 2
            code = "INVALID_JSON"
            message = msg
            includeCodeInText = false
        case .daemonRequired(let msg):
            exitCode = 3
            code = "DAEMON_REQUIRED"
            message = msg
            includeCodeInText = true
        case .rpcFailure(let rpcCode, let rpcMessage):
            if rpcCode == "DAEMON_REQUIRED" {
                exitCode = 3
            } else if policyBlockCodes.contains(rpcCode) {
                exitCode = 4
            } else {
                exitCode = 1
            }
            code = rpcCode
            message = rpcMessage
            includeCodeInText = true
        }

        if json {
            printEncodableJSON(CLIErrorEnvelope(error: .init(code: code, message: message)))
        } else if includeCodeInText {
            writeStderr("Error [\(code)]: \(message)\n")
        } else {
            writeStderr("Error: \(message)\n")
        }
        return exitCode
    }

    private static func emitUnexpectedError(_ error: Error, json: Bool) -> Int32 {
        let code: String
        let exitCode: Int32
        let includeCodeInText: Bool

        if let socketError = error as? UnixSocketClientError {
            switch socketError {
            case .connectionFailed, .socketCreationFailed, .pathTooLong:
                code = "DAEMON_REQUIRED"
                exitCode = 3
                includeCodeInText = true
            default:
                code = "INTERNAL"
                exitCode = 1
                includeCodeInText = false
            }
        } else {
            code = "INTERNAL"
            exitCode = 1
            includeCodeInText = false
        }

        let message = error.localizedDescription
        if json {
            printEncodableJSON(CLIErrorEnvelope(error: .init(code: code, message: message)))
        } else if includeCodeInText {
            writeStderr("Error [\(code)]: \(message)\n")
        } else {
            writeStderr("Error: \(message)\n")
        }
        return exitCode
    }

    // MARK: - Argument Parsing

    private static func extractGlobalOptions(from args: [String], into options: inout GlobalOptions) throws -> [String] {
        var remaining: [String] = []
        var i = 0
        var literalMode = false

        while i < args.count {
            let arg = args[i]
            if literalMode {
                remaining.append(arg)
                i += 1
                continue
            }

            switch arg {
            case "--":
                literalMode = true
                i += 1
            case "--socket":
                guard i + 1 < args.count else {
                    throw CLIError.usage("Missing path after --socket.")
                }
                options.socketPath = args[i + 1]
                i += 2
            case "--json":
                options.json = true
                i += 1
            case "--standalone":
                options.standalone = true
                i += 1
            case "--require-daemon":
                options.requireDaemon = true
                i += 1
            default:
                if arg.hasPrefix("--socket=") {
                    options.socketPath = String(arg.dropFirst("--socket=".count))
                    i += 1
                } else {
                    remaining.append(arg)
                    i += 1
                }
            }
        }

        return remaining
    }

    private static func parseAppAndExtras(
        args: [String],
        valueFlags: Set<String> = ["--app"],
        boolFlags: Set<String> = []
    ) throws -> (values: [String: String], flags: Set<String>, positionals: [String]) {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var i = 0

        while i < args.count {
            let arg = args[i]
            if valueFlags.contains(arg) {
                guard i + 1 < args.count else {
                    throw CLIError.usage("Missing value after \(arg).")
                }
                values[arg] = args[i + 1]
                i += 2
            } else if let eqIndex = arg.firstIndex(of: "="), valueFlags.contains(String(arg[..<eqIndex])) {
                let key = String(arg[..<eqIndex])
                let val = String(arg[arg.index(after: eqIndex)...])
                values[key] = val
                i += 1
            } else if boolFlags.contains(arg) {
                flags.insert(arg)
                i += 1
            } else if arg.hasPrefix("--") {
                throw CLIError.usage("Unknown flag: \(arg)")
            } else {
                positionals.append(arg)
                i += 1
            }
        }

        return (values, flags, positionals)
    }

    private static func parseOptionalInt(
        _ values: [String: String],
        flag: String,
        positive: Bool = false
    ) throws -> Int? {
        guard let raw = values[flag] else { return nil }
        guard let value = Int(raw) else {
            throw CLIError.usage("\(flag) expects an integer.")
        }
        if positive && value <= 0 {
            throw CLIError.usage("\(flag) expects a positive integer.")
        }
        return value
    }

    private static func parseOptionalDouble(
        _ values: [String: String],
        flag: String,
        positive: Bool = false
    ) throws -> Double? {
        guard let raw = values[flag] else { return nil }
        guard let value = Double(raw), value.isFinite else {
            throw CLIError.usage("\(flag) expects a number.")
        }
        if positive && value <= 0 {
            throw CLIError.usage("\(flag) expects a positive number.")
        }
        return value
    }

    // MARK: - RPC Execution

    private static func executeRPC(
        _ request: RPCRequest,
        options: GlobalOptions,
        timeoutMs: Int = 10000
    ) async throws -> (response: RPCResponse, roundTripMs: Double, mode: ExecutionMode) {
        if options.standalone {
            if isActionMethod(request.method) {
                writeStderr("Warning: running without the UseMac app. The Kill Switch and execution mode do not apply.\n")
            }
            let service = UseMacEngineService(socketPath: options.socketPath)
            let start = DispatchTime.now().uptimeNanoseconds
            let response = await service.handle(request)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            return (response, elapsedMs, .inProcess)
        }

        let client = UnixSocketClient(socketPath: options.socketPath, timeoutMs: timeoutMs, keepAlive: false)
        if client.isDaemonReachable() {
            defer { client.close() }
            let (response, rttMs) = try client.send(request)
            return (response, rttMs, .daemon)
        }

        if options.requireDaemon {
            throw CLIError.daemonRequired("The UseMac daemon is not reachable at \(options.socketPath) (--require-daemon is set).")
        }

        if isActionMethod(request.method) {
            throw CLIError.daemonRequired("The UseMac app is not running, so actions are disabled. Open UseMac, or pass --standalone to run this command without the app's safety controls.")
        }

        let service = UseMacEngineService(socketPath: options.socketPath)
        let start = DispatchTime.now().uptimeNanoseconds
        let response = await service.handle(request)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return (response, elapsedMs, .inProcess)
    }

    // MARK: - Commands

    private static func handlePing(options: GlobalOptions) async throws -> Int32 {
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

    private static func handleStatus(options: GlobalOptions) async throws -> Int32 {
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

    private static func handleApps(options: GlobalOptions) async throws -> Int32 {
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

    private static func handleObserve(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--app", "--max-depth", "--max-elements"],
            boolFlags: ["--no-cache", "--diff", "--no-diff", "--screenshot"]
        )

        let maxDepth = try parseOptionalInt(parsed.values, flag: "--max-depth", positive: true)
        let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        let useCache = !parsed.flags.contains("--no-cache")
        let includeDiff = parsed.flags.contains("--diff") || !parsed.flags.contains("--no-diff")
        let includeScreenshot = parsed.flags.contains("--screenshot")

        let params = ObserveParams(
            app: parsed.values["--app"],
            maxDepth: maxDepth,
            maxElements: maxElements,
            useCache: useCache,
            includeDiff: includeDiff,
            includeScreenshot: includeScreenshot
        )
        let req = RPCRequest(method: .observe, observe: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
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

        print(String(format: "[%@] RTT: %.2f ms", mode.rawValue, rttMs))
        print(snapshot.formattedCompactSummary())
        return 0
    }

    private static func handleAct(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--app"])
        guard let rawInput = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac act '<json>' [--app <name>]")
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

        return try await sendBatchAction(batch, options: options)
    }

    private static func handleClick(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--app"])
        guard let elementId = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac click <@eID> [--app <name>]")
        }
        let app = parsed.values["--app"]
        let batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .click, app: app, elementId: elementId)]
        )
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleSet(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--app"])
        guard parsed.positionals.count >= 2 else {
            throw CLIError.usage("Usage: usemac set <@eID> <text> [--app <name>]")
        }
        let elementId = parsed.positionals[0]
        let text = parsed.positionals.dropFirst().joined(separator: " ")
        let app = parsed.values["--app"]
        let batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .setValue, app: app, elementId: elementId, text: text)]
        )
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleType(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--app"])
        guard !parsed.positionals.isEmpty else {
            throw CLIError.usage("Usage: usemac type <text> [--app <name>]")
        }
        let text = parsed.positionals.joined(separator: " ")
        let app = parsed.values["--app"]
        let batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .type, app: app, text: text)]
        )
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleKey(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--app"])
        guard let chord = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac key <chord> [--app <name>]")
        }
        let (modifiers, key) = parseKeyChord(chord)
        let app = parsed.values["--app"]
        let batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .pressKey, app: app, key: key, modifiers: modifiers.isEmpty ? nil : modifiers)]
        )
        return try await sendBatchAction(batch, options: options)
    }

    private static func sendBatchAction(_ batch: BatchActionRequest, options: GlobalOptions) async throws -> Int32 {
        let req = RPCRequest(method: .act, act: batch)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)

        if options.json {
            if let actionResult = res.actionResult {
                printEncodableJSON(actionResult)
                return actionResult.success ? 0 : 1
            }
            printEncodableJSON(res)
            return 0
        }

        guard let result = res.actionResult else {
            throw CLIError.rpcFailure(code: "empty_action_result", message: "Response missing BatchActionResult.")
        }

        printBatchActionResult(result, rttMs: rttMs, mode: mode)
        return result.success ? 0 : 1
    }

    private static func printBatchActionResult(
        _ result: BatchActionResult,
        rttMs: Double,
        mode: ExecutionMode,
        headerDetail: String? = nil
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
            if let d = step.scrollDeltaY {
                extras.append(String(format: "scrollDeltaY=%.0fpx", d))
            }
            if let v = step.visualChangePercent {
                extras.append(String(format: "visualDiff=%.2f%%", v))
            }
            if let warn = step.blockedWarning, !warn.isEmpty {
                extras.append("⚠️ \(warn)")
            } else if let m = step.message, !m.isEmpty {
                extras.append(m)
            }
            let msg = extras.isEmpty ? "" : " — " + extras.joined(separator: " | ")
            print(String(
                format: "  #%d [%@] %@ via %@ (%.2f ms)%@",
                step.index,
                step.action.rawValue,
                step.success ? "ok" : "error",
                step.mechanism,
                step.latencyMs,
                msg
            ))
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
            print(obs.formattedCompactSummary())
        }
    }

    private static func handleBrowser(args: [String], options: GlobalOptions) async throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: usemac browser <status|tabs|open|observe|extract|screenshot|act> ...")
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
        case "screenshot":
            return try await handleBrowserScreenshot(args: rest, options: options)
        case "act":
            return try await handleBrowserAct(args: rest, options: options)
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            throw CLIError.usage("Unknown browser subcommand: '\(subcommand)'. Use: status, tabs, open, observe, extract, screenshot, act.")
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
                print("  • \(profile.profileName)\(emailPart) | v\(profile.extensionVersion) | tabs=\(profile.tabCount)\(streamPart)")
            }
        }
        return 0
    }

    private static func handleBrowserOpen(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab"],
            boolFlags: ["--same-tab", "--new-tab", "--no-stream"]
        )
        guard let url = parsed.positionals.first, !url.isEmpty else {
            throw CLIError.usage("Usage: usemac browser open <url> [--profile <name>] [--tab <id>] [--same-tab] [--no-stream]")
        }
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let openNewTab: Bool = {
            if parsed.flags.contains("--same-tab") { return false }
            if parsed.flags.contains("--new-tab") { return true }
            return tabId == nil
        }()
        let params = BrowserOpenParams(
            url: url,
            profile: parsed.values["--profile"],
            tabId: tabId,
            newTab: openNewTab,
            stream: !parsed.flags.contains("--no-stream")
        )
        let req = RPCRequest(method: .browserOpen, browserOpen: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 20000)
        try ensureOK(res)

        if options.json {
            printEncodableJSON(res)
            return 0
        }

        let tabStr = res.browserTabId.map { "tab=\($0)" } ?? "tab=?"
        let resolvedUrl = res.browserUrl ?? url
        let titlePart = res.browserTitle.map { " — \"\($0)\"" } ?? ""
        print(String(format: "[%@] Chrome opened (%@): %@%@ (%.2f ms)", mode.rawValue, tabStr, resolvedUrl, titlePart, rttMs))
        if let snapshot = res.snapshot {
            print("")
            print(snapshot.formattedCompactSummary())
        }
        return 0
    }

    private static func handleBrowserObserve(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--max-elements", "--width", "--height", "--scale"],
            boolFlags: ["--screenshot", "--no-text", "--no-tables"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        let vpWidth = try parseOptionalInt(parsed.values, flag: "--width", positive: true)
        let vpHeight = try parseOptionalInt(parsed.values, flag: "--height", positive: true)
        let scale = try parseOptionalDouble(parsed.values, flag: "--scale", positive: true)

        let params = BrowserObserveParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            maxElements: maxElements,
            includeText: !parsed.flags.contains("--no-text"),
            includeTables: !parsed.flags.contains("--no-tables"),
            includeScreenshot: parsed.flags.contains("--screenshot"),
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
        print(snapshot.formattedCompactSummary())
        return 0
    }

    private static func handleBrowserExtract(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--selector", "--expr", "--max-chars"],
            boolFlags: ["--scan-horizontal"]
        )
        let extractMode = parsed.positionals.first ?? "auto"
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let maxChars = try parseOptionalInt(parsed.values, flag: "--max-chars", positive: true) ?? 16000
        let params = BrowserExtractParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            mode: extractMode,
            selector: parsed.values["--selector"],
            expression: parsed.values["--expr"],
            scanHorizontal: parsed.flags.contains("--scan-horizontal"),
            maxChars: maxChars
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
            print("--- EVAL RESULT ---")
            print(json)
        }
        if let text = ext.text, !text.isEmpty {
            print("--- EXTRACTED TEXT ---")
            print(text)
        }
        if let downloads = ext.downloads {
            print("--- RECENT DOWNLOADS (\(downloads.count)) ---")
            for dl in downloads {
                print("  • [\(dl.state)] \(dl.filename)")
            }
        }
        return 0
    }

    private static func handleBrowserScreenshot(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--selector", "--element", "--width", "--height", "--scale", "--quality"],
            boolFlags: ["--full-page"]
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
            returnImageContent: false
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
        return 0
    }

    private static func handleBrowserAct(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--profile", "--tab", "--verify"], boolFlags: ["--read-only", "--screenshot"])
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")

        guard let rawInput = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac browser act '<steps-or-BrowserActParams-json>' [--profile <name>] [--tab <id>] [--read-only] [--verify \"<condition>\"] [--screenshot]")
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
        let verifyOverride = parsed.values["--verify"]
        var params: BrowserActParams
        if trimmed.hasPrefix("[") {
            do {
                let steps = try decoder.decode([ActionStep].self, from: data)
                params = BrowserActParams(
                    profile: parsed.values["--profile"],
                    tabId: tabId,
                    steps: steps,
                    readOnly: readOnlyFlag ? true : nil,
                    verify: verifyOverride,
                    returnImageContent: screenshotFlag ? true : nil
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
            params = decoded
        }

        let req = RPCRequest(method: .browserAct, browserAct: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 45000)
        try ensureOK(res)

        if options.json {
            if let actionResult = res.actionResult {
                printEncodableJSON(actionResult)
                return actionResult.success ? 0 : 1
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
        printBatchActionResult(result, rttMs: rttMs, mode: mode, headerDetail: headerDetail)
        return result.success ? 0 : 1
    }

    private static func handleVision(args: [String], options: GlobalOptions) async throws -> Int32 {
        guard let sub = args.first else {
            throw CLIError.usage("Usage: usemac vision <status|install|ask|verify|describe|locate|diagnose|ocr> ...")
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
            print("Model: \(vs.modelId) | runtime=\(vs.runtimeInstalled ? "ok" : "not installed") | weights=\(vs.modelDownloaded ? "ok" : "pending") | worker=\(vs.workerRunning ? "running" : "idle") | Apple OCR=ok")
            if let err = vs.lastError, !err.isEmpty {
                print("Last error: \(err)")
            }
            return 0

        case "install":
            let parsed = try parseAppAndExtras(args: rest, valueFlags: ["--model"])
            let params = VisionInstallParams(modelId: parsed.values["--model"], enable: true)
            let req = RPCRequest(method: .visionInstall, visionInstall: params)
            let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 300_000)
            try ensureOK(res)
            if options.json {
                printEncodableJSON(res)
                return 0
            }
            if let vs = res.visionStatus {
                print(String(format: "[%@] Vision install complete (%.1f ms): state=%@ model=%@", mode.rawValue, rttMs, vs.state, vs.modelId))
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

        default:
            throw CLIError.usage("Unknown vision subcommand: '\(sub)'. Use: status, install, ask, verify, describe, locate, diagnose, or ocr.")
        }
    }

    private static func handleTaskStart(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--app", "--summary"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let summary = parsed.values["--summary"] ?? (parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "))
        let params = TaskStartParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            app: parsed.values["--app"],
            summary: summary
        )
        let req = RPCRequest(method: .taskStart, taskStart: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)
        if options.json {
            printEncodableJSON(res)
            return 0
        }
        print(String(format: "[%@] Session started (%@) | rtt: %.2f ms", mode.rawValue, summary ?? "Working…", rttMs))
        return 0
    }

    private static func handleTaskComplete(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab", "--app", "--summary"]
        )
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let summary = parsed.values["--summary"] ?? (parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " "))
        let params = TaskCompleteParams(
            profile: parsed.values["--profile"],
            tabId: tabId,
            app: parsed.values["--app"],
            summary: summary
        )
        let req = RPCRequest(method: .taskComplete, taskComplete: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options)
        try ensureOK(res)
        if options.json {
            printEncodableJSON(res)
            return 0
        }
        print(String(format: "[%@] Task marked as complete (%@) | rtt: %.2f ms", mode.rawValue, summary ?? "Task completed", rttMs))
        return 0
    }

    private static func handleScreenshot(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--app", "--max-dim"],
            boolFlags: ["--base64"]
        )

        let maxDim = try parseOptionalInt(parsed.values, flag: "--max-dim", positive: true) ?? 1280

        let includeBase64 = parsed.flags.contains("--base64")
        let req = RPCRequest(
            method: .screenshot,
            screenshot: ScreenshotRequest(
                app: parsed.values["--app"],
                maxDimension: maxDim,
                quality: 0.78,
                includeBase64: includeBase64
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

    private static func handleServe(options: GlobalOptions) async throws -> Int32 {
        let service = UseMacEngineService(socketPath: options.socketPath)
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

    private static func handleMCP(options: GlobalOptions) async -> Int32 {
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

    private static func handleBench(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--iterations", "--app"])
        let iterations = try parseOptionalInt(parsed.values, flag: "--iterations", positive: true) ?? 100

        let probeClient = UnixSocketClient(socketPath: options.socketPath, timeoutMs: 2000, keepAlive: false)
        let daemonRunning = !options.standalone && probeClient.isDaemonReachable()
        probeClient.close()

        var ephemeralServer: UnixSocketServer?
        let benchSocketPath: String
        let mode: ExecutionMode

        if daemonRunning {
            benchSocketPath = options.socketPath
            mode = .daemon
        } else {
            if options.requireDaemon {
                throw CLIError.daemonRequired("The UseMac daemon is not reachable at \(options.socketPath) (--require-daemon is set).")
            }
            benchSocketPath = "/tmp/usemac-bench-\(getpid()).sock"
            let service = UseMacEngineService(socketPath: benchSocketPath)
            let server = UnixSocketServer(socketPath: benchSocketPath, service: service, onClientCountChange: nil)
            try server.start()
            ephemeralServer = server
            mode = .inProcess
        }

        defer {
            if let server = ephemeralServer {
                server.stop()
                try? FileManager.default.removeItem(atPath: benchSocketPath)
            }
        }

        let client = UnixSocketClient(socketPath: benchSocketPath, timeoutMs: 10000, keepAlive: true)
        defer { client.close() }

        // Warmup connection
        _ = try client.send(RPCRequest(method: .ping))

        // 1. Ping benchmark
        var pingRttsMs: [Double] = []
        pingRttsMs.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let (res, rttMs) = try client.send(RPCRequest(method: .ping))
            if res.ok {
                pingRttsMs.append(rttMs)
            }
        }
        let pingStats = computeStats(pingRttsMs)

        // 2. list_apps benchmark (20 iterations)
        var appsRttsMs: [Double] = []
        appsRttsMs.reserveCapacity(20)
        for _ in 0..<20 {
            let (res, rttMs) = try client.send(RPCRequest(method: .listApps))
            if res.ok {
                appsRttsMs.append(rttMs)
            }
        }
        let appsStats = computeStats(appsRttsMs)

        // 3. Observe benchmark: 1 cold + 20 warm
        let targetApp = parsed.values["--app"]
        var coldObserveMs: Double?
        var coldObserveError: String?
        let coldReq = RPCRequest(
            method: .observe,
            observe: ObserveParams(app: targetApp, useCache: false, includeDiff: false, includeScreenshot: false)
        )
        let (coldRes, coldRtt) = try client.send(coldReq)
        if coldRes.ok {
            coldObserveMs = coldRtt
        } else {
            coldObserveError = coldRes.error?.message ?? "observe failed"
        }

        var warmObserveRttsMs: [Double] = []
        if coldRes.ok {
            warmObserveRttsMs.reserveCapacity(20)
            for _ in 0..<20 {
                let warmReq = RPCRequest(
                    method: .observe,
                    observe: ObserveParams(app: targetApp, useCache: true, includeDiff: true, includeScreenshot: false)
                )
                let (warmRes, warmRtt) = try client.send(warmReq)
                if warmRes.ok {
                    warmObserveRttsMs.append(warmRtt)
                }
            }
        }
        let warmStats = computeStats(warmObserveRttsMs)

        if options.json {
            let payload: [String: Any] = [
                "mode": mode.rawValue,
                "socketPath": benchSocketPath,
                "ping": [
                    "iterations": iterations,
                    "minMs": pingStats.min,
                    "p50Ms": pingStats.p50,
                    "p95Ms": pingStats.p95,
                    "avgMs": pingStats.avg
                ],
                "listApps": [
                    "iterations": 20,
                    "p50Ms": appsStats.p50,
                    "avgMs": appsStats.avg
                ],
                "observe": [
                    "coldMs": coldObserveMs as Any,
                    "warmIterations": warmObserveRttsMs.count,
                    "warmP50Ms": warmStats.p50,
                    "warmAvgMs": warmStats.avg,
                    "error": coldObserveError as Any
                ]
            ]
            printJSONObject(payload)
            return 0
        }

        print("UseMac Benchmark [\(mode.rawValue)] socket=\(benchSocketPath)")
        print(String(
            format: "  ping (%dx):      min=%.1f µs (%.3f ms) | p50=%.1f µs (%.3f ms) | p95=%.1f µs (%.3f ms) | avg=%.1f µs (%.3f ms)",
            iterations,
            pingStats.min * 1000.0, pingStats.min,
            pingStats.p50 * 1000.0, pingStats.p50,
            pingStats.p95 * 1000.0, pingStats.p95,
            pingStats.avg * 1000.0, pingStats.avg
        ))
        print(String(
            format: "  list_apps (20x): p50=%.3f ms | avg=%.3f ms",
            appsStats.p50,
            appsStats.avg
        ))
        if let coldMs = coldObserveMs {
            print(String(
                format: "  observe:         cold=%.3f ms | hot-cache (20x) p50=%.3f ms | avg=%.3f ms",
                coldMs,
                warmStats.p50,
                warmStats.avg
            ))
        } else {
            print("  observe:         unavailable (\(coldObserveError ?? "unknown error"))")
        }

        return 0
    }

    // MARK: - Helpers

    private static func validateTopLevelKeys(in data: Data, allowedKeys: [String]) throws {
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIError.invalidJSON("Invalid JSON: \(error.localizedDescription)")
        }

        guard let dict = jsonObject as? [String: Any] else {
            throw CLIError.invalidJSON("Invalid JSON: expected a JSON object or an array of action steps.")
        }

        let allowedSet = Set(allowedKeys)
        let unknownKeys = dict.keys.filter { !allowedSet.contains($0) }.sorted()
        if let firstUnknown = unknownKeys.first {
            let allowedList = allowedKeys.sorted().joined(separator: ", ")
            throw CLIError.invalidJSON("Unknown key \"\(firstUnknown)\". Allowed keys: \(allowedList)")
        }
    }

    private static func formatCodingPath(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else if result.isEmpty {
                result = key.stringValue
            } else {
                result += ".\(key.stringValue)"
            }
        }
        return result
    }

    private static func formatDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "Invalid JSON: \(error.localizedDescription)"
        }

        func prefix(for path: [CodingKey]) -> String {
            let formatted = formatCodingPath(path)
            return formatted.isEmpty ? "Invalid JSON" : "Invalid JSON at \(formatted)"
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            let fullPath = context.codingPath + [key]
            return "\(prefix(for: fullPath)): missing required key \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            return "\(prefix(for: context.codingPath)): expected \(type) (\(context.debugDescription))"
        case .valueNotFound(let type, let context):
            return "\(prefix(for: context.codingPath)): missing value of type \(type)"
        case .dataCorrupted(let context):
            let desc = context.debugDescription
            let marker = "from invalid String value "
            if let range = desc.range(of: marker) {
                let badValue = String(desc[range.upperBound...])
                return "\(prefix(for: context.codingPath)): unknown value \"\(badValue)\""
            }
            if let underlying = context.underlyingError {
                return "\(prefix(for: context.codingPath)): \(underlying.localizedDescription)"
            }
            return "\(prefix(for: context.codingPath)): \(desc)"
        @unknown default:
            return "Invalid JSON: \(decodingError.localizedDescription)"
        }
    }

    private static func parseKeyChord(_ chord: String) -> (modifiers: [String], key: String) {
        let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "+" {
            return ([], "+")
        }
        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.count <= 1 {
            return ([], trimmed.lowercased())
        }

        let rawMods = parts.dropLast()
        let keyPart = parts.last ?? ""
        let key = keyPart.isEmpty ? "+" : keyPart.lowercased()

        let modifiers: [String] = rawMods.compactMap { mod in
            let normalized = mod.trimmingCharacters(in: .whitespaces).lowercased()
            switch normalized {
            case "": return nil
            case "command", "cmd", "super", "meta": return "cmd"
            case "control", "ctrl": return "ctrl"
            case "option", "opt", "alt": return "opt"
            case "shift": return "shift"
            case "fn", "function": return "fn"
            default: return normalized
            }
        }
        return (modifiers, key)
    }

    private struct LatencyStats {
        let min: Double
        let p50: Double
        let p95: Double
        let avg: Double
    }

    private static func computeStats(_ samples: [Double]) -> LatencyStats {
        guard !samples.isEmpty else {
            return LatencyStats(min: 0, p50: 0, p95: 0, avg: 0)
        }
        let sorted = samples.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let p50Index = Int(Double(count - 1) * 0.50)
        let p95Index = Int(Double(count - 1) * 0.95)
        return LatencyStats(
            min: sorted[0],
            p50: sorted[p50Index],
            p95: sorted[p95Index],
            avg: sum / Double(count)
        )
    }

    private static func ensureOK(_ response: RPCResponse) throws {
        if !response.ok {
            let code = response.error?.code ?? "rpc_error"
            let message = response.error?.message ?? "Unknown RPC error."
            throw CLIError.rpcFailure(code: code, message: message)
        }
    }

    private static func printEncodableJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func printJSONObject(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func writeStderr(_ text: String) {
        if let data = text.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private static func printUsage() {
        print("""
        UseMac CLI v\(UseMacDefaults.version) — Native macOS GUI & browser control

        Usage:
          usemac [global options] <command> [arguments]

        Global options:
          --socket <path>     Unix socket path (default: \(UseMacDefaults.defaultSocketPath))
          --json              Output JSON
          --standalone        Run in-process without connecting to the UseMac daemon
          --require-daemon    Fail if the UseMac daemon is not reachable

        Commands:
          ping                                       Test socket and engine latency
          status                                     Show daemon status, permissions, and telemetry
          apps                                       List running applications
          observe [--app <n|pid>] [--max-depth <n>] [--max-elements <n>] [--no-cache] [--diff] [--screenshot]
                                                     Capture a compact accessibility snapshot
          act '<json>' [--app <name>]                Execute a BatchActionRequest or [ActionStep]
          click <@eID> [--app <name>]                Click an element by ID
          set <@eID> <text> [--app <name>]           Set the value of an element by ID
          type <text> [--app <name>]                 Type text
          key <chord> [--app <name>]                 Press a key or shortcut (e.g. cmd+shift+p, return)
          screenshot [--app <name>] [--max-dim <n>] [--base64]
                                                     Capture a window or screen screenshot
          browser status                             List Chrome profiles connected to the extension
          browser tabs [--profile <n>] [--query <q>] List open Chrome tabs with tabId, title, and URL
          browser open <url> [--profile <name>] [--tab <id>] [--same-tab] [--no-stream]
                                                     Open a URL in a new tab or navigate a specific tab (--tab) in the background
          browser observe [--profile <n>] [--tab <id>] [--max-elements <n>] [--screenshot] [--no-text] [--no-tables] [--width <px>] [--height <px>] [--scale <n>]
                                                     Inspect DOM (including cross-origin iframes and Shadow DOM), tables, text, and overlays (@b1..@bN)
          browser extract [auto|tables|text|kpis|eval|downloads] [--profile <n>] [--tab <id>] [--selector <css>] [--expr <js>] [--scan-horizontal] [--max-chars <n>]
                                                     Extract tables/ARIA grids (with horizontal scan), KPIs, text, JS, or downloads
          browser screenshot [--profile <n>] [--tab <id>] [--selector <css>] [--element <@bID>] [--full-page] [--width <px>] [--height <px>] [--scale <n>] [--quality <n>]
                                                     Capture a crisp screenshot of the tab or a specific element
          browser act '<json>' [--profile <name>] [--tab <id>] [--read-only] [--verify "<condition>"] [--screenshot]
                                                     Execute BrowserActParams or [ActionStep] in Chrome with optional local verification or screenshot
          vision status                              Show Local Vision engine status (Apple OCR + MLX-VLM)
          vision install [--model <hf-repo>]         Install the MLX runtime and download the local model on demand
          vision ask "<question>" [--profile <n>] [--tab <id>] [--selector <css>] [--element <@bID>] [--app <n>] [--image <path>]
                                                     Ask the local vision model + Apple OCR about the screen (zero cloud image tokens)
          vision verify "<condition>" [--profile <n>] [--tab <id>] [--selector <css>] [--app <n>] [--image <path>]
                                                     Visually verify an expectation locally (YES/NO + evidence)
          vision describe [--profile <n>] [--tab <id>] [--selector <css>] [--app <n>] [--image <path>]
                                                     Summarize the current visual state of the screen (errors, values, buttons, modals)
          vision locate "<target>" [--profile <n>] [--tab <id>] [--app <n>] [--image <path>]
                                                     Locate (x, y) coordinates of a visual element
          vision diagnose [--profile <n>] [--tab <id>] [--app <n>] [--prompt "<text>"]
                                                     Diagnose banners, modals, or errors blocking the page and suggest where to click
          vision ocr [--profile <n>] [--tab <id>] [--app <n>] [--image <path>]
                                                     Run fast native OCR via Apple Vision (Neural Engine)
          start [--profile <n>] [--tab <id>] [--app <n>] [--summary "<text>"]
                                                     Start a continuous session keeping the live preview open between steps
          stop|done [--profile <n>] [--tab <id>] [--app <n>] [--summary "<text>"]
                                                     Finish the task with a completion overlay and smoothly close the preview
          serve                                      Start the Unix socket RPC daemon
          mcp                                        Start the stdio MCP server
          install-skill [--workspace] [--dir <path>] [--force] [--dry-run]
                                                     Install the UseMac SKILL.md into detected agent directories
          bench [--iterations <n>] [--app <name>]    Run a latency benchmark (default: 100)
        """)
    }

    // MARK: - Skill Installer

    private static func handleInstallSkill(args: [String], options: GlobalOptions) throws -> Int32 {
        var workspaceOnly = false
        var customDir: String?
        var force = false
        var dryRun = false
        var idx = 0

        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--workspace", "-w":
                workspaceOnly = true
                idx += 1
            case "--dir", "-d":
                guard idx + 1 < args.count else {
                    throw CLIError.usage("Missing path after \(arg).")
                }
                customDir = (args[idx + 1] as NSString).expandingTildeInPath
                idx += 2
            case "--force":
                force = true
                idx += 1
            case "--dry-run":
                dryRun = true
                idx += 1
            default:
                if arg.hasPrefix("--dir=") {
                    let raw = String(arg.dropFirst("--dir=".count))
                    guard !raw.isEmpty else {
                        throw CLIError.usage("Missing path after --dir=.")
                    }
                    customDir = (raw as NSString).expandingTildeInPath
                    idx += 1
                } else {
                    throw CLIError.usage("Unknown option for install-skill: '\(arg)'.")
                }
            }
        }

        let execURL = resolveExecutableURL()
        let resolvedBin = FileManager.default.isExecutableFile(atPath: execURL.path) ? execURL.path : "usemac"
        let rawSkill = loadSkillMarkdownTemplate(execURL: execURL)
        let stampedSkill = rawSkill
            .replacingOccurrences(of: "{{USEMAC_BIN}}", with: resolvedBin)
            .replacingOccurrences(of: "{{USEMAC_SOCKET}}", with: options.socketPath)

        var targetSkillRoots: [URL] = []
        let fm = FileManager.default

        if let customDir {
            targetSkillRoots.append(URL(fileURLWithPath: customDir, isDirectory: true))
        } else if workspaceOnly {
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            targetSkillRoots.append(cwd.appendingPathComponent(".agents/skills", isDirectory: true))
        } else {
            let home = fm.homeDirectoryForCurrentUser
            // Always install to universal ~/.agents/skills
            targetSkillRoots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))

            // Also install to detected agent homes on this Mac
            let candidateHomes: [(check: String, skillsRel: String)] = [
                (".codex", ".codex/skills"),
                (".claude", ".claude/skills"),
                (".cursor", ".cursor/skills"),
                (".gemini/antigravity", ".gemini/antigravity/skills")
            ]
            for candidate in candidateHomes {
                let checkURL = home.appendingPathComponent(candidate.check, isDirectory: true)
                if fm.fileExists(atPath: checkURL.path) {
                    targetSkillRoots.append(home.appendingPathComponent(candidate.skillsRel, isDirectory: true))
                }
            }
        }

        var results: [InstallSkillTargetResult] = []
        for root in targetSkillRoots {
            let destDir = root.appendingPathComponent("usemac", isDirectory: true)
            let destFile = destDir.appendingPathComponent("SKILL.md", isDirectory: false)
            let status: String

            if isSymbolicLink(atPath: destDir.path) || isSymbolicLink(atPath: destFile.path) {
                status = "skipped (symlink)"
            } else if !fm.fileExists(atPath: destFile.path) {
                status = "installed"
                if !dryRun {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    try stampedSkill.write(to: destFile, atomically: true, encoding: .utf8)
                }
            } else {
                let existing = try? String(contentsOf: destFile, encoding: .utf8)
                if existing == stampedSkill {
                    status = "up to date"
                } else if hasUsemacSkillHeader(existing) {
                    status = "updated"
                    if !dryRun {
                        try stampedSkill.write(to: destFile, atomically: true, encoding: .utf8)
                    }
                } else if force {
                    status = "replaced"
                    if !dryRun {
                        try stampedSkill.write(to: destFile, atomically: true, encoding: .utf8)
                    }
                } else {
                    status = "skipped (not a UseMac skill; use --force)"
                }
            }

            let reportedStatus = dryRun ? "would be \(status)" : status
            results.append(InstallSkillTargetResult(path: destFile.path, status: reportedStatus))

            let legacyDir = root.appendingPathComponent("macuse", isDirectory: true) // Legacy skill folder from the old product name.
            let legacyFile = legacyDir.appendingPathComponent("SKILL.md", isDirectory: false)
            if !isSymbolicLink(atPath: legacyDir.path),
               !isSymbolicLink(atPath: legacyFile.path),
               fm.fileExists(atPath: legacyFile.path),
               let legacyContent = try? String(contentsOf: legacyFile, encoding: .utf8),
               hasLegacySkillHeader(legacyContent) {
                results.append(InstallSkillTargetResult(
                    path: legacyFile.path,
                    status: "legacy skill found, remove it manually"
                ))
            }
        }

        if options.json {
            printEncodableJSON(InstallSkillOutput(ok: true, binary: resolvedBin, targets: results))
        } else {
            for target in results {
                print("\(target.status): \(target.path)")
            }
        }
        return 0
    }

    private static func resolveExecutableURL() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer)
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            }
        }
        if let bundleExec = Bundle.main.executableURL {
            return bundleExec.resolvingSymlinksInPath().standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isSymbolicLink(atPath path: String) -> Bool {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        var st = stat()
        guard lstat(trimmed, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func hasUsemacSkillHeader(_ content: String?) -> Bool {
        guard let content else { return false }
        let lines = content.components(separatedBy: .newlines).prefix(10)
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "name: usemac" }
    }

    private static func hasLegacySkillHeader(_ content: String?) -> Bool {
        guard let content else { return false }
        let lines = content.components(separatedBy: .newlines).prefix(10)
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == "name: macuse" } // Legacy skill folder from the old product name.
    }

    private static func loadSkillMarkdownTemplate(execURL: URL) -> String {
        // 1. Inside UseMac.app/Contents/Helpers/usemac -> ../Resources/agent/skills/usemac/SKILL.md
        let bundledSkill = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/agent/skills/usemac/SKILL.md")
        if let content = try? String(contentsOf: bundledSkill, encoding: .utf8), !content.isEmpty {
            return content
        }

        // 2. Embedded self-contained fallback
        return """
        ---
        name: usemac
        description: Control native macOS desktop applications in the background with Accessibility inspection and zero-focus UI actions via UseMac.
        ---

        # UseMac — Native macOS Background Computer Control

        Always act in the background (`preferBackground: true` on steps, `open -g -a "<App>"`) so you never steal window focus from the user.

        - Check status: `"{{USEMAC_BIN}}" status`
        - Observe app: `"{{USEMAC_BIN}}" observe --app "<AppName>"`
        - Batch actions: `"{{USEMAC_BIN}}" act '{"app":"<AppName>","returnObservation":true,"returnDiffOnly":true,"steps":[{"action":"click","elementId":"@e1","preferBackground":true}]}'`
        """
    }
}
