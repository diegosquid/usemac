#!/usr/bin/env bash
set -euo pipefail

# Builds the Chrome Web Store upload: dist/usemac-chrome-extension-v<app version>.zip.
# Refuses a manifest whose numeric "version" / "version_name" don't match the app version, keeps dev files out
# of the zip, and checks that every file the extension loads is in it (scripts/extension-package-check.mjs).
# Submission steps: docs/CHROME-WEB-STORE.md.
#
#   scripts/package-extension.sh            # check, test and zip
#   scripts/package-extension.sh --check    # check and test only, no zip
# USEMAC_VERSION, when set, must match the app version in Sources/UseMacProtocol/Models.swift.

CHECK_ONLY="0"
for arg in "$@"; do
  case "$arg" in
    --check)
      CHECK_ONLY="1"
      ;;
    *)
      echo "Usage: $0 [--check]" >&2
      exit 1
      ;;
  esac
done

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

echo "Checking the manifest version against the app and the files to package..."
FILE_LIST="$(mktemp -t usemac-extension-files)"
trap 'rm -f "$FILE_LIST"' EXIT
APP_VERSION="$(node "$SCRIPT_DIR/extension-package-check.mjs" --root "$ROOT_DIR" --list-out "$FILE_LIST")"

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

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "Extension package check OK (app ${APP_VERSION}), would zip:"
  sed 's/^/  /' "$FILE_LIST"
  exit 0
fi

mkdir -p "$DIST_DIR"
OUT_ZIP="$DIST_DIR/usemac-chrome-extension-v${APP_VERSION}.zip"

rm -f "$OUT_ZIP"
(
  cd "$EXT_DIR"
  zip -X -q "$OUT_ZIP" -@ < "$FILE_LIST"
)

# The zip must hold exactly the checked list, with manifest.json at its root.
if ! diff -q <(sort "$FILE_LIST") <(zipinfo -1 "$OUT_ZIP" | grep -v '/$' | sort) >/dev/null; then
  echo "Error: $OUT_ZIP does not match the checked file list" >&2
  rm -f "$OUT_ZIP"
  exit 1
fi

echo "Chrome Web Store package ready:"
echo "  $OUT_ZIP"
ls -lh "$OUT_ZIP"
