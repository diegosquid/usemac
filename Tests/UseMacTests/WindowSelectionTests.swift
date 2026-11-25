import CoreGraphics
import XCTest
@testable import UseMacEngine

final class WindowSelectionTests: XCTestCase {
    private typealias Candidate = WindowResolver.CaptureCandidate
    private typealias Target = WindowResolver.TargetWindow

    private let chrome: pid_t = 500
    private let other: pid_t = 600

    private func window(
        _ id: CGWindowID,
        pid: pid_t? = nil,
        _ frame: CGRect,
        layer: Int = 0,
        onScreen: Bool = true,
        title: String? = nil
    ) -> Candidate {
        Candidate(windowId: id, pid: pid ?? chrome, frame: frame, layer: layer, isOnScreen: onScreen, title: title)
    }

    // MARK: chooseCaptureWindow

    func testExactIdWinsOverIdenticalFrameInAnotherSpace() {
        // Two Chrome windows with the same frame, both off the current Space (the preview showed the wrong one).
        let frame = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let candidates = [
            window(10, frame, onScreen: false, title: "Other window"),
            window(11, frame, onScreen: false, title: "Page")
        ]
        let chosen = WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [Target(windowId: 11)])
        XCTAssertEqual(chosen?.windowId, 11)
    }

    func testExactIdIgnoresTitleMismatch() {
        // AX: "Page - Part of group X - Google Chrome - Profile"; SCK: "Page". Titles are never compared.
        let candidates = [
            window(20, CGRect(x: 0, y: 0, width: 1400, height: 900), title: "Other"),
            window(21, CGRect(x: 40, y: 40, width: 1200, height: 800), title: "Page")
        ]
        let chosen = WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [Target(windowId: 21)])
        XCTAssertEqual(chosen?.windowId, 21)
    }

    func testHeuristicSkipsHelperStripsAndOverlaysAndPicksLargest() {
        let candidates = [
            window(30, CGRect(x: 10, y: 10, width: 52, height: 20), title: ""),
            window(31, CGRect(x: 0, y: 0, width: 2000, height: 1200), layer: 25),
            window(32, CGRect(x: 0, y: 0, width: 800, height: 600), title: "Small"),
            window(33, CGRect(x: 0, y: 0, width: 1400, height: 900), onScreen: false, title: "Big")
        ]
        let chosen = WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [])
        XCTAssertEqual(chosen?.windowId, 33)
    }

    func testHeuristicReturnsNilWhenOnlyHelperWindowsExist() {
        let candidates = [
            window(40, CGRect(x: 10, y: 10, width: 52, height: 20)),
            window(41, CGRect(x: 0, y: 0, width: 300, height: 100))
        ]
        XCTAssertNil(WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: []))
        // Even a matching id does not make a helper strip a capture target.
        XCTAssertNil(WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [Target(windowId: 40)]))
    }

    func testSmallFocusedDialogUsesTheWindowUnderIt() {
        let candidates = [
            window(50, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(51, CGRect(x: 1500, y: 0, width: 1000, height: 700)),
            window(52, CGRect(x: 1700, y: 200, width: 300, height: 100))
        ]
        let chosen = WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [Target(windowId: 52)])
        XCTAssertEqual(chosen?.windowId, 51)
    }

    func testMissingTargetFallsBackToNextTargetThenHeuristic() {
        let candidates = [
            window(60, CGRect(x: 0, y: 0, width: 1000, height: 700)),
            window(61, CGRect(x: 0, y: 0, width: 1200, height: 800))
        ]
        let viaSecond = WindowResolver.chooseCaptureWindow(
            from: candidates,
            pid: chrome,
            targets: [Target(windowId: 999), Target(windowId: 60)]
        )
        XCTAssertEqual(viaSecond?.windowId, 60)
        let viaHeuristic = WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [Target(windowId: 999)])
        XCTAssertEqual(viaHeuristic?.windowId, 61)
    }

    func testOtherAppsWindowsAreNeverChosen() {
        let candidates = [
            window(70, pid: other, CGRect(x: 0, y: 0, width: 2000, height: 1200)),
            window(71, CGRect(x: 0, y: 0, width: 900, height: 600))
        ]
        XCTAssertEqual(WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [])?.windowId, 71)
        // An id that belongs to another app is not used for this app.
        XCTAssertEqual(
            WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [Target(windowId: 70)])?.windowId,
            71
        )
    }

    func testEqualSizePrefersWindowOnCurrentSpace() {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let candidates = [
            window(80, frame, onScreen: false, title: "A"),
            window(81, frame, onScreen: true, title: "B")
        ]
        XCTAssertEqual(WindowResolver.chooseCaptureWindow(from: candidates, pid: chrome, targets: [])?.windowId, 81)
    }

    // MARK: chooseStreamWindow (pinning)

    func testPinnedWindowStaysWhenTargetIsUnchangedOrUnknown() {
        let candidates = [
            window(100, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(101, CGRect(x: 0, y: 0, width: 1600, height: 1000))
        ]
        XCTAssertEqual(
            WindowResolver.chooseStreamWindow(from: candidates, pid: chrome, targets: [], pinnedWindowId: 100)?.windowId,
            100
        )
        XCTAssertEqual(
            WindowResolver.chooseStreamWindow(
                from: candidates,
                pid: chrome,
                targets: [Target(windowId: 100)],
                pinnedWindowId: 100
            )?.windowId,
            100
        )
    }

    func testSheetOverPinnedWindowDoesNotMoveThePreview() {
        let candidates = [
            window(110, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(111, CGRect(x: 300, y: 60, width: 800, height: 500))
        ]
        let chosen = WindowResolver.chooseStreamWindow(
            from: candidates,
            pid: chrome,
            targets: [Target(windowId: 111, isStandardWindow: false)],
            pinnedWindowId: 110
        )
        XCTAssertEqual(chosen?.windowId, 110)
    }

    func testPopupOverPinnedWindowDoesNotMoveThePreview() {
        let candidates = [
            window(120, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(121, CGRect(x: 2000, y: 0, width: 400, height: 300), layer: 101)
        ]
        let chosen = WindowResolver.chooseStreamWindow(
            from: candidates,
            pid: chrome,
            targets: [Target(windowId: 121)],
            pinnedWindowId: 120
        )
        XCTAssertEqual(chosen?.windowId, 120)
    }

    func testFocusMovingToAnotherRealWindowSwitchesThePreview() {
        let candidates = [
            window(130, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(131, CGRect(x: 1500, y: 0, width: 1200, height: 800))
        ]
        let chosen = WindowResolver.chooseStreamWindow(
            from: candidates,
            pid: chrome,
            targets: [Target(windowId: 131)],
            pinnedWindowId: 130
        )
        XCTAssertEqual(chosen?.windowId, 131)
    }

    func testStandardWindowInsidePinnedFrameStillSwitches() {
        let candidates = [
            window(140, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(141, CGRect(x: 100, y: 100, width: 900, height: 600))
        ]
        let chosen = WindowResolver.chooseStreamWindow(
            from: candidates,
            pid: chrome,
            targets: [Target(windowId: 141, isStandardWindow: true)],
            pinnedWindowId: 140
        )
        XCTAssertEqual(chosen?.windowId, 141)
    }

    func testTargetNotListedKeepsPinAndVanishedPinReselects() {
        let candidates = [
            window(150, CGRect(x: 0, y: 0, width: 1400, height: 900)),
            window(151, CGRect(x: 1500, y: 0, width: 1000, height: 700))
        ]
        XCTAssertEqual(
            WindowResolver.chooseStreamWindow(
                from: candidates,
                pid: chrome,
                targets: [Target(windowId: 999)],
                pinnedWindowId: 150
            )?.windowId,
            150
        )
        XCTAssertEqual(
            WindowResolver.chooseStreamWindow(
                from: candidates,
                pid: chrome,
                targets: [Target(windowId: 151)],
                pinnedWindowId: 777
            )?.windowId,
            151
        )
    }

    func testIsAttached() {
        let parent = window(160, CGRect(x: 0, y: 0, width: 1400, height: 900))
        XCTAssertTrue(WindowResolver.isAttached(window(161, CGRect(x: 200, y: 50, width: 700, height: 400)), to: parent))
        XCTAssertTrue(WindowResolver.isAttached(window(162, CGRect(x: 5000, y: 0, width: 600, height: 400), layer: 3), to: parent))
        XCTAssertFalse(WindowResolver.isAttached(window(163, CGRect(x: 1200, y: 0, width: 700, height: 400)), to: parent))
        XCTAssertFalse(WindowResolver.isAttached(window(164, pid: other, CGRect(x: 200, y: 50, width: 700, height: 400)), to: parent))
        XCTAssertFalse(WindowResolver.isAttached(parent, to: parent))
    }
}
