import CoreGraphics
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Modifier names: one table for native pressKey, the Chrome extension and the sensitive-shortcut checks. The
/// Chrome path used to press ⌘ for "meta" while Block sensitive only knew cmd/command/ctrl/control, so
/// `browser_act` pressKey with ["meta"] skipped it.
final class ModifierAliasesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UseMacTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    // MARK: - The table

    func testAliasesMatchTheChromeExtension() throws {
        let chrome = try chromeModifierNames()
        XCTAssertEqual(chrome.count, 4, "Couldn't read buildModifierMask from the Chrome background scripts: \(chrome)")
        // CDP modifier bits: Alt 1, Ctrl 2, Meta/Command 4, Shift 8.
        let bits: [Int: ModifierAliases.Modifier] = [1: .option, 2: .control, 4: .command, 8: .shift]
        for (bit, modifier) in bits {
            XCTAssertEqual(
                chrome[bit], ModifierAliases.names[modifier],
                "buildModifierMask and ModifierAliases.names disagree on \(modifier): change both, or a spelling one path presses can skip the sensitive-shortcut check"
            )
        }
    }

    func testEveryCommandOrControlSpellingIsSensitive() {
        for name in (ModifierAliases.names[.command] ?? []).union(ModifierAliases.names[.control] ?? []) {
            XCTAssertTrue(ModifierAliases.isSensitive([name]), name)
            XCTAssertTrue(ModifierAliases.isSensitive([name.uppercased()]), name.uppercased())
            XCTAssertTrue(ModifierAliases.isSensitive(["shift", " \(name) "]), "padded \(name)")
        }
        XCTAssertTrue(ModifierAliases.isSensitive(["Meta"]))
        for name in ["shift", "alt", "opt", "option", "fn", "hyper", "super", "", "cmdx"] {
            XCTAssertFalse(ModifierAliases.isSensitive([name]), name)
        }
        XCTAssertFalse(ModifierAliases.isSensitive(nil))
        XCTAssertFalse(ModifierAliases.isSensitive([]))
    }

    func testNativeFlagsFollowTheSameTable() {
        XCTAssertEqual(ModifierAliases.eventFlags(["meta"]), .maskCommand)
        XCTAssertEqual(ModifierAliases.eventFlags(["Command", "SHIFT"]), [.maskCommand, .maskShift])
        XCTAssertEqual(ModifierAliases.eventFlags(["control", "opt"]), [.maskControl, .maskAlternate])
        XCTAssertEqual(ModifierAliases.eventFlags(["option"]), .maskAlternate)
        XCTAssertEqual(ModifierAliases.eventFlags(["fn", "hyper"]), [])
        XCTAssertEqual(ModifierAliases.eventFlags(nil), [])
        // Whatever native presses as ⌘ or ⌃ is sensitive, and the other way round.
        for name in ModifierAliases.names.values.flatMap({ $0 }) {
            let pressesCommandOrControl = !ModifierAliases.eventFlags([name]).isDisjoint(with: [.maskCommand, .maskControl])
            XCTAssertEqual(pressesCommandOrControl, ModifierAliases.isSensitive([name]), name)
        }
    }

    func testSymbolsUseAppleOrder() {
        XCTAssertEqual(ModifierAliases.symbols(["meta", "shift", "ctrl", "alt"]), "⌃⌥⇧⌘")
        XCTAssertEqual(ModifierAliases.symbols(["command"]), "⌘")
        XCTAssertEqual(ModifierAliases.symbols(nil), "")
    }

    // MARK: - The policy checks use it

    func testBlockSensitiveRefusesAMetaShortcutInChrome() async {
        let service = makeService()
        service.setGovernancePolicy(.confirmSensitive)
        for modifiers in [["meta"], ["Meta"], ["command"], ["control"], [" cmd "]] {
            let response = await service.handle(RPCRequest(
                method: .browserAct,
                browserAct: BrowserActParams(tabId: 1, steps: [ActionStep(action: .pressKey, key: "q", modifiers: modifiers)])
            ))
            XCTAssertFalse(response.ok, "\(modifiers)")
            XCTAssertEqual(response.error?.code, "POLICY_BLOCKED", "\(modifiers): \(response.error?.message ?? "")")
        }
    }

    func testBlockSensitiveRefusesAMetaShortcutInANativeApp() async {
        let service = makeService()
        service.setGovernancePolicy(.confirmSensitive)
        // An unknown key, so nothing could be pressed even if a check let it through.
        let response = await service.handle(RPCRequest(
            method: .act,
            act: BatchActionRequest(
                app: "no-such-app-\(UUID().uuidString)",
                steps: [ActionStep(action: .pressKey, key: "pgdn", modifiers: ["meta"])],
                returnObservation: false
            )
        ))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED", response.error?.message ?? "")
    }

    func testTheExecutorsOwnCheckCountsMeta() async {
        let executor = ActionExecutor(
            axIndexer: AXIndexer(),
            workspaceMonitor: WorkspaceMonitor(),
            killSwitch: KillSwitch(policy: .confirmSensitive)
        )
        let request = BatchActionRequest(app: "no-such-app-\(UUID().uuidString)", steps: [
            ActionStep(action: .pressKey, key: "pgdn", modifiers: ["meta"])
        ], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stepResults.first?.errorCode, "POLICY_BLOCKED", result.stepResults.first?.message ?? "")
    }

    func testATargetlessBrowserSetValueIsRefusedBeforeSending() async {
        let service = makeService()
        let response = await service.handle(RPCRequest(
            method: .browserAct,
            browserAct: BrowserActParams(tabId: 1, steps: [ActionStep(action: .setValue, elementId: "", text: "secret")])
        ))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "INVALID_REQUEST")
        XCTAssertTrue(response.error?.message.contains("names no field") ?? false, response.error?.message ?? "")
    }

    // MARK: - No check spells the names out again

    func testModifierChecksGoThroughModifierAliases() throws {
        // A check written as `lower.contains("cmd") || lower.contains("command")` misses "meta". Engine code asks
        // ModifierAliases (isSensitive, eventFlags, symbols) instead of comparing names itself.
        let aliases = ModifierAliases.names.values.flatMap { $0 }.joined(separator: "|")
        let pattern = try NSRegularExpression(pattern: #"(contains\(|==\s*|case\s+)"(\#(aliases))""#)
        let folder = Self.repoRoot.appendingPathComponent("Sources/UseMacEngine")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") && $0 != "ModifierAliases.swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files.sorted() {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    XCTFail("Sources/UseMacEngine/\(file):\(index + 1) compares modifier names itself; use ModifierAliases: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-mods-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    /// CDP modifier bit -> the names buildModifierMask maps to it.
    private func chromeModifierNames() throws -> [Int: Set<String>] {
        let source = try readChromeBackgroundSource()
        let start = try XCTUnwrap(source.range(of: "function buildModifierMask("), "buildModifierMask is gone")
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let branch = try NSRegularExpression(pattern: #"if \((.*)\) mask \|= (\d+);"#)
        let name = try NSRegularExpression(pattern: #"m === "([^"]+)""#)
        var table: [Int: Set<String>] = [:]
        for line in body.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = branch.firstMatch(in: line, range: range),
                  let condition = Range(match.range(at: 1), in: line),
                  let bitRange = Range(match.range(at: 2), in: line),
                  let bit = Int(line[bitRange]) else { continue }
            let conditionText = String(line[condition])
            let names = name.matches(in: conditionText, range: NSRange(conditionText.startIndex..., in: conditionText))
                .compactMap { Range($0.range(at: 1), in: conditionText).map { String(conditionText[$0]) } }
            table[bit, default: []].formUnion(names)
        }
        return table
    }
}
