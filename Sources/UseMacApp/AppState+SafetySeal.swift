import AppKit
import SwiftUI
import UseMacEngine

extension AppState {
    /// The user read the notice about settings changed outside UseMac. It also goes away when they resume.
    func dismissSafetySealNotice() {
        safetySealNotice = nil
    }
}

/// The notice at the top of Settings → Safety after UseMac found its safety settings changed outside it and started
/// paused. Shows nothing otherwise.
struct SafetySealNoticeRow: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let notice = appState.safetySealNotice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(UseMacTheme.statusAmber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(notice.title)
                        .font(.system(size: 13.5, weight: .medium))
                    Text(notice.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Button("OK") {
                    appState.dismissSafetySealNotice()
                }
                .buttonStyle(SubtleOutlineButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(UseMacTheme.statusAmber.opacity(0.06))

            InsetDivider(leading: 18)
        }
    }
}
