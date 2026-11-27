# UseMac — Complete Reference

Full specification for all 29 methods (Unix socket NDJSON), all 9 MCP tools (plus legacy aliases), the `usemac` CLI, action steps, error codes, problem reporting, and debug capture.

---

## 1. Unix Socket NDJSON — All 29 Methods

Socket path: `{{USEMAC_SOCKET}}` (default `/tmp/usemac-$UID/usemac.sock`, override with `$USEMAC_SOCKET`). Same-user connections only; one UTF-8 JSON line per message; max request size 16 MiB (`message_too_large`). Connections support **concurrent pipelining** over one persistent socket (responses carry matching `id`). `id` is optional.

Booleans on `act` and `browser_act` default to `stopOnError: true`, `returnObservation: true`, `returnDiffOnly: false`, `includeScreenshot: false`. Any method accepts top-level `taskId`, piggybacked `taskStart`, and piggybacked `taskComplete`.

| Method | Description |
| :--- | :--- |
| `ping` | Health and round-trip check (`pong`). |
| `status` | Daemon status, execution mode, Kill Switch state, permissions, telemetry, and connected Chrome profiles. |
| `list_apps` | Running macOS GUI apps with PIDs, bundle IDs, and window metadata (omits UseMac and blocked apps). |
| `observe` | Native Accessibility tree (`@e1..@eN`, stable across observes; auto-fuses `@v1..@vN` Apple Vision OCR on AX-blind windows). Supports `app`, `window`, `useCache`, `includeDiff`, `includeOffscreen` (default `false`), `filter` (`role`, `text`, `selector`, `viewportOnly`), `maxDepth`, `maxElements`, `includeScreenshot`, `returnImageContent`. |
| `act` | Native UI batch (`steps` required). Supports `match`, `optional`, `assert`, `scrollUntil`, `fillForm`, `menuAction`, `drag`, `saveFile`, `scrollIntoView`, `axAction`, `waitFor`, `uploadFile`, `observationMode`, `returnDiffOnly`, `diffCrop`, `verify`, `expectWindowTitle`, `allowStaleSnapshot`, `foreground`, `foregroundFallback`, `waitForIdleMs`, `waitForLeaseMs`, `window`, `includeScreenshot`, `returnImageContent`. |
| `screenshot` | Downscaled JPEG of an app window or display (`maxDimension`, `quality`, `includeBase64`, `diffCrop`, `region`), saved in a private temp folder pruned after 30 minutes. |
| `set_policy` | Keep or tighten execution mode (`autonomous` → `ask` → `confirmSensitive` → `readOnly` → `paused`); relaxing returns `POLICY_LOCKED`. |
| `pair_app` | Set or clear the default target app (`appTarget`). |
| `audit_log` | Redacted audit entries, newest first (`limit` up to 1000, `sinceMs`, `taskId`; kept 30 days). Typed text and `eval` sources appear only as character length. |
| `highlight` | Highlight a cached `@eID` element on screen (`elementId`, `durationMs`). |
| `app_menu` | Search (`query`) or directly invoke (`menuPath`, e.g. `["File", "Export as PDF…"]`) native macOS app menu bar items via `kAXMenuBarAttribute` without stealing focus. |
| `browser_status` | Paired, connected Chrome profiles (`extensionOutdated`, `extensionSource`, `extensionNote`, `bundledExtensionVersion`) and daemon status. |
| `browser_tabs` | Open Chrome tabs (`tabId`, `title`, `url`, `active`, `restricted`, `usemac`), optional `profile` and substring `query` (omits blocked sites). |
| `browser_open` | Open a URL in a new background tab, navigate an existing `tabId`, activate a tab (`activate: true`), or open an unfocused window (`newWindow: true`). Supports `autoDismissOverlays: true`, inline `steps` (open + act in one turn), `dialogAction` (`"accept"`/`"dismiss"`), `dialogPromptText`, `waitForLeaseMs`, `returnDiffOnly`, and `observationMode`. Returns the settled snapshot directly. |
| `browser_observe` | Chrome DOM (`@b1..@bN` stable across observes via WeakMap; traverses OOPIFs, child iframes, and open Shadow DOM), viewport-first sorting, `offscreenCount`, `filter`, `maxElements`, `includeText`, `includeTables`, `includeScreenshot`, `returnImageContent`, `tablesSummary`, `webMcpTools`. |
| `browser_extract` | Extract structured data: `mode` = `"auto"`, `"tables"` (`scanHorizontal`, `scanVertical`), `"kpis"`, `"text"`, `"network"` (passive CDP XHR/Fetch ring buffer with `urlFilter`), `"downloads"` (recent Chrome profile downloads), or `"eval"` (`expression`, optional `frameIndex`; `autonomous` mode or `ask` once allowed). |
| `browser_screenshot` | JPEG of a Chrome tab, element (`elementId`/`selector`), `region`, `diffCrop: true`, or stitched `fullPage` (up to 16384 CSS px, 40 captures, 12 s; sets `truncated: true` if clipped). Never resizes the tab; `viewportWidth`/`viewportHeight` only cap output image dimensions. |
| `browser_act` | DOM action steps in a Chrome tab (`match`, `optional`, `assert`, `scrollUntil`, `fillForm`, `drag`, `waitFor` via `MutationObserver`, `uploadFile`, `dialogAction`, `dialogPromptText`, `waitForLeaseMs`, `readOnly`, `verify`, `observationMode`, `returnDiffOnly`, `diffCrop`, `returnImageContent`). Surfaces `dialogs`, `networkErrors` (4xx/5xx XHRs), `dirtyRect`, and `visualDeltaOCR`. |
| `browser_batch` | Open and `observe` or `extract` multiple `urls` in parallel Chrome background tabs (`mode`, `extractMode`, `maxElements`, `autoDismissOverlays`, `closeAfter`), enforcing site rules per URL. |
| `browser_reload_extension` | Reload the Chrome extension and wait up to 15 s for re-pairing (`profile`, `force`). Stops all active browser work in that profile — use only when asked. |
| `vision_status` | On-device Apple Vision OCR readiness (`backend: "apple-vision-ocr"`, `ocrAvailable: true`). Instant, zero setup. |
| `vision_query` | On-device Apple Vision OCR (`mode`: `"ocr"`, `"verify"`, `"locate"`, `"diagnose"`, `"ask"`, `"describe"`). Negation-safe `verify`. Accepts `app`, `tabId`, `profile`, `selector`, `elementId`, or `imagePath` (must be in user temp dir or `/tmp`). |
| `skill_save` | Persist (or delete with `delete: true`) a reusable, parameterized `{{param}}` macro (`name`, `description`, `target`, `app`, `urlPattern`, `params`, `steps`). |
| `skill_run` | Deterministically replay a saved skill (`name`, `params`, `app`, `profile`, `tabId`, `stopOnError`, `returnObservation`, `returnDiffOnly`, `observationMode`) through the full governed `act`/`browser_act` pipeline. |
| `skill_list` | List saved skills filtered by `query`, `target`, `app`, or `url`. |
| `task_start` | Start a tracked task session and hold the live preview open; returns `taskId` (`summary`, `agent`, `app`, `tabId`, `profile`). Can also be piggybacked via `taskStart` on any request. |
| `task_complete` | Finish a task, close its live preview cards, auto-close eligible tabs it opened (~2 s later unless `keepTabs`/`keepTabIds`), and return `taskSummary`. Can also be piggybacked via `taskComplete` on any request. |
| `report_prepare` | Prepare a redacted problem report for the user to review in UseMac before anything is sent (`summary`, optional `title`, `taskId`). |
| `debug_capture` | Developing UseMac only: read-only PNG capture of UseMac's own windows and surrounding context once Debug capture is enabled in Settings (`DEBUG_CAPTURE_OFF` otherwise). |

