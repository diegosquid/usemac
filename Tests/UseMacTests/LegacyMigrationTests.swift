import Foundation
import XCTest
import UseMacEngine

final class LegacyMigrationTests: XCTestCase {

    private func makeScratchRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usemac-migration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMovesLegacyDirectoryWhenCurrentIsMissing() throws {
        let fm = FileManager.default
        let root = try makeScratchRoot()
        defer { try? fm.removeItem(at: root) }

        let legacyDir = root.appendingPathComponent("old-app/vision-venv", isDirectory: true)
        let currentDir = root.appendingPathComponent("new-app/vision-venv", isDirectory: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let payload = Data("mlx-runtime-marker-v1".utf8)
        let sourceFile = legacyDir.appendingPathComponent("marker.txt")
        try payload.write(to: sourceFile)

        let moved = LocalVisionEngine.migrateLegacyDirectory(from: legacyDir, to: currentDir)

        XCTAssertTrue(moved)
        XCTAssertFalse(fm.fileExists(atPath: legacyDir.path))
        let movedFile = currentDir.appendingPathComponent("marker.txt")
        XCTAssertTrue(fm.fileExists(atPath: movedFile.path))
        XCTAssertEqual(try Data(contentsOf: movedFile), payload)
    }

    func testDoesNothingWhenCurrentAlreadyExists() throws {
        let fm = FileManager.default
        let root = try makeScratchRoot()
        defer { try? fm.removeItem(at: root) }

        let legacyDir = root.appendingPathComponent("old-app/vision-venv", isDirectory: true)
        let currentDir = root.appendingPathComponent("new-app/vision-venv", isDirectory: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: currentDir, withIntermediateDirectories: true)

        let legacyPayload = Data("legacy-content".utf8)
        let currentPayload = Data("current-content".utf8)
        try legacyPayload.write(to: legacyDir.appendingPathComponent("state.txt"))
        try currentPayload.write(to: currentDir.appendingPathComponent("state.txt"))

        let moved = LocalVisionEngine.migrateLegacyDirectory(from: legacyDir, to: currentDir)

        XCTAssertFalse(moved)
        XCTAssertEqual(try Data(contentsOf: legacyDir.appendingPathComponent("state.txt")), legacyPayload)
        XCTAssertEqual(try Data(contentsOf: currentDir.appendingPathComponent("state.txt")), currentPayload)
    }

    func testIgnoresSymlinkedLegacyDirectory() throws {
        let fm = FileManager.default
        let root = try makeScratchRoot()
        defer { try? fm.removeItem(at: root) }

        let externalTarget = root.appendingPathComponent("external-target", isDirectory: true)
        try fm.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        let targetPayload = Data("untouched-target".utf8)
        try targetPayload.write(to: externalTarget.appendingPathComponent("keep.txt"))

        let legacyParent = root.appendingPathComponent("old-app", isDirectory: true)
        try fm.createDirectory(at: legacyParent, withIntermediateDirectories: true)
        let legacySymlink = legacyParent.appendingPathComponent("vision-venv", isDirectory: true)
        try fm.createSymbolicLink(atPath: legacySymlink.path, withDestinationPath: externalTarget.path)

        let currentDir = root.appendingPathComponent("new-app/vision-venv", isDirectory: true)

        let moved = LocalVisionEngine.migrateLegacyDirectory(from: legacySymlink, to: currentDir)

        XCTAssertFalse(moved)
        XCTAssertFalse(fm.fileExists(atPath: currentDir.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacySymlink.path), externalTarget.path)
        XCTAssertEqual(try Data(contentsOf: externalTarget.appendingPathComponent("keep.txt")), targetPayload)
    }
}
