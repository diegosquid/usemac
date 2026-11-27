import Foundation
import XCTest
@testable import UseMacEngine
@testable import UseMacProtocol

final class SkillStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usemac-skillstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storageURL = tempDir.appendingPathComponent("skills.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - CRUD & Persistence

    func testSaveGetListDeleteAndPersistenceAcrossInstances() throws {
        let store = SkillStore(storageURL: storageURL)
        XCTAssertTrue(store.list().isEmpty)

        let saveParams = SkillSaveParams(
            name: "search-docs",
            description: "Search documentation site",
            target: "browser",
            urlPattern: "https://docs.example.com/*",
            steps: [
                ActionStep(action: .setValue, selector: "input[type=search]", text: "{{query}}"),
                ActionStep(action: .pressKey, key: "Return")
            ]
        )

        let saved = try store.save(saveParams, nowMs: 1_000)
        XCTAssertEqual(saved.name, "search-docs")
        XCTAssertEqual(saved.params, ["query"], "auto-extracts placeholder names when params is omitted")
        XCTAssertEqual(saved.createdAtMs, 1_000)
        XCTAssertEqual(saved.updatedAtMs, 1_000)
        XCTAssertEqual(saved.runCount, 0)
        XCTAssertNil(saved.lastSuccessAtMs)

        // Reload from disk in a fresh SkillStore instance
        let reopened = SkillStore(storageURL: storageURL)
        let fetched = try XCTUnwrap(reopened.get(name: "search-docs"))
        XCTAssertEqual(fetched, saved)

        // Update existing skill preserves createdAtMs, runCount, and lastSuccessAtMs
        _ = reopened.recordRun(name: "search-docs", success: true, nowMs: 2_000)
        let updatedParams = SkillSaveParams(
            name: "search-docs",
            description: "Updated description",
            target: "browser",
            urlPattern: "https://docs.example.com/*",
            steps: [
                ActionStep(action: .setValue, selector: "#q", text: "{{query}}"),
                ActionStep(action: .assert, expectText: "{{expected}}")
            ]
        )
        let updated = try reopened.save(updatedParams, nowMs: 3_000)
        XCTAssertEqual(updated.createdAtMs, 1_000)
        XCTAssertEqual(updated.updatedAtMs, 3_000)
        XCTAssertEqual(updated.runCount, 1)
        XCTAssertEqual(updated.lastSuccessAtMs, 2_000)
        XCTAssertEqual(updated.params, ["query", "expected"])

        // Delete persists
        XCTAssertTrue(try reopened.delete(name: "search-docs"))
        XCTAssertFalse(try reopened.delete(name: "search-docs"))
        XCTAssertNil(reopened.get(name: "search-docs"))

        let afterDelete = SkillStore(storageURL: storageURL)
        XCTAssertTrue(afterDelete.list().isEmpty)
    }

    func testValidationRejectsEmptyNameOrSteps() {
        let store = SkillStore(storageURL: storageURL)

        XCTAssertThrowsError(try store.save(SkillSaveParams(name: "   ", steps: [ActionStep(action: .wait, durationMs: 10)]))) { error in
            XCTAssertEqual(error as? SkillStoreError, .invalidName)
        }

        XCTAssertThrowsError(try store.save(SkillSaveParams(name: "no-steps", steps: []))) { error in
            XCTAssertEqual(error as? SkillStoreError, .emptySteps)
        }
    }

    func testRecordRunTracksCountsAndLastSuccessOnlyOnSuccess() throws {
        let store = SkillStore(storageURL: storageURL)
        _ = try store.save(SkillSaveParams(name: "export-pdf", target: "native", app: "Notes", steps: [ActionStep(action: .menuAction, menuPath: ["File", "Export as PDF…"])]), nowMs: 100)

        let failed = try XCTUnwrap(store.recordRun(name: "export-pdf", success: false, nowMs: 200))
        XCTAssertEqual(failed.runCount, 1)
        XCTAssertNil(failed.lastSuccessAtMs)

        let succeeded = try XCTUnwrap(store.recordRun(name: "export-pdf", success: true, nowMs: 300))
        XCTAssertEqual(succeeded.runCount, 2)
        XCTAssertEqual(succeeded.lastSuccessAtMs, 300)

        let failedLater = try XCTUnwrap(store.recordRun(name: "export-pdf", success: false, nowMs: 400))
        XCTAssertEqual(failedLater.runCount, 3)
        XCTAssertEqual(failedLater.lastSuccessAtMs, 300, "subsequent failure keeps lastSuccessAtMs")

        XCTAssertNil(store.recordRun(name: "missing", success: true))
    }

    func testListFilteringByQueryTargetAppAndUrlPattern() throws {
        let store = SkillStore(storageURL: storageURL)
        _ = try store.save(SkillSaveParams(
            name: "stripe-refund",
            description: "Issue a customer refund in Stripe",
            target: "browser",
            urlPattern: "https://dashboard.stripe.com/*",
            steps: [ActionStep(action: .click, selector: ".refund")]
        ))
        _ = try store.save(SkillSaveParams(
            name: "notes-export",
            description: "Export active note to PDF",
            target: "native",
            app: "Notes",
            steps: [ActionStep(action: .menuAction, menuPath: ["File", "Export as PDF…"])]
        ))
        _ = try store.save(SkillSaveParams(
            name: "github-merge",
            description: "Squash and merge PR",
            target: "browser",
            urlPattern: "github.com",
            steps: [ActionStep(action: .click, selector: ".merge")]
        ))

        // Sorted alphabetically by name
        XCTAssertEqual(store.list().map(\.name), ["github-merge", "notes-export", "stripe-refund"])

        // Filter by target
        XCTAssertEqual(store.list(filter: SkillListParams(target: "native")).map(\.name), ["notes-export"])
        XCTAssertEqual(store.list(filter: SkillListParams(target: "BROWSER")).map(\.name), ["github-merge", "stripe-refund"])

        // Filter by app
        XCTAssertEqual(store.list(filter: SkillListParams(app: "not")).map(\.name), ["notes-export"])

        // Filter by URL (glob & substring)
        XCTAssertEqual(
            store.list(filter: SkillListParams(url: "https://dashboard.stripe.com/payments/pi_123")).map(\.name),
            ["stripe-refund"]
        )
        XCTAssertEqual(
            store.list(filter: SkillListParams(url: "https://github.com/org/repo/pull/42")).map(\.name),
            ["github-merge"]
        )

        // Filter by query across name/description/app/urlPattern
        XCTAssertEqual(store.list(filter: SkillListParams(query: "refund")).map(\.name), ["stripe-refund"])
        XCTAssertEqual(store.list(filter: SkillListParams(query: "PDF")).map(\.name), ["notes-export"])
    }

    func testCorruptFileOnDiskDegradesGracefully() throws {
        try Data("{not-valid-json".utf8).write(to: storageURL)
        let store = SkillStore(storageURL: storageURL)
        XCTAssertTrue(store.list().isEmpty)

        // Subsequent save overwrites corrupt file cleanly
        _ = try store.save(SkillSaveParams(name: "fresh", steps: [ActionStep(action: .wait, durationMs: 5)]))
        let reopened = SkillStore(storageURL: storageURL)
        XCTAssertEqual(reopened.list().map(\.name), ["fresh"])
    }

    // MARK: - Interpolation

    func testInterpolateCoversAllSupportedStepFields() {
        let steps: [ActionStep] = [
            ActionStep(
                action: .openURL,
                url: "https://{{host}}/projects/{{projectId}}"
            ),
            ActionStep(
                action: .type,
                text: "Hello {{user}}!",
                match: ElementMatch(
                    role: "AXTextField",
                    title: "Message for {{recipient}}",
                    value: "{{currentVal}}",
                    text: "Compose {{topic}}"
                )
            ),
            ActionStep(
                action: .fillForm,
                fields: [
                    FormFieldEntry(
                        selector: "#email",
                        match: ElementMatch(title: "Field {{fieldTitle}}"),
                        label: "{{emailLabel}}",
                        value: "{{email}}"
                    ),
                    FormFieldEntry(
                        label: "Agree",
                        value: nil,
                        checked: true
                    )
                ],
                submitMatch: ElementMatch(title: "Submit {{formName}}")
            ),
            ActionStep(
                action: .assert,
                expectText: "Welcome, {{user}}",
                expectNotText: "Error {{errorCode}}",
                expectUrl: "https://{{host}}/done/{{projectId}}",
                expectTitle: "{{projectId}} — Complete"
            ),
            ActionStep(
                action: .menuAction,
                menuPath: ["File", "{{exportMenu}}", "{{format}}"]
            ),
            ActionStep(
                action: .uploadFile,
                files: ["{{dir}}/{{filename}}", "/tmp/static.pdf"]
            )
        ]

        let params: [String: String] = [
            "host": "app.example.com",
            "projectId": "proj-42",
            "user": "Diego",
            "recipient": "Alice",
            "currentVal": "draft",
            "topic": "Release",
            "fieldTitle": "Work Email",
            "emailLabel": "Email Address",
            "email": "diego@example.com",
            "formName": "Order",
            "errorCode": "500",
            "exportMenu": "Export",
            "format": "PDF…",
            "dir": "/tmp/uploads",
            "filename": "report.csv"
        ]

        let interpolated = SkillStore.interpolate(steps: steps, with: params)

        XCTAssertEqual(interpolated[0].url, "https://app.example.com/projects/proj-42")

        XCTAssertEqual(interpolated[1].text, "Hello Diego!")
        XCTAssertEqual(interpolated[1].match?.title, "Message for Alice")
        XCTAssertEqual(interpolated[1].match?.value, "draft")
        XCTAssertEqual(interpolated[1].match?.text, "Compose Release")

        XCTAssertEqual(interpolated[2].fields?[0].label, "Email Address")
        XCTAssertEqual(interpolated[2].fields?[0].value, "diego@example.com")
        XCTAssertEqual(interpolated[2].fields?[0].match?.title, "Field Work Email")
        XCTAssertEqual(interpolated[2].fields?[1].checked, true)
        XCTAssertEqual(interpolated[2].submitMatch?.title, "Submit Order")

        XCTAssertEqual(interpolated[3].expectText, "Welcome, Diego")
        XCTAssertEqual(interpolated[3].expectNotText, "Error 500")
        XCTAssertEqual(interpolated[3].expectUrl, "https://app.example.com/done/proj-42")
        XCTAssertEqual(interpolated[3].expectTitle, "proj-42 — Complete")

        XCTAssertEqual(interpolated[4].menuPath, ["File", "Export", "PDF…"])
        XCTAssertEqual(interpolated[5].files, ["/tmp/uploads/report.csv", "/tmp/static.pdf"])
    }

    func testInterpolateSinglePassAndUnknownPlaceholdersPreserved() {
        let steps = [
            ActionStep(action: .type, text: "{{a}} and {{missing}} and {{ spaced }}")
        ]
        let interpolated = SkillStore.interpolate(steps: steps, with: [
            "a": "{{b}}",
            "b": "SHOULD_NOT_EXPAND",
            "spaced": "ok"
        ])
        XCTAssertEqual(interpolated[0].text, "{{b}} and {{missing}} and ok")

        // Empty params returns steps untouched
        XCTAssertEqual(SkillStore.interpolate(steps: steps, with: [:]), steps)
    }

    // MARK: - Concurrency

    func testConcurrentSavesReadsAndRecordRunsAreThreadSafe() async throws {
        let store = SkillStore(storageURL: storageURL)
        let iterations = 40
        let workers = 4

        // These operations write a whole snapshot under a lock. Keep concurrent callers without starting
        // 40 blocking jobs or measuring how quickly the runner schedules and finishes them.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    for i in stride(from: worker, to: iterations, by: workers) {
                        let name = "skill-\(i)"
                        let saved = try store.save(SkillSaveParams(
                            name: name,
                            target: "browser",
                            steps: [ActionStep(action: .click, selector: "#btn-\(i)")]
                        ))
                        XCTAssertEqual(store.get(name: name), saved)
                        let run = try XCTUnwrap(store.recordRun(name: name, success: i % 2 == 0))
                        XCTAssertEqual(run.runCount, 1)
                        XCTAssertTrue(store.list().contains { $0.name == name })
                    }
                }
            }
            try await group.waitForAll()
        }

        let records = store.list()
        XCTAssertEqual(records.count, iterations)
        XCTAssertTrue(records.allSatisfy { $0.runCount == 1 })
        let reopened = SkillStore(storageURL: storageURL)
        XCTAssertEqual(reopened.list(), records)
    }
}
