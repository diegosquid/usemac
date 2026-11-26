import CoreGraphics
import XCTest
@testable import UseMacEngine
import UseMacProtocol

/// Which element the scroll fallback scrolls into view when a page ignores the wheel event.
final class ScrollFallbackTests: XCTestCase {
    private let webArea = ScreenRect(x: 0, y: 215, width: 1512, height: 685)
    private var pageCenter: CGPoint { CGPoint(x: webArea.centerX, y: webArea.centerY) }

    private func node(_ id: String, _ role: String = "AXButton", _ frame: ScreenRect, offscreen: Bool = false) -> ElementNode {
        ElementNode(id: id, role: role, title: id, frame: frame, offscreen: offscreen ? true : nil)
    }

    private func row(_ n: Int, y: Double, height: Double = 56, offscreen: Bool = false) -> ElementNode {
        node("row\(n)", "AXButton", ScreenRect(x: 24, y: y, width: 879, height: height), offscreen: offscreen)
    }

    /// The tree a native observe of a Chrome window returns (smoke run, 2026-11-25): window and toolbar, then
    /// the page's web area with its rows, then the infobar and the tab strip, all visible.
    private func chromeWindow(rowsAbove: Int = 0, visibleRows: Int = 10, totalRows: Int = 160)
        -> (nodes: [ElementNode], containers: [ScrollContainer]) {
        var nodes: [ElementNode] = [
            node("window", "AXWindow", ScreenRect(x: 0, y: 38, width: 1512, height: 862)),
            node("back", "AXButton", ScreenRect(x: 0, y: 84, width: 40, height: 34)),
            node("omnibox", "AXTextField", ScreenRect(x: 158, y: 89, width: 775, height: 24)),
            node("page", "AXWebArea", webArea)
        ]
        let pageStart = nodes.count
        // A fixed "scrollY=" indicator first in the DOM: always visible.
        nodes.append(node("position", "AXStaticText", ScreenRect(x: 1435, y: 222, width: 66, height: 19)))
        for n in 1...totalRows {
            if n <= rowsAbove {
                // Chrome clips an element scrolled out above to the viewport's top edge.
                nodes.append(row(n, y: webArea.y, height: 0, offscreen: true))
            } else if n <= rowsAbove + visibleRows {
                nodes.append(row(n, y: 283 + Double(n - rowsAbove - 1) * 60))
            } else {
                // ...and one below to the bottom edge.
                nodes.append(row(n, y: webArea.y + webArea.height, height: 0, offscreen: true))
            }
        }
        let pageEnd = nodes.count
        nodes += [
            node("infobar", "AXGroup", ScreenRect(x: 0, y: 159, width: 1512, height: 56)),
            node("infobarClose", "AXButton", ScreenRect(x: 1468, y: 173, width: 28, height: 28)),
            node("tabStrip", "AXTabGroup", ScreenRect(x: 114, y: 38, width: 328, height: 41)),
            node("tab", "AXRadioButton", ScreenRect(x: 186, y: 38, width: 256, height: 41)),
            node("newTab", "AXButton", ScreenRect(x: 436, y: 38, width: 28, height: 41))
        ]
        let containers = [ScrollContainer(role: "AXWebArea", frame: webArea, descendants: pageStart..<pageEnd, depth: 4)]
        return (nodes, containers)
    }

    private func id(_ index: Int?, in nodes: [ElementNode]) -> String? {
        index.map { nodes[$0].id }
    }

    // MARK: Chrome

    func testChromeScrollDownPicksTheFirstRowBelowThePage() {
        let layout = chromeWindow()
        let index = ScrollFallback.nextOffscreenIndex(nodes: layout.nodes, containers: layout.containers, at: pageCenter, down: true)
        XCTAssertEqual(id(index, in: layout.nodes), "row11")
    }

    func testWindowWideTreeOrderFindsNothingInChrome() {
        // The old rule (first offscreen element after the last visible one in the whole window): the tab strip is
        // listed after the page, so nothing follows it.
        let layout = chromeWindow()
        XCTAssertNil(ScrollFallback.nextOffscreenIndex(nodes: layout.nodes, containers: [], at: pageCenter, down: true))
    }

    func testChromeScrollUpAndDownFromTheMiddleOfThePage() {
        let layout = chromeWindow(rowsAbove: 5, visibleRows: 10)
        XCTAssertEqual(id(ScrollFallback.nextOffscreenIndex(nodes: layout.nodes, containers: layout.containers, at: pageCenter, down: false), in: layout.nodes), "row5")
        XCTAssertEqual(id(ScrollFallback.nextOffscreenIndex(nodes: layout.nodes, containers: layout.containers, at: pageCenter, down: true), in: layout.nodes), "row16")
    }

    func testAtTheTopNothingScrollsUp() {
        let layout = chromeWindow()
        XCTAssertNil(ScrollFallback.nextOffscreenIndex(nodes: layout.nodes, containers: layout.containers, at: pageCenter, down: false))
    }

