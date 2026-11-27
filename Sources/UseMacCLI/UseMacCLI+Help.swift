import Foundation

extension UseMacCLI {
    private struct CommandHelp {
        var usage: [String]
        var summary: String
        var flags: [(String, String)] = []
        var notes: [String] = []
        var examples: [String] = []
        var json: String?
    }

    private static let waitForLeaseHelp = ("--wait-for-lease <ms>", "Wait for the target lease (up to 30000 ms; default is no wait)")
    private static let browserDialogFlagHelp = [
        waitForLeaseHelp,
        ("--dialog-action <accept|dismiss>", "Override the JS dialog default: dismiss confirm and prompt, accept alert and beforeunload"),
        ("--dialog-prompt <text>", "Text to enter when accepting a JS prompt")
    ]
    private static let browserDragNote = "Drag between elementId/selector/match or (x, y) and toElementId/toSelector/toMatch or (toX, toY). saveFile is native only; for Chrome, click the download control and inspect the download path."

    private static let batchFlagHelp: [(String, String)] = [
        ("--app <name|pid>", "Target app (default: the app in the JSON, else the paired or frontmost app)"),
        ("--foreground", "Foreground burst: bring the app to the front, run the steps with real input, then give focus back. Refused with USER_ACTIVE if the user typed or used the mouse in the last 1.5 s. Use only when a background step had no effect or failed with TARGET_NOT_FRONTMOST."),
        ("--foreground-fallback", "Automatically escalate to a foreground burst if a background step fails with TARGET_NOT_FRONTMOST"),
        ("--mode <m>", "Post-action observation mode: auto, delta, interactive, full, none"),
        ("--diff-crop", "Crop post-action screenshot to the changed dirty rect"),
        ("--diff-only", "Render only changed/added/removed elements from the post-action diff"),
        ("--expect-title <text>", "Precondition: fail with STALE_SNAPSHOT before any step unless the target window title contains <text> (digits ignored)"),
        ("--allow-stale", "Skip the automatic check that the window still shows what your last observe saw"),
        ("--window <title>", "Act in the window whose title contains this text (default: the window of your last observe)"),
        waitForLeaseHelp
    ]

    private static let batchResultJSON = "BatchActionResult {success, totalLatencyMs, stepResults: [{index, action, success, mechanism, latencyMs, message, errorCode, effect (changed|none|unverified), warning, resolvedElementId, scrollDeltaY, visualChangePercent, downloadPath}], observation: WindowSnapshot, dialogs, agentFeedback, screenshot}"

    private static let snapshotJSON = "WindowSnapshot {app: {pid, name, bundleId, windowTitle, windowId}, timestampMs, latencyMs, fromHotCache, focusedElementId, elements: [{id, role, title, value, roleDescription, enabled, focused, frame {x, y, width, height}, actions, offscreen}], diff, screenshotPath}"

    private static let restrictedPageNote = "On RESTRICTED_PAGE (Chrome Web Store, chrome://), use 'usemac browser open --tab <id> --activate' (or 'browser open <url> --new-window'). Keep the Chrome window visible on screen, then use native observe and act with --app \"Google Chrome\" and --window <title>. If observe only shows the toolbar or setValue reports effect: none, use 'usemac act' with --foreground to briefly focus the pinned window, act, and restore focus."

    private static let browserSubcommands: [(String, String)] = [
        ("status", "List Chrome profiles connected to the extension"),
        ("tabs", "List open Chrome tabs with tabId, title and URL"),
        ("open", "Open a URL in a background tab, navigate a tab, activate a tab, or open a new window"),
        ("observe", "Inspect a tab's DOM (@b1..@bN), tables, text and overlays"),
        ("extract", "Extract tables, KPIs, text, network JSON, JS results or session downloads"),
        ("batch", "Open and observe/extract multiple URLs in parallel Chrome tabs"),
        ("screenshot", "Capture a JPEG of a tab or one element"),
        ("act", "Run DOM action steps in a tab"),
        ("reload-extension", "Reload the extension so Chrome runs its current code")
    ]

    private static let skillSubcommands: [(String, String)] = [
        ("list", "List saved automation skills (filter by --query, --kind, --app, --url)"),
        ("save", "Save or update a parameterized automation skill"),
        ("run", "Replay a saved skill with --params"),
        ("delete", "Delete a saved skill by name")
    ]

    private static let visionSubcommands: [(String, String)] = [
        ("status", "Show Local Vision status (Apple Vision OCR)"),
        ("ask", "Ask a visual question about the screen"),
        ("verify", "Check a visual assertion (YES/NO + evidence)"),
        ("describe", "Summarize the visible state (errors, values, buttons, modals)"),
        ("locate", "Find the (x, y) point of a visual element"),
        ("diagnose", "Detect banners, modals or errors blocking the page"),
        ("ocr", "Run Apple Vision OCR")
    ]

