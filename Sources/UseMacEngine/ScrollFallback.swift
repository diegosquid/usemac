import CoreGraphics
import Foundation
import UseMacProtocol

/// A scrollable region seen in an observe (a web area or a scroll area), with the elements inside it.
public struct ScrollContainer: Equatable, Sendable {
    public var role: String
    public var frame: ScreenRect?
    /// Indexes, in the snapshot's `elements`, of the container's descendants (the container itself excluded).
    public var descendants: Range<Int>
    /// Depth in the AX tree, 0 being the window.
    public var depth: Int

    public init(role: String, frame: ScreenRect?, descendants: Range<Int>, depth: Int) {
        self.role = role
        self.frame = frame
        self.descendants = descendants
        self.depth = depth
    }
}

/// Picks the element to scroll into view when a page ignores the wheel: the next element out of view in the
/// region being scrolled. Elements outside that region never count, so Chrome's tab strip and infobar (listed
/// after the page's web area) or another scroll view's rows cannot stop or misdirect it.
public enum ScrollFallback {
    /// AX roles that scroll their content.
    public static let containerRoles: Set<String> = ["AXWebArea", "AXScrollArea"]

    /// The innermost container whose frame holds `point`. Without a point, or when no frame holds it, the
    /// innermost container holding `elementIndex`. Nil when neither finds one.
    public static func container(_ containers: [ScrollContainer], at point: CGPoint?, elementIndex: Int? = nil) -> ScrollContainer? {
        func innermost(_ matching: [ScrollContainer]) -> ScrollContainer? {
            matching.max { a, b in
                a.depth != b.depth ? a.depth < b.depth : a.descendants.count > b.descendants.count
            }
        }
        if let point {
            let holding = containers.filter { container in
                guard let frame = container.frame, frame.width > 1, frame.height > 1 else { return false }
                return Self.rect(frame).contains(point)
            }
            if let found = innermost(holding) {
                return found
            }
        }
        if let elementIndex {
            return innermost(containers.filter { $0.descendants.contains(elementIndex) })
        }
        return nil
    }

    /// Index in `nodes` of the element to scroll into view next, or nil.
    ///
    /// Inside the container under `point`:
    /// 1. by position: the first element below the visible part when scrolling down (the last one above it when
    ///    scrolling up). Chrome clips the bounds of an element out of view to the edge of the page's viewport
    ///    (zero height at its bottom or top edge); native views report real positions past the edge.
    /// 2. by tree order, when no position says where an element is: the first element out of view after the
    ///    last visible one (the last one before the first visible one, scrolling up).
    /// Without a container under the point, the whole list is searched, by tree order only.
    public static func nextOffscreenIndex(
        nodes: [ElementNode],
        containers: [ScrollContainer],
        at point: CGPoint?,
        down: Bool,
        elementIndex: Int? = nil
    ) -> Int? {
        let found = container(containers, at: point, elementIndex: elementIndex)
        let scope: Range<Int> = found.map { $0.descendants.clamped(to: nodes.indices) } ?? nodes.indices
        guard !scope.isEmpty else { return nil }

        if let frame = found?.frame.map(Self.rect), frame.width > 1, frame.height > 1 {
            let edge: CGFloat = 1
            let byPosition: (Int) -> Bool = { index in
                let node = nodes[index]
                guard node.offscreen == true, isCandidateRole(node.role), hasPosition(node) else { return false }
                let box = rect(node.frame)
                guard box.maxX >= frame.minX, box.minX <= frame.maxX else { return false }
                return down ? box.minY >= frame.maxY - edge : box.maxY <= frame.minY + edge
            }
            if let index = down ? scope.first(where: byPosition) : scope.last(where: byPosition) {
                return index
            }
        }

        let visible = scope.filter { nodes[$0].offscreen != true && isCandidateRole(nodes[$0].role) }
        guard let firstVisible = visible.first, let lastVisible = visible.last else { return nil }
        let isOffscreen: (Int) -> Bool = { nodes[$0].offscreen == true && isCandidateRole(nodes[$0].role) }
        return down
            ? (lastVisible + 1 ..< scope.upperBound).first(where: isOffscreen)
            : (scope.lowerBound ..< firstVisible).last(where: isOffscreen)
    }

    private static func isCandidateRole(_ role: String) -> Bool {
        role != "AXWindow"
    }

    /// False for elements AX gave no frame at all (reported as an empty rect at the origin).
    private static func hasPosition(_ node: ElementNode) -> Bool {
        !(node.frame.x == 0 && node.frame.y == 0 && node.frame.width == 0 && node.frame.height == 0)
    }

    private static func rect(_ frame: ScreenRect) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}
