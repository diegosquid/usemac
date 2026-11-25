#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXT_DIR="$ROOT_DIR/Extension"
DIST_DIR="$ROOT_DIR/dist"

echo "Validating Extension/*.js syntax..."
JS_FILES=()
for js_file in "$EXT_DIR"/*.js; do
  if [[ -f "$js_file" ]]; then
    JS_FILES+=("$js_file")
  fi
done
if [[ ${#JS_FILES[@]} -eq 0 ]]; then
  echo "Error: no .js files found in $EXT_DIR" >&2
  exit 1
fi
for js_file in "${JS_FILES[@]}"; do
  node --check "$js_file"
done

TEST_FILES=()
for test_file in "$ROOT_DIR"/Tests/ExtensionTests/*.test.mjs; do
  if [[ -f "$test_file" ]]; then
    TEST_FILES+=("$test_file")
  fi
done
if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
  echo "Running extension tests..."
  node --test "${TEST_FILES[@]}"
fi

MANIFEST_PATH="$EXT_DIR/manifest.json"
VERSION="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
if "key" in data:
    sys.stderr.write("manifest.json must not contain \"key\"\n")
    sys.exit(1)
print(data["version"])
' "$MANIFEST_PATH")"

mkdir -p "$DIST_DIR"
OUT_ZIP="$DIST_DIR/usemac-chrome-extension-v${VERSION}.zip"

rm -f "$OUT_ZIP"
(
  cd "$EXT_DIR"
  zip -r -X "$OUT_ZIP" . \
    -x "*.DS_Store" \
    -x "__MACOSX/*" \
    -x "*.tmp" \
    -x "*.bak" \
    -x "*.swp"
)

echo "Chrome Web Store package ready:"
echo "  $OUT_ZIP"
ls -lh "$OUT_ZIP"
