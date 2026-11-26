# The RESTRICTED_PAGE hybrid flow. Chrome lets no extension script the Chrome Web Store, so it is the one http(s)
# page that answers RESTRICTED_PAGE (UseMac refuses chrome:// URLs by design, and only allows http, https and
# about:blank). The case opens the store in a new UseMac window, checks that the extension refuses it, then observes
# and acts on it natively with --window: it types into the store's search box without submitting it.

SMOKE_DESC="Chrome: RESTRICTED_PAGE hybrid flow on the Chrome Web Store (new window, native observe/act)"
SMOKE_NEEDS="chrome network"
SMOKE_MIN_EXT="0.6.0-beta.1"
SMOKE_TIMEOUT=100

STORE_URL="https://chromewebstore.google.com/"

# page_field: id of the first text field inside the page (the AXWebArea), from the last observe. The window's first
# text field is Chrome's address bar, which must not be touched.
page_field() {
  jout '(.elements | map(.role) | index("AXWebArea")) as $i
    | if $i == null then empty else
        (.elements[$i].frame.y) as $top
        | [.elements[$i:][] | select((.role == "AXTextField" or .role == "AXComboBox" or .role == "AXSearchField")
            and .frame.y >= $top)] | first | .id // empty
      end'
}

store_ready() {
  observe_window "Google Chrome" "$1" || return 1
  [ -n "$(page_field)" ]
}

store_field_value() {
  observe_window "Google Chrome" "$1" || return 1
  [ "$(printf '%s' "$UM_OUT" | jq -r --arg id "$2" 'first(.elements[] | select(.id == $id) | .value // empty)')" = "$3" ]
}

store_titled() {
  load_tabs || return 1
  local t
  t=$(tab_info "$1" title)
  [ -n "$t" ] && [ "${t#http}" = "$t" ]
}

# No script can close a store tab (window.close() is a page script), so when its task's cleanup kept it, move it to
# one of our pages and let a second, empty task's cleanup close it.
STORE_TAB=""
store_cleanup() {
  [ -n "$STORE_TAB" ] || return 0
  wait_until 4 tab_is_gone "$STORE_TAB" && return 0
  smoke_log "the store tab $STORE_TAB is still open; navigating it away and sweeping with another task"
  um browser open "$SMOKE_BASE/tab.html?t=usemac-smoke-store-cleanup-$SMOKE_TOKEN" --tab "$STORE_TAB"
  um start --summary "smoke: restricted page cleanup"
  local sweep
  sweep=$(jout '.taskId // empty')
  [ -n "$sweep" ] && um done --task "$sweep" --summary "smoke: restricted page cleanup"
  if wait_until 6 tab_is_gone "$STORE_TAB"; then
    note "the store window did not close with its task; a second task's cleanup closed it"
  fi
  return 0
}

smoke_case() {
  curl -s -o /dev/null -m 8 "$STORE_URL" || skip "no network: $STORE_URL did not answer"
  skip_if_chrome_in_front

  task_start "RESTRICTED_PAGE hybrid flow"
  defer 'unpin_window "Google Chrome"'
  defer 'store_cleanup'

  if ext_older_than "0.6.0-beta.1"; then
    # Forced run on an old extension: it may ignore --new-window and open the store as a background tab in the
    # user's window, where nothing could close it again. Probe with one of our own pages first.
    open_tab "$TASK_ID" "$SMOKE_BASE/tab.html?t=usemac-smoke-probe-$SMOKE_TOKEN" --new-window
    local probe=$TAB_ID
    require_own_window "$probe"
  fi

  # 1. browser open --new-window answers with the restricted-page guidance instead of a DOM snapshot.
  open_tab "$TASK_ID" "$STORE_URL" --new-window
  local tab=$TAB_ID trigger
  STORE_TAB=$tab
  trigger=$(jout '.snapshot.agentFeedback.trigger // empty')
  [ "$trigger" = "restricted_page" ] \
    || fail "browser open did not flag the store as restricted (agentFeedback.trigger: ${trigger:-none})"
  require_own_window "$tab"

  # 2. The extension refuses to observe it: RESTRICTED_PAGE, exit code 7.
  um browser observe --tab "$tab"
  [ "$UM_RC" = 7 ] && [ "$(um_error_code)" = "RESTRICTED_PAGE" ] \
    || fail "browser observe on the store: expected RESTRICTED_PAGE (exit 7), got exit $UM_RC $(um_error_code)"

  # 3. Native observe of the window. Its title is the tab's title, so it must not be shared by a window of yours.
  wait_until 20 store_titled "$tab" || fail "the store tab never got a title"
  local title others
  title=$(tab_info "$tab" title)
  others=$(printf '%s' "$SMOKE_ALL_TABS" | jq -r --argjson id "$tab" --arg t "$title" \
    '[.[] | select(.tabId != $id and .active == true and ((.title // "") | contains($t)))] | length')
  [ "${others:-0}" = 0 ] || skip "another Chrome window shows a tab titled \"$title\"; close it so --window finds only the smoke window"
  wait_until 25 store_ready "$title" || fail "native observe of \"$title\" never showed the store's search box: $(um_error)"
  local count field
  count=$(jout '.elements | length')
  field=$(page_field)
  smoke_log "store search box: $field ($(jout 'first(.elements[] | select(.id == $id) | "\(.role) \(.title // "")")' --arg id "$field"))"

  # 4. Native act in that window: type a query into the search box (not submitted), then read it back.
  skip_if_chrome_in_front
  local query="usemac smoke $SMOKE_TOKEN"
  um_ok act "$(jq -nc --arg id "$field" --arg t "$query" '[{action: "setValue", elementId: $id, text: $t}]')" \
    --app "Google Chrome" --window "$title"
  [ "$(jout '.success')" = "true" ] || fail "native setValue in the store failed: $(jout '.stepResults[0].message // empty')"
  local mech
  mech=$(jout '.stepResults[0].mechanism // empty')
  wait_until 4 store_field_value "$title" "$field" "$query" \
    || fail "the store's search box does not read back \"$query\" after $mech"

  # 5. done closes the window, restricted page or not.
  task_done "$TASK_ID" --summary "smoke: restricted page done" || fail "done failed: $(um_error)"
  wait_until 6 tab_is_gone "$tab" || fail "done did not close the store window (tab $tab)"
  note "observed $count elements natively in \"$title\", setValue via $mech"
}
