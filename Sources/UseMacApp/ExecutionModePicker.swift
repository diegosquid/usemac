import SwiftUI
import UseMacEngine
import UseMacProtocol

/// Picks the execution mode, with the modes, names and descriptions from `ExecutionModeChoices`.
///
/// In Settings it lists every mode as a row with its description. The Setup guide has less room, so there it
/// is a segmented control with full names (each description in the segment's tooltip), and the guide shows
/// the selected mode's description next to it.
struct ExecutionModePicker: View {
    enum Placement {
        case settings
        case setupGuide
    }

    @Binding var selection: GovernancePolicy
    let placement: Placement

    var body: some View {
        switch placement {
        case .settings:
            VStack(spacing: 2) {
                ForEach(ExecutionModeChoices.settings, id: \.self) { mode in
                    ExecutionModeRow(mode: mode, isSelected: selection == mode) {
                        selection = mode
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Execution mode")
        case .setupGuide:
            CodexSegmentedControl(
                selection: $selection,
                options: ExecutionModeChoices.setupGuide.map {
                    CodexSegmentOption(
                        value: $0,
                        label: ExecutionModeChoices.name($0),
                        helpText: ExecutionModeChoices.summary($0)
                    )
                }
            )
            .fixedSize()
        }
    }
}

private struct ExecutionModeRow: View {
    let mode: GovernancePolicy
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                SetupRadio(isSelected: isSelected)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(ExecutionModeChoices.name(mode))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(ExecutionModeChoices.summary(mode))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .background(shape.fill(background))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isSelected {
            return UseMacTheme.accentActive.opacity(colorScheme == .dark ? 0.16 : 0.08)
        }
        return isHovered ? UseMacTheme.subtleFill(colorScheme) : Color.clear
    }
}
