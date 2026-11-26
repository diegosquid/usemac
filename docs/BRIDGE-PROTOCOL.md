# UseMac Browser Bridge protocol (v2)

Contract between the Chrome extension (`Extension/`) and the daemon bridge
(`Sources/UseMacEngine/ChromeExtensionBridge.swift`). Both sides must implement it exactly.

## Transport

- WebSocket, text frames, one JSON object per frame.
- The extension is the client and connects to `ws://127.0.0.1:49222/usemac-bridge`.
- The daemon binds `127.0.0.1` only and accepts the WebSocket upgrade only when the `Origin` header starts with
  `chrome-extension://`. Authentication below, not the port, is what proves each side to the other.
- Builds that know the Chrome Web Store ID (Info.plist `UseMacChromeExtensionID`, or `USEMAC_CHROME_EXTENSION_ID`)
  also check the ID in that `Origin`. They accept the store ID, the ID Chrome gives the app's own
  `UseMac.app/Contents/Resources/chrome-extension` folder when it is loaded unpacked, the comma-separated IDs in
  `USEMAC_ALLOWED_EXTENSION_IDS`, and the IDs in the app's `usemac.bridge.allowedExtensionIds` default (an array,
  set only by the user with `defaults write app.usemac`). Any other extension, such as a copy loaded unpacked from
  a repo checkout, is refused at the upgrade, and its popup shows the app as not running. Builds without a store ID
  accept any extension ID unless `USEMAC_ALLOWED_EXTENSION_IDS` is set; the default only adds IDs and never turns
  the check on. Everything after the upgrade, pairing included, is the same for a store install and an unpacked
  one. Each install keeps its own copy of the pairing key, so a new install needs the key pasted once.

## Pairing key

- One key per Mac user, created by the daemon on first start: 32 random bytes.
- Text form shown to the user and pasted into the extension popup: `umk_` followed by 64 lowercase hex characters
  (68 characters in total). Input is trimmed and compared case-insensitively; anything else is rejected.
- The HMAC key `K` is the 32 decoded bytes (never the text form).
- Daemon storage: `~/Library/Application Support/UseMac/bridge-key`, file mode `0600`, directory mode `0700`,
  content is the text form followed by a newline.
- Extension storage: `chrome.storage.local`, item `bridgeKey`, value is the text form.

## Handshake

All nonces are 32 random bytes written as 64 lowercase hex characters. All proofs are HMAC-SHA256 outputs written
as 64 lowercase hex characters. Proofs are compared in constant time. `|` below is the literal ASCII character.

1. Extension → daemon, first frame after the socket opens:

   ```json
   {"type":"hello","protocol":2,"extensionVersion":"0.5.0","profileName":"Work","clientNonce":"<64 hex>","hasKey":true}
   ```

   `hello` carries no e-mail, no window titles and no tab count. A `hello` whose `protocol` is not `2`, or whose
   `clientNonce` is not 64 hex characters, gets `{"type":"auth_failed","reason":"bad_hello"}` and the socket is closed.

2. If `hasKey` is `false`, the daemon answers `{"type":"pairing_required"}` and keeps the socket open and
   unauthenticated. The extension may send a new `hello` on the same socket once the user has pasted a key.

3. If `hasKey` is `true`, the daemon answers:

   ```json
   {"type":"challenge","serverNonce":"<64 hex>","serverProof":"<64 hex>"}
   ```

   `serverProof = HMAC-SHA256(K, utf8("usemac-bridge-v2|server|" + clientNonce + "|" + serverNonce))`

   The extension verifies `serverProof`. On mismatch it closes the socket, enters the state `key_mismatch`, sends
   nothing else, and retries no more often than every 30 seconds. This covers both a wrong key and a process
   pretending to be the daemon.

4. Extension → daemon:

   ```json
   {"type":"auth","clientProof":"<64 hex>"}
   ```

   `clientProof = HMAC-SHA256(K, utf8("usemac-bridge-v2|client|" + clientNonce + "|" + serverNonce))`

   The daemon verifies it. On success it answers `{"type":"ready"}`. On failure it answers
   `{"type":"auth_failed","reason":"bad_proof"}` and closes the socket. Each `challenge` is valid for one `auth`.

