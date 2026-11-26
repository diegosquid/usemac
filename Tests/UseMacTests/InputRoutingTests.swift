import CoreGraphics
import XCTest
@testable import UseMacEngine

/// Where real input would land, decided from the window server's front-to-back order (no live windows).
final class InputRoutingTests: XCTestCase {
    private typealias Window = WindowResolver.WindowInfo

    private let chrome: pid_t = 500
    private let textEdit: pid_t = 600
    private let useMac: pid_t = 700

    /// The window UseMac opened and works in (pinned with `--window`).
    private let usemacWindow: CGWindowID = 11
    /// The user's own Chrome window.
    private let userWindow: CGWindowID = 10

    private let full = CGRect(x: 0, y: 38, width: 1512, height: 862)
    private var center: CGPoint { CGPoint(x: full.midX, y: full.midY) }

    private func window(_ id: CGWindowID, pid: pid_t, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> Window {
        Window(windowId: id, pid: pid, frame: frame, layer: layer, isOnScreen: true, title: nil, alpha: alpha)
    }

    private func route(
        _ windows: [Window],
        at point: CGPoint?,
        targetPid: pid_t? = nil,
        targetWindowId: CGWindowID?,
        documentWindows: Set<CGWindowID> = [],
        backgroundAllowed: Bool
    ) -> InputRouting.PointerRoute {
        InputRouting.pointerRoute(
            point: point,
            targetPid: targetPid ?? chrome,
            targetWindowId: targetWindowId,
            windows: windows,
            isDocumentWindow: { documentWindows.contains($0) },
            backgroundAllowed: backgroundAllowed
        )
    }

    // MARK: Mouse events

    func testTargetWindowOnTopGetsRealInput() {
        let windows = [window(usemacWindow, pid: chrome, full), window(userWindow, pid: chrome, full)]
        XCTAssertEqual(route(windows, at: center, targetWindowId: usemacWindow, backgroundAllowed: true), .foreground)
        XCTAssertEqual(route(windows, at: center, targetWindowId: usemacWindow, backgroundAllowed: false), .foreground)
    }

    func testUsersWindowOfTheSameAppOnTopNeverGetsTheEvent() {
        // Chrome is the active app; the user's window sits over the one UseMac opened (smoke finding #80 (2)).
        let user = window(userWindow, pid: chrome, full)
        let windows = [user, window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(
            route(windows, at: center, targetWindowId: usemacWindow, documentWindows: [userWindow, usemacWindow], backgroundAllowed: true),
            .background(covering: user)
        )
        XCTAssertEqual(
            route(windows, at: center, targetWindowId: usemacWindow, documentWindows: [userWindow, usemacWindow], backgroundAllowed: false),
            .refuse(covering: user)
        )
    }

    func testFullSizeWindowOfTheSameAppIsNotMistakenForAPopup() {
        // Even when AX cannot list the app's windows, a window as large as the target is not attached to it.
        let user = window(userWindow, pid: chrome, full)
        let windows = [user, window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(route(windows, at: center, targetWindowId: usemacWindow, backgroundAllowed: false), .refuse(covering: user))
    }

    func testAnotherAppsWindowOnTop() {
        let cover = window(30, pid: textEdit, CGRect(x: 500, y: 300, width: 600, height: 400))
        let windows = [cover, window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(route(windows, at: center, targetWindowId: usemacWindow, backgroundAllowed: true), .background(covering: cover))
        // Away from the covering window the target is on top again.
        XCTAssertEqual(route(windows, at: CGPoint(x: 100, y: 100), targetWindowId: usemacWindow, backgroundAllowed: false), .foreground)
    }

    func testPopupOfTheTargetAppOverItsWindowStillCounts() {
        // An autocomplete list or sheet of the same app, small and inside the target window, is the target.
        let popup = window(40, pid: chrome, CGRect(x: 600, y: 400, width: 300, height: 200))
        let windows = [popup, window(usemacWindow, pid: chrome, full), window(userWindow, pid: chrome, full)]
        XCTAssertEqual(
            route(windows, at: CGPoint(x: 700, y: 450), targetWindowId: usemacWindow, documentWindows: [userWindow, usemacWindow], backgroundAllowed: false),
            .foreground
        )
    }

    func testSmallDocumentWindowOfTheSameAppInsideTheTargetIsACover() {
        // A small user window placed inside the target's frame looks attached by geometry; AX says it is a
        // document window of its own.
        let small = window(41, pid: chrome, CGRect(x: 600, y: 400, width: 500, height: 300))
        let windows = [small, window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(
            route(windows, at: CGPoint(x: 700, y: 450), targetWindowId: usemacWindow, documentWindows: [41, usemacWindow], backgroundAllowed: false),
            .refuse(covering: small)
        )
    }

    func testNothingOnScreenAtThePoint() {
        let windows = [window(usemacWindow, pid: chrome, CGRect(x: 0, y: 0, width: 400, height: 400))]
        XCTAssertEqual(route(windows, at: CGPoint(x: 900, y: 900), targetWindowId: usemacWindow, backgroundAllowed: true), .background(covering: nil))
        XCTAssertEqual(route(windows, at: CGPoint(x: 900, y: 900), targetWindowId: usemacWindow, backgroundAllowed: false), .refuse(covering: nil))
    }

    func testNoPointMeansNoRealInput() {
        // A wheel event without a location goes wherever the cursor is.
        let windows = [window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(route(windows, at: nil, targetWindowId: usemacWindow, backgroundAllowed: true), .background(covering: nil))
        XCTAssertEqual(route(windows, at: nil, targetWindowId: usemacWindow, backgroundAllowed: false), .refuse(covering: nil))
    }

    func testFloatingPanelOfAnotherAppCovers() {
        let panel = window(50, pid: textEdit, CGRect(x: 700, y: 400, width: 200, height: 200), layer: 3)
        let windows = [panel, window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(route(windows, at: CGPoint(x: 750, y: 450), targetWindowId: usemacWindow, backgroundAllowed: false), .refuse(covering: panel))
    }

    func testScreenLevelOverlaysDoNotCover() {
        // UseMac's highlight overlay (status bar level, click-through), the menu bar, the Dock and invisible
        // windows sit above or outside the levels that take input like a normal window.
        let windows = [
            window(60, pid: useMac, full, layer: 25),
            window(61, pid: 900, full, layer: 24),
            window(62, pid: 901, full, layer: 20),
            window(63, pid: 902, full, layer: 0, alpha: 0),
            window(usemacWindow, pid: chrome, full)
        ]
        XCTAssertEqual(route(windows, at: center, targetWindowId: usemacWindow, backgroundAllowed: false), .foreground)
    }

    func testUseMacActivityPanelCovers() {
        // The activity panel floats at the floating level and takes clicks (its Stop button): a real click there
        // would hit UseMac, not the target.
        let panel = window(64, pid: useMac, CGRect(x: 1100, y: 600, width: 380, height: 260), layer: 3)
        let windows = [panel, window(usemacWindow, pid: chrome, full)]
        XCTAssertEqual(route(windows, at: CGPoint(x: 1200, y: 700), targetWindowId: usemacWindow, backgroundAllowed: false), .refuse(covering: panel))
        XCTAssertEqual(route(windows, at: center, targetWindowId: usemacWindow, backgroundAllowed: false), .foreground)
    }

    func testWithoutAKnownWindowAnyWindowOfTheAppCounts() {
        let windows = [window(userWindow, pid: chrome, full), window(30, pid: textEdit, full)]
        XCTAssertEqual(route(windows, at: center, targetWindowId: nil, backgroundAllowed: false), .foreground)
        XCTAssertEqual(
            route(windows, at: center, targetPid: textEdit, targetWindowId: nil, backgroundAllowed: false),
            .refuse(covering: windows[0])
        )
    }

    func testReceiverIsTheFrontmostWindowAtThePoint() {
        let back = window(1, pid: chrome, full)
        let front = window(2, pid: textEdit, CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(InputRouting.receiver(at: CGPoint(x: 100, y: 100), in: [front, back])?.windowId, 2)
        XCTAssertEqual(InputRouting.receiver(at: CGPoint(x: 800, y: 800), in: [front, back])?.windowId, 1)
        XCTAssertNil(InputRouting.receiver(at: CGPoint(x: 5000, y: 5000), in: [front, back]))
    }

    // MARK: Keys

    func testKeysReachOnlyTheFocusedWindowOfTheFrontmostApp() {
        XCTAssertTrue(InputRouting.keysReachTarget(appIsFrontmost: true, targetWindowId: 11, focusedWindowId: 11))
        // Chrome in front with the user's window focused: keys would go there, not to UseMac's window.
        XCTAssertFalse(InputRouting.keysReachTarget(appIsFrontmost: true, targetWindowId: 11, focusedWindowId: 10))
        XCTAssertFalse(InputRouting.keysReachTarget(appIsFrontmost: false, targetWindowId: 11, focusedWindowId: 11))
        // Unknown ids: the app-level check decides, as before.
        XCTAssertTrue(InputRouting.keysReachTarget(appIsFrontmost: true, targetWindowId: nil, focusedWindowId: 10))
        XCTAssertTrue(InputRouting.keysReachTarget(appIsFrontmost: true, targetWindowId: 11, focusedWindowId: nil))
    }
}
