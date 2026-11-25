#!/usr/bin/env bash
set -euo pipefail

# Official Apple Direct Distribution Release Pipeline for UseMac:
#   1. Preflights release requirements before building or modifying dist/ or website/
#   2. Builds release UseMac.app with Sparkle 2 + Hardened Runtime
#   3. Packages a clean drag-to-Applications .dmg (Apple Silicon arm64)
#   4. Notarizes (--notarize) via Apple Notary Service + staples + validates Gatekeeper
#   5. Optional (--update-appcast): Signs with Sparkle EdDSA + updates website/public/appcast.xml
#   6. Publishes notarized DMG + _redirects to website/public/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${USEMAC_VERSION:-0.5.0}"
BUILD_NUMBER="${USEMAC_BUILD_NUMBER:-50}"
NOTARIZE="0"
SKIP_NOTARIZE="0"
UPDATE_APPCAST="0"
LOCAL_DEV="0"
CHECK_ONLY="0"
NOTARY_PROFILE="${USEMAC_NOTARY_PROFILE:-usemac-notary}"
DOWNLOAD_BASE_URL="${USEMAC_DOWNLOAD_BASE_URL:-https://usemac.app/downloads}"

for arg in "$@"; do
  case "$arg" in
    --notarize)
      NOTARIZE="1"
      ;;
    --skip-notarize)
      SKIP_NOTARIZE="1"
      ;;
    --update-appcast)
      UPDATE_APPCAST="1"
      ;;
    --local)
      LOCAL_DEV="1"
      ;;
    --check)
      CHECK_ONLY="1"
      ;;
    *)
      echo "Usage: $0 [--local] [--notarize | --skip-notarize] [--update-appcast] [--check]" >&2
      exit 1
      ;;
  esac
done

find_sign_update() {
  if command -v sign_update >/dev/null 2>&1; then
    command -v sign_update
    return 0
  fi
  if [[ -d "$ROOT_DIR/.build/artifacts" ]]; then
    local found
    found="$(find "$ROOT_DIR/.build/artifacts" -name "sign_update" -type f 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  fi
  return 1
}

DEV_ID=""
SIGN_UPDATE=""
RELEASE_NOTES_FILE="$ROOT_DIR/docs/release-notes/${VERSION}.html"

