import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("usemac-audit-\(UUID().uuidString.prefix(8))", isDirectory: true)
}

private func entry(
    _ summary: String,
    at date: Date = Date(),
    method: String = "observe",
    app: String? = "TextEdit",
    success: Bool = true,
    taskId: String? = nil
) -> AuditEntry {
    AuditEntry(
        timestampMs: Int64(date.timeIntervalSince1970 * 1000),
        method: method,
        targetApp: app,
        summary: summary,
        latencyMs: 1.5,
        success: success,
        taskId: taskId
    )
}

final class AuditLogStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testEntriesSurviveANewStoreInstance() {
        let first = AuditLogStore(directory: directory, retentionDays: { 30 })
        let written = (1...3).map { entry("step \($0)", at: Date().addingTimeInterval(Double($0))) }
        written.forEach(first.append)
        first.flush()

        let reopened = AuditLogStore(directory: directory, retentionDays: { 30 })
        XCTAssertEqual(reopened.recentEntries().map(\.id), written.map(\.id), "oldest first, as the engine keeps them")
        XCTAssertEqual(reopened.entries(matching: AuditLogQuery(limit: 2)).map(\.summary), ["step 3", "step 2"])
    }

    func testOneFilePerDayReadableOnlyByTheUser() throws {
        let store = AuditLogStore(directory: directory, retentionDays: { 30 })
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        store.append(entry("yesterday", at: yesterday))
        store.append(entry("today", at: today))
        store.flush()

        let names = store.dayFiles().map(\.lastPathComponent)
        XCTAssertEqual(names, [
            "audit-\(AuditLogStore.dayString(for: today)).jsonl",
            "audit-\(AuditLogStore.dayString(for: yesterday)).jsonl"
        ])
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.dayFiles()[0].path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)

        let todayLines = try String(contentsOf: store.dayFiles()[0], encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(todayLines.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(AuditEntry.self, from: Data(todayLines[0].utf8)).summary, "today")
    }

    func testQueryFiltersByTaskAppResultAndTime() {
        let store = AuditLogStore(directory: directory, retentionDays: { 30 })
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        store.append(entry("old", at: old, taskId: "task-a"))
        store.append(entry("a ok", at: now, taskId: "task-a"))
        store.append(entry("b failed", at: now.addingTimeInterval(1), app: "Notes", success: false, taskId: "task-b"))
        store.append(entry("no task", at: now.addingTimeInterval(2)))

        XCTAssertEqual(store.entries(matching: AuditLogQuery(limit: nil, taskId: "task-a")).map(\.summary), ["a ok", "old"])
        XCTAssertEqual(store.entries(matching: AuditLogQuery(limit: nil, app: "Notes")).map(\.summary), ["b failed"])
        XCTAssertEqual(store.entries(matching: AuditLogQuery(limit: nil, success: false)).map(\.summary), ["b failed"])
        let sinceMs = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        XCTAssertEqual(store.entries(matching: AuditLogQuery(limit: nil, sinceMs: sinceMs)).map(\.summary), ["no task", "b failed", "a ok"])
        XCTAssertEqual(store.entries(matching: AuditLogQuery(limit: 1)).map(\.summary), ["no task"])
    }

    func testRetentionDeletesOnlyOldDayFiles() throws {
        let writer = AuditLogStore(directory: directory, retentionDays: { 365 })
        let now = Date()
        writer.append(entry("40 days ago", at: Calendar.current.date(byAdding: .day, value: -40, to: now)!))
        writer.append(entry("10 days ago", at: Calendar.current.date(byAdding: .day, value: -10, to: now)!))
        writer.append(entry("today", at: now))
        writer.flush()
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        XCTAssertEqual(writer.dayFiles().count, 3)

        let pruner = AuditLogStore(directory: directory, retentionDays: { 30 })
        pruner.prune(now: now)
        XCTAssertEqual(pruner.entries(matching: AuditLogQuery(limit: nil)).map(\.summary), ["today", "10 days ago"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCutShortLineIsSkipped() throws {
        let store = AuditLogStore(directory: directory, retentionDays: { 30 })
        let good = entry("good")
        store.append(good)
        store.flush()
        let file = store.fileURL(forTimestampMs: good.timestampMs)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{\"id\":\"cut-sh".utf8))
        try handle.close()

        let after = entry("after", at: Date().addingTimeInterval(1))
        store.append(after)
        XCTAssertEqual(store.entries(matching: AuditLogQuery(limit: nil)).map(\.summary), ["good"],
                       "the cut-short line swallows the next one, and both are skipped instead of failing the read")
    }

    func testCSVExportEscapesCellsAndDefusesFormulas() throws {
        let rows = [
            entry("=HYPERLINK(\"x\")", app: "Chrome (Work, Main)", taskId: "task-1"),
            entry("line one\nline two", success: false)
        ]
        let csv = try XCTUnwrap(String(data: AuditLogStore.export(rows, as: .csv), encoding: .utf8))
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "time,timestampMs,taskId,method,app,result,latencyMs,summary,id")
        XCTAssertTrue(lines[1].contains(",failed,1.50,\"line one\nline two\","), "oldest first; newlines are quoted: \(lines[1])")
        XCTAssertTrue(csv.contains(",task-1,observe,\"Chrome (Work, Main)\",ok,1.50,\"'=HYPERLINK(\"\"x\"\")\","), csv)
    }

    func testJSONLExportRoundTrips() throws {
        let rows = [entry("second", at: Date().addingTimeInterval(1), taskId: "t"), entry("first")]
        let lines = String(decoding: AuditLogStore.export(rows, as: .jsonl), as: UTF8.self).split(separator: "\n")
        let decoded = try lines.map { try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded, Array(rows.reversed()))
    }
}

