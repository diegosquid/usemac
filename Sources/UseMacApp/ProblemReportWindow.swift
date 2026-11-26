import AppKit
import os
import SwiftUI
import UseMacEngine
import UseMacProtocol

/// The window where the user reviews a problem report an agent prepared (`report_prepare`), and the only place a
/// report can leave the Mac from.
///
/// Like Ask mode's prompt, it answers only to the user:
/// - the window drops every pointer event some process posted before any view sees it;
/// - the checkbox and the buttons are `ApprovalClickTarget`s, which count only a physical click made after the window
///   has been on screen a moment, and refuse AXPress;
/// - any change to the text, by the user or anything else, clears the checkbox, so what the user checked is what
///   opens.
/// "Open issue on GitHub" only opens a prefilled `issues/new` page in the browser; the user submits it there.
@MainActor
final class ProblemReportReviewController: NSObject, NSWindowDelegate {
    static let shared = ProblemReportReviewController()
    static let windowTitle = "Review problem report"

    private static let log = Logger(subsystem: "app.usemac", category: "problem-report")

    private weak var engine: UseMacEngineService?
    private var window: ProblemReportWindow?
    private var model: ProblemReportReviewModel?

    /// Lets the engine open this window for `report_prepare`.
    func attach(to engine: UseMacEngineService) {
        self.engine = engine
        engine.problemReports.setPresenter { draft in
            Task { @MainActor in
                ProblemReportReviewController.shared.show(draft)
            }
        }
    }

    private func show(_ draft: ProblemReportDraft) {
        if let open = model {
            // The broker allows one draft at a time; never swap the text under the user.
            Self.log.error("Ignored report \(draft.id, privacy: .public): report \(open.reportId, privacy: .public) is still open")
            engine?.problemReports.reviewEnded(reportId: draft.id)
            return
        }
        let model = ProblemReportReviewModel(draft: draft)
        model.armedAt = ProcessInfo.processInfo.systemUptime + ApprovalInputCheck.armingDelaySeconds
        let view = ProblemReportReviewView(
            model: model,
            onCancel: { [weak self] in self?.window?.close() },
            onCopy: { [weak self] in self?.copy() },
            onOpen: { [weak self] in self?.openOnGitHub() }
        )
        let window = ProblemReportWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700))
        window.title = Self.windowTitle
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.onIgnoredInput = { sourcePid in
            Self.log.notice("Ignored a posted click from pid \(sourcePid, privacy: .public) on the report window")
        }
        window.center()
        self.model = model
        self.window = window
        window.orderFrontRegardless()
        Self.log.notice("Opened \"\(Self.windowTitle, privacy: .public)\" for report \(draft.id, privacy: .public): \(draft.entryCount) entries, \(draft.body.count) characters")
    }

    private func copy() {
        guard let model else { return }
        Self.writeToPasteboard(model.clipboardText)
        model.copied = true
        Self.log.notice("Report \(model.reportId, privacy: .public) copied by the user")
    }

    private func openOnGitHub() {
        guard let model, model.confirmed else { return }
        let link = ProblemReportIssueLink.make(title: model.title, body: model.body)
        if link.bodyOnClipboard {
            Self.writeToPasteboard(model.body)
        }
        NSWorkspace.shared.open(link.url)
        Self.log.notice("Report \(model.reportId, privacy: .public) opened on GitHub by the user (body on clipboard: \(link.bodyOnClipboard, privacy: .public))")
        window?.close()
    }

    private static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? ProblemReportWindow, closing === window else { return }
        if let model {
            engine?.problemReports.reviewEnded(reportId: model.reportId)
            Self.log.notice("Closed the report window for report \(model.reportId, privacy: .public)")
        }
        closing.delegate = nil
        window = nil
        model = nil
    }
}

@MainActor
final class ProblemReportReviewModel: ObservableObject {
    let reportId: String
    let entryCount: Int
    @Published var title: String {
        didSet { if title != oldValue { textChanged() } }
    }
    @Published var body: String {
        didSet { if body != oldValue { textChanged() } }
    }
    /// The user checked "no personal or sensitive data". Cleared by any change to the text.
    @Published var confirmed = false
    @Published var copied = false
    /// When the checkbox and buttons go live, in `ProcessInfo.systemUptime` (the clock NSEvent timestamps use).
    @Published var armedAt: TimeInterval = .greatestFiniteMagnitude
    @Published var pressed: String?