### Browser extract results

The socket wraps results under `browserExtract`. In that object, `auto` returns `text` and any `tablesMarkdown`; `tables` returns `tablesMarkdown` when tables are found plus row and column counts; `text` and `kpis` return `text`. Only `network` and `eval` return a string in `jsonResult`.

`downloads` returns the `browserExtract.downloads` array, or `"downloads":[]` when nothing matches. It queries Chrome downloads from the past 24 hours for the selected profile, not a tab or UseMac session. Use `profile` to select a Chrome profile when needed; do not combine this mode with `browser_batch` or MCP `urls`. UseMac filters items through `TargetRules` and sanitizes returned URLs (no credentials, query strings, or fragments).

Request (NDJSON):

```json
{"method":"browser_extract","browserExtract":{"mode":"downloads"}}
```

Example response (abridged):

```json
{"ok":true,"browserExtract":{"mode":"downloads","downloads":[{"id":938,"filename":"/Users/example/Downloads/app.js","url":"https://cdn.example/app.js","state":"complete","bytesReceived":1972462,"totalBytes":1972462,"mime":"text/javascript","startTime":"2026-11-27T01:02:18.023Z"}]}}
```

CLI JSON (`"$USEMAC" --json browser extract downloads`) returns the result object directly, so read `.downloads` at the root. MCP returns a formatted text list.

