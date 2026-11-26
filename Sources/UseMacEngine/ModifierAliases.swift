import CoreGraphics
import Foundation

/// The modifier names `pressKey` takes, the same on both paths: native (`ActionExecutor`) and Chrome
/// (`buildModifierMask` in Extension/background.js). Every check of what a shortcut does goes through here,
/// including whether it is sensitive, so no spelling one path accepts can slip past a check that only knows
/// another one: `meta` used to press ⌘ in Chrome without counting as a sensitive shortcut.
/// `ModifierAliasesTests` keeps this table equal to the extension's and keeps checks from spelling names out.
enum ModifierAliases {
    enum Modifier: CaseIterable, Hashable {
        case command, control, option, shift
    }

    static let names: [Modifier: Set<String>] = [
        .command: ["cmd", "command", "meta"],
        .control: ["ctrl", "control"],
        .option: ["alt", "opt", "option"],
        .shift: ["shift"]
    ]

    /// The modifier a name stands for (case-insensitive, trimmed), or nil for a name neither path knows.
    static func modifier(named name: String) -> Modifier? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Modifier.allCases.first { names[$0]?.contains(key) == true }
    }

    static func modifiers(in list: [String]?) -> Set<Modifier> {
        Set((list ?? []).compactMap(modifier(named:)))
    }

    /// ⌘ and ⌃ shortcuts are sensitive: Block sensitive refuses them and Ask mode asks first.
    static func isSensitive(_ list: [String]?) -> Bool {
        !modifiers(in: list).isDisjoint(with: [.command, .control])
    }

    static func eventFlags(_ list: [String]?) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers(in: list) {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .shift: flags.insert(.maskShift)
            }
        }
        return flags
    }

    /// "⌃⌥⇧⌘" in Apple's order, for the keys a step holds down.
    static func symbols(_ list: [String]?) -> String {
        let held = modifiers(in: list)
        var symbols = ""
        if held.contains(.control) { symbols += "⌃" }
        if held.contains(.option) { symbols += "⌥" }
        if held.contains(.shift) { symbols += "⇧" }
        if held.contains(.command) { symbols += "⌘" }
        return symbols
    }
}
