import AppKit
import SwiftUI
import UseMacEngine
import UseMacProtocol

/// One connected Chrome profile in Settings > Chrome Extension: tabs, the extension version and where Chrome loads
/// it from, a note when it is outdated or loaded from another folder, and a Reload button.
struct ChromeExtensionProfileRow: View {
    @ObservedObject var appState: AppState
    let profile: BrowserProfileStatus
    @State private var isReloading = false

    private var outdated: Bool { profile.extensionOutdated == true }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(profile.profileName)
                    .font(.system(size: 13.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let note = profile.extensionNote {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(outdated ? UseMacTheme.statusAmber : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                if profile.extensionReloadable == true {
                    Button(isReloading ? "Reloading…" : "Reload") {
                        reload()
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .disabled(isReloading)
                    .help("Reload the extension so Chrome runs the code now in its folder")
                } else if outdated || profile.extensionSource == "other_folder" {
                    Button("Open Chrome") {
                        appState.openChromeExtensionsPage()
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .help("This extension predates remote reload: click its reload button in chrome://extensions once")
                }

                StatusDot(
                    color: outdated ? UseMacTheme.statusAmber : UseMacTheme.statusGreen,
                    label: outdated ? "Outdated" : "Connected"
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        var parts = [
            "\(profile.tabCount) open \(profile.tabCount == 1 ? "tab" : "tabs")",
            "extension \(profile.extensionVersion)"
        ]
        switch profile.extensionSource {
        case "app": parts.append("from UseMac")
        case "web_store": parts.append("from the Chrome Web Store")
        case "other_folder": parts.append("from another folder")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        isReloading = true
        Task { @MainActor in
            await appState.reloadChromeExtension(profile)
            isReloading = false
        }
    }
}

extension AppState {
    /// Settings > Chrome Extension > Reload. Asks first when agents still have Chrome commands running in that
    /// profile, because reloading stops them. The row updates when the extension reconnects.
    func reloadChromeExtension(_ profile: BrowserProfileStatus) async {
        var outcome = await engine.chromeBridge.reloadExtension(sessionId: profile.id)
        if outcome.error?.code == "BROWSER_BUSY" {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Agents are using Chrome"
            alert.informativeText = "Reloading the extension in “\(profile.profileName)” stops their browser work."
            alert.addButton(withTitle: "Reload Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            outcome = await engine.chromeBridge.reloadExtension(sessionId: profile.id, force: true)
        }
        if let error = outcome.error {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't reload the extension"
            alert.informativeText = error.message
            alert.runModal()
        }
    }
}
