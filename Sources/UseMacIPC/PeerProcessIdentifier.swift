import Darwin
import Foundation

public struct PeerProcessInfo: Equatable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    public var executablePath: String
    public var arguments: [String]
    public var appBundleName: String?

    public init(pid: pid_t, ppid: pid_t, executablePath: String, arguments: [String], appBundleName: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.executablePath = executablePath
        self.arguments = arguments
        self.appBundleName = appBundleName
    }
}

/// Resolves a display name, not an authenticated identity. Process arguments are never returned or logged.
public enum PeerProcessIdentifier {
    public static func peerPID(forSocketFd fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard Darwin.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == MemoryLayout<pid_t>.size, pid > 0 else { return nil }
        return pid
    }

    public static func resolveAgentName(forSocketFd fd: Int32) -> String? {
        peerPID(forSocketFd: fd).flatMap { resolveAgentName(forPID: $0) }
    }

    public static func resolveAgentName(forPID pid: pid_t) -> String? {
        var chain: [PeerProcessInfo] = []
        var seen: Set<pid_t> = []
        var current = pid
        for _ in 0...12 {
            guard current > 0, seen.insert(current).inserted else { break }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let count = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, infoSize)
            let parent = count == infoSize ? pid_t(exactly: info.pbi_ppid) ?? 0 : 0
            let path = executablePath(for: current) ?? ""
            chain.append(PeerProcessInfo(
                pid: current,
                ppid: parent,
                executablePath: path,
                arguments: processArguments(for: current),
                appBundleName: appBundleName(in: path)
            ))
            current = parent
        }
        return classify(chain: chain)
    }

    /// The chain is ordered from the socket peer outward. Prefer any known agent over a terminal or generic app.
    public static func classify(chain: [PeerProcessInfo]) -> String? {
        let candidates = chain.compactMap { process -> Candidate? in
            let executable = basename(process.executablePath).trimmingCharacters(in: .whitespacesAndNewlines)
            let bundle = process.appBundleName.flatMap { clean(bundleStem($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
                ?? appBundleName(in: process.executablePath).flatMap(clean)
            guard !excludedNames.contains(executable.lowercased()),
                  !excludedNames.contains(bundle?.lowercased() ?? "") else { return nil }
            let names = pathNames(process.executablePath) + invocationNames(for: process, executable: executable)
            return Candidate(executable: executable, bundle: bundle, names: names)
        }
        for candidate in candidates {
            if let agent = candidate.knownAgent { return agent }
        }
        for candidate in candidates {
            if let editor = candidate.editorOrTerminal { return editor }
        }
        if let bundle = candidates.lazy.compactMap(\.bundle).first { return bundle }
        return candidates.lazy.compactMap { candidate in
            let executable = candidate.executable
            return wrapperNames.contains(executable.lowercased()) ? nil : clean(executable)
        }.first
    }

    private static let agents = [
        "claude-code": "Claude Code", "claude": "Claude Code",
        "codex": "Codex", "antigravity": "Antigravity", "cursor": "Cursor",
        "t3-code": "T3 Code", "t3 code": "T3 Code", "openclaw": "OpenClaw",
        "windsurf": "Windsurf", "opencode": "OpenCode", "goose": "Goose",
        "aider": "Aider", "cline": "Cline", "roo-code": "Roo Code", "roocode": "Roo Code",
        "zed": "Zed", "chatgpt": "ChatGPT"
    ]

    private static let editorsAndTerminals = [
        "visual studio code": "VS Code", "code.app": "VS Code",
        "warp": "Warp", "iterm2": "iTerm2", "iterm": "iTerm2", "ghostty": "Ghostty",
        "terminal": "Terminal", "kitty": "kitty", "wezterm": "WezTerm", "alacritty": "Alacritty", "hyper": "Hyper"
    ]

    private static let excludedNames: Set<String> = [
        "usemac", "usemac-cli", "loginwindow", "windowserver", "launchd"
    ]

    private static let wrapperNames: Set<String> = [
        "nc", "ncat", "socat", "sh", "zsh", "bash", "dash", "fish", "csh", "tcsh",
        "env", "sudo", "login", "script", "timeout", "xargs", "nohup", "osascript"
    ]

    private static let scriptLaunchers: Set<String> = [
        "node", "nodejs", "bun", "deno", "npm", "npx", "pnpm", "yarn", "python", "python3",
        "sh", "zsh", "bash", "dash", "fish", "csh", "tcsh"
    ]

    private struct Candidate {
        var executable: String
        var bundle: String?
        var names: [String]

        var knownAgent: String? {
            let bundleKey = bundle?.lowercased()
            if bundleKey == "claude" {
                return names.contains("claude-code") ? "Claude Code" : "Claude"
            }
            if let bundleKey, let agent = agents[bundleKey] { return agent }
            for name in names {
                // The ChatGPT label is reserved for the app bundle.
                if name == "chatgpt.app" { return "ChatGPT" }
                if name != "chatgpt", let agent = agents[bundleStem(name)] { return agent }
            }
            return nil
        }

        var editorOrTerminal: String? {
            if let name = bundle?.lowercased(),
               let editor = editorsAndTerminals[name + ".app"] ?? editorsAndTerminals[name] { return editor }
            return names.lazy.compactMap { editorsAndTerminals[$0] ?? editorsAndTerminals[bundleStem($0)] }.first
        }
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func bundleStem(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func appBundleName(in path: String) -> String? {
        path.split(separator: "/").first { $0.lowercased().hasSuffix(".app") }
            .map { bundleStem(String($0)) }
    }

    private static func pathNames(_ path: String) -> [String] {
        var names = path.lowercased().split(separator: "/").map(String.init)
        if let file = names.last, let suffix = [".js", ".mjs", ".cjs", ".ts", ".py"].first(where: { file.hasSuffix($0) }) {
            names.append(String(file.dropLast(suffix.count)))
        }
        return names
    }

    private static func invocationNames(for process: PeerProcessInfo, executable: String) -> [String] {
        guard let argv0 = process.arguments.first else { return [] }
        let names = pathNames(argv0)
        // Inspect an interpreter's script or module, not its script body, prompts, or later data arguments.
        guard scriptLaunchers.contains(executable.lowercased()) else { return names }
        let program = process.arguments.dropFirst()
            .drop(while: { $0.hasPrefix("--") && $0 != "--" && $0 != "--eval" && $0 != "--print" })
        guard let first = program.first else { return names }
        if first == "--" || first == "-m" {
            return names + (program.dropFirst().first.map(pathNames) ?? [])
        }
        return first.hasPrefix("-") ? names : names + pathNames(first)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro, not imported by Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        return String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8)
    }

    private static func processArguments(for pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        let mibCount = u_int(mib.count)
        var byteCount = 0
        guard sysctl(&mib, mibCount, nil, &byteCount, nil, 0) == 0,
              byteCount > MemoryLayout<Int32>.size, byteCount <= 1024 * 1024 else { return [] }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes {
            sysctl(&mib, mibCount, $0.baseAddress, &byteCount, nil, 0)
        }
        let headerSize = MemoryLayout<Int32>.size
        guard result == 0, byteCount > headerSize, byteCount <= bytes.count else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // argc, saved executable path, NUL padding, then argc NUL-terminated arguments and the environment.
        guard argc > 0, let pathEnd = bytes[headerSize..<byteCount].firstIndex(of: 0),
              var start = bytes[(pathEnd + 1)..<byteCount].firstIndex(where: { $0 != 0 }) else { return [] }
        var arguments: [String] = []
        for _ in 0..<min(Int(argc), 8) {
            guard let end = bytes[start..<byteCount].firstIndex(of: 0) else { break }
            arguments.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end + 1
        }
        return arguments
    }
}