final class AuditRedactionTests: XCTestCase {
    func testStepsKeepOnlyTheLengthOfTypedText() {
        let steps = [
            ActionStep(action: .type, text: "hunter2-secret"),
            ActionStep(action: .setValue, elementId: "@e3", text: "abc"),
            ActionStep(action: .pressKey, key: "s", modifiers: ["cmd"]),
            ActionStep(action: .pressKey, key: "a"),
            ActionStep(action: .pressKey, key: "return"),
            ActionStep(action: .openURL, url: "https://bob:pw@example.com/a?token=xyz&q=1"),
            ActionStep(action: .uploadFile, files: ["/tmp/a.pdf", "/tmp/b.pdf"]),
            ActionStep(action: .click, elementId: "@e1"),
            ActionStep(action: .scroll)
        ]
        XCTAssertEqual(
            AuditRedactor.describeSteps(steps, recordText: false),
            "type (14 chars), setValue (3 chars), pressKey cmd+s, pressKey (1 char), pressKey return, "
                + "openURL https://***@example.com/a?token=***&q=1, uploadFile (2 files), click, +1 more"
        )
    }

    func testRecordTypedTextKeepsTheText() {
        let steps = [ActionStep(action: .type, text: "Meeting\nnotes"), ActionStep(action: .pressKey, key: "a")]
        XCTAssertEqual(AuditRedactor.describeSteps(steps, recordText: true), "type \"Meeting notes\", pressKey a")
        XCTAssertEqual(AuditRedactor.evalSummary("document.title", recordText: true), "Eval (14 chars): document.title")
        XCTAssertEqual(
            AuditRedactor.scrub("Opened https://u:p@x.com/ with hunter2-secret", secrets: ["hunter2-secret"], recordText: true),
            "Opened https://***@x.com/ with hunter2-secret",
            "credentials in URLs go even when typed text is recorded"
        )
    }

    func testScrubRemovesSecretsEchoedInMessages() {
        XCTAssertEqual(
            AuditRedactor.scrub("Could not type hunter2-secret into @e4 (ok)", secrets: ["hunter2-secret", "ok"], recordText: false),
            "Could not type [14 chars] into @e4 (ok)",
            "secrets shorter than 4 characters are left alone so ordinary words survive"
        )
    }

    func testURLsLoseCredentialsAndSecretValues() {
        XCTAssertEqual(
            AuditRedactor.scrub("Opened https://alice:hunter2@example.com/path?api_key=123&page=2#access_token=abc", secrets: [], recordText: false),
            "Opened https://***@example.com/path?api_key=***&page=2#***"
        )
        XCTAssertEqual(AuditRedactor.redactURL("https://example.com/search?q=shoes"), "https://example.com/search?q=shoes")
        XCTAssertEqual(AuditRedactor.redactURL("about:blank"), "about:blank")
        XCTAssertEqual(
            AuditRedactor.scrub("URL blocked: ftp://user:pw@files.example.com/x and http://ok.example.com", secrets: [], recordText: false),
            "URL blocked: ftp://***@files.example.com/x and http://ok.example.com"
        )
    }

    func testEvalAndOCRKeepOnlyLengths() {
        XCTAssertEqual(AuditRedactor.evalSummary("fetch('/api?token=' + secret)", recordText: false), "Eval (29 chars)")
        XCTAssertEqual(
            AuditRedactor.visionSummary(mode: "ocr", backend: "apple-vision", answer: "Password: hunter2", recordText: false),
            "Vision ocr [apple-vision]: read 17 chars"
        )
        XCTAssertEqual(
            AuditRedactor.visionSummary(mode: "ask", backend: "apple-vision-ocr", answer: "A dialog is open", recordText: false),
            "Vision ask [apple-vision-ocr]: A dialog is open"
        )
    }

    func testRequestHintsAndSecrets() {
        let open = RPCRequest(method: .browserOpen, browserOpen: BrowserOpenParams(url: "https://example.com", tabId: 5, taskId: "task-x"))
        XCTAssertEqual(open.auditTaskHint.taskId, "task-x")
        XCTAssertEqual(open.auditTaskHint.tabId, 5)
        let observe = RPCRequest(method: .browserObserve, browserObserve: BrowserObserveParams(tabId: 42))
        XCTAssertNil(observe.auditTaskHint.taskId)
        XCTAssertEqual(observe.auditTaskHint.tabId, 42)

        let act = RPCRequest(method: .act, act: BatchActionRequest(steps: [
            ActionStep(action: .type, text: "typed words"),
            ActionStep(action: .click, text: "not a secret")
        ]))
        XCTAssertEqual(act.auditSecrets, ["typed words"])
        let eval = RPCRequest(method: .browserExtract, browserExtract: BrowserExtractParams(mode: "eval", expression: "1 + 1"))
        XCTAssertEqual(eval.auditSecrets, ["1 + 1"])
    }

