# UseMac

UseMac is a native macOS app and background daemon (written in Swift) that lets AI agents inspect and control macOS desktop applications and Google Chrome tabs without stealing focus. Agents connect over a local Unix domain socket, a native stdio MCP server, or the `usemac` CLI, while a Manifest V3 Chrome extension bridges background tabs and local safety controls govern what agents can do.

## Requirements

- macOS 15 or later
- Apple Silicon (`arm64`)
- Google Chrome (120 or later) for background browser tab automation

## Install

1. Drag `UseMac.app` into `/Applications` and open it.
2. Grant **Accessibility** and **Screen Recording** permissions in **UseMac → Settings → General → Permissions**.
3. Load the bundled Chrome extension in `chrome://extensions` (enable **Developer mode**, click **Load unpacked**, and select `/Applications/UseMac.app/Contents/Resources/chrome-extension`), then pair each Chrome profile once: open **UseMac → Settings → General → Chrome Extension**, click **Copy key**, and paste the `umk_…` key into the extension popup.
4. Open **UseMac → Settings → Connect** and paste the setup prompt into your AI agent (or run `/Applications/UseMac.app/Contents/Helpers/usemac install-skill`).

## How agents connect

### Unix socket (NDJSON)

`UseMac.app` listens on `/tmp/usemac-$UID/usemac.sock` (override with `USEMAC_SOCKET`), inside a folder only your user can open. If the socket file is deleted while the app runs, UseMac recreates it within 30 seconds. Connections are restricted to the same macOS user, and requests over 16 MiB are rejected (`message_too_large`). `id` is optional on requests, and boolean fields on `act` default to `stopOnError: true`, `returnObservation: true`, `returnDiffOnly: false`, and `includeScreenshot: false`.

```bash
printf '{"id":"1","method":"status"}\n' | nc -U "/tmp/usemac-$(id -u)/usemac.sock"
```

