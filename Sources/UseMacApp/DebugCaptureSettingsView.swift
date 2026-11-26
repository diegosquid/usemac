import AppKit
import SwiftUI
import UseMacEngine
import UseMacProtocol

/// Settings → General → Developer: Debug capture, for developing UseMac itself.
///
/// Off by default. Turning it on opens a confirmation that says what it allows, and only a physical click on its
/// Turn On button turns it on: the button is an `ApprovalClickTarget`, which ignores clicks some process posted and
/// refuses Accessibility presses, like Ask mode's prompt. Turning it off needs no confirmation.
struct DebugCaptureGroupView: View {
    @ObservedObject var appState: AppState
    @State private var confirming = false

    var body: some View {
        let isOn = appState.isDebugCaptureEnabled
        SettingsGroup(title: "Developer") {
            if isOn {
                StatusDot(color: UseMacTheme.statusAmber, label: "Debug capture on")
            }
        } content: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(DebugCaptureNotice.settingTitle)
                        .font(.system(size: 13.5, weight: .medium))
                    Text(isOn ? DebugCaptureNotice.settingSubtitleOn : DebugCaptureNotice.settingSubtitleOff)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                CodexToggle(
                    isOn: Binding(
                        get: { appState.isDebugCaptureEnabled },
                        set: { wantsOn in
                            if wantsOn {
                                confirming = true
                            } else {
                                appState.turnOffDebugCapture()
                            }
                        }
                    ),
                    activeColor: UseMacTheme.statusAmber,
                    accessibilityLabel: DebugCaptureNotice.settingTitle
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(isOn ? UseMacTheme.statusAmber.opacity(0.05) : Color.clear)
        }
        .sheet(isPresented: $confirming) {
            DebugCaptureConfirmSheet(
                onCancel: { confirming = false },
                onConfirm: { click in
                    appState.turnOnDebugCapture(confirmedBy: click)
                    confirming = false
                }
            )
        }
    }
}

/// The confirmation before Debug capture turns on.
private struct DebugCaptureConfirmSheet: View {
    let onCancel: () -> Void
    let onConfirm: (ApprovalInputCheck.PhysicalClick) -> Void

    @Environment(\.colorScheme) private var scheme
    /// When Turn On goes live, in `ProcessInfo.systemUptime` (the clock NSEvent timestamps use).
    @State private var armedAt: TimeInterval = .greatestFiniteMagnitude
    @State private var armed = false
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(UseMacTheme.statusAmber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(DebugCaptureNotice.confirmTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(DebugCaptureNotice.confirmMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                turnOnButton
            }

            Text(DebugCaptureNotice.confirmFootnote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            armedAt = ProcessInfo.processInfo.systemUptime + ApprovalInputCheck.armingDelaySeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + ApprovalInputCheck.armingDelaySeconds) {
                armed = true
            }
        }
    }

    private var turnOnButton: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Text(DebugCaptureNotice.confirmButton)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(UseMacTheme.inkForeground(scheme))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(shape.fill(UseMacTheme.inkBackground(scheme).opacity(pressed ? 0.86 : 1)))
            .opacity(armed ? 1 : 0.45)
            .accessibilityHidden(true)
            .overlay(
                ApprovalClickTarget(
                    title: DebugCaptureNotice.confirmButton,
                    armedAt: armedAt,
                    onPressChange: { pressed = $0 },
                    onClick: onConfirm
                )
            )
    }
}
