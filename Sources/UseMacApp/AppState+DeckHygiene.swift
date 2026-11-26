import AppKit
import SwiftUI
import UseMacEngine
import UseMacProtocol

/// What the deck hygiene keeps between runs: the periodic sweep and when each card last tried a still.
struct DeckHygieneState {
    var sweepTask: Task<Void, Never>?
    var stillAttempts: [String: Date] = [:]
}

/// Keeps the preview's cards honest (PreviewCardLifecycle): background native cards get a still picture of their
/// window, quiet background cards stop showing the busy dot, and cards with nothing to show (no picture and quiet, or
/// an app that quit) leave the deck.
extension AppState {
    /// How often the deck is checked while it has cards.
    static let deckSweepIntervalNs: UInt64 = 10_000_000_000

    /// Called after an activity updated a card.
    func deckCardDidRecordActivity(cardId: String) {
        refreshCardStillIfNeeded(cardId: cardId)
        scheduleDeckSweepIfNeeded()
    }

    /// Takes a one-shot still of a native card's window when the live stream does not cover it (it is not in front)
    /// or it has no picture yet.
    func refreshCardStillIfNeeded(cardId: String) {
        guard let card = hudDeck.first(where: { $0.id == cardId }), !card.isBrowser,
              let app = card.appDescriptor, app.pid > 0 else { return }
        let now = Date()
        guard PreviewCardLifecycle.wantsStill(
            isBrowser: card.isBrowser,
            isChromium: Self.isChromium(app),
            isFront: hudDeck.first?.id == cardId,
            hasPreview: card.previewImage != nil,
            lastAttempt: deckHygiene.stillAttempts[cardId],
            now: now
        ) else { return }
        deckHygiene.stillAttempts[cardId] = now
        Task { @MainActor [weak self] in
            guard let self, let shot = await self.engine.captureWindowPreview(for: app) else { return }
            guard let idx = self.hudDeck.firstIndex(where: { $0.id == cardId }), !self.hudDeck[idx].isBrowser else { return }
            // The front card's live stream frames are newer than this still.
            if idx == 0 && self.hudDeck[idx].previewImage != nil { return }
            self.hudDeck[idx].previewImage = shot.image
            if self.hudDeck[idx].sourceBounds == nil {
                self.hudDeck[idx].sourceBounds = shot.windowBounds
            }
            if idx == 0 && !self.videoSink.hasReceivedFrame {
                self.syncFrontCardToUI()
            }
        }
    }

    /// When the live stream goes idle (the front card's window could not be found or captured right now), the stage
    /// keeps that card's still instead of an empty spinner.
    func showFrontCardStillIfStreamIdle() {
        guard let front = hudDeck.first, let cgImage = front.previewImage else { return }
        let isChromium = front.appDescriptor.map(Self.isChromium) ?? false
        guard PreviewCardLifecycle.stageKeepsStill(
            frontIsBrowser: front.isBrowser,
            frontIsChromium: isChromium,
            frontHasPreview: true
        ), !chromePreviewHidden else { return }
        videoSink.pushCGImage(
            cgImage,
            width: max(1, cgImage.width),
            height: max(1, cgImage.height),
            sourceBounds: front.appDescriptor?.windowBounds ?? front.sourceBounds,
            sourceName: front.title,
            isBrowser: false,
            pid: front.appDescriptor?.pid
        )
    }

    /// Runs the deck sweep every few seconds while the deck has cards.
    func scheduleDeckSweepIfNeeded() {
        guard deckHygiene.sweepTask == nil, !hudDeck.isEmpty else { return }
        deckHygiene.sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.deckSweepIntervalNs)
                guard let self, !Task.isCancelled else { return }
                if self.hudDeck.isEmpty {
                    self.deckHygiene.sweepTask = nil
                    self.deckHygiene.stillAttempts.removeAll()
                    return
                }
                self.sweepDeck()
            }
        }
    }

    /// Applies PreviewCardLifecycle.sweep to every card.
    func sweepDeck(now: Date = Date()) {
        var removedIds: Set<String> = []
        var settledIds: Set<String> = []
        for (index, card) in hudDeck.enumerated() {
            let appRunning: Bool = {
                guard !card.isBrowser, let pid = card.appDescriptor?.pid, pid > 0 else { return true }
                guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
                return !running.isTerminated
            }()
            let verdict = PreviewCardLifecycle.sweep(
                PreviewCardLifecycle.Card(
                    isBrowser: card.isBrowser,
                    isFront: index == 0,
                    hasPreview: card.previewImage != nil,
                    isBusy: card.isBusy,
                    isCompleted: card.isCompleted,
                    appRunning: appRunning,
                    lastActivity: card.lastActivityDate
                ),
                now: now
            )
            switch verdict {
            case .keep: break
            case .settle: settledIds.insert(card.id)
            case .remove: removedIds.insert(card.id)
            }
        }
        guard !removedIds.isEmpty || !settledIds.isEmpty else { return }

        let frontChanged = hudDeck.first.map { removedIds.contains($0.id) } ?? false
        for idx in hudDeck.indices where settledIds.contains(hudDeck[idx].id) {
            hudDeck[idx].isBusy = false
        }
        if !removedIds.isEmpty {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                hudDeck.removeAll { removedIds.contains($0.id) }
            }
            for id in removedIds {
                deckHygiene.stillAttempts[id] = nil
            }
        }
        if hudDeck.isEmpty {
            if !isHUDManuallyPinned && isHUDVisible && !status.killSwitchTripped {
                hideHUD(userInitiated: false)
            }
        } else if frontChanged {
            syncFrontCardToUI()
        }
    }
}
