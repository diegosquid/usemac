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

## Build from source

```bash
# Build all Swift targets
swift build

# Run Swift tests
swift test

# Run Chrome extension tests
node --test Tests/ExtensionTests/*.test.mjs

# Build and sign the local .app bundle under dist/
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
- `scripts/` — App bundling, DMG notarization/release, extension packaging, icon generation, and local vision worker scripts.
- `website/` — Static landing page, privacy policy, and Sparkle appcast deployed to Cloudflare Workers.

## Documentation

- [Agent Guide](.agents/AGENTS.md): setup, Unix socket, MCP and CLI
- [Agent Skill](.agents/skills/usemac/SKILL.md)
- [Chrome Extension Bridge Protocol](docs/BRIDGE-PROTOCOL.md)

## License

UseMac is released under the [MIT License](LICENSE).