    init(draft: ProblemReportDraft) {
        reportId = draft.id
        entryCount = draft.entryCount
        title = draft.title
        body = draft.body
    }

    var clipboardText: String {
        "\(title)\n\n\(body)"
    }

    /// The body doesn't fit in a link: opening the issue copies it first.
    var opensWithClipboard: Bool {
        ProblemReportIssueLink.make(title: title, body: body).bodyOnClipboard
    }

    private func textChanged() {
        confirmed = false
        copied = false
    }
}

/// A titled window that never handles a pointer event some process posted (another agent, a script, Screen Sharing).
final class ProblemReportWindow: NSWindow {
    var onIgnoredInput: ((Int64) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 520, height: 520)
    }

    override func sendEvent(_ event: NSEvent) {
        if Self.isPointerEvent(event.type), !ApprovalInputCheck.isPhysical(event.cgEvent) {
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                onIgnoredInput?(ApprovalInputCheck.sourcePid(of: event.cgEvent) ?? -1)
            }
            return
        }
        super.sendEvent(event)
    }

    private static func isPointerEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel, .pressure, .tabletPoint, .tabletProximity:
            return true
        default:
            return false
        }
    }
}

struct ProblemReportReviewView: View {
    @ObservedObject var model: ProblemReportReviewModel
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("An agent prepared this report about a problem with UseMac")
                    .font(.system(size: 14, weight: .semibold))
                Text("Nothing has been sent. Read it and delete anything you don't want to share. Open issue on GitHub opens a prefilled issue in your browser, and you submit it there.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                label("Title")
                TextField("Title", text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
            }

            VStack(alignment: .leading, spacing: 5) {
                label("Report")
                TextEditor(text: $model.body)
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(UseMacTheme.codeBackground(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(UseMacTheme.strongHairline(scheme), lineWidth: 0.8))
                    .frame(minHeight: 280, maxHeight: .infinity)
                Text("UseMac already removed typed text, emails, tokens and keys, your home folder, URL query strings and long numbers. Screenshots are never included. Check the rest yourself: app names, page addresses and what the agent wrote stay in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            checkbox

            if model.opensWithClipboard {
                Text("This report is too long for a link. Open issue on GitHub copies it, and you paste it into the issue.")
                    .font(.system(size: 11))
                    .foregroundStyle(UseMacTheme.statusAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                button("Cancel", id: "cancel", primary: false, enabled: true, action: onCancel)
                Spacer(minLength: 0)
                if model.copied {
                    Text("Copied")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                button("Copy", id: "copy", primary: false, enabled: true, action: onCopy)
                button("Open issue on GitHub", id: "open", primary: true, enabled: model.confirmed, action: onOpen)
            }

            Text("Click with your mouse or trackpad; agents can't check the box or press these buttons.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
        .background(UseMacTheme.canvas(scheme))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var checkbox: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let title = "I checked this report and it has no personal or sensitive data"
        return HStack(spacing: 8) {
            ZStack {
                shape
                    .fill(model.confirmed ? UseMacTheme.inkBackground(scheme) : UseMacTheme.surface(scheme))
                shape
                    .strokeBorder(UseMacTheme.strongHairline(scheme), lineWidth: model.confirmed ? 0 : 1)
                if model.confirmed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(UseMacTheme.inkForeground(scheme))
                }
            }
            .frame(width: 15, height: 15)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .overlay(
            ApprovalClickTarget(
                title: title,
                armedAt: model.armedAt,
                onPressChange: { _ in },
                onClick: { _ in model.confirmed.toggle() }
            )
        )
    }

    private func button(_ title: String, id: String, primary: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let isPressed = model.pressed == id && enabled
        return Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? UseMacTheme.inkForeground(scheme) : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                shape.fill(primary
                    ? UseMacTheme.inkBackground(scheme).opacity(isPressed ? 0.8 : 1)
                    : (isPressed ? UseMacTheme.hoverFill(scheme) : UseMacTheme.surface(scheme)))
            )
            .overlay(shape.strokeBorder(UseMacTheme.strongHairline(scheme), lineWidth: primary ? 0 : 0.8))
            .opacity(enabled ? 1 : 0.4)
            .accessibilityHidden(true)
            .overlay(
                ApprovalClickTarget(
                    title: title,
                    armedAt: model.armedAt,
                    onPressChange: { pressing in model.pressed = pressing ? id : nil },
                    onClick: { _ in
                        guard enabled else { return }
                        action()
                    }
                )
            )
    }
}
