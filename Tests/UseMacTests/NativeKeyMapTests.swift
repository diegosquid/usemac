import Carbon.HIToolbox
import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

/// Native `pressKey` key names: the virtual key codes, the INVALID_REQUEST message, and parity with the Chrome
/// path's key table (`buildKeyDescriptor` in Extension/background.js), so a step means the same in `act` and
/// `browser_act`.
final class NativeKeyMapTests: XCTestCase {
    private static let backgroundJS = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/UseMacTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Extension/background.js")

    /// The native name for each DOM `key` value the Chrome table produces.
    private static let nativeNameForDOMKey: [String: String] = {
        var names = [
            "Enter": "return", "Tab": "tab", "Escape": "escape", "Backspace": "backspace", "Delete": "forwarddelete",
            " ": "space", "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left", "ArrowRight": "right",
            "Home": "home", "End": "end", "PageUp": "pageup", "PageDown": "pagedown"
        ]
        for n in 1...12 { names["F\(n)"] = "f\(n)" }
        return names
    }()

    /// Names both paths accept with a different meaning, on purpose. Each one is documented with pressKey.
    private static let knownDifferences: Set<String> = ["delete"]

    // MARK: - Key codes

    func testNamedKeysUseCarbonVirtualKeyCodes() {
        let expected: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, " ": kVK_Space,
            "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "escape": kVK_Escape, "esc": kVK_Escape,
            "left": kVK_LeftArrow, "arrowleft": kVK_LeftArrow, "right": kVK_RightArrow, "arrowright": kVK_RightArrow,
            "down": kVK_DownArrow, "arrowdown": kVK_DownArrow, "up": kVK_UpArrow, "arrowup": kVK_UpArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12
        ]
        for (name, code) in expected {
            XCTAssertEqual(NativeKeyMap.keyCode(for: name).map(Int.init), code, name)
        }
    }

    func testCharacterKeysUseANSIVirtualKeyCodes() {
        let letters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z
        ]
        let others: [Character: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave
        ]
        for (character, code) in letters.merging(others, uniquingKeysWith: { a, _ in a }) {
            XCTAssertEqual(NativeKeyMap.keyCode(for: String(character)).map(Int.init), code, String(character))
        }
        // Letters are case-insensitive: "N" is the n key (add "shift" for a capital).
        XCTAssertEqual(NativeKeyMap.keyCode(for: "N"), NativeKeyMap.keyCode(for: "n"))
    }

    func testNamesAreCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(NativeKeyMap.keyCode(for: "PageDown"), NativeKeyMap.keyCode(for: "pagedown"))
        XCTAssertEqual(NativeKeyMap.keyCode(for: "pageDown"), NativeKeyMap.keyCode(for: "pagedown"))
        XCTAssertEqual(NativeKeyMap.keyCode(for: " End "), NativeKeyMap.keyCode(for: "end"))
        XCTAssertEqual(NativeKeyMap.keyCode(for: "ArrowLeft"), NativeKeyMap.keyCode(for: "left"))
        XCTAssertEqual(NativeKeyMap.keyCode(for: "F5"), NativeKeyMap.keyCode(for: "f5"))
        XCTAssertEqual(NativeKeyMap.keyCode(for: "ForwardDelete"), NativeKeyMap.keyCode(for: "forwarddelete"))
        XCTAssertEqual(NativeKeyMap.keyCode(for: " "), NativeKeyMap.keyCode(for: "space"))
        XCTAssertNil(NativeKeyMap.keyCode(for: nil))
        XCTAssertNil(NativeKeyMap.keyCode(for: ""))
        XCTAssertNil(NativeKeyMap.keyCode(for: "  \n"))
        XCTAssertNil(NativeKeyMap.keyCode(for: "pgdn"))
        XCTAssertNil(NativeKeyMap.keyCode(for: "f13"))
    }

    // MARK: - Refusal message

    func testUnsupportedKeyMessageListsTheSupportedNames() {
        let message = NativeKeyMap.unsupportedKeyMessage(for: "pgdn")
        XCTAssertTrue(message.hasPrefix("Unsupported key \"pgdn\". Supported keys: "), message)
        for name in ["return", "forwarddelete", "home", "end", "pageup", "pagedown", "f1–f12", "a–z", "0–9", "arrowup", "use type"] {
            XCTAssertTrue(message.contains(name), "\(name) missing from: \(message)")
        }
        XCTAssertTrue(NativeKeyMap.unsupportedKeyMessage(for: nil).hasPrefix("pressKey needs a key. Supported keys: "))
        XCTAssertTrue(NativeKeyMap.unsupportedKeyMessage(for: "  ").hasPrefix("pressKey needs a key."))
    }

    func testShiftedCharactersPointToTheirBaseKey() {
        XCTAssertEqual(
            NativeKeyMap.unsupportedKeyMessage(for: "+"),
            "\"+\" is a shifted key: press \"=\" with modifiers [\"shift\"], or use type to enter \"+\"."
        )
        for (shifted, base) in NativeKeyMap.shiftedCharacters {
            XCTAssertNil(NativeKeyMap.keyCode(for: String(shifted)), String(shifted))
            XCTAssertNotNil(NativeKeyMap.keyCode(for: String(base)), "base key \(base) of \(shifted) must map")
            XCTAssertTrue(NativeKeyMap.unsupportedKeyMessage(for: String(shifted)).contains("press \"\(base)\""), String(shifted))
        }
    }

    func testExecutorRefusesAnUnknownKeyWithTheSupportedNames() async {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let request = BatchActionRequest(app: "no-such-app-\(UUID().uuidString)", steps: [
            ActionStep(action: .pressKey, key: "pgdn")
        ], returnObservation: false)
        let (result, _) = await executor.executeBatch(request)
        XCTAssertFalse(result.success)
        let step = result.stepResults.first
        XCTAssertEqual(step?.errorCode, "INVALID_REQUEST", step?.message ?? "")
        XCTAssertTrue(step?.message?.contains("pagedown") ?? false, step?.message ?? "")
    }

    // MARK: - Parity with the Chrome path

    func testEveryChromeKeyNameMeansTheSameNatively() throws {
        let table = try chromeKeyTable()
        XCTAssertGreaterThan(table.count, 20, "Couldn't read buildKeyDescriptor's table from \(Self.backgroundJS.path)")
        for (name, domKey) in table {
            guard let native = NativeKeyMap.keyCode(for: name) else {
                XCTFail("The Chrome path accepts \"\(name)\" (DOM key \"\(domKey)\") but native pressKey doesn't. Add it to NativeKeyMap.codes.")
                continue
            }
            if Self.knownDifferences.contains(name) { continue }
            guard let nativeName = Self.nativeNameForDOMKey[domKey] else {
                XCTFail("No native name for DOM key \"\(domKey)\" (Chrome name \"\(name)\"): add it to nativeNameForDOMKey.")
                continue
            }
            XCTAssertEqual(native, NativeKeyMap.keyCode(for: nativeName), "\"\(name)\" is \(domKey) in Chrome but not natively")
        }
    }

    func testDeleteIsTheOneNameWithADifferentMeaning() throws {
        // Native "delete" is the Mac delete key (backspace); Chrome's is the DOM Delete key (forward delete).
        // The pressKey docs say so: change them too if either side changes.
        let table = try chromeKeyTable()
        XCTAssertEqual(table["delete"], "Delete")
        XCTAssertEqual(NativeKeyMap.keyCode(for: "delete"), NativeKeyMap.keyCode(for: "backspace"))
        XCTAssertEqual(table["backspace"], "Backspace")
        XCTAssertEqual(table["forwarddelete"], "Delete")
    }

    func testEveryNativeNameIsKnownToChrome() throws {
        // Single characters are typed as themselves by the Chrome path; every other native name is in its table.
        let table = try chromeKeyTable()
        for name in NativeKeyMap.codes.keys where name.count > 1 {
            XCTAssertNotNil(table[name], "native pressKey accepts \"\(name)\" but the Chrome path doesn't: add it to buildKeyDescriptor")
        }
    }

    func testEveryPrintableCharacterMapsOrIsAShiftedKey() {
        // The Chrome path accepts any single character. Natively each printable ASCII character is a key, or a
        // shifted key the refusal points to.
        for scalar in UInt8(0x20)...UInt8(0x7E) {
            let character = Character(UnicodeScalar(scalar))
            let mapped = NativeKeyMap.keyCode(for: String(character)) != nil
            let shifted = NativeKeyMap.shiftedCharacters[character] != nil
            XCTAssertTrue(mapped != shifted, "\"\(character)\": mapped=\(mapped) shifted=\(shifted)")
        }
    }

    // MARK: - Reading the Chrome table

    /// `name -> DOM key` for each entry of the `special` table in buildKeyDescriptor.
    private func chromeKeyTable() throws -> [String: String] {
        let source = try String(contentsOf: Self.backgroundJS, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "function buildKeyDescriptor("), "buildKeyDescriptor is gone")
        let open = try XCTUnwrap(source.range(of: "const special = {", range: start.upperBound..<source.endIndex))
        let close = try XCTUnwrap(source.range(of: "\n  };", range: open.upperBound..<source.endIndex))
        let body = String(source[open.upperBound..<close.lowerBound])
        let entry = try NSRegularExpression(pattern: #"^\s*("(?:[^"\\]|\\.)*"|[A-Za-z0-9_]+):\s*\{\s*key:\s*"((?:[^"\\]|\\.)*)""#)
        var table: [String: String] = [:]
        for line in body.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = entry.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let keyRange = Range(match.range(at: 2), in: line) else { continue }
            var name = String(line[nameRange])
            if name.hasPrefix("\"") { name = String(name.dropFirst().dropLast()) }
            table[name] = String(line[keyRange])
        }
        return table
    }
}
