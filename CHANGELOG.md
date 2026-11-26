# Changelog

All notable changes to UseMac are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Versions below 1.0 may still change how agents talk to UseMac.

## [Unreleased]

### Added

- **Ask mode**: a new execution mode between Autonomous and Block sensitive. An upload, a ⌘/⌃ shortcut or a page
  script waits until you click **Allow once** or **Deny** in a prompt next to the live preview; nobody answering
  within 45 s denies it. For shortcuts and page scripts you can also allow the rest of the task. Agents get
  `APPROVAL_DENIED` or `APPROVAL_TIMEOUT` (CLI exit code 4).
- App and site rules in **Settings → General**: block apps (by bundle ID) and sites (by host) that agents may never
  see, control or capture, or allow only the ones you list. Password managers, Keychain Access and password-manager
  web vaults are blocked by default. Blocked apps and tabs are hidden from `list_apps` and `browser_tabs` and left
  out of the preview and display screenshots, and requests that would reach them fail with `TARGET_BLOCKED` (CLI
  exit code 4). The rules can only be changed in the app.
- Several agents can run at once without colliding. Any request can carry the `taskId` from `task_start` (top-level
  `taskId`, CLI `--task` or `USEMAC_TASK`, automatic over MCP). A task's browser requests without `tabId` go to its
  own last tab, and the windows and tabs it acts in are its own until it finishes: another task's action there
  fails with `TARGET_BUSY` (CLI exit code 6, wait and retry). Reads keep working, and callers that don't use tasks
  are never refused.
- The live preview names the agent on each card (`task_start` `agent`, CLI `usemac start --agent`; MCP clients show
  their own name). `task_complete` returns a `taskSummary` (requests, actions, blocked steps, tabs, duration), and
  `usemac done` prints it.
- The audit log is kept on disk and survives restarts: one JSON Lines file per day in `~/Library/Application
  Support/UseMac/audit/`, kept for 30 days by default (**Settings → General → History**). Each entry names its
  task. **Settings → History** filters by task, app and result and exports JSON Lines or CSV. `audit_log` takes
  `limit`, `sinceMs` and `taskId`, and `usemac audit` prints the log.
- While an agent works in a Chrome tab you're looking at, the tab shows a blue border and a pill: "UseMac is
  controlling this tab", the current step and a **Stop** button that stops the agent like Stop in the HUD. Agents
  never see them in observations, screenshots or vision results.
- **Settings → Chrome Extension** and the extension popup show each profile's extension version and where Chrome
  loads it from, flag an extension older than the app's copy or loaded from another folder, and **Reload** it with
  no trip to `chrome://extensions`. `browser_status` reports the same (`extensionSource`, `extensionOutdated`, …),
  and `browser_reload_extension` (CLI `usemac browser reload-extension`) reloads it and waits until it pairs again
  (new errors: `EXTENSION_RELOAD_UNSUPPORTED`, `EXTENSION_RELOAD_TIMEOUT`, `BROWSER_BUSY`).
- The setup guide offers **Add from Chrome Web Store** first once the app knows the store ID, with **Load it
  unpacked instead** as the fallback. `scripts/package-extension.sh` checks the manifest version against the app
  and keeps dev files out of the store zip.
- `scripts/smoke.sh`, a live smoke run to use before releases (see `docs/SMOKE.md`), and `scripts/bench.sh`, a
  reproducible benchmark for local IPC latency and snapshot vs. screenshot tokens.
- Continuous integration: every pull request and push to `main` runs the Swift and Chrome extension tests on an
  Apple Silicon runner.

### Changed

- The live preview's caption says which step failed and why, in plain words (for example "Couldn't click “Open”",
  "needs the app in front"), instead of "Batch failed", with a failure mark instead of a spinner.
- The CLI and the MCP server wait 75 s longer for `act`, `browser_act` and `browser_extract`, which can now wait
  for your answer in Ask mode, and `usemac act` waits up to 60 s for a step like MCP does.
- The agent guide, the skill and the README list every socket method and error code UseMac returns, and a test
  keeps them in sync with the code.
- Building from source: the CLI product is now `usemac-cli`, so it no longer overwrites the app on case-insensitive
  volumes. The app still installs it as `Contents/Helpers/usemac`.
- Website: the performance numbers are measured with `scripts/bench.sh` and linked to a README "Benchmarks"
  section, the unbacked "−97% vision tokens" and "0.5 s on-device MLX" claims are gone, and the hero demo shows a
  generic agent.
- Bridge protocol (still v2): `hello` carries an optional `extensionId`, `ready` may carry `extensionStatus`, and
  new `tab_control` / `stop_requested` messages drive the tab indicator.

### Fixed

- With several agents working at once, the preview no longer jumps between their cards every second. The card in
  front stays until you pick another one, it goes away or its task finishes. The others keep updating in the
  filmstrip, and their captions, cursor and clicks no longer show up on the card you are watching.