### Piggybacked Task Lifecycle & Multi-Agent Leases

- Pass `"taskStart": {"summary": "...", "agent": "..."}` on your first request to start a task without a separate RPC turn; pass `"taskComplete": {"taskId": "...", "summary": "..."}` on your final request to finish cleanly.
- Carry `taskId` at the top level of every intermediate request: tab-scoped browser calls without `tabId` route to your task's own last tab, `task_complete` closes only your task's tabs, and windows/tabs your task acts in are leased until completion (or 30 idle minutes). Another task's action on a leased target fails immediately with `TARGET_BUSY` unless `waitForLeaseMs` (`0`–`30000`, CLI `--wait-for-lease <ms>`) is set to wait in a FIFO queue; reads never block, and Kill Switch or Paused cancels any lease wait immediately with `POLICY_BLOCKED`.

### Ask Mode & Per-App / Per-Site Policies

Under `ask`, requests containing a sensitive step (`uploadFile`, `saveFile`, `axAction` `AXOpen` in a file panel, `pressKey` with `cmd`/`ctrl` in any spelling, or `browser_extract` `eval`) — and any mutating action on an app or site configured as **Ask** in **Settings → General → App and site rules** (even in `autonomous` mode) — wait up to 45 s (+10 s queued) for the user's physical click next to the HUD. Per-app and per-site rules follow **Block > Read-only > Ask > Allow** precedence: **Read-only** apps/sites allow `observe`, `screenshot`, `app_menu` search, read-only `browser_extract`, and non-mutating `scroll`/`hover`/`wait`/`assert`, while refusing mutations with `POLICY_BLOCKED`. Deny → `APPROVAL_DENIED`; timeout → `APPROVAL_TIMEOUT`; mode change/Kill Switch → `POLICY_BLOCKED`. Nothing runs unless allowed. Keep MCP client tool timeouts ≥ 120 s. Only physical clicks answer prompts — never try to click/script a prompt.

---

## 2. MCP Server (`stdio`) — All 9 MCP Tools

Register `{{USEMAC_BIN}}` with `"args": ["mcp"]`. Every tool carries `annotations` (`readOnlyHint`, `destructiveHint`) and never retries mutating actions on timeout. `usemac_observe`, `usemac_act`, and `usemac_screenshot` return inline `.image` blocks for both native apps and Chrome when `returnImageContent` is true (default `true` on `usemac_screenshot`).

| Tool | Purpose |
| :--- | :--- |
| `usemac_observe` | Observe native app (`app`/`window`) or Chrome tab (`tabId`/`profile`); supports `filter`, `includeOffscreen`, `maxElements`, `returnImageContent`, inline `task`. |
| `usemac_act` | Execute resilient action steps (`match`, `optional`, `assert`, `scrollUntil`, `fillForm`, `menuAction`, `waitFor`, `uploadFile`, …) on native app or Chrome tab; supports `verify`, `observationMode`, `returnDiffOnly`, `diffCrop`, `foregroundFallback`, `returnImageContent`, inline `task` / `completeTask`. |
| `usemac_browser_open` | Open or navigate a Chrome tab (`url`, `tabId`, `profile`, `activate`, `newWindow`) with optional `autoDismissOverlays`, inline `steps`, and inline `task`. |
| `usemac_browser_extract` | Extract Chrome data (`mode`: `auto`, `tables`, `text`, `kpis`, `network`, `downloads`, `eval`; `urlFilter`, `scanHorizontal`, `scanVertical`, `frameIndex`, `maxChars`) or parallel multi-tab `browser_batch` when `urls` is provided. |
| `usemac_screenshot` | Capture native window (`app`) or Chrome tab (`tabId`/`profile`) as an inline image; supports `maxDimension`, `diffCrop`, `region`, `elementId`, `selector`, `fullPage`. |
| `usemac_discover` | Unified read-only discovery: `kind` = `apps`, `tabs`, `menu`, or `status` (with `app`, `profile`, `query`). |
| `usemac_vision` | Instant on-device Apple Vision OCR: `mode` = `ocr`, `verify`, `locate`, `diagnose`, `ask`, `describe` (`query`, `app`/`tabId`/`imagePath`/`selector`/`elementId`). |
| `usemac_skill` | Manage & replay compiled macros: `action` = `list`, `save`, or `run` (`name`, `description`, `target`/`kind`, `app`, `urlPattern`, `params`, `steps`, `delete`). |
| `usemac_session` | Session utilities: `action` = `status`, `task_start`, `task_complete`, `highlight`, or `report_prepare` (`summary`, `agent`, `keepTabs`, `keepTabIds`, `elementId`, `durationMs`, `title`). |

