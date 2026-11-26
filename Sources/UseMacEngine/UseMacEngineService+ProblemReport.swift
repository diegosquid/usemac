import Foundation
import UseMacProtocol

/// Hands report drafts to the app's review window, one at a time, and keeps the recent error codes a draft lists.
///
/// The agent's side ends when the draft is on screen: nothing here tells it whether the user opened, copied or
/// cancelled the report, so it has nothing to push for.
public final class ProblemReportBroker: @unchecked Sendable {
    /// How many error codes stay in memory (all tasks together).
    public static let failureMemory = 300

    public enum Presentation: Equatable, Sendable {
        case shown
        /// Another draft is still in the review window.
        case busy
        /// No review window in this process (the CLI or MCP server without the app).
        case unavailable
    }

    private let lock = NSLock()
    private var presenter: (@Sendable (ProblemReportDraft) -> Void)?
    private var reviewingId: String?
    private var failures: [ProblemReportFailure] = []

    public init() {}

    /// The app sets this to open its review window. It is called off the main thread.
    public func setPresenter(_ presenter: (@Sendable (ProblemReportDraft) -> Void)?) {
        lock.lock()
        self.presenter = presenter
        lock.unlock()
    }

    /// The draft in the review window, if any.
    public var reviewingReportId: String? {
        lock.lock(); defer { lock.unlock() }
        return reviewingId
    }

    var canPresent: Bool {
        lock.lock(); defer { lock.unlock() }
        return presenter != nil
    }

    /// Opens the review window with `draft`, unless one is already open.
    func present(_ draft: ProblemReportDraft) -> Presentation {
        lock.lock()
        guard let presenter else {
            lock.unlock()
            return .unavailable
        }
        guard reviewingId == nil else {
            lock.unlock()
            return .busy
        }
        reviewingId = draft.id
        lock.unlock()
        presenter(draft)
        return .shown
    }

    /// The review window closed (the user opened the issue, or closed the window), so another draft may open.
    public func reviewEnded(reportId: String) {
        lock.lock()
        if reviewingId == reportId {
            reviewingId = nil
        }
        lock.unlock()
    }

    /// Keeps the error codes of a finished request.
    func record(_ response: RPCResponse, of request: RPCRequest, taskId: String?, now: Date = Date()) {
        let notes = ProblemReportFailure.notes(in: response, method: request.method, taskId: taskId, now: now)
        guard !notes.isEmpty else { return }
        lock.lock()
        failures.append(contentsOf: notes)
        if failures.count > Self.failureMemory {
            failures.removeFirst(failures.count - Self.failureMemory)
        }
        lock.unlock()
    }

    /// The codes a draft of this scope lists, oldest first.
    func failures(for scope: ProblemReportScope, now: Date = Date()) -> [ProblemReportFailure] {
        lock.lock(); defer { lock.unlock() }
        switch scope {
        case .task(let id):
            return failures.filter { $0.taskId == id }
        case .recent(let minutes):
            let since = Int64((now.timeIntervalSince1970 - Double(minutes * 60)) * 1000)
            return failures.filter { $0.timestampMs >= since }
        }
    }
}

extension UseMacEngineService {
    /// `report_prepare`: builds a redacted draft about the request's task (or recent activity) and opens it in the
    /// app's review window. It answers at once with `awaiting_user_review`; only the user sends it. It reads UseMac's
    /// own log and opens UseMac's own window, so it works in every execution mode. The Kill Switch is checked by the
    /// caller.
    func prepareProblemReport(_ request: RPCRequest, startNs: UInt64) -> RPCResponse {
        let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000 }
        let params = request.reportPrepare ?? ReportPrepareParams()
        guard let summary = params.resolvedSummary else {
            return .failure(
                id: request.id,
                code: "INVALID_REQUEST",
                message: "report_prepare needs reportPrepare.summary: what you tried, what you expected and what happened.",
                latencyMs: elapsed()
            )
        }
        guard problemReports.canPresent else {
            return .failure(
                id: request.id,
                code: "DAEMON_REQUIRED",
                message: "Only the UseMac app can show a report for the user to review. Ask the user to open UseMac, then try again.",
                latencyMs: elapsed()
            )
        }
        if problemReports.reviewingReportId != nil {
            return Self.reportInReviewResponse(request, latencyMs: elapsed())
        }

        let scope = problemReportScope(for: request)
        let status = currentStatus()
        let draft = ProblemReportComposer.compose(
            summary: summary,
            title: params.resolvedTitle,
            scope: scope,
            entries: problemReportEntries(for: scope),
            failures: problemReports.failures(for: scope),
            environment: .current(status: status),
            chromeProfileNames: Set(status.browserProfiles.map(\.profileName))
        )
        switch problemReports.present(draft) {
        case .shown:
            break
        case .busy:
            return Self.reportInReviewResponse(request, latencyMs: elapsed())
        case .unavailable:
            return .failure(id: request.id, code: "DAEMON_REQUIRED", message: "Only the UseMac app can show a report for the user to review.", latencyMs: elapsed())
        }

        let latencyMs = elapsed()
        appendAudit(
            method: request.method.rawValue,
            targetApp: nil,
            summary: "Problem report ready for the user's review (\(draft.entryCount) entr\(draft.entryCount == 1 ? "y" : "ies"))",
            latencyMs: latencyMs,
            success: true,
            taskId: scope.taskId
        )
        let receipt = ProblemReportReceipt(
            reportId: draft.id,
            taskId: draft.taskId,
            entryCount: draft.entryCount,
            errorCodes: draft.errorCodes,
            message: "The report is open in UseMac's \"Review problem report\" window. Tell the user to read it there and remove anything they don't want to share. Only they can open it as a GitHub issue; don't paste the report anywhere else."
        )
        return .success(id: request.id, latencyMs: latencyMs, problemReport: receipt)
    }

    /// The task the report is about: the one the request names (even a finished one: its entries are on disk), else
    /// the only running task; with neither, recent activity.
    func problemReportScope(for request: RPCRequest) -> ProblemReportScope {
        let named = request.namedTaskId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named, !named.isEmpty {
            return .task(named)
        }
        if let running = taskTabs.resolve(taskId: nil, tabId: nil) {
            return .task(running)
        }
        return .recent(minutes: ProblemReport.recentMinutes)
    }

    /// The scope's audit entries, newest first, from the log on disk when there is one.
    func problemReportEntries(for scope: ProblemReportScope, now: Date = Date()) -> [AuditEntry] {
        let query: AuditLogQuery
        switch scope {
        case .task(let id):
            query = AuditLogQuery(limit: AuditLogParams.maxLimit, taskId: id)
        case .recent(let minutes):
            let since = Int64((now.timeIntervalSince1970 - Double(minutes * 60)) * 1000)
            query = AuditLogQuery(limit: AuditLogParams.maxLimit, sinceMs: since)
        }
        if let auditStore {
            return auditStore.entries(matching: query)
        }
        return query.apply(to: recentAuditEntries(limit: AuditLogStore.memoryLimit))
    }

    private static func reportInReviewResponse(_ request: RPCRequest, latencyMs: Double) -> RPCResponse {
        .failure(
            id: request.id,
            code: "REPORT_IN_REVIEW",
            message: "Another problem report is still open for the user's review. Only one shows at a time: wait until the user closes it.",
            latencyMs: latencyMs
        )
    }
}
