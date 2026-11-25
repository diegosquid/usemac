import AppKit
import SwiftUI

public enum MacUseTheme {
    // Outer matte window shell & sidebar rail (warm stone in Light, deep obsidian in Dark)
    public static func shellBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.055, green: 0.055, blue: 0.067)   // #0E0E11
            : Color(red: 0.925, green: 0.927, blue: 0.941)   // #ECECEF
    }

    // Floating inset workspace sheet canvas (warm paper so pure white cards pop with soft shadows)
    public static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.082, green: 0.082, blue: 0.098)   // #151519
            : Color(red: 0.969, green: 0.970, blue: 0.978)   // #F7F7FA
    }

    // Elevated porcelain cards & active pills
    public static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.141)   // #1E1E24
            : Color.white
    }

    // Active sliding thumb inside segmented tracks
    public static func elevatedThumb(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.169, green: 0.169, blue: 0.200)   // #2B2B33
            : Color.white
    }

    // Recessed segmented & code header tracks
    public static func recessed(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.black.opacity(0.34)
            : Color(red: 0.933, green: 0.935, blue: 0.949)   // #EEEEF2
    }

    public static func subtleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    public static func hoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.052)
    }

    public static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.058)
    }

    public static func strongHairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.105)
    }

    public static func codeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.063, green: 0.063, blue: 0.075)   // #101013
            : Color(red: 0.965, green: 0.967, blue: 0.976)   // #F6F7F9
    }

    public static func inkBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
            : Color(red: 0.090, green: 0.090, blue: 0.106)   // #17171B
    }

    public static func inkForeground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.078, green: 0.078, blue: 0.090)
            : Color.white
    }

    // Semantic accents
    public static let statusGreen = Color(red: 0.110, green: 0.725, blue: 0.345)
    public static let statusAmber = Color(red: 0.859, green: 0.549, blue: 0.086)
    public static let statusRed = Color(red: 0.863, green: 0.196, blue: 0.196)
    public static let accentActive = Color(red: 0.231, green: 0.549, blue: 0.961) // Calm glacier/sky blue (#3B8CF5)
    public static let accentViolet = accentActive
}

// MARK: - Codex Multi-Layered Soft Shadow Modifiers

public extension View {
    func codexSheetElevation(_ scheme: ColorScheme, cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .clipShape(shape)
            .background {
                shape
                    .fill(MacUseTheme.canvas(scheme))
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.42 : 0.045),
                        radius: 1.5,
                        x: 0,
                        y: 1
                    )
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.48 : 0.065),
                        radius: 8,
                        x: 0,
                        y: 4
                    )
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.56 : 0.06),
                        radius: 22,
                        x: 0,
                        y: 10
                    )
            }
            .overlay(
                shape.strokeBorder(MacUseTheme.hairline(scheme), lineWidth: 0.75)
            )
    }

    func codexCardElevation(_ scheme: ColorScheme, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .clipShape(shape)
            .background {
                shape
                    .fill(MacUseTheme.surface(scheme))
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.30 : 0.038),
                        radius: 1,
                        x: 0,
                        y: 0.75
                    )
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.38 : 0.055),
                        radius: 6,
                        x: 0,
                        y: 3
                    )
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.44 : 0.048),
                        radius: 16,
                        x: 0,
                        y: 7
                    )
            }
            .overlay(
                shape.strokeBorder(MacUseTheme.hairline(scheme), lineWidth: 0.75)
            )
    }

    func codexPillElevation(_ scheme: ColorScheme, cornerRadius: CGFloat = 9) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape
                    .fill(MacUseTheme.elevatedThumb(scheme))
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.34 : 0.055),
                        radius: 1,
                        x: 0,
                        y: 1
                    )
                    .shadow(
                        color: Color.black.opacity(scheme == .dark ? 0.38 : 0.065),
                        radius: 5,
                        x: 0,
                        y: 2.5
                    )
            }
            .overlay(
                shape.strokeBorder(MacUseTheme.hairline(scheme), lineWidth: 0.6)
            )
    }
}

// MARK: - Codex Quiet Settings Card Group

public struct SettingsGroup<Content: View, Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let title: String?
    private let trailing: Trailing
    private let content: Content

    public init(
        title: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                content
            }
            .codexCardElevation(colorScheme, cornerRadius: 14)
        }
    }
}

public struct InsetDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    private let leading: CGFloat

    public init(leading: CGFloat = 18) {
        self.leading = leading
    }

    public var body: some View {
        Rectangle()
            .fill(MacUseTheme.hairline(colorScheme))
            .frame(height: 0.75)
            .padding(.leading, leading)
    }
}

// MARK: - Minimal Status Dot

public struct StatusDot: View {
    @Environment(\.colorScheme) private var colorScheme
    private let color: Color
    private let label: String

