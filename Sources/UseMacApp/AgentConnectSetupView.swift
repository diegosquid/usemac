import AppKit
import SwiftUI
import UseMacEngine

struct AgentConnectSetupGroup: View {
    @ObservedObject var appState: AppState
    @State private var statuses: [AgentClientStatus] = []
    @State private var feedback: [AgentClientID: Feedback] = [:]

    private let configurator = AgentClientConfigurator()

    private struct Inputs: Equatable {
        let cliPath: String
        let socketPath: String
        let agentDocsDir: URL
    }

    private struct Feedback {
        let message: String
        let isError: Bool
    }

    private var inputs: Inputs {
        Inputs(
            cliPath: appState.resolvedCliPath,
            socketPath: appState.status.socketPath,
            agentDocsDir: URL(fileURLWithPath: appState.resolvedAgentDocsDir, isDirectory: true)
        )
    }

    var body: some View {
        let installed = statuses.filter(\.isInstalled)
        let pending = installed.filter { $0.state != .configured }
        let otherClients = statuses.filter { !$0.isInstalled }

        SettingsGroup(title: "Quick Setup") {
            if pending.count >= 2 {
                AgentSetupClickButton(title: "Connect All", accessibilityTitle: "Connect all detected clients") { click in
                    connectAll(pending: pending, confirmedBy: click)
                }
            }
        } content: {
            if installed.isEmpty && !statuses.isEmpty {
                Text("No supported clients were detected on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
            }

            ForEach(installed) { status in
                if status.id != installed.first?.id { InsetDivider() }
                clientRow(status)
            }

            if !otherClients.isEmpty {
                InsetDivider()
                DisclosureGroup("Other supported clients") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(otherClients) { status in
                            Text(status.client.rawValue)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
            }
        }
        .task(id: inputs) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func clientRow(_ status: AgentClientStatus) -> some View {
        let action = status.state == .needsUpdate ? "Update" : "Connect"
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.client.rawValue)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(status.skillPath == nil ? "MCP" : "MCP + Skill") · ~/\(status.client.configRelativePath)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if status.state == .configured {
                    StatusDot(color: UseMacTheme.statusGreen, label: "Configured")
                        .help(status.detail)
                } else {
                    AgentSetupClickButton(title: action, accessibilityTitle: "\(action) \(status.client.rawValue)") { click in
                        connect(status.client, confirmedBy: click)
                    }
                    .id(action)
                    .help(status.detail)
                }
            }

            if let notice = feedback[status.id] {
                Text(notice.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(notice.isError ? UseMacTheme.statusRed : UseMacTheme.statusGreen)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func refresh() {
        let setup = inputs
        statuses = configurator.inspectAll(
            cliPath: setup.cliPath, socketPath: setup.socketPath, agentDocsDir: setup.agentDocsDir
        )
    }

    private func connect(_ client: AgentClientID, confirmedBy click: ApprovalInputCheck.PhysicalClick) {
        let setup = inputs
        show(Result {
            try configurator.configure(
                client: client, cliPath: setup.cliPath, socketPath: setup.socketPath,
                agentDocsDir: setup.agentDocsDir, confirmedBy: click
            )
        }, for: client)
        refresh()
    }

    private func connectAll(pending: [AgentClientStatus], confirmedBy click: ApprovalInputCheck.PhysicalClick) {
        let setup = inputs
        let pendingClients = Set(pending.map(\.client))
        let results = configurator.configureAllDetected(
            cliPath: setup.cliPath, socketPath: setup.socketPath, agentDocsDir: setup.agentDocsDir,
            confirmedBy: click
        )
        for (client, result) in results where pendingClients.contains(client) {
            show(result, for: client)
        }
        refresh()
    }

    private func show(_ result: Result<AgentClientStatus, Error>, for client: AgentClientID) {
        switch result {
        case .success:
            feedback[client] = Feedback(message: "Restart \(client.rawValue) to load the configuration.", isError: false)
        case .failure(let error):
            feedback[client] = Feedback(message: error.localizedDescription, isError: true)
        }
    }
}

/// A SwiftUI Button would expose a keyboard action and AXPress. Only ApprovalClickTarget can invoke this action.
private struct AgentSetupClickButton: View {
    let title: String
    let accessibilityTitle: String
    let onClick: (ApprovalInputCheck.PhysicalClick) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var armedAt: TimeInterval = .greatestFiniteMagnitude
    @State private var armed = false
    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(UseMacTheme.inkForeground(colorScheme))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(shape.fill(UseMacTheme.inkBackground(colorScheme).opacity(pressed ? 0.86 : 1)))
            .opacity(armed ? 1 : 0.45)
            .accessibilityHidden(true)
            .overlay {
                ApprovalClickTarget(
                    title: accessibilityTitle,
                    armedAt: armedAt,
                    onPressChange: { pressed = $0 },
                    onClick: onClick
                )
            }
            .task {
                armedAt = ProcessInfo.processInfo.systemUptime + ApprovalInputCheck.armingDelaySeconds
                armed = false
                try? await Task.sleep(for: .seconds(ApprovalInputCheck.armingDelaySeconds))
                if !Task.isCancelled { armed = true }
            }
    }
}
