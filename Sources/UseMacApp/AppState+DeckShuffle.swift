import AppKit
import SwiftUI
import UseMacEngine

/// What the deck's shuffle keeps between ticks.
struct DeckShuffleState {
    var tickTask: Task<Void, Never>?
    var dipTask: Task<Void, Never>?
    /// When the current front card came to the front.
    var frontSince = Date()
}

extension HUDSessionCard {
    /// The same card under a new id (a tab that was still opening got its real one), with its task, steps and stack
    /// history kept.
    func carryingDeckState(of existing: HUDSessionCard) -> HUDSessionCard {
        var card = self
        card.taskId = card.taskId ?? existing.taskId
        card.agentName = card.agentName ?? existing.agentName
        card.lastStepDate = existing.lastStepDate
        card.lastShownDate = existing.lastShownDate
        card.backgroundStepCount = existing.backgroundStepCount
        return card
    }

    /// Notes an activity on the card: its task, and for a step when it happened and, behind the front, a flash.
    mutating func recordDeckActivity(taskId: String?, isStep: Bool, isFront: Bool) {
        if let taskId, !taskId.isEmpty {
            self.taskId = taskId
        }
        guard isStep else { return }
        lastStepDate = Date()
        if !isFront {
            backgroundStepCount &+= 1
        }
    }
}

/// The live preview's stack: cards behind the front one take turns in front (PreviewDeckFocus.shuffleTarget).
extension AppState {
    /// How often the shuffle checks whether another card should come forward.
    static let deckShuffleTickNs: UInt64 = 1_000_000_000
    /// The front card's dip before it goes to the back.
    static let deckDipNs: UInt64 = 170_000_000

    /// Called whenever the deck changes: a new front starts its time in front and the old one remembers when it left,
    /// and the shuffle runs while there is a card behind the front.
    func deckDidChange(from oldDeck: [HUDSessionCard]) {
        let oldFront = oldDeck.first?.id
        let newFront = hudDeck.first?.id
        // A tab that was still opening getting its real id is the same card, not a new front.
        let isUpgrade = oldFront.flatMap { old in newFront.map { $0.hasPrefix(old + ":") } } ?? false
        if oldFront != newFront && !isUpgrade {
            let now = Date()
            deckShuffle.frontSince = now
            if let oldFront, let idx = hudDeck.firstIndex(where: { $0.id == oldFront }) {
                hudDeck[idx].lastShownDate = now
            }
        }

        if hudDeck.count > 1 {
            scheduleDeckShuffleIfNeeded()
        }
    }

    /// Checks the deck once a second while it has a card behind the front one.
    func scheduleDeckShuffleIfNeeded() {
        guard deckShuffle.tickTask == nil else { return }
        deckShuffle.tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.deckShuffleTickNs)
                guard let self, !Task.isCancelled else { return }
                if self.hudDeck.count < 2 {
                    self.deckShuffle.tickTask = nil
                    return
                }
                self.shuffleDeckIfDue()
            }
        }
    }

    /// Brings the next card with new work forward when the front has had its turn.
    func shuffleDeckIfDue(now: Date = Date()) {
        guard isHUDVisible, !isHUDCollapsed, deckShuffle.dipTask == nil else { return }
        let cards = hudDeck.map { card in
            PreviewDeckFocus.ShuffleCard(
                id: card.id,
                isCompleted: card.isCompleted && !card.isBusy,
                lastStep: card.lastStepDate,
                lastShown: card.lastShownDate
            )
        }
        let paused = isHUDHovered || status.killSwitchTripped || status.policy == .paused
        guard let target = PreviewDeckFocus.shuffleTarget(
            front: cards.first,
            behind: Array(cards.dropFirst()),
            frontSince: deckShuffle.frontSince,
            now: now,
            paused: paused
        ) else { return }
        shuffleDeck(to: target)
    }

    /// The front card dips, goes to the back of the deck, and `target` rises to the front. With Reduce Motion the
    /// cards change places at once and the new front fades in (ActivityHUDView).
    func shuffleDeck(to target: String) {
        guard let leaving = hudDeck.first?.id, leaving != target else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            applyShuffle(to: target, animation: nil)
            return
        }
        withAnimation(.easeIn(duration: 0.17)) {
            isDeckFrontDipping = true
        }
        deckShuffle.dipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.deckDipNs)
            guard let self else { return }
            self.deckShuffle.dipTask = nil
            // The deck may have changed during the dip: shuffle only if both cards are still where they were.
            if self.hudDeck.first?.id == leaving, self.hudDeck.contains(where: { $0.id == target }) {
                self.applyShuffle(to: target, animation: .spring(response: 0.42, dampingFraction: 0.8))
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                self.isDeckFrontDipping = false
            }
        }
    }

    private func applyShuffle(to target: String, animation: Animation?) {
        let byId = Dictionary(hudDeck.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = PreviewDeckFocus.shuffled(hudDeck.map(\.id), to: target).compactMap { byId[$0] }
        guard reordered.count == hudDeck.count else { return }
        withAnimation(animation) {
            hudDeck = reordered
        }
        syncFrontCardToUI()
    }
}
