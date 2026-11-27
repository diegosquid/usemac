import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UseMacEngine
import UseMacProtocol

/// Settings → History: filter and export the audit log, or open a session to see its folded entries.
struct AuditLogView: View {
    @ObservedObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AuditLogSettings.retentionDaysKey) private var retentionDays = AuditLogSettings.defaultRetentionDays

    @State private var resultFilter: ResultFilter = .all
    @State private var taskFilter: String?
    @State private var agentFilter: String?
    @State private var appFilter: String?
    /// Off hides observations, so the list shows what agents changed, plus task and settings events.
    @State private var showsObservations = true
    /// The most recent entries with no filter: the source of the agent and app menus.
    @State private var recent: [AuditEntry] = []
    @State private var shownCount = 0
    @State private var sessions: [AuditSession] = []
    @State private var expandedSessions: Set<String> = []
    /// Folded runs opened to show each entry, by run id.
    @State private var expandedRuns: Set<String> = []
    @State private var hasLoaded = false
    @State private var exportStatus: String?

    /// Entries the list reads at most (repeats fold, so the rows are fewer); the export always writes every
    /// matching entry.
    private static let displayLimit = 5000

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
        var agent: String?
        var app: String?
        var showsObservations: Bool
        var retention: Int
        var latestEntryId: String?
    }

    private var isFiltered: Bool {
        resultFilter != .all || taskFilter != nil || agentFilter != nil || appFilter != nil || !showsObservations
    }

    private var filterQuery: AuditLogQuery {
        AuditLogQuery(
            limit: Self.displayLimit,
            taskId: taskFilter,
            app: appFilter,
            success: resultFilter.success,
            kinds: showsObservations ? nil : [.action, .other],
            agent: agentFilter
        )
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

            if let taskFilter {
                taskFilterChip(taskFilter)
                    .padding(.horizontal, 34)
                    .padding(.top, 8)
            }

            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    sessionList
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 34)
                        .padding(.top, 16)
                        .padding(.bottom, 34)
                }
            }
        }
        .task(id: LoadKey(
            result: resultFilter,
            task: taskFilter,
            agent: agentFilter,
            app: appFilter,
            showsObservations: showsObservations,
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
                Text("Grouped by session, kept for \(Self.durationLabel(retentionDays)) on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let exportStatus {
                Text(exportStatus)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
                    .help(exportStatus)
                    .transition(.opacity)
            }

            if sessions.count > 1 {
                let allExpanded = sessions.allSatisfy { expandedSessions.contains($0.id) }
                Button(allExpanded ? "Collapse all" : "Expand all") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if allExpanded {
                            expandedSessions.subtract(sessions.map(\.id))
                        } else {
                            expandedSessions.formUnion(sessions.map(\.id))
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                resultControl
                observationsSwitch
                Spacer(minLength: 8)
                scopeMenus
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    resultControl
                    observationsSwitch
                }
                HStack {
                    Spacer(minLength: 8)
                    scopeMenus
                }
            }
        }
    }

    private var resultControl: some View {
        CodexSegmentedControl(
            selection: $resultFilter,
            options: ResultFilter.allCases.map { CodexSegmentOption(value: $0, label: $0.rawValue) }
        )
        .fixedSize()
    }

    private var scopeMenus: some View {
        HStack(spacing: 10) {
            filterMenu(
                title: agentFilter ?? "All agents",
                symbol: "cpu",
                allLabel: "All agents",
                values: Self.distinct(recent.compactMap(\.agent)),
                selection: $agentFilter,
                accessibilityLabel: "Filter by agent"
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

    private var observationsSwitch: some View {
        HStack(spacing: 7) {
            // One weight in both states, so the switch doesn't shift under the pointer.
            Text("Observations")
                .font(.system(size: 12))
                .foregroundStyle(showsObservations ? .secondary : .primary)
                .lineLimit(1)
            CodexToggle(isOn: $showsObservations, accessibilityLabel: "Show observations")
        }
        .fixedSize()
        .help(showsObservations
            ? "Hide observations to see only what agents changed, with task and settings events"
            : "Show observations again")
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
            .frame(maxWidth: 130)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(selection.wrappedValue == nil ? .secondary : .primary)
        .help(title)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selection.wrappedValue ?? allLabel)
    }

    private func taskFilterChip(_ taskId: String) -> some View {
        HStack(spacing: 6) {
            Text("# \(taskId)")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(taskId)

            Button {
                taskFilter = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Clear task filter")
            .accessibilityLabel("Clear task filter")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(UseMacTheme.subtleFill(colorScheme), in: Capsule())
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: - Sessions

    private var sessionList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(sessions) { session in
                sessionCard(session)
            }
            if shownCount >= Self.displayLimit {
                Text("Showing the \(Self.displayLimit) most recent entries. Export to get all of them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func sessionCard(_ session: AuditSession) -> some View {
        let isExpanded = expandedSessions.contains(session.id)
        return VStack(spacing: 0) {
            sessionHeader(session, isExpanded: isExpanded)
            if isExpanded {
                InsetDivider(leading: 0)
                sessionRuns(session)
            }
        }
        .codexCardElevation(colorScheme, cornerRadius: 14)
    }

    private func sessionHeader(_ session: AuditSession, isExpanded: Bool) -> some View {
        let expansionLabel = isExpanded ? "Collapse session" : "Expand session"
        return HStack(spacing: 12) {
            sessionStatusBadge(session)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.title)
                    agentBadge(session)
                }

                HStack(spacing: 6) {
                    Text(session.summaryLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.summaryLine)
                    if session.durationMs >= 1000 {
                        Text("· \(Self.formatDuration(session.durationMs))")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    if let taskId = session.taskId {
                        taskBadge(taskId)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sessionTiming(session, isExpanded: isExpanded)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { toggleSession(session.id) }
        .accessibilityAction(named: Text(expansionLabel)) { toggleSession(session.id) }
        .contextMenu {
            Button(expansionLabel) { toggleSession(session.id) }
            Divider()
            Button("Copy session title") { Self.copy(session.title) }
            if let agent = session.agentName {
                Button("Show only \(agent)") { filterByAgent(agent, in: session) }
            }
            if let taskId = session.taskId {
                Button("Copy task ID") { Self.copy(taskId) }
                Button("Show only this task") { taskFilter = taskId }
            }
            if let app = session.primaryApp {
                Button("Show only \(app)") {
                    appFilter = session.entries.lazy.compactMap(\.targetApp).first {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines) == app
                    } ?? app
                }
            }
        }
    }

    private func sessionStatusBadge(_ session: AuditSession) -> some View {
        let symbol: String
        let tint: AnyShapeStyle
        let fill: Color
        if session.hasFailures {
            symbol = "exclamationmark.triangle.fill"
            tint = AnyShapeStyle(UseMacTheme.statusRed)
            fill = UseMacTheme.statusRed.opacity(colorScheme == .dark ? 0.20 : 0.12)
        } else if session.actionCount > 0 {
            symbol = session.isCompleted ? "checkmark.circle.fill" : "bolt.fill"
            tint = AnyShapeStyle(UseMacTheme.accentActive)
            fill = UseMacTheme.accentActive.opacity(colorScheme == .dark ? 0.22 : 0.12)
        } else {
            symbol = session.observationCount > 0 ? "eye" : "gearshape"
            tint = AnyShapeStyle(.secondary)
            fill = UseMacTheme.subtleFill(colorScheme)
        }
        return Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func agentBadge(_ session: AuditSession) -> some View {
        if let agent = session.agentName {
            Button {
                filterByAgent(agent, in: session)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 8.5))
                    Text(agent)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(UseMacTheme.accentActive.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(colorScheme == .dark ? AnyShapeStyle(UseMacTheme.accentActive) : AnyShapeStyle(.primary))
            .frame(maxWidth: 128)
            .fixedSize(horizontal: true, vertical: false)
            .help("Show only \(agent)")
        } else {
            Text("Unknown agent")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(UseMacTheme.subtleFill(colorScheme), in: Capsule())
        }
    }

    private func taskBadge(_ taskId: String) -> some View {
        Button {
            taskFilter = taskId
        } label: {
            Text(taskId)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(UseMacTheme.subtleFill(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 85)
        .fixedSize(horizontal: true, vertical: false)
        .help("Show only this task: \(taskId)")
    }

    private func sessionTiming(_ session: AuditSession, isExpanded: Bool) -> some View {
        let time = session.totalCount > 1
            ? Self.formatRange(session.firstTimestampMs, session.lastTimestampMs)
            : Self.formatTimestamp(session.lastTimestampMs)
        return VStack(alignment: .trailing, spacing: 4) {
            Text(time)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(time)

            Button {
                toggleSession(session.id)
            } label: {
                HStack(spacing: 4) {
                    Text("\(session.totalCount) \(session.totalCount == 1 ? "log" : "logs")")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(UseMacTheme.subtleFill(colorScheme), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse session" : "Expand session")
            .accessibilityValue("\(session.totalCount) \(session.totalCount == 1 ? "log" : "logs")")
        }
        .frame(maxWidth: 175, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func filterByAgent(_ agent: String, in session: AuditSession) {
        // The session trims display names, but the query matches the original metadata exactly.
        agentFilter = session.entries.lazy.compactMap(\.agent).first {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == agent
        } ?? agent
    }

    private func toggleSession(_ id: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            if expandedSessions.contains(id) {
                expandedSessions.remove(id)
            } else {
                expandedSessions.insert(id)
            }
        }
    }

    // MARK: - Entries inside a session

    private func sessionRuns(_ session: AuditSession) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(session.runs) { run in
                if run.id != session.runs.first?.id {
                    InsetDivider(leading: 48)
                }
                row(run)
                if run.isFolded && expandedRuns.contains(run.id) {
                    ForEach(run.entries) { entry in
                        memberRow(entry, isLast: entry.id == run.id)
                    }
                }
            }
        }
        .background(UseMacTheme.codeBackground(colorScheme).opacity(0.55))
    }

    private func row(_ run: AuditEntryRun) -> some View {
        let entry = run.representative
        let safeSummary = AuditRedactor.scrubSensitivePatterns(in: entry.summary)
        let isExpanded = run.isFolded && expandedRuns.contains(run.id)
        let isObservation = run.kind == .observation
        let time = run.isFolded
            ? Self.formatRange(run.firstTimestampMs, run.lastTimestampMs)
            : Self.formatTimestamp(entry.timestampMs)
        return HStack(alignment: .center, spacing: 12) {
            kindBadge(run.kind, method: entry.method, success: entry.success)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    let app = entry.targetApp?.isEmpty == false ? entry.targetApp : nil
                    // Without an app (tasks, settings) the method is the title: "task_complete" → "Task complete".
                    Text(app ?? Self.sentenceCase(entry.method))
                        .font(.system(size: 13, weight: isObservation ? .regular : .medium))
                        .foregroundStyle(isObservation ? .secondary : .primary)
                        .lineLimit(1)
                    if app != nil {
                        Text(entry.method)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Text(safeSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(safeSummary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(time)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(time)
                if run.isFolded {
                    countButton(run, isExpanded: isExpanded)
                }
            }
            .frame(maxWidth: 175, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, isExpanded ? 4 : 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if run.isFolded { toggleExpansion(run) }
        }
        .contextMenu {
            if run.isFolded {
                Button(isExpanded ? "Hide entries" : "Show each entry") { toggleExpansion(run) }
                Divider()
            }
            Button("Copy summary") { Self.copy(safeSummary) }
            if let agent = entry.agent, !agent.isEmpty {
                Button("Show only \(agent)") { agentFilter = agent }
            }
            if let taskId = entry.taskId {
                Button("Copy task ID") { Self.copy(taskId) }
                Button("Show only this task") { taskFilter = taskId }
            }
            if let app = entry.targetApp, !app.isEmpty {
                Button("Show only \(app)") { appFilter = app }
            }
        }
    }

    /// Actions get a tinted badge, observations a plain faint one, failures a red one whatever their kind.
    private func kindBadge(_ kind: AuditEntryKind, method: String, success: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let tint: Color?
        let fill: Color
        switch (success, kind) {
        case (false, _):
            tint = UseMacTheme.statusRed
            fill = UseMacTheme.statusRed.opacity(colorScheme == .dark ? 0.2 : 0.12)
        case (true, .action):
            tint = UseMacTheme.accentActive
            fill = UseMacTheme.accentActive.opacity(colorScheme == .dark ? 0.22 : 0.13)
        case (true, .other):
            tint = nil
            fill = UseMacTheme.subtleFill(colorScheme)
        case (true, .observation):
            tint = nil
            fill = .clear
        }
        return Image(systemName: Self.symbol(for: kind, method: method))
            .font(.system(size: 10.5, weight: kind == .observation ? .regular : .semibold))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(kind == .observation ? .tertiary : .secondary))
            .frame(width: 20, height: 20)
            .background(fill, in: shape)
            .help(Self.kindHelp(kind))
            .accessibilityElement()
            .accessibilityLabel("\(Self.kindLabel(kind)), \(success ? "done" : "failed")")
    }

    private func countButton(_ run: AuditEntryRun, isExpanded: Bool) -> some View {
        Button {
            toggleExpansion(run)
        } label: {
            HStack(spacing: 3) {
                Text("×\(run.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(UseMacTheme.subtleFill(colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the \(run.count) entries" : "Show the \(run.count) entries")
        .accessibilityLabel("\(run.count) times, \(Self.formatRange(run.firstTimestampMs, run.lastTimestampMs))")
        .accessibilityHint(isExpanded ? "Hides each entry" : "Shows each entry")
    }

    /// One entry of an opened run: they differ only in time and latency.
    private func memberRow(_ entry: AuditEntry, isLast: Bool) -> some View {
        HStack(spacing: 14) {
            Text(Self.formatPreciseTimestamp(entry.timestampMs))
            Text(Self.formatLatency(entry.latencyMs))
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .padding(.leading, 48)
        .padding(.trailing, 16)
        .padding(.vertical, 1.5)
        .padding(.bottom, isLast ? 10 : 0)
        .contextMenu {
            Button("Copy entry ID") { Self.copy(entry.id) }
        }
    }

    private func toggleExpansion(_ run: AuditEntryRun) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expandedRuns.contains(run.id) {
                expandedRuns.remove(run.id)
            } else {
                expandedRuns.insert(run.id)
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
                Text(isFiltered
                    ? (showsObservations
                        ? "Try changing or clearing a filter."
                        : "Try changing a filter or showing observations.")
                    : "Observations and actions your agents run will appear here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                if isFiltered {
                    Button("Clear filters") {
                        resultFilter = .all
                        taskFilter = nil
                        agentFilter = nil
                        appFilter = nil
                        showsObservations = true
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
        let store = appState.engine.auditStore
        // New entries arrive in bursts while an agent works: read the files once the burst settles.
        if store != nil && hasLoaded {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard !Task.isCancelled else { return }
        let memoryEntries = store == nil ? appState.auditEntries : []
        let limit = Self.displayLimit
        let query = isFiltered ? filterQuery : nil
        let loaded = await Task.detached(priority: .userInitiated) {
            let recent = store?.entries(matching: AuditLogQuery(limit: limit)) ?? memoryEntries
            let shown = query.map { store?.entries(matching: $0) ?? $0.apply(to: memoryEntries) } ?? recent
            return (recent: recent, count: shown.count, sessions: AuditLogSessionGrouper.group(shown))
        }.value
        guard !Task.isCancelled else { return }
        recent = loaded.recent
        shownCount = loaded.count
        sessions = loaded.sessions
        if taskFilter != nil, sessions.count == 1 {
            expandedSessions.insert(sessions[0].id)
        }
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

    private static func formatDuration(_ ms: Int64) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return String(format: "%lldh %02lldm", minutes / 60, minutes % 60)
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let preciseTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func date(_ timestampMs: Int64) -> Date {
        Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
    }

    private static func formatTimestamp(_ timestampMs: Int64) -> String {
        let date = date(timestampMs)
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return dateTimeFormatter.string(from: date)
    }

    /// "00:01:43–00:01:45", with the day in front when it isn't today; one time when both fall in the same second.
    private static func formatRange(_ firstMs: Int64, _ lastMs: Int64) -> String {
        let first = date(firstMs)
        let last = date(lastMs)
        guard Calendar.current.isDate(first, inSameDayAs: last) else {
            return "\(formatTimestamp(firstMs)) – \(formatTimestamp(lastMs))"
        }
        let start = timeFormatter.string(from: first)
        let end = timeFormatter.string(from: last)
        let times = start == end ? start : "\(start)–\(end)"
        return Calendar.current.isDateInToday(last) ? times : "\(dayFormatter.string(from: last)), \(times)"
    }

    /// An entry inside an opened run, to the millisecond: repeats often fall in the same second.
    private static func formatPreciseTimestamp(_ timestampMs: Int64) -> String {
        let date = date(timestampMs)
        let time = preciseTimeFormatter.string(from: date)
        return Calendar.current.isDateInToday(date) ? time : "\(dayFormatter.string(from: date)), \(time)"
    }

    private static func formatLatency(_ latencyMs: Double) -> String {
        if latencyMs >= 1000 { return String(format: "%.2f s", latencyMs / 1000) }
        if latencyMs >= 10 { return String(format: "%.0f ms", latencyMs) }
        return String(format: "%.1f ms", latencyMs)
    }

    private static func sentenceCase(_ method: String) -> String {
        let words = method.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func symbol(for kind: AuditEntryKind, method: String) -> String {
        switch kind {
        case .action:
            switch method {
            case RPCMethod.browserOpen.rawValue: return "arrow.up.forward.square"
            case RPCMethod.browserExtract.rawValue: return "curlybraces"
            default: return "cursorarrow.click"
            }
        case .observation:
            return "eye"
        case .other:
            switch method {
            case RPCMethod.taskStart.rawValue: return "flag"
            case RPCMethod.taskComplete.rawValue: return "flag.checkered"
            case RPCMethod.setPolicy.rawValue: return "shield"
            default: return "gearshape"
            }
        }
    }

    private static func kindLabel(_ kind: AuditEntryKind) -> String {
        switch kind {
        case .action: return "Action"
        case .observation: return "Observation"
        case .other: return "Task or setting"
        }
    }

    private static func kindHelp(_ kind: AuditEntryKind) -> String {
        switch kind {
        case .action: return "Action: changed an app or a page"
        case .observation: return "Observation: only read"
        case .other: return "Task or setting change"
        }
    }
}

/// Settings → General → History: how long the audit log is kept and whether it records typed text.
struct AuditLogSettingsGroup: View {
    let store: AuditLogStore?
    /// Record typed text is sealed with the safety settings, so it is read and saved through AppState, never through
    /// the preferences directly.
    let recordsTypedText: Bool
    let setRecordsTypedText: (Bool) -> Void
    let onOpenHistory: () -> Void

    @AppStorage(AuditLogSettings.retentionDaysKey) private var retentionDays = AuditLogSettings.defaultRetentionDays
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
                CodexToggle(
                    isOn: Binding(get: { recordsTypedText }, set: { setRecordsTypedText($0) }),
                    accessibilityLabel: "Record typed text"
                )
            }

            InsetDivider(leading: 18)

            row(title: "Audit log", subtitle: "Filter by agent, app and result, or export it as JSON Lines or CSV.") {
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
