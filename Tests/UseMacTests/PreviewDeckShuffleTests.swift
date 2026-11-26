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
}

final class PreviewTaskColorsTests: XCTestCase {
    func testTwoSessionsOfTheSameAgentGetTwoColors() {
        let one = PreviewTaskColors.key(taskId: "t1", cardId: "tab:1")
        let two = PreviewTaskColors.key(taskId: "t2", cardId: "tab:2")
        let slots = PreviewTaskColors.reconcile([:], keys: [one, two])
        XCTAssertNotEqual(slots[one], slots[two])
    }

    func testATasksCardsShareItsColor() {
        let first = PreviewTaskColors.key(taskId: "t1", cardId: "tab:1")
        let second = PreviewTaskColors.key(taskId: "t1", cardId: "tab:2")
        XCTAssertEqual(first, second)
        let slots = PreviewTaskColors.reconcile([:], keys: [first, "card:x", second])
        XCTAssertEqual(slots.count, 2)
    }

    func testCardsWithoutATaskGetTheirOwnColor() {
        let a = PreviewTaskColors.key(taskId: nil, cardId: "app:10")
        let b = PreviewTaskColors.key(taskId: "", cardId: "app:11")
        XCTAssertNotEqual(a, b)
        let slots = PreviewTaskColors.reconcile([:], keys: [a, b])
        XCTAssertNotEqual(slots[a], slots[b])
    }

    func testColorsGoInOrderOfArrivalAndStayPut() {
        var slots = PreviewTaskColors.reconcile([:], keys: ["task:a"])
        slots = PreviewTaskColors.reconcile(slots, keys: ["task:b", "task:a"])
        XCTAssertEqual(slots["task:a"], 0)
        XCTAssertEqual(slots["task:b"], 1)
    }

    func testAFinishedTaskGivesItsColorBack() {
        var slots = PreviewTaskColors.reconcile([:], keys: ["task:a", "task:b", "task:c"])
        slots = PreviewTaskColors.reconcile(slots, keys: ["task:a", "task:c"])
        XCTAssertNil(slots["task:b"])
        slots = PreviewTaskColors.reconcile(slots, keys: ["task:a", "task:c", "task:d"])
        XCTAssertEqual(slots["task:d"], 1)
        XCTAssertEqual(slots["task:c"], 2)
    }

    func testMoreTasksThanColorsStillGetOne() {
        let keys = (0..<(PreviewTaskColors.paletteSize + 2)).map { "task:\($0)" }
        let slots = PreviewTaskColors.reconcile([:], keys: keys)
        XCTAssertEqual(slots.count, keys.count)
        XCTAssertTrue(slots.values.allSatisfy { (0..<PreviewTaskColors.paletteSize).contains($0) })
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