**Legacy MCP tool aliases** (still accepted on `tools/call` for backwards compatibility): `usemac_status`, `usemac_list_apps`, `usemac_browser_tabs`, `usemac_browser_observe`, `usemac_browser_act`, `usemac_browser_screenshot`, `usemac_vision_status`, `usemac_vision_query`, `usemac_task_start`, `usemac_task_complete`, `usemac_highlight`, `usemac_report_prepare`.

---

## 3. CLI (`usemac`) Quick Reference

```bash
USEMAC="{{USEMAC_BIN}}"
"$USEMAC" observe --app "Notes" [--filter-role button] [--filter-text "new"] [--include-offscreen]
"$USEMAC" menu --app "Finder" --query "New"          # search or invoke native menu bar items
"$USEMAC" act '{"app":"Notes","observationMode":"auto","steps":[...]}' [--foreground-fallback] [--diff-crop]
"$USEMAC" browser open "https://example.com" [--auto-dismiss] [--new-window | --activate]
"$USEMAC" browser batch "https://a.example" "https://b.example" [--mode extract]
"$USEMAC" browser extract network --url-filter "/api/"
"$USEMAC" --json browser extract downloads
"$USEMAC" browser extract tables --scan-horizontal --scan-vertical
"$USEMAC" skill list | save | run <name>
"$USEMAC" vision verify "Success banner is visible" [--app "Notes" | --tab <id>]
"$USEMAC" audit --task <taskId> [--since 2h] [--limit 200]
"$USEMAC" report --task <taskId> --summary "<tried, expected, happened>"
"$USEMAC" debug capture --window preview [--context] [--frames 12 --interval 100] [--out <dir>]
```

Exit codes: `0` success; `1` command/RPC failure; `2` invalid usage/JSON; `3` `DAEMON_REQUIRED`; `4` safety block (`POLICY_BLOCKED`, `POLICY_LOCKED`, `APPROVAL_DENIED`, `APPROVAL_TIMEOUT`, `URL_BLOCKED`, `UPLOAD_BLOCKED`, `SELF_TARGET_BLOCKED`, `TARGET_BLOCKED`, `DEBUG_CAPTURE_OFF`); `5` screen changed (`STALE_SNAPSHOT`, `ELEMENT_NOT_FOUND`, `WAIT_TIMEOUT`); `6` focus/busy (`TARGET_NOT_FRONTMOST`, `USER_ACTIVE`, `TARGET_BUSY`); `7` switch route (`RESTRICTED_PAGE`, `CAPTURE_TOO_SMALL`).

---

## 4. Action Steps (`act` & `browser_act`)