    func testParseSince() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AuditLogParams.parseSince("2h", now: now), (1_800_000_000 - 7200) * 1000)
        XCTAssertEqual(AuditLogParams.parseSince("30m", now: now), (1_800_000_000 - 1800) * 1000)
        XCTAssertEqual(AuditLogParams.parseSince("1732575600000", now: now), 1_732_575_600_000)
        XCTAssertEqual(AuditLogParams.parseSince("2026-11-25T10:00:00Z", now: now), 1_795_600_800_000)
        var midnight = DateComponents()
        midnight.year = 2026; midnight.month = 11; midnight.day = 25
        let localMidnight = Calendar.current.date(from: midnight)!
        XCTAssertEqual(AuditLogParams.parseSince("2026-11-25", now: now), Int64(localMidnight.timeIntervalSince1970 * 1000))
        XCTAssertNil(AuditLogParams.parseSince("yesterday-ish", now: now))
        XCTAssertNil(AuditLogParams.parseSince("", now: now))
    }
}

final class AuditLogEngineTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeService() -> UseMacEngineService {
        UseMacEngineService(
            socketPath: "/tmp/usemac-audit-\(UUID().uuidString.prefix(8)).sock",
            extensionPort: 0,
            auditStore: AuditLogStore(directory: directory, retentionDays: { 30 })
        )
    }

    func testEntriesCarryTheTaskAndSurviveARestart() async throws {
        let service = makeService()
        let missingApp = "NoSuchApp-\(UUID().uuidString.prefix(6))"
        let start = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(summary: "Audit test", taskId: "task-audit-1")))
        XCTAssertEqual(start.taskId, "task-audit-1")
        let observe = await service.handle(RPCRequest(method: .observe, observe: ObserveParams(app: missingApp)))
        XCTAssertEqual(observe.error?.code, "APP_NOT_FOUND")
        _ = await service.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(summary: "Done", taskId: "task-audit-1")))
        // Not tied to a task: none is running any more.
        _ = await service.handle(RPCRequest(method: .observe, observe: ObserveParams(app: missingApp)))

        let beforeRestart = await service.handle(RPCRequest(method: .auditLog)).auditEntries ?? []
        XCTAssertEqual(beforeRestart.map(\.method), ["observe", "task_complete", "observe", "task_start"])
        XCTAssertEqual(beforeRestart.map(\.taskId), [nil, "task-audit-1", "task-audit-1", "task-audit-1"])
        service.auditStore?.flush()

        let restarted = makeService()
        let afterRestart = await restarted.handle(RPCRequest(method: .auditLog)).auditEntries ?? []
        XCTAssertEqual(afterRestart.map(\.id), beforeRestart.map(\.id), "audit_log without params still answers from memory, loaded from disk")

        let taskOnly = await restarted.handle(RPCRequest(method: .auditLog, auditLog: AuditLogParams(taskId: "task-audit-1"))).auditEntries ?? []
        XCTAssertEqual(taskOnly.map(\.method), ["task_complete", "observe", "task_start"])
        let one = await restarted.handle(RPCRequest(method: .auditLog, auditLog: AuditLogParams(limit: 1))).auditEntries ?? []
        XCTAssertEqual(one.map(\.id), [beforeRestart[0].id])
        let future = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let none = await restarted.handle(RPCRequest(method: .auditLog, auditLog: AuditLogParams(sinceMs: future))).auditEntries
        XCTAssertEqual(none?.count, 0)
    }

    func testBlockedTypeNeverReachesTheLog() async throws {
        let service = makeService()
        service.setGovernancePolicy(.readOnly)
        let secret = "correct-horse-battery-staple"
        let response = await service.handle(RPCRequest(method: .act, act: BatchActionRequest(
            app: "TextEdit",
            steps: [ActionStep(action: .type, text: secret)]
        )))
        XCTAssertEqual(response.error?.code, "POLICY_BLOCKED")
        service.auditStore?.flush()

        let files = service.auditStore?.dayFiles() ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(secret))
        }
    }

    func testWithoutAStoreFiltersStillWork() async {
        let service = UseMacEngineService(socketPath: "/tmp/usemac-audit-\(UUID().uuidString.prefix(8)).sock", extensionPort: 0)
        XCTAssertNil(service.auditStore)
        _ = await service.handle(RPCRequest(method: .taskStart, taskStart: TaskStartParams(taskId: "task-mem")))
        _ = await service.handle(RPCRequest(method: .taskComplete, taskComplete: TaskCompleteParams(taskId: "task-mem")))
        let entries = await service.handle(RPCRequest(method: .auditLog, auditLog: AuditLogParams(limit: 1, taskId: "task-mem"))).auditEntries
        XCTAssertEqual(entries?.map(\.method), ["task_complete"])
    }
}
