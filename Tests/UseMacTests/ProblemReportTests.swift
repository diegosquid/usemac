import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

private let redactor = ProblemReportRedactor(
    homeDirectory: "/Users/alice",
    identities: [
        .init("Alice's MacBook Pro", placeholder: "[computer name]"),
        .init("Alice Example", placeholder: "[name]"),
        .init("alicex", placeholder: "[user]"),
        .init("dev", placeholder: "[user]")
    ]
)

private func entry(
    _ summary: String,
    secondsAfter offset: Double,
    method: String = "act",
    app: String? = "TextEdit",
    success: Bool = true,
    taskId: String? = "task-1a2b3c4d",
    latencyMs: Double = 12
) -> AuditEntry {
    AuditEntry(
        timestampMs: 1_780_000_000_000 + Int64(offset * 1000),
        method: method,
        targetApp: app,
        summary: summary,
        latencyMs: latencyMs,
        success: success,
        taskId: taskId
    )
}

private let environment = ProblemReportEnvironment(
    appVersion: "0.6.0-beta.3",
    appBuild: "62",
    macOSVersion: "15.7 (Build 24G222)",
    architecture: "arm64",
    executionMode: "ask",
    killSwitchTripped: false,
    accessibilityGranted: true,
    screenRecordingGranted: false,
    chromeExtensions: ["0.6.0 from UseMac.app (2 profiles)"]
)

final class ProblemReportRedactionTests: XCTestCase {
    func testHomeFolderBecomesTildeAndOtherUsersAreHidden() {
        XCTAssertEqual(redactor.redact("Saved /Users/alice/Documents/notes.txt"), "Saved ~/Documents/notes.txt")
        XCTAssertEqual(redactor.redact("cd /Users/alice"), "cd ~")
        XCTAssertEqual(redactor.redact("/Users/alicebob/x"), "/Users/[user]/x", "only the exact home folder becomes ~")
        XCTAssertEqual(redactor.redact("/Users/Shared/report.pdf"), "/Users/Shared/report.pdf")
    }

    func testURLsLoseCredentialsQueryAndFragment() {
        XCTAssertEqual(
            redactor.redact("Opened https://bob:pw@example.com/a/b?token=1&page=2#top."),
            "Opened https://example.com/a/b?[query removed]."
        )
        XCTAssertEqual(redactor.redact("see https://example.com/inbox#msg-42"), "see https://example.com/inbox#[fragment removed]")
        XCTAssertEqual(redactor.redact("http://127.0.0.1:8742/form.html"), "http://127.0.0.1:8742/form.html")
        XCTAssertEqual(redactor.redact("[link](https://example.com/a?b=c)"), "[link](https://example.com/a?[query removed])")
    }

    func testEmailsTokensAndKeysAreRemoved() {
        let text = """
        mail alice.example+test@gmail.com
        key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv
        gh ghp_0123456789abcdefghijABCDEFGHIJ012345
        aws AKIAIOSFODNN7EXAMPLE
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
        pairing umk_9f8e7d6c5b4a
        Authorization: Bearer abcdefghijklmnop1234
        password=hunter2 and "api_key": "abc123"
        id a1b2c3d4e5f6a7b8c9d0e1f2a3b4
        """
        let out = redactor.redact(text)
        for leaked in ["gmail", "sk-ant", "ghp_", "AKIA", "eyJ", "umk_9f", "abcdefghijklmnop1234", "hunter2", "abc123", "a1b2c3d4e5f6"] {
            XCTAssertFalse(out.contains(leaked), "\(leaked) survived:\n\(out)")
        }
        XCTAssertTrue(out.contains("mail [email]"))
        XCTAssertTrue(out.contains("Bearer [secret]"))
        XCTAssertTrue(out.contains("password=[secret]"))
        XCTAssertTrue(out.contains("id [token]"))
    }

    func testOrdinaryTextCodesAndTaskIdsSurvive() {
        let text = "usemac_browser_reload_extension failed with ELEMENT_NOT_FOUND in task-1a2b3c4d and task-20261126 after 12345 ms (1234567 bytes), macOS 15.7 (Build 24G222)"
        XCTAssertEqual(redactor.redact(text), text)
    }

