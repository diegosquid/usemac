#!/usr/bin/env bash
# Live smoke run: drives the installed UseMac app through its CLI against TextEdit and local pages in Chrome, and
# prints PASS, FAIL or SKIP for each case. Run it before every release (docs/SMOKE.md).
#
#   scripts/smoke.sh                  run every case
#   scripts/smoke.sh --list           list the cases
#   scripts/smoke.sh --only upload    run one case (repeat --only, or separate names with commas)
#
# Exit code: 0 when nothing failed, 1 when a case failed, 2 when the run could not start (usage, daemon, policy).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SMOKE_ROOT="$HERE/smoke"
export SMOKE_REPO="$(cd "$HERE/.." && pwd)"
export USEMAC_CLI="${USEMAC_CLI:-/Applications/UseMac.app/Contents/Helpers/usemac}"
DEFAULT_TIMEOUT="${SMOKE_CASE_TIMEOUT:-120}"

usage() {
  cat <<EOF
Usage: scripts/smoke.sh [--list] [--only <case>[,<case>]] [--force-ext] [--verbose]

  --list         List the cases with what they need, and exit
  --only <case>  Run only these cases (repeatable, or comma-separated)
  --force-ext    Also run cases that need a newer Chrome extension than the one connected
  --verbose      Stream each case's log while it runs (logs are always kept on disk)

Environment:
  USEMAC_CLI           usemac binary to drive (default: /Applications/UseMac.app/Contents/Helpers/usemac)
  SMOKE_CASE_TIMEOUT   Seconds before a case is stopped and failed (default: 120)
EOF
}

LIST=0
ONLY=""
FORCE_EXT=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --only)
      [ $# -ge 2 ] || { echo "smoke: --only needs a case name" >&2; exit 2; }
      ONLY="$ONLY,$2"
      shift
      ;;
    --only=*) ONLY="$ONLY,${1#--only=}" ;;
    --force-ext) FORCE_EXT=1 ;;
    -v | --verbose) VERBOSE=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "smoke: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { echo "smoke: $*" >&2; exit 2; }

# --- Cases -----------------------------------------------------------------------------------------------------

case_name() { basename "$1" .sh | sed -E 's/^[0-9]+-//'; }

# Prints a case's needs, minimum extension, timeout and description, separated by \x1f. Case files only set variables
# and define functions at the top level, so sourcing them has no side effects.
case_meta() {
  (
    SMOKE_DESC="" SMOKE_NEEDS="" SMOKE_MIN_EXT="" SMOKE_TIMEOUT=""
    # shellcheck source=/dev/null
    . "$1"
    printf '%s\037%s\037%s\037%s\n' "$SMOKE_NEEDS" "$SMOKE_MIN_EXT" "$SMOKE_TIMEOUT" "$SMOKE_DESC"
  )
}