| `action` | Key Parameters | Behavior |
| :--- | :--- | :--- |
| `target` | `app`, `preferBackground` | Locks target native app. |
| `navigate` / `openURL` | `url` | Navigates Chrome tab or opens URL (`http://`, `https://`, `about:blank` only; else `URL_BLOCKED`). |
| `click` / `doubleClick` / `rightClick` | `elementId` / `match` / `selector` / `x`, `y` | Background `AXPress` (`AXOpen` first for `doubleClick`) or CDP click; tracks navigations & downloads (`downloadPath`). |
| `hover` | `elementId` / `match` / `selector` / `x`, `y` | Reveals hover toolbars/tooltips (allowed in `readOnly`). |
| `setValue` | `elementId` / `match` / `selector`, `text` | Direct `AXValue` / React-safe input write, `<select>` matching, checkbox toggle. In Chrome, requires an explicit target (`INVALID_REQUEST` otherwise; use `type` for focused input). |
| `type` | `text`, optional `elementId` | Background Unicode typing. |
| `pressKey` | `key`, `modifiers` | Case-insensitive keys: `return` (`enter`), `tab`, `space`, `delete` (`backspace`), `forwarddelete`, `escape` (`esc`), `up`/`down`/`left`/`right` (`arrow*`), `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`, `a`–`z`, `0`–`9`, `-` `=` `[` `]` `;` `'` `,` `.` `/` `\` `` ` ``. Native keys use US positions; `delete` is backspace natively vs forward-delete in Chrome (prefer `backspace`/`forwarddelete`). Modifiers: `cmd`/`command`/`meta`, `ctrl`/`control`, `alt`/`opt`/`option`, `shift`. Any ⌘/⌃ shortcut is sensitive. |
| `scroll` | `deltaY`, `deltaX`, optional `elementId`/`selector` | Vertical & horizontal scroll (allowed in `readOnly`). |
| `focus` | `elementId` / `app` | Focuses element. |
| `wait` | `durationMs`, optional `selector` / `text` | Fixed pause or wait for selector/text (allowed in `readOnly`). |
| `uploadFile` | `files` (`["/abs/path"]`), optional `elementId`/`selector` | Chrome: CDP `DOM.setFileInputFiles` → file chooser intercept → drag-drop (zero Finder). Native open panel: Spotlight search + `AXOpen` (for `/tmp`, `$TMPDIR`, or hidden dirs, copy to `~/Downloads` or pass `foreground: true`). Sensitive under `ask`/`confirmSensitive`/`readOnly`. |
| `saveFile` | `files` (`["/abs/dest"]`), `overwrite` (default `false`) | Native `NSSavePanel` only (`INVALID_REQUEST` in Chrome). Validates non-sensitive destination (`UPLOAD_BLOCKED` on protected paths/extensions or existing destination when `overwrite` is false). Sensitive under `ask`/`confirmSensitive`/`readOnly`. |
| `drag` | Source (`elementId` / `match` / `selector` / `x`, `y`) + destination (`toElementId` / `toMatch` / `toSelector` / `toX`, `toY`), `durationMs` | Chrome: HTML5 `DragEvent` + `DataTransfer` sequence with CDP pointer fallback and preview cursor animation. Native: `CGEvent` drag checking both source and destination windows (`foregroundFallback` supported). |
| `scrollIntoView` | `elementId` / `match` | Native background `AXScrollToVisible`. |
| `axAction` | `elementId` / `match`, `actionName` | Native named AX action (`AXOpen`, `AXShowMenu`, `AXIncrement`, …). |
| `waitFor` | `match` / `elementId` / `selector` / `text`, `timeoutMs` (default 5000, max 30000), `gone` | Event-driven wait (`AXObserver` natively, `MutationObserver` in Chrome) until present or `gone: true`; fails with `WAIT_TIMEOUT`. |
| `assert` | `expectText`, `expectNotText`, `expectUrl`, `expectTitle`, `match`, `gone` | `<1 ms` deterministic post-check; fails with `ASSERTION_FAILED`. |
| `scrollUntil` | `match` / `selector` / `expectText`, `maxScrolls` (default 8) | Bounded local scroll loop until target becomes visible. |
| `fillForm` | `fields` (`[{elementId, selector, match, label, value, checked}]`), `submitMatch`, `submitSelector` | Fills inputs, selects, checkboxes, and ARIA comboboxes, surfaces validation alerts, and optionally submits (`FORM_FILL_FAILED` on field/validation failure). |
| `menuAction` | `menuPath` (`["File", "Save"]`) | Native background menu bar invocation via `kAXMenuBarAttribute` (zero focus steal). |

Any step accepts `"optional": true` (failure/not-found records `{success: true, skipped: true}` and continues). Every step returns `effect` (`changed` / `none` / `unverified`), `warning`, `errorCode`, and `resolvedElementId`.

`browser_act` rechecks click target geometry after reflow and reports the click's `effect`. A `warning` flags a click that didn't reach the page or a link click with no observable effect. UseMac doesn't automatically retry the click; observe the result before deciding what to do.