Methods (22): `ping`, `status`, `list_apps`, `observe`, `act`, `screenshot`, `set_policy`, `pair_app`, `audit_log`, `highlight`, `browser_status`, `browser_tabs`, `browser_open`, `browser_observe`, `browser_extract`, `browser_screenshot`, `browser_act`, `vision_status`, `vision_install`, `vision_query`, `task_start`, `task_complete`. The [Agent Guide](.agents/AGENTS.md#3-unix-socket-ndjson) describes each one.

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

Every MCP tool includes `annotations` (`readOnlyHint`, `destructiveHint`), and the server does not automatically retry an action on timeout. Exposed tools (16):

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

### CLI (`usemac`)

```bash
USEMAC="/Applications/UseMac.app/Contents/Helpers/usemac"
"$USEMAC" status
"$USEMAC" observe --app "Notes"
"$USEMAC" act '{"app":"Notes","steps":[{"action":"type","text":"Meeting notes","preferBackground":true}]}'
"$USEMAC" browser status
"$USEMAC" install-skill
```

When `UseMac.app` is closed, the CLI and MCP server run in read-only mode and action requests return `DAEMON_REQUIRED`. Passing `--standalone` runs in-process without the app and without its safety controls.

### Error codes

Failed requests carry an error `code`. The [Agent Guide](.agents/AGENTS.md#error-codes) explains each one and what the agent should do next.

- **Stop and tell the user** (a safety rule blocked it, or UseMac isn't running): `POLICY_BLOCKED`, `POLICY_LOCKED`, `URL_BLOCKED`, `UPLOAD_BLOCKED`, `SELF_TARGET_BLOCKED`, `IMAGE_PATH_BLOCKED`, `DAEMON_REQUIRED`.
- **The screen changed** (observe again): `STALE_SNAPSHOT`, `ELEMENT_NOT_FOUND`, `WAIT_TIMEOUT`.
- **Needs the app in front, or the user is busy**: `TARGET_NOT_FRONTMOST`, `USER_ACTIVE`.
- **Wrong route** (switch to native observe or the hybrid Chrome flow): `RESTRICTED_PAGE`, `CAPTURE_TOO_SMALL`.
- **Chrome extension**: `EXTENSION_NOT_CONNECTED`, `EXTENSION_NOT_PAIRED`, `EXTENSION_TIMEOUT`, `NO_USEMAC_TAB`, `CANCELLED`, `WINDOW_ERROR`, `EVAL_ERROR`.
- **Apps, permissions and captures**: `APP_NOT_FOUND`, `PERMISSION_DENIED`, `CAPTURE_FAILED`, `UPLOAD_FAILED`, `NO_IMAGE_SOURCE`.
- **Malformed requests**: `USAGE`, `INVALID_JSON`, `INVALID_REQUEST`, `INVALID_ARGUMENT`, `UNKNOWN_COMMAND`, `INVALID_MODEL`.
- **Unexpected failures**: `INTERNAL`, `ENCODING_FAILED`, `EXTENSION_ERROR`, `BROWSER_TABS_FAILED`, `BROWSER_OPEN_FAILED`, `BROWSER_OBSERVE_FAILED`, `BROWSER_EXTRACT_FAILED`, `BROWSER_SCREENSHOT_FAILED`, `BROWSER_ACT_FAILED`.

## Safety model

### Execution modes

| Mode (`set_policy`) | App UI label | Behavior |
| :--- | :--- | :--- |
| `autonomous` | **Autonomous** | Allows all actions (still subject to URL, upload, and path guards). |
| `confirmSensitive` | **Block sensitive** | Blocks `uploadFile`, keyboard shortcuts using `⌘` or `⌃`, and `browser_extract` in `eval` mode. |
| `readOnly` | **Read-only** | Blocks mutating actions; `scroll`, `hover`, `wait`, `target`, observe, read-only extract (`auto`, `tables`, `text`, `kpis`, `downloads`), and screenshots remain allowed. |
| `paused` | **Paused** | Blocks all automation, including reads. |

- **Kill Switch (`⇧⌘⎋`)**: Immediately blocks all automation including reads and cancels any in-progress Chrome batch. While **Kill Switch** or **Paused** is active, only `ping`, `status`, `audit_log`, `browser_status`, `vision_status`, `task_start`, and `task_complete` continue responding. Blocked requests return `POLICY_BLOCKED`.
- **One-way socket policy changes**: `set_policy` over the socket can only keep or tighten the execution mode; attempting to relax it returns `POLICY_LOCKED` (only the app can relax the mode).
- **Blocked by default**:
  - **URLs**: `browser_open` and `openURL`/`navigate` accept only `http://`, `https://`, and `about:blank` (scheme-less URLs get `https://`; everything else returns `URL_BLOCKED`).
  - **File uploads**: `uploadFile` blocks `~/.ssh`, `~/.aws`, `~/.gnupg`, Keychains, `.env` files, browser and password-manager directories in `~/Library`, shell histories, and secret/key extensions (`.pem`, `.pfx`, `.p8`, `.kdbx`, `.ovpn`, `.jks`, `.keystore`, `.tfstate`), returning `UPLOAD_BLOCKED`.
  - **UseMac's own windows**: agents can't observe or act on UseMac itself (Settings, the setup guide). Requests that name it return `SELF_TARGET_BLOCKED`, and `list_apps` leaves it out.
  - **Local vision paths & models**: `vision_query.imagePath` only accepts files inside your user temporary directory or `/tmp`; `vision_install` only accepts the three built-in model presets (`INVALID_MODEL`).
  - **Temporary captures**: Screenshots are written to a private folder inside your user temporary directory and deleted after 30 minutes.
- **Chrome extension pairing & tab isolation**: Each Chrome profile must be paired once with the local `umk_…` key (unpaired requests return `EXTENSION_NOT_PAIRED`, and the key is never exposed via RPC, MCP, or CLI). Without an explicit `tabId`, browser methods only target the last UseMac tab or a tab in the `UseMac` tab group (`NO_USEMAC_TAB` otherwise).
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

## License

UseMac is released under the [MIT License](LICENSE).
