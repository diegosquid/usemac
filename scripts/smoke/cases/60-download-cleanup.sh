# Tab cleanup after task_complete while a download runs: the tab that started the download stays open, and another tab
# of the task closes. The local server sends the file slowly (about 12 s); the case deletes the file afterwards.

SMOKE_DESC="Chrome: done keeps the tab of a running download open"
SMOKE_NEEDS="chrome"
SMOKE_MIN_EXT="0.6.0-beta.1"
SMOKE_TIMEOUT=90

DL_NAME=""
DL_SIZE=524288
DL_SECONDS=12

# download_field <field>: that field of our download in `browser extract downloads` ("" when not listed).
download_field() {
  UM_QUIET=1 um browser extract downloads || return 1
  printf '%s' "$UM_OUT" | jq -r --arg n "$DL_NAME" --arg f "$1" \
    '[(.downloads // [])[] | select(((.url // "") | contains($n)) or ((.filename // "") | contains($n)))] | first | .[$f] // empty'
}

download_state_is() { [ "$(download_field state)" = "$1" ]; }

# The local server logs every request (smoke.sh keeps its log next to the case logs).
server_saw_download() { grep -q "GET /download/$DL_NAME" "$SMOKE_RUN_DIR/server.log" 2>/dev/null; }

# Stops the server's transfer (if still running) and deletes what Chrome wrote, final file or partial download.
delete_download() {
  [ -n "$DL_NAME" ] || return 0
  [ -n "$SMOKE_BASE" ] && curl -s -o /dev/null -m 3 "$SMOKE_BASE/cancel/$DL_NAME"
  sleep 1
  local reported dir f
  reported=$(download_field filename)
  for dir in "$(dirname "${reported:-/nonexistent/x}")" "$HOME/Downloads"; do
    [ -d "$dir" ] || continue
    for f in "$dir/$DL_NAME" "$dir/$DL_NAME.crdownload"; do
      if [ -f "$f" ]; then
        rm -f "$f" && smoke_log "deleted $f"
      fi
    done
  done
  for f in "$HOME/Downloads/$DL_NAME" "$HOME/Downloads/$DL_NAME.crdownload"; do
    [ -e "$f" ] && leak "downloaded file $f"
  done
  return 0
}

smoke_case() {
  DL_NAME="usemac-smoke-$SMOKE_TOKEN.bin"
  task_start "download during task_complete"
  defer 'delete_download'

  open_tab "$TASK_ID" "$SMOKE_BASE/download.html?t=usemac-smoke-download-$SMOKE_TOKEN&name=$DL_NAME&seconds=$DL_SECONDS&size=$DL_SIZE"
  local tab=$TAB_ID
  # A control tab on another origin (localhost, not 127.0.0.1): the download does not protect it, so done must close
  # it. Without it, an extension with no tab cleanup at all would pass this case.
  open_tab "$TASK_ID" "${SMOKE_BASE/127.0.0.1/localhost}/tab.html?t=usemac-smoke-control-$SMOKE_TOKEN"
  local control=$TAB_ID
  um_ok browser act '[{"action":"click","selector":"#dl"}]' --tab "$tab"
  if ! wait_until 4 download_state_is in_progress && ! server_saw_download; then
    # The click reported success but never reached the link (the server saw no request). Not what this case checks,
    # so click once more and say so.
    note "the first click on the link reported success ($(jout '.stepResults[0].mechanism // empty')) but started nothing; clicked again"
    um_ok browser act '[{"action":"click","selector":"#dl"}]' --tab "$tab"
  fi
  if ! wait_until 6 download_state_is in_progress; then
    server_saw_download \
      && fail "Chrome requested the file but lists no running download (is it set to ask where to save each file?)"
    fail "clicking the download link started no download (the server saw no request)"
  fi

  task_done "$TASK_ID" --summary "smoke: download task done" || fail "done failed: $(um_error)"
  # The cleanup runs about 2 s after done; check after it.
  sleep 4
  download_state_is in_progress || fail "the download ended before the check ($(download_field state)); the check proves nothing"
  tab_is_open "$tab" || fail "done closed tab $tab while its download was still running"
  tab_is_gone "$control" || fail "done did not close the control tab $control (no tab cleanup ran)"

  wait_until 25 download_state_is complete || fail "the download did not complete (state: $(download_field state))"
  local path size
  path=$(download_field filename)
  size=$(stat -f %z "$path" 2>/dev/null)
  [ "$size" = "$DL_SIZE" ] || fail "the downloaded file $path has ${size:-no} bytes, expected $DL_SIZE"

  # The kept tab stays open after the download; close it ourselves.
  close_tab_by_script "$tab" || fail "could not close the download tab $tab"
  note "done closed the control tab and kept tab $tab while its download ran; the file arrived whole and was deleted"
}