if [[ "$LOCAL_DEV" != "1" ]]; then
  PREFLIGHT_ERRORS=()

  if [[ -n "${USEMAC_SIGN_IDENTITY:-}" ]]; then
    if [[ "$USEMAC_SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
      DEV_ID="$USEMAC_SIGN_IDENTITY"
    fi
  else
    DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
  fi
  if [[ -z "$DEV_ID" ]]; then
    PREFLIGHT_ERRORS+=('no "Developer ID Application" signing identity found')
  fi

  if [[ -z "${USEMAC_SPARKLE_PUBLIC_KEY:-}" ]]; then
    PREFLIGHT_ERRORS+=('USEMAC_SPARKLE_PUBLIC_KEY is not set (Sparkle updates would be disabled)')
  fi

  if [[ "$NOTARIZE" == "1" && "$SKIP_NOTARIZE" == "1" ]]; then
    PREFLIGHT_ERRORS+=('cannot pass both --notarize and --skip-notarize')
  elif [[ "$NOTARIZE" != "1" && "$SKIP_NOTARIZE" != "1" ]]; then
    PREFLIGHT_ERRORS+=('pass --notarize, or --skip-notarize for an internal build that is not published')
  fi

  if [[ "$NOTARIZE" == "1" ]]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      PREFLIGHT_ERRORS+=("notarytool keychain profile \"${NOTARY_PROFILE}\" not found")
    fi
  fi

  if [[ "$UPDATE_APPCAST" == "1" ]]; then
    if [[ "$NOTARIZE" != "1" ]]; then
      PREFLIGHT_ERRORS+=('--update-appcast requires --notarize')
    fi
    SIGN_UPDATE="$(find_sign_update || true)"
    if [[ -z "$SIGN_UPDATE" ]]; then
      PREFLIGHT_ERRORS+=('Sparkle sign_update tool not found')
    fi
    if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
      PREFLIGHT_ERRORS+=("docs/release-notes/${VERSION}.html not found")
    fi
  fi

  if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
    for err in "${PREFLIGHT_ERRORS[@]}"; do
      echo "release preflight: $err" >&2
    done
    exit 1
  fi

  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "Release preflight OK."
    exit 0
  fi
else
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "Local dev preflight OK."
    exit 0
  fi
fi

echo "==> 1. Building release app bundle (v${VERSION}, build ${BUILD_NUMBER})..."
if [[ "$LOCAL_DEV" != "1" ]]; then
  USEMAC_VERSION="$VERSION" \
    USEMAC_BUILD_NUMBER="$BUILD_NUMBER" \
    USEMAC_SIGN_IDENTITY="$DEV_ID" \
    "$SCRIPT_DIR/bundle-app.sh" --hardened --require-sparkle-key
else
  USEMAC_VERSION="$VERSION" \
    USEMAC_BUILD_NUMBER="$BUILD_NUMBER" \
    "$SCRIPT_DIR/bundle-app.sh"
fi

APP_DIR="$ROOT_DIR/dist/UseMac.app"
DMG_NAME="usemac-${VERSION}-arm64.dmg"
DMG_PATH="$ROOT_DIR/dist/${DMG_NAME}"
STAGE_DIR="$(mktemp -d /tmp/usemac-dmg-stage.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> 2. Staging drag-to-Applications DMG..."
/usr/bin/ditto "$APP_DIR" "$STAGE_DIR/UseMac.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "UseMac ${VERSION}" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

if [[ "$LOCAL_DEV" != "1" ]]; then
  echo "==> 3. Signing DMG with: $DEV_ID"
  /usr/bin/codesign --force --timestamp --sign "$DEV_ID" "$DMG_PATH"
fi

if [[ "$LOCAL_DEV" != "1" && "$NOTARIZE" == "1" ]]; then
  echo "==> 4. Submitting to Apple Notary Service (profile: ${NOTARY_PROFILE})..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> 5. Stapling and validating notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl -a -t open --context context:primary-signature -v "$DMG_PATH"
fi

DMG_SIZE="$(stat -f%z "$DMG_PATH")"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

if [[ "$LOCAL_DEV" != "1" && "$NOTARIZE" == "1" ]]; then
  if [[ "$UPDATE_APPCAST" == "1" ]]; then
    echo "==> 6. Signing DMG for Sparkle 2 appcast..."
    SIGN_UPDATE_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
    SPARKLE_SIG="$(printf '%s\n' "$SIGN_UPDATE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    if [[ -z "$SPARKLE_SIG" ]]; then
      echo "Error: Sparkle signature is empty" >&2
      exit 1
    fi
    PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    APPCAST_FILE="$ROOT_DIR/website/public/appcast.xml"
    {
      cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>UseMac Changelog</title>
    <link>https://usemac.app/appcast.xml</link>
    <description>Official automatic updates for UseMac (macOS 15+ Apple Silicon).</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[
XML
      awk '{print "        " $0}' "$RELEASE_NOTES_FILE"
      cat <<XML
      ]]></description>
      <enclosure
        url="${DOWNLOAD_BASE_URL}/${DMG_NAME}"
        sparkle:edSignature="${SPARKLE_SIG}"
        length="${DMG_SIZE}"
        type="application/octet-stream"
        sparkle:os="macos"
      />
    </item>
  </channel>
</rss>
XML
    } > "$APPCAST_FILE"
    echo "Updated $APPCAST_FILE with signed EdDSA signature."
  fi

  mkdir -p "$ROOT_DIR/website/public/downloads"
  cp "$DMG_PATH" "$ROOT_DIR/website/public/downloads/${DMG_NAME}"
  printf '/downloads/usemac-latest-arm64.dmg /downloads/%s 302\n' "$DMG_NAME" > "$ROOT_DIR/website/public/_redirects"
  echo "Published ${DMG_NAME} and updated website/public/_redirects."
elif [[ "$LOCAL_DEV" != "1" && "$SKIP_NOTARIZE" == "1" ]]; then
  echo "NOT PUBLISHED: this build is not notarized."
fi

echo ""
echo "Release DMG ready!"
echo "  Path:   $DMG_PATH"
echo "  Size:   $(ls -lh "$DMG_PATH" | awk '{print $5}') ($DMG_SIZE bytes)"
echo "  SHA256: $DMG_SHA256"