For native `uploadFile`, UseMac restores the previous focus if opening the file during a background upload activates the target app. The foreground `⌘⇧G` (Go to Folder) fallback waits for the path field and Open button.

`actionResult.stepResults[i].downloadPath` is an absolute local path. It appears only if a download correlated with the step's tab and action completes during the same `browser_act` (for example, a `click` followed by a `wait`). If it is absent for an asynchronous download, query `browser_extract` in `downloads` mode instead of clicking again.

In Chrome, `browser_open` and `browser_act` intercept JavaScript dialogs (`alert`, `confirm`, `prompt`, `beforeunload`) via CDP `Page.javascriptDialogOpening` so tabs never hang. By default (fail-closed), `alert` and `beforeunload` are accepted while `confirm` and `prompt` are dismissed with an `AgentFeedback` warning. Pass `dialogAction: "accept" | "dismiss"` and optional `dialogPromptText` (CLI `--dialog-action <accept|dismiss>` / `--dialog-prompt <text>`) to answer explicitly; handled dialogs are recorded in `actionResult.dialogs` and `snapshot.pageState.lastDialog`.

### Chrome Rules & Hybrid Restricted Flow

- **Pairing**: copy `umk_…` from **UseMac → Settings → General → Chrome Extension** into the extension popup once per profile (`EXTENSION_NOT_PAIRED` until paired; key is never exposed over IPC).
- **Extension source**: In `browser_status`, `extensionSource: "other_folder"` means Chrome loaded an unpacked copy outside the app bundle, even if `extensionOutdated: false` and the versions match. Reloading the existing copy only reads that folder again. To receive bundled updates, load the extension from `/Applications/UseMac.app/Contents/Resources/chrome-extension` in `chrome://extensions`.
- **Tab size**: UseMac never resizes tabs. `browser_screenshot` scales captures to fit `viewportWidth`/`viewportHeight` while keeping aspect ratio (`deviceScaleFactor` is ignored).
- **Hybrid flow (`RESTRICTED_PAGE`)**: for the Chrome Web Store or `chrome://`, open with `browser_open` `newWindow: true` or activate an existing tab (`tabId` + `url: ""` + `activate: true`). Keep the window visible on screen and use native `observe` / `act` with `app: "Google Chrome"` and `window: "<title substring>"`. If `observe` only shows the toolbar or `setValue` returns `effect: none`, use native `act` with `foreground: true` (CLI `--foreground`) to briefly focus the pinned window, act, and restore prior focus. Return to `browser_*` on normal pages.
- **Site rules**: `TargetRules` apply to native `observe`, `act`, `screenshot`, and `app_menu` in Chromium windows. With site rules active, the request is blocked if UseMac can't confirm the target site.
- **Active work indicators**: UseMac's native overlay marks visible Chromium windows on restricted pages. In a tab the agent controls, the user's typing or clicking pauses the agent there and changes the tab indicator to **You're using this tab, agent paused · Resume**. Only the user should resume it.

---

## 5. Error Codes

