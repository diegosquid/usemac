# Live smoke run

`scripts/smoke.sh` drives the installed UseMac app through its CLI, against TextEdit and local test pages in
Google Chrome, and prints PASS, FAIL or SKIP for each case. It covers the paths that unit tests can't check in a
real browser. Run it before every release, on the build you are about to ship. A full run takes about 90 seconds.

## Before you run it

- UseMac is installed in `/Applications`, running, and has Accessibility and Screen Recording permission. The
  execution mode is **Autonomous** (the run uploads a file and runs page scripts), and the kill switch is not
  tripped. The script checks all of this first and stops with exit code 2 if something is missing.
- Chrome is open, and the UseMac Browser Bridge extension is connected and reloaded, so that it matches the build.
  Chrome cases skip when no extension is connected. When a case needs a newer extension than the connected one, it
  also skips and says which version it needs.
- Chrome is not the app in front (run the script from your terminal). With Chrome in front, UseMac sends real input
  instead of taking the background paths these cases check, so `scroll-event`, `scroll-fallback` and
  `restricted-page` skip.
- The Mac is online. The `restricted-page` case opens the Chrome Web Store, and it skips when the store doesn't
  answer.
- TextEdit is best left closed. The case then launches its own TextEdit in the background and quits it at the end.
  If TextEdit is open, the case opens a new document with ⌘N and only types into it if it is empty.
- Chrome saves downloads without asking (the default). The `download-cleanup` case downloads a 512 KB file to your
  downloads folder and deletes it afterwards.

## Run it

```bash
scripts/smoke.sh                       # every case
scripts/smoke.sh --list                # the cases and what each needs
scripts/smoke.sh --only upload         # some cases (repeat --only, or separate names with commas)
scripts/smoke.sh --verbose             # stream each case's log while it runs
USEMAC_CLI=dist/UseMac.app/Contents/Helpers/usemac scripts/smoke.sh   # another usemac binary
```

The exit code is 0 when no case failed, 1 when one did, and 2 when the run could not start. Each case has a log
in the folder printed at the top and the end of the run, with every `usemac` command and its JSON output. Native
observes of Chrome include the browser's own toolbars, so these logs can show your bookmark and tab group names; they
stay on your Mac. `--force-ext` also runs the cases gated on a newer extension, to see how they fail on the
connected one.

| Case | What it checks |
| --- | --- |
| `textedit` | Native basics: observe an untitled document, type into it in the background, read the text back, close it without saving. |
| `scroll-event` | Native background scroll of a page in a UseMac Chrome window. The page moves, through the wheel event (`cgevent-pid-scroll`) or the offscreen-element fallback (`ax-scroll-to-next`), and a second UseMac window gets neither scrolled nor any wheel event. |
| `scroll-fallback` | The same on a page that swallows wheel events, so only the fallback (`ax-scroll-to-next`) can move it. |
| `restricted-page` | The background leg of the hybrid flow: open the Chrome Web Store with `browser open --new-window`, confirm `browser observe` returns `RESTRICTED_PAGE`, then observe the visible Chrome window and write to the search box natively with `--window`. |
| `upload` | `uploadFile` in Chrome with files created a second before in `$TMPDIR`: into a file input on the page, then through an intercepted file chooser. |
| `two-tasks` | Two tasks at once: `done --task A` closes A's tab and leaves B's open. |
| `download-cleanup` | Click a download link and verify the transfer started. Run `done` while it is active: its tab stays open, the control tab closes, and the download finishes at the expected size. |

For `restricted-page`, keep the Chrome window visible on screen even though Chrome is not the frontmost app.
Outside this background-only smoke case, if native observe shows only the toolbar or `setValue` reports
`effect: none`, use native `act --foreground` on the pinned window. UseMac briefly focuses it, acts, and restores
the previous focus.

The `download-cleanup` case checks transfer and tab state, not just click success. A `browser_act` click may
report a warning if it didn't reach the page or the link produced no observable effect. UseMac does not
automatically retry; the smoke script can explicitly click once more if there is no sign the transfer started.

## What it touches

Every Chrome case runs in its own task (`usemac start`, `--task`, `done --task`), on pages served from
`scripts/smoke/pages/` by a server on 127.0.0.1 that the script starts and stops. Native work happens only in Chrome
windows UseMac opened. Every case cleans up after itself, even when it fails or times out: it finishes its tasks,
closes its tabs and windows, closes its TextEdit document without saving, and deletes the files it created or
downloaded. A case that passes but leaves something open is reported as a FAIL. Before and after the cases, the run
also closes any smoke test page an earlier, interrupted run left open.

## Adding a case

Add a file `scripts/smoke/cases/NN-name.sh`. The number sets the order, and the case is called `name`. At the top
level it sets only variables, and it defines `smoke_case`:

```bash
SMOKE_DESC="Chrome: what this checks, in one line"
SMOKE_NEEDS="chrome"              # chrome and/or textedit
SMOKE_MIN_EXT="0.6.0-beta.1"      # optional: oldest extension that has the feature
SMOKE_TIMEOUT=60                  # optional, seconds (default 120)

smoke_case() {
  task_start "what the task does"
  open_tab "$TASK_ID" "$SMOKE_BASE/tab.html?t=usemac-smoke-mine-$SMOKE_TOKEN"
  um_ok browser observe --tab "$TAB_ID"
  [ "$(jout '.elements | length')" -gt 0 ] || fail "the page has no elements"
  task_done "$TASK_ID" || fail "done failed: $(um_error)"
}
```

The helpers are in `scripts/smoke/lib.sh`: `um` and `um_ok` run `usemac --json`, `jout` reads the JSON, `fail`,
`skip` and `note` report, `defer` registers cleanup, and `wait_until` polls. Tasks from `task_start` and tabs from
`open_tab` are cleaned up for you.