    func testLongNumbersAndAddressesAreRemoved() {
        XCTAssertEqual(redactor.redact("card 4111 1111 1111 1111"), "card [number]")
        XCTAssertEqual(redactor.redact("call +55 11 98765-4321"), "call [number]")
        XCTAssertEqual(redactor.redact("code 123456 sent"), "code [number] sent")
        XCTAssertEqual(redactor.redact("host 192.168.1.20 and 127.0.0.1"), "host [ip] and 127.0.0.1")
    }

    func testNamesWindowTitlesAndChromeProfilesAreRemoved() {
        XCTAssertEqual(redactor.redact("Busy: TextEdit window \"Contract for Bob.rtf\""), "Busy: TextEdit window \"[title]\"")
        XCTAssertEqual(redactor.redact("Started in Chrome (Work)"), "Started in Chrome")
        XCTAssertEqual(redactor.redact("Alice's MacBook Pro, owner ALICE EXAMPLE, account alicex"), "[computer name], owner [name], account [user]")
        XCTAssertEqual(redactor.redact("a dev build"), "a dev build", "names shorter than 4 characters are left alone")
        XCTAssertEqual(redactor.redact("alicexyz"), "alicexyz", "a name only matches as a whole word")
    }

    func testPrivateKeyBlocksAreRemoved() {
        let text = "before -----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY----- after"
        XCTAssertEqual(redactor.redact(text), "before [private key] after")
    }
}

final class ProblemReportComposerTests: XCTestCase {
    func testDraftListsTheTaskOldestFirstWithEnvironmentAndCodes() {
        let newestFirst = [
            entry("Problem report ready for the user's review (2 entries)", secondsAfter: 9, method: "report_prepare", app: nil),
            entry("Executed 1 step(s): failed · click", secondsAfter: 3.2, success: false, latencyMs: 1400),
            entry("Reviewing contract for alice.example@gmail.com", secondsAfter: 0, method: "task_start", app: "Chrome (Alice)")
        ]
        let failures = [
            ProblemReportFailure(timestampMs: 1, taskId: "task-1a2b3c4d", method: "act", step: "click", code: "ELEMENT_NOT_FOUND"),
            ProblemReportFailure(timestampMs: 2, taskId: "task-1a2b3c4d", method: "observe", code: "STALE_SNAPSHOT"),
            ProblemReportFailure(timestampMs: 3, taskId: "task-1a2b3c4d", method: "act", step: "click", code: "ELEMENT_NOT_FOUND")
        ]
        let draft = ProblemReportComposer.compose(
            id: "r1",
            summary: "Tried to click Save in TextEdit.\nExpected the sheet; got ELEMENT_NOT_FOUND. Files are in /Users/alice/Desktop.",
            title: nil,
            scope: .task("task-1a2b3c4d"),
            entries: newestFirst,
            failures: failures,
            environment: environment,
            chromeProfileNames: ["Alice"],
            redactor: redactor
        )

        XCTAssertEqual(draft.id, "r1")
        XCTAssertEqual(draft.title, "Tried to click Save in TextEdit.")
        XCTAssertEqual(draft.taskId, "task-1a2b3c4d")
        XCTAssertEqual(draft.entryCount, 2, "the report_prepare entry is left out")
        XCTAssertEqual(draft.errorCodes, ["ELEMENT_NOT_FOUND", "STALE_SNAPSHOT"])

        let body = draft.body
        XCTAssertTrue(body.contains("### What happened\n\nTried to click Save in TextEdit.\nExpected the sheet; got ELEMENT_NOT_FOUND. Files are in ~/Desktop."))
        XCTAssertTrue(body.contains("- UseMac 0.6.0-beta.3 (build 62)"))
        XCTAssertTrue(body.contains("- macOS 15.7 (Build 24G222), arm64"))
        XCTAssertTrue(body.contains("- Execution mode: `ask`"))
        XCTAssertTrue(body.contains("- Permissions: Accessibility granted, Screen Recording not granted"))
        XCTAssertTrue(body.contains("- Chrome extension: 0.6.0 from UseMac.app (2 profiles)"))
        XCTAssertTrue(body.contains("- `ELEMENT_NOT_FOUND` in act › click (2×)\n- `STALE_SNAPSHOT` in observe (1×)"))
        XCTAssertTrue(body.contains("Task `task-1a2b3c4d`: 2 audit entries, oldest first."))

        let lines = body.components(separatedBy: "\n")
        let start = try! XCTUnwrap(lines.firstIndex(of: "```text"))
        XCTAssertEqual(lines[start + 1], "+0:00.0  ok      12 ms    task_start  Chrome    Reviewing contract for [email]")
        XCTAssertEqual(lines[start + 2], "+0:03.2  FAILED  1.4 s    act         TextEdit  Executed 1 step(s): failed · click")
        XCTAssertEqual(lines[start + 3], "```")
        XCTAssertFalse(body.contains("gmail"))
        XCTAssertFalse(body.contains("Alice"))
        XCTAssertTrue(body.contains("No screenshots."))
    }

