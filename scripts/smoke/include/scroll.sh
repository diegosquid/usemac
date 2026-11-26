# Shared by the scroll-event and scroll-fallback cases: native background scrolling of web content in a Chrome
# window UseMac opened. Native observe finds the page's rows; the page's real position (window.scrollY) is read
# through the extension, because Chrome stops rendering a window that other windows cover, so the page's own
# "scrollY=<n>" indicator (updated on scroll events) can lag behind.

# scroll_ready <window title>: the page is in the native tree, with rows out of view below the fold.
scroll_ready() {
  observe_window "Google Chrome" "$1" || return 1
  local rows offscreen
  rows=$(jout '[.elements[] | select(((.title // "") + " " + (.value // "")) | test("Row [0-9]+"))] | length')
  offscreen=$(jout '[.elements[] | select(.offscreen == true)] | length')
  [ "${rows:-0}" -ge 5 ] && [ "${offscreen:-0}" -ge 1 ]
}

# page_scroll_y <tabId>: window.scrollY of the tab, read through the extension.
page_scroll_y() {
  um browser extract eval --tab "$1" --expr "Math.round(window.scrollY)" || return 1
  jout '.jsonResult // empty' | tr -d '"[:space:]'
}

# indicator_y <window title>: what the page's indicator says in the native tree (for the log only).
indicator_y() {
  observe_window "Google Chrome" "$1" --text "scrollY=" || return 1
  jout '[.elements[] | ((.title // "") + " " + (.value // "")) | capture("scrollY=(?<y>[0-9]+)") | .y] | first // empty'
}

page_moved() {
  local y
  y=$(page_scroll_y "$1")
  [ -n "$y" ] && [ "$y" -gt 0 ] 2>/dev/null
}

# run_scroll_case <lock>: lock=0 expects the wheel event to move the page; lock=1 serves a page that swallows wheel
# events, so UseMac must fall back to scrolling the next offscreen element into view.
run_scroll_case() {
  local lock=$1 title="usemac-smoke-$SMOKE_CASE-$SMOKE_TOKEN"
  skip_if_chrome_in_front
  task_start "background scrolling ($SMOKE_CASE)"
  defer 'unpin_window "Google Chrome"'

  open_tab "$TASK_ID" "$SMOKE_BASE/scroll.html?lock=$lock&t=$title" --new-window
  local tab=$TAB_ID
  require_own_window "$tab"

  wait_until 15 scroll_ready "$title" \
    || fail "native observe of the window never showed the page's rows with some out of view: $(um_error)"
  local before
  before=$(page_scroll_y "$tab")
  [ "$before" = "0" ] || fail "the page did not start at the top (window.scrollY: '${before:-unreadable}')"

  # The act must follow the observe directly: its stale-window check compares against the last observe.
  observe_window "Google Chrome" "$title" || fail "observe --window $title failed: $(um_error)"
  skip_if_chrome_in_front
  um_ok act '[{"action":"scroll","deltaY":-600}]' --app "Google Chrome" --window "$title"
  local ok mech effect delta warning
  ok=$(jout '.stepResults[0].success')
  mech=$(jout '.stepResults[0].mechanism // empty')
  effect=$(jout '.stepResults[0].effect // empty')
  delta=$(jout '.stepResults[0].scrollDeltaY // empty')
  warning=$(jout '.stepResults[0].warning // empty')
  smoke_log "scroll: success=$ok mechanism=$mech effect=$effect scrollDeltaY=$delta warning=$warning"
  [ "$ok" = "true" ] || fail "the scroll step failed: $(jout '.stepResults[0].message // empty')"

  wait_until 4 page_moved "$tab"
  local after shown
  after=$(page_scroll_y "$tab")
  shown=$(indicator_y "$title")
  smoke_log "after the step: window.scrollY=${after:-?}, indicator scrollY=${shown:-?}"
  local visibility
  um browser extract eval --tab "$tab" --expr "document.visibilityState"
  visibility=$(jout '.jsonResult // empty' | tr -d '"')
  local seen="mechanism $mech, effect $effect, scrollDeltaY ${delta:-none}, warning: ${warning:-none}, page ${visibility:-?}"

  [ -n "$after" ] && [ "$after" -gt 0 ] 2>/dev/null \
    || fail "the page did not move: window.scrollY is still ${after:-unreadable} ($seen)"
  if [ "$lock" = 1 ]; then
    [ "$mech" = "ax-scroll-to-next" ] \
      || fail "expected the ax-scroll-to-next fallback on a page that ignores the wheel ($seen, window.scrollY $after)"
    [ "$effect" = "changed" ] || fail "the fallback moved the page but reported effect '$effect' ($seen)"
  else
    [ "$mech" = "cgevent-pid-scroll" ] \
      || fail "expected the background wheel event, cgevent-pid-scroll ($seen, window.scrollY $after)"
    awk -v d="${delta:-0}" 'BEGIN { exit !(d >= 1 || d <= -1) }' \
      || fail "the page moved to window.scrollY $after but the step reported no movement ($seen)"
  fi

  task_done "$TASK_ID" --summary "smoke: $SMOKE_CASE done" || fail "done failed: $(um_error)"
  note "$mech moved the page to window.scrollY=$after"
}
