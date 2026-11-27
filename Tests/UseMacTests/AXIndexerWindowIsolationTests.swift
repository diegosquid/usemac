import ApplicationServices
import XCTest
@testable import UseMacEngine
import UseMacProtocol

final class AXIndexerWindowIsolationTests: XCTestCase {
    private let pid: Int32 = 1_000_001
    private let firstWindow: UInt32 = 101
    private let secondWindow: UInt32 = 202

    func testHotObserveDoesNotRelabelElementsFromAnotherWindow() {
        let indexer = AXIndexer(resolveWindowId: { _ in self.firstWindow })
        let first = indexer.observe(app: app(windowId: firstWindow), accessibilityGranted: false)
        let second = indexer.observe(app: app(windowId: secondWindow), accessibilityGranted: false)

        XCTAssertFalse(first.fromHotCache)
        XCTAssertFalse(second.fromHotCache)
        XCTAssertEqual(second.elements.first?.title, "Window 202")
        XCTAssertNotEqual(first.elements.first?.id, second.elements.first?.id)

        let hot = indexer.observe(app: app(windowId: secondWindow), accessibilityGranted: false)
        XCTAssertTrue(hot.fromHotCache)
        XCTAssertEqual(hot.app.windowId, secondWindow)
        XCTAssertEqual(hot.elements.map(\.id), second.elements.map(\.id))

        let implicit = indexer.observe(app: AppDescriptor(pid: pid, name: "Two-window app"), accessibilityGranted: false)
        XCTAssertTrue(implicit.fromHotCache)
        XCTAssertEqual(implicit.app.windowId, firstWindow)
        XCTAssertEqual(implicit.elements.map(\.id), first.elements.map(\.id))
    }

    func testWindowScopedLookupsAndCachedElementOwnerStayIsolated() throws {
        var target: UInt32? = firstWindow
        let indexer = AXIndexer(resolveWindowId: { _ in target })
        let firstElement = AXUIElementCreateApplication(pid)
        let secondElement = AXUIElementCreateSystemWide()
        let first = try seed(indexer, windowId: firstWindow, element: firstElement)
        let second = try seed(indexer, windowId: secondWindow, element: secondElement)

        for (windowId, ownNode, otherNode, ownElement) in [
            (firstWindow, first, second, firstElement),
            (secondWindow, second, first, secondElement)
        ] {
            target = windowId
            XCTAssertEqual(indexer.node(for: ownNode.id, pid: pid)?.title, ownNode.title)
            XCTAssertNil(indexer.node(for: otherNode.id, pid: pid))
            XCTAssertNil(indexer.element(for: otherNode.id, pid: pid))
            XCTAssertNil(indexer.liveNode(for: otherNode.id, pid: pid))
            XCTAssertEqual(indexer.snapshotContext(pid: pid), .init(windowId: windowId, windowTitle: ownNode.title))
            XCTAssertEqual(indexer.latestNodes(pid: pid).map(\.id), [ownNode.id])
            let scrollLayout = indexer.latestScrollLayout(pid: pid)
            XCTAssertEqual(scrollLayout.nodes.map(\.id), [ownNode.id])
            XCTAssertEqual(scrollLayout.containers.first?.depth, Int(windowId))

            let match = ElementMatch(title: "Window")
            let hits = try XCTUnwrap(indexer.findInCleanCache(pid: pid, match: match, limit: 10) { element, node in
                XCTAssertTrue(CFEqual(element, ownElement))
                XCTAssertEqual(node.id, ownNode.id)
                return node
            })
            XCTAssertEqual(hits.map(\.id), [ownNode.id])
            XCTAssertNil(indexer.findInCleanCache(pid: pid, match: ElementMatch(title: otherNode.title), limit: 10) { _, node in
                XCTFail("The other window's element must not be refreshed")
                return node
            })

            let owner = try XCTUnwrap(indexer.cachedElementOwner(for: otherNode.id))
            XCTAssertEqual(owner.node.title, otherNode.title)
            XCTAssertEqual(owner.pid, pid)
            XCTAssertEqual(owner.windowId, windowId == firstWindow ? secondWindow : firstWindow)
            XCTAssertEqual(indexer.node(for: otherNode.id)?.pid, pid)
        }

        target = nil
        XCTAssertNil(indexer.snapshotContext(pid: pid))
        XCTAssertNil(indexer.node(for: first.id, pid: pid))
        XCTAssertNil(indexer.cachedElementOwner(for: "missing"))
    }

    func testColdObserveDiffUsesOnlyPreviousSnapshotOfThatWindow() {
        let indexer = AXIndexer(resolveWindowId: { _ in nil })
        let first = indexer.observe(app: app(windowId: firstWindow), accessibilityGranted: false)
        _ = indexer.observe(app: app(windowId: secondWindow), accessibilityGranted: false)

        let refreshed = indexer.observe(app: app(windowId: firstWindow), useCache: false, accessibilityGranted: false)
        XCTAssertEqual(refreshed.elements.map(\.id), first.elements.map(\.id))
        XCTAssertEqual(refreshed.diff?.summary, "no changes")
    }

    func testInvalidationAndChangeNotificationsDirtyBothWindowsOfThePID() throws {
        var target: UInt32? = firstWindow
        let indexer = AXIndexer(resolveWindowId: { _ in target })
        let element = AXUIElementCreateApplication(pid)
        let match = ElementMatch(title: "Window")

        for dirty in [{ indexer.invalidate(pid: self.pid) }, { indexer.recordChange(pid: self.pid) }, { indexer.markDirtyAll() }] {
            for windowId in [firstWindow, secondWindow] {
                target = windowId
                _ = try seed(indexer, windowId: windowId, element: element)
                XCTAssertNotNil(indexer.findInCleanCache(pid: pid, match: match, limit: 1) { _, node in node })
            }

            dirty()
            for windowId in [firstWindow, secondWindow] {
                target = windowId
                XCTAssertNil(indexer.findInCleanCache(pid: pid, match: match, limit: 1) { _, node in node })
                XCTAssertFalse(indexer.observe(app: app(windowId: windowId), accessibilityGranted: false).fromHotCache)
            }
        }
    }

    private func app(windowId: UInt32) -> AppDescriptor {
        AppDescriptor(pid: pid, name: "Two-window app", windowTitle: "Window \(windowId)", windowId: windowId)
    }

    private func seed(_ indexer: AXIndexer, windowId: UInt32, element: AXUIElement) throws -> ElementNode {
        let snapshot = indexer.observe(app: app(windowId: windowId), useCache: false, accessibilityGranted: false)
        let node = try XCTUnwrap(snapshot.elements.first)
        indexer.storeSnapshot(
            snapshot,
            elementMap: [node.id: element],
            windowTitle: node.title,
            scrollContainers: [.init(role: "AXScrollArea", frame: node.frame, descendants: 0..<1, depth: Int(windowId))]
        )
        return node
    }
}