5. After `ready`, the extension sends `{"type":"profile_info","profileName":"Work","tabCount":12}` and repeats it
   whenever the profile name changes.

### Rules before `ready`

- The extension ignores every `request` and `cancel` frame.
- The daemon never sends `request` or `cancel`, and drops `response`, `frame`, `cursor`, `stream_stopped` and
  `profile_info` frames. An unauthenticated session is never listed as a connected profile for agents.
- `ping` / `pong` frames are allowed in any state.

### Test vector

```
K            = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
key text     = umk_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
clientNonce  = aa repeated 32 times (64 characters)
serverNonce  = bb repeated 32 times (64 characters)
serverProof  = 0dc1c8449ec46032d911453f6e6668ee5474655b9f6b9d6de080377afc9f794a
clientProof  = c98c470a7e7cf4f566d842b2a2fcdd46e9894e13bcfe448ad0c180cb17fa4f35
```

## Commands after `ready`

Daemon → extension requests keep the existing shape: `{"type":"request","id":"<uuid>","command":"…", …}` with
`command` one of `tabs`, `open`, `observe`, `extract`, `screenshot`, `act`, `focus_tab`, `stop_stream`.
Extension → daemon frames keep the existing shapes: `response`, `frame`, `cursor`, `stream_stopped`, `ping`.

### `cancel` (new, daemon → extension)

```json
{"type":"cancel","tabId":123}
```

`tabId` is a number, or `null` for every tab. `cancel` has no `id`, gets no `response`, and is handled immediately,
outside the per-tab command queues:

- A running `act` batch on the affected tab stops before its next step and inside any `wait` step. Steps that did
  not run are reported with `success: false` and the message `Cancelled by UseMac`. The batch answers with
  `ok: false` and `error: {"code":"CANCELLED","message":"Cancelled by UseMac"}`.
- Commands still queued for the affected tab answer with the same error without running.
- The extension detaches the debugger from the affected tab (or from every tab) and emits `stream_stopped`.

## URL rule

`open`, and the `openURL` / `navigate` steps of `act`, accept only `http:` and `https:` URLs and the exact string
`about:blank`. Anything else answers `error: {"code":"URL_BLOCKED","message":"Only http(s) URLs can be opened."}`.
The daemon applies the same rule before sending; the extension applies it again. The one exception is the empty
`url` of an activate-only `open` (below), which navigates nowhere.

## `open`

```json
{"type":"request","id":"<uuid>","command":"open","url":"https://example.com/","tabId":123,"newTab":false,"stream":true,"activate":true,"newWindow":false}
```

| Field | Meaning |
| --- | --- |
| `url` | Page to load. Must pass the URL rule, except `""` for activate-only. |
| `tabId` | Navigate this existing tab with `chrome.tabs.update` (no debugger needed). |
| `newTab` | Without `tabId`: `true` (default) opens a background tab in the focused window; `false` reuses the last UseMac tab. |
| `stream` | Start the live preview after loading (default `true`). Skipped on restricted pages. |
| `activate` | Optional. Make the tab the active tab of its window with `chrome.tabs.update({active: true})`. Never focuses or raises the Chrome window. |
| `newWindow` | Optional. Open `url` in a new Chrome window created with `chrome.windows.create({url, focused: false})`. Cannot be combined with `tabId`. |

The daemon omits `activate` and `newWindow` when they are not set.

