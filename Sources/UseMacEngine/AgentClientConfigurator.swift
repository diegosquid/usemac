import Darwin
import Foundation

public enum AgentClientID: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "Claude Code"
    case claudeDesktop = "Claude Desktop"
    case cursor = "Cursor"
    case codex = "Codex"
    case antigravity = "Antigravity"

    public var id: Self { self }

    private static let claudeSupport = "Library/Application Support/Claude"

    public var configRelativePath: String {
        switch self {
        case .claudeCode: ".claude.json"
        case .claudeDesktop: "\(Self.claudeSupport)/claude_desktop_config.json"
        case .cursor: ".cursor/mcp.json"
        case .codex: ".codex/config.toml"
        case .antigravity: ".gemini/antigravity/mcp_config.json"
        }
    }

    private var appName: String? {
        switch self {
        case .claudeCode: nil
        case .claudeDesktop: "Claude.app"
        case .cursor: "Cursor.app"
        case .codex: "Codex.app"
        case .antigravity: "Antigravity.app"
        }
    }

    fileprivate var skillRelativePath: String? {
        switch self {
        case .claudeCode: ".claude/skills/usemac"
        case .claudeDesktop: nil
        case .cursor: ".cursor/skills/usemac"
        case .codex: ".codex/skills/usemac"
        case .antigravity: ".gemini/antigravity/skills/usemac"
        }
    }

    fileprivate func isInstalled(in environment: AgentClientConfigurator.Environment) -> Bool {
        let files = FileManager.default
        let home = environment.homeDirectory

        if let appName,
           [environment.applicationsDirectory, home.appendingPathComponent("Applications")].contains(where: {
               files.fileExists(atPath: $0.appendingPathComponent(appName).path)
           }) {
            return true
        }

        let markers: [String]
        switch self {
        case .claudeCode:
            if environment.claudeBinaryCandidates.contains(where: { binary in
                var info = stat()
                return stat(binary.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                    && files.isExecutableFile(atPath: binary.path)
            }) {
                return true
            }
            markers = [".claude", configRelativePath]
        case .claudeDesktop: markers = [Self.claudeSupport]
        case .cursor: markers = [".cursor"]
        case .codex: markers = [".codex"]
        case .antigravity: markers = [".gemini/antigravity"]
        }

        return markers.contains { marker in
            // Count dangling links as markers, too, so Quick Setup can explain why it won't use them.
            var info = stat()
            return lstat(home.appendingPathComponent(marker).path, &info) == 0
        }
    }
}

public struct AgentClientStatus: Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case configured, needsUpdate, notConfigured, notInstalled
    }

    public let client: AgentClientID
    public let isInstalled: Bool
    public let state: State
    public let configPath: URL
    /// Client-specific SKILL.md (the universal copy is also checked for skill-capable clients).
    public let skillPath: URL?
    public let detail: String

    public var id: AgentClientID { client }
}

/// Quick Setup is a native UI action; none of these writes are exposed over RPC, MCP or the CLI.
public struct AgentClientConfigurator: Sendable {
    public struct Environment: Sendable {
        public let homeDirectory: URL
        public let applicationsDirectory: URL
        public let claudeBinaryCandidates: [URL]

