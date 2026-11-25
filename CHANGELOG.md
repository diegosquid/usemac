# Changelog

All notable changes to UseMac are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Versions below 1.0 may still change how agents talk to UseMac.

## [0.6.0-beta.1] - 2026-11-25

A reliability pass on everything agents do in the background, and a new live preview.

### Added

- **Semantic targets.** Steps can name an element by what it is (`match`: role, title, value or text)
  instead of an id from an earlier observe. `usemac find` shows what a match would hit.
- **New steps:** `scrollIntoView`, `axAction` (any accessibility action, such as `AXOpen`) and `waitFor`
  (until an element appears or goes away).
- **Effect reporting.** Each step says whether anything changed (`effect`), with a warning when it did not,
  instead of a silent "ok".
- **Foreground bursts** (`"foreground": true`): when real keyboard or mouse input is unavoidable, UseMac brings
  the app forward, runs the steps and gives the screen back. It refuses while you are typing (`USER_ACTIVE`).
- **Window targeting** (`window`): observe and act in a window that is not focused, such as a Chrome window
  UseMac opened in the background.
- **Chrome restricted pages.** Pages Chrome does not let extensions script (Chrome Web Store, `chrome://`)
  answer `RESTRICTED_PAGE` right away, with a hybrid flow that switches to native accessibility.
  `browser_open` gains `activate` and `newWindow`.
- **Tab cleanup.** About two seconds after `task_complete`, UseMac closes the Chrome tabs it opened. It never
  closes your own tabs, the tab you are looking at, or tabs with a running download; agents can keep tabs with
  `keepTabIds` or `keepTabs`.
- **Filmstrip preview.** With several tabs or apps, the preview shows the active one large and live thumbnails
  of the others, and makes it clear when another one comes to the front.
- Per-command help in the CLI (`usemac help <command>`), new error codes with exit codes, and the new fields in
  the MCP tools and agent guides.

### Changed

- **Element ids are stable** across observes, and elements scrolled out of view are listed as `(offscreen)` and
  scrolled into view before UseMac acts on them.
- **Background scrolling** moves native scroll views through their scroll bars and pages web content by
  scrolling the next offscreen element into view, with no events and no focus change.
- **File pickers** are driven without focus: UseMac browses to the file or searches for it, selects it and
  presses Open.
- The live preview and screenshots follow the exact window being worked on (by window id) and stay on it.
- The preview's element highlight is drawn on screen only where the target window is actually visible;
  otherwise it appears inside the preview.

### Fixed

- The preview could show another window of the same app (for example a different Chrome window), flicker
  between windows and resize unexpectedly.
- Screenshots and local vision could use a tiny helper window and answer confidently from it; they now refuse
  (`CAPTURE_TOO_SMALL`).
- Steps reported success when nothing happened (background scrolls, clicks posted to an inactive app).
- A tab that only lost its live stream disappeared from the preview, and a tab brought forward after reading it
  showed a stale, half-loaded frame.

### Security and privacy

- Real keyboard and mouse input is only sent when the target app is in front (`TARGET_NOT_FRONTMOST`), so it can
  never land in the app you are using.
- A batch refuses to run when the window changed since the last observe (`STALE_SNAPSHOT`), instead of acting on
  the wrong page.
- The preview never shows your own Chrome tabs: native work on a tab that is not UseMac's does not open the
  preview, and Chrome windows only appear when they show a UseMac tab.

## [0.5.0] - 2026-11-25

First public release.

### Added

- UseMac app for macOS 15+ on Apple Silicon with a background control daemon, the `usemac` CLI and an MCP server.
- Native accessibility control of Mac apps without stealing focus, and the UseMac Browser Bridge extension for
  Chrome with a paired, local-only connection.
- Execution modes (autonomous, block sensitive, read only, paused), the ⇧⌘⎋ kill switch and an audit log.
- Live preview HUD, on-device vision (Apple Vision OCR and a local MLX model) and a first-run setup guide.
- Sparkle 2 updates and a drag-to-Applications DMG.

[0.6.0-beta.1]: https://github.com/diegosquid/usemac/compare/v0.5.0...v0.6.0-beta.1
[0.5.0]: https://github.com/diegosquid/usemac/releases/tag/v0.5.0
