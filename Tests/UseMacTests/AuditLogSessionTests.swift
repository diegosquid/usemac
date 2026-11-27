import XCTest
@testable import UseMacEngine
import UseMacProtocol

final class AuditLogSessionTests: XCTestCase {
    func testRedactsKnownTokenFormatsAndJWTsInFreeText() {
        let tokens = [
            "sk-abcdefghijklmnop", "sk-ant-abcdefghijklmnop", "umk_abcdefghijklmnop",
            "pk_live_123456789abc", "rk_test_123456789abc", "ghp_abcdefghijklmnopqrst",
            "github_pat_abcdefghijklmnopqrst_uv", "glpat-abcdefghijklmnop", "xoxb-123456789-abc",
            "AKIAABCDEFGHIJKLMNOP", "AIzaabcdefghijklmnopqrst"
        ]
        XCTAssertEqual(
            AuditRedactor.scrubSensitivePatterns(in: tokens.joined(separator: ", ")),
            Array(repeating: "[redacted-token]", count: tokens.count).joined(separator: ", ")
        )
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fwp"
        XCTAssertEqual(AuditRedactor.scrubSensitivePatterns(in: "Received \(jwt)"), "Received [redacted-jwt]")
        XCTAssertEqual(AuditRedactor.scrubSensitivePatterns(in: "Bearer abcDEF_123+= then Bearer short"),
                       "Bearer [redacted] then Bearer short")
    }

    func testRedactsInlineCredentialsWithoutTouchingURLMasks() {
        let raw = #"password=hunter2, passwd='two words', "api_key": "a quote \" in the value", Authorization: Bearer abcDEF_123, Cookie: session=private; theme=private"#
        let expected = #"password=[redacted], passwd=[redacted], "api_key": [redacted], Authorization: Bearer [redacted], Cookie: [redacted]"#
        let redacted = AuditRedactor.scrubSensitivePatterns(in: raw)
        XCTAssertEqual(redacted, expected)
        XCTAssertEqual(AuditRedactor.scrubSensitivePatterns(in: redacted), expected)
        XCTAssertEqual(
            AuditRedactor.scrubSensitivePatterns(in: "Opened https://***@example.com/path?api_key=***&q=1#***"),
            "Opened https://***@example.com/path?api_key=***&q=1#***"
        )
    }