    func testFixedFooterLastInThePageDoesNotHideTheRowsBelow() {
        var layout = chromeWindow()
        // A cookie bar fixed at the bottom, last in the DOM and visible.
        let footer = node("cookieBar", "AXButton", ScreenRect(x: 0, y: 840, width: 1512, height: 60))
        let end = layout.containers[0].descendants.upperBound
        layout.nodes.insert(footer, at: end)
        layout.containers[0].descendants = layout.containers[0].descendants.lowerBound..<(end + 1)
        let index = ScrollFallback.nextOffscreenIndex(nodes: layout.nodes, containers: layout.containers, at: pageCenter, down: true)
        XCTAssertEqual(id(index, in: layout.nodes), "row11")
    }

    func testElementsWithoutAFrameFallBackToTreeOrder() {
        let unknown = ScreenRect(x: 0, y: 0, width: 0, height: 0)
        let nodes = [
            node("page", "AXWebArea", webArea),
            node("a", "AXButton", ScreenRect(x: 24, y: 300, width: 200, height: 40)),
            node("b", "AXButton", ScreenRect(x: 24, y: 360, width: 200, height: 40)),
            node("c", "AXButton", unknown, offscreen: true),
            node("d", "AXButton", unknown, offscreen: true)
        ]
        let containers = [ScrollContainer(role: "AXWebArea", frame: webArea, descendants: 1..<5, depth: 3)]
        XCTAssertEqual(id(ScrollFallback.nextOffscreenIndex(nodes: nodes, containers: containers, at: pageCenter, down: true), in: nodes), "c")
        // An element without a frame is never taken for one above the page.
        XCTAssertNil(ScrollFallback.nextOffscreenIndex(nodes: nodes, containers: containers, at: pageCenter, down: false))
    }

    // MARK: Containers

    func testOnlyTheScrollViewUnderThePointCounts() {
        // Two lists side by side in a native window; the left one has rows below its edge too.
        let left = ScreenRect(x: 0, y: 100, width: 300, height: 500)
        let right = ScreenRect(x: 300, y: 100, width: 600, height: 500)
        let nodes = [
            node("window", "AXWindow", ScreenRect(x: 0, y: 60, width: 900, height: 545)),
            node("l1", "AXRow", ScreenRect(x: 0, y: 120, width: 300, height: 20)),
            node("l2", "AXRow", ScreenRect(x: 0, y: 640, width: 300, height: 20), offscreen: true),
            node("r1", "AXRow", ScreenRect(x: 300, y: 120, width: 600, height: 20)),
            node("r2", "AXRow", ScreenRect(x: 300, y: 610, width: 600, height: 20), offscreen: true),
            node("r3", "AXRow", ScreenRect(x: 300, y: 630, width: 600, height: 20), offscreen: true)
        ]
        let containers = [
            ScrollContainer(role: "AXScrollArea", frame: left, descendants: 1..<3, depth: 2),
            ScrollContainer(role: "AXScrollArea", frame: right, descendants: 3..<6, depth: 2)
        ]
        XCTAssertEqual(id(ScrollFallback.nextOffscreenIndex(nodes: nodes, containers: containers, at: CGPoint(x: 600, y: 350), down: true), in: nodes), "r2")
        XCTAssertEqual(id(ScrollFallback.nextOffscreenIndex(nodes: nodes, containers: containers, at: CGPoint(x: 150, y: 350), down: true), in: nodes), "l2")
    }

    func testInnermostContainerUnderThePointWins() {
        let outer = ScrollContainer(role: "AXWebArea", frame: webArea, descendants: 1..<20, depth: 3)
        let inner = ScrollContainer(role: "AXScrollArea", frame: ScreenRect(x: 100, y: 300, width: 400, height: 300), descendants: 5..<10, depth: 7)
        XCTAssertEqual(ScrollFallback.container([outer, inner], at: CGPoint(x: 200, y: 400)), inner)
        XCTAssertEqual(ScrollFallback.container([outer, inner], at: CGPoint(x: 1000, y: 400)), outer)
        XCTAssertNil(ScrollFallback.container([outer, inner], at: CGPoint(x: 1000, y: 100)))
        // Without a point (or outside every frame), the container holding the scrolled element.
        XCTAssertEqual(ScrollFallback.container([outer, inner], at: nil, elementIndex: 7), inner)
        XCTAssertEqual(ScrollFallback.container([outer, inner], at: CGPoint(x: 1000, y: 100), elementIndex: 12), outer)
    }

    func testWithoutContainersTheWholeListIsSearchedByTreeOrder() {
        // Snapshots taken before containers were recorded, or apps whose scroll views AX does not expose.
        let nodes = [
            node("window", "AXWindow", ScreenRect(x: 0, y: 0, width: 800, height: 600)),
            node("a", "AXCell", ScreenRect(x: 0, y: 100, width: 800, height: 20)),
            node("b", "AXCell", ScreenRect(x: 0, y: 0, width: 0, height: 0), offscreen: true)
        ]
        XCTAssertEqual(id(ScrollFallback.nextOffscreenIndex(nodes: nodes, containers: [], at: CGPoint(x: 400, y: 300), down: true), in: nodes), "b")
    }
}