CASE_FILES=()
for f in "$SMOKE_ROOT"/cases/*.sh; do
  [ -f "$f" ] && CASE_FILES[${#CASE_FILES[@]}]="$f"
done
[ ${#CASE_FILES[@]} -gt 0 ] || die "no cases in $SMOKE_ROOT/cases"

selected() {
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

if [ -n "$ONLY" ]; then
  for want in $(printf '%s' "$ONLY" | tr ',' ' '); do
    found=0
    for f in "${CASE_FILES[@]}"; do [ "$(case_name "$f")" = "$want" ] && found=1; done
    [ "$found" = 1 ] || die "unknown case '$want' (see --list)"
  done
fi

if [ "$LIST" = 1 ]; then
  printf '%-18s %-15s %-17s %s\n' CASE NEEDS EXTENSION DESCRIPTION
  for f in "${CASE_FILES[@]}"; do
    IFS=$'\037' read -r needs minext _ desc <<<"$(case_meta "$f")"
    printf '%-18s %-15s %-17s %s\n' "$(case_name "$f")" "${needs:--}" "${minext:+>= $minext}" "$desc"
  done
  exit 0
fi

# --- Preflight -------------------------------------------------------------------------------------------------

command -v jq >/dev/null || die "needs jq (macOS 15 ships /usr/bin/jq)"
command -v python3 >/dev/null || die "needs python3 for the local page server"
[ -x "$USEMAC_CLI" ] || die "no usemac CLI at $USEMAC_CLI (install UseMac, or set USEMAC_CLI)"
"$USEMAC_CLI" --require-daemon ping >/dev/null 2>&1 || die "the UseMac daemon is not answering: open UseMac and try again"

STATUS_JSON="$("$USEMAC_CLI" --json status 2>/dev/null)" || die "usemac status failed"
APP_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.version // "?"')
POLICY=$(printf '%s' "$STATUS_JSON" | jq -r '.policy // "?"')
[ "$(printf '%s' "$STATUS_JSON" | jq -r '.killSwitchTripped')" = "false" ] || die "the kill switch is tripped: reset it in UseMac first"
[ "$(printf '%s' "$STATUS_JSON" | jq -r '.permissions.accessibilityGranted')" = "true" ] || die "UseMac has no Accessibility permission"
[ "$POLICY" = "autonomous" ] || die "the execution mode is '$POLICY'; the smoke run needs autonomous (it uploads a file and runs page scripts)"

EXT_JSON="$("$USEMAC_CLI" --json browser status 2>/dev/null)" || EXT_JSON="[]"
export SMOKE_EXT_VERSION=$(printf '%s' "$EXT_JSON" | jq -r 'if type == "array" and length > 0 then (.[0].extensionVersion // "unknown") else empty end' 2>/dev/null)
export SMOKE_FORCE_EXT=$FORCE_EXT
export SMOKE_TOKEN=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usemac-smoke.XXXXXX")" || die "mktemp failed"
export SMOKE_RUN_DIR="$RUN_DIR"

# shellcheck source=smoke/lib.sh
. "$SMOKE_ROOT/lib.sh"   # for ver_ge

SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}
trap 'stop_server' EXIT
trap 'stop_server; exit 130' INT TERM

needs_chrome=0
for f in "${CASE_FILES[@]}"; do
  selected "$(case_name "$f")" || continue
  case "$(case_meta "$f" | cut -d $'\037' -f1)" in *chrome*) needs_chrome=1 ;; esac
done
export SMOKE_BASE=""
if [ "$needs_chrome" = 1 ] && [ -n "$SMOKE_EXT_VERSION" ]; then
  python3 -I "$SMOKE_ROOT/server.py" --root "$SMOKE_ROOT/pages" --port-file "$RUN_DIR/port" 2>"$RUN_DIR/server.log" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$RUN_DIR/port" ] && break; sleep 0.1; done
  [ -s "$RUN_DIR/port" ] || die "the local page server did not start (see $RUN_DIR/server.log)"
  SMOKE_BASE="http://127.0.0.1:$(cat "$RUN_DIR/port")"
fi

echo "UseMac smoke run: app $APP_VERSION ($USEMAC_CLI), policy $POLICY"
if [ -n "$SMOKE_EXT_VERSION" ]; then
  echo "Chrome extension: $SMOKE_EXT_VERSION$([ "$FORCE_EXT" = 1 ] && echo ' (--force-ext: version gates off)')"
else
  echo "Chrome extension: not connected (Chrome cases skip)"
fi
[ -n "$SMOKE_BASE" ] && echo "Test pages: $SMOKE_BASE"
echo "Logs: $RUN_DIR"
echo

# --- Run -------------------------------------------------------------------------------------------------------

PASSED=0
FAILED=0
SKIPPED=0
RUN_START=$SECONDS

join_lines() { [ -s "$1" ] && awk 'NR > 1 { printf "; " } { printf "%s", $0 }' "$1"; }

report() { # report <result> <name> <seconds> <reason>
  printf '%-5s %-18s %4ss  %s\n' "$1" "$2" "$3" "$4"
  case "$1" in PASS) PASSED=$((PASSED + 1)) ;; FAIL) FAILED=$((FAILED + 1)) ;; SKIP) SKIPPED=$((SKIPPED + 1)) ;; esac
}

run_case() { # run_case <file> <name> <timeout>
  local file=$1 name=$2 timeout=$3 dir="$RUN_DIR/$2" pid wd tailpid="" rc
  mkdir -p "$dir"
  (
    set +u
    export SMOKE_CASE="$name" SMOKE_CASE_DIR="$dir"
    # shellcheck source=smoke/lib.sh
    . "$SMOKE_ROOT/lib.sh"
    # shellcheck source=/dev/null
    . "$file"
    smoke_init
    smoke_case
  ) >"$dir/log" 2>&1 </dev/null &
  pid=$!
  # Watchdog: stop the case after <timeout> seconds; its trap still cleans up.
  (
    t=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      t=$((t + 1))
      if [ "$t" -ge "$timeout" ]; then
        echo "timed out after ${timeout}s" >"$dir/timeout"
        kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 1 45); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; done
        kill -KILL "$pid" 2>/dev/null
        exit 0
      fi
    done
  ) >/dev/null 2>&1 &
  wd=$!
  if [ "$VERBOSE" = 1 ]; then
    tail -n +1 -f "$dir/log" | sed "s/^/  [$name] /" &
    tailpid=$!
  fi
  wait "$pid"
  rc=$?
  wait "$wd" 2>/dev/null
  if [ -n "$tailpid" ]; then
    sleep 0.3
    kill "$tailpid" 2>/dev/null
    wait "$tailpid" 2>/dev/null
  fi
  CASE_RC=$rc
}

for f in "${CASE_FILES[@]}"; do
  name=$(case_name "$f")
  selected "$name" || continue
  IFS=$'\037' read -r needs minext timeout _ <<<"$(case_meta "$f")"
  timeout=${timeout:-$DEFAULT_TIMEOUT}

  case "$needs" in
    *chrome*)
      if [ -z "$SMOKE_EXT_VERSION" ]; then
        report SKIP "$name" 0 "the Chrome extension is not connected"
        continue
      fi
      if [ -n "$minext" ] && ! ver_ge "$SMOKE_EXT_VERSION" "$minext" && [ "$FORCE_EXT" != 1 ]; then
        report SKIP "$name" 0 "needs Chrome extension $minext or later (connected: $SMOKE_EXT_VERSION)"
        continue
      fi
      ;;
  esac
  case "$needs" in
    *textedit*)
      if [ ! -d /System/Applications/TextEdit.app ]; then
        report SKIP "$name" 0 "TextEdit is not installed"
        continue
      fi
      ;;
  esac

  started=$SECONDS
  run_case "$f" "$name" "$timeout"
  took=$((SECONDS - started))
  dir="$RUN_DIR/$name"
  reason=$(head -n 1 "$dir/reason" 2>/dev/null)
  notes=$(join_lines "$dir/notes")
  leaks=$(join_lines "$dir/leaks")
  if [ -s "$dir/timeout" ]; then
    report FAIL "$name" "$took" "$(cat "$dir/timeout")${reason:+ ($reason)}"
  elif [ "$CASE_RC" -eq 0 ] && [ -n "$leaks" ]; then
    report FAIL "$name" "$took" "passed but left something behind: $leaks"
  elif [ "$CASE_RC" -eq 0 ]; then
    report PASS "$name" "$took" "$notes"
  elif [ "$CASE_RC" -eq 77 ]; then
    report SKIP "$name" "$took" "$reason"
  else
    report FAIL "$name" "$took" "${reason:-exit $CASE_RC, see $dir/log}${leaks:+; also left behind: $leaks}"
  fi
done

# A case stopped hard (after its timeout) skips its own cleanup: close any test page still open.
if [ -n "$SMOKE_BASE" ]; then
  mkdir -p "$RUN_DIR/_sweep"
  (
    set +u
    export SMOKE_CASE=_sweep SMOKE_CASE_DIR="$RUN_DIR/_sweep"
    . "$SMOKE_ROOT/lib.sh"
    close_leftover_tabs
  ) >"$RUN_DIR/_sweep/log" 2>&1
  if [ -s "$RUN_DIR/_sweep/leaks" ]; then
    report FAIL "(final sweep)" 0 "left behind: $(join_lines "$RUN_DIR/_sweep/leaks")"
  elif [ -s "$RUN_DIR/_sweep/notes" ]; then
    echo "note: the final sweep closed test tabs a case left open ($(join_lines "$RUN_DIR/_sweep/notes"))"
  fi
fi

echo
echo "smoke: $PASSED passed, $FAILED failed, $SKIPPED skipped in $((SECONDS - RUN_START))s (app $APP_VERSION, extension ${SMOKE_EXT_VERSION:-none}). Logs: $RUN_DIR"
[ "$FAILED" -eq 0 ]