    func testDraftKeepsTheMostRecentEntriesAndSaysHowManyAreLeftOut() {
        let count = ProblemReport.maxEntries + 5
        let newestFirst = (0..<count).reversed().map { entry("step \($0)", secondsAfter: Double($0)) }
        let params = ReportPrepareParams(summary: "  Many steps  ", title: "  A title\nwith two lines  ")
        let draft = ProblemReportComposer.compose(
            summary: try! XCTUnwrap(params.resolvedSummary),
            title: params.resolvedTitle,
            scope: .task("task-1a2b3c4d"),
            entries: newestFirst,
            failures: [],
            environment: environment,
            redactor: redactor
        )
        XCTAssertEqual(draft.title, "A title with two lines")
        XCTAssertTrue(draft.body.hasPrefix("### What happened\n\nMany steps\n\n"))
        XCTAssertEqual(draft.entryCount, ProblemReport.maxEntries)
        XCTAssertTrue(draft.body.contains("the last \(ProblemReport.maxEntries) of \(count) audit entries"))
        XCTAssertTrue(draft.body.contains("step 5"))
        XCTAssertFalse(draft.body.contains("step 4\n"))
        XCTAssertTrue(draft.body.contains("None recorded."))
    }

    func testRecentScopeWithoutEntriesHasNoActivityBlock() {
        let draft = ProblemReportComposer.compose(
            summary: "It hung",
            title: nil,
            scope: .recent(minutes: 30),
            entries: [],
            failures: [],
            environment: environment,
            redactor: redactor
        )
        XCTAssertNil(draft.taskId)
        XCTAssertEqual(draft.entryCount, 0)
        XCTAssertTrue(draft.body.contains("No task named, so this is the last 30 minutes of activity: no audit entries."))
        XCTAssertFalse(draft.body.contains("```text"))
    }

    func testEntrySummariesStayInsideTheCodeBlock() {
        let draft = ProblemReportComposer.compose(
            summary: "x",
            title: nil,
            scope: .task("t1"),
            entries: [entry("line one\n```\n# injected heading" + String(repeating: "z", count: 300), secondsAfter: 0)],
            failures: [],
            environment: environment,
            redactor: redactor
        )
        let block = draft.body.components(separatedBy: "```text\n")[1].components(separatedBy: "\n```")[0]
        XCTAssertEqual(block.components(separatedBy: "\n").count, 1)
        XCTAssertTrue(block.contains("line one ''' # injected heading"))
        XCTAssertTrue(block.hasSuffix("…"))
    }

    func testDefaultTitleIsTheFirstLineCutAtAWord() {
        XCTAssertEqual(ProblemReportComposer.defaultTitle(from: "\n  Short title  \nmore"), "Short title")
        let long = String(repeating: "word ", count: 30)
        let title = ProblemReportComposer.defaultTitle(from: long)
        XCTAssertLessThanOrEqual(title.count, 81)
        XCTAssertTrue(title.hasSuffix("word…"))
    }

