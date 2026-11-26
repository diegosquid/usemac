# Chrome Web Store release

UseMac Browser Bridge 0.5.0 is under review in the Chrome Web Store. The store takes a new package only after the
current review ends, so **0.6.0 can be submitted only once the 0.5.0 review is over** (approved or rejected).

## Set the store ID (once 0.5.0 is approved)

1. Copy the item ID from the developer dashboard. It is 32 letters `a`–`p`, the last part of the listing URL.
2. Build the release app with it. `release-dmg.sh` hands `USEMAC_CHROME_EXTENSION_ID` to `bundle-app.sh`, which
   checks the format and writes it to Info.plist as `UseMacChromeExtensionID`:

   ```bash
   USEMAC_CHROME_EXTENSION_ID=<id> scripts/release-dmg.sh --notarize --update-appcast
   /usr/libexec/PlistBuddy -c 'Print :UseMacChromeExtensionID' dist/UseMac.app/Contents/Info.plist
   ```

   A local bundle takes it the same way: `USEMAC_CHROME_EXTENSION_ID=<id> scripts/bundle-app.sh`.
   `release-dmg.sh` warns when a stable release has no ID. Leave it unset for betas.
3. On the website (`website/public/index.html`), point the **Chrome Extension** button (`#chromeStoreBtn`) at the
   listing, and make its install step say to add the extension from the store.

With the ID set:

- The setup guide offers **Add from Chrome Web Store** first. Its button opens
  `https://chromewebstore.google.com/detail/<id>` in Chrome, and **Load it unpacked instead** keeps the bundled
  folder as the fallback. Until a profile connects, **Settings → General → Chrome Extension** shows the same
  **Open Web Store** button.
- The bridge accepts the store ID and the app's own `UseMac.app/Contents/Resources/chrome-extension` folder loaded
  unpacked. A copy loaded from another folder, such as a repo checkout's `Extension/`, is refused, and its popup
  says the app isn't running. To develop against a store build, allow that copy's ID (shown on its card in
  `chrome://extensions`). UseMac reads the setting on every connection attempt, and only you can change it, not
  agents:

  ```bash
  defaults write app.usemac usemac.bridge.allowedExtensionIds -array <id>
  defaults delete app.usemac usemac.bridge.allowedExtensionIds   # undo
  ```

  `USEMAC_ALLOWED_EXTENSION_IDS=<id>,<id>` in UseMac's environment does the same. Unlike the setting, it also turns
  the check on in builds without a store ID.
- Pairing works the same way for every install. Each install keeps its own copy of the key, though: after moving a
  profile from the unpacked copy to the store one, remove the unpacked copy in `chrome://extensions`, because two
  copies would both connect, and paste the key into the new popup.

## Submit 0.6.0 with the stable app

1. Bump the app to `0.6.0`: `UseMacDefaults.version` in `Sources/UseMacProtocol/Models.swift` and the defaults in
   `scripts/bundle-app.sh` and `scripts/release-dmg.sh`. In `Extension/manifest.json`, `version` stays `"0.6.0"`.
   Remove `version_name`, or set it to `"0.6.0"`. Betas keep a numeric `version` and put the suffix only in
   `version_name` (`"0.6.0 beta 2"` for `0.6.0-beta.2`).
2. Build the upload with `scripts/package-extension.sh`, which writes `dist/usemac-chrome-extension-v0.6.0.zip`.
   Use `--check` to validate without zipping. The script runs the extension tests. It stops when:
   - `version` isn't numeric;
   - `version` or `version_name` doesn't match the app version (the files above, plus `USEMAC_VERSION` when set,
     must agree);
   - the manifest has `key` or `update_url`;
   - a file the extension loads is missing;
   - a `*.pem` file is in `Extension/`.

   Dotfiles, docs, source maps, tests and package manifests are left out of the zip, and the script lists them.
3. Once the 0.5.0 review is over, go to the developer dashboard and choose **Package → Upload new package**. Upload
   the zip, check that the permission justifications and the privacy fields still match the manifest, and submit
   it for review.
4. Ship the stable app with the store ID, as above. Until 0.6.0 is approved the listing serves 0.5.0, and the app's
   Chrome Extension settings flag that install as outdated. Chrome updates store installs on its own once 0.6.0 is
   published.