        public init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
            claudeBinaryCandidates: [URL]? = nil
        ) {
            self.homeDirectory = homeDirectory
            self.applicationsDirectory = applicationsDirectory
            self.claudeBinaryCandidates = claudeBinaryCandidates ?? [
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
                homeDirectory.appendingPathComponent(".local/bin/claude")
            ]
        }
    }

    private static let setupLock = NSLock()
    private let environment: Environment
    private let files: AgentSetupFiles

    public init(environment: Environment = .init()) {
        self.environment = environment
        self.files = AgentSetupFiles(root: environment.homeDirectory)
    }

    public func inspectAll(cliPath: String, socketPath: String, agentDocsDir: URL) -> [AgentClientStatus] {
        let setup = Setup(cliPath: cliPath, socketPath: socketPath, agentDocsDir: agentDocsDir)
        return Self.setupLock.withLock {
            AgentClientID.allCases.map { inspect($0, setup: setup) }
        }
    }

    @discardableResult
    public func configure(
        client: AgentClientID,
        cliPath: String,
        socketPath: String,
        agentDocsDir: URL,
        confirmedBy click: ApprovalInputCheck.PhysicalClick
    ) throws -> AgentClientStatus {
        let setup = Setup(cliPath: cliPath, socketPath: socketPath, agentDocsDir: agentDocsDir)
        return try Self.setupLock.withLock {
            try apply(client, setup: setup)
        }
    }

    public func configureAllDetected(
        cliPath: String,
        socketPath: String,
        agentDocsDir: URL,
        confirmedBy click: ApprovalInputCheck.PhysicalClick
    ) -> [(client: AgentClientID, result: Result<AgentClientStatus, Error>)] {
        let setup = Setup(cliPath: cliPath, socketPath: socketPath, agentDocsDir: agentDocsDir)
        return Self.setupLock.withLock {
            AgentClientID.allCases
                .filter { $0.isInstalled(in: environment) }
                .map { client in (client, Result { try apply(client, setup: setup) }) }
        }
    }

    private struct Setup {
        let cliPath: String
        let socketPath: String
        let agentDocsDir: URL
    }

    private struct Change {
        let path: String
        let original: Data?
        let updated: Data
    }

    private struct Plan {
        var hasServer: Bool
        var changes: [Change] = []
    }

    private func inspect(_ client: AgentClientID, setup: Setup) -> AgentClientStatus {
        guard client.isInstalled(in: environment) else {
            return status(client, .notInstalled, detail: "This client wasn’t found on this Mac.")
        }
        do {
            let plan = try plan(for: client, setup: setup)
            if plan.changes.isEmpty {
                return configured(client)
            }
            return plan.hasServer
                ? status(client, .needsUpdate, detail: "UseMac’s MCP settings or skill need an update.")
                : status(client, .notConfigured, detail: "The UseMac MCP server hasn’t been added.")
        } catch {
            return status(client, .needsUpdate, detail: error.localizedDescription)
        }
    }

    private func apply(_ client: AgentClientID, setup: Setup) throws -> AgentClientStatus {
        guard client.isInstalled(in: environment) else {
            throw AgentSetupError("\(client.rawValue) wasn’t found on this Mac.")
        }
        // Check every destination before changing anything. In particular, a bad skill must not leave a new MCP entry.
        let plan = try plan(for: client, setup: setup)
        for change in plan.changes {
            try files.replace(change.path, original: change.original, with: change.updated)
        }
        return configured(client)
    }

    private func configured(_ client: AgentClientID) -> AgentClientStatus {
        status(client, .configured, detail: client.skillRelativePath == nil
               ? "The UseMac MCP server is configured."
               : "The UseMac MCP server and skill are configured.")
    }

    private func status(_ client: AgentClientID, _ state: AgentClientStatus.State, detail: String) -> AgentClientStatus {
        AgentClientStatus(
            client: client,
            isInstalled: state != .notInstalled,
            state: state,
            configPath: environment.homeDirectory.appendingPathComponent(client.configRelativePath),
            skillPath: client.skillRelativePath.map { environment.homeDirectory.appendingPathComponent("\($0)/SKILL.md") },
            detail: detail
        )
    }

    private func plan(for client: AgentClientID, setup: Setup) throws -> Plan {
        let path = client.configRelativePath
        let original = try files.read(path)
        let config: ConfigUpdate
        if client == .codex {
            config = try CodexMCPConfiguration.update(original, cliPath: setup.cliPath, path: path)
        } else {
            config = try jsonUpdate(original, cliPath: setup.cliPath, path: path)
        }

        var plan = Plan(hasServer: config.hasServer)
        if config.updated != nil, let original {
            let backupPath = path + ".usemac.bak"
            let backup = try files.read(backupPath)
            plan.changes.append(Change(path: backupPath, original: backup, updated: original))
        }

        if let skill = client.skillRelativePath {
            try addSkills(at: [skill, ".agents/skills/usemac"], setup: setup, to: &plan)
        }
        if let updated = config.updated {
            plan.changes.append(Change(path: path, original: original, updated: updated))
        }
        return plan
    }

    private func addSkills(at destinations: [String], setup: Setup, to plan: inout Plan) throws {
        let bundle = AgentSetupFiles(root: setup.agentDocsDir)
        func stamp(_ path: String) throws -> Data {
            guard let data = try bundle.read("skills/usemac/\(path)"), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                throw AgentSetupError("The bundled UseMac skill file \(path) is missing or is not valid UTF-8.")
            }
            return Data(text
                .replacingOccurrences(of: "{{USEMAC_BIN}}", with: setup.cliPath)
                .replacingOccurrences(of: "{{USEMAC_SOCKET}}", with: setup.socketPath)
                .utf8)
        }

        let skill = try stamp("SKILL.md")
        let reference = try stamp("references/REFERENCE.md")
        for destination in destinations {
            let skillPath = "\(destination)/SKILL.md"
            let existingSkill = try files.read(skillPath)
            if let existingSkill, !Self.isUseMacSkill(existingSkill) {
                throw AgentSetupError("Not replacing ~/\(skillPath): its frontmatter does not identify it as the UseMac skill.")
            }
            if existingSkill != skill {
                plan.changes.append(Change(path: skillPath, original: existingSkill, updated: skill))
            }
            let referencePath = "\(destination)/references/REFERENCE.md"
            let existingReference = try files.read(referencePath)
            if existingReference != reference {
                plan.changes.append(Change(path: referencePath, original: existingReference, updated: reference))
            }
        }
    }

    private static func isUseMacSkill(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return false }
        let nameLines = lines[1..<end].filter { $0.hasPrefix("name:") }
        return nameLines.count == 1 && nameLines[0].dropFirst("name:".count)
            .trimmingCharacters(in: .whitespaces) == "usemac"
    }

    private func jsonUpdate(_ original: Data?, cliPath: String, path: String) throws -> ConfigUpdate {
        var document: [String: Any] = [:]
        if let original, !original.isEmpty {
            guard let dictionary = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
                throw AgentSetupError("~/\(path) contains invalid JSON or is not a JSON object. Nothing was overwritten.")
            }
            document = dictionary
        }

        if let servers = document["mcpServers"], !(servers is [String: Any]) {
            throw AgentSetupError("~/\(path) has an invalid mcpServers setting: it must be a JSON object. Nothing was overwritten.")
        }
        var servers = document["mcpServers"] as? [String: Any] ?? [:]
        let existing = servers["usemac"] as? [String: Any]
        let matches = existing?.count == 2 && existing?["command"] as? String == cliPath
            && existing?["args"] as? [String] == ["mcp"]
        if matches {
            return ConfigUpdate(hasServer: true, updated: nil)
        }

        let hasServer = servers["usemac"] != nil
        servers["usemac"] = ["command": cliPath, "args": ["mcp"]]
        document["mcpServers"] = servers
        let updated = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return ConfigUpdate(hasServer: hasServer, updated: updated)
    }
}

