#!/usr/bin/env bash
set -euo pipefail

CONFIG="release"
ALLOW_ADHOC="${USEMAC_ALLOW_ADHOC:-0}"
HARDENED="${USEMAC_HARDENED_RUNTIME:-0}"
REQUIRE_SPARKLE_KEY="0"

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIG="debug"
      ;;
    --allow-adhoc)
      ALLOW_ADHOC="1"
      ;;
    --hardened)
      HARDENED="1"
      ;;
    --require-sparkle-key)
      REQUIRE_SPARKLE_KEY="1"
      ;;
    *)
      echo "Usage: $0 [--debug] [--hardened] [--allow-adhoc] [--require-sparkle-key]" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_DIR="$ROOT_DIR/dist/UseMac.app"
APP_VERSION="${USEMAC_VERSION:-0.8.0-beta.1}"
APP_BUILD="${USEMAC_BUILD_NUMBER:-64}"
APPCAST_URL="${USEMAC_APPCAST_URL:-https://usemac.app/appcast.xml}"
SPARKLE_PUBLIC_KEY="${USEMAC_SPARKLE_PUBLIC_KEY:-}"
# The EdDSA public key that update signatures are checked against (the private key stays in the
# maintainer's keychain). Not a secret.
if [[ -z "$SPARKLE_PUBLIC_KEY" && -f "$SCRIPT_DIR/sparkle-public-key.txt" ]]; then
  SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$SCRIPT_DIR/sparkle-public-key.txt")"
fi
CHROME_EXT_ID="${USEMAC_CHROME_EXTENSION_ID:-}"

if [[ -n "$CHROME_EXT_ID" ]]; then
  CHROME_EXT_ID_REGEX='^[abcdefghijklmnop]{32}$'
  if [[ ! "$CHROME_EXT_ID" =~ $CHROME_EXT_ID_REGEX ]]; then
    echo "USEMAC_CHROME_EXTENSION_ID must be 32 characters a-p" >&2
    exit 1
  fi
fi