    func testAlwaysScrubsTaskStartAndCompleteBeforeAuditStorage() async {
        let service = UseMacEngineService(socketPath: "/tmp/unused-session-audit.sock", extensionPort: 0)
        let taskId = "test-session-audit"
        _ = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(
            summary: "Preparing sk-abcdefghijklmnop", taskId: taskId
        )))
        _ = await service.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(
            summary: "Finished for test@example.com", taskId: taskId
        )))
        let result = await service.handle(RPCRequest(method: .auditLog, auditLog: AuditLogParams(taskId: taskId)))
        XCTAssertEqual(result.auditEntries?.map(\.summary), ["Finished for [redacted-email]", "Preparing [redacted-token]"])
    }

    func testRecordingTypedTextStillStripsExplicitSecrets() {
        let text = "Meeting notes for test@example.com with sk-abcdefghijklmnop"
        XCTAssertEqual(AuditRedactor.scrub(text, secrets: [text], recordText: true),
                       "Meeting notes for [redacted-email] with [redacted-token]")
    }

    func testRedactsOnlyValidCardCandidatesAndRecognizesDocumentsAndEmail() {
        let raw = "test+history@example.com and ***@example.com; 4111 1111 1111 1111, 4111-1111-1111-1112, "
            + "1732575600000, 4222222222222, 123.456.789-09, 123-45-6789"
        XCTAssertEqual(
            AuditRedactor.scrubSensitivePatterns(in: raw),
            "[redacted-email] and ***@example.com; [redacted-card], 4111-1111-1111-1112, "
                + "1732575600000, [redacted-card], [redacted-id], [redacted-id]"
        )
        XCTAssertEqual(AuditRedactor.scrubSensitivePatterns(in: "ID 1732575600000 4111 1111 1111 1111 43"),
                       "ID 1732575600000 [redacted-card] 43")
    }

    func testRedactsFullAndSingleLinePrivateKeys() {
        let raw = """
        Before -----BEGIN RSA PRIVATE KEY-----
        cHJpdmF0ZS1rZXktZGF0YQ==
        -----END RSA PRIVATE KEY----- after
        -----BEGIN PRIVATE KEY-----cHJpdmF0ZS1rZXktZGF0YQ==
        Next line
        """
        XCTAssertEqual(AuditRedactor.scrubSensitivePatterns(in: raw), "Before [redacted-key] after\n[redacted-key]\nNext line")
    }

    func testSanitizeTitleKeepsHostAndBasenameButDropsQuotedTextAndPrivatePaths() {
        let raw = """
        \tOpen   https://user:pass@app.example.com/secret/path?foo=bar#private
        Review "this is a private prompt" and 'another private message' at /Users/diego/.ssh/id_rsa
        Save  ~/Documents/notes.txt
        """
        XCTAssertEqual(AuditRedactor.sanitizeTitle(raw, maxLength: 120),
                       #"Open app.example.com Review "[redacted]" and "[redacted]" at [path] Save …/notes.txt"#)
        XCTAssertEqual(AuditRedactor.sanitizeTitle("Use /Users/diego/Work/.env and ~/Documents/signing.pem"), "Use [path] and [path]")
        XCTAssertEqual(AuditRedactor.sanitizeTitle("Save /Users/diego/Work/quarterly\\ report.txt"), "Save …/quarterly report.txt")
        XCTAssertEqual(AuditRedactor.sanitizeTitle(#"Read "15 chars only..""#), #"Read "15 chars only..""#)
        XCTAssertEqual(AuditRedactor.sanitizeTitle(#"Read "16 chars only...""#), #"Read "[redacted]""#)
    }

    func testSanitizeTitleSkipsGenericOrBlankTextAndBoundsDisplayLength() {
        for generic in ["", " \n\t", "Working…", "working...", "Task\tstarted", "Task   completed"] {
            XCTAssertNil(AuditRedactor.sanitizeTitle(generic))
        }
        XCTAssertEqual(AuditRedactor.sanitizeTitle("Read 👩🏾‍💻 notes", maxLength: 7), "Read 👩🏾‍💻…")
        XCTAssertEqual(AuditRedactor.sanitizeTitle("Read Notes", maxLength: 1), "…")
        XCTAssertNil(AuditRedactor.sanitizeTitle("Read Notes", maxLength: 0))
    }

    func testExplicitTasksRegroupAcrossOtherTasksAgentsAndLongGaps() throws {
        let events = [
            entry("a-done", at: 400_000, .taskComplete, "Closed the report", task: "a", agent: " ", app: "Agent"),
            entry("b-read", at: 300_000, .observe, "Read the report", task: "b", agent: "Codex", app: "Notes"),
            entry("adhoc", at: 200_000, .observe, "Observed", agent: "Codex", app: "Notes"),
            entry("a-click", at: 100_000, .act, "click", task: "a", agent: "  New agent ", app: "Chrome (Work)"),
            entry("b-start", at: 10, .taskStart, "Start the report", task: "b", agent: "Codex", app: "Notes"),
            entry("a-start", at: 0, .taskStart, "Open https://test:pw@example.com/private?q=hidden", task: "a", agent: "Old agent", app: "Notes")
        ]
        let sessions = AuditLogSessionGrouper.group(events)
        XCTAssertEqual(sessions.map(\.id), ["task:a", "task:b", "adhoc:adhoc"])
        XCTAssertEqual(sessions.flatMap(\.entries).map(\.id).sorted(), events.map(\.id).sorted())
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.entries.map(\.id), ["a-done", "a-click", "a-start"])
        XCTAssertEqual(session.title, "Open example.com")
        XCTAssertEqual(session.taskId, "a")
        XCTAssertEqual(session.agentName, "New agent")
        XCTAssertEqual(session.apps, ["Chrome (Work)", "Notes"])
        XCTAssertEqual(session.primaryApp, "Chrome (Work)")
        XCTAssertEqual(session.firstTimestampMs, 0)
        XCTAssertEqual(session.lastTimestampMs, 400_000)
        XCTAssertEqual(session.durationMs, 400_000)
        XCTAssertTrue(session.isExplicitTask)
        XCTAssertTrue(session.isCompleted)
        XCTAssertFalse(sessions[1].isCompleted)
    }

    func testAdHocGroupsByNormalizedAgentAndGapBetweenItsOwnNeighbors() {
        let events = [
            entry("latest", at: 360_001, .observe, "Observed", agent: "  Codex\n", app: "Notes"),
            entry("other-agent", at: 240_002, .observe, "Observed", agent: "Claude", app: "Notes"),
            entry("exact-gap", at: 240_001, .observe, "Observed", agent: "codex", app: "Chrome (Work)"),
            entry("same-session-oldest", at: 120_001, .observe, "Observed", agent: "CODEX"),
            entry("older-session", at: 0, .observe, "Observed", agent: "Codex")
        ]
        let sessions = AuditLogSessionGrouper.group(events)
        XCTAssertEqual(sessions.map { $0.entries.map(\.id) },
                       [["latest", "exact-gap", "same-session-oldest"], ["other-agent"], ["older-session"]])
        XCTAssertEqual(sessions[0].id, "adhoc:same-session-oldest")
        XCTAssertEqual(sessions[0].agentName, "Codex")
        XCTAssertFalse(sessions[0].isExplicitTask)
        XCTAssertEqual(AuditLogSessionGrouper.group(Array(events.dropFirst()))
            .first { $0.agentName == "codex" }?.id, sessions[0].id)
        XCTAssertEqual(AuditLogSessionGrouper.group(events, adHocGapMs: 5_000).count, events.count)
    }

    func testMissingAgentsUseTheirAppAndTimestampTiesSortByID() {
        let events = [
            entry("c", at: 1, .observe, "Observed", app: "Notes"),
            entry("b", at: 1, .observe, "Observed", app: "Chrome"),
            entry("a", at: 1, .observe, "Observed", agent: "Notes", app: "Notes"),
            entry("older-chrome", at: 0, .observe, "Observed", app: "chrome"),
            entry("unnamed", at: 0, .observe, "Observed")
        ]
        let sessions = AuditLogSessionGrouper.group(events)
        XCTAssertEqual(sessions.map(\.id), ["adhoc:a", "adhoc:c", "adhoc:older-chrome", "adhoc:unnamed"])
        XCTAssertEqual(sessions[2].entries.map(\.id), ["b", "older-chrome"])
        XCTAssertEqual(sessions[2].apps, ["Chrome", "chrome"])
        XCTAssertNil(sessions[2].agentName)
        XCTAssertTrue(AuditLogSessionGrouper.group([]).isEmpty)
    }

    func testSynthesizesTitleFromFormAndEvalWithoutCopyingFreeText() throws {
        let events = [
            entry("eval", at: 2, .browserExtract, "Eval (103 chars): hiddenScript('test@example.com, uploadFile')", agent: "Codex", app: "Chrome (Work)"),
            entry("act", at: 1, .browserAct, "Executed 2 browser step(s): ok · fillForm (2 fields), click",
                  agent: "Codex", app: "Chrome (Work)")
        ]
        let session = try XCTUnwrap(AuditLogSessionGrouper.group(events).first)
        XCTAssertEqual(session.title, "Filled form & ran page script in Chrome (Work)")
        XCTAssertEqual(session.summaryLine, "2 actions · Chrome (Work)")
    }

    func testTitleUsesUsableTaskStartThenCompletionAndCanFallBackToActivity() {
        let genericStart = entry("generic", at: 4, .taskStart, "Working…")
        let end = entry("done", at: 3, .taskComplete, "Finished checking Notes")
        let oldStart = entry("old", at: 2, .taskStart, "Check Notes")
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [genericStart, end, oldStart], apps: []), "Check Notes")
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [genericStart, end], apps: []), "Finished checking Notes")
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [genericStart], apps: ["Notes"]), "Activity in Notes")
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [genericStart], apps: []), "Agent activity")
    }

    func testStructuralTitleUsesPluralVerbsAndSanitizesAppLabels() {
        let open = entry("open", at: 3, .browserOpen, "Opened https://private.example/hidden")
        let action = entry("act", at: 2, .browserAct, "navigate https://other.example/hidden, doubleClick")
        let read = entry("read", at: 1, .observe, "Untrusted screen text")
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [open, action, read], apps: ["Chrome (test@example.com)"]),
                       "Opened pages & clicked in Chrome ([redacted-email])")
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [action], apps: ["Agent"]), "Opened page & clicked")
        let typed = entry("typed", at: 0, .act, #"type "test@example.com, uploadFile", click"#)
        XCTAssertEqual(AuditLogSessionGrouper.makeTitle(entries: [typed], apps: []), "Entered text & clicked")
    }

    func testSessionCountsAndFoldsEntriesWithoutHidingFailures() throws {
        let task = "folded"
        let entries = [
            entry("done", at: 7, .taskComplete, "Task completed", task: task, app: "Agent"),
            entry("click2", at: 6, .act, "click", task: task, app: "Notes"),
            entry("click1", at: 5, .act, "click", task: task, app: "Notes"),
            entry("eval", at: 4, .browserExtract, "Eval (103 chars)", task: task, app: "Notes", success: false),
            entry("read2", at: 3, .observe, "Observed", task: task, app: "Notes"),
            entry("read1", at: 2, .observe, "Observed", task: task, app: "Notes"),
            entry("start", at: 1, .taskStart, "Working…", task: task, app: "Notes")
        ]
        let session = try XCTUnwrap(AuditLogSessionGrouper.group(entries).first)
        XCTAssertEqual(session.entries, entries)
        XCTAssertEqual(session.runs.map(\.count), [1, 2, 1, 2, 1])
        XCTAssertEqual(session.runs.map(\.id), ["done", "click1", "eval", "read1", "start"])
        XCTAssertEqual(session.totalCount, 7)
        XCTAssertEqual(session.actionCount, 3)
        XCTAssertEqual(session.observationCount, 2)
        XCTAssertEqual(session.failureCount, 1)
        XCTAssertTrue(session.isCompleted)
        XCTAssertTrue(session.hasFailures)
        XCTAssertEqual(session.summaryLine, "3 actions · 2 reads · 1 failed · Notes")
    }

    private func entry(
        _ id: String, at timestampMs: Int64, _ method: RPCMethod, _ summary: String,
        task: String? = nil, agent: String? = nil, app: String? = nil, success: Bool = true
    ) -> AuditEntry {
        AuditEntry(id: id, timestampMs: timestampMs, method: method.rawValue, targetApp: app,
                   summary: summary, latencyMs: 0, success: success, taskId: task, agent: agent)
    }
}