    func testExtensionLinesHideProfileNamesAndCountDuplicates() {
        let profile = { (name: String, version: String, source: String?, outdated: Bool) -> BrowserProfileStatus in
            var status = BrowserProfileStatus(id: name, profileName: name, profileEmail: "\(name)@example.com", extensionVersion: version, tabCount: 3)
            status.extensionSource = source
            status.extensionOutdated = outdated
            status.bundledExtensionVersion = "0.6.1"
            return status
        }
        let lines = ProblemReportEnvironment.extensionLines([
            profile("Work", "0.6.1", "app", false),
            profile("Home", "0.6.1", "app", false),
            profile("Old", "0.5.0", "other_folder", true)
        ])
        XCTAssertEqual(lines, ["0.6.1 from UseMac.app (2 profiles)", "0.5.0 unpacked from another folder, outdated (the app ships 0.6.1)"])
    }
}

final class ProblemReportIssueLinkTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testShortReportGoesInTheLink() {
        let body = "### What happened\n\nA+B & C = 100% #1?"
        let link = ProblemReportIssueLink.make(title: "Save fails: \"match\"", body: body)
        XCTAssertFalse(link.bodyOnClipboard)
        XCTAssertTrue(link.url.absoluteString.hasPrefix("https://github.com/diegosquid/usemac/issues/new?title="))
        XCTAssertTrue(link.url.absoluteString.contains("A%2BB%20%26%20C"), "+ and & must be encoded")
        XCTAssertEqual(query(link.url)["title"], "Save fails: \"match\"")
        XCTAssertEqual(query(link.url)["body"], body)
    }

    func testLongReportGoesToTheClipboard() {
        let body = String(repeating: "é long line of audit activity\n", count: 400)
        let link = ProblemReportIssueLink.make(title: "Title", body: body)
        XCTAssertTrue(link.bodyOnClipboard)
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ProblemReportIssueLink.maxURLLength)
        XCTAssertEqual(query(link.url)["title"], "Title")
        XCTAssertEqual(query(link.url)["body"], ProblemReportIssueLink.clipboardNote)
    }

    func testLinkLengthLimitIsExact() {
        let fits = ProblemReportIssueLink.make(title: "t", body: "abc", maxLength: 200)
        XCTAssertFalse(fits.bodyOnClipboard)
        let limit = fits.url.absoluteString.count
        XCTAssertFalse(ProblemReportIssueLink.make(title: "t", body: "abc", maxLength: limit).bodyOnClipboard)
        XCTAssertTrue(ProblemReportIssueLink.make(title: "t", body: "abcd", maxLength: limit).bodyOnClipboard)
    }

    func testRepositoryIsUseMacs() {
        XCTAssertEqual(ProblemReport.githubRepository, "diegosquid/usemac")
    }
}