- **Activate only**: `tabId` + `url: ""` + `activate: true` only switches the tab. No navigation, no debugger, no
  streaming, and the tab is not moved into the UseMac group (it is usually the user's own tab). The response has
  `snapshot: null`, or the restricted-page snapshot below. `url: ""` without `activate` (or with `newWindow`) answers
  `INVALID_ARGUMENT`.
- **New window**: the window's single tab joins a `UseMac` tab group in that window and becomes the tab that later
  commands without `tabId` use, exactly like a tab opened by `open` today. Use it to give native Accessibility
  (`observe`/`act` with app "Google Chrome", which only see the active tab of each window) a place to work without
  switching the user's tabs.
- Every `open` response also carries `windowId` (the tab's Chrome window). Daemon-side decoding ignores it today.

## Restricted pages

Chrome does not let extensions attach the debugger (or run any script) on some pages. The extension detects them
before attaching, so commands fail fast instead of waiting for `EXTENSION_TIMEOUT`:

- every scheme other than `http:`, `https:`, `data:`, `blob:`, `filesystem:` and `chrome-error:` — `chrome://`,
  `chrome-extension://`, `chrome-untrusted://`, `chrome-search://`, `devtools://`, `view-source:`, `edge://`,
  `brave://`, `opera://`, …; `about:` pages other than `about:blank` / `about:srcdoc`;
- extension stores: the whole `chrome.google.com` host (Chrome treats it as the legacy Web Store origin, which covers
  `/webstore/devconsole`), `chromewebstore.google.com`, and in Edge / Opera their own stores
  (`microsoftedge.microsoft.com`, `addons.opera.com`);
- `file://` pages when "Allow access to file URLs" is off for the extension
  (`chrome.extension.isAllowedFileSchemeAccess()`).

A tab that is navigating is judged by its `pendingUrl`. If an attach still fails, Chrome's refusal messages
("… cannot be scripted", "Cannot access a chrome:// URL", "Cannot attach to this target", "Cannot access contents of
…") are mapped the same way, including policy-blocked hosts.

Behavior on a restricted tab:

- `observe`, `extract` (all modes except `downloads`), `screenshot` and `act` answer
  `ok: false` and `error.code: "RESTRICTED_PAGE"` without attaching the debugger or moving the tab into the UseMac
  group. The message names the page and tells the agent what to do: make the tab active with
  `browser_open {"tabId":N,"url":"","activate":true}` (or, for http(s) pages, open the URL in a UseMac window with
  `newWindow: true`), then use native `observe`/`act` with app "Google Chrome" (or the browser it runs in); call
  `browser_open` with the tabId and another URL to leave the page.
- `open` (navigation with `tabId`, a new tab, or `newWindow`) and activate-only still work. When the loaded page is
  restricted, the response is `ok: true` with `restricted: true`, no streaming, and a stand-in `snapshot` with no
  elements whose `agentFeedback` (`trigger: "restricted_page"`) carries the same guidance.
- `act` whose step lands on a restricted page (an `openURL`, or a click on a store link): Chrome detaches the
  debugger, so later steps that need it fail with `errorCode: "RESTRICTED_PAGE"` (`mechanism: "restricted-page"`).
  The response skips the observation: `restricted: true`, `actionResult.observation: null` and
  `actionResult.agentFeedback` with the guidance.
- `tabs` adds `"restricted": true` to each restricted tab (the field is absent otherwise).
- `focus_tab` and `stop_stream` are unaffected.


## Closing the tabs UseMac opened (`close_owned_tabs`)

The extension remembers the tabs it created itself (`open` with a new tab or `newWindow`), in
`chrome.storage.session` so a service-worker restart keeps the list. The daemon sends `close_owned_tabs` about
2 s after `task_complete` unless the agent passed `keepTabs: true`.

```json
{"type":"request","id":"…","command":"close_owned_tabs","keepTabIds":[123]}
```

The extension closes every owned tab except tabs in `keepTabIds`, the active tab of the focused window (the user
is looking at it) and tabs whose origin has a download still in progress. Tabs the user opened are never in the
list, even if a command used them through `tabId`. The response carries `closedTabs` and `keptTabs`
(`[{tabId, title, reason}]`).

## UseMac tabs in `tabs` (`usemac: true`)

Tab listings mark tabs that belong to UseMac (in its "UseMac" tab group, or opened by it) with `usemac: true`.
The UseMac app only streams a Chrome window through the native (ScreenCaptureKit) preview when that window's
active tab is one of these; otherwise the preview shows a placeholder, so the user's own tabs never appear in it.
Extensions that predate the field send no `usemac`, which the app treats as "not a UseMac tab".
