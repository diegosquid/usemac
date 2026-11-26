# Helpers for the smoke cases in scripts/smoke/cases/. scripts/smoke.sh sources this file, then the case file,
# in a fresh subshell per case, and calls the case's smoke_case function. Written for macOS's bash 3.2.
#
# Results:  fail "<reason>"  (exit 1)  ·  skip "<reason>"  (exit 77)  ·  note "<text>"  ·  return normally to pass.
# Cleanup:  defer '<command>' runs at exit in reverse order, even after fail or a timeout. Tasks started with
#           task_start are finished, and tabs opened with open_tab are checked and closed, after the defers.
#
# Environment from smoke.sh: USEMAC_CLI, SMOKE_CASE, SMOKE_CASE_DIR, SMOKE_TOKEN, SMOKE_BASE (the local page
# server, empty when no case needs Chrome), SMOKE_EXT_VERSION, SMOKE_FORCE_EXT, SMOKE_REPO.

SMOKE_DEFERRED=()
SMOKE_OPEN_TASKS=""
SMOKE_TABS=""
SMOKE_IN_CLEANUP=0
SMOKE_CMD_SEQ=0
UM_OUT=""
UM_RC=0
TASK_ID=""
TAB_ID=""

# Everything the helpers log goes to stderr (the case log), so a function that prints a value can run in $(...) even
# when it calls um.
smoke_log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# --- Results ---------------------------------------------------------------------------------------------------

fail() {
  if [ "$SMOKE_IN_CLEANUP" = 1 ]; then
    smoke_log "cleanup problem: $*"
    return 1
  fi
  [ -s "$SMOKE_CASE_DIR/reason" ] || printf '%s\n' "$*" > "$SMOKE_CASE_DIR/reason"
  smoke_log "FAIL: $*"
  exit 1
}

skip() {
  printf '%s\n' "$*" > "$SMOKE_CASE_DIR/reason"
  smoke_log "SKIP: $*"
  exit 77
}

note() {
  printf '%s\n' "$*" >> "$SMOKE_CASE_DIR/notes"
  smoke_log "note: $*"
}

# Something the case could not clean up (an open tab, a file). It turns a pass into a fail.
leak() {
  printf '%s\n' "$*" >> "$SMOKE_CASE_DIR/leaks"
  smoke_log "LEAK: $*"
}

# --- Cleanup ---------------------------------------------------------------------------------------------------

