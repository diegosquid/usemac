import Foundation

/// When a live-preview card finishes, settles, leaves, or gets a still picture.
///
/// Native app cards used to linger as grey "ghost" cards with a busy dot that never stopped:
/// - since the preview stays on one card while several agents work, only the front card's app is streamed, and a
///   native card's thumbnail came only from that stream, so a card added in the background never got a picture;
/// - a card's busy flag cleared only on a `task_complete` that matched it, and a known task's `task_complete` matched
///   native cards only by the app it named (agents usually finish with just their task id);
/// - nothing dropped the card of an app that quit.
/// These rules keep the deck honest; `AppState` applies them.
public enum PreviewCardLifecycle {
    /// Inactivity limits for standalone actions and explicitly started tasks.
    public static let adHocIdleTimeoutSeconds: TimeInterval = 20
    public static let taskIdleTimeoutSeconds: TimeInterval = 60
    /// Drop a completed card if the normal completion cleanup never ran.
    public static let completedCardFailsafeSeconds: TimeInterval = 15
    /// Legacy name for the explicit task's inactivity limit.
    public static let quietSettleSeconds: TimeInterval = taskIdleTimeoutSeconds
    /// How often a background native card's still picture may be refreshed while its agent works.
    public static let stillRefreshSeconds: TimeInterval = 4
    /// How soon a card that has no picture yet may try again (its window may only just have opened).
    public static let stillRetrySeconds: TimeInterval = 1.5

    /// What the deck knows about one card.
    public struct Card: Equatable, Sendable {
        public var isBrowser: Bool
        public var isFront: Bool
        public var hasPreview: Bool
        public var isBusy: Bool
        public var isCompleted: Bool
        /// For a native card, whether its app is still running (always true for browser cards).
        public var appRunning: Bool
        /// The last agent activity, or the completion time for a completed card.
        public var lastActivity: Date
        public var hasExplicitTask: Bool = false
        public var isPinned: Bool = false

        public init(
            isBrowser: Bool,
            isFront: Bool = false,
            hasPreview: Bool = false,
            isBusy: Bool = false,
            isCompleted: Bool = false,
            appRunning: Bool = true,
            lastActivity: Date,
            hasExplicitTask: Bool = false,
            isPinned: Bool = false
        ) {
            self.isBrowser = isBrowser
            self.isFront = isFront
            self.hasPreview = hasPreview
            self.isBusy = isBusy
            self.isCompleted = isCompleted
            self.appRunning = appRunning
            self.lastActivity = lastActivity
            self.hasExplicitTask = hasExplicitTask
            self.isPinned = isPinned
        }
    }

    public enum Verdict: Equatable, Sendable {
        case keep
        /// Still worth showing, but nobody is working on it any more: clear the busy dot.
        case settle
        /// Nothing left to show: drop it.
        case remove
    }

    public static func idleTimeoutSeconds(hasExplicitTask: Bool) -> TimeInterval {
        hasExplicitTask ? taskIdleTimeoutSeconds : adHocIdleTimeoutSeconds
    }

    public static func isIdleTimedOut(lastAgentActivity: Date, hasExplicitTask: Bool, now: Date) -> Bool {
        now.timeIntervalSince(lastAgentActivity) >= idleTimeoutSeconds(hasExplicitTask: hasExplicitTask)
    }

    /// Expire idle cards even in front. User-pinned cards stay but lose their busy dot.
    /// Completed cards and cards whose native app has quit can be removed even when pinned.
    public static func sweep(_ card: Card, now: Date) -> Verdict {
        if !card.isBrowser && !card.appRunning { return .remove }

        let elapsed = now.timeIntervalSince(card.lastActivity)
        if card.isCompleted {
            return elapsed >= completedCardFailsafeSeconds ? .remove : .keep
        }

        let timeout = idleTimeoutSeconds(hasExplicitTask: card.hasExplicitTask)
        guard elapsed >= timeout else { return .keep }
        guard card.isPinned else { return .remove }
        return card.isBusy ? .settle : .keep
    }

    /// Whether a `task_complete` that names its task finishes a card (marks it done, so it leaves after the check).
    /// - A browser card is done when its tab belongs to the finished task (or is the tab the call named). A browser
    ///   placeholder (a `task_start` that never opened a tab) has nothing to show for any task, so it finishes too.
    /// - A native card is done when it is the app the call named, or, if none was named, an app the finished task used.
    ///   With no app ownership information, preserve the legacy behavior: finish native cards if no tabs were owned.
    public static func taskCompleteFinishes(
        isBrowser: Bool,
        browserTabId: Int?,
        appPid: Int32?,
        finishedTabIds: Set<Int>,
        finishedTabId: Int?,
        finishedAppPid: Int32?,
        finishedAppPids: Set<Int32>? = nil
    ) -> Bool {
        if isBrowser {
            guard let browserTabId else { return true }
            return finishedTabIds.contains(browserTabId) || browserTabId == finishedTabId
        }
        if let finishedAppPid {
            return appPid == finishedAppPid
        }
        if let finishedAppPids {
            return appPid.map { finishedAppPids.contains($0) } ?? false
        }
        return finishedTabIds.isEmpty
    }

    /// Whether to take a one-shot still of a native card's window. Only the front card's app is streamed, so a
    /// background card needs its own picture. Never for Chromium windows: they can show the user's own tabs.
    public static func wantsStill(
        isBrowser: Bool,
        isChromium: Bool,
        isFront: Bool,
        hasPreview: Bool,
        lastAttempt: Date?,
        now: Date
    ) -> Bool {
        guard !isBrowser, !isChromium else { return false }
        // The live stream keeps the front card's picture current.
        if isFront && hasPreview { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= (hasPreview ? stillRefreshSeconds : stillRetrySeconds)
    }

    /// Whether the stage keeps the front card's still when the live stream goes idle (its window could not be found
    /// or captured right now), instead of an empty spinner. Chromium windows never: they can show the user's tabs.
    public static func stageKeepsStill(frontIsBrowser: Bool, frontIsChromium: Bool, frontHasPreview: Bool) -> Bool {
        !frontIsBrowser && !frontIsChromium && frontHasPreview
    }
}
