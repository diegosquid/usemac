import CoreGraphics
import Foundation

/// The key names native `pressKey` understands, mapped to macOS virtual key codes (Carbon `kVK_*`).
///
/// The names and aliases follow the Chrome path's key table (`buildKeyDescriptor` in Extension/background.js), so a
/// step means the same in `act` and `browser_act`; `NativeKeyMapTests` keeps the two tables in step. Names are
/// case-insensitive (`PageDown`, `pageDown`, `pagedown`). Character keys are key positions on a US (ANSI) keyboard:
/// with another layout the same key can produce another character, so text goes through `type`.
///
/// One name differs on purpose: `delete` is the Mac delete key (backspace) here, and forward delete (the DOM
/// `Delete` key) in Chrome. `backspace` and `forwarddelete` mean the same on both paths.
enum NativeKeyMap {
    /// Shown in the INVALID_REQUEST message and the docs.
    static let supportedKeysSummary =
        "return (enter), tab, space, delete (backspace), forwarddelete, escape (esc), up, down, left, right "
        + "(or arrowup, arrowdown, arrowleft, arrowright), home, end, pageup, pagedown, f1–f12, a–z, 0–9, "
        + "and - = [ ] ; ' , . / \\ `"

    /// The virtual key code for a `pressKey` key name, or nil when the name is unknown or missing.
    static func keyCode(for key: String?) -> CGKeyCode? {
        guard let name = normalizedName(key) else { return nil }
        return codes[name]
    }

    /// Why native `pressKey` refused `key`, with the names it accepts.
    static func unsupportedKeyMessage(for key: String?) -> String {
        guard let name = normalizedName(key) else {
            return "pressKey needs a key. Supported keys: \(supportedKeysSummary)."
        }
        if name.count == 1, let character = name.first, let base = shiftedCharacters[character] {
            return "\"\(name)\" is a shifted key: press \"\(base)\" with modifiers [\"shift\"], or use type to enter \"\(name)\"."
        }
        return "Unsupported key \"\(key ?? "")\". Supported keys: \(supportedKeysSummary). To enter other characters, use type."
    }

    /// Lower-cased and trimmed; a lone space is the space key. Nil for a missing or blank key.
    static func normalizedName(_ key: String?) -> String? {
        guard let key else { return nil }
        if key == " " { return " " }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Characters the Chrome path types as text but that need shift on a US keyboard, with the key that makes them.
    /// Native `pressKey` refuses them rather than add a modifier the caller didn't ask for.
    static let shiftedCharacters: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/"
    ]

    static let codes: [String: CGKeyCode] = [
        // Named keys (kVK_Return, kVK_Tab, …), with the Chrome path's aliases.
        "return": 0x24,
        "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        " ": 0x31,
        "delete": 0x33,
        "backspace": 0x33,
        "forwarddelete": 0x75,
        "escape": 0x35,
        "esc": 0x35,
        "left": 0x7B,
        "arrowleft": 0x7B,
        "right": 0x7C,
        "arrowright": 0x7C,
        "down": 0x7D,
        "arrowdown": 0x7D,
        "up": 0x7E,
        "arrowup": 0x7E,
        "home": 0x73,
        "end": 0x77,
        "pageup": 0x74,
        "pagedown": 0x79,
        // kVK_F1 … kVK_F12
        "f1": 0x7A,
        "f2": 0x78,
        "f3": 0x63,
        "f4": 0x76,
        "f5": 0x60,
        "f6": 0x61,
        "f7": 0x62,
        "f8": 0x64,
        "f9": 0x65,
        "f10": 0x6D,
        "f11": 0x67,
        "f12": 0x6F,
        // kVK_ANSI_A … kVK_ANSI_Z
        "a": 0x00,
        "s": 0x01,
        "d": 0x02,
        "f": 0x03,
        "h": 0x04,
        "g": 0x05,
        "z": 0x06,
        "x": 0x07,
        "c": 0x08,
        "v": 0x09,
        "b": 0x0B,
        "q": 0x0C,
        "w": 0x0D,
        "e": 0x0E,
        "r": 0x0F,
        "y": 0x10,
        "t": 0x11,
        "o": 0x1F,
        "u": 0x20,
        "i": 0x22,
        "p": 0x23,
        "l": 0x25,
        "j": 0x26,
        "k": 0x28,
        "n": 0x2D,
        "m": 0x2E,
        // kVK_ANSI_0 … kVK_ANSI_9
        "1": 0x12,
        "2": 0x13,
        "3": 0x14,
        "4": 0x15,
        "6": 0x16,
        "5": 0x17,
        "9": 0x19,
        "7": 0x1A,
        "8": 0x1C,
        "0": 0x1D,
        // kVK_ANSI_Minus, _Equal, _LeftBracket, _RightBracket, _Semicolon, _Quote, _Comma, _Period, _Slash,
        // _Backslash, _Grave
        "-": 0x1B,
        "=": 0x18,
        "[": 0x21,
        "]": 0x1E,
        ";": 0x29,
        "'": 0x27,
        ",": 0x2B,
        ".": 0x2F,
        "/": 0x2C,
        "\\": 0x2A,
        "`": 0x32
    ]
}
