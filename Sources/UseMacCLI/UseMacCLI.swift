import Foundation
import Darwin
import Dispatch
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

    enum ExecutionMode: String {
        case daemon
        case inProcess = "in-process"
    }

    struct GlobalOptions {
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
        var agentFlag: String?
        var agentName: String? {
            agentFlag ?? ProcessInfo.processInfo.environment["USEMAC_AGENT"].flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    enum CLIError: Error {
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

    final class ReadOnlyFallbackService: UseMacServiceProtocol {
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

    final class SignalGate: @unchecked Sendable {
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
        .browserBatch,
        .appMenu,
        .skillSave,
        .skillRun,
        .setPolicy,
        .pairApp,
        .browserReloadExtension,
        .reportPrepare,
        .debugCapture
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
        "TARGET_BLOCKED",
        "DEBUG_CAPTURE_OFF"
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

    static let batchActionAllowedKeys: [String] = [
        "allowStaleSnapshot",
        "app",
        "diffCrop",
        "expectWindowTitle",
        "foreground",
        "foregroundFallback",
        "includeScreenshot",
        "includeTables",
        "includeText",
        "maxElements",
        "observationMode",
        "returnDiffOnly",
        "returnImageContent",
        "returnObservation",
        "steps",
        "stopOnError",
        "verify",
        "waitForIdleMs",
        "waitForLeaseMs",
        "window"
    ]

    /// Flags shared by every command that sends an `act` batch.
    static let batchValueFlags: Set<String> = ["--app", "--expect-title", "--window", "--mode", "--verify", "--max-elements", "--wait-for-lease"]
    static let batchBoolFlags: Set<String> = ["--foreground", "--foreground-fallback", "--allow-stale", "--diff-crop", "--diff-only"]

    private static func exitCode(forErrorCode code: String) -> Int32 {
        if code == "DAEMON_REQUIRED" { return 3 }
        if policyBlockCodes.contains(code) { return 4 }
        if screenChangedCodes.contains(code) { return 5 }
        if focusCodes.contains(code) { return 6 }
        if wrongRouteCodes.contains(code) { return 7 }
        return 1
    }

    /// The code of the first failed step, which decides the exit code of a failed batch.
    static func firstFailureCode(_ result: BatchActionResult) -> String? {
        result.stepResults.first(where: { !$0.success && ($0.errorCode?.isEmpty == false) })?.errorCode
    }

    static func exitCode(for result: BatchActionResult) -> Int32 {
        if result.success { return 0 }
        return firstFailureCode(result).map(exitCode(forErrorCode:)) ?? 1
    }

    static let browserActAllowedKeys: [String] = [
        "dialogAction",
        "dialogPromptText",
        "diffCrop",
        "includeTables",
        "includeText",
        "maxElements",
        "observationMode",
        "profile",
        "readOnly",
        "returnDiffOnly",
        "returnImageContent",
        "returnObservation",
        "steps",
        "stopOnError",
        "tabId",
        "verify",
        "waitForLeaseMs"
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
                let isGroup = command == "browser" || command == "vision" || command == "debug" || command == "skill"
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
            case "menu":
                return try await handleMenu(args: rest, options: options)
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
            case "skill":
                if rest.isEmpty || (rest.first?.hasPrefix("-") == true) {
                    return try handleInstallSkill(args: rest, options: options)
                }
                return try await handleSkill(args: rest, options: options)
            case "start":
                return try await handleTaskStart(args: rest, options: options)
            case "done", "complete", "stop":
                return try await handleTaskComplete(args: rest, options: options)
            case "audit":
                return try await handleAudit(args: rest, options: options)
            case "report":
                return try await handleReport(args: rest, options: options)
            case "debug":
                return try await handleDebug(args: rest, options: options)
            case "serve":
                return try await handleServe(options: options)
            case "mcp":
                return await handleMCP(options: options)
            case "install-skill":
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
            case "--agent":
                guard i + 1 < args.count else {
                    throw CLIError.usage("Missing name after --agent.")
                }
                options.agentFlag = args[i + 1]
                i += 2
            default:
                if arg.hasPrefix("--socket=") {
                    options.socketPath = String(arg.dropFirst("--socket=".count))
                    i += 1
                } else if arg.hasPrefix("--task=") {
                    options.taskFlag = String(arg.dropFirst("--task=".count))
                    i += 1
                } else if arg.hasPrefix("--agent=") {
                    options.agentFlag = String(arg.dropFirst("--agent=".count))
                    i += 1
                } else {
                    remaining.append(arg)
                    i += 1
                }
            }
        }

        return remaining
    }

    static func parseAppAndExtras(
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

    static func parseOptionalInt(
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

    static func parseOptionalDouble(
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

    static func parseObservationMode(
        _ values: [String: String],
        flag: String = "--mode"
    ) throws -> ObservationMode? {
        guard let raw = values[flag] else { return nil }
        guard let mode = ObservationMode(rawValue: raw) else {
            throw CLIError.usage("\(flag) expects one of: auto, delta, interactive, full, none.")
        }
        return mode
    }

    // MARK: - RPC Execution

    static func executeRPC(
        _ request: RPCRequest,
        options: GlobalOptions,
        timeoutMs: Int = 10000
    ) async throws -> (response: RPCResponse, roundTripMs: Double, mode: ExecutionMode) {
        var request = request
        if request.taskId == nil, request.method != .taskStart {
            request.taskId = options.taskId
        }
        request.agent = request.agent ?? options.agentName
        if request.method == .taskStart, request.taskStart?.agent == nil {
            request.taskStart?.agent = options.agentName
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
        let waitMs = timeoutMs + ApprovalTiming.clientAllowanceMs(for: request.method) + request.effectiveWaitForLeaseMs
        let client = UnixSocketClient(socketPath: options.socketPath, timeoutMs: waitMs, keepAlive: false)
        defer { client.close() }
        do {
            let (response, rttMs) = try client.send(request)
            return (response, rttMs, .daemon)
        } catch let error as UnixSocketClientError {
            switch error {
            case .connectionFailed, .socketCreationFailed, .pathTooLong:
                break
            default:
                throw error
            }
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

    // MARK: - Benchmark

    private static func handleBench(args: [String], options: GlobalOptions) async throws -> Int32 {
        let parsed = try parseAppAndExtras(args: args, valueFlags: ["--iterations", "--app"])
        let iterations = try parseOptionalInt(parsed.values, flag: "--iterations", positive: true) ?? 100
        let agent = options.agentName

        var ephemeralServer: UnixSocketServer?
        let benchSocketPath: String
        let mode: ExecutionMode
        let client: UnixSocketClient

        let daemonClient = UnixSocketClient(socketPath: options.socketPath, timeoutMs: 10000, keepAlive: true)
        if !options.standalone && daemonClient.ensureConnected() {
            benchSocketPath = options.socketPath
            mode = .daemon
            client = daemonClient
        } else {
            daemonClient.close()
            if options.requireDaemon {
                throw CLIError.daemonRequired("The UseMac daemon is not reachable at \(options.socketPath) (--require-daemon is set).")
            }
            benchSocketPath = "/tmp/usemac-bench-\(getpid()).sock"
            let service = UseMacEngineService(socketPath: benchSocketPath)
            let server = UnixSocketServer(socketPath: benchSocketPath, service: service, onClientCountChange: nil)
            try server.start()
            ephemeralServer = server
            mode = .inProcess
            client = UnixSocketClient(socketPath: benchSocketPath, timeoutMs: 10000, keepAlive: true)
        }

        defer {
            client.close()
            if let server = ephemeralServer {
                server.stop()
                try? FileManager.default.removeItem(atPath: benchSocketPath)
            }
        }

        // Warmup connection
        _ = try client.send(RPCRequest(method: .ping, agent: agent))

        // 1. Ping benchmark
        var pingRttsMs: [Double] = []
        pingRttsMs.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let (res, rttMs) = try client.send(RPCRequest(method: .ping, agent: agent))
            if res.ok {
                pingRttsMs.append(rttMs)
            }
        }
        let pingStats = computeStats(pingRttsMs)

        // 2. list_apps benchmark (20 iterations)
        var appsRttsMs: [Double] = []
        appsRttsMs.reserveCapacity(20)
        for _ in 0..<20 {
            let (res, rttMs) = try client.send(RPCRequest(method: .listApps, agent: agent))
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
            observe: ObserveParams(app: targetApp, useCache: false, includeDiff: false, includeScreenshot: false),
            agent: agent
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
                    observe: ObserveParams(app: targetApp, useCache: true, includeDiff: true, includeScreenshot: false),
                    agent: agent
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

    static func validateTopLevelKeys(in data: Data, allowedKeys: [String]) throws {
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

    static func formatDecodingError(_ error: Error) -> String {
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

    static func parseKeyChord(_ chord: String) -> (modifiers: [String], key: String) {
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

    static func ensureOK(_ response: RPCResponse) throws {
        if !response.ok {
            let code = response.error?.code ?? "rpc_error"
            let message = response.error?.message ?? "Unknown RPC error."
            throw CLIError.rpcFailure(code: code, message: message, hint: response.error?.hint)
        }
    }

    static func printEncodableJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func printJSONObject(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func writeStderr(_ text: String) {
        if let data = text.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    // MARK: - Help

    static func printUsage() {
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
          --agent <name>      The agent making the request (default: $USEMAC_AGENT or automatic detection)

        Commands:
          ping                                       Test socket and engine latency
          status                                     Show daemon status, permissions, and telemetry
          apps                                       List running applications
          observe [--app <n|pid>] [--role <r>] [--text <t>] [--filter-role <r>] [--filter-text <t>] [--max-depth <n>] [--max-elements <n>] [--no-cache] [--no-diff] [--include-offscreen] [--no-offscreen] [--screenshot]
                                                     Capture a compact accessibility snapshot (stable @eN ids)
          find --app <n|pid> [--role <r>] [--text <t>] [--title <t>] [--value <v>] [--exact] [--first] [--max-depth <n>] [--max-elements <n>]
                                                     Search the live accessibility tree with the same rules as act's "match"
          menu [--app <n|pid>] [--query <q>] [--invoke "File > Save"]
                                                     Search or invoke native app menu bar items without stealing focus
          act '<json>'|- [--app <name>] [--foreground] [--foreground-fallback] [--mode <m>] [--diff-crop] [--expect-title <text>] [--allow-stale]
                                                     Execute a BatchActionRequest or [ActionStep]
          click <@eID> [--app <name>]                Click an element by ID
          set <@eID> <text> [--app <name>]           Set the value of an element by ID
          type <text> [--app <name>]                 Type text
          key <chord> [--app <name>]                 Press a key or shortcut (e.g. cmd+shift+p, return)
                                                     (click, set, type and key also take --foreground, --foreground-fallback, --mode, --diff-crop, --expect-title, --allow-stale)
          screenshot [--app <name>] [--max-dim <n>] [--diff-crop] [--base64]
                                                     Capture a window or screen screenshot
          browser status                             List Chrome profiles connected to the extension (version, outdated, source)
          browser tabs [--profile <n>] [--query <q>] List open Chrome tabs with tabId, title, and URL
          browser open <url> [--profile <name>] [--tab <id>] [--same-tab] [--activate] [--new-window] [--auto-dismiss] [--steps '<json>'] [--mode <m>] [--no-stream]
                                                     Open a URL in a background tab, navigate --tab, or open it in a new window
          browser open --tab <id> --activate         Make an existing tab the active tab of its window (for native observe/act)
          browser observe [--profile <n>] [--tab <id>] [--filter-role <r>] [--filter-text <t>] [--max-elements <n>] [--screenshot] [--no-text] [--no-tables]
                                                     Inspect DOM (including cross-origin iframes and Shadow DOM), tables, text, and overlays (@b1..@bN)
          browser extract [auto|tables|text|kpis|network|eval|downloads] [--profile <n>] [--tab <id>] [--selector <css>] [--url-filter <q>] [--expr <js>] [--scan-horizontal] [--scan-vertical] [--max-chars <n>]
                                                     Extract tables/ARIA grids, KPIs, text, network JSON, or JS.
                                                     Downloads lists files per Chrome profile in downloads (not jsonResult); not supported in browser batch.
          browser batch <url1> [<url2> ...] [--profile <n>] [--mode observe|extract] [--auto-dismiss] [--close-after]
                                                     Open and observe/extract multiple URLs in parallel Chrome tabs
          browser screenshot [--profile <n>] [--tab <id>] [--selector <css>] [--element <@bID>] [--full-page] [--diff-crop] [--width <px>] [--height <px>] [--quality <n>]
                                                     Capture the tab or one element at its real size (--width/--height: fit the image in that box)
          browser act '<json>' [--profile <name>] [--tab <id>] [--read-only] [--verify "<condition>"] [--mode <m>] [--diff-crop] [--screenshot]
                                                     Execute BrowserActParams or [ActionStep] in Chrome with optional local verification or screenshot
          browser reload-extension [--profile <n>] [--force]
                                                     Reload the extension so Chrome runs the code now in its folder (stops running browser work)
          skill list|save|run|delete ...             Manage and deterministically replay saved automation skills
          vision status                              Show Local Vision engine status (Apple Vision OCR)
          vision ask|verify|describe|locate|diagnose|ocr ["<text>"] [--profile <n>] [--tab <id>] [--app <n>] [--image <path>] [--selector <css>] [--element <@bID>]
                                                     Ask Apple Vision OCR about the screen (zero cloud image tokens)
          start [--profile <n>] [--tab <id>] [--app <n>] [--summary "<text>"] [--agent <name>]
                                                     Start a task (prints its taskId) keeping the live preview open between steps
          stop|done [--profile <n>] [--tab <id>] [--app <n>] [--summary "<text>"]
                                                     Finish the task with a completion overlay and smoothly close the preview
          audit [--limit <n>] [--since <time>] [--task <taskId>]
                                                     Print the audit log (kept on disk, typed text redacted), newest first
          report --summary "<text>" [--title "<text>"] [--task <taskId>]
                                                     Prepare a problem report the user reviews in UseMac before anything is sent
          debug capture [--window <kinds>] [--frames <n>] [--interval <ms>] [--context] [--margin <pt>] [--out <dir>]
                                                     For developing UseMac: PNGs of UseMac's own windows (the user must turn on Debug capture)
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
          4  Blocked by a safety rule or the user (POLICY_BLOCKED, POLICY_LOCKED, APPROVAL_DENIED, APPROVAL_TIMEOUT, URL_BLOCKED, UPLOAD_BLOCKED, SELF_TARGET_BLOCKED, TARGET_BLOCKED, DEBUG_CAPTURE_OFF): stop and tell the user
          5  The screen is not what you expected (STALE_SNAPSHOT, ELEMENT_NOT_FOUND, WAIT_TIMEOUT): observe again, then retry
          6  Needs the app (and its window) in front, or the user or another task is busy there (TARGET_NOT_FRONTMOST, USER_ACTIVE, TARGET_BUSY): use a background step, or wait and retry
          7  This route cannot reach it (RESTRICTED_PAGE, CAPTURE_TOO_SMALL): switch route (see 'usemac help browser')

        JSON output (--json):
          Success prints the result object itself: observe → WindowSnapshot, find → {"app","count","matches"},
          act/click/set/type/key → BatchActionResult, apps → [AppDescriptor], status → DaemonStatus.
          Errors print {"ok":false,"error":{"code":"…","message":"…","hint":"…"}} to stdout; the exit code is set as above.
          "hint" ("Next:" without --json) says what to do next; for POLICY_BLOCKED it names the execution mode, pause
          or Kill Switch that refused the request, which only the user can change (UseMac → Settings → Safety).
          Run 'usemac help <command>' for that command's fields.
        """)
    }
}
