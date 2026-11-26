# Shared by the scroll-event and scroll-fallback cases: native background scrolling of web content in a Chrome
# window UseMac opened. The page shows window.scrollY in a fixed "scrollY=<n>" element, read through native observe.

# scroll_ready <window title>: the page is in the native tree, with rows out of view below the fold.
scroll_ready() {
  observe_window "Google Chrome" "$1" || return 1
  local rows offscreen
  rows=$(jout '[.elements[] | select(((.title // "") + " " + (.value // "")) | test("Row [0-9]+"))] | length')
  offscreen=$(jout '[.elements[] | select(.offscreen == true)] | length')
  [ "${rows:-0}" -ge 5 ] && [ "${offscreen:-0}" -ge 1 ]
}

# scroll_position: the page's scrollY from the last observe ("" when the indicator is not in the tree).
scroll_position() {
  jout '[.elements[] | ((.title // "") + " " + (.value // "")) | capture("scrollY=(?<y>[0-9]+)") | .y] | first // empty'
}

scrolled_past_top() {
  observe_window "Google Chrome" "$1" || return 1
  local y
  y=$(scroll_position)
  [ -n "$y" ] && [ "$y" -gt 0 ]
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
  before=$(scroll_position)
  [ "$before" = "0" ] || fail "the page did not start at the top (scrollY indicator: '${before:-missing}')"

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

  wait_until 4 scrolled_past_top "$title"
  local after
  after=$(scroll_position)

  if [ "$lock" = 1 ]; then
    [ "$mech" = "ax-scroll-to-next" ] \
      || fail "expected the ax-scroll-to-next fallback on a page that ignores the wheel, got mechanism $mech (effect $effect, scrollY ${after:-?})"
    [ "$effect" = "changed" ] || fail "the fallback reported effect '$effect', expected changed"
  else
    [ "$mech" = "cgevent-pid-scroll" ] \
      || fail "expected the background wheel event (cgevent-pid-scroll), got mechanism $mech (effect $effect, warning: ${warning:-none}, scrollY ${after:-?})"
    awk -v d="${delta:-0}" 'BEGIN { exit !(d >= 1 || d <= -1) }' \
      || fail "the wheel event reported no movement (scrollDeltaY ${delta:-none}, warning: ${warning:-none})"
  fi
  [ -n "$after" ] && [ "$after" -gt 0 ] || fail "the page did not move: scrollY is still ${after:-unknown} after a $mech step"

  task_done "$TASK_ID" --summary "smoke: $SMOKE_CASE done" || fail "done failed: $(um_error)"
  note "$mech moved the page to scrollY=$after"
}