defer() { SMOKE_DEFERRED[${#SMOKE_DEFERRED[@]}]="$*"; }

smoke_on_exit() {
  local rc=$? i id
  trap - EXIT TERM INT HUP
  set +e
  SMOKE_IN_CLEANUP=1
  smoke_log "cleanup (exit $rc)"
  i=$(( ${#SMOKE_DEFERRED[@]} - 1 ))
  while [ "$i" -ge 0 ]; do
    smoke_log "cleanup: ${SMOKE_DEFERRED[$i]}"
    eval "${SMOKE_DEFERRED[$i]}" || smoke_log "cleanup step failed: ${SMOKE_DEFERRED[$i]}"
    i=$(( i - 1 ))
  done
  for id in $SMOKE_OPEN_TASKS; do
    task_done "$id" --summary "smoke: $SMOKE_CASE cleanup" || smoke_log "cleanup: done --task $id failed"
  done
  close_leftover_tabs
  exit "$rc"
}

smoke_init() {
  trap smoke_on_exit EXIT
  trap 'smoke_log "interrupted (timeout or Ctrl-C)"; [ -s "$SMOKE_CASE_DIR/reason" ] || echo "interrupted" > "$SMOKE_CASE_DIR/reason"; exit 124' TERM INT HUP
}

# --- Running usemac --------------------------------------------------------------------------------------------

# um <args...>: runs `usemac --json <args...>`. Sets UM_OUT (stdout) and UM_RC (exit code) and logs both; the
# full output also goes to cmd-NN.json in the case folder. UM_QUIET=1 keeps the output out of the log (tab lists
# hold the user's own tab titles).
um() {
  # The counter lives in a file, so calls made in $(...) subshells get their own numbers too.
  SMOKE_CMD_SEQ=$(( $(cat "$SMOKE_CASE_DIR/.seq" 2>/dev/null || echo 0) + 1 ))
  echo "$SMOKE_CMD_SEQ" > "$SMOKE_CASE_DIR/.seq"
  local seq
  seq=$(printf '%02d' "$SMOKE_CMD_SEQ")
  smoke_log "\$ usemac $*"
  UM_OUT="$("$USEMAC_CLI" --json "$@" 2>"$SMOKE_CASE_DIR/cmd-$seq.stderr")"
  UM_RC=$?
  if [ "${UM_QUIET:-0}" != 1 ]; then
    printf '%s\n' "$UM_OUT" > "$SMOKE_CASE_DIR/cmd-$seq.json"
    if [ "${#UM_OUT}" -gt 1500 ]; then
      printf '%s… (%d chars, cmd-%s.json)\n' "${UM_OUT:0:1500}" "${#UM_OUT}" "$seq" >&2
    else
      printf '%s\n' "$UM_OUT" >&2
    fi
  fi
  [ -s "$SMOKE_CASE_DIR/cmd-$seq.stderr" ] && sed 's/^/  stderr: /' "$SMOKE_CASE_DIR/cmd-$seq.stderr" >&2
  smoke_log "exit $UM_RC"
  return "$UM_RC"
}

# The error of the last um call, as "CODE: message".
um_error() {
  local e
  e=$(printf '%s' "$UM_OUT" | jq -r 'if type == "object" and .error then "\(.error.code // "?"): \(.error.message // "")" else empty end' 2>/dev/null)
  if [ -n "$e" ]; then printf '%s' "${e:0:400}"; else printf 'exit %s: %s' "$UM_RC" "$(printf '%s' "$UM_OUT" | head -c 300)"; fi
}

um_error_code() { printf '%s' "$UM_OUT" | jq -r '.error.code // empty' 2>/dev/null; }

# um_ok <args...>: um, and fail the case when the command fails.
um_ok() {
  um "$@" || fail "usemac $1 ${2:-} failed: $(um_error)"
}

# jout <jq filter> [jq options...]: reads the last um output.
jout() {
  local filter=$1
  shift
  printf '%s' "$UM_OUT" | jq -r "$@" "$filter" 2>/dev/null
}

# --- Waiting and versions --------------------------------------------------------------------------------------

# wait_until <seconds> <command...>: retries the command every 0.5 s until it succeeds or the time is up.
wait_until() {
  local deadline=$(( $(date +%s) + $1 ))
  shift
  while :; do
    "$@" && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.5
  done
}

# A sortable key for "0.6.0", "0.6.0 beta 2" or "0.6.0-beta.2": a release sorts after its pre-releases.
ver_key() {
  printf '%s\n' "$1" | awk '{
    s = tolower($0)
    if (!match(s, /^[0-9]+(\.[0-9]+)*/)) { print "00000.00000.00000.a00000"; exit }
    core = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
    n = split(core, p, ".")
    key = ""
    for (i = 1; i <= 3; i++) key = key sprintf("%05d.", (i <= n) ? p[i] : 0)
    gsub(/^[^a-z0-9]+/, "", rest)
    if (rest == "") { print key "z"; exit }
    num = 0
    if (match(rest, /[0-9]+/)) num = substr(rest, RSTART, RLENGTH)
    print key substr(rest, 1, 1) sprintf("%05d", num)
  }'
}

# ver_ge <a> <b>: a >= b.
ver_ge() {
  local a b
  a=$(ver_key "$1")
  b=$(ver_key "$2")
  [[ "$a" > "$b" || "$a" == "$b" ]]
}

# ext_older_than <version>: the connected extension is older (only true in a --force-ext run of a gated case).
ext_older_than() { ! ver_ge "${SMOKE_EXT_VERSION:-0}" "$1"; }

# --- Tasks and tabs --------------------------------------------------------------------------------------------

# task_start <summary> [start flags...]: `usemac start`, sets TASK_ID. The cleanup finishes it if the case does not.
task_start() {
  local summary=$1
  shift
  um_ok start --summary "smoke: $summary" "$@"
  TASK_ID=$(jout '.taskId // empty')
  [ -n "$TASK_ID" ] || fail "start returned no taskId (this UseMac predates task-owned tabs, #31)"
  SMOKE_OPEN_TASKS="$SMOKE_OPEN_TASKS $TASK_ID"
}

# task_done <taskId> [done flags...]: `usemac done --task <taskId>`.
task_done() {
  local id=$1 rest="" t
  shift
  for t in $SMOKE_OPEN_TASKS; do [ "$t" = "$id" ] || rest="$rest $t"; done
  SMOKE_OPEN_TASKS=$rest
  um done --task "$id" "$@"
}

# open_tab <taskId> <url> [browser open flags...]: opens a tab for the task, sets TAB_ID. The cleanup makes sure it
# is closed.
open_tab() {
  local task=$1 url=$2
  shift 2
  TAB_ID=""
  um browser open "$url" --task "$task" "$@"
  local rc=$UM_RC
  TAB_ID=$(jout '.browserTabId // empty')
  if [ "$rc" -ne 0 ] && [ "$(um_error_code)" = "EXTENSION_NOT_CONNECTED" ]; then
    # The bridge dropped mid-command (it reconnects on its own, for example after UseMac relaunched). The tab may
    # have opened anyway: wait for the extension, then fail with the tab tracked so the cleanup closes it.
    local first_error
    first_error=$(um_error)
    wait_until 15 extension_connected
    load_tabs && TAB_ID=$(printf '%s' "$SMOKE_ALL_TABS" | jq -r --arg u "$url" 'first(.[] | select(.url == $u) | .tabId) // empty')
    [ -n "$TAB_ID" ] && SMOKE_TABS="$SMOKE_TABS $TAB_ID"
    fail "the Chrome extension disconnected during browser open ($first_error)"
  fi
  [ -n "$TAB_ID" ] && SMOKE_TABS="$SMOKE_TABS $TAB_ID"
  [ "$rc" -eq 0 ] || fail "browser open $url failed: $(um_error)"
  [ -n "$TAB_ID" ] || fail "browser open $url returned no tab id"
}

extension_connected() {
  UM_QUIET=1 um browser status || return 1
  [ "$(jout 'length')" -ge 1 ] 2>/dev/null
}

# load_tabs: reads every Chrome tab into SMOKE_ALL_TABS without logging them (they include the user's own tabs).
load_tabs() {
  UM_QUIET=1 um browser tabs || return 1
  SMOKE_ALL_TABS=$UM_OUT
}

# tab_info <tabId> <field>: a field of one tab from the last load_tabs ("" when the tab is not open).
tab_info() {
  printf '%s' "${SMOKE_ALL_TABS:-[]}" | jq -r --argjson id "$1" --arg f "$2" '(map(select(.tabId == $id)) | first | .[$f]) // empty' 2>/dev/null
}

tab_is_open() { load_tabs && [ -n "$(tab_info "$1" tabId)" ]; }
tab_is_gone() { load_tabs && [ -z "$(tab_info "$1" tabId)" ]; }

# tabs_in_window <windowId>: how many tabs that window has, from the last load_tabs.
tabs_in_window() {
  printf '%s' "${SMOKE_ALL_TABS:-[]}" | jq -r --argjson w "$1" 'map(select(.windowId == $w)) | length' 2>/dev/null
}

# require_own_window <tabId>: the tab is alone in its window, i.e. the extension honored --new-window. Extensions
# older than 0.6.0 beta 1 ignore it and open a background tab in the user's window instead.
require_own_window() {
  load_tabs || fail "browser tabs failed: $(um_error)"
  local win count
  win=$(tab_info "$1" windowId)
  [ -n "$win" ] || fail "tab $1 is not open"
  count=$(tabs_in_window "$win")
  [ "$count" = 1 ] || fail "tab $1 opened in a window with $count tabs: the extension ignored --new-window (needs 0.6.0 beta 1 or later)"
}

# close_tab_by_script <tabId>: the fallback when task cleanup did not close a tab (an old extension has no tab
# cleanup). A tab with one history entry may close itself with window.close().
close_tab_by_script() {
  um browser extract eval --tab "$1" --expr "window.close()"
  wait_until 3 tab_is_gone "$1"
}

# own_page_tabs: ids of open tabs showing a smoke test page (a local page named with t=usemac-smoke-...), from the
# last load_tabs. Catches tabs whose browser open failed before it returned an id, and strays of an earlier run.
own_page_tabs() {
  printf '%s' "${SMOKE_ALL_TABS:-[]}" | jq -r \
    '.[] | select((.url // "") | test("^http://(127\\.0\\.0\\.1|localhost):[0-9]+/[a-z-]+\\.html\\?(.*&)?t=usemac-smoke-")) | .tabId' \
    2>/dev/null
}

# Runs at exit: every tab the case opened must be gone shortly after its task finished.
close_leftover_tabs() {
  local id deadline still
  deadline=$(( $(date +%s) + 6 ))
  while :; do
    still=""
    load_tabs || break
    for id in $SMOKE_TABS; do [ -n "$(tab_info "$id" tabId)" ] && still="$still $id"; done
    for id in $(own_page_tabs); do
      case " $still " in *" $id "*) ;; *) still="$still $id" ;; esac
    done
    [ -z "$still" ] && return 0
    [ -z "$(printf '%s' "$SMOKE_TABS" | tr -d ' ')" ] && break   # nothing of ours to wait for: sweep strays now
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.5
  done
  for id in $still; do
    smoke_log "tab $id is still open after its task finished; closing it with window.close()"
    if close_tab_by_script "$id"; then
      note "tab $id did not close with its task; closed it with window.close()"
    else
      leak "Chrome tab $id is still open"
    fi
  done
}

# unpin_window <app>: observe and act with --window pin that window for later requests. Observing a window that does
# not exist clears the pin without reading any other window.
unpin_window() {
  um observe --app "$1" --window "usemac-smoke-unpin-$SMOKE_TOKEN"
  return 0
}

# chrome_in_front: Chrome is the active app. Native steps on Chrome then send real input to whatever window is on top
# instead of taking the background paths, and task cleanup keeps a UseMac window that became Chrome's focused window.
chrome_in_front() {
  UM_QUIET=1 um status || return 1
  [ "$(jout '.frontmostApp.bundleId // empty')" = "com.google.Chrome" ]
}

# skip_if_chrome_in_front: the native Chrome cases only run while another app is in front.
skip_if_chrome_in_front() {
  if chrome_in_front; then
    skip "Chrome is the active app, so native steps would send real input instead of the background path (it could land in your own window); bring another app to the front and rerun"
  fi
}

# --- Native observe helpers ------------------------------------------------------------------------------------

# observe_window <app> <window title> [observe flags...]: a live observe of that window (no cache).
observe_window() {
  local app=$1 win=$2
  shift 2
  um observe --app "$app" --window "$win" --no-cache --max-depth 40 --max-elements 600 "$@"
}

# first_element <jq condition> <jq field>: that field of the first element of the last observe matching the condition.
first_element() {
  jout "[.elements[] | select($1)] | first | $2 // empty"
}
