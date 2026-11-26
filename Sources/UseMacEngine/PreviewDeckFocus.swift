import Foundation

/// Decides which card the live preview shows large.
///
/// With several agents working at once, following each one's latest step made the preview jump between their
/// cards every second. So the front card only changes when the user picks another one, when it goes away, or when
/// it has nothing left to show: an empty placeholder, or a card whose task has finished. Activity on the other cards
/// updates their filmstrip thumbnails and nothing else.
public enum PreviewDeckFocus {
    /// What the deck knows about its front card.
    public struct Front: Equatable, Sendable {
        public var isBrowser: Bool
        public var browserTabId: Int?
        public var appPid: Int32?
        public var hasPreview: Bool
        public var isBusy: Bool
        public var isCompleted: Bool

        public init(
            isBrowser: Bool,
            browserTabId: Int? = nil,
            appPid: Int32? = nil,
            hasPreview: Bool = false,
            isBusy: Bool = false,
            isCompleted: Bool = false
        ) {
            self.isBrowser = isBrowser
            self.browserTabId = browserTabId
            self.appPid = appPid
            self.hasPreview = hasPreview
            self.isBusy = isBusy
            self.isCompleted = isCompleted
        }
    }

    /// Whether agent activity may bring another card to the front. True with no front card, with an empty browser
    /// placeholder (a `task_start` that named no tab yet), and with a front card whose task has finished.
    public static func frontYieldsToActivity(_ front: Front?) -> Bool {
        guard let front else { return true }
        if front.isBrowser && front.browserTabId == nil && !front.hasPreview {
            return true
        }
        return front.isCompleted && !front.isBusy
    }

    /// Whether the live preview reacts to an activity at all. Work on a guessed target (the request named no app, so
    /// UseMac fell back to the app in front, usually the user's own) is never shown: only UseMac tabs and apps an
    /// agent named are.
    public static func previewShows(targetGuessed: Bool) -> Bool {
        !targetGuessed
    }

    /// Whether an activity may add a card the deck does not have yet. A Chrome tab's card only comes from a real
    /// frame of that tab, never from a step: a step can name a tab that is closed or not UseMac's, and its card would
    /// stay empty. A browser activity that names no tab (a task that has not opened one yet) may add the placeholder.
    public static func activityAddsCard(isBrowser: Bool, namesTab: Bool, success: Bool) -> Bool {
        guard isBrowser else { return true }
        return !namesTab && success
    }

    /// True when an activity is another card's work, so it must not drive the large preview (its caption, cursor,
    /// click pulse or stream target). Activity that names neither a tab nor an app, and native work in a Chromium
    /// browser (which can be the front tab's own page), counts as the front card's.
    public static func isBackgroundActivity(front: Front?, tabId: Int?, appPid: Int32?, isChromiumApp: Bool) -> Bool {
        guard let front, !frontYieldsToActivity(front) else { return false }
        if let tabId {
            return front.browserTabId != tabId
        }
        guard let appPid, !isChromiumApp else { return false }
        return front.isBrowser || front.appPid != appPid
    }
}