private struct ConfigUpdate {
    let hasServer: Bool
    let updated: Data?
}

private struct AgentSetupError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Use directory-relative operations so a swapped directory or symlink cannot redirect an approved write.
/// The final rename gives the same atomic replacement as Data.write(.atomic), without resolving the path again.
private struct AgentSetupFiles {
    let root: URL

    func read(_ path: String) throws -> Data? {
        try withParent(of: path, create: false) { directory, name in
            try read(name, in: directory, path: path)
        } ?? nil
    }

    func replace(_ path: String, original: Data?, with data: Data) throws {
        try withParent(of: path, create: true) { directory, name in
            guard try read(name, in: directory, path: path) == original else {
                throw AgentSetupError("~/\(path) changed during setup. Try again to keep the latest changes.")
            }

            let temp = ".usemac-\(UUID().uuidString).tmp"
            let output = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw ioError(path, errno) }
            defer {
                close(output)
                unlinkat(directory, temp, 0)
            }
            let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()

            // Don't replace a changed config, including a swapped symlink, while staging the write.
            guard try read(name, in: directory, path: path) == original else {
                throw AgentSetupError("~/\(path) changed during setup. Try again to keep the latest changes.")
            }
            guard renameat(directory, temp, directory, name) == 0 else { throw ioError(path, errno) }
        }
    }

    private func withParent<T>(
        of path: String, create: Bool, _ operation: (Int32, String) throws -> T
    ) throws -> T? {
        let components = path.split(separator: "/").map(String.init)
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = open(root.path, flags)
        if current < 0 {
            let reason = errno
            if reason == ENOENT && !create { return nil }
            throw ioError(root.path, reason)
        }
        defer { close(current) }

        var traversed: [String] = []
        for component in components.dropLast() {
            traversed.append(component)
            let relativePath = traversed.joined(separator: "/")
            switch try fileType(component, in: current, path: relativePath) {
            case nil:
                guard create else { return nil }
                if mkdirat(current, component, 0o700) != 0 && errno != EEXIST {
                    throw ioError(relativePath, errno)
                }
            case S_IFDIR: break
            default: throw AgentSetupError("~/\(relativePath) is not a directory.")
            }
            let next = openat(current, component, flags)
            guard next >= 0 else { throw ioError(relativePath, errno) }
            close(current)
            current = next
        }

        return try operation(current, components[components.count - 1])
    }

    private func read(_ name: String, in directory: Int32, path: String) throws -> Data? {
        switch try fileType(name, in: directory, path: path) {
        case nil: return nil
        case S_IFREG: break
        default: throw AgentSetupError("~/\(path) is not a regular file.")
        }

        // Non-blocking also protects against a FIFO swapped in after the lstat-equivalent check.
        let input = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw ioError(path, errno) }
        defer { close(input) }

        var info = stat()
        guard fstat(input, &info) == 0 else { throw ioError(path, errno) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw AgentSetupError("~/\(path) is not a regular file.")
        }
        return try FileHandle(fileDescriptor: input, closeOnDealloc: false).readToEnd() ?? Data()
    }

    private func fileType(_ name: String, in directory: Int32, path: String) throws -> mode_t? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            let reason = errno
            if reason == ENOENT { return nil }
            throw ioError(path, reason)
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw AgentSetupError("Not using ~/\(path): it is a symbolic link.") }
        return type
    }

    private func ioError(_ path: String, _ code: Int32) -> AgentSetupError {
        let displayPath = path.hasPrefix("/") ? path : "~/" + path
        let reason = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        return AgentSetupError("Couldn’t access \(displayPath): \(reason)")
    }
}

