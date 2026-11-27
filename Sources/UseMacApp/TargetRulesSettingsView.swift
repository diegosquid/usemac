import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UseMacEngine

/// Settings → App and site rules. The rules are edited only here; nothing on the socket, MCP or CLI changes them.
struct TargetRulesGroupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var rules: TargetRules = TargetRulesStore.shared.rules
    @State private var deniedAppDraft = ""
    @State private var deniedSiteDraft = ""
    @State private var allowedAppDraft = ""
    @State private var allowedSiteDraft = ""
    @State private var readOnlyAppDraft = ""
    @State private var readOnlySiteDraft = ""
    @State private var askAppDraft = ""
    @State private var askSiteDraft = ""
    @State private var draftError: DraftField?

    private enum DraftField: Equatable {
        case deniedApp, deniedSite, allowedApp, allowedSite
        case readOnlyApp, readOnlySite, askApp, askSite
    }

    var body: some View {
        SettingsGroup(title: "App and site rules") {
            if rules != TargetRules.defaults {
                Button("Restore Defaults") {
                    save(TargetRules.defaults)
                }
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .help("Restore Block listed with the built-in blocks and clear custom rules")
            }
        } content: {
            modeRow

            InsetDivider(leading: 18)
            appList(
                title: "Blocked apps",
                subtitle: "Agents never see, capture or control these apps, and the live preview never shows them.",
                patterns: rules.deniedApps,
                draft: $deniedAppDraft,
                field: .deniedApp,
                prompt: "Block",
                remove: { pattern in update { $0.deniedApps.removeAll { $0 == pattern } } },
                add: { pattern in update { $0.deniedApps.append(pattern) } }
            )

            InsetDivider(leading: 18)
            siteList(
                title: "Blocked sites",
                subtitle: "Chrome tabs on these sites and their subdomains are hidden from agents and never streamed.",
                patterns: rules.deniedSites,
                draft: $deniedSiteDraft,
                field: .deniedSite,
                remove: { pattern in update { $0.deniedSites.removeAll { $0 == pattern } } },
                add: { pattern in update { $0.deniedSites.append(pattern) } }
            )

            if rules.mode == .allow {
                InsetDivider(leading: 18)
                appList(
                    title: "Allowed apps",
                    subtitle: "Apps agents can use without an extra restriction. More restrictive rules take precedence.",
                    patterns: rules.allowedApps,
                    draft: $allowedAppDraft,
                    field: .allowedApp,
                    prompt: "Allow",
                    remove: { pattern in update { $0.allowedApps.removeAll { $0 == pattern } } },
                    add: { pattern in update { $0.allowedApps.append(pattern) } }
                )

                InsetDivider(leading: 18)
                siteList(
                    title: "Allowed sites",
                    subtitle: "Sites agents can use without an extra restriction. More restrictive rules take precedence.",
                    patterns: rules.allowedSites,
                    draft: $allowedSiteDraft,
                    field: .allowedSite,
                    remove: { pattern in update { $0.allowedSites.removeAll { $0 == pattern } } },
                    add: { pattern in update { $0.allowedSites.append(pattern) } }
                )
            }
            governedLists
        }
        .onReceive(NotificationCenter.default.publisher(for: TargetRulesStore.didChangeNotification)) { _ in
            rules = TargetRulesStore.shared.rules
        }
    }

    // MARK: - Mode

    private var modeRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text("Mode")
                    .font(.system(size: 13.5, weight: .medium))
                Text(rules.mode == .allow
                    ? "Agents can use only targets listed under Allow, Read-only or Ask. Blocked targets stay blocked."
                    : "Unlisted apps and sites are allowed. Listed targets follow the most restrictive rule.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            CodexSegmentedControl(
                selection: Binding(
                    get: { rules.mode },
                    set: { mode in update { $0.mode = mode } }
                ),
                options: [
                    CodexSegmentOption(value: TargetRules.Mode.deny, label: "Block listed"),
                    CodexSegmentOption(value: TargetRules.Mode.allow, label: "Allow only listed")
                ]
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Read-only and Ask

    private var governedLists: some View {
        Group {
            InsetDivider(leading: 18)
            appList(
                title: "Read-only apps",
                subtitle: "Agents can observe and capture, but mutating actions are blocked.",
                patterns: rules.readOnlyApps,
                draft: $readOnlyAppDraft,
                field: .readOnlyApp,
                prompt: "Set Read-only",
                remove: { pattern in update { $0.readOnlyApps.removeAll { $0 == pattern } } },
                add: { pattern in update { $0.readOnlyApps.append(pattern) } }
            )
            InsetDivider(leading: 18)
            siteList(
                title: "Read-only sites",
                subtitle: "Agents can observe and capture, but mutating actions are blocked.",
                patterns: rules.readOnlySites,
                draft: $readOnlySiteDraft,
                field: .readOnlySite,
                remove: { pattern in update { $0.readOnlySites.removeAll { $0 == pattern } } },
                add: { pattern in update { $0.readOnlySites.append(pattern) } }
            )
            InsetDivider(leading: 18)
            appList(
                title: "Ask before acting — apps",
                subtitle: "Mutating actions wait for your approval in the HUD, even in Autonomous mode.",
                patterns: rules.askApps,
                draft: $askAppDraft,
                field: .askApp,
                prompt: "Require Approval",
                remove: { pattern in update { $0.askApps.removeAll { $0 == pattern } } },
                add: { pattern in update { $0.askApps.append(pattern) } }
            )
            InsetDivider(leading: 18)
            siteList(
                title: "Ask before acting — sites",
                subtitle: "Mutating actions wait for your approval in the HUD, even in Autonomous mode.",
                patterns: rules.askSites,
                draft: $askSiteDraft,
                field: .askSite,
                remove: { pattern in update { $0.askSites.removeAll { $0 == pattern } } },
                add: { pattern in update { $0.askSites.append(pattern) } }
            )
        }
    }

    // MARK: - Apps

    private func appList(
        title: String,
        subtitle: String,
        patterns: [String],
        draft: Binding<String>,
        field: DraftField,
        prompt: String,
        remove: @escaping (String) -> Void,
        add: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            listHeader(title: title, subtitle: subtitle)

            if patterns.isEmpty {
                emptyLine("No apps")
            } else {
                VStack(spacing: 0) {
                    ForEach(patterns, id: \.self) { pattern in
                        let info = Self.appInfo(for: pattern)
                        entryRow(
                            icon: info.icon.map { Image(nsImage: $0) },
                            title: info.name,
                            detail: info.name == pattern ? nil : pattern,
                            removeLabel: "Remove \(info.name)",
                            remove: { remove(pattern) }
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                draftField("Bundle ID, e.g. com.example.app", text: draft, field: field) {
                    commitApp(draft, field: field, add: add)
                }
                Button("Add") {
                    commitApp(draft, field: field, add: add)
                }
                .buttonStyle(SubtleOutlineButtonStyle())
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Choose App…") {
                    for bundleId in Self.chooseApps(prompt: prompt) {
                        add(bundleId)
                    }
                }
                .buttonStyle(SubtleOutlineButtonStyle())
            }
            if draftError == field {
                errorLine("Enter a bundle ID such as com.example.app, or com.example.* for all of a vendor's apps.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func commitApp(_ draft: Binding<String>, field: DraftField, add: (String) -> Void) {
        guard let pattern = TargetRules.normalizedAppPattern(draft.wrappedValue) else {
            draftError = field
            return
        }
        draftError = nil
        add(pattern)
        draft.wrappedValue = ""
    }

    /// Display name and icon: the installed app for an exact bundle ID, else the built-in name for a default.
    private static func appInfo(for pattern: String) -> (name: String, icon: NSImage?) {
        if !pattern.hasSuffix("*"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pattern) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (TargetRules.knownAppNames[pattern.lowercased()] ?? pattern, nil)
    }

    private static func chooseApps(prompt: String) -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = prompt
        panel.message = "Choose apps for this rule."
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    // MARK: - Sites

    private func siteList(
        title: String,
        subtitle: String,
        patterns: [String],
        draft: Binding<String>,
        field: DraftField,
        remove: @escaping (String) -> Void,
        add: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            listHeader(title: title, subtitle: subtitle)

            if patterns.isEmpty {
                emptyLine("No sites")
            } else {
                VStack(spacing: 0) {
                    ForEach(patterns, id: \.self) { pattern in
                        entryRow(
                            icon: nil,
                            symbol: "globe",
                            title: pattern,
                            detail: pattern.hasPrefix(".") ? "This host only" : nil,
                            removeLabel: "Remove \(pattern)",
                            remove: { remove(pattern) }
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                draftField("Site, e.g. bank.com", text: draft, field: field) {
                    commitSite(draft, field: field, add: add)
                }
                Button("Add") {
                    commitSite(draft, field: field, add: add)
                }
                .buttonStyle(SubtleOutlineButtonStyle())
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if draftError == field {
                errorLine("Enter a host such as bank.com, a URL, or host:port. Start with a dot (.bank.com) for that host only.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func commitSite(_ draft: Binding<String>, field: DraftField, add: (String) -> Void) {
        guard let pattern = TargetRules.normalizedSitePattern(draft.wrappedValue) else {
            draftError = field
            return
        }
        draftError = nil
        add(pattern)
        draft.wrappedValue = ""
    }

    // MARK: - Pieces

    private func listHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func entryRow(
        icon: Image?,
        symbol: String = "app.dashed",
        title: String,
        detail: String?,
        removeLabel: String,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    icon.resizable().interpolation(.high)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
        .padding(.vertical, 5)
    }

    private func draftField(
        _ placeholder: String,
        text: Binding<String>,
        field: DraftField,
        onSubmit: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(UseMacTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        draftError == field ? UseMacTheme.statusRed.opacity(0.6) : UseMacTheme.hairline(colorScheme),
                        lineWidth: 0.7
                    )
            )
            .onSubmit(onSubmit)
            .onChange(of: text.wrappedValue) { _, _ in
                if draftError == field { draftError = nil }
            }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(UseMacTheme.statusRed)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Saving

    private func update(_ change: (inout TargetRules) -> Void) {
        var next = rules
        change(&next)
        save(next)
    }

    private func save(_ next: TargetRules) {
        TargetRulesStore.shared.update(next)
        rules = TargetRulesStore.shared.rules
    }
}
