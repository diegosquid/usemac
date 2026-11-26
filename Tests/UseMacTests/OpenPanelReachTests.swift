import Foundation
import XCTest
@testable import UseMacEngine

final class OpenPanelReachTests: XCTestCase {
    func testTempAndHiddenFoldersBlockTheSearch() {
        XCTAssertEqual(OpenPanelReach.searchBlocker(for: "/private/tmp/shot.png"), "/tmp")
        XCTAssertEqual(OpenPanelReach.searchBlocker(for: "/tmp/shot.png"), "/tmp")
        XCTAssertEqual(OpenPanelReach.searchBlocker(for: "/private/var/folders/hk/abc/T/shot.png"), "a temporary folder ($TMPDIR)")
        XCTAssertEqual(OpenPanelReach.searchBlocker(for: "/private/etc/hosts.txt"), "a system folder (/private)")
        XCTAssertEqual(OpenPanelReach.searchBlocker(for: "/Users/me/Downloads/.cache/shot.png"), "a hidden folder (.cache)")
        XCTAssertEqual(OpenPanelReach.searchBlocker(for: "/Users/me/Downloads/.shot.png"), "a hidden file")
    }

    func testIndexedFoldersKeepTheSearch() {
        XCTAssertNil(OpenPanelReach.searchBlocker(for: "/Users/me/Downloads/report.pdf"))
        XCTAssertNil(OpenPanelReach.searchBlocker(for: "/Users/me/Documents/a.b/report.v2.pdf"))
        // ~/Library carries the hidden flag, but Spotlight indexes it: keep searching there.
        XCTAssertNil(OpenPanelReach.searchBlocker(for: "/Users/me/Library/Mobile Documents/report.pdf"))
        XCTAssertNil(OpenPanelReach.searchBlocker(for: "/Volumes/Data/report.pdf"))
    }

    func testRealTemporaryFilesAreBlockedAfterUploadNormalization() throws {
        // Check the paths exactly as uploadFile hands them over (symlinks resolved, /private kept or dropped).
        let name = "usemac-reach-\(UUID().uuidString.prefix(8)).txt"
        let files = [
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name),
            URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        ]
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        for file in files {
            try "reach".write(to: file, atomically: true, encoding: .utf8)
            guard case .success(let paths) = ActionExecutor.validateAndNormalizeUploadFiles([file.path]) else {
                return XCTFail("\(file.path) should be a valid upload")
            }
            XCTAssertNotNil(OpenPanelReach.searchBlocker(for: paths[0]), paths[0])
        }
    }

    func testMessageNamesBothWaysOut() {
        let message = OpenPanelReach.backgroundMessage(fileName: "shot.png", reason: "/tmp", appName: "TextEdit")
        XCTAssertTrue(message.hasPrefix("shot.png is in /tmp"), message)
        XCTAssertTrue(message.contains("TextEdit is in the background"), message)
        XCTAssertTrue(message.contains("\"foreground\": true"), message)
        XCTAssertTrue(message.contains("~/Downloads"), message)
    }
}