    public init(color: Color, label: String) {
        self.color = color
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tactile Physical Keycap Badges

public struct ShortcutText: View {
    @Environment(\.colorScheme) private var colorScheme
    private let tokens: [String]

    public init(_ text: String) {
        self.tokens = Self.tokenize(text)
    }

    public var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, token.count > 1 ? 5 : 4)
                    .frame(minWidth: 17, minHeight: 17)
                    .background {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(MacUseTheme.surface(colorScheme))
                            .shadow(
                                color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.065),
                                radius: 0.75,
                                x: 0,
                                y: 1
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(MacUseTheme.strongHairline(colorScheme), lineWidth: 0.6)
                    )
            }
        }
    }

    private static func tokenize(_ raw: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        let symbols: Set<Character> = ["⌘", "⇧", "⌥", "⌃", "⎋", "⏎", "⇥"]
        for ch in raw {
            if symbols.contains(ch) {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(String(ch))
            } else {
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
        return result
    }
}

// MARK: - Codex Sliding Segmented Pill Control

public struct CodexSegmentOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let label: String?
    public let symbolName: String?
    public let helpText: String?
    public let accessibilityLabel: String?

    public var id: Value { value }

    public init(
        value: Value,
        label: String? = nil,
        symbolName: String? = nil,
        helpText: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.value = value
        self.label = label
        self.symbolName = symbolName
        self.helpText = helpText
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct CodexSegmentedControl<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var thumbNamespace

    @Binding private var selection: Value
    private let options: [CodexSegmentOption<Value>]

    public init(selection: Binding<Value>, options: [CodexSegmentOption<Value>]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segmentButton(for: option)
            }
        }
        .padding(3)
        .background(
            MacUseTheme.recessed(colorScheme),
            in: RoundedRectangle(cornerRadius: 9.5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                .strokeBorder(MacUseTheme.hairline(colorScheme), lineWidth: 0.55)
        )
    }

    private func segmentButton(for option: CodexSegmentOption<Value>) -> some View {
        let isSelected = selection == option.value
        let helpText = option.helpText ?? option.label ?? ""
        let a11yLabel = option.accessibilityLabel ?? option.label ?? option.helpText ?? ""

        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                selection = option.value
            }
        } label: {
            HStack(spacing: 4.5) {
                if let symbol = option.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                }
                if let label = option.label {
                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, option.label == nil ? 8.5 : 11)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MacUseTheme.elevatedThumb(colorScheme))
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06),
                            radius: 1,
                            x: 0,
                            y: 1
                        )
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.065),
                            radius: 4,
                            x: 0,
                            y: 2
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(MacUseTheme.hairline(colorScheme), lineWidth: 0.55)
                        )
                        .matchedGeometryEffect(id: "codexSegmentThumb", in: thumbNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(a11yLabel)
    }
}

// MARK: - Codex Tactile Ink Switch

public struct CodexToggle: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var isOn: Bool
    private let activeColor: Color?
    private let accessibilityLabelText: String?

    public init(isOn: Binding<Bool>, activeColor: Color? = nil, accessibilityLabel: String? = nil) {
        self._isOn = isOn
        self.activeColor = activeColor
        self.accessibilityLabelText = accessibilityLabel
    }

    public var body: some View {
        let onTrack = activeColor ?? MacUseTheme.inkBackground(colorScheme)
        let offTrack = colorScheme == .dark
            ? Color.white.opacity(0.13)
            : Color.black.opacity(0.095)
        let thumbColor = (isOn && activeColor == nil && colorScheme == .dark)
            ? Color(red: 0.09, green: 0.09, blue: 0.11)
            : Color.white

        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.80)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? onTrack : offTrack)
                    .frame(width: 36, height: 21)

                Circle()
                    .fill(thumbColor)
                    .frame(width: 17, height: 17)
                    .shadow(color: Color.black.opacity(0.16), radius: 2, x: 0, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabelText ?? "Toggle")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.80)) {
                isOn.toggle()
            }
        }
    }
}

// MARK: - App Glyph & Tactile Button Styles

public struct MacUseGlyph: View {
    private let size: CGFloat

    public init(size: CGFloat = 16) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.095))
            Image(systemName: "command")
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

public struct PrimaryInkButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MacUseTheme.inkForeground(colorScheme))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MacUseTheme.inkBackground(colorScheme).opacity(configuration.isPressed ? 0.86 : 1.0))
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.13),
                        radius: configuration.isPressed ? 2 : 5,
                        x: 0,
                        y: configuration.isPressed ? 1 : 2
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

public struct SubtleOutlineButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background {
                shape
                    .fill(
                        configuration.isPressed
                            ? MacUseTheme.hoverFill(colorScheme)
                            : (isHovered ? MacUseTheme.elevatedThumb(colorScheme) : MacUseTheme.surface(colorScheme))
                    )
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.045),
                        radius: configuration.isPressed ? 1 : 3,
                        x: 0,
                        y: configuration.isPressed ? 0.5 : 1.5
                    )
            }
            .overlay(
                shape.strokeBorder(MacUseTheme.strongHairline(colorScheme), lineWidth: 0.7)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .onHover { isHovered = $0 }
    }
}
