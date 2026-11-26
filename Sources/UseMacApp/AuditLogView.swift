import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UseMacEngine
import UseMacProtocol

/// Settings → History: the audit log kept on disk, filtered by result, task and app, with an export.
struct AuditLogView: View {
    @ObservedObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AuditLogSettings.retentionDaysKey) private var retentionDays = AuditLogSettings.defaultRetentionDays

    @State private var resultFilter: ResultFilter = .all
    @State private var taskFilter: String?
    @State private var appFilter: String?
    /// The most recent entries with no filter: the source of the task and app menus.
    @State private var recent: [AuditEntry] = []
    /// What the list shows: `recent`, or the persisted log read again with the filters.
    @State private var shown: [AuditEntry] = []
    @State private var hasLoaded = false
    @State private var exportStatus: String?

    /// Rows the list shows at most; the export always writes every matching entry.
    private static let displayLimit = 1000

    enum ResultFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case ok = "Done"
        case failed = "Failed"
        var id: String { rawValue }

        var success: Bool? {
            switch self {
            case .all: return nil
            case .ok: return true
            case .failed: return false
            }
        }
    }

    private struct LoadKey: Equatable {
        var result: ResultFilter
        var task: String?
        var app: String?
        var retention: Int
        var latestEntryId: String?
    }

    private var isFiltered: Bool {
        resultFilter != .all || taskFilter != nil || appFilter != nil
    }

    private var filterQuery: AuditLogQuery {
        AuditLogQuery(limit: Self.displayLimit, taskId: taskFilter, app: appFilter, success: resultFilter.success)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 28)
                .padding(.bottom, 16)

            filterBar
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.bottom, 16)

            if shown.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        entryList
                        if shown.count >= Self.displayLimit {
                            Text("Showing the \(Self.displayLimit) most recent entries. Export to get all of them.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.bottom, 34)
                }
            }
        }
        .task(id: LoadKey(
            result: resultFilter,
            task: taskFilter,
            app: appFilter,
            retention: retentionDays,
            latestEntryId: appState.auditEntries.first?.id
        )) {
            await reload()
        }
    }

    // MARK: - Header and filters

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.4)
                Text("Every observation and action, kept for \(Self.durationLabel(retentionDays)) on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let exportStatus {
                Text(exportStatus)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Menu {
                Button("JSON Lines (.jsonl)…") { export(as: .jsonl) }
                Button("CSV (.csv)…") { export(as: .csv) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(appState.engine.auditStore == nil)
            .help(isFiltered ? "Export the entries that match the filters" : "Export the whole history")
            .accessibilityLabel("Export history")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            CodexSegmentedControl(
                selection: $resultFilter,
                options: ResultFilter.allCases.map { CodexSegmentOption(value: $0, label: $0.rawValue) }
            )

            Spacer(minLength: 8)

            filterMenu(
                title: taskFilter ?? "All tasks",
                symbol: "number",
                allLabel: "All tasks",
                values: Self.distinct(recent.compactMap(\.taskId)),
                selection: $taskFilter,
                accessibilityLabel: "Filter by task"
            )

            filterMenu(
                title: appFilter ?? "All apps",
                symbol: "macwindow",
                allLabel: "All apps",
                values: Self.distinct(recent.compactMap(\.targetApp)),
                selection: $appFilter,
                accessibilityLabel: "Filter by app"
            )
        }
    }

    private func filterMenu(
        title: String,
        symbol: String,
        allLabel: String,
        values: [String],
        selection: Binding<String?>,
        accessibilityLabel: String
    ) -> some View {
        Menu {
            Button(allLabel) { selection.wrappedValue = nil }
            if !values.isEmpty {
                Divider()
                ForEach(values, id: \.self) { value in
                    Button(value) { selection.wrappedValue = value }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: selection.wrappedValue == nil ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 150)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(selection.wrappedValue == nil ? .secondary : .primary)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selection.wrappedValue ?? allLabel)
    }

    // MARK: - List

    private var entryList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    InsetDivider(leading: 34)
                }
                row(entry)
            }
        }
        .codexCardElevation(colorScheme, cornerRadius: 14)
    }

    private func row(_ entry: AuditEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(entry.success ? UseMacTheme.statusGreen : UseMacTheme.statusRed)
                .frame(width: 6, height: 6)
                .accessibilityLabel(entry.success ? "Done" : "Failed")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.targetApp?.isEmpty == false ? entry.targetApp! : entry.method.capitalized)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(entry.method)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let taskId = entry.taskId {
                        Button {
                            taskFilter = taskId
                        } label: {
                            Text(taskId)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(UseMacTheme.subtleFill(colorScheme), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Show only this task")
                    }
                }

                Text(entry.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.summary)
            }

            Spacer(minLength: 12)

            Text(Self.formatTimestamp(entry.timestampMs))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contextMenu {
            Button("Copy summary") { Self.copy(entry.summary) }
            if let taskId = entry.taskId {
                Button("Copy task ID") { Self.copy(taskId) }
                Button("Show only this task") { taskFilter = taskId }
            }
            if let app = entry.targetApp, !app.isEmpty {
                Button("Show only \(app)") { appFilter = app }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(hasLoaded ? (isFiltered ? "Nothing matches these filters" : "No history yet") : "Loading…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if hasLoaded {
                Text(isFiltered ? "Try another task, app or result." : "Observations and actions your agents run will appear here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                if isFiltered {
                    Button("Clear filters") {
                        resultFilter = .all
                        taskFilter = nil
                        appFilter = nil
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading and export

    private func reload() async {
        guard let store = appState.engine.auditStore else {
            // No log on disk (it is always there in the app): filter what is in memory.
            recent = appState.auditEntries
            shown = filterQuery.apply(to: appState.auditEntries)
            hasLoaded = true
            return
        }
        // New entries arrive in bursts while an agent works: read the files once the burst settles.
        if hasLoaded {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        let limit = Self.displayLimit
        let query = isFiltered ? filterQuery : nil
        let loaded = await Task.detached(priority: .userInitiated) {
            let recent = store.entries(matching: AuditLogQuery(limit: limit))
            let shown = query.map { store.entries(matching: $0) } ?? recent
            return (recent, shown)
        }.value
        if Task.isCancelled { return }
        recent = loaded.0
        shown = loaded.1
        hasLoaded = true
    }

    private func export(as format: AuditLogExportFormat) {
        guard let store = appState.engine.auditStore else { return }
        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "UseMac History \(Self.fileDateFormatter.string(from: Date())).\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : (UTType(filenameExtension: "jsonl") ?? .json)]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var query = filterQuery
        query.limit = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                let entries = store.entries(matching: query)
                do {
                    try AuditLogStore.export(entries, as: format).write(to: url, options: .atomic)
                    return .success(entries.count)
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let count):
                showExportStatus("Exported \(count) entr\(count == 1 ? "y" : "ies")")
            case .failure(let error):
                showExportStatus("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func showExportStatus(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { exportStatus = text }
        let shownText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if exportStatus == shownText {
                withAnimation(.easeOut(duration: 0.2)) { exportStatus = nil }
            }
        }
    }

    // MARK: - Helpers

    /// "30 days", "1 year".
    static func durationLabel(_ days: Int) -> String {
        switch days {
        case 365: return "1 year"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// Values in first-seen order (newest first), without repeats.
    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter
    }()

    private static func formatTimestamp(_ timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return dateTimeFormatter.string(from: date)
    }
}

/// Settings → General → History: how long the audit log is kept and whether it records typed text.
struct AuditLogSettingsGroup: View {
    let store: AuditLogStore?
    let onOpenHistory: () -> Void

    @AppStorage(AuditLogSettings.retentionDaysKey) private var retentionDays = AuditLogSettings.defaultRetentionDays
    @AppStorage(AuditLogSettings.recordTypedTextKey) private var recordsTypedText = false
    @State private var pendingRetention: Int?

    var body: some View {
        SettingsGroup(title: "History") {
            EmptyView()
        } content: {
            row(
                title: "Keep history",
                subtitle: "Every observation and action, one file per day in ~/Library/Application Support/UseMac/audit."
            ) {
                Menu {
                    ForEach(AuditLogSettings.retentionChoices, id: \.self) { days in
                        Button {
                            chooseRetention(days)
                        } label: {
                            if days == retentionDays {
                                Label(AuditLogView.durationLabel(days), systemImage: "checkmark")
                            } else {
                                Text(AuditLogView.durationLabel(days))
                            }
                        }
                    }
                } label: {
                    Text(AuditLogView.durationLabel(retentionDays))
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Keep history")
                .accessibilityValue(AuditLogView.durationLabel(retentionDays))
            }

            InsetDivider(leading: 18)

            row(
                title: "Record typed text",
                subtitle: recordsTypedText
                    ? "On: typed text, set values and page scripts are saved in the history as written."
                    : "Off: typed text, set values and page scripts are saved only as their length."
            ) {
                CodexToggle(isOn: $recordsTypedText, accessibilityLabel: "Record typed text")
            }

            InsetDivider(leading: 18)

            row(title: "Audit log", subtitle: "Filter by task, app and result, or export it as JSON Lines or CSV.") {
                HStack(spacing: 8) {
                    Button("Show in Finder") { revealInFinder() }
                        .buttonStyle(SubtleOutlineButtonStyle())
                        .disabled(store == nil)
                    Button("Open History") { onOpenHistory() }
                        .buttonStyle(SubtleOutlineButtonStyle())
                }
            }
        }
        .confirmationDialog(
            "Keep only \(pendingRetention.map(AuditLogView.durationLabel) ?? "") of history?",
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Older History", role: .destructive) {
                if let days = pendingRetention { applyRetention(days) }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("History older than that is deleted now and can't be recovered.")
        }
    }

    private func row<Trailing: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// A shorter retention deletes files, so it asks first; a longer one applies at once.
    private func chooseRetention(_ days: Int) {
        if days < retentionDays {
            pendingRetention = days
        } else {
            applyRetention(days)
        }
    }

    private func applyRetention(_ days: Int) {
        retentionDays = days
        guard let store else { return }
        Task.detached(priority: .utility) {
            store.prune()
        }
    }

    private func revealInFinder() {
        guard let store else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let newest = store.dayFiles().first {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([store.directory])
        }
    }
}
