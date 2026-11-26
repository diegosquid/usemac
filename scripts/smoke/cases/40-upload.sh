# uploadFile in Chrome with files created seconds before, in $TMPDIR (where the native file picker's Spotlight search
# cannot find them; the extension sets the file input directly). First through an <input type=file> in the page,
# then through an input created on click, where UseMac has to intercept Chrome's file chooser.

SMOKE_DESC="Chrome: uploadFile with a file created seconds before (page input, then intercepted chooser)"
SMOKE_NEEDS="chrome"

# upload_shown <tab> <selector> <expected text>: the page read the uploaded file and shows its name, size and text.
upload_shown() {
  um browser extract text --tab "$1" --selector "$2" || return 1
  case "$(jout '.text // empty')" in *"$3"*) return 0 ;; esac
  return 1
}

# upload_once <tab> <selector> <file> <output selector> <expected mechanism>
upload_once() {
  local tab=$1 selector=$2 file=$3 out=$4 want=$5 name size content
  name=$(basename "$file")
  size=$(stat -f %z "$file")
  content=$(cat "$file")
  um_ok browser act "$(jq -nc --arg s "$selector" --arg f "$file" '[{action: "uploadFile", selector: $s, files: [$f]}]')" --tab "$tab"
  [ "$(jout '.success')" = "true" ] || fail "uploadFile on $selector failed: $(jout '.stepResults[0].message // empty')"
  UPLOAD_MECH=$(jout '.stepResults[0].mechanism // empty')
  [ "$UPLOAD_MECH" = "$want" ] || fail "uploadFile on $selector used $UPLOAD_MECH, expected $want"
  wait_until 5 upload_shown "$tab" "$out" "name=$name size=$size text=$content" \
    || fail "the page did not receive $name through $selector (it shows: $(jout '.text // empty'))"
}

smoke_case() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/usemac-smoke-upload.XXXXXX") || fail "mktemp failed"
  defer "rm -rf '$dir'"

  task_start "uploadFile"
  local first="$dir/usemac-smoke-$SMOKE_TOKEN-a.txt" second="$dir/usemac-smoke-$SMOKE_TOKEN-b.txt" created
  printf 'smoke upload %s first %s\n' "$SMOKE_TOKEN" "$(date +%s)" > "$first"
  created=$(date +%s)

  open_tab "$TASK_ID" "$SMOKE_BASE/upload.html?t=usemac-smoke-upload-$SMOKE_TOKEN"
  local tab=$TAB_ID age
  sleep 1
  age=$(( $(date +%s) - created ))
  upload_once "$tab" "#f" "$first" "#out" "cdp-file-input"
  local mech1=$UPLOAD_MECH

  printf 'smoke upload %s second %s\n' "$SMOKE_TOKEN" "$(date +%s)" > "$second"
  sleep 1
  upload_once "$tab" "#dyn" "$second" "#out2" "cdp-file-chooser"
  local mech2=$UPLOAD_MECH

  task_done "$TASK_ID" --summary "smoke: uploadFile done" || fail "done failed: $(um_error)"
  note "files ${age}s and 1s old: $mech1, then $mech2"
}