if [[ "$REQUIRE_SPARKLE_KEY" == "1" && -z "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "USEMAC_SPARKLE_PUBLIC_KEY is required for this build" >&2
  exit 1
fi

# Resolve a persistent signing identity BEFORE rebuilding or deleting the existing bundle,
# avoiding any silent fallback to ad-hoc signing (which invalidates TCC permissions).
SIGN_IDENTITY="${USEMAC_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && "$HARDENED" == "1" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" && -d "$APP_DIR" ]]; then
  EXISTING_AUTH="$(/usr/bin/codesign -dvv "$APP_DIR" 2>&1 | sed -n 's/^Authority=//p' | head -n 1 || true)"
  if [[ -n "$EXISTING_AUTH" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$EXISTING_AUTH\""; then
    SIGN_IDENTITY="$EXISTING_AUTH"
  fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(UseMac[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi

if [[ "$HARDENED" == "1" && "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "--hardened requires a \"Developer ID Application\" identity (found: ${SIGN_IDENTITY:-none})" >&2
  exit 1
fi

if [[ -z "$SIGN_IDENTITY" && "$ALLOW_ADHOC" != "1" ]]; then
  echo "No persistent codesigning identity found in Keychain." >&2
  echo "Aborting before modifying $APP_DIR to avoid invalidating Accessibility/Screen Recording (TCC) permissions." >&2
  echo "Set USEMAC_SIGN_IDENTITY=\"...\" or pass --allow-adhoc explicitly." >&2
  exit 1
fi

if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  HARDENED="1"
fi

CACHE_ROOT="$ROOT_DIR/.build/bundle-cache"
SPM_CACHE_DIR="$CACHE_ROOT/spm-cache"
SPM_CONFIG_DIR="$CACHE_ROOT/spm-config"
SPM_SEC_DIR="$CACHE_ROOT/spm-sec"
CLANG_CACHE_DIR="$CACHE_ROOT/clang-cache"
mkdir -p "$SPM_CACHE_DIR" "$SPM_CONFIG_DIR" "$SPM_SEC_DIR" "$CLANG_CACHE_DIR"

SPM_FLAGS=(
  --disable-sandbox
  --cache-path "$SPM_CACHE_DIR"
  --config-path "$SPM_CONFIG_DIR"
  --security-path "$SPM_SEC_DIR"
  --manifest-cache local
)

BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" swift build --show-bin-path "${SPM_FLAGS[@]}" -c "$CONFIG")"

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

# The CLI product is named usemac-cli so it can't overwrite UseMac on a case-insensitive volume.
# It is installed as Contents/Helpers/usemac.
echo "Building UseMac.app and the usemac CLI ($CONFIG)..."
# A build from before the rename can leave the CLI's binary at $BIN_PATH/UseMac. Removing it forces a relink.
rm -f "$BIN_PATH/UseMac" "$BIN_PATH/usemac"
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" swift build "${SPM_FLAGS[@]}" -c "$CONFIG"
cp "$BIN_PATH/UseMac" "$MACOS_DIR/UseMac"
cp "$BIN_PATH/usemac-cli" "$HELPERS_DIR/usemac"

# Embed Sparkle.framework with symlinks intact (ditto) and ensure @executable_path/../Frameworks rpath
SPARKLE_SRC=""
if [[ -d "$BIN_PATH/Sparkle.framework" ]]; then
  SPARKLE_SRC="$BIN_PATH/Sparkle.framework"
elif [[ -d "$ROOT_DIR/.build/artifacts" ]]; then
  SPARKLE_SRC="$(find "$ROOT_DIR/.build/artifacts" -maxdepth 6 -name "Sparkle.framework" -type d | head -n 1 || true)"
fi
if [[ -n "$SPARKLE_SRC" && -d "$SPARKLE_SRC" ]]; then
  echo "Embedding Sparkle.framework..."
  /usr/bin/ditto "$SPARKLE_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/UseMac" 2>/dev/null || true
fi

chmod +x "$MACOS_DIR/UseMac" "$HELPERS_DIR/usemac"

if [[ -d "$ROOT_DIR/.agents" ]]; then
  mkdir -p "$RESOURCES_DIR/agent"
  cp -R "$ROOT_DIR/.agents/"* "$RESOURCES_DIR/agent/"
fi

if [[ -d "$ROOT_DIR/Extension" ]]; then
  mkdir -p "$RESOURCES_DIR/chrome-extension"
  rsync -a --exclude='.DS_Store' --exclude='*.tmp' --exclude='*.bak' --exclude='*.swp' "$ROOT_DIR/Extension/" "$RESOURCES_DIR/chrome-extension/"
fi

if [[ -f "$ROOT_DIR/scripts/usemac-vision-worker.py" ]]; then
  mkdir -p "$RESOURCES_DIR/vision"
  cp "$ROOT_DIR/scripts/usemac-vision-worker.py" "$RESOURCES_DIR/vision/worker.py"
  chmod +x "$RESOURCES_DIR/vision/worker.py"
fi

ICON_PLIST_ENTRY=""
ICON_GEN_ARGS=("$RESOURCES_DIR/AppIcon.icns")
if [[ -f "$ROOT_DIR/Assets/usemac-icon-master.png" ]]; then
  ICON_GEN_ARGS+=(--source "$ROOT_DIR/Assets/usemac-icon-master.png")
  cp "$ROOT_DIR/Assets/usemac-icon-master.png" "$RESOURCES_DIR/usemac-logo.png"
fi
if CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" swift "$SCRIPT_DIR/generate-icon.swift" "${ICON_GEN_ARGS[@]}"; then
  ICON_PLIST_ENTRY="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>"
else
  echo "Warning: failed to generate AppIcon.icns; continuing without custom icon." >&2
fi

SPARKLE_KEY_PLIST=""
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  SPARKLE_KEY_PLIST="  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_KEY}</string>"
fi

CHROME_EXT_PLIST=""
if [[ -n "$CHROME_EXT_ID" ]]; then
  CHROME_EXT_PLIST="  <key>UseMacChromeExtensionID</key>
  <string>${CHROME_EXT_ID}</string>"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>UseMac</string>
  <key>CFBundleExecutable</key>
  <string>UseMac</string>
${ICON_PLIST_ENTRY}
  <key>CFBundleIdentifier</key>
  <string>app.usemac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>UseMac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>SUFeedURL</key>
  <string>${APPCAST_URL}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
${SPARKLE_KEY_PLIST}
${CHROME_EXT_PLIST}
  <key>NSAccessibilityUsageDescription</key>
  <string>UseMac needs Accessibility permission to inspect UI elements and execute background actions in macOS windows.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>UseMac needs Screen Recording permission to stream background window previews and capture on-demand screenshots.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>UseMac uses Apple Events to focus specific browser tabs when you click the floating preview.</string>
</dict>
</plist>
PLIST

SIGN_FLAGS=(--force)
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_FLAGS+=(--sign "$SIGN_IDENTITY")
else
  SIGN_FLAGS+=(--sign -)
fi

if [[ "$HARDENED" == "1" && -n "$SIGN_IDENTITY" ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
  echo "Signing $APP_DIR (Hardened Runtime + Timestamp) with: $SIGN_IDENTITY..."
elif [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing $APP_DIR with persistent identity: $SIGN_IDENTITY..."
else
  echo "Signing $APP_DIR (explicit ad-hoc via --allow-adhoc)..."
fi

# Sign nested Sparkle 2 components inside-out (required for Apple Notarization)
SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  for xpc in \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/Autoupdate" \
    "$SPARKLE_FW/Versions/B/Updater.app"; do
    if [[ -e "$xpc" ]]; then
      if [[ "$xpc" == */Downloader.xpc ]]; then
        /usr/bin/codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
      else
        /usr/bin/codesign "${SIGN_FLAGS[@]}" "$xpc"
      fi
    fi
  done
  /usr/bin/codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW"
fi

/usr/bin/codesign "${SIGN_FLAGS[@]}" "$HELPERS_DIR/usemac"

if [[ "$HARDENED" == "1" && -f "$ROOT_DIR/Assets/usemac.entitlements" ]]; then
  /usr/bin/codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT_DIR/Assets/usemac.entitlements" "$APP_DIR"
else
  /usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP_DIR"
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
echo "Bundle created successfully at: $APP_DIR (v${APP_VERSION} build ${APP_BUILD})"
