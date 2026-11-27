import XCTest
@testable import UseMacEngine

final class PreviewDeckShuffleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var longAgo: Date { now.addingTimeInterval(-PreviewDeckFocus.shuffleDwell - 1) }
    private var front: PreviewDeckFocus.ShuffleCard { .init(id: "front", lastStep: now) }

    private func target(
        front: PreviewDeckFocus.ShuffleCard?,
        behind: [PreviewDeckFocus.ShuffleCard],
        frontSince: Date? = nil,
        paused: Bool = false
    ) -> String? {
        PreviewDeckFocus.shuffleTarget(front: front, behind: behind, frontSince: frontSince ?? longAgo, now: now, paused: paused)
    }

    // MARK: When the deck shuffles

    func testShufflesToACardBehindWithNewWork() {
        let behind = PreviewDeckFocus.ShuffleCard(id: "b", lastStep: now.addingTimeInterval(-1), lastShown: now.addingTimeInterval(-20))
        XCTAssertEqual(target(front: front, behind: [behind]), "b")
    }

    func testACardThatWasNeverInFrontCountsAsNew() {
        let behind = PreviewDeckFocus.ShuffleCard(id: "b", lastStep: now.addingTimeInterval(-30))
        XCTAssertEqual(target(front: front, behind: [behind]), "b")
    }

    func testHoldsTheFrontForTheDwellTime() {
        let behind = PreviewDeckFocus.ShuffleCard(id: "b", lastStep: now)
        let recently = now.addingTimeInterval(-(PreviewDeckFocus.shuffleDwell - 0.5))
        XCTAssertNil(target(front: front, behind: [behind], frontSince: recently))
    }

    func testSkipsACardWithNothingNewSinceItWasShown() {
        let shownAlready = PreviewDeckFocus.ShuffleCard(id: "b", lastStep: now.addingTimeInterval(-10), lastShown: now.addingTimeInterval(-5))
        let fresh = PreviewDeckFocus.ShuffleCard(id: "c", lastStep: now.addingTimeInterval(-1), lastShown: now.addingTimeInterval(-5))
        XCTAssertEqual(target(front: front, behind: [shownAlready, fresh]), "c")
        XCTAssertNil(target(front: front, behind: [shownAlready]))
    }

    func testSkipsCardsWithoutAnyStep() {
        // A tab that only sent frames (the page animates by itself) has no agent work to show.
        XCTAssertNil(target(front: front, behind: [.init(id: "b", lastStep: nil)]))
    }

    func testSkipsFinishedCards() {
        let finished = PreviewDeckFocus.ShuffleCard(id: "b", isCompleted: true, lastStep: now)
        XCTAssertNil(target(front: front, behind: [finished]))
    }

    func testFinishedFrontKeepsItsCheck() {
        // The finished card leaves through the completion flow; shuffling it away would cut its check short.
        let finishedFront = PreviewDeckFocus.ShuffleCard(id: "front", isCompleted: true, lastStep: now)
        XCTAssertNil(target(front: finishedFront, behind: [.init(id: "b", lastStep: now)]))
    }

    func testPausedDeckHolds() {
        // Pointer over the preview, or automation stopped.
        XCTAssertNil(target(front: front, behind: [.init(id: "b", lastStep: now)], paused: true))
    }

    func testNothingToShuffleWithoutAFrontOrCardsBehind() {
        XCTAssertNil(target(front: nil, behind: [.init(id: "b", lastStep: now)]))
        XCTAssertNil(target(front: front, behind: []))
    }

    // MARK: Deck order after a shuffle

    func testNextCardComesForwardAndTheFrontGoesToTheBack() {
        XCTAssertEqual(PreviewDeckFocus.shuffled(["a", "b", "c"], to: "b"), ["b", "c", "a"])
    }

    func testACardFurtherBackComesForwardAndTheOthersKeepTheirOrder() {
        XCTAssertEqual(PreviewDeckFocus.shuffled(["a", "b", "c", "d"], to: "c"), ["c", "b", "d", "a"])
    }

    func testShuffleToTheFrontOrAnUnknownCardChangesNothing() {
        XCTAssertEqual(PreviewDeckFocus.shuffled(["a", "b"], to: "a"), ["a", "b"])
        XCTAssertEqual(PreviewDeckFocus.shuffled(["a", "b"], to: "z"), ["a", "b"])
    }

    // MARK: One card per id

    func testDeckKeepsTheFirstCardOfEachId() {
        let ids = ["browser:Diego:1", "browser:Diego:1", "browser:Diego:2", "browser:Diego:1"]
        XCTAssertTrue(PreviewDeckFocus.hasDuplicateIds(ids))
        XCTAssertEqual(PreviewDeckFocus.firstOfEachId(ids, id: { $0 }), ["browser:Diego:1", "browser:Diego:2"])
        XCTAssertFalse(PreviewDeckFocus.hasDuplicateIds(["a", "b"]))
        XCTAssertEqual(PreviewDeckFocus.firstOfEachId([String](), id: { $0 }), [])
    }
}