| Code | Meaning | Agent Recovery |
| :--- | :--- | :--- |
| `POLICY_BLOCKED` | Blocked by execution mode (`confirmSensitive`, `readOnly`, `paused`), Kill Switch (`⇧⌘⎋`), or your own `browser_act` `readOnly: true`. `hint` names which. | Stop and tell the user; only they change **Settings → Safety** (or **Resume Agents**). Do not retry or route around. |
| `POLICY_LOCKED` | `set_policy` attempted to relax execution mode. | Stop and tell the user; only the app UI can relax mode. |
| `APPROVAL_DENIED` | Ask mode: user denied sensitive step. Nothing ran. | Stop and tell the user; retry only if requested. |
| `APPROVAL_TIMEOUT` | Ask mode: prompt timed out (45 s). Nothing ran. | Tell the user what needs approval; retry once confirmed. |
| `URL_BLOCKED` | URL scheme is not `http://`, `https://`, or `about:blank`. | Stop and tell the user; never use an alternate route. |
| `UPLOAD_BLOCKED` | File is in a protected directory or matches blocked secrets/keys (`~/.ssh`, `~/.aws`, `~/.gnupg`, Keychains, `.env`, browser/password-manager data, shell history, `.pem`/`.pfx`/`.p8`/`.kdbx`/`.ovpn`/`.jks`/`.keystore`/`.tfstate`). | Stop and tell the user; never copy or bypass. |
| `SELF_TARGET_BLOCKED` | Request targeted UseMac itself or real input would land on a UseMac window. | Stop and tell the user; never drive UseMac's UI. |
| `TARGET_BLOCKED` | Blocked by user's App & Site rules (default: password managers & vaults), or tab site could not be confirmed while site rules are active. | Retry once if message says tab site couldn't be confirmed; otherwise stop and tell the user (**Settings → General → App and site rules**). |
| `DEBUG_CAPTURE_OFF` | `debug_capture` requested while Debug capture is off. | Stop and ask the user to turn it on in **Settings → Developer**. |
| `DAEMON_REQUIRED` | `UseMac.app` is closed so actions are disabled. | Ask the user to open `UseMac.app`; never bypass with `--standalone`. |
| `REPORT_IN_REVIEW` | Another problem report review window is already open. | Inform the user; wait until they close it. |
| `STALE_SNAPSHOT` | Target window changed (`windowId` or `expectWindowTitle` mismatch) or cached element is gone. Nothing ran. | Re-observe or use `match`. |
| `ELEMENT_NOT_FOUND` | No element matched `match` or `elementId` is gone. | Re-observe (adjust `filter`/`maxDepth`/`maxElements` or scroll), loosen `match`, or check `index`. |
| `WAIT_TIMEOUT` | `waitFor` / `scrollUntil` exceeded timeout. | Observe current state before retrying. |
| `ASSERTION_FAILED` | `assert` step expectation did not match (`expectText`, `expectNotText`, `expectUrl`, `expectTitle`, `match`, `gone`). | Read failure detail and re-observe before deciding next step. |
| `FORM_FILL_FAILED` | `fillForm` could not set a field or triggered form validation errors. | Inspect reported field/validation message and correct values. |
| `MENU_NOT_FOUND` | Native `app_menu` / `menuAction` path was not found or is disabled. | Search available paths with `app_menu` (`query`) first. |
| `SKILL_NOT_FOUND` | `skill_run` named a skill that does not exist in `SkillStore`. | Check available skills with `skill_list`. |
| `TARGET_NOT_FRONTMOST` | Step required real input while app/window wasn't frontmost or was covered. Nothing sent. | Use a background AX step (`setValue`, `axAction`, `menuAction`), or rerun with `foreground: true` / `foregroundFallback: true`. |
| `USER_ACTIVE` | Foreground burst refused because user interacted within 1.5 s (or after `waitForIdleMs`). | Wait and retry later; never force focus. |
| `TARGET_BUSY` | Another running task leased this window or tab. Nothing ran. | Wait and retry later, or open your own tab/window; reads still work. |
| `RESTRICTED_PAGE` | Chrome extension cannot script this page (`chrome://`, Web Store). | Switch to hybrid native Chrome flow above. |
| `CAPTURE_TOO_SMALL` | Captured window is too small to trust (helper strip/hidden). | Do not rely on image; observe or target the main window. |
| `EXTENSION_NOT_CONNECTED` | No paired Chrome extension connected (or `profile` mismatch). | Check `browser_status` or ask user to open Chrome. |
| `EXTENSION_NOT_PAIRED` | Extension connected but unpaired. | Ask user to copy `umk_…` key from **Settings → Chrome Extension** into popup. |
| `EXTENSION_TIMEOUT` | Extension timed out; running batch cancelled. | Call `browser_status` or `browser_observe` before retrying. |
| `EXTENSION_RELOAD_UNSUPPORTED` | Extension predates remote reload. | Ask user to reload once in `chrome://extensions`. |
| `EXTENSION_RELOAD_TIMEOUT` | Extension reloaded but didn't re-pair within 15 s. | Ask user to inspect `chrome://extensions` for errors. |
| `BROWSER_BUSY` | `browser_reload_extension` refused while commands run in profile. | Wait; pass `force: true` only if user asked. |
| `NO_USEMAC_TAB` | No `tabId` provided and no task/UseMac tab available (or task's last tab closed before action). | Call `browser_open` or pick a `tabId` from `browser_tabs`. |
| `CANCELLED` | Chrome batch cancelled (Kill Switch or timeout). | Stop, check `status`, and inform the user. |
| `APP_NOT_FOUND` | No running app matches `app`. | Check `list_apps` or launch silently with `open -g -a "<App>"`. |
| `PERMISSION_DENIED` | Screen Recording permission not granted. | Ask user to allow it in **Settings → General → Permissions**. |
| `CAPTURE_FAILED` | Screenshot capture failed (or no requested window visible for `debug_capture`). | Retry once; fall back to `observe`. |
| `UPLOAD_FAILED` | Native `uploadFile` found file but couldn't confirm open panel. | Rerun step with `foreground: true`. |
| `IMAGE_PATH_BLOCKED` | `vision_query.imagePath` outside user temp dir and `/tmp`. | Save inside temp dir or pass `app`/`tabId`. |
| `NO_IMAGE_SOURCE` | `vision_query` had no `imagePath`, screenshot, or browser frame. | Pass `imagePath`, `app`, or `tabId`. |
| `EVAL_ERROR` | `browser_extract` `eval` expression threw in page. | Fix expression using returned error message. |
| `WINDOW_ERROR` | Chrome failed to create window for `newWindow`. | Retry once or open background tab without `newWindow`. |
| `USAGE`, `INVALID_JSON`, `INVALID_REQUEST`, `INVALID_ARGUMENT`, `UNKNOWN_COMMAND`, `NOT_IMPLEMENTED` | Malformed request, bad flag/key, or command unknown to an older extension/build. | Fix request from message (`usemac help <cmd>`). On `UNKNOWN_COMMAND`, tell user extension may be outdated. |
| `INTERNAL`, `ENCODING_FAILED`, `EXTENSION_ERROR`, `BROWSER_TABS_FAILED`, `BROWSER_OPEN_FAILED`, `BROWSER_OBSERVE_FAILED`, `BROWSER_EXTRACT_FAILED`, `BROWSER_SCREENSHOT_FAILED`, `BROWSER_ACT_FAILED`, `BROWSER_BATCH_FAILED`, `APP_MENU_FAILED`, `SKILL_SAVE_FAILED`, `SKILL_RUN_FAILED` | Unexpected engine/extension failure. | Read message, check `status` / `browser_status`, retry at most once. |

---

## 6. Reporting a Problem (`report_prepare`)

Only when a failure looks like a UseMac bug (e.g. `INTERNAL`, visible element repeatedly returning `ELEMENT_NOT_FOUND`, unresponsive extension, step reporting `ok` with no effect) — **never** for safety blocks or user choices:

1. Ask the user in one sentence if they want to send a GitHub issue report. Proceed only if they agree.
2. Call `report_prepare` (MCP `usemac_session` `action: "report_prepare"` or legacy `usemac_report_prepare`; CLI `usemac report --task <id> --summary "..."`) with a concise `summary` (tried, expected, happened, error codes; no personal data) and `taskId`.
3. Tell the user to review UseMac's **"Review problem report"** window (UseMac auto-redacts typed text, tokens, emails, home paths, query strings, long numbers, IPs, window titles, and user/computer names; screenshots are never included).
4. Response returns `problemReport.status: "awaiting_user_review"`. Never read, click, or paste the report yourself (`SELF_TARGET_BLOCKED`). One report at a time (`REPORT_IN_REVIEW`). Works in every mode except Kill Switch (`POLICY_BLOCKED`) or closed app (`DAEMON_REQUIRED`).

---

## 7. Debug Capture (`debug_capture` — Developing UseMac Only)

Strictly for developing UseMac itself (inspecting live preview, Settings, setup guide, or Ask prompt). Off by default; only the user can enable it in **UseMac → Settings → Developer** (`DEBUG_CAPTURE_OFF`, CLI exit 4 while off).

```json
{"method":"debug_capture","debugCapture":{"window":"preview","frames":12,"intervalMs":100,"context":true}}
```

- `window`: `preview`, `prompt`, `settings`, `setup`, `report`, `other`, `all` (default), or `context` (comma-separated).
- `context: true`: screen around live preview (`contextMargin` default 48 pt; blocked apps omitted).
- Burst caps: up to 40 `frames`, `intervalMs` 100–1000 (default 250).
- Read-only PNGs with `path`, `kind`, `title`, `windowId`, `frame`; `observe`/`act`/`screenshot` still refuse UseMac windows (`SELF_TARGET_BLOCKED`). No matching window on screen → `CAPTURE_FAILED`.
