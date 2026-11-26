# Shared by the scroll-event and scroll-fallback cases: native background scrolling of web content in a Chrome
# window UseMac opened. Native observe finds the page's rows; the page's real position (window.scrollY) is read
# through the extension, because Chrome stops rendering a window that other windows cover, so the page's own
# "scrollY=<n>" indicator (updated on scroll events) can lag behind.
#
# A second UseMac window with the same page, opened after the target (so usually on top of it), stands in for the
# user's windows: the scroll must not move it, and no wheel event may reach it.

# scroll_ready <window title>: the page is in the native tree, with rows out of view below the fold.
scroll_ready() {
  observe_window "Google Chrome" "$1" || return 1
  local rows offscreen
  rows=$(jout '[.elements[] | select(((.title // "") + " " + (.value // "")) | test("Row [0-9]+"))] | length')
  offscreen=$(jout '[.elements[] | select(.offscreen == true)] | length')
  [ "${rows:-0}" -ge 5 ] && [ "${offscreen:-0}" -ge 1 ]
}

# page_eval <tabId> <expression>: the expression's value in the tab, read through the extension.
page_eval() {
  um browser extract eval --tab "$1" --expr "$2" || return 1
  jout '.jsonResult // empty' | tr -d '"[:space:]'
}

page_scroll_y() { page_eval "$1" "Math.round(window.scrollY)"; }
page_wheels() { page_eval "$1" "window.__smokeWheels"; }

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

# run_scroll_case <lock>: lock=0 serves a plain page, where either background path may move it: the wheel event
# posted to Chrome (cgevent-pid-scroll) or, when Chrome ignores it, the next offscreen element scrolled into view
# (ax-scroll-to-next). lock=1 serves a page that swallows wheel events, so only the fallback can move it.
run_scroll_case() {
  local lock=$1 title="usemac-smoke-$SMOKE_CASE-$SMOKE_TOKEN" other_title="usemac-smoke-$SMOKE_CASE-control-$SMOKE_TOKEN"
  skip_if_chrome_in_front
  task_start "background scrolling ($SMOKE_CASE)"
  defer 'unpin_window "Google Chrome"'

  open_tab "$TASK_ID" "$SMOKE_BASE/scroll.html?lock=$lock&t=$title" --new-window
  local tab=$TAB_ID
  require_own_window "$tab"
  open_tab "$TASK_ID" "$SMOKE_BASE/scroll.html?lock=0&t=$other_title" --new-window
  local other=$TAB_ID
  require_own_window "$other"

  wait_until 15 scroll_ready "$title" \
    || fail "native observe of the window never showed the page's rows with some out of view: $(um_error)"
  local before other_before
  before=$(page_scroll_y "$tab")
  [ "$before" = "0" ] || fail "the page did not start at the top (window.scrollY: '${before:-unreadable}')"
  other_before=$(page_scroll_y "$other")
  [ "$other_before" = "0" ] || fail "the control window did not start at the top (window.scrollY: '${other_before:-unreadable}')"

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
  local after shown visibility other_after other_wheels
  after=$(page_scroll_y "$tab")
  shown=$(indicator_y "$title")
  visibility=$(page_eval "$tab" "document.visibilityState")
  other_after=$(page_scroll_y "$other")
  other_wheels=$(page_wheels "$other")
  smoke_log "after the step: window.scrollY=${after:-?} (indicator ${shown:-?}, page ${visibility:-?}); control window scrollY=${other_after:-?}, wheel events=${other_wheels:-?}"
  local seen="mechanism $mech, effect $effect, scrollDeltaY ${delta:-none}, warning: ${warning:-none}, page ${visibility:-?}"

  # What matters: the target page moved, and nothing reached the other window.
  [ -n "$after" ] && [ "$after" -gt 0 ] 2>/dev/null \
    || fail "the page did not move: window.scrollY is still ${after:-unreadable} ($seen)"
  [ "$other_after" = "0" ] \
    || fail "the scroll moved the control window too (its window.scrollY is ${other_after:-unreadable}; $seen)"
  [ "$other_wheels" = "0" ] \
    || fail "${other_wheels:-unreadable} wheel event(s) reached the control window ($seen)"

  # And the step reported a background path, consistently with what happened.
  case "$mech" in
    ax-scroll-to-next)
      [ "$effect" = "changed" ] || fail "the fallback moved the page but reported effect '$effect' ($seen)"
      ;;
    cgevent-pid-scroll)
      [ "$lock" = 0 ] \
        || fail "a page that swallows wheel events moved after a wheel event, which it cannot ($seen, window.scrollY $after)"
      awk -v d="${delta:-0}" 'BEGIN { exit !(d >= 1 || d <= -1) }' \
        || fail "the page moved to window.scrollY $after but the step reported no movement ($seen)"
      ;;
    *)
      fail "expected a background scroll (cgevent-pid-scroll or ax-scroll-to-next), got $seen"
      ;;
  esac

  task_done "$TASK_ID" --summary "smoke: $SMOKE_CASE done" || fail "done failed: $(um_error)"
  note "$mech moved the page to window.scrollY=$after; the control window stayed at 0 with no wheel events"
}
