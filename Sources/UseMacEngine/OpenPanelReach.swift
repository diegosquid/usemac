import Foundation

/// Which files a native open panel can reach while its app stays in the background.
///
/// On macOS 15 the open panel is hosted out of process (the open-and-save panel service) for sandboxed and regular
/// apps alike. Its accessibility tree shows up under the app's pid, but it takes no keyboard input while the app is
/// in the background: keys posted to the app's pid arrive, yet an inactive app has no key window, so ⌘⇧G (or typing
/// "/" or "~") never reaches the panel; keys posted to the panel service, or through AXUIElementPostKeyboardEvent,
/// change nothing; and no accessibility attribute or action opens Go to Folder. So in the background UseMac reaches a
/// file only by browsing the panel's folders or through its search, which is Spotlight. Go to Folder needs the app in
/// front, which is what a batch with `"foreground": true` gives it.
enum OpenPanelReach {
    /// Why the panel's search can never list `path` (absolute, symlinks resolved, as `uploadFile` normalizes it), or
    /// nil when it can or might. Spotlight skips the system's private folders, which hold /tmp and $TMPDIR, and
    /// anything inside a dot-folder, and indexing the file with `mdimport` does not change that. Resolving symlinks
    /// can drop the "/private" prefix again, so both spellings count.
    static func searchBlocker(for path: String) -> String? {
        if path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") {
            return "/tmp"
        }
        if path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") {
            return "a temporary folder ($TMPDIR)"
        }
        if path.hasPrefix("/private/") || path.hasPrefix("/var/") || path.hasPrefix("/etc/") {
            return "a system folder (/private)"
        }
        let components = (path as NSString).pathComponents
        if let hidden = components.dropFirst().dropLast().first(where: { $0.hasPrefix(".") }) {
            return "a hidden folder (\(hidden))"
        }
        if let name = components.last, name.hasPrefix(".") {
            return "a hidden file"
        }
        return nil
    }

    /// The answer when the panel cannot reach the file with the app in the background.
    static func backgroundMessage(fileName: String, reason: String, appName: String) -> String {
        "\(fileName) is in \(reason), which the file picker cannot reach while \(appName) is in the background: "
            + "browsing its folders did not get there, its search (Spotlight) never lists such files, and Go to Folder (⌘⇧G) "
            + "only takes keys with the app in front. Copy the file to a folder such as ~/Downloads and upload the copy, or "
            + "rerun this step in a batch with \"foreground\": true (UseMac types the path with ⌘⇧G and gives focus back)."
    }

    static func shouldRestoreFocusAfterBackgroundUpload(
        previousPid: Int32?,
        targetPid: Int32,
        targetBecameFrontmost: Bool,
        secondsSinceUserInput: Double,
        ownInputRecent: Bool
    ) -> Bool {
        guard let previousPid, previousPid != targetPid, targetBecameFrontmost else { return false }
        return secondsSinceUserInput >= ActionExecutor.userIdleRequiredSeconds || ownInputRecent
    }

    static func isGoToFolderFieldCandidate(
        role: String?,
        subrole: String?,
        inFileRow: Bool,
        isSearchField: Bool
    ) -> Bool {
        guard !inFileRow, !isSearchField, subrole != "AXSearchField" else { return false }
        return role == "AXComboBox" || role == "AXTextField"
    }

    static func shouldAttemptGoToFolderAfterSearchFailure(isFrontmost: Bool) -> Bool {
        isFrontmost
    }

    static func goToFolderFailureMessage(fileName: String, detectedField: Bool) -> String {
        if detectedField {
            return "Go to Folder appeared, but the file picker stayed open without confirming \(fileName)."
        }
        return "Could not detect the Go to Folder path field after ⌘⇧G, so UseMac stopped without confirming the picker. Copy \(fileName) to a folder such as ~/Downloads and upload the copy."
    }
}
