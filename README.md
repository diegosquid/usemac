# UseMac

UseMac is a native macOS app and background daemon (written in Swift) that lets AI agents inspect and control macOS desktop applications and Google Chrome tabs without stealing focus. Agents connect over a local Unix domain socket, a native stdio MCP server, or the `usemac` CLI, while a Manifest V3 Chrome extension bridges background tabs and local safety controls govern what agents can do.

## Requirements

- macOS 15 or later
- Apple Silicon (`arm64`)
- Google Chrome (120 or later) for background browser tab automation

## Install

1. Drag `UseMac.app` into `/Applications` and open it.
2. Grant **Accessibility** and **Screen Recording** permissions in **UseMac → Settings → General → Permissions**.
3. Add the Chrome extension. Once the Chrome Web Store listing is live, add it from there: **Open Web Store** in the setup guide opens the listing, where you click **Add to Chrome**. Until then, and in beta builds, load the bundled copy in `chrome://extensions` (enable **Developer mode**, click **Load unpacked**, and select `/Applications/UseMac.app/Contents/Resources/chrome-extension`). Then pair each Chrome profile once: open **UseMac → Settings → General → Chrome Extension**, click **Copy key**, and paste the `umk_…` key into the extension popup.
   After a UseMac update, **Settings → Chrome Extension** flags a profile whose Chrome still runs the old extension (or one loaded from another folder, which app updates never reach); click **Reload** there, or run `usemac browser reload-extension` (socket method `browser_reload_extension`; it fails with `EXTENSION_RELOAD_UNSUPPORTED` for an extension too old to reload itself, which you reload once in `chrome://extensions`, `BROWSER_BUSY` while agents are using Chrome, or `EXTENSION_RELOAD_TIMEOUT` if it doesn't come back).
4. Open **UseMac → Settings → Connect** and paste the setup prompt into your AI agent (or run `/Applications/UseMac.app/Contents/Helpers/usemac install-skill`).

## How agents connect

### Unix socket (NDJSON)

`UseMac.app` listens on `/tmp/usemac-$UID/usemac.sock` (override with `USEMAC_SOCKET`), inside a folder only your user can open. If the socket file is deleted while the app runs, UseMac recreates it within 30 seconds. Connections are restricted to the same macOS user, and requests over 16 MiB are rejected (`message_too_large`). `id` is optional on requests, and boolean fields on `act` default to `stopOnError: true`, `returnObservation: true`, `returnDiffOnly: false`, and `includeScreenshot: false`.

```bash
printf '{"id":"1","method":"status"}\n' | nc -U "/tmp/usemac-$(id -u)/usemac.sock"
```

Methods (24): `ping`, `status`, `list_apps`, `observe`, `act`, `screenshot`, `set_policy`, `pair_app`, `audit_log`, `highlight`, `browser_status`, `browser_tabs`, `browser_open`, `browser_observe`, `browser_extract`, `browser_screenshot`, `browser_act`, `browser_reload_extension`, `vision_status`, `vision_install`, `vision_query`, `task_start`, `task_complete`, `report_prepare`. The [Agent Guide](.agents/AGENTS.md#3-unix-socket-ndjson) describes each one.

### MCP (`stdio`)

Add the bundled helper binary to your MCP client configuration under the `"usemac"` key:

```json
{
  "mcpServers": {
    "usemac": {
      "command": "/Applications/UseMac.app/Contents/Helpers/usemac",
      "args": ["mcp"]
    }
  }
}
```

Every MCP tool includes `annotations` (`readOnlyHint`, `destructiveHint`), and the server does not automatically retry an action on timeout. Exposed tools (17):

- `usemac_status`
- `usemac_list_apps`
- `usemac_observe`
- `usemac_act`
- `usemac_screenshot`
- `usemac_highlight`
- `usemac_browser_tabs`
- `usemac_browser_open`
- `usemac_browser_observe`
- `usemac_browser_extract`
- `usemac_browser_screenshot`
- `usemac_browser_act`
- `usemac_vision_status`
- `usemac_vision_query`
- `usemac_task_start`
- `usemac_task_complete`
- `usemac_report_prepare`

### CLI (`usemac`)

```bash
USEMAC="/Applications/UseMac.app/Contents/Helpers/usemac"
"$USEMAC" status
"$USEMAC" observe --app "Notes"
"$USEMAC" act '{"app":"Notes","steps":[{"action":"type","text":"Meeting notes","preferBackground":true}]}'
"$USEMAC" browser status
"$USEMAC" audit --since 2h
"$USEMAC" install-skill
```

When `UseMac.app` is closed, the CLI and MCP server run in read-only mode and action requests return `DAEMON_REQUIRED`. Passing `--standalone` runs in-process without the app and without its safety controls.

### Error codes

Failed requests carry an error `code` and `message`, and an optional `hint` when UseMac knows what the agent should do next (for `POLICY_BLOCKED`, which execution mode, pause or Kill Switch refused it). The [Agent Guide](.agents/AGENTS.md#error-codes) explains each code and what the agent should do next.

- **Stop and tell the user** (a safety rule blocked it, or UseMac isn't running): `POLICY_BLOCKED`, `POLICY_LOCKED`, `URL_BLOCKED`, `UPLOAD_BLOCKED`, `SELF_TARGET_BLOCKED`, `IMAGE_PATH_BLOCKED`, `DAEMON_REQUIRED`.
- **The screen changed** (observe again): `STALE_SNAPSHOT`, `ELEMENT_NOT_FOUND`, `WAIT_TIMEOUT`.
- **Needs the app in front, or the user is busy**: `TARGET_NOT_FRONTMOST`, `USER_ACTIVE`.
- **Wrong route** (switch to native observe or the hybrid Chrome flow): `RESTRICTED_PAGE`, `CAPTURE_TOO_SMALL`.
- **Chrome extension**: `EXTENSION_NOT_CONNECTED`, `EXTENSION_NOT_PAIRED`, `EXTENSION_TIMEOUT`, `EXTENSION_RELOAD_UNSUPPORTED`, `EXTENSION_RELOAD_TIMEOUT`, `BROWSER_BUSY`, `NO_USEMAC_TAB`, `CANCELLED`, `WINDOW_ERROR`, `EVAL_ERROR`.
- **Apps, permissions and captures**: `APP_NOT_FOUND`, `PERMISSION_DENIED`, `CAPTURE_FAILED`, `UPLOAD_FAILED`, `NO_IMAGE_SOURCE`.
- **Problem reports**: `REPORT_IN_REVIEW` (another report is still open for your review; see [How to contribute](#how-to-contribute)).
- **Malformed requests**: `USAGE`, `INVALID_JSON`, `INVALID_REQUEST`, `INVALID_ARGUMENT`, `UNKNOWN_COMMAND`, `INVALID_MODEL`.
- **Unexpected failures**: `INTERNAL`, `ENCODING_FAILED`, `EXTENSION_ERROR`, `BROWSER_TABS_FAILED`, `BROWSER_OPEN_FAILED`, `BROWSER_OBSERVE_FAILED`, `BROWSER_EXTRACT_FAILED`, `BROWSER_SCREENSHOT_FAILED`, `BROWSER_ACT_FAILED`.

## Safety model

### Execution modes

UseMac starts in **Autonomous** until you pick another mode in **Settings → General → Safety**. Any other mode shows in the menu bar: Read-only badges the icon with an eye, Paused and the Kill Switch with pause bars, and the menu says "Mode: …" with a link back to Safety. Agents that a mode refuses get a `POLICY_BLOCKED` hint that names it and tells them to ask you.

| Mode (`set_policy`) | App UI label | Behavior |
| :--- | :--- | :--- |
| `autonomous` | **Autonomous** | Allows all actions (still subject to URL, upload, and path guards). |
| `ask` | **Ask** | Holds `uploadFile`, keyboard shortcuts using `⌘` or `⌃` (any spelling), and `browser_extract` in `eval` mode until you click **Allow once** or **Deny** in a prompt next to the HUD. Deny returns `APPROVAL_DENIED`; no answer within 45 s returns `APPROVAL_TIMEOUT`. |
| `confirmSensitive` | **Block sensitive** | Blocks `uploadFile`, keyboard shortcuts using `⌘` or `⌃` (whatever the spelling: `cmd`, `command`, `meta`, `ctrl`, `control`), and `browser_extract` in `eval` mode. |
| `readOnly` | **Read-only** | Blocks mutating actions; `scroll`, `hover`, `wait`, `target`, observe, read-only extract (`auto`, `tables`, `text`, `kpis`, `downloads`), and screenshots remain allowed. |
| `paused` | **Paused** | Blocks all automation, including reads. |

- **Kill Switch (`⇧⌘⎋`)**: Immediately blocks all automation including reads and cancels any in-progress Chrome batch. While **Kill Switch** or **Paused** is active, only `ping`, `status`, `audit_log`, `browser_status`, `vision_status`, `task_start`, and `task_complete` continue responding. Blocked requests return `POLICY_BLOCKED`. `report_prepare` also works while **Paused** (it only opens UseMac's own review window), but not with the Kill Switch on.
- **One-way socket policy changes**: `set_policy` over the socket can only keep or tighten the execution mode; attempting to relax it returns `POLICY_LOCKED` (only the app can relax the mode).
- **Ask prompts answer only to you**: only a physical click with this Mac's mouse or trackpad answers an Ask prompt. It ignores clicks posted by any process (another agent, Screen Sharing, Universal Control, Voice Control) and Accessibility actions, there is no socket method or MCP tool for it, and UseMac refuses to post real input onto it. One prompt shows at a time; the others queue. Every answer, and every ignored click, goes to the audit log.
- **Blocked by default**:
  - **URLs**: `browser_open` and `openURL`/`navigate` accept only `http://`, `https://`, and `about:blank` (scheme-less URLs get `https://`; everything else returns `URL_BLOCKED`).
  - **File uploads**: `uploadFile` blocks `~/.ssh`, `~/.aws`, `~/.gnupg`, Keychains, `.env` files, browser and password-manager directories in `~/Library`, shell histories, and secret/key extensions (`.pem`, `.pfx`, `.p8`, `.kdbx`, `.ovpn`, `.jks`, `.keystore`, `.tfstate`), returning `UPLOAD_BLOCKED`.
  - **UseMac's own windows**: agents can't observe or act on UseMac itself (Settings, the setup guide). Requests that name it return `SELF_TARGET_BLOCKED`, and `list_apps` leaves it out.
  - **Local vision paths & models**: `vision_query.imagePath` only accepts files inside your user temporary directory or `/tmp`; `vision_install` only accepts the three built-in model presets (`INVALID_MODEL`).
  - **Temporary captures**: Screenshots are written to a private folder inside your user temporary directory and deleted after 30 minutes.
- **Audit log**: Every observation and action is appended to one JSONL file per day in `~/Library/Application Support/UseMac/audit/` (readable only by you), kept for 30 days by default (**Settings → General → History**). Typed text, `setValue` values and `eval` sources are stored only as their length unless you turn on **Record typed text**, and URLs always lose their credentials and secret-looking query values. **Settings → History** filters it by task, app and result and exports it as JSON Lines or CSV; agents read it with `audit_log` (`limit`, `sinceMs`, `taskId`) or `usemac audit`.
- **App and site rules** (**Settings → General → App and site rules**): apps by bundle ID and sites by host that agents never observe, act on or capture. By default they block Keychain Access, Passwords, 1Password, Bitwarden, KeePassXC and Dashlane, and the password managers' web vaults. **Allow only listed** mode limits agents to the apps and sites you list. Blocked apps and tabs are left out of `list_apps` and `browser_tabs`, whole-display screenshots and the live preview, and requests that would reach them return `TARGET_BLOCKED`. The daemon enforces the site rules for every `browser_*` call (it checks the tab's URL before sending and every result's URL), so they hold with any extension version. The rules can only be edited in the app, never over the socket, MCP or CLI.
- **Chrome extension pairing & tab isolation**: Each Chrome profile must be paired once with the local `umk_…` key (unpaired requests return `EXTENSION_NOT_PAIRED`, and the key is never exposed via RPC, MCP, or CLI). Without an explicit `tabId`, browser methods only target the task's own last tab (when the request carries the `taskId` from `task_start`), the last UseMac tab, or a tab in the `UseMac` tab group (`NO_USEMAC_TAB` otherwise).
- **Several agents at once**: `task_start` returns a `taskId` that every request can carry (top-level `taskId`, CLI `--task`/`USEMAC_TASK`, automatic over MCP). A task's requests without `tabId` stay in its own tabs, `task_complete` closes only the tabs that task opened and returns a `taskSummary` (requests, actions, blocked steps, tabs opened and closed, duration). The windows and tabs a task acts in are leased to it until it finishes: another task's action there returns `TARGET_BUSY` (CLI exit code 6), while reads never wait and requests of no task are never refused. Preview cards show each task's `agent` name (`task_start` `agent`, CLI `--agent`, the MCP client name by default).
- **AI client data flow**: Everything an agent observes, extracts, or captures through UseMac is returned to the AI client you connected, which typically sends that data to its AI provider under that provider's terms.

## Benchmarks

The numbers on [usemac.app](https://usemac.app) come from `scripts/bench.sh`. To reproduce them, open UseMac.app and run:

```bash
python3 -m http.server --bind 127.0.0.1 8742 --directory scripts/bench &   # serves the fixture form page
open -g -a Calculator
scripts/bench.sh --app Calculator --url http://127.0.0.1:8742/expense-form.html \
  --vision "The Submit expense button is visible"
```

It measures three things:

- **Local IPC**: `usemac bench --iterations 1000 --app Calculator`. Each sample is a round trip from the CLI to the running daemon over the Unix socket: encode, send, handle, reply, decode. `ping` does no work, so it is the floor. A hot-cache `observe` returns the window's cached snapshot and diff.
- **What the agent reads per look**: for a Chrome tab at a 1280×800 viewport, or a native window, the text that `usemac browser observe` or `usemac observe` prints (the same text the MCP tools return), next to a screenshot of the same view. Screenshot tokens use Anthropic's published estimate, width × height / 750, after the API's downscale (1568 px long edge, about 1,600 tokens). Text tokens are estimated at 2.5 characters per token, which is high on purpose for this dense text. `--count-tokens` replaces both with exact counts from Anthropic's `count_tokens` endpoint. It needs `ANTHROPIC_API_KEY` and sends the captures to the API.
- **On-device visual check**: `usemac vision verify` answered by the local model (install it first with `usemac vision install`). The agent reads the text answer instead of an image.

Results from 2026-11-26 on an Apple M4 Pro (12 cores, 24 GB), macOS 15.7 (24G222), with the installed UseMac 0.6.0-beta.2 and other builds running on the same machine:

| Local IPC, p50 across 9 runs | Result |
| :--- | ---: |
| `ping` (1,000 per run) | 0.032–0.039 ms (p95 0.04–0.13 ms) |
| `list_apps` | 0.44–0.69 ms |
| `observe` Calculator, hot cache | 0.99–1.24 ms |
| `observe` Calculator, cold | 19–69 ms |

| What the agent reads per look (estimated) | Text | Screenshot | Text vs. screenshot |
| :--- | ---: | ---: | ---: |
| Fixture form page (`scripts/bench/expense-form.html`) | ≈904 tokens | 1,366 tokens (1280×800) | −34% |
| This repository's landing page (`website/public`) | ≈1,674 tokens | 1,366 tokens (1280×800) | +23% |
| Calculator window | ≈744 tokens | 93 tokens (198×350) | +700% |
| Visual check of the fixture form, on-device (Qwen2.5-VL-3B-Instruct-4bit, 2.3–2.9 s inference) | ≈118 tokens | 1,366 tokens (1280×800) | −91% |

What this shows:

- A text snapshot is not always smaller than a screenshot. It is smaller for a form-like page. For a long page it lists every link and button plus the readable text, so it can cost more than one screenshot of the viewport. For a small native window, the screenshot is cheaper. What the snapshot gives the agent is element ids it can act on without guessing coordinates.
- The large saving is the on-device visual check: the agent reads a one-line answer instead of an image. It costs a couple of seconds of local inference, and the answer is only as good as a 3B model.
- Newer Claude models accept larger screenshots (up to 2576 px on the long edge) and can spend up to about 3× more tokens on a large capture. This comparison uses the smaller limit, so it does not count that.

## Build from source

```bash
# Build all Swift targets: .build/debug/UseMac (the app) and .build/debug/usemac-cli (the CLI)
swift build

# Run Swift tests
swift test

# Run Chrome extension tests
node --test Tests/ExtensionTests/*.test.mjs

# Build and sign the local .app bundle under dist/ (the CLI is installed as Contents/Helpers/usemac)
./scripts/bundle-app.sh

# Run release preflight checks (requires Developer ID, notarization, and Sparkle key to publish)
./scripts/release-dmg.sh --check
```

## Repository layout

- `.agents/` — The agent guide (`AGENTS.md`: setup, Unix socket, MCP and CLI) and the `usemac` skill (`skills/usemac/SKILL.md`), both bundled inside the app.
- `Assets/` — Master app icon artwork and Hardened Runtime entitlements.
- `Extension/` — Manifest V3 Google Chrome extension (`UseMac Browser Bridge`).
- `Sources/` — Swift package sources for the protocol, automation engine, IPC/MCP layer, macOS app, and CLI.
- `Tests/` — Swift unit/integration tests and Node.js extension tests.
- `docs/` — Chrome bridge protocol specification and release notes.
- `scripts/` — App bundling, DMG notarization/release, extension packaging, icon generation, local vision worker, and benchmark (`bench.sh`) scripts.
- `website/` — Static landing page, privacy policy, and Sparkle appcast deployed to Cloudflare Workers.

## Documentation

- [Agent Guide](.agents/AGENTS.md): setup, Unix socket, MCP and CLI
- [Agent Skill](.agents/skills/usemac/SKILL.md)
- [Chrome Extension Bridge Protocol](docs/BRIDGE-PROTOCOL.md)
- [Live smoke run](docs/SMOKE.md): `scripts/smoke.sh`, run before every release
- [Chrome Web Store release](docs/CHROME-WEB-STORE.md): the store ID (`USEMAC_CHROME_EXTENSION_ID`), packaging and submitting the extension

## How to contribute

### Report a problem

**With your agent.** When a task fails in a way that looks like a UseMac bug, your agent can offer to report it (or ask it to). It calls `report_prepare` (MCP `usemac_report_prepare`, CLI `usemac report --summary "…"`), and UseMac opens a **Review problem report** window with exactly the text that would be sent:

1. Read it. You can edit the title and the text to remove anything else.
2. Check **I checked this report and it has no personal or sensitive data**. Any later edit clears the check.
3. Click **Open issue on GitHub**. Your browser opens a prefilled issue on [diegosquid/usemac](https://github.com/diegosquid/usemac/issues), and you submit it there. A report too long for a link is copied to your clipboard instead, and you paste it into the issue.

**Copy** puts the report on the clipboard, and **Cancel** discards it. Nothing leaves your Mac until you submit the issue on GitHub yourself. Only a click with your own mouse or trackpad checks the box or presses the buttons: the window ignores clicks some process posted and Accessibility actions, and agents can't observe or act on UseMac's windows. The agent only learns that the report is waiting for your review (`awaiting_user_review`), never its text or what you decided. One report shows at a time.

**By hand.** [Open an issue](https://github.com/diegosquid/usemac/issues/new) with what you did, what you expected and what happened, your UseMac version (`usemac --version`) and macOS version, and the error code if there was one. `usemac audit --since 30m` prints recent activity; check it for personal data before you paste it.

**What a report contains**: the agent's description of the problem; the environment (UseMac version and build, macOS version, architecture, Chrome extension version and where Chrome loads it from, execution mode, permissions); the error codes UseMac recorded for the task since it last started; and up to 40 of the task's audit entries (or the last 30 minutes of activity when no task is named), already redacted as described under **Audit log** above.

**What is removed** before you see it, from the whole report including the agent's text: typed text, `setValue` values and page scripts (kept only as their length), emails, API keys and tokens, `password=`-style values, private keys, your home folder path (shown as `~`) and other users' folders, URL credentials, query strings and fragments, long numbers (card, phone and account numbers, codes), IP addresses, window titles, Chrome profile names, and your name, account name and computer name. Screenshots are never included. This is a safety net, not a guarantee: app names, page addresses and what the agent wrote stay in, so read the report before you send it.

### Build and test

You need macOS 15 on Apple Silicon, Xcode or the Swift 6 toolchain, and Node.js for the extension tests.

```bash
swift build                                  # .build/debug/UseMac (the app) and .build/debug/usemac-cli (the CLI)
swift test                                   # Swift unit and integration tests
node --test Tests/ExtensionTests/*.test.mjs  # Chrome extension tests
./scripts/bundle-app.sh                      # signed dist/UseMac.app, with the CLI in Contents/Helpers/usemac
```

`swift test` includes a docs sync test: every method, MCP tool and error code in the code must appear in `.agents/AGENTS.md`, `.agents/skills/usemac/SKILL.md` and this README, and the counts above must match. Before a release, `scripts/smoke.sh` runs a live check against the installed app ([docs/SMOKE.md](docs/SMOKE.md)).

### Open a pull request

1. Fork the repository and create a branch from `main`.
2. Keep commits small, with a subject in the imperative and a body that says why.
3. Run `swift build`, `swift test` and the extension tests. CI runs the same three on every pull request.
4. Document agent-facing changes (methods, parameters, MCP tools, error codes, defaults) in `.agents/AGENTS.md`, the skill, the MCP tool descriptions, the CLI help and this README.
5. Open the pull request against `main`. Say what changed for users and agents, how you tested it, and what you couldn't test. Link the issue it fixes (`Closes #123`).

## License

UseMac is released under the [MIT License](LICENSE).
