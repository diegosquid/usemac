import Foundation

/// `report_prepare`: an agent's description of a problem it hit with UseMac. UseMac turns it, the environment and the
/// task's audit entries into a draft, removes sensitive data, and shows it to the user in a review window. Nothing
/// leaves the Mac unless the user checks the report and opens it on GitHub themselves.
public struct ReportPrepareParams: Codable, Equatable, Sendable {
    /// What the agent tried, what it expected and what happened. Required.
    public var summary: String?
    /// Optional issue title. Default: the first line of `summary`.
    public var title: String?
    /// The task the report is about (the `taskId` from `task_start`). Default: the request's task, or the only
    /// running one; with neither, the report covers the last 30 minutes of activity.
    public var taskId: String?

    public static let maxSummaryLength = 4000
    public static let maxTitleLength = 120

    public init(summary: String? = nil, title: String? = nil, taskId: String? = nil) {
        self.summary = summary
        self.title = title
        self.taskId = taskId
    }

    /// The summary, trimmed and cut to `maxSummaryLength`; nil when missing or blank.
    public var resolvedSummary: String? {
        Self.cleaned(summary, maxLength: Self.maxSummaryLength)
    }

    /// The title, trimmed, on one line and cut to `maxTitleLength`; nil when missing or blank.
    public var resolvedTitle: String? {
        Self.cleaned(title?.components(separatedBy: .newlines).joined(separator: " "), maxLength: Self.maxTitleLength)
    }

    static func cleaned(_ raw: String?, maxLength: Int) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "…" : trimmed
    }
}

/// What `report_prepare` answers: the draft is waiting in UseMac's review window. It never carries the report's text
/// or what the user decides: only the user sends a report, from that window.
public struct ProblemReportReceipt: Codable, Equatable, Sendable {
    /// The only status `report_prepare` returns.
    public static let awaitingUserReview = "awaiting_user_review"

    public var reportId: String
    public var status: String
    /// The task the report covers; nil when it covers recent activity.
    public var taskId: String?
    /// How many audit entries the draft lists.
    public var entryCount: Int
    /// The error codes the draft lists, most frequent first.
    public var errorCodes: [String]
    /// What to tell the user.
    public var message: String

    public init(
        reportId: String,
        status: String = ProblemReportReceipt.awaitingUserReview,
        taskId: String? = nil,
        entryCount: Int,
        errorCodes: [String],
        message: String
    ) {
        self.reportId = reportId
        self.status = status
        self.taskId = taskId
        self.entryCount = entryCount
        self.errorCodes = errorCodes
        self.message = message
    }
}
