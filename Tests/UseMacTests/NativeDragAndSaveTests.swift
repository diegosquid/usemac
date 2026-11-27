import Foundation
import XCTest
@testable import UseMacEngine
import UseMacProtocol

final class NativeDragAndSaveTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testSaveDestinationAcceptsANewFileAndResolvesOnlyItsParent() throws {
        try withDirectory { directory in
            let alias = directory.appendingPathComponent("alias")
            let realFolder = directory.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realFolder)
            let destination = alias.appendingPathComponent("report.pdf").path
            let expected = realFolder.resolvingSymlinksInPath().appendingPathComponent("report.pdf").path
            XCTAssertEqual(try ActionExecutor.validateAndNormalizeSaveDestination([destination], overwrite: false).get(), expected)
        }
    }

    func testSaveDestinationRequiresExactlyOneAbsolutePathWithAnExistingParent() throws {
        XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination(nil, overwrite: false).get())
        XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([], overwrite: false).get())
        XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination(["/first", "/second"], overwrite: false).get())
        XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination(["report.pdf"], overwrite: false).get())
        try withDirectory { directory in
            let destination = directory.appendingPathComponent("missing/report.pdf").path
            XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([destination], overwrite: false).get())
        }
    }

    func testSaveDestinationBlocksSensitiveLocationsEvenWithOverwrite() throws {
        let paths = [
            "~/.ssh/report.txt", "~/.aws/report.txt", "~/.config/gcloud/report.txt", "~/Library/Keychains/report.txt",
            "/etc/report.txt", "/private/etc/report.txt", "/System/report.txt", "/usr/report.txt", "/bin/report.txt",
            "/sbin/report.txt", "/Library/report.txt", "~/Library/Application Support/UseMac/report.txt"
        ]
        for path in paths {
            XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([path], overwrite: true).get()) { error in
                XCTAssertTrue(String(describing: error).contains("Blocked sensitive destination"), path)
            }
        }
        try withDirectory { directory in
            let alias = directory.appendingPathComponent("system")
            try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/etc")
            let path = alias.appendingPathComponent("report.txt").path
            XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([path], overwrite: true).get()) { error in
                XCTAssertTrue(String(describing: error).contains("Blocked sensitive destination"), path)
            }
        }
    }

    func testSaveDestinationRequiresExplicitOverwriteAndNeverReplacesDirectoriesOrSymlinks() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("report.txt")
            try Data("existing".utf8).write(to: path)
            let symlink = directory.appendingPathComponent("symlink.txt")
            let dangling = directory.appendingPathComponent("dangling.txt")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: path)
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("absent"))

            XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([path.path], overwrite: false).get()) { error in
                XCTAssertTrue(String(describing: error).contains("overwrite: true"))
            }
            XCTAssertEqual(try ActionExecutor.validateAndNormalizeSaveDestination([path.path], overwrite: true).get(),
                           path.resolvingSymlinksInPath().path)
            XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([directory.path], overwrite: true).get()) { error in
                XCTAssertTrue(String(describing: error).contains("existing directory"))
            }
            for link in [symlink, dangling] {
                XCTAssertThrowsError(try ActionExecutor.validateAndNormalizeSaveDestination([link.path], overwrite: true).get()) { error in
                    XCTAssertTrue(String(describing: error).contains("symbolic link"))
                }
            }
        }
    }

    private func execute(_ step: ActionStep) async -> ActionStepResult? {
        let executor = ActionExecutor(axIndexer: AXIndexer(), workspaceMonitor: WorkspaceMonitor(), killSwitch: KillSwitch())
        let (result, _) = await executor.executeBatch(
            BatchActionRequest(steps: [step]),
            preResolvedTarget: AppDescriptor(pid: Int32.max, name: "Test app")
        )
        return result.stepResults.first
    }

    func testSaveStepReportsUploadBlockedForUnsafeDestination() async {
        let result = await execute(ActionStep(action: .saveFile, files: ["/etc/report.txt"], overwrite: true))
        XCTAssertEqual(result?.errorCode, "UPLOAD_BLOCKED")
    }

    func testDragNeedsACompleteSourceAndDestination() async {
        let missingSource = await execute(ActionStep(action: .drag, x: 10, toX: 30, toY: 40))
        XCTAssertEqual(missingSource?.errorCode, "INVALID_REQUEST")
        XCTAssertEqual(missingSource?.message, "drag needs a source elementId, match, or x/y coordinates.")

        let missingDestination = await execute(ActionStep(action: .drag, x: 10, y: 20, toY: 40))
        XCTAssertEqual(missingDestination?.errorCode, "INVALID_REQUEST")
        XCTAssertEqual(missingDestination?.message, "drag needs a destination: pass toElementId, toMatch, or toX and toY.")
    }

    func testSkillParametersIncludeDragSelectorsAndDestinationMatch() throws {
        let step = ActionStep(
            action: .drag,
            selector: "#{{source}}",
            toSelector: "#{{dest}}",
            toMatch: ElementMatch(title: "{{title}}", value: "{{value}}", text: "{{text}}")
        )
        XCTAssertEqual(SkillStore.extractParamNames(from: [step]), ["source", "dest", "title", "text", "value"])
        let filled = try XCTUnwrap(SkillStore.interpolate(steps: [step], with: [
            "source": "avatar", "dest": "result", "title": "Drop zone", "value": "Ready", "text": "Drop here"
        ]).first)
        XCTAssertEqual(filled.selector, "#avatar")
        XCTAssertEqual(filled.toSelector, "#result")
        XCTAssertEqual(filled.toMatch, ElementMatch(title: "Drop zone", value: "Ready", text: "Drop here"))
    }
}
