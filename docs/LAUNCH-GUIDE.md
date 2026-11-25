# UseMac Official Launch Guide

Everything required to ship **UseMac** officially:
1. Landing page + Privacy Policy + Sparkle `appcast.xml` on Cloudflare Workers
2. Chrome Web Store publication (`UseMac Browser Bridge`)
3. Apple Direct Distribution (Developer ID + Hardened Runtime + Notarization + Sparkle 2 auto-update)

---

## 1. Deploy the Landing Page (`website/`) to Cloudflare

```bash
cd website
npx wrangler deploy
```

- Serves `index.html`, `/privacy.html`, and `/appcast.xml` globally on Cloudflare's edge.
- Connect your custom domain (e.g., `usemac.app`) inside Cloudflare Dashboard → Workers & Pages → `usemac` → Custom Domains.

---

## 2. Publish the Chrome Extension to Chrome Web Store

1. Build the clean submission zip:
   ```bash
   ./scripts/package-extension.sh
   ```
   Output: `dist/usemac-chrome-extension-v0.5.0.zip` (`scripting` and `<all_urls>` already removed for clean review).

2. Open [Chrome Web Store Developer Dashboard](https://chrome.google.com/webstore/devconsole) ($5 one-time fee) → **New Item** → Upload `dist/usemac-chrome-extension-v0.5.0.zip`.

3. **Privacy Policy URL:** `https://usemac.app/privacy.html`

4. **Permission Justifications (copy-paste ready):**
   - **Single Purpose:** *"Connects Google Chrome to the user's local UseMac desktop daemon over loopback (`127.0.0.1`), authenticated with a local pairing key, to execute zero-focus background tab automation and stream a local live corner preview."*
   - **`tabs`:** *"Lists open tab titles/URLs and routes user-requested agent commands to the exact background tab without stealing window focus."*
   - **`tabGroups`:** *"Groups tabs actively controlled by UseMac into a dedicated 'UseMac' tab group so users can visually distinguish automated tabs from personal browsing."*
   - **`debugger`:** *"Attaches Chrome DevTools Protocol locally on active tasks to read interactive DOM trees, dispatch background clicks/typing/uploads, and capture local HUD preview frames."*
   - **`storage`:** *"Stores the profile label typed by the user and the local pairing key in `chrome.storage.local`."*
   - **`alarms`:** *"Keeps the local `127.0.0.1` WebSocket connection alive across Manifest V3 service worker idle suspensions."*
   - **`downloads`:** *"Detects newly downloaded files triggered by explicit agent actions (e.g., CSV exports) so the local file path is returned to the user's agent."*
   - **Remote Code:** **No** (all JavaScript is bundled inside the extension package).

5. Once approved, copy your 32-character Extension ID and set `USEMAC_CHROME_EXTENSION_ID=<32-char-id>` when building your release `.dmg` — UseMac will then show a 1-click **Install Extension** button that registers Chrome's official External Extension JSON automatically!

---

## 3. Set Up Apple Developer ID, Notarization & Sparkle 2 Auto-Updates

### A. Create Developer ID Application Certificate (once)
1. Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list) → **+** → **Developer ID Application** (G2 Sub-CA).
2. Download and double-click the `.cer` file to install it into your macOS Keychain.
3. Verify: `security find-identity -v -p codesigning` should now show `Developer ID Application: Diego Dias de Macedo (...)`.

### B. Store Apple Notarization Credentials in Keychain (once)
1. Generate an App-Specific Password at [appleid.apple.com](https://appleid.apple.com).
2. Store credentials once:
   ```bash
   xcrun notarytool store-credentials "usemac-notary" \
     --apple-id "YOUR_APPLE_ID_EMAIL" \
     --team-id "YOUR_10_CHAR_TEAM_ID" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

### C. Generate Sparkle 2 EdDSA Signing Key (once)
```bash
# Using Sparkle's generate_keys tool (from brew install --cask sparkle or Sparkle release archive)
generate_keys
```
- This saves your private key safely in macOS Keychain and prints your public `SUPublicEDKey` string.

### D. Cut an Official Signed, Notarized, Auto-Updating Release
1. Write the release notes HTML fragment at `docs/release-notes/<VERSION>.html` (required when using `--update-appcast`).
2. Verify all release prerequisites before building with `--check`:
   ```bash
   USEMAC_VERSION="0.5.0" \
   USEMAC_BUILD_NUMBER="50" \
   USEMAC_SPARKLE_PUBLIC_KEY="<YOUR_SUPUBLICEDKEY>" \
   USEMAC_CHROME_EXTENSION_ID="<YOUR_CHROME_WEB_STORE_ID>" \
   ./scripts/release-dmg.sh --notarize --update-appcast --check
   ```
3. Build, sign, notarize, verify, and stage the website release artifacts:
   ```bash
   USEMAC_VERSION="0.5.0" \
   USEMAC_BUILD_NUMBER="50" \
   USEMAC_SPARKLE_PUBLIC_KEY="<YOUR_SUPUBLICEDKEY>" \
   USEMAC_CHROME_EXTENSION_ID="<YOUR_CHROME_WEB_STORE_ID>" \
   ./scripts/release-dmg.sh --notarize --update-appcast
   ```
   - After notarization, stapling, and Gatekeeper (`spctl`) verification pass, the script copies `usemac-<VERSION>-arm64.dmg` into `website/public/downloads/`, updates `website/public/_redirects` to point `/downloads/usemac-latest-arm64.dmg` to `/downloads/usemac-<VERSION>-arm64.dmg`, and writes the signed `website/public/appcast.xml` with the release notes.
   - Use `--skip-notarize` for an internal Developer ID build that is not published to `website/`, or `--local` for a local development build.
4. Run `cd website && npx wrangler deploy` to publish the notarized DMG, `_redirects`, and signed `appcast.xml`.
