# Two tasks at once (#31): `done --task A` closes task A's tab and leaves task B's tab open; `done --task B` then
# closes B's.

SMOKE_DESC="Chrome: done --task A closes only task A's tab, never task B's (#31)"
SMOKE_NEEDS="chrome"
# Tab cleanup with keepTabIds arrived in extension 0.6.0 beta 1.
SMOKE_MIN_EXT="0.6.0-beta.1"

smoke_case() {
  task_start "two tasks: A"
  local a=$TASK_ID
  task_start "two tasks: B"
  local b=$TASK_ID
  [ "$a" != "$b" ] || fail "both starts returned the same taskId ($a)"

  open_tab "$a" "$SMOKE_BASE/tab.html?t=usemac-smoke-task-a-$SMOKE_TOKEN"
  local tab_a=$TAB_ID
  open_tab "$b" "$SMOKE_BASE/tab.html?t=usemac-smoke-task-b-$SMOKE_TOKEN"
  local tab_b=$TAB_ID

  task_done "$a" --summary "smoke: task A done" || fail "done --task $a failed: $(um_error)"
  # The cleanup runs about 2 s after done.
  wait_until 6 tab_is_gone "$tab_a" || fail "done --task A did not close task A's tab $tab_a"
  sleep 1
  tab_is_open "$tab_b" || fail "done --task A closed task B's tab $tab_b"

  task_done "$b" --summary "smoke: task B done" || fail "done --task $b failed: $(um_error)"
  wait_until 6 tab_is_gone "$tab_b" || fail "done --task B did not close its own tab $tab_b"
  note "A's done closed tab $tab_a only; B's done closed tab $tab_b"
}