/// Edits just Codex’s UseMac table. The lexer keeps source ranges so everything outside the table stays byte-for-byte
/// intact, including headers inside multi-line strings. Only the table being replaced needs its values parsed.
private enum CodexMCPConfiguration {
    private static let section = ["mcp_servers", "usemac"]
    private static let lexer = try! NSRegularExpression(pattern: #"""
        (?x)
        """(?:(?!""")[^\\]|\\[\s\S])*"{3,5}
        | '''(?:(?!''')[\s\S])*'{3,5}
        | "(?!"")(?:[^"\\\r\n]|\\[^\r\n])*"
        | '(?!'')[^'\r\n]*'
        | """ | '''
        | \x23[^\r\n]* | \r?\n | [\t\x20]+ | [\[\]{},.=]
        | [^\s\[\]{},.="'\x23]+ | (?s:.)
        """#)
    private static let bareKey = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9_-]+\z"#)
    private static let scalar = try! NSRegularExpression(pattern: #"""
        (?x) \A (?:
            true | false | [+-]?(?:inf|nan)
            | 0(?:x[0-9a-fA-F](?:_?[0-9a-fA-F])*|o[0-7](?:_?[0-7])*|b[01](?:_?[01])*)
            | [+-]?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?
            | [0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})?)?
            | [0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?
        ) \z
        """#)

    private struct Token {
        let text: String
        let range: NSRange

        var isLineBreak: Bool { text == "\n" || text == "\r\n" }
        var isComment: Bool { text.hasPrefix("#") }
        var isString: Bool { text.hasPrefix("\"") || text.hasPrefix("'") }
        var isMultiline: Bool { text.hasPrefix("\"\"\"") || text.hasPrefix("'''") }
    }

    private struct Line {
        let start: Int
        let end: Int
        let tokens: [Token]
        let lineEnding: String?
    }

    private struct InvalidSyntax: Error {}

    static func update(_ original: Data?, cliPath: String, path: String) throws -> ConfigUpdate {
        guard let text = String(data: original ?? Data(), encoding: .utf8) else {
            throw invalidConfig(path)
        }
        do {
            return try update(text, cliPath: cliPath)
        } catch is InvalidSyntax {
            throw invalidConfig(path)
        }
    }

    private static func invalidConfig(_ path: String) -> AgentSetupError {
        AgentSetupError("~/\(path) contains invalid or conflicting TOML for the UseMac MCP server. Nothing was overwritten.")
    }

    private static func update(_ text: String, cliPath: String) throws -> ConfigUpdate {
        let source = text as NSString
        let lines = try tokenize(source)
        let newline = lines.compactMap(\.lineEnding).first ?? "\n"
        let settings = "command = \(escaped(cliPath))\(newline)args = [\"mcp\"]\(newline)"
        var headerIndex: Int?
        var bodyEnd = lines.count
        var activeTable: [String] = []
        var nesting = 0

        for (index, line) in lines.enumerated() {
            let tokens = line.tokens.filter { !$0.isComment }
            if nesting == 0, tokens.first?.text == "[" {
                var header = Reader(source: source, tokens: tokens)
                if let table = try? header.tableHeader() {
                    if table.key == section {
                        guard !table.isArray, headerIndex == nil else { throw InvalidSyntax() }
                        headerIndex = index
                    } else if headerIndex != nil && bodyEnd == lines.count {
                        bodyEnd = index
                    }
                    if table.key.starts(with: section),
                       ["command", "args"].contains(table.key.dropFirst(section.count).first ?? "") {
                        throw InvalidSyntax()
                    }
                    activeTable = table.key
                    continue
                }
                if tokens.contains(where: { $0.text.contains("mcp_servers") })
                    && tokens.contains(where: { $0.text.contains("usemac") }) {
                    throw InvalidSyntax()
                }
            } else if nesting == 0 {
                var assignment = Reader(source: source, tokens: tokens)
                if let key = try? assignment.key(), assignment.take("=") {
                    let fullKey = activeTable + key
                    if (activeTable.isEmpty || activeTable == ["mcp_servers"])
                        && (fullKey.starts(with: section) || section.starts(with: fullKey)) {
                        throw InvalidSyntax()
                    }
                }
            }
            for token in tokens {
                switch token.text {
                case "[", "{": nesting += 1
                case "]", "}": nesting = max(0, nesting - 1)
                default: break
                }
            }
        }

        guard let headerIndex else {
            // Appending inside an unterminated array or inline table would not create an MCP table.
            guard nesting == 0 else { throw InvalidSyntax() }
            let separator: String
            if text.isEmpty || text.hasSuffix(newline + newline) {
                separator = ""
            } else {
                separator = text.utf8.last == 10 ? newline : newline + newline
            }
            let output = text + separator + "[mcp_servers.usemac]" + newline + settings
            return ConfigUpdate(hasServer: false, updated: Data(output.utf8))
        }

        let header = lines[headerIndex]
        let body = lines[(headerIndex + 1)..<bodyEnd]
        var reader = Reader(source: source, tokens: body.flatMap { line in
            let terminator = line.lineEnding.map { [Token(text: $0, range: NSRange(location: 0, length: 0))] } ?? []
            return line.tokens + terminator
        })
        let values = try reader.assignments()
        if values.count == 2, values[["command"]] == .string(cliPath), values[["args"]] == .array([.string("mcp")]) {
            return ConfigUpdate(hasServer: true, updated: nil)
        }

        let suffixStart = bodyEnd < lines.count ? lines[bodyEnd].start : source.length
        var output = source.substring(to: header.end)
        if header.lineEnding == nil { output += newline }
        output += settings
        for line in body {
            if line.tokens.isEmpty || line.tokens.first?.isComment == true {
                output += source.substring(with: NSRange(location: line.start, length: line.end - line.start))
            } else if let comment = line.tokens.last, comment.isComment {
                output += comment.text + (line.lineEnding ?? "")
            }
        }
        output += source.substring(from: suffixStart)
        return ConfigUpdate(hasServer: true, updated: Data(output.utf8))
    }

    private static func tokenize(_ source: NSString) throws -> [Line] {
        let range = NSRange(location: 0, length: source.length)
        var lines: [Line] = []
        var tokens: [Token] = []
        var lineStart = 0
        for match in lexer.matches(in: source as String, range: range) {
            let text = source.substring(with: match.range)
            let token = Token(text: text, range: match.range)
            if token.isLineBreak {
                let end = NSMaxRange(match.range)
                lines.append(Line(start: lineStart, end: end, tokens: tokens, lineEnding: text))
                tokens.removeAll()
                lineStart = end
            } else if text == "\"\"\"" || text == "'''" {
                // Unclosed strings make it ambiguous whether following lines are even headers.
                throw InvalidSyntax()
            } else if !text.allSatisfy({ $0 == " " || $0 == "\t" }),
                      !(match.range.location == 0 && text == "\u{feff}") {
                tokens.append(token)
            }
        }
        if lineStart < source.length {
            lines.append(Line(start: lineStart, end: source.length, tokens: tokens, lineEnding: nil))
        }
        return lines
    }

    private static func escaped(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{0}"..."\u{1f}", "\u{7f}": output += String(format: "\\u%04X", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    private enum Value: Equatable {
        case string(String)
        case array([Value])
        case other
    }

    private struct Reader {
        let source: NSString
        let tokens: [Token]
        private var index = 0

        init(source: NSString, tokens: [Token]) {
            self.source = source
            self.tokens = tokens
        }

        private var next: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func take(_ expected: String) -> Bool {
            guard next?.text == expected else { return false }
            index += 1
            return true
        }

        mutating func key() throws -> [String] {
            var parts: [String] = []
            repeat {
                guard let token = next else { throw InvalidSyntax() }
                if token.isString && !token.isMultiline {
                    parts.append(try string(token))
                } else {
                    guard Self.matches(token.text, bareKey) else { throw InvalidSyntax() }
                    parts.append(token.text)
                }
                index += 1
            } while take(".")
            return parts
        }

        mutating func tableHeader() throws -> (key: [String], isArray: Bool) {
            guard take("[") else { throw InvalidSyntax() }
            let isArray = take("[")
            let name = try key()
            guard take("]"), !isArray || take("]"), next == nil else { throw InvalidSyntax() }
            return (name, isArray)
        }

        mutating func assignments() throws -> [[String]: Value] {
            var values: [[String]: Value] = [:]
            skipLineTrivia()
            while next != nil {
                let name = try key()
                guard take("="), !values.keys.contains(where: { $0.starts(with: name) || name.starts(with: $0) })
                else { throw InvalidSyntax() }
                values[name] = try value()
                if next?.isComment == true { index += 1 }
                guard next == nil || next?.isLineBreak == true else { throw InvalidSyntax() }
                skipLineTrivia()
            }
            return values
        }

        private mutating func skipLineTrivia() {
            while let token = next, token.isComment || token.isLineBreak { index += 1 }
        }

        private mutating func value(depth: Int = 0) throws -> Value {
            // A damaged file must not be able to exhaust the stack during inspection.
            guard depth < 128, let token = next else { throw InvalidSyntax() }
            if token.isString {
                index += 1
                return .string(try string(token))
            }
            if take("[") {
                var items: [Value] = []
                skipLineTrivia()
                while !take("]") {
                    items.append(try value(depth: depth + 1))
                    skipLineTrivia()
                    if take("]") { break }
                    guard take(",") else { throw InvalidSyntax() }
                    skipLineTrivia()
                }
                return .array(items)
            }
            if take("{") {
                if take("}") { return .other }
                var keys: [[String]] = []
                repeat {
                    let name = try key()
                    guard take("="), !keys.contains(where: { $0.starts(with: name) || name.starts(with: $0) })
                    else { throw InvalidSyntax() }
                    keys.append(name)
                    _ = try value(depth: depth + 1)
                } while take(",")
                guard take("}") else { throw InvalidSyntax() }
                return .other
            }

            guard !token.isLineBreak else { throw InvalidSyntax() }
            let start = token.range.location
            var end = start
            while let part = next, !part.isLineBreak, !part.isComment, ![",", "]", "}"].contains(part.text) {
                end = NSMaxRange(part.range)
                index += 1
            }
            let atom = source.substring(with: NSRange(location: start, length: end - start))
            guard Self.matches(atom, scalar) else { throw InvalidSyntax() }
            return .other
        }

        private static func matches(_ text: String, _ regex: NSRegularExpression) -> Bool {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
        }

        private func string(_ token: Token) throws -> String {
            let delimiterCount = token.isMultiline ? 3 : 1
            let raw = token.text.unicodeScalars
            guard raw.count >= delimiterCount * 2 else { throw InvalidSyntax() }
            var body = raw.dropFirst(delimiterCount).dropLast(delimiterCount)
            if token.isMultiline {
                if body.starts(with: "\r\n".unicodeScalars) {
                    body = body.dropFirst(2)
                } else if body.first == "\n" {
                    body = body.dropFirst()
                }
            }
            let literal = token.text.hasPrefix("'")
            let scalars = Array(body)
            var output = ""
            var offset = 0

            while offset < scalars.count {
                let character = scalars[offset]
                offset += 1
                if character == "\\", !literal {
                    let afterSlash = offset
                    while offset < scalars.count, scalars[offset] == " " || scalars[offset] == "\t" { offset += 1 }
                    if token.isMultiline, offset < scalars.count, scalars[offset] == "\r" || scalars[offset] == "\n" {
                        while offset < scalars.count, [" ", "\t", "\r", "\n"].contains(scalars[offset]) { offset += 1 }
                        continue
                    }
                    offset = afterSlash
                    guard offset < scalars.count else { throw InvalidSyntax() }
                    let escape = scalars[offset]
                    offset += 1
                    switch escape {
                    case "b": output += "\u{8}"
                    case "t": output += "\t"
                    case "n": output += "\n"
                    case "f": output += "\u{c}"
                    case "r": output += "\r"
                    case "\"", "\\": output.unicodeScalars.append(escape)
                    case "u", "U":
                        let count = escape == "u" ? 4 : 8
                        guard offset + count <= scalars.count else { throw InvalidSyntax() }
                        let hexadecimal = String(String.UnicodeScalarView(scalars[offset..<(offset + count)]))
                        guard hexadecimal.allSatisfy(\.isHexDigit), let number = UInt32(hexadecimal, radix: 16),
                              let decoded = Unicode.Scalar(number) else { throw InvalidSyntax() }
                        output.unicodeScalars.append(decoded)
                        offset += count
                    default: throw InvalidSyntax()
                    }
                } else {
                    let isMultilineBreak = token.isMultiline && (character == "\n"
                        || (character == "\r" && offset < scalars.count && scalars[offset] == "\n"))
                    guard character == "\t" || isMultilineBreak || (character.value >= 0x20 && character.value != 0x7f)
                    else { throw InvalidSyntax() }
                    output.unicodeScalars.append(character)
                }
            }
            return output
        }
    }
}