final class ProblemReportFlowTests: XCTestCase {
    private func makeService() -> UseMacEngineService {
        UseMacEngineService(socketPath: "/tmp/usemac-report-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
    }

    private final class Presented: @unchecked Sendable {
        private let lock = NSLock()
        private var drafts: [ProblemReportDraft] = []
        func add(_ draft: ProblemReportDraft) { lock.lock(); drafts.append(draft); lock.unlock() }
        var all: [ProblemReportDraft] { lock.lock(); defer { lock.unlock() }; return drafts }
    }

    private func report(_ summary: String? = "It failed", taskId: String? = nil) -> RPCRequest {
        RPCRequest(method: .reportPrepare, reportPrepare: ReportPrepareParams(summary: summary, taskId: taskId))
    }

    func testFailureNotesComeFromTheResponseAndItsSteps() {
        let failed = RPCResponse.failure(id: "1", code: "APP_NOT_FOUND", message: "no")
        let notes = ProblemReportFailure.notes(in: failed, method: .pairApp, taskId: "t1")
        XCTAssertEqual(notes.map(\.code), ["APP_NOT_FOUND"])
        XCTAssertEqual(notes.first?.method, "pair_app")
        XCTAssertEqual(notes.first?.taskId, "t1")

        var step = ActionStepResult(index: 0, action: .click, success: false, mechanism: "ax", latencyMs: 1)
        step.errorCode = "ELEMENT_NOT_FOUND"
        let ok = ActionStepResult(index: 1, action: .type, success: true, mechanism: "ax", latencyMs: 1)
        let batch = RPCResponse.success(id: "2", latencyMs: 1, actionResult: BatchActionResult(success: false, totalLatencyMs: 2, stepResults: [step, ok]))
        XCTAssertEqual(ProblemReportFailure.notes(in: batch, method: .act, taskId: nil).map { "\($0.step ?? "-"):\($0.code)" }, ["click:ELEMENT_NOT_FOUND"])

        let own = RPCResponse.failure(id: "3", code: "REPORT_IN_REVIEW", message: "busy")
        XCTAssertTrue(ProblemReportFailure.notes(in: own, method: .reportPrepare, taskId: nil).isEmpty)
    }

    func testWithoutTheAppThereIsNoReviewWindow() async {
        let service = makeService()
        let response = await service.handle(report())
        XCTAssertEqual(response.error?.code, "DAEMON_REQUIRED")
    }

    func testSummaryIsRequired() async {
        let service = makeService()
        service.problemReports.setPresenter { _ in }
        let response = await service.handle(report("   "))
        XCTAssertEqual(response.error?.code, "INVALID_REQUEST")
    }

    func testReportOpensOnceAndAnswersWithoutTheText() async throws {
        let service = makeService()
        let presented = Presented()
        service.problemReports.setPresenter { presented.add($0) }

        let started = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "Testing")))
        let taskId = try XCTUnwrap(started.taskId)
        let failed = await service.handle(RPCRequest(method: .pairApp, appTarget: "NoSuchApp-\(UUID().uuidString.prefix(6))", taskId: taskId))
        XCTAssertEqual(failed.error?.code, "APP_NOT_FOUND")

        let response = await service.handle(report("Pairing failed for alice@example.com"))
        XCTAssertTrue(response.ok, "\(String(describing: response.error))")
        let receipt = try XCTUnwrap(response.problemReport)
        XCTAssertEqual(receipt.status, "awaiting_user_review")
        XCTAssertEqual(receipt.taskId, taskId, "without taskId the only running task is used")
        XCTAssertEqual(receipt.errorCodes, ["APP_NOT_FOUND"])
        XCTAssertEqual(receipt.entryCount, 2)

        let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Pairing failed"), "the agent never gets the report's text back")

        let draft = try XCTUnwrap(presented.all.first)
        XCTAssertEqual(draft.id, receipt.reportId)
        XCTAssertTrue(draft.body.contains("Pairing failed for [email]"))
        XCTAssertTrue(draft.body.contains("Pair failed: app not found"))
        XCTAssertTrue(draft.body.contains("`APP_NOT_FOUND` in pair_app (1×)"))

        let second = await service.handle(report("Again"))
        XCTAssertEqual(second.error?.code, "REPORT_IN_REVIEW")
        XCTAssertEqual(presented.all.count, 1, "the text under review is never replaced")

        service.problemReports.reviewEnded(reportId: receipt.reportId)
        let third = await service.handle(report("Again", taskId: "task-other"))
        XCTAssertTrue(third.ok)
        XCTAssertEqual(third.problemReport?.taskId, "task-other", "an explicit taskId wins, even for a finished task")
        XCTAssertEqual(third.problemReport?.entryCount, 0)
    }

    func testWorksWhilePausedButNotUnderTheKillSwitch() async {
        let service = makeService()
        service.problemReports.setPresenter { _ in }
        service.setGovernancePolicy(.paused)
        let paused = await service.handle(report())
        XCTAssertTrue(paused.ok, "\(String(describing: paused.error))")
        service.problemReports.reviewEnded(reportId: paused.problemReport?.reportId ?? "")

        service.tripKillSwitch(true)
        let stopped = await service.handle(report())
        XCTAssertEqual(stopped.error?.code, "POLICY_BLOCKED")
    }

    func testRequestDecodesFromTheSocket() throws {
        let line = #"{"method":"report_prepare","taskId":"task-9","reportPrepare":{"summary":"S","title":"T"}}"#
        let request = try JSONDecoder().decode(RPCRequest.self, from: Data(line.utf8))
        XCTAssertEqual(request.method, .reportPrepare)
        XCTAssertEqual(request.reportPrepare?.summary, "S")
        XCTAssertEqual(request.namedTaskId, "task-9")
        let withParamsTask = RPCRequest(method: .reportPrepare, taskId: "task-2", reportPrepare: ReportPrepareParams(summary: "S", taskId: "task-1"))
        XCTAssertEqual(withParamsTask.namedTaskId, "task-1")
    }
}
