#!/usr/bin/env bash
# Reproducible UseMac benchmarks. The method and the published numbers are in README.md → Benchmarks.
#
#   scripts/bench.sh [--app <name>] [--url <url>]... [--vision "<assertion>"] [--iterations <n>] [--out <dir>]
#                    [--count-tokens]
#
# 1. Local IPC: `usemac bench` against the running UseMac daemon (ping, list_apps, and observe of --app).
# 2. What an agent reads per look, for each --url (a background Chrome tab, its screenshot fit to 1280x800) and for
#    --app (a native window): the text UseMac returns (`usemac browser observe` / `usemac observe`, the same text the
#    MCP tools return) next to a screenshot of the same view (`usemac browser screenshot` / `usemac screenshot`).
# 3. With --vision: `usemac vision verify "<assertion>"` on the first --url tab, three times, answered by the
#    on-device model (needs `usemac vision install` first). The first run can include loading the model.
#
# scripts/bench-tokens.py turns the captures into token counts. They are estimates unless you pass --count-tokens,
# which sends the captures to Anthropic's count_tokens endpoint (needs ANTHROPIC_API_KEY) for exact counts.
#
# Needs UseMac.app running with Accessibility and Screen Recording, and the Chrome extension for --url. Everything is
# read-only. The --url tabs belong to one UseMac task, and `usemac done --task` closes them at the end.
# Name an app with --app: without it, `usemac bench` observes whatever app is in front.
set -euo pipefail

USEMAC="${USEMAC:-/Applications/UseMac.app/Contents/Helpers/usemac}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITERATIONS=1000
APP=""
URLS=()
VISION=""
OUT=""
TOKEN_FLAGS=()
# Every web screenshot is scaled down to fit the same box, so the image numbers compare across runs and machines.
# UseMac never resizes the tab, so the text depends on the size of the Chrome window it opens in.
VIEW_W=1280
VIEW_H=800

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?--app needs a name}"; shift 2 ;;
    --url) URLS+=("${2:?--url needs a URL}"); shift 2 ;;
    --vision) VISION="${2:?--vision needs an assertion}"; shift 2 ;;
    --iterations) ITERATIONS="${2:?--iterations needs a number}"; shift 2 ;;
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    --count-tokens) TOKEN_FLAGS+=(--count-tokens); shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done
if [[ -n "$VISION" && ${#URLS[@]} -eq 0 ]]; then
  echo "bench.sh: --vision needs at least one --url" >&2
  exit 2
fi

OUT="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/usemac-bench.XXXXXX")}"
VIEWS="$OUT/views"
mkdir -p "$VIEWS"

if ! "$USEMAC" --require-daemon ping >/dev/null 2>&1; then
  echo "bench.sh: the UseMac daemon is not reachable. Open UseMac.app first." >&2
  exit 3
fi

BENCH_ARGS=(--require-daemon --json bench --iterations "$ITERATIONS")
if [[ -n "$APP" ]]; then BENCH_ARGS+=(--app "$APP"); fi
{
  echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "chip: $(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB)"
  echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "UseMac: $("$USEMAC" --version)"
  echo "command: usemac ${BENCH_ARGS[*]}"
} > "$OUT/machine.txt"

echo "bench.sh: IPC, ${ITERATIONS} pings" >&2
"$USEMAC" "${BENCH_ARGS[@]}" > "$OUT/ipc.json"

TASK=""
finish() {
  if [[ -n "$TASK" ]]; then
    "$USEMAC" done --task "$TASK" --summary "Benchmark finished" >/dev/null 2>&1 || true
  fi
}
trap finish EXIT

FIRST_TAB=""
if (( ${#URLS[@]} > 0 )); then
  TASK="$("$USEMAC" --require-daemon --json start --summary "UseMac benchmark" | jq -r '.taskId // empty')"
  n=0
  for url in "${URLS[@]}"; do
    n=$((n + 1))
    name="web${n}"
    echo "bench.sh: ${name} ${url}" >&2
    if [[ -n "$TASK" ]]; then
      tab="$("$USEMAC" --require-daemon --json browser open "$url" --task "$TASK" | jq -r '.browserTabId')"
    else
      tab="$("$USEMAC" --require-daemon --json browser open "$url" | jq -r '.browserTabId')"
    fi
    FIRST_TAB="${FIRST_TAB:-$tab}"
    sleep 2
    "$USEMAC" --require-daemon browser observe --tab "$tab" > "$VIEWS/${name}.observe.txt"
    "$USEMAC" --require-daemon --json browser screenshot --tab "$tab" \
      --width "$VIEW_W" --height "$VIEW_H" > "$VIEWS/${name}.shot.json"
    cp "$(jq -r '.path' "$VIEWS/${name}.shot.json")" "$VIEWS/${name}.jpg"
    printf '%s\n' "$url" > "$VIEWS/${name}.source.txt"
  done
fi

if [[ -n "$VISION" ]]; then
  for i in 1 2 3; do
    echo "bench.sh: vision verify, run ${i}" >&2
    "$USEMAC" --require-daemon vision verify "$VISION" --tab "$FIRST_TAB" > "$OUT/vision-${i}.txt"
  done
  printf '%s\n' "$VISION" > "$OUT/vision-assertion.txt"
fi

if [[ -n "$APP" ]]; then
  echo "bench.sh: native window of ${APP}" >&2
  "$USEMAC" --require-daemon observe --app "$APP" > "$VIEWS/native.observe.txt"
  "$USEMAC" --require-daemon --json screenshot --app "$APP" > "$VIEWS/native.shot.json"
  cp "$(jq -r '.path' "$VIEWS/native.shot.json")" "$VIEWS/native.jpg"
  printf '%s\n' "$APP" > "$VIEWS/native.source.txt"
fi

python3 "$HERE/bench-tokens.py" "$OUT" ${TOKEN_FLAGS[@]+"${TOKEN_FLAGS[@]}"} | tee "$OUT/summary.md"
echo "bench.sh: results in ${OUT}" >&2