- A Chrome tab no longer changes size when you switch away from it while an agent works there. In the
  background it keeps the size it had on screen instead of jumping to 1280×800, so the page doesn't reflow and
  the agent's clicks land where it measured them.
- When several agents work at once, one finishing no longer closes the other's Chrome tabs. `task_start` returns a
  `taskId`; pass it to `browser_open` and `task_complete` (CLI `--task`) and only that task's tabs close and only its
  preview cards are marked done. A finished agent's card now leaves the filmstrip after its check even while others
  keep working, and the preview closes only when every task is done.
- Real mouse input and keys only go to the window UseMac works in. With the app in front but that window covered,
  `scroll` and `hover` run in the background, and coordinate clicks, `type` and `pressKey` fail with
  `TARGET_NOT_FRONTMOST` instead of landing in the window on top, which could be yours.
- Native `scroll` on a web page that ignores the wheel now scrolls it in real Chrome, `setValue` no longer brings a
  covered window forward or reports `effect: none` for a value Chrome took, and clicks on a tall element aim at its
  visible part.
- Chrome no longer ends up with several "UseMac" tab groups in one window when agents use tabs at the same time;
  existing duplicates are merged the next time UseMac uses a tab there.
- Finishing a task no longer closes a tab another task opened just before the cleanup, closed tabs are forgotten,
  and a `taskId` naming a finished task no longer finishes another one.
- The live preview no longer keeps grey placeholder cards with busy dots that never stop, and keeps the selected
  card's picture instead of only a spinner when its window can't be streamed.
- The live preview of a Chrome tab no longer freezes when its window is covered by other windows.
- A native file picker step for a file in `/tmp`, `$TMPDIR` or a hidden folder answers at once with
  `TARGET_NOT_FRONTMOST` and says how to get the file in, instead of searching for 12 s and failing with "element
  not found".
- Builds with a Chrome Web Store ID still accept the extension loaded unpacked from UseMac.app, and
  `usemac.bridge.allowedExtensionIds` lets them accept a copy loaded from another folder.
- Checking whether the local vision runtime is installed no longer scans every file of it.

### Security

- The live preview only shows UseMac's own Chrome tabs and apps an agent named. A screenshot, observe or action
  that names no app (so it falls back to the app in front, usually your own) no longer makes the preview show that
  app, and a failed step on a closed tab no longer leaves an empty card.
- Agents can no longer observe or act on UseMac's own windows, such as Settings. Requests that name UseMac
  return `SELF_TARGET_BLOCKED`, and `list_apps` no longer lists it.
- The audit log no longer copies what agents typed: typed text, `setValue` values, `eval` scripts and OCR results
  are kept only as their length unless you turn on **Record typed text**, and URLs lose their credentials and
  secret-looking query values.
- Only a physical click answers an Ask prompt: clicks posted by any process and Accessibility actions are ignored,
  UseMac refuses to send real input onto the prompt, and no socket method or MCP tool can answer it.

## [0.6.0-beta.2] - 2026-11-25

Fixes from the first days of the beta, mostly in Chrome and the live preview.

This beta is not notarized yet: the first time, open it with right-click > Open, or allow it in
System Settings > Privacy & Security ("Open Anyway"). If you installed 0.6.0-beta.1, it updates itself.

### Fixed

- A Chrome tab UseMac controls now keeps its real width and no longer flickers while you are looking at it.
- The Resume button in the HUD's "Stopped" pill no longer wraps onto two lines.
- The preview filmstrip no longer shows the same Chrome tab twice when an agent does not name the Chrome profile.
- Activity that names no app (for example after pressing Resume) no longer makes the preview show whatever app is in front, such as your own screen; native work in a window showing a UseMac tab uses that tab's card.
- The Chrome extension reports its real version to the app instead of a fixed "0.5.0".

## [0.6.0-beta.1] - 2026-11-25

A reliability pass on everything agents do in the background, and a new live preview.

This beta is not notarized yet: the first time, open it with right-click > Open, or allow it in
System Settings > Privacy & Security ("Open Anyway").

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
- **Beta updates.** A "Beta updates" switch in Settings > Software Updates (on by default in beta builds).
  Pre-releases are published in Sparkle's beta channel, so stable installs are never moved to a beta.
  Updates are now signed with an EdDSA key.

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

[Unreleased]: https://github.com/diegosquid/usemac/compare/v0.6.0-beta.2...HEAD
[0.6.0-beta.2]: https://github.com/diegosquid/usemac/compare/v0.6.0-beta.1...v0.6.0-beta.2
[0.6.0-beta.1]: https://github.com/diegosquid/usemac/compare/v0.5.0...v0.6.0-beta.1
[0.5.0]: https://github.com/diegosquid/usemac/releases/tag/v0.5.0