    private static func commandHelp(_ key: String) -> CommandHelp? {
        switch key {
        case "ping":
            return CommandHelp(
                usage: ["usemac ping"],
                summary: "Check that the daemon answers and show the round-trip latency.",
                examples: ["usemac ping"],
                json: "{ok, mode, pong, roundTripMs, roundTripUs, serverLatencyMs}"
            )
        case "status":
            return CommandHelp(
                usage: ["usemac status"],
                summary: "Show the daemon version, execution mode, Kill Switch, permissions, paired and frontmost app, connected Chrome profiles and telemetry.",
                examples: ["usemac status"],
                json: "DaemonStatus {version, pid, socketPath, policy, killSwitchTripped, permissions {accessibilityGranted, screenRecordingGranted}, pairedApp, frontmostApp, browserProfiles, telemetry}"
            )
        case "apps":
            return CommandHelp(
                usage: ["usemac apps"],
                summary: "List running GUI apps with pid, bundle id, active state and front window title. UseMac itself, and apps the user's app and site rules block (TARGET_BLOCKED), are never listed or targeted.",
                examples: ["usemac apps"],
                json: "[AppDescriptor {pid, name, bundleId, isActive, isHidden, windowTitle, windowBounds, windowId}]"
            )
        case "observe":
            return CommandHelp(
                usage: ["usemac observe [--app <name|pid>] [--role <role>] [--text <text>] [--max-depth <n>] [--max-elements <n>] [--no-cache] [--no-diff] [--include-offscreen] [--no-offscreen] [--screenshot]"],
                summary: "Capture a compact accessibility snapshot of the app's focused window. The same element keeps the same @eN id across observes; pass --include-offscreen to list scrolled-out elements as (offscreen).",
                flags: [
                    ("--app <name|pid>", "Target app name, bundle id or pid (default: the paired app, else the frontmost app)"),
                    ("--role <role>", "Only print elements with this AX role, with or without the AX prefix (button = AXButton)"),
                    ("--text <text>", "Only print elements whose title, description or value contains <text> (case- and accent-insensitive)"),
                    ("--max-depth <n>", "How deep to walk the accessibility tree (raise it for nested lists and sheets)"),
                    ("--max-elements <n>", "Maximum number of elements to index"),
                    ("--no-cache", "Read the live tree instead of the hot cache"),
                    ("--diff | --no-diff", "Include (default) or leave out the diff against the previous snapshot"),
                    ("--include-offscreen", "Also list elements scrolled out of view as (offscreen)"),
                    ("--no-offscreen", "Leave out elements scrolled out of view (default)"),
                    ("--window <title>", "Observe the window whose title contains this text instead of the focused one; later acts keep using it"),
                    ("--screenshot", "Also save a JPEG of the window and print its path")
                ],
                notes: ["--role and --text only narrow what is printed; the daemon still indexes the whole window, so ids stay valid for act."],
                examples: [
                    "usemac observe --app \"Notes\"",
                    "usemac observe --app \"System Settings\" --role checkbox --text bluetooth"
                ],
                json: snapshotJSON + " (with --role/--text, elements holds only the matches)"
            )
        case "find":
            return CommandHelp(
                usage: ["usemac find --app <name|pid> [--role <role>] [--text <t>] [--title <t>] [--value <v>] [--exact] [--first] [--max-depth <n>] [--max-elements <n>]"],
                summary: "Read the app's live accessibility tree (no cache) and print the elements that match, using the same rules act uses for \"match\". Use it to check a match before acting, or to get an id.",
                flags: [
                    ("--app <name|pid>", "Target app (required)"),
                    ("--role <role>", "AX role, with or without the AX prefix (button = AXButton)"),
                    ("--text <t>", "Title, description or value contains <t>"),
                    ("--title <t>", "Title or description contains <t>"),
                    ("--value <v>", "Value contains <v>"),
                    ("--exact", "Require equal text instead of contains"),
                    ("--first", "Print only the id of the first match (exit 1 when nothing matches)"),
                    ("--max-depth <n>", "How deep to walk the tree (raise it for long or nested lists)"),
                    ("--max-elements <n>", "Maximum number of elements to read")
                ],
                notes: [
                    "Text compares are case- and accent-insensitive. Every filter you pass must match. At least one filter is required.",
                    "Exit code 1 when nothing matches, like grep."
                ],
                examples: [
                    "usemac find --app \"Notes\" --role button --text \"new note\"",
                    "ID=$(usemac find --app \"Mail\" --role textfield --title subject --first) && usemac set \"$ID\" \"Weekly report\" --app \"Mail\""
                ],
                json: "{app: AppDescriptor, count, matches: [ElementNode]} (count 0 and exit 1 when nothing matches)"
            )
        case "act":
            return CommandHelp(
                usage: [
                    "usemac act '<json>' [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]",
                    "usemac act - < batch.json"
                ],
                summary: "Run a BatchActionRequest (a JSON object) or a list of ActionStep (a JSON array) on a native app, in the background by default. Pass - to read the JSON from stdin.",
                flags: batchFlagHelp,
                notes: [
                    "Batch keys: app, steps, stopOnError, returnObservation, returnDiffOnly, includeScreenshot, expectWindowTitle, allowStaleSnapshot, foreground, window, waitForLeaseMs. Flags win over the same keys in the JSON.",
                    "Step actions: target, openURL, navigate, click, doubleClick, rightClick, hover, setValue, type, pressKey, scroll, focus, wait, uploadFile, scrollIntoView, axAction (actionName, e.g. AXOpen), waitFor (match or elementId, timeoutMs default 5000, gone: true to wait until it disappears).",
                    "Target a step with \"elementId\": \"@e12\" or with \"match\": {\"role\", \"title\", \"value\", \"text\", \"exact\", \"index\"}, resolved when the step runs. Prefer match when the window may have changed.",
                    "drag: name the source with elementId/match or (x, y), and the destination with toElementId/toMatch or (toX, toY). saveFile: with a native Save panel open, pass one absolute destination in files and overwrite: true only to replace an existing file.",
                    "Each step reports effect: changed, none or unverified. \"⚠ no visible effect\" means the step reported ok but nothing changed: observe before continuing.",
                    "In an open panel (file picker) use one uploadFile step with the absolute path instead of clicking through Finder. Files in /tmp, $TMPDIR or hidden folders fail with TARGET_NOT_FRONTMOST in the background: upload a copy from ~/Downloads, or rerun with --foreground.",
                    "In Ask mode a step with an upload or a cmd/ctrl shortcut waits (up to 45 s) for the user to allow it in UseMac; APPROVAL_DENIED or APPROVAL_TIMEOUT (exit 4) means nothing ran."
                ],
                examples: [
                    "usemac act '{\"app\":\"Notes\",\"steps\":[{\"action\":\"click\",\"match\":{\"role\":\"button\",\"title\":\"New Note\"}},{\"action\":\"type\",\"text\":\"Hello\"}]}'",
                    "usemac act '[{\"action\":\"waitFor\",\"match\":{\"text\":\"Saved\"},\"timeoutMs\":8000}]' --app \"Notes\"",
                    "usemac act '[{\"action\":\"uploadFile\",\"files\":[\"/Users/me/Desktop/report.pdf\"]}]' --app \"Safari\""
                ],
                json: batchResultJSON
            )
        case "click":
            return CommandHelp(
                usage: ["usemac click <@eID> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Click an element by id (AXPress in the background when the element supports it).",
                flags: batchFlagHelp,
                notes: ["To click by what the element is, use act with \"match\", or: usemac click \"$(usemac find --app <name> --role button --title Save --first)\" --app <name>."],
                examples: ["usemac click @e12 --app \"Notes\""],
                json: batchResultJSON
            )
        case "set":
            return CommandHelp(
                usage: ["usemac set <@eID> <text> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Set an element's value directly (AXValue) without typing. Works in the background.",
                flags: batchFlagHelp,
                examples: ["usemac set @e7 \"hello@example.com\" --app \"Mail\""],
                json: batchResultJSON
            )
        case "type":
            return CommandHelp(
                usage: ["usemac type <text> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Type text into the app's focused element.",
                flags: batchFlagHelp,
                examples: ["usemac type \"Meeting notes\" --app \"Notes\""],
                json: batchResultJSON
            )
        case "key":
            return CommandHelp(
                usage: ["usemac key <chord> [--app <name>] [--foreground] [--expect-title <text>] [--allow-stale]"],
                summary: "Press a key or shortcut. Modifiers: cmd (command, meta), shift, opt (alt, option), ctrl (control). Keys: return (enter), tab, space, delete (backspace), forwarddelete, escape (esc), up, down, left, right, home, end, pageup, pagedown, f1–f12, a–z, 0–9, - = [ ] ; ' , . / \\ `.",
                flags: batchFlagHelp,
                notes: [
                    "In Ask mode a step with an upload or a cmd/ctrl shortcut waits (up to 45 s) for the user to allow it in UseMac; APPROVAL_DENIED or APPROVAL_TIMEOUT (exit 4) means nothing ran.",
                    "Character keys are key positions on a US keyboard: use `usemac type` to enter text, and shift plus the base key for a shifted symbol (shift+= for +).",
                    "An unknown key fails with INVALID_REQUEST and lists these names."
                ],
                examples: ["usemac key cmd+shift+n --app \"Finder\"", "usemac key pagedown --app \"TextEdit\""],
                json: batchResultJSON
            )
        case "screenshot":
            return CommandHelp(
                usage: ["usemac screenshot [--app <name>] [--max-dim <n>] [--base64]"],
                summary: "Save a downscaled JPEG of the app's target window (or the display) to a private temp folder (pruned after 30 minutes).",
                flags: [
                    ("--app <name>", "Target app (default: the paired or frontmost app)"),
                    ("--max-dim <n>", "Longest edge in pixels (default 1280)"),
                    ("--base64", "Also print the image as base64")
                ],
                notes: ["Fails with CAPTURE_TOO_SMALL (exit 7) when the only window found is too small to trust, such as a helper strip: observe the app instead of reading that image."],
                examples: ["usemac screenshot --app \"Notes\""],
                json: "ScreenshotResult {path, mimeType, width, height, byteCount, latencyMs, base64Data}"
            )
        case "browser":
            return CommandHelp(
                usage: ["usemac browser <subcommand> [arguments]"],
                summary: "Drive Google Chrome tabs in the background through the UseMac Browser Bridge extension. Use these before any native observe/act on Chrome.",
                flags: browserSubcommands,
                notes: [restrictedPageNote, "Run 'usemac help browser <subcommand>' for its flags."],
                examples: ["usemac browser tabs --query analytics", "usemac browser observe --tab 123"]
            )
        case "browser status":
            return CommandHelp(
                usage: ["usemac browser status"],
                summary: "List the Chrome profiles connected to the extension (name, e-mail, extension version, tab count, streaming tab), and whether each one runs an outdated extension or one loaded from another folder.",
                notes: [
                    "extensionOutdated: Chrome runs an older extension than UseMac.app ships (bundledExtensionVersion). Tell the user, or run 'usemac browser reload-extension' when nothing else is using Chrome.",
                    "extensionSource: app (UseMac.app's folder), web_store, other_folder (unpacked from another folder: app updates won't reach it) or unknown."
                ],
                examples: ["usemac browser status"],
                json: "[BrowserProfileStatus {profileName, profileEmail, extensionVersion, tabCount, streamingTabId, streamingUrl, extensionId, extensionSource, bundledExtensionVersion, extensionOutdated, extensionReloadable, extensionNote}]"
            )
        case "browser reload-extension":
            return CommandHelp(
                usage: ["usemac browser reload-extension [--profile <name>] [--force]"],
                summary: "Reload the UseMac extension so Chrome runs the code now in its folder (after an app update, or a change in the folder it was loaded from). Waits until it has reconnected and prints its new version.",
                flags: [
                    ("--profile <name>", "Reload only this Chrome profile (default: every connected profile)"),
                    ("--force", "Reload even while agents have Chrome commands running (they fail)")
                ],
                notes: [
                    "Reloading stops every agent's browser work in that profile: run it only when the user asks, or when nothing else is using Chrome. Without --force it fails with BROWSER_BUSY while commands are running.",
                    "Tabs UseMac opened before the reload stay open, but 'done' no longer closes them.",
                    "EXTENSION_RELOAD_UNSUPPORTED: the extension predates remote reload. The user reloads it once in chrome://extensions. EXTENSION_RELOAD_TIMEOUT: it did not come back within 15 s; check chrome://extensions for errors."
                ],
                examples: ["usemac browser reload-extension", "usemac browser reload-extension --profile Work"],
                json: "[BrowserProfileStatus] of the reloaded profiles, as 'browser status' prints them"
            )
        case "browser tabs":
            return CommandHelp(
                usage: ["usemac browser tabs [--profile <name>] [--query <text>]"],
                summary: "List open Chrome tabs with tabId, title, URL and active state. Tabs on sites the user's app and site rules block are left out; any browser command on one, or opening such a site, fails with TARGET_BLOCKED (exit 4).",
                flags: [
                    ("--profile <name>", "Chrome profile from 'browser status' (only needed with several profiles)"),
                    ("--query <text>", "Case-insensitive filter on title or URL")
                ],
                examples: ["usemac browser tabs --query \"analytics\""],
                json: "[BrowserTabInfo {tabId, windowId, index, title, url, active, pinned, status, profileName}]"
            )
        case "browser open":
            return CommandHelp(
                usage: [
                    "usemac browser open <url> [--profile <name>] [--tab <id>] [--same-tab|--new-tab] [--activate] [--new-window] [--no-stream] [--task <taskId>]",
                    "usemac browser open --tab <id> --activate"
                ],
                summary: "Open a URL in a new background tab, navigate an existing tab, make a tab active, or open the URL in a new unfocused window.",
                flags: [
                    ("--profile <name>", "Chrome profile from 'browser status' (only needed with several profiles)"),
                    ("--tab <id>", "Navigate this tab instead of opening a new one"),
                    ("--same-tab | --new-tab", "Force navigating in place or opening a new tab"),
                    ("--activate", "Make the tab the active tab of its window (Chrome stays in the background). With --tab and no URL, only activates that tab."),
                    ("--new-window", "Open the URL in a new, unfocused Chrome window owned by UseMac (cannot be combined with --tab)"),
                    ("--no-stream", "Do not stream live preview frames to the UseMac HUD"),
                    ("--task <taskId>", "The taskId 'start' printed: the new tab belongs to that task, so another agent's 'done' never closes it"),
                    ("--steps <json>", "Run an array of browser action steps after the page loads")
                ] + browserDialogFlagHelp,
                notes: [
                    "Only http://, https:// and about:blank are allowed (a URL without a scheme gets https://); anything else fails with URL_BLOCKED.",
                    browserDragNote,
                    restrictedPageNote
                ],
                examples: [
                    "usemac browser open \"https://example.com\"",
                    "usemac browser open --tab 123 --activate",
                    "usemac browser open \"https://chromewebstore.google.com/\" --new-window"
                ],
                json: "RPCResponse {ok, browserTabId, browserUrl, browserTitle, snapshot, actionResult}"
            )
        case "browser observe":
            return CommandHelp(
                usage: ["usemac browser observe [--profile <name>] [--tab <id>] [--max-elements <n>] [--screenshot] [--no-text] [--no-tables]"],
                summary: "Inspect a tab's interactive DOM as @b1..@bN refs (including cross-origin iframes and Shadow DOM), tables, readable text, scroll state and blocking overlays.",
                flags: [
                    ("--profile <name>", "Chrome profile (only needed with several profiles)"),
                    ("--tab <id>", "Tab to observe (default: the last UseMac tab)"),
                    ("--max-elements <n>", "Maximum DOM elements (default 280, max 600)"),
                    ("--screenshot", "Also save a JPEG of the tab"),
                    ("--no-text | --no-tables", "Leave out readable text or tables"),
                    ("--width/--height <px>, --scale <n>", "Ignored: UseMac never resizes a tab (still accepted, for old scripts)")
                ],
                notes: [
                    "The tab is observed at the size Chrome gives it; UseMac never resizes it.",
                    restrictedPageNote
                ],
                examples: ["usemac browser observe --tab 123"],
                json: snapshotJSON + " plus pageState {readableText, tablesMarkdown, scroll…, blockingOverlay}"
            )
        case "browser extract":
            return CommandHelp(
                usage: ["usemac browser extract [auto|tables|text|kpis|network|eval|downloads] [--profile <name>] [--tab <id>] [--selector <css>] [--expr <js>] [--scan-horizontal] [--max-chars <n>]"],
                summary: "Extract structured data from a tab. auto, tables, text, kpis and network only read; eval runs JavaScript in the page (autonomous mode, or Ask mode once the user allows it; logged). Downloads lists recent UseMac downloads per Chrome profile and is not supported in browser batch.",
                flags: [
                    ("--tab <id>", "Tab to read (not used in downloads mode)"),
                    ("--selector <css>", "Scope extraction to one container"),
                    ("--expr <js>", "Expression for eval mode"),
                    ("--scan-horizontal", "Scroll wide virtualized grids horizontally and merge all columns"),
                    ("--max-chars <n>", "Output limit (default 16000)")
                ],
                examples: ["usemac browser extract tables --tab 123 --scan-horizontal", "usemac browser extract downloads --profile Work"],
                json: "BrowserExtractResult {mode, tabId, url, tablesMarkdown, rowCount, columnCount, text, jsonResult, downloads, latencyMs}. Downloads mode returns the downloads array, not jsonResult."
            )
        case "browser screenshot":
            return CommandHelp(
                usage: ["usemac browser screenshot [--profile <name>] [--tab <id>] [--selector <css>] [--element <@bID>] [--full-page] [--width <px>] [--height <px>] [--quality <n>]"],
                summary: "Capture a JPEG of a tab at its real size, or crop it around a selector or @bID. UseMac never resizes the tab. Prefer observe/extract or on-device vision first.",
                flags: [
                    ("--selector <css> | --element <@bID>", "Capture this element, scrolled into view if needed; one bigger than the tab shows its top-left part (truncated)"),
                    ("--full-page", "Scroll through the page and stitch it at the tab's width, up to 16384 CSS px (longer pages are truncated)"),
                    ("--width/--height <px>", "Scale the image down to fit this box, keeping its aspect ratio (one is enough); the page is not resized"),
                    ("--scale <n>", "Ignored (still accepted, for old scripts)"),
                    ("--quality <n>", "JPEG quality 30–100 (default 84)")
                ],
                examples: ["usemac browser screenshot --tab 123 --selector \"#chart\"", "usemac browser screenshot --tab 123 --width 1280 --height 800"],
                json: "ScreenshotResult {path, mimeType, width, height, byteCount, latencyMs, truncated}"
            )
        case "browser act":
            return CommandHelp(
                usage: ["usemac browser act '<json>' [--profile <name>] [--tab <id>] [--read-only] [--verify \"<condition>\"] [--screenshot]"],
                summary: "Run DOM action steps in a tab with @bN refs or CSS selectors: click, doubleClick, rightClick, drag, hover, setValue (including <select>), type, pressKey, scroll, wait (with selector or text), uploadFile (no Finder), navigate/openURL.",
                flags: [
                    ("--tab <id>", "Tab to act on"),
                    ("--read-only", "Block mutating steps (only scroll, hover, wait and target run)"),
                    ("--verify \"<condition>\"", "Check the result on-device after the steps (zero cloud image tokens)"),
                    ("--screenshot", "Attach a post-action screenshot")
                ] + browserDialogFlagHelp,
                notes: [
                    "JSON keys: profile, tabId, steps, stopOnError, returnObservation, returnDiffOnly, readOnly, verify, returnImageContent, waitForLeaseMs, dialogAction, dialogPromptText.",
                    browserDragNote,
                    restrictedPageNote,
                    "In Ask mode a step with an upload or a cmd/ctrl shortcut waits (up to 45 s) for the user to allow it in UseMac; APPROVAL_DENIED or APPROVAL_TIMEOUT (exit 4) means nothing ran."
                ],
                examples: ["usemac browser act '[{\"action\":\"setValue\",\"elementId\":\"@b2\",\"text\":\"UseMac\"},{\"action\":\"click\",\"elementId\":\"@b3\"}]' --tab 123"],
                json: batchResultJSON
            )
        case "vision":
            return CommandHelp(
                usage: ["usemac vision <subcommand> [arguments]"],
                summary: "On-device vision (Apple Vision OCR). Images never leave the Mac.",
                flags: visionSubcommands,
                notes: ["Run 'usemac help vision <subcommand>' for its flags."],
                examples: ["usemac vision verify \"Success banner is visible\" --tab 123"]
            )
        case "vision status":
            return CommandHelp(
                usage: ["usemac vision status"],
                summary: "Show whether on-device Apple Vision OCR is ready.",
                examples: ["usemac vision status"],
                json: "VisionStatus {state, enabled, backend, ocrAvailable, lastError}"
            )
        case "vision ask", "vision verify", "vision describe", "vision locate", "vision diagnose", "vision ocr":
            let mode = String(key.dropFirst("vision ".count))
            let summaries: [String: String] = [
                "ask": "Answer a visual question about the screen, grounded in OCR.",
                "verify": "Check a visual assertion and answer YES/NO with evidence.",
                "describe": "Summarize the visible state: errors, values, buttons, modals.",
                "locate": "Return the (x, y) point of a visual element.",
                "diagnose": "Detect banners, modals or errors blocking the page and suggest where to click.",
                "ocr": "Run Apple Vision OCR and print the text with positions."
            ]
            let takesText = ["ask", "verify", "locate"].contains(mode)
            return CommandHelp(
                usage: ["usemac vision \(mode)\(takesText ? " \"<text>\"" : "") [--profile <name>] [--tab <id>] [--app <name>] [--image <path>] [--selector <css>] [--element <@bID>] [--prompt \"<text>\"]"],
                summary: summaries[mode] ?? "",
                flags: [
                    ("--tab <id> | --app <name>", "What to look at: a Chrome tab or a native app window"),
                    ("--image <path>", "Use an existing image (must be in your temp folder or /tmp)"),
                    ("--selector <css> | --element <@bID>", "Crop to one element of a Chrome tab"),
                    ("--prompt \"<text>\"", "Question or condition (same as the positional text)")
                ],
                examples: [mode == "verify" ? "usemac vision verify \"Success banner is visible\" --tab 123" : "usemac vision \(mode)\(takesText ? " \"X close button\"" : "") --app \"Notes\""],
                json: "VisionQueryResult {mode, backend, modelId, answer, verified, x, y, blockingDetected, imagePath, detections, latencyMs}"
            )
        case "start":
            return CommandHelp(
                usage: ["usemac start [--summary \"<text>\"] [--agent <name>] [--app <name>] [--profile <name>] [--tab <id>] [--task <taskId>]"],
                summary: "Call once at the start of a multi-step task so the floating live preview opens once and stays open between steps. Prints a taskId: pass it as --task to every later command (or export USEMAC_TASK=<taskId>). When several agents work at once, a browser command without --tab then goes to this task's own last tab, not another agent's, and finishing this task only closes the tabs it opened. While the task runs, the windows and tabs it acts in are its own: another task's act there fails with TARGET_BUSY (exit 6) until this one is done. --agent names the agent on its preview cards.",
                examples: ["usemac start --summary \"Reviewing dashboard\" --agent \"Claude Code\""]
            )
        case "stop", "done", "complete":
            return CommandHelp(
                usage: ["usemac done [--summary \"<text>\"] [--task <taskId>] [--app <name>] [--profile <name>] [--tab <id>] [--keep-tab <id,id>] [--keep-tabs]   (aliases: stop, complete)"],
                summary: "Call once when the whole task is finished: shows the completion state and closes the live preview. About 2 s later UseMac closes the Chrome tabs it opened (never your own tabs, the tab you are looking at, or tabs with a running download). --keep-tab keeps the page with the result; --keep-tabs keeps them all. With --task, only that task's tabs close: tabs other running tasks opened are never closed. Prints what the task did (with --json: taskSummary with requests, actions, failedActions, blocked, tabsOpened, tabsClosed, tabsClosing, durationMs).",
                examples: ["usemac done --summary \"Report exported\"", "usemac done --summary \"Invoice ready\" --keep-tab 123"]
            )
        case "audit":
            return CommandHelp(
                usage: ["usemac audit [--limit <n>] [--since <30m|2h|7d|date|ms>] [--task <taskId>]"],
                summary: "Print the audit log, newest first: every observation and action, with its app, result and task. Without flags, the 50 most recent entries. UseMac keeps it on disk (one file per day, 30 days by default), and typed text and page scripts appear only as their length.",
                flags: [
                    ("--limit <n>", "How many entries (default 50, at most 1000)"),
                    ("--since <time>", "Only newer entries: a duration (30m, 2h, 7d), a date (2026-11-25, ISO 8601) or ms since 1970"),
                    ("--task <taskId>", "Only the entries of this task (the taskId 'start' printed)")
                ],
                notes: ["Filters read the log on disk, so they reach back past the last restart; with the app closed, only the files in ~/Library/Application Support/UseMac/audit/ have it."],
                examples: ["usemac audit", "usemac audit --task task-1a2b3c4d", "usemac audit --since 2h --limit 200 --json"],
                json: "[AuditEntry {id, timestampMs, method, targetApp, summary, latencyMs, success, taskId}]"
            )
        case "report":
            return CommandHelp(
                usage: ["usemac report --summary \"<what you tried, what you expected, what happened>\" [--title \"<text>\"] [--task <taskId>]"],
                summary: "Prepare a problem report about a failure that looks like a UseMac bug (not a safety block or the user's choice), after the user agreed. UseMac builds it from your summary, the environment (app, extension and macOS versions, execution mode) and the task's audit entries and error codes, removes sensitive data (typed text, emails, tokens and keys, the home folder, URL query strings, long numbers; never screenshots), and opens it in its \"Review problem report\" window. It answers at once with awaiting_user_review. Only the user can open the report as a GitHub issue, from that window; you never see the text or the user's decision. Tell the user to review the window, and never paste the report anywhere else.",
                flags: [
                    ("--summary <text>", "Required: what you tried, what you expected and what happened (at most 4000 characters)"),
                    ("--title <text>", "Issue title (default: the first line of the summary)"),
                    ("--task <taskId>", "The task the report is about (default: $USEMAC_TASK, else the only running task, else the last 30 minutes of activity)")
                ],
                notes: [
                    "Works in every execution mode, Read-only and Paused included; the Kill Switch blocks it (POLICY_BLOCKED). Without the app it fails with DAEMON_REQUIRED.",
                    "One report shows at a time: while the user still has one open, report fails with REPORT_IN_REVIEW."
                ],
                examples: ["usemac report --task task-1a2b3c4d --summary \"Clicked Save in TextEdit with match; expected the sheet to open; got ELEMENT_NOT_FOUND twice although the button was visible.\""],
                json: "ProblemReportReceipt {reportId, status (awaiting_user_review), taskId, entryCount, errorCodes, message}"
            )
        case "debug":
            return CommandHelp(
                usage: ["usemac debug <subcommand> [arguments]"],
                summary: "Tools for developing UseMac itself. They work only after the user turns on Debug capture in UseMac → Settings → Developer.",
                flags: [("capture", "Save PNGs of UseMac's own windows (live preview, Settings, …), read-only")],
                notes: ["Run 'usemac help debug capture' for its flags."],
                examples: ["usemac debug capture --window preview"]
            )
        case "debug capture":
            return CommandHelp(
                usage: ["usemac debug capture [--window <kinds>] [--frames <n>] [--interval <ms>] [--context] [--margin <pt>] [--out <dir>]"],
                summary: "For developing UseMac: save PNGs of UseMac's own windows so you can check its UI (the live preview, Settings, the setup guide, …). Read-only: it never clicks or types in them, and observe, act and screenshot still refuse UseMac's windows (SELF_TARGET_BLOCKED). Each window is captured on its own with its transparency and shadow. Prints each PNG's path, window kind, title and frame in screen points (origin at the top-left of the main display).",
                flags: [
                    ("--window <kinds>", "Comma-separated: preview, prompt (the Ask prompt), settings, setup, report, other, all, context (default all)"),
                    ("--frames <n>", "Take a burst of n captures to see an animation (default 1, at most 40)"),
                    ("--interval <ms>", "Time between frames (default 250, from 100 to 1000)"),
                    ("--context", "Also capture the screen around the live preview, so it shows over what is behind it (same as adding 'context' to --window)"),
                    ("--margin <pt>", "Points around the preview in a context capture (default 48, at most 400)"),
                    ("--out <dir>", "Copy the PNGs into this folder (default: they stay in the private temp folder 'screenshot' uses, pruned after 30 minutes)")
                ],
                notes: [
                    "Needs the user: Debug capture is off by default and only they can turn it on, in UseMac → Settings → Developer. While it is off this fails with DEBUG_CAPTURE_OFF (exit 4): ask the user, don't look for another route. No command, method or MCP tool turns it on.",
                    "Values out of range are brought into range; 'Notes:' (notes in JSON) says so. A context capture leaves out apps the user's rules block. The Kill Switch and Paused block it (POLICY_BLOCKED); without the app it fails with DAEMON_REQUIRED.",
                    "When none of the windows asked for is on screen it fails with CAPTURE_FAILED. The live preview shows while a task runs ('usemac start'); only the user opens Settings."
                ],
                examples: [
                    "usemac debug capture --window preview --context",
                    "usemac debug capture --window preview --frames 12 --interval 100 --out ./hud-frames",
                    "usemac debug capture --window settings --json"
                ],
                json: "DebugCaptureResult {window, frames, intervalMs, directory, latencyMs, notes, images: [{path, kind, title, windowId, frame {x, y, width, height}, width, height, byteCount, frameIndex, offsetMs}]}"
            )
        case "serve":
            return CommandHelp(
                usage: ["usemac serve [--socket <path>]"],
                summary: "Run the Unix socket RPC daemon in this process (for testing; UseMac.app normally runs it, with the Kill Switch and execution mode).",
                examples: ["usemac serve --socket /tmp/usemac-test.sock"]
            )
        case "mcp":
            return CommandHelp(
                usage: ["usemac mcp"],
                summary: "Start the stdio MCP server. Register it in your agent's MCP config as {\"command\": \"<path to usemac>\", \"args\": [\"mcp\"]}.",
                examples: ["claude mcp add --scope user usemac -- \"/Applications/UseMac.app/Contents/Helpers/usemac\" mcp"]
            )
        case "menu":
            return CommandHelp(
                usage: [
                    "usemac menu [--app <name|pid>] [--query <text>]",
                    "usemac menu --app <name> --invoke \"File > Export as PDF…\""
                ],
                summary: "Search or invoke native macOS application menu bar items in the background without stealing focus.",
                flags: [
                    ("--app <name|pid>", "Target app (default: paired or frontmost app)"),
                    ("--query <text>", "Substring filter when listing menu items"),
                    ("--invoke <path>", "Menu path to invoke (e.g. \"File > Save\" or JSON array)"),
                    waitForLeaseHelp
                ],
                examples: ["usemac menu --app Notes --query export", "usemac menu --app Notes --invoke \"File > Export as PDF…\""],
                json: "AppMenuResult {app, items, invokedPath, message}"
            )
        case "browser batch":
            return CommandHelp(
                usage: ["usemac browser batch <url1> [<url2> ...] [--profile <name>] [--mode observe|extract] [--extract-mode <m>] [--max-elements <n>] [--auto-dismiss] [--close-after]"],
                summary: "Open and observe or extract multiple URLs concurrently in parallel background Chrome tabs.",
                flags: [
                    ("--profile <name>", "Chrome profile name"),
                    ("--mode <observe|extract>", "Batch mode (default extract)"),
                    ("--extract-mode <m>", "Extract mode when mode=extract (auto, tables, text, kpis, network)"),
                    ("--max-elements <n>", "Maximum DOM elements per tab when observing"),
                    ("--auto-dismiss", "Auto-dismiss cookie/modal overlays on each tab"),
                    ("--close-after", "Close batch tabs automatically after extraction")
                ],
                examples: ["usemac browser batch https://a.test https://b.test --mode extract --close-after"],
                json: "BrowserBatchResult {results, totalLatencyMs}"
            )
        case "skill":
            return CommandHelp(
                usage: ["usemac skill <list|save|run|delete> [arguments]"],
                summary: "Persist and deterministically replay parameterized ({{param}}) automation workflows.",
                flags: skillSubcommands,
                notes: ["Run 'usemac help skill <subcommand>' for flags."],
                examples: ["usemac skill list", "usemac skill run export-pdf --params '{\"name\":\"q4\"}'"]
            )
        case "skill list":
            return CommandHelp(
                usage: ["usemac skill list [--query <q>] [--kind browser|native] [--app <name>] [--url <url>]"],
                summary: "List saved automation skills.",
                examples: ["usemac skill list --kind browser"],
                json: "SkillListResult {skills}"
            )
        case "skill save":
            return CommandHelp(
                usage: ["usemac skill save <name> '<steps-json>'|- [--description <text>] [--kind browser|native] [--app <name>] [--url-pattern <glob>] [--delete]"],
                summary: "Save or update a reusable automation skill.",
                examples: ["usemac skill save search-docs '[{\"action\":\"setValue\",\"selector\":\"#q\",\"text\":\"{{query}}\" }]' --kind browser"],
                json: "SkillListResult {saved}"
            )
        case "skill run":
            return CommandHelp(
                usage: ["usemac skill run <name> [--params '{\"k\":\"v\"}'] [--app <name>] [--profile <name>] [--tab <id>] [--mode <m>] [--diff-only]"],
                summary: "Deterministically replay a saved skill through UseMac's governed action pipeline.",
                flags: [waitForLeaseHelp],
                examples: ["usemac skill run search-docs --params '{\"query\":\"hooks\"}' --tab 123"],
                json: "SkillRunResult {name, success, actionResult, totalLatencyMs, message}"
            )
        case "install-skill":
            return CommandHelp(
                usage: ["usemac install-skill [--workspace] [--dir <path>] [--force] [--dry-run]"],
                summary: "Install the usemac SKILL.md, stamped with this Mac's binary and socket path, into every detected agent skills folder.",
                flags: [
                    ("--workspace, -w", "Install into .agents/skills in the current folder"),
                    ("--dir <path>, -d", "Install into this skills folder"),
                    ("--force", "Replace a SKILL.md that does not belong to UseMac"),
                    ("--dry-run", "Show the target paths without writing")
                ],
                examples: ["usemac install-skill"],
                json: "{ok, binary, targets: [{path, status}]}"
            )
        case "bench":
            return CommandHelp(
                usage: ["usemac bench [--iterations <n>] [--app <name>]"],
                summary: "Measure ping, list_apps and observe latency (cold and hot cache).",
                flags: [
                    ("--iterations <n>", "Ping iterations (default 100)"),
                    ("--app <name>", "App to observe")
                ],
                examples: ["usemac bench --app \"Notes\""]
            )
        case "help":
            return CommandHelp(
                usage: ["usemac help [<command> [<subcommand>]]", "usemac <command> --help"],
                summary: "Show the overview, or usage, flags and an example for one command.",
                examples: ["usemac help act", "usemac help browser open"]
            )
        case "version":
            return CommandHelp(
                usage: ["usemac --version"],
                summary: "Print the CLI version.",
                examples: ["usemac --version"]
            )
        default:
            return nil
        }
    }

    static func printHelp(for path: [String]) throws -> Int32 {
        guard let command = path.first else {
            printUsage()
            return 0
        }
        let key = path.count > 1 ? "\(command) \(path[1])" : command
        guard let help = commandHelp(key) else {
            if path.count > 1, commandHelp(command) != nil {
                throw CLIError.usage("Unknown \(command) subcommand: '\(path[1])'. Run 'usemac help \(command)'.")
            }
            throw CLIError.usage("Unknown command: '\(command)'. Run 'usemac help' to see available commands.")
        }

        var lines: [String] = ["usemac \(key) — \(help.summary)", "", "Usage:"]
        lines.append(contentsOf: help.usage.map { "  \($0)" })
        if !help.flags.isEmpty {
            let isGroup = key == "browser" || key == "vision" || key == "debug" || key == "skill"
            lines.append("")
            lines.append(isGroup ? "Subcommands:" : "Flags:")
            let width = min(28, help.flags.map(\.0.count).max() ?? 0)
            for (flag, text) in help.flags {
                let padded = flag.count >= width ? flag + "  " : flag.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                lines.append("  \(padded)\(text)")
            }
        }
        if !help.notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: help.notes.map { "  - \($0)" })
        }
        if !help.examples.isEmpty {
            lines.append("")
            lines.append(help.examples.count == 1 ? "Example:" : "Examples:")
            lines.append(contentsOf: help.examples.map { "  \($0)" })
        }
        if let json = help.json {
            lines.append("")
            lines.append("JSON (--json): \(json)")
            lines.append("Errors with --json: {\"ok\":false,\"error\":{\"code\",\"message\",\"hint\"}}. Exit codes: run 'usemac help'.")
        }
        print(lines.joined(separator: "\n"))
        return 0
    }
}
