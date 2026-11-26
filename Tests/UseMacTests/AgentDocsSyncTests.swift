import Foundation
import XCTest
@testable import UseMacProtocol
@testable import UseMacIPC

/// Keeps the hand-written agent docs in sync with the code. The RPC methods, the MCP tools and the error codes
/// are read from the code, and each one must appear, in backticks, in `.agents/AGENTS.md`,
/// `.agents/skills/usemac/SKILL.md` and the README. The method and tool counts the docs state must match, and
/// the exit-code tables in AGENTS.md and `usemac --help` must match the CLI's mapping.
final class AgentDocsSyncTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UseMacTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    private static let agentGuide = ".agents/AGENTS.md"
    private static let skill = ".agents/skills/usemac/SKILL.md"
    private static let readme = "README.md"
    private static let documents = [agentGuide, skill, readme]

    private static let cliSource = "Sources/UseMacCLI/UseMacCLI.swift"

    /// Upper-case string literals in Sources/ and Extension/ that look like error codes but are not.
    /// `USEMAC_…` literals are environment variables and are skipped too.
    /// Upper-case literals the scan finds that are not error codes: the function key names in the extension's
    /// key table (`F1`…`F12`, added with the native key map).
    private static let notErrorCodes: Set<String> = Set((1...12).map { "F\($0)" })

    // MARK: - Every name is documented

    func testEveryRPCMethodIsDocumented() throws {
        let methods = RPCMethod.allCases.map { ($0.rawValue, "RPCMethod.\($0)") }
        try assertDocumented(methods, kind: "RPC methods", where: "with the other methods")
    }

    func testEveryMCPToolIsDocumented() async throws {
        let tools = try await mcpToolNames().map { ($0, "MCP tools/list") }
        XCTAssertFalse(tools.isEmpty, "tools/list returned no tools")
        try assertDocumented(tools, kind: "MCP tools", where: "with the other MCP tools")
    }

    func testEveryErrorCodeIsDocumented() throws {
        let codes = try errorCodesInCode()
        XCTAssertFalse(codes.isEmpty, "Found no error codes in Sources/ or Extension/")
        try assertDocumented(
            codes.map { ($0.code, $0.location) },
            kind: "error codes",
            where: "where the other error codes are listed (if one is not an error code, add it to AgentDocsSyncTests.notErrorCodes)"
        )
    }

    // MARK: - Counts and exit codes

    func testStatedCountsMatchTheCode() async throws {
        let actual = ["methods": RPCMethod.allCases.count, "tools": try await mcpToolNames().count]
        for document in Self.documents {
            for claim in try statedCounts(in: read(document)) {
                guard let count = actual[claim.noun], claim.count != count else { continue }
                XCTFail("\(document) line \(claim.line) says \(claim.count) \(claim.noun), but the code has \(count): \"\(claim.text)\"")
            }
        }

        let readmeNouns = Set(try statedCounts(in: read(Self.readme)).map(\.noun))
        for (noun, count) in actual.sorted(by: { $0.key < $1.key }) where !readmeNouns.contains(noun) {
            XCTFail("\(Self.readme) doesn't state how many \(noun) there are. Write it as \"\(noun) (\(count))\" above the list.")
        }
    }

    func testExitCodeTablesMatchTheCLI() throws {
        let expected = try cliExitCodes()
        XCTAssertFalse(
            expected.isEmpty,
            "Couldn't read the error-code sets of exitCode(forErrorCode:) from \(Self.cliSource). If it changed shape, update cliExitCodes() in this test."
        )

        // AGENTS.md: rows like "| `4` | Blocked by a safety rule (`POLICY_BLOCKED`, …). |"
        var guideRows: [Int: Set<String>] = [:]
        for line in try read(Self.agentGuide).components(separatedBy: .newlines) {
            guard let match = Self.firstMatch(#"^\|\s*`(\d+)`\s*\|(.*)\|\s*$"#, in: line), let exit = Int(match[1]) else { continue }
            guideRows[exit] = Set(Self.matches(#"`([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)`"#, in: match[2]).map { $0[1] })
        }
        compareExitCodes(expected, with: guideRows, in: "the exit-code table of \(Self.agentGuide)")

        // `usemac --help`: lines like "  4  Blocked by a safety rule (POLICY_BLOCKED, …): stop and tell the user"
        var helpRows: [Int: Set<String>] = [:]
        let cli = try read(Self.cliSource)
        let helpBlock = cli.components(separatedBy: "Exit codes:").dropFirst().first ?? ""
        let helpLines = helpBlock.components(separatedBy: .newlines).dropFirst()  // the rest of the "Exit codes:" line
        for line in helpLines.prefix(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            guard let match = Self.firstMatch(#"^\s+(\d+)\s{2,}(.*)$"#, in: line), let exit = Int(match[1]) else { continue }
            helpRows[exit] = Set(Self.matches(#"\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b"#, in: match[2]).map { $0[1] })
        }
        compareExitCodes(expected, with: helpRows, in: "the \"Exit codes:\" help in \(Self.cliSource)")
    }

    // MARK: - Reading the code

    private func mcpToolNames() async throws -> [String] {
        let server = MCPStdioServer(
            socketPath: "/tmp/usemac-docs-sync-\(UUID().uuidString.prefix(8)).sock",
            fallbackService: StubService()
        )
        defer { server.close() }
        let line = await server.processLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let output = try XCTUnwrap(line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    private struct FoundCode {
        let code: String
        let location: String
    }

    /// Every error code the app, the CLI and the Chrome extension can return: upper-case snake-case string
    /// literals (`"URL_BLOCKED"`), plus single-word literals assigned to a code (`code: "CANCELLED"`).
    private func errorCodesInCode() throws -> [FoundCode] {
        let patterns = [
            #"["']([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)["']"#,
            #"\b(?:errorCode|code)\s*(?::|=|==)\s*["']([A-Z][A-Z0-9_]+)["']"#
        ]
        var found: [String: String] = [:]
        for file in try sourceFiles() {
            let lines = try read(file).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                for pattern in patterns {
                    for match in Self.matches(pattern, in: line) {
                        let code = match[1]
                        guard !code.hasPrefix("USEMAC_"), !Self.notErrorCodes.contains(code), found[code] == nil else { continue }
                        found[code] = "\(file):\(index + 1)"
                    }
                }
            }
        }
        return found.map { FoundCode(code: $0.key, location: $0.value) }.sorted { $0.code < $1.code }
    }

    private func sourceFiles() throws -> [String] {
        let fileManager = FileManager.default
        var files: [String] = []
        for (folder, ext) in [("Sources", "swift"), ("Extension", "js")] {
            let root = Self.repoRoot.appendingPathComponent(folder)
            let enumerator = try XCTUnwrap(fileManager.enumerator(atPath: root.path), "Missing \(folder)/")
            var inFolder: [String] = []
            while let relative = enumerator.nextObject() as? String {
                if relative.hasSuffix(".\(ext)") {
                    inFolder.append("\(folder)/\(relative)")
                }
            }
            files += inFolder.sorted()
        }
        return files
    }

    /// Exit code → error codes, read from the sets that `exitCode(forErrorCode:)` in the CLI checks.
    private func cliExitCodes() throws -> [Int: Set<String>] {
        let source = try read(Self.cliSource)
        var sets: [String: Set<String>] = [:]
        for match in Self.matches(#"static let (\w+): Set<String> = \[([^\]]*)\]"#, in: source) {
            sets[match[1]] = Set(Self.matches(#""([A-Z][A-Z0-9_]+)""#, in: match[2]).map { $0[1] })
        }
        guard let start = source.range(of: "func exitCode(forErrorCode code: String) -> Int32 {"),
              let end = source.range(of: "\n    }", range: start.upperBound..<source.endIndex) else {
            return [:]
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        var result: [Int: Set<String>] = [:]
        for match in Self.matches(#"if code == "([A-Z][A-Z0-9_]+)" \{ return (\d+) \}"#, in: body) {
            result[Int(match[2])!, default: []].insert(match[1])
        }
        for match in Self.matches(#"if (\w+)\.contains\(code\) \{ return (\d+) \}"#, in: body) {
            result[Int(match[2])!, default: []].formUnion(sets[match[1]] ?? [])
        }
        return result
    }

    // MARK: - Reading the docs

    private struct CountClaim {
        let noun: String
        let count: Int
        let line: Int
        let text: String
    }

    /// "All 22 methods", "16 MCP tools", "Exposed tools (16)", "Methods (22)".
    private func statedCounts(in text: String) -> [CountClaim] {
        var claims: [CountClaim] = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            for match in Self.matches(#"(?i)\b(\d+)\s+(?:RPC\s+|MCP\s+|socket\s+)?(methods|tools)\b"#, in: line) {
                claims.append(CountClaim(noun: match[2].lowercased(), count: Int(match[1])!, line: index + 1, text: match[0]))
            }
            for match in Self.matches(#"(?i)\b(methods|tools)\s*\((\d+)\)"#, in: line) {
                claims.append(CountClaim(noun: match[1].lowercased(), count: Int(match[2])!, line: index + 1, text: match[0]))
            }
        }
        return claims
    }

    // MARK: - Assertions

    private func assertDocumented(
        _ names: [(name: String, source: String)],
        kind: String,
        where place: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for document in Self.documents {
            let text = try read(document)
            let missing = names.filter { !text.contains("`\($0.name)`") }
            guard !missing.isEmpty else { continue }
            let list = missing.map { "  `\($0.name)` (\($0.source))" }.joined(separator: "\n")
            XCTFail(
                "\(document) is missing \(missing.count) \(kind) that the code defines. Mention each one in backticks \(place):\n\(list)",
                file: file,
                line: line
            )
        }
    }

    private func compareExitCodes(_ expected: [Int: Set<String>], with documented: [Int: Set<String>], in place: String) {
        for exit in expected.keys.sorted() {
            guard let row = documented[exit] else {
                XCTFail("\(place) has no row for exit code \(exit) (\(expected[exit]!.sorted().joined(separator: ", ")))")
                continue
            }
            let missing = expected[exit]!.subtracting(row).sorted()
            let extra = row.subtracting(expected[exit]!).sorted()
            if !missing.isEmpty {
                XCTFail("\(place): the row for exit code \(exit) is missing \(missing.joined(separator: ", ")), which \(Self.cliSource) maps to \(exit)")
            }
            if !extra.isEmpty {
                XCTFail("\(place): the row for exit code \(exit) lists \(extra.joined(separator: ", ")), which \(Self.cliSource) doesn't map to \(exit)")
            }
        }
    }

    // MARK: - Helpers

    private func read(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// All matches of `pattern` in `text`, each as [whole match, group 1, group 2, …].
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            XCTFail("Invalid pattern \(pattern)")
            return []
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { result in
            (0..<result.numberOfRanges).map { index in
                let range = result.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        matches(pattern, in: text).first
    }
}
