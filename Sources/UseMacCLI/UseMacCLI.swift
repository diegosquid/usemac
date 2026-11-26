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
        /// `--help` / `-h` anywhere before a literal `--`: print help for the command instead of running it.
        var help: Bool = false
        /// `--task <taskId>` anywhere before a literal `--`: the task (from 'start') every request belongs to.
        var taskFlag: String?
        /// The task requests belong to: `--task`, else `$USEMAC_TASK`.
        var taskId: String? {
            taskFlag ?? ProcessInfo.processInfo.environment["USEMAC_TASK"].flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private enum CLIError: Error {
        case usage(String)
        case daemonRequired(String)
        case invalidJSON(String)
        /// `hint`: the daemon's own advice for this refusal (`error.hint`), preferred over `UseMacErrorGuide`.
        case rpcFailure(code: String, message: String, hint: String? = nil)
    }

    private struct CLIErrorEnvelope: Encodable {
        struct ErrorBody: Encodable {
            let code: String
            let message: String
            let hint: String?
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
        .pairApp,
        .browserReloadExtension
    ]

    /// Exit code 4: a safety rule blocked the request. Stop and tell the user.
    private static let policyBlockCodes: Set<String> = [
        "POLICY_BLOCKED",
        "POLICY_LOCKED",
        "APPROVAL_DENIED",
        "APPROVAL_TIMEOUT",
        "URL_BLOCKED",
        "UPLOAD_BLOCKED",
        "SELF_TARGET_BLOCKED",
        "TARGET_BLOCKED"
    ]

    /// Exit code 5: the screen is not what the caller expected. Observe again, then retry.
    private static let screenChangedCodes: Set<String> = [
        "STALE_SNAPSHOT",
        "ELEMENT_NOT_FOUND",
        "WAIT_TIMEOUT"
    ]

    /// Exit code 6: the step needs the app in front, or the user or another task is busy there. Use a background
    /// step, or wait and retry.
    private static let focusCodes: Set<String> = [
        "TARGET_NOT_FRONTMOST",
        "USER_ACTIVE",
        "TARGET_BUSY"
    ]

    /// Exit code 7: this route cannot reach the content. Switch route (hybrid Chrome flow, observe instead of a capture).
    private static let wrongRouteCodes: Set<String> = [
        "RESTRICTED_PAGE",
        "CAPTURE_TOO_SMALL"
    ]

    private static let batchActionAllowedKeys: [String] = [
        "allowStaleSnapshot",
        "app",
        "expectWindowTitle",
        "foreground",
        "includeScreenshot",
        "returnDiffOnly",
        "returnObservation",
        "steps",
        "stopOnError",
        "window"
    ]

    /// Flags shared by every command that sends an `act` batch.
    private static let batchValueFlags: Set<String> = ["--app", "--expect-title", "--window"]
    private static let batchBoolFlags: Set<String> = ["--foreground", "--allow-stale"]

    private static func exitCode(forErrorCode code: String) -> Int32 {
        if code == "DAEMON_REQUIRED" { return 3 }
        if policyBlockCodes.contains(code) { return 4 }
        if screenChangedCodes.contains(code) { return 5 }
        if focusCodes.contains(code) { return 6 }
        if wrongRouteCodes.contains(code) { return 7 }
        return 1
    }

    /// The code of the first failed step, which decides the exit code of a failed batch.
    private static func firstFailureCode(_ result: BatchActionResult) -> String? {
        result.stepResults.first(where: { !$0.success && ($0.errorCode?.isEmpty == false) })?.errorCode
    }

    private static func exitCode(for result: BatchActionResult) -> Int32 {
        if result.success { return 0 }
        return firstFailureCode(result).map(exitCode(forErrorCode:)) ?? 1
    }

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

            if command == "help" {
                return try printHelp(for: rest)
            }
            if options.help {
                // Only group commands take a subcommand word; for the others the next word is data (JSON, text).
                let isGroup = command == "browser" || command == "vision"
                let path = isGroup && !(rest.first?.hasPrefix("-") ?? true) ? [command, rest[0]] : [command]
                return try printHelp(for: path)
            }

            switch command {
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
            case "find":
                return try await handleFind(args: rest, options: options)
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
            case "audit":
                return try await handleAudit(args: rest, options: options)
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
        var serverHint: String?

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
        case .rpcFailure(let rpcCode, let rpcMessage, let rpcHint):
            exitCode = Self.exitCode(forErrorCode: rpcCode)
            code = rpcCode
            message = rpcMessage
            includeCodeInText = true
            serverHint = rpcHint
        }

        let hint = serverHint ?? UseMacErrorGuide.hint(for: code)
        if json {
            printEncodableJSON(CLIErrorEnvelope(error: .init(code: code, message: message, hint: hint)))
        } else if includeCodeInText {
            writeStderr("Error [\(code)]: \(message)\n")
            if let hint {
                writeStderr("Next: \(hint)\n")
            }
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
            printEncodableJSON(CLIErrorEnvelope(error: .init(code: code, message: message, hint: UseMacErrorGuide.hint(for: code))))
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
            case "--help", "-h":
                options.help = true
                i += 1
            case "--task":
                guard i + 1 < args.count else {
                    throw CLIError.usage("Missing taskId after --task.")
                }
                options.taskFlag = args[i + 1]
                i += 2
            default:
                if arg.hasPrefix("--socket=") {
                    options.socketPath = String(arg.dropFirst("--socket=".count))
                    i += 1
                } else if arg.hasPrefix("--task=") {
                    options.taskFlag = String(arg.dropFirst("--task=".count))
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
        var request = request
        if request.taskId == nil, request.method != .taskStart {
            request.taskId = options.taskId
        }
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

        // In Ask mode a sensitive step waits for the user's answer before it runs.
        let waitMs = timeoutMs + ApprovalTiming.clientAllowanceMs(for: request.method)
        let client = UnixSocketClient(socketPath: options.socketPath, timeoutMs: waitMs, keepAlive: false)
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
            valueFlags: ["--app", "--max-depth", "--max-elements", "--role", "--text", "--window"],
            boolFlags: ["--no-cache", "--diff", "--no-diff", "--screenshot", "--no-offscreen"]
        )
        if let extra = parsed.positionals.first {
            throw CLIError.usage("Unexpected argument '\(extra)'. Run 'usemac help observe'.")
        }

        let maxDepth = try parseOptionalInt(parsed.values, flag: "--max-depth", positive: true)
        let maxElements = try parseOptionalInt(parsed.values, flag: "--max-elements", positive: true)
        let useCache = !parsed.flags.contains("--no-cache")
        let includeDiff = parsed.flags.contains("--diff") || !parsed.flags.contains("--no-diff")
        let includeScreenshot = parsed.flags.contains("--screenshot")
        let filter = ElementMatch(role: parsed.values["--role"], text: parsed.values["--text"])

        let params = ObserveParams(
            app: parsed.values["--app"],
            maxDepth: maxDepth,
            maxElements: maxElements,
            useCache: useCache,
            includeDiff: includeDiff,
            includeScreenshot: includeScreenshot,
            includeOffscreen: parsed.flags.contains("--no-offscreen") ? false : nil,
            window: parsed.values["--window"]
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
        print(snapshot.formattedCompactSummary())
        return 0
    }

    private struct FindOutput: Encodable {
        let app: AppDescriptor
        let count: Int
        let matches: [ElementNode]
    }

    private static func handleFind(args: [String], options: GlobalOptions) async throws -> Int32 {
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

    private static func parseBatchArgs(_ args: [String]) throws -> (values: [String: String], flags: Set<String>, positionals: [String]) {
        let parsed = try parseAppAndExtras(args: args, valueFlags: batchValueFlags, boolFlags: batchBoolFlags)
        if let title = parsed.values["--expect-title"], title.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CLIError.usage("--expect-title expects the text the window title must contain.")
        }
        return parsed
    }

    /// Flags win over the same keys in the JSON, so a caller can add a precondition to a saved batch.
    private static func applyBatchFlags(_ parsed: (values: [String: String], flags: Set<String>, positionals: [String]), to batch: inout BatchActionRequest) {
        if parsed.flags.contains("--foreground") {
            batch.foreground = true
        }
        if parsed.flags.contains("--allow-stale") {
            batch.allowStaleSnapshot = true
        }
        if let title = parsed.values["--expect-title"] {
            batch.expectWindowTitle = title
        }
        if let window = parsed.values["--window"] {
            batch.window = window
        }
    }

    private static func handleAct(args: [String], options: GlobalOptions) async throws -> Int32 {
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

        applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleClick(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseBatchArgs(args)
        guard let elementId = parsed.positionals.first else {
            throw CLIError.usage("Usage: usemac click <@eID> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]")
        }
        let app = parsed.values["--app"]
        var batch = BatchActionRequest(
            app: app,
            steps: [ActionStep(action: .click, app: app, elementId: elementId)]
        )
        applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleSet(args: [String], options: GlobalOptions) async throws -> Int32 {
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
        applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleType(args: [String], options: GlobalOptions) async throws -> Int32 {
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
        applyBatchFlags(parsed, to: &batch)
        return try await sendBatchAction(batch, options: options)
    }

    private static func handleKey(args: [String], options: GlobalOptions) async throws -> Int32 {
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
        applyBatchFlags(parsed, to: &batch)
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

        printBatchActionResult(result, rttMs: rttMs, mode: mode)
        return exitCode(for: result)
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
            var status = step.success ? "ok" : "error"
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
            throw CLIError.usage("Usage: usemac browser <status|tabs|open|observe|extract|screenshot|act|reload-extension> ...")
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
        case "reload-extension":
            return try await handleBrowserReloadExtension(args: rest, options: options)
        case "help":
            return try printHelp(for: ["browser"] + rest.prefix(1))
        default:
            throw CLIError.usage("Unknown browser subcommand: '\(subcommand)'. Use: status, tabs, open, observe, extract, screenshot, act, reload-extension.")
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

    private static func handleBrowserOpen(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(
            args: args,
            valueFlags: ["--profile", "--tab"],
            boolFlags: ["--same-tab", "--new-tab", "--no-stream", "--activate", "--new-window"]
        )
        let usage = "Usage: usemac browser open <url> [--profile <name>] [--tab <id>] [--same-tab|--new-tab] [--activate] [--new-window] [--no-stream] [--task <taskId>], or: usemac browser open --tab <id> --activate"
        let tabId = try parseOptionalInt(parsed.values, flag: "--tab")
        let activate = parsed.flags.contains("--activate")
        let newWindow = parsed.flags.contains("--new-window")
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
        let openNewTab: Bool = {
            if url.isEmpty { return false }
            if parsed.flags.contains("--same-tab") { return false }
            if parsed.flags.contains("--new-tab") { return true }
            return tabId == nil
        }()
        let params = BrowserOpenParams(
            url: url,
            profile: parsed.values["--profile"],
            tabId: tabId,
            newTab: openNewTab,
            stream: !parsed.flags.contains("--no-stream"),
            activate: activate ? true : nil,
            newWindow: newWindow ? true : nil,
            taskId: options.taskId
        )
        let req = RPCRequest(method: .browserOpen, browserOpen: params)
        let (res, rttMs, mode) = try await executeRPC(req, options: options, timeoutMs: 20000)
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
        printBatchActionResult(result, rttMs: rttMs, mode: mode, headerDetail: headerDetail)
        return exitCode(for: result)
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

        case "help":
            return try printHelp(for: ["vision"] + rest.prefix(1))
        default:
            throw CLIError.usage("Unknown vision subcommand: '\(sub)'. Use: status, install, ask, verify, describe, locate, diagnose, or ocr.")
        }
    }

    private static func handleTaskStart(args: [String], options: GlobalOptions) async throws -> Int32 {
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
            agent: parsed.values["--agent"]
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

    private static func handleTaskComplete(args: [String], options: GlobalOptions) async throws -> Int32 {
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

    private static func handleAudit(args: [String], options: GlobalOptions) async throws -> Int32 {
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
        let taskId = parsed.values["--task"]
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
            throw CLIError.rpcFailure(code: code, message: message, hint: response.error?.hint)
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

    // MARK: - Help

    private static func printUsage() {
        print("""
        UseMac CLI v\(UseMacDefaults.version) — Native macOS GUI & browser control

        Usage:
          usemac [global options] <command> [arguments]
          usemac help <command>          Usage, flags and an example for one command (same as <command> --help)

        Global options:
          --socket <path>     Unix socket path (default: \(UseMacDefaults.defaultSocketPath))
          --json              Output JSON (shape below)
          --standalone        Run in-process without connecting to the UseMac daemon
          --require-daemon    Fail if the UseMac daemon is not reachable
          --task <taskId>     The task ('start' prints it) the request belongs to (default: $USEMAC_TASK)

        Commands:
          ping                                       Test socket and engine latency
          status                                     Show daemon status, permissions, and telemetry
          apps                                       List running applications
          observe [--app <n|pid>] [--role <r>] [--text <t>] [--max-depth <n>] [--max-elements <n>] [--no-cache] [--no-diff] [--no-offscreen] [--screenshot]
                                                     Capture a compact accessibility snapshot (stable @eN ids)
          find --app <n|pid> [--role <r>] [--text <t>] [--title <t>] [--value <v>] [--exact] [--first] [--max-depth <n>] [--max-elements <n>]
                                                     Search the live accessibility tree with the same rules as act's "match"
          act '<json>'|- [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]
                                                     Execute a BatchActionRequest or [ActionStep]
          click <@eID> [--app <name>]                Click an element by ID
          set <@eID> <text> [--app <name>]           Set the value of an element by ID
          type <text> [--app <name>]                 Type text
          key <chord> [--app <name>]                 Press a key or shortcut (e.g. cmd+shift+p, return)
                                                     (click, set, type and key also take --foreground, --expect-title, --allow-stale)
          screenshot [--app <name>] [--max-dim <n>] [--base64]
                                                     Capture a window or screen screenshot
          browser status                             List Chrome profiles connected to the extension (version, outdated, source)
          browser tabs [--profile <n>] [--query <q>] List open Chrome tabs with tabId, title, and URL
          browser open <url> [--profile <name>] [--tab <id>] [--same-tab] [--activate] [--new-window] [--no-stream]
                                                     Open a URL in a background tab, navigate --tab, or open it in a new window
          browser open --tab <id> --activate         Make an existing tab the active tab of its window (for native observe/act)
          browser observe [--profile <n>] [--tab <id>] [--max-elements <n>] [--screenshot] [--no-text] [--no-tables] [--width <px>] [--height <px>] [--scale <n>]
                                                     Inspect DOM (including cross-origin iframes and Shadow DOM), tables, text, and overlays (@b1..@bN)
          browser extract [auto|tables|text|kpis|eval|downloads] [--profile <n>] [--tab <id>] [--selector <css>] [--expr <js>] [--scan-horizontal] [--max-chars <n>]
                                                     Extract tables/ARIA grids (with horizontal scan), KPIs, text, JS, or downloads
          browser screenshot [--profile <n>] [--tab <id>] [--selector <css>] [--element <@bID>] [--full-page] [--width <px>] [--height <px>] [--scale <n>] [--quality <n>]
                                                     Capture a crisp screenshot of the tab or a specific element
          browser act '<json>' [--profile <name>] [--tab <id>] [--read-only] [--verify "<condition>"] [--screenshot]
                                                     Execute BrowserActParams or [ActionStep] in Chrome with optional local verification or screenshot
          browser reload-extension [--profile <n>] [--force]
                                                     Reload the extension so Chrome runs the code now in its folder (stops running browser work)
          vision status                              Show Local Vision engine status (Apple OCR + MLX-VLM)
          vision install [--model <hf-repo>]         Install the MLX runtime and download the local model on demand
          vision ask|verify|describe|locate|diagnose|ocr ["<text>"] [--profile <n>] [--tab <id>] [--app <n>] [--image <path>] [--selector <css>] [--element <@bID>]
                                                     Ask the on-device vision model + Apple OCR about the screen (zero cloud image tokens)
          start [--profile <n>] [--tab <id>] [--app <n>] [--summary "<text>"] [--agent <name>]
                                                     Start a task (prints its taskId) keeping the live preview open between steps
          stop|done [--profile <n>] [--tab <id>] [--app <n>] [--summary "<text>"]
                                                     Finish the task with a completion overlay and smoothly close the preview
          audit [--limit <n>] [--since <time>] [--task <taskId>]
                                                     Print the audit log (kept on disk, typed text redacted), newest first
          serve                                      Start the Unix socket RPC daemon
          mcp                                        Start the stdio MCP server
          install-skill [--workspace] [--dir <path>] [--force] [--dry-run]
                                                     Install the UseMac SKILL.md into detected agent directories
          bench [--iterations <n>] [--app <name>]    Run a latency benchmark (default: 100)

        Exit codes:
          0  Success
          1  Command or RPC failure (find: nothing matched)
          2  Invalid usage, unknown flag or key, or invalid JSON
          3  Daemon required (DAEMON_REQUIRED): ask the user to open UseMac
          4  Blocked by a safety rule or the user (POLICY_BLOCKED, POLICY_LOCKED, APPROVAL_DENIED, APPROVAL_TIMEOUT, URL_BLOCKED, UPLOAD_BLOCKED, SELF_TARGET_BLOCKED, TARGET_BLOCKED): stop and tell the user
          5  The screen is not what you expected (STALE_SNAPSHOT, ELEMENT_NOT_FOUND, WAIT_TIMEOUT): observe again, then retry
          6  Needs the app (and its window) in front, or the user or another task is busy there (TARGET_NOT_FRONTMOST, USER_ACTIVE, TARGET_BUSY): use a background step, or wait and retry
          7  This route cannot reach it (RESTRICTED_PAGE, CAPTURE_TOO_SMALL): switch route (see 'usemac help browser')

        JSON output (--json):
          Success prints the result object itself: observe → WindowSnapshot, find → {"app","count","matches"},
          act/click/set/type/key → BatchActionResult, apps → [AppDescriptor], status → DaemonStatus.
          Errors print {"ok":false,"error":{"code":"…","message":"…","hint":"…"}} to stdout; the exit code is set as above.
          Run 'usemac help <command>' for that command's fields.
        """)
    }

    private struct CommandHelp {
        var usage: [String]
        var summary: String
        var flags: [(String, String)] = []
        var notes: [String] = []
        var examples: [String] = []
        var json: String?
    }

    private static let batchFlagHelp: [(String, String)] = [
        ("--app <name|pid>", "Target app (default: the app in the JSON, else the paired or frontmost app)"),
        ("--foreground", "Foreground burst: bring the app to the front, run the steps with real input, then give focus back. Refused with USER_ACTIVE if the user typed or used the mouse in the last 1.5 s. Use only when a background step had no effect or failed with TARGET_NOT_FRONTMOST."),
        ("--expect-title <text>", "Precondition: fail with STALE_SNAPSHOT before any step unless the target window title contains <text> (digits ignored)"),
        ("--allow-stale", "Skip the automatic check that the window still shows what your last observe saw"),
        ("--window <title>", "Act in the window whose title contains this text (default: the window of your last observe)")
    ]

    private static let batchResultJSON = "BatchActionResult {success, totalLatencyMs, stepResults: [{index, action, success, mechanism, latencyMs, message, errorCode, effect (changed|none|unverified), warning, resolvedElementId, scrollDeltaY, visualChangePercent, downloadPath}], observation: WindowSnapshot, agentFeedback, screenshot}"

    private static let snapshotJSON = "WindowSnapshot {app: {pid, name, bundleId, windowTitle, windowId}, timestampMs, latencyMs, fromHotCache, focusedElementId, elements: [{id, role, title, value, roleDescription, enabled, focused, frame {x, y, width, height}, actions, offscreen}], diff, screenshotPath}"

    private static let restrictedPageNote = "On RESTRICTED_PAGE (Chrome Web Store, chrome:// pages the extension cannot script) switch to the hybrid flow: 'usemac browser open --tab <id> --activate' (or 'browser open <url> --new-window'), then 'usemac observe --app \"Google Chrome\"' and 'usemac act … --app \"Google Chrome\"'. Native observe only sees the active tab of each Chrome window."

    private static let browserSubcommands: [(String, String)] = [
        ("status", "List Chrome profiles connected to the extension"),
        ("tabs", "List open Chrome tabs with tabId, title and URL"),
        ("open", "Open a URL in a background tab, navigate a tab, activate a tab, or open a new window"),
        ("observe", "Inspect a tab's DOM (@b1..@bN), tables, text and overlays"),
        ("extract", "Extract tables, KPIs, text, JS results or session downloads"),
        ("screenshot", "Capture a JPEG of a tab or one element"),
        ("act", "Run DOM action steps in a tab"),
        ("reload-extension", "Reload the extension so Chrome runs its current code")
    ]

    private static let visionSubcommands: [(String, String)] = [
        ("status", "Show Local Vision status (Apple OCR + MLX model)"),
        ("install", "Install the MLX runtime and download a preset model"),
        ("ask", "Ask a visual question about the screen"),
        ("verify", "Check a visual assertion (YES/NO + evidence)"),
        ("describe", "Summarize the visible state (errors, values, buttons, modals)"),
        ("locate", "Find the (x, y) point of a visual element"),
        ("diagnose", "Detect banners, modals or errors blocking the page"),
        ("ocr", "Run Apple Vision OCR")
    ]

    private static func commandHelp(_ key: String) -> CommandHelp? {
        switch key {
        case "ping":
            return CommandHelp(
                usage: ["usemac ping"],
                summary: "Check that the daemon answers and show the round-trip latency.",
                examples: ["usemac ping"],
                json: "{ok, mode, pong, roundTripMs, roundTripUs, serverLatencyMs}"
            )
        case "status":
            return CommandHelp(
                usage: ["usemac status"],
                summary: "Show the daemon version, execution mode, Kill Switch, permissions, paired and frontmost app, connected Chrome profiles and telemetry.",
                examples: ["usemac status"],
                json: "DaemonStatus {version, pid, socketPath, policy, killSwitchTripped, permissions {accessibilityGranted, screenRecordingGranted}, pairedApp, frontmostApp, browserProfiles, telemetry}"
            )
        case "apps":
            return CommandHelp(
                usage: ["usemac apps"],
                summary: "List running GUI apps with pid, bundle id, active state and front window title. UseMac itself, and apps the user's app and site rules block (TARGET_BLOCKED), are never listed or targeted.",
                examples: ["usemac apps"],
                json: "[AppDescriptor {pid, name, bundleId, isActive, isHidden, windowTitle, windowBounds, windowId}]"
            )
        case "observe":
            return CommandHelp(
                usage: ["usemac observe [--app <name|pid>] [--role <role>] [--text <text>] [--max-depth <n>] [--max-elements <n>] [--no-cache] [--no-diff] [--no-offscreen] [--screenshot]"],
                summary: "Capture a compact accessibility snapshot of the app's focused window. The same element keeps the same @eN id across observes; elements scrolled out of view are listed as (offscreen) and acting on one scrolls it into view first.",
                flags: [
                    ("--app <name|pid>", "Target app name, bundle id or pid (default: the paired app, else the frontmost app)"),
                    ("--role <role>", "Only print elements with this AX role, with or without the AX prefix (button = AXButton)"),
                    ("--text <text>", "Only print elements whose title, description or value contains <text> (case- and accent-insensitive)"),
                    ("--max-depth <n>", "How deep to walk the accessibility tree (raise it for nested lists and sheets)"),
                    ("--max-elements <n>", "Maximum number of elements to index"),
                    ("--no-cache", "Read the live tree instead of the hot cache"),
                    ("--diff | --no-diff", "Include (default) or leave out the diff against the previous snapshot"),
                    ("--no-offscreen", "Leave out elements scrolled out of view"),
                    ("--window <title>", "Observe the window whose title contains this text instead of the focused one; later acts keep using it"),
                    ("--screenshot", "Also save a JPEG of the window and print its path")
                ],
                notes: ["--role and --text only narrow what is printed; the daemon still indexes the whole window, so ids stay valid for act."],
                examples: [
                    "usemac observe --app \"Notes\"",
                    "usemac observe --app \"System Settings\" --role checkbox --text bluetooth"
                ],
                json: snapshotJSON + " (with --role/--text, elements holds only the matches)"
            )
        case "find":
            return CommandHelp(
                usage: ["usemac find --app <name|pid> [--role <role>] [--text <t>] [--title <t>] [--value <v>] [--exact] [--first] [--max-depth <n>] [--max-elements <n>]"],
                summary: "Read the app's live accessibility tree (no cache) and print the elements that match, using the same rules act uses for \"match\". Use it to check a match before acting, or to get an id.",
                flags: [
                    ("--app <name|pid>", "Target app (required)"),
                    ("--role <role>", "AX role, with or without the AX prefix (button = AXButton)"),
                    ("--text <t>", "Title, description or value contains <t>"),
                    ("--title <t>", "Title or description contains <t>"),
                    ("--value <v>", "Value contains <v>"),
                    ("--exact", "Require equal text instead of contains"),
                    ("--first", "Print only the id of the first match (exit 1 when nothing matches)"),
                    ("--max-depth <n>", "How deep to walk the tree (raise it for long or nested lists)"),
                    ("--max-elements <n>", "Maximum number of elements to read")
                ],
                notes: [
                    "Text compares are case- and accent-insensitive. Every filter you pass must match. At least one filter is required.",
                    "Exit code 1 when nothing matches, like grep."
                ],
                examples: [
                    "usemac find --app \"Notes\" --role button --text \"new note\"",
                    "ID=$(usemac find --app \"Mail\" --role textfield --title subject --first) && usemac set \"$ID\" \"Weekly report\" --app \"Mail\""
                ],
                json: "{app: AppDescriptor, count, matches: [ElementNode]} (count 0 and exit 1 when nothing matches)"
            )
        case "act":
            return CommandHelp(
                usage: [
                    "usemac act '<json>' [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]",
                    "usemac act - < batch.json"
                ],
                summary: "Run a BatchActionRequest (a JSON object) or a list of ActionStep (a JSON array) on a native app, in the background by default. Pass - to read the JSON from stdin.",
                flags: batchFlagHelp,
                notes: [
                    "Batch keys: app, steps, stopOnError, returnObservation, returnDiffOnly, includeScreenshot, expectWindowTitle, allowStaleSnapshot, foreground, window. Flags win over the same keys in the JSON.",
                    "Step actions: target, openURL, navigate, click, doubleClick, rightClick, hover, setValue, type, pressKey, scroll, focus, wait, uploadFile, scrollIntoView, axAction (actionName, e.g. AXOpen), waitFor (match or elementId, timeoutMs default 5000, gone: true to wait until it disappears).",
                    "Target a step with \"elementId\": \"@e12\" or with \"match\": {\"role\", \"title\", \"value\", \"text\", \"exact\", \"index\"}, resolved when the step runs. Prefer match when the window may have changed.",
                    "Each step reports effect: changed, none or unverified. \"⚠ no visible effect\" means the step reported ok but nothing changed: observe before continuing.",
                    "In an open panel (file picker) use one uploadFile step with the absolute path instead of clicking through Finder. Files in /tmp, $TMPDIR or hidden folders fail with TARGET_NOT_FRONTMOST in the background: upload a copy from ~/Downloads, or rerun with --foreground.",
                    "In Ask mode a step with an upload or a cmd/ctrl shortcut waits (up to 45 s) for the user to allow it in UseMac; APPROVAL_DENIED or APPROVAL_TIMEOUT (exit 4) means nothing ran."
                ],
                examples: [
                    "usemac act '{\"app\":\"Notes\",\"steps\":[{\"action\":\"click\",\"match\":{\"role\":\"button\",\"title\":\"New Note\"}},{\"action\":\"type\",\"text\":\"Hello\"}]}'",
                    "usemac act '[{\"action\":\"waitFor\",\"match\":{\"text\":\"Saved\"},\"timeoutMs\":8000}]' --app \"Notes\"",
                    "usemac act '[{\"action\":\"uploadFile\",\"files\":[\"/Users/me/Desktop/report.pdf\"]}]' --app \"Safari\""
                ],
                json: batchResultJSON
            )
        case "click":
            return CommandHelp(
                usage: ["usemac click <@eID> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Click an element by id (AXPress in the background when the element supports it).",
                flags: batchFlagHelp,
                notes: ["To click by what the element is, use act with \"match\", or: usemac click \"$(usemac find --app <name> --role button --title Save --first)\" --app <name>."],
                examples: ["usemac click @e12 --app \"Notes\""],
                json: batchResultJSON
            )
        case "set":
            return CommandHelp(
                usage: ["usemac set <@eID> <text> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Set an element's value directly (AXValue) without typing. Works in the background.",
                flags: batchFlagHelp,
                examples: ["usemac set @e7 \"hello@example.com\" --app \"Mail\""],
                json: batchResultJSON
            )
        case "type":
            return CommandHelp(
                usage: ["usemac type <text> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Type text into the app's focused element.",
                flags: batchFlagHelp,
                examples: ["usemac type \"Meeting notes\" --app \"Notes\""],
                json: batchResultJSON
            )
        case "key":
            return CommandHelp(
                usage: ["usemac key <chord> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Press a key or shortcut. Modifiers: cmd (command, meta), shift, opt (alt, option), ctrl (control). Keys: return (enter), tab, space, delete (backspace), forwarddelete, escape (esc), up, down, left, right, home, end, pageup, pagedown, f1–f12, a–z, 0–9, - = [ ] ; ' , . / \\ `.",
                flags: batchFlagHelp,
                notes: [
                    "In Ask mode a step with an upload or a cmd/ctrl shortcut waits (up to 45 s) for the user to allow it in UseMac; APPROVAL_DENIED or APPROVAL_TIMEOUT (exit 4) means nothing ran.",
                    "Character keys are key positions on a US keyboard: use `usemac type` to enter text, and shift plus the base key for a shifted symbol (shift+= for +).",
                    "An unknown key fails with INVALID_REQUEST and lists these names."
                ],
                examples: ["usemac key cmd+shift+n --app \"Finder\"", "usemac key pagedown --app \"TextEdit\""],
                json: batchResultJSON
            )
        case "screenshot":
            return CommandHelp(
                usage: ["usemac screenshot [--app <name>] [--max-dim <n>] [--base64]"],
                summary: "Save a downscaled JPEG of the app's target window (or the display) to a private temp folder (pruned after 30 minutes).",
                flags: [
                    ("--app <name>", "Target app (default: the paired or frontmost app)"),
                    ("--max-dim <n>", "Longest edge in pixels (default 1280)"),
                    ("--base64", "Also print the image as base64")
                ],
                notes: ["Fails with CAPTURE_TOO_SMALL (exit 7) when the only window found is too small to trust, such as a helper strip: observe the app instead of reading that image."],
                examples: ["usemac screenshot --app \"Notes\""],
                json: "ScreenshotResult {path, mimeType, width, height, byteCount, latencyMs, base64Data}"
            )
        case "browser":
            return CommandHelp(
                usage: ["usemac browser <subcommand> [arguments]"],
                summary: "Drive Google Chrome tabs in the background through the UseMac Browser Bridge extension. Use these before any native observe/act on Chrome.",
                flags: browserSubcommands,
                notes: [restrictedPageNote, "Run 'usemac help browser <subcommand>' for its flags."],
                examples: ["usemac browser tabs --query analytics", "usemac browser observe --tab 123"]
            )
        case "browser status":
            return CommandHelp(
                usage: ["usemac browser status"],
                summary: "List the Chrome profiles connected to the extension (name, e-mail, extension version, tab count, streaming tab), and whether each one runs an outdated extension or one loaded from another folder.",
                notes: [
                    "extensionOutdated: Chrome runs an older extension than UseMac.app ships (bundledExtensionVersion). Tell the user, or run 'usemac browser reload-extension' when nothing else is using Chrome.",
                    "extensionSource: app (UseMac.app's folder), web_store, other_folder (unpacked from another folder: app updates won't reach it) or unknown."
                ],
                examples: ["usemac browser status"],
                json: "[BrowserProfileStatus {profileName, profileEmail, extensionVersion, tabCount, streamingTabId, streamingUrl, extensionId, extensionSource, bundledExtensionVersion, extensionOutdated, extensionReloadable, extensionNote}]"
            )
        case "browser reload-extension":
            return CommandHelp(
                usage: ["usemac browser reload-extension [--profile <name>] [--force]"],
                summary: "Reload the UseMac extension so Chrome runs the code now in its folder (after an app update, or a change in the folder it was loaded from). Waits until it has reconnected and prints its new version.",
                flags: [
                    ("--profile <name>", "Reload only this Chrome profile (default: every connected profile)"),
                    ("--force", "Reload even while agents have Chrome commands running (they fail)")
                ],
                notes: [
                    "Reloading stops every agent's browser work in that profile: run it only when the user asks, or when nothing else is using Chrome. Without --force it fails with BROWSER_BUSY while commands are running.",
                    "Tabs UseMac opened before the reload stay open, but 'done' no longer closes them.",
                    "EXTENSION_RELOAD_UNSUPPORTED: the extension predates remote reload. The user reloads it once in chrome://extensions. EXTENSION_RELOAD_TIMEOUT: it did not come back within 15 s; check chrome://extensions for errors."
                ],
                examples: ["usemac browser reload-extension", "usemac browser reload-extension --profile Work"],
                json: "[BrowserProfileStatus] of the reloaded profiles, as 'browser status' prints them"
            )
        case "browser tabs":
            return CommandHelp(
                usage: ["usemac browser tabs [--profile <name>] [--query <text>]"],
                summary: "List open Chrome tabs with tabId, title, URL and active state. Tabs on sites the user's app and site rules block are left out; any browser command on one, or opening such a site, fails with TARGET_BLOCKED (exit 4).",
                flags: [
                    ("--profile <name>", "Chrome profile from 'browser status' (only needed with several profiles)"),
                    ("--query <text>", "Case-insensitive filter on title or URL")
                ],
                examples: ["usemac browser tabs --query \"analytics\""],
                json: "[BrowserTabInfo {tabId, windowId, index, title, url, active, pinned, status, profileName}]"
            )
        case "browser open":
            return CommandHelp(
                usage: [
                    "usemac browser open <url> [--profile <name>] [--tab <id>] [--same-tab|--new-tab] [--activate] [--new-window] [--no-stream] [--task <taskId>]",
                    "usemac browser open --tab <id> --activate"
                ],
                summary: "Open a URL in a new background tab, navigate an existing tab, make a tab active, or open the URL in a new unfocused window.",
                flags: [
                    ("--profile <name>", "Chrome profile from 'browser status' (only needed with several profiles)"),
                    ("--tab <id>", "Navigate this tab instead of opening a new one"),
                    ("--same-tab | --new-tab", "Force navigating in place or opening a new tab"),
                    ("--activate", "Make the tab the active tab of its window (Chrome stays in the background). With --tab and no URL, only activates that tab."),
                    ("--new-window", "Open the URL in a new, unfocused Chrome window owned by UseMac (cannot be combined with --tab)"),
                    ("--no-stream", "Do not stream live preview frames to the UseMac HUD"),
                    ("--task <taskId>", "The taskId 'start' printed: the new tab belongs to that task, so another agent's 'done' never closes it")
                ],
                notes: [
                    "Only http://, https:// and about:blank are allowed (a URL without a scheme gets https://); anything else fails with URL_BLOCKED.",
                    restrictedPageNote
                ],
                examples: [
                    "usemac browser open \"https://example.com\"",
                    "usemac browser open --tab 123 --activate",
                    "usemac browser open \"https://chromewebstore.google.com/\" --new-window"
                ],
                json: "RPCResponse {ok, browserTabId, browserUrl, browserTitle, snapshot}"
            )
        case "browser observe":
            return CommandHelp(
                usage: ["usemac browser observe [--profile <name>] [--tab <id>] [--max-elements <n>] [--screenshot] [--no-text] [--no-tables] [--width <px>] [--height <px>] [--scale <n>]"],
                summary: "Inspect a tab's interactive DOM as @b1..@bN refs (including cross-origin iframes and Shadow DOM), tables, readable text, scroll state and blocking overlays.",
                flags: [
                    ("--profile <name>", "Chrome profile (only needed with several profiles)"),
                    ("--tab <id>", "Tab to observe (default: the last UseMac tab)"),
                    ("--max-elements <n>", "Maximum DOM elements (default 280, max 600)"),
                    ("--screenshot", "Also save a JPEG of the tab"),
                    ("--no-text | --no-tables", "Leave out readable text or tables"),
                    ("--width/--height <px>, --scale <n>", "Emulated viewport size and pixel density")
                ],
                notes: [restrictedPageNote],
                examples: ["usemac browser observe --tab 123"],
                json: snapshotJSON + " plus pageState {readableText, tablesMarkdown, scroll…, blockingOverlay}"
            )
        case "browser extract":
            return CommandHelp(
                usage: ["usemac browser extract [auto|tables|text|kpis|eval|downloads] [--profile <name>] [--tab <id>] [--selector <css>] [--expr <js>] [--scan-horizontal] [--max-chars <n>]"],
                summary: "Extract structured data from a tab. auto, tables, text and kpis only read; downloads lists files downloaded during the UseMac session; eval runs JavaScript in the page (autonomous mode, or Ask mode once the user allows it; logged).",
                flags: [
                    ("--tab <id>", "Tab to read"),
                    ("--selector <css>", "Scope extraction to one container"),
                    ("--expr <js>", "Expression for eval mode"),
                    ("--scan-horizontal", "Scroll wide virtualized grids horizontally and merge all columns"),
                    ("--max-chars <n>", "Output limit (default 16000)")
                ],
                examples: ["usemac browser extract tables --tab 123 --scan-horizontal"],
                json: "BrowserExtractResult {mode, tabId, url, tablesMarkdown, rowCount, columnCount, text, jsonResult, downloads, latencyMs}"
            )
        case "browser screenshot":
            return CommandHelp(
                usage: ["usemac browser screenshot [--profile <name>] [--tab <id>] [--selector <css>] [--element <@bID>] [--full-page] [--width <px>] [--height <px>] [--scale <n>] [--quality <n>]"],
                summary: "Capture a JPEG of a tab, or crop it around a selector or @bID. Prefer observe/extract or on-device vision first.",
                flags: [
                    ("--selector <css> | --element <@bID>", "Crop around this element"),
                    ("--full-page", "Capture the full scrollable height (capped at 6000 px)"),
                    ("--width/--height <px>, --scale <n>", "Emulated viewport size and pixel density"),
                    ("--quality <n>", "JPEG quality 30–100 (default 84)")
                ],
                examples: ["usemac browser screenshot --tab 123 --selector \"#chart\" --scale 2"],
                json: "ScreenshotResult {path, mimeType, width, height, byteCount, latencyMs}"
            )
        case "browser act":
            return CommandHelp(
                usage: ["usemac browser act '<json>' [--profile <name>] [--tab <id>] [--read-only] [--verify \"<condition>\"] [--screenshot]"],
                summary: "Run DOM action steps in a tab with @bN refs or CSS selectors: click, doubleClick, rightClick, hover, setValue (including <select>), type, pressKey, scroll, wait (with selector or text), uploadFile (no Finder), navigate/openURL.",
                flags: [
                    ("--tab <id>", "Tab to act on"),
                    ("--read-only", "Block mutating steps (only scroll, hover, wait and target run)"),
                    ("--verify \"<condition>\"", "Check the result on-device after the steps (zero cloud image tokens)"),
                    ("--screenshot", "Attach a post-action screenshot")
                ],
                notes: [
                    "JSON keys: profile, tabId, steps, stopOnError, returnObservation, returnDiffOnly, readOnly, verify, returnImageContent.",
                    restrictedPageNote,
                    "In Ask mode a step with an upload or a cmd/ctrl shortcut waits (up to 45 s) for the user to allow it in UseMac; APPROVAL_DENIED or APPROVAL_TIMEOUT (exit 4) means nothing ran."
                ],
                examples: ["usemac browser act '[{\"action\":\"setValue\",\"elementId\":\"@b2\",\"text\":\"UseMac\"},{\"action\":\"click\",\"elementId\":\"@b3\"}]' --tab 123"],
                json: batchResultJSON
            )
        case "vision":
            return CommandHelp(
                usage: ["usemac vision <subcommand> [arguments]"],
                summary: "On-device vision (Apple Vision OCR plus an optional MLX model). Images never leave the Mac.",
                flags: visionSubcommands,
                notes: ["Run 'usemac help vision <subcommand>' for its flags."],
                examples: ["usemac vision verify \"Success banner is visible\" --tab 123"]
            )
        case "vision status":
            return CommandHelp(
                usage: ["usemac vision status"],
                summary: "Show whether OCR and the local model are ready.",
                examples: ["usemac vision status"],
                json: "VisionStatus {state, enabled, backend, modelId, runtimeInstalled, modelDownloaded, workerRunning, lastError}"
            )
        case "vision install":
            return CommandHelp(
                usage: ["usemac vision install [--model <hf-repo>]"],
                summary: "Install the MLX runtime and download one of the three preset models (INVALID_MODEL otherwise).",
                flags: [("--model <hf-repo>", "Preset model id (default: the recommended preset)")],
                examples: ["usemac vision install"]
            )
        case "vision ask", "vision verify", "vision describe", "vision locate", "vision diagnose", "vision ocr":
            let mode = String(key.dropFirst("vision ".count))
            let summaries: [String: String] = [
                "ask": "Answer a visual question about the screen, grounded in OCR.",
                "verify": "Check a visual assertion and answer YES/NO with evidence.",
                "describe": "Summarize the visible state: errors, values, buttons, modals.",
                "locate": "Return the (x, y) point of a visual element.",
                "diagnose": "Detect banners, modals or errors blocking the page and suggest where to click.",
                "ocr": "Run Apple Vision OCR and print the text with positions."
            ]
            let takesText = ["ask", "verify", "locate"].contains(mode)
            return CommandHelp(
                usage: ["usemac vision \(mode)\(takesText ? " \"<text>\"" : "") [--profile <name>] [--tab <id>] [--app <name>] [--image <path>] [--selector <css>] [--element <@bID>] [--prompt \"<text>\"]"],
                summary: summaries[mode] ?? "",
                flags: [
                    ("--tab <id> | --app <name>", "What to look at: a Chrome tab or a native app window"),
                    ("--image <path>", "Use an existing image (must be in your temp folder or /tmp)"),
                    ("--selector <css> | --element <@bID>", "Crop to one element of a Chrome tab"),
                    ("--prompt \"<text>\"", "Question or condition (same as the positional text)")
                ],
                examples: [mode == "verify" ? "usemac vision verify \"Success banner is visible\" --tab 123" : "usemac vision \(mode)\(takesText ? " \"X close button\"" : "") --app \"Notes\""],
                json: "VisionQueryResult {mode, backend, modelId, answer, verified, x, y, blockingDetected, imagePath, detections, latencyMs}"
            )
        case "start":
            return CommandHelp(
                usage: ["usemac start [--summary \"<text>\"] [--agent <name>] [--app <name>] [--profile <name>] [--tab <id>] [--task <taskId>]"],
                summary: "Call once at the start of a multi-step task so the floating live preview opens once and stays open between steps. Prints a taskId: pass it as --task to every later command (or export USEMAC_TASK=<taskId>). When several agents work at once, a browser command without --tab then goes to this task's own last tab, not another agent's, and finishing this task only closes the tabs it opened. While the task runs, the windows and tabs it acts in are its own: another task's act there fails with TARGET_BUSY (exit 6) until this one is done. --agent names the agent on its preview cards.",
                examples: ["usemac start --summary \"Reviewing dashboard\" --agent \"Claude Code\""]
            )
        case "stop", "done", "complete":
            return CommandHelp(
                usage: ["usemac done [--summary \"<text>\"] [--task <taskId>] [--app <name>] [--profile <name>] [--tab <id>] [--keep-tab <id,id>] [--keep-tabs]   (aliases: stop, complete)"],
                summary: "Call once when the whole task is finished: shows the completion state and closes the live preview. About 2 s later UseMac closes the Chrome tabs it opened (never your own tabs, the tab you are looking at, or tabs with a running download). --keep-tab keeps the page with the result; --keep-tabs keeps them all. With --task, only that task's tabs close: tabs other running tasks opened are never closed. Prints what the task did (with --json: taskSummary with requests, actions, failedActions, blocked, tabsOpened, tabsClosed, tabsClosing, durationMs).",
                examples: ["usemac done --summary \"Report exported\"", "usemac done --summary \"Invoice ready\" --keep-tab 123"]
            )
        case "audit":
            return CommandHelp(
                usage: ["usemac audit [--limit <n>] [--since <30m|2h|7d|date|ms>] [--task <taskId>]"],
                summary: "Print the audit log, newest first: every observation and action, with its app, result and task. Without flags, the 50 most recent entries. UseMac keeps it on disk (one file per day, 30 days by default), and typed text and page scripts appear only as their length.",
                flags: [
                    ("--limit <n>", "How many entries (default 50, at most 1000)"),
                    ("--since <time>", "Only newer entries: a duration (30m, 2h, 7d), a date (2026-11-25, ISO 8601) or ms since 1970"),
                    ("--task <taskId>", "Only the entries of this task (the taskId 'start' printed)")
                ],
                notes: ["Filters read the log on disk, so they reach back past the last restart; with the app closed, only the files in ~/Library/Application Support/UseMac/audit/ have it."],
                examples: ["usemac audit", "usemac audit --task task-1a2b3c4d", "usemac audit --since 2h --limit 200 --json"],
                json: "[AuditEntry {id, timestampMs, method, targetApp, summary, latencyMs, success, taskId}]"
            )
        case "serve":
            return CommandHelp(
                usage: ["usemac serve [--socket <path>]"],
                summary: "Run the Unix socket RPC daemon in this process (for testing; UseMac.app normally runs it, with the Kill Switch and execution mode).",
                examples: ["usemac serve --socket /tmp/usemac-test.sock"]
            )
        case "mcp":
            return CommandHelp(
                usage: ["usemac mcp"],
                summary: "Start the stdio MCP server. Register it in your agent's MCP config as {\"command\": \"<path to usemac>\", \"args\": [\"mcp\"]}.",
                examples: ["claude mcp add --scope user usemac -- \"/Applications/UseMac.app/Contents/Helpers/usemac\" mcp"]
            )
        case "install-skill", "skill":
            return CommandHelp(
                usage: ["usemac install-skill [--workspace] [--dir <path>] [--force] [--dry-run]"],
                summary: "Install the usemac SKILL.md, stamped with this Mac's binary and socket path, into every detected agent skills folder.",
                flags: [
                    ("--workspace, -w", "Install into .agents/skills in the current folder"),
                    ("--dir <path>, -d", "Install into this skills folder"),
                    ("--force", "Replace a SKILL.md that does not belong to UseMac"),
                    ("--dry-run", "Show the target paths without writing")
                ],
                examples: ["usemac install-skill"],
                json: "{ok, binary, targets: [{path, status}]}"
            )
        case "bench":
            return CommandHelp(
                usage: ["usemac bench [--iterations <n>] [--app <name>]"],
                summary: "Measure ping, list_apps and observe latency (cold and hot cache).",
                flags: [
                    ("--iterations <n>", "Ping iterations (default 100)"),
                    ("--app <name>", "App to observe")
                ],
                examples: ["usemac bench --app \"Notes\""]
            )
        case "help":
            return CommandHelp(
                usage: ["usemac help [<command> [<subcommand>]]", "usemac <command> --help"],
                summary: "Show the overview, or usage, flags and an example for one command.",
                examples: ["usemac help act", "usemac help browser open"]
            )
        case "version":
            return CommandHelp(
                usage: ["usemac --version"],
                summary: "Print the CLI version.",
                examples: ["usemac --version"]
            )
        default:
            return nil
        }
    }

    private static func printHelp(for path: [String]) throws -> Int32 {
        guard let command = path.first else {
            printUsage()
            return 0
        }
        let key = path.count > 1 ? "\(command) \(path[1])" : command
        guard let help = commandHelp(key) else {
            if path.count > 1, commandHelp(command) != nil {
                throw CLIError.usage("Unknown \(command) subcommand: '\(path[1])'. Run 'usemac help \(command)'.")
            }
            throw CLIError.usage("Unknown command: '\(command)'. Run 'usemac help' to see available commands.")
        }

        var lines: [String] = ["usemac \(key) — \(help.summary)", "", "Usage:"]
        lines.append(contentsOf: help.usage.map { "  \($0)" })
        if !help.flags.isEmpty {
            let isGroup = key == "browser" || key == "vision"
            lines.append("")
            lines.append(isGroup ? "Subcommands:" : "Flags:")
            let width = min(28, help.flags.map(\.0.count).max() ?? 0)
            for (flag, text) in help.flags {
                let padded = flag.count >= width ? flag + "  " : flag.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                lines.append("  \(padded)\(text)")
            }
        }
        if !help.notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: help.notes.map { "  - \($0)" })
        }
        if !help.examples.isEmpty {
            lines.append("")
            lines.append(help.examples.count == 1 ? "Example:" : "Examples:")
            lines.append(contentsOf: help.examples.map { "  \($0)" })
        }
        if let json = help.json {
            lines.append("")
            lines.append("JSON (--json): \(json)")
            lines.append("Errors with --json: {\"ok\":false,\"error\":{\"code\",\"message\",\"hint\"}}. Exit codes: run 'usemac help'.")
        }
        print(lines.joined(separator: "\n"))
        return 0
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
