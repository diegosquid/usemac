# Native basics in TextEdit: observe, type into an untitled document, read the text back, close without saving.
# It launches its own TextEdit in the background when TextEdit is not running (and quits it afterwards). When
# TextEdit is already running it opens a new document with ⌘N and only types into it if the document is empty.

SMOKE_DESC="TextEdit: observe, type into an untitled document, read it back, close without saving"
SMOKE_NEEDS="textedit"
SMOKE_TIMEOUT=90

TE_LAUNCHED=0
TE_PID=""
TE_TITLE=""

# Titles of the buttons that discard an unsaved document in the close sheet, in the languages macOS ships most.
TE_DISCARD_TITLES='["Delete","Don’t Save","Don'"'"'t Save","Apagar","Excluir","Não Salvar","Não salvar","Supprimer","Ne pas enregistrer","Löschen","Nicht sichern","Eliminar","No guardar"]'

te_observe() { observe_window TextEdit "$TE_TITLE"; }

te_has_text_area() {
  um observe --app TextEdit --no-cache --max-depth 30 --max-elements 300 || return 1
  [ -n "$(first_element '.role == "AXTextArea"' '.id')" ]
}

te_window_gone() {
  um observe --app TextEdit --window "$TE_TITLE" --no-cache --max-depth 4
  [ "$(um_error_code)" = "ELEMENT_NOT_FOUND" ] || [ "$(um_error_code)" = "APP_NOT_FOUND" ]
}

# Closes the document window without saving: its close button (or ⌘W), then the discard button of the sheet.
te_close_without_saving() {
  [ -n "$TE_TITLE" ] || return 0
  te_window_gone && return 0
  te_observe || return 1
  local close
  close=$(first_element '.role == "AXButton" and (((.roleDescription // "") | test("close|fechar|fermer|schließen|cerrar"; "i")) or ((.title // "") | test("^(close|fechar)$"; "i")))' '.id')
  if [ -n "$close" ]; then
    um click "$close" --app TextEdit --allow-stale
  else
    um key cmd+w --app TextEdit
  fi
  local i discard=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    te_window_gone && return 0
    if te_observe; then
      discard=$(first_element ".role == \"AXButton\" and ((.title // \"\") as \$t | $TE_DISCARD_TITLES | index(\$t))" '.id')
      [ -n "$discard" ] && break
    fi
    sleep 0.3
  done
  if [ -n "$discard" ]; then
    um click "$discard" --app TextEdit --allow-stale
  else
    # ⌘⌫ is the discard button's shortcut in the sheet.
    um key cmd+delete --app TextEdit
  fi
  wait_until 5 te_window_gone
}

te_quit() { ! kill -0 "$TE_PID" 2>/dev/null; }

te_cleanup() {
  if ! te_close_without_saving; then
    leak "TextEdit window \"$TE_TITLE\" is still open (close it without saving)"
    return 1
  fi
  unpin_window TextEdit
  if [ "$TE_LAUNCHED" = 1 ] && [ -n "$TE_PID" ]; then
    # The smoke run launched this TextEdit, restored no windows, and closed its document: quitting loses nothing.
    um key cmd+q --app TextEdit
    if ! wait_until 4 te_quit; then
      kill -TERM "$TE_PID" 2>/dev/null
      wait_until 3 te_quit || leak "TextEdit (pid $TE_PID, launched by the smoke run) is still running"
    fi
  fi
}

smoke_case() {
  local text="UseMac smoke $SMOKE_TOKEN typed in the background"

  task_start "TextEdit basics" --app TextEdit
  defer 'task_done "$TASK_ID" --app TextEdit --keep-tabs --summary "smoke: TextEdit done"'
  defer 'te_cleanup'

  if pgrep -x TextEdit >/dev/null; then
    smoke_log "TextEdit is already running: opening a new document with ⌘N"
    um_ok key cmd+n --app TextEdit
    sleep 1
  else
    TE_LAUNCHED=1
    # A background launch straight into an untitled document: no open panel and no restored windows. These
    # arguments only apply to this launch; no setting changes.
    open -g -a TextEdit --args -NSShowAppCentricOpenPanelInsteadOfUntitledFile NO -ApplePersistenceIgnoreState YES \
      || fail "could not launch TextEdit"
    wait_until 10 pgrep -x TextEdit >/dev/null || fail "TextEdit did not start"
    TE_PID=$(pgrep -x TextEdit | head -n 1)
  fi

  # 1. Observe: the untitled document and its text area.
  wait_until 10 te_has_text_area || fail "observe never showed a TextEdit document with a text area: $(um_error)"
  TE_TITLE=$(jout '.app.windowTitle // empty')
  [ -n "$TE_TITLE" ] || fail "observe did not report the window title"
  local area value
  area=$(first_element '.role == "AXTextArea"' '.id')
  value=$(first_element '.role == "AXTextArea"' '.value')
  [ -z "$value" ] || {
    TE_TITLE=""   # not our document: leave it alone
    skip "the focused TextEdit document is not empty, so it may be yours; quit TextEdit and run again"
  }
  smoke_log "document \"$TE_TITLE\", text area $area"

  # 2. Type into it, in the background.
  te_observe || fail "observe --window \"$TE_TITLE\" failed: $(um_error)"
  um_ok act "$(jq -nc --arg t "$text" '[{action: "type", text: $t, match: {role: "AXTextArea"}}]')" --app TextEdit --window "$TE_TITLE"
  [ "$(jout '.success')" = "true" ] || fail "type failed: $(jout '.stepResults[0].message // .agentFeedback.diagnosis // empty')"
  local mech effect
  mech=$(jout '.stepResults[0].mechanism // empty')
  effect=$(jout '.stepResults[0].effect // empty')

  # 3. Read it back from the live tree.
  read_back() { te_observe && [ "$(first_element '.role == "AXTextArea"' '.value')" = "$text" ]; }
  wait_until 4 read_back || fail "the text area reads \"$(first_element '.role == "AXTextArea"' '.value')\", expected \"$text\" (type mechanism $mech, effect $effect)"
  um_ok find --app TextEdit --role AXTextArea --value "$SMOKE_TOKEN"
  [ "$(jout '.count')" -ge 1 ] 2>/dev/null || fail "find --value did not match the typed text"

  # 4. Close it without saving.
  te_close_without_saving || fail "the document window did not close without saving"
  note "typed with $mech (effect $effect), read back, closed without saving"
}
