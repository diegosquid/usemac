import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  checkManifest,
  checkPackage,
  devFileReason,
  isChromeVersion,
  manifestVersionsFor,
  resolveAppVersion,
} from "../../scripts/extension-package-check.mjs";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function makeRepo(t, { appVersion = "0.6.0-beta.2", manifest = {}, extraFiles = {} } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "usemac-package-check-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (rel, content) => {
    const file = path.join(root, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  };
  write("Sources/UseMacProtocol/Models.swift", `public enum UseMacDefaults {\n    public static let version = "${appVersion}"\n}\n`);
  write("scripts/bundle-app.sh", `APP_VERSION="\${USEMAC_VERSION:-${appVersion}}"\n`);
  write("scripts/release-dmg.sh", `VERSION="\${USEMAC_VERSION:-${appVersion}}"\n`);
  write(
    "Extension/manifest.json",
    JSON.stringify({
      manifest_version: 3,
      name: "UseMac Browser Bridge",
      version: "0.6.0",
      version_name: "0.6.0 beta 2",
      background: { service_worker: "background.js" },
      action: { default_popup: "popup.html", default_icon: { 16: "icons/icon16.png" } },
      icons: { 128: "icons/icon128.png" },
      ...manifest,
    })
  );
  write("Extension/background.js", 'importScripts("bridge-auth.js");\n');
  write("Extension/bridge-auth.js", "// auth\n");
  write("Extension/popup.html", '<link rel="stylesheet" href="popup.css"><img src="icons/icon16.png"><script src="popup.js"></script>');
  write("Extension/popup.css", "");
  write("Extension/popup.js", "");
  write("Extension/icons/icon16.png", "png");
  write("Extension/icons/icon128.png", "png");
  for (const [rel, content] of Object.entries(extraFiles)) write(`Extension/${rel}`, content);
  return root;
}

test("the repository's own extension passes the store package check", () => {
  const app = resolveAppVersion(REPO, "");
  assert.deepEqual(app.errors, []);
  const result = checkPackage(path.join(REPO, "Extension"), app.version);
  assert.deepEqual(result.errors, []);
  assert.ok(result.files.includes("manifest.json"));
  assert.ok(result.files.includes("background.js"));
});

test("Chrome version rule: numeric parts only, 0-65535, no leading zeros", () => {
  for (const ok of ["0.6.0", "1", "1.2.3.4", "0.0.1", "65535.0"]) assert.equal(isChromeVersion(ok), true, ok);
  for (const bad of ["0.6.0-beta.2", "0.6.0 beta 2", "1.2.3.4.5", "01.2", "1.032", "65536", "", "1..2", "v1.0", null]) {
    assert.equal(isChromeVersion(bad), false, String(bad));
  }
});

test("an app version maps to a numeric version and a version_name that carries the beta suffix", () => {
  assert.deepEqual(manifestVersionsFor("0.6.0-beta.2"), { version: "0.6.0", versionName: "0.6.0 beta 2" });
  assert.deepEqual(manifestVersionsFor("0.6.0-rc.1"), { version: "0.6.0", versionName: "0.6.0 rc 1" });
  assert.deepEqual(manifestVersionsFor("0.6.0"), { version: "0.6.0", versionName: null });
});

test("checkManifest refuses a version that doesn't match the app", () => {
  const base = { version: "0.6.0", version_name: "0.6.0 beta 2" };
  assert.deepEqual(checkManifest(base, "0.6.0-beta.2"), []);
  assert.deepEqual(checkManifest({ ...base, version_name: "0.6.0-beta.2" }, "0.6.0-beta.2"), []);

  assert.match(checkManifest({ ...base, version_name: "0.6.0 beta 1" }, "0.6.0-beta.2").join("\n"), /expected "0.6.0 beta 2"/);
  assert.match(checkManifest({ version: "0.6.0" }, "0.6.0-beta.2").join("\n"), /"version_name" is null/);
  assert.match(checkManifest({ ...base, version: "0.6.1" }, "0.6.0-beta.2").join("\n"), /expected "0.6.0"/);
  assert.match(checkManifest({ ...base, version: "0.6.0-beta.2" }, "0.6.0-beta.2").join("\n"), /1 to 4 dot-separated integers/);

  // The stable release: no beta label left behind.
  assert.deepEqual(checkManifest({ version: "0.6.0" }, "0.6.0"), []);
  assert.deepEqual(checkManifest({ version: "0.6.0", version_name: "0.6.0" }, "0.6.0"), []);
  assert.match(checkManifest(base, "0.6.0").join("\n"), /remove "version_name"/);
});

test("checkManifest refuses fields the store assigns", () => {
  const errors = checkManifest({ version: "0.6.0", key: "abc", update_url: "https://example.com/u" }, "0.6.0").join("\n");
  assert.match(errors, /"key"/);
  assert.match(errors, /"update_url"/);
});

test("dev files stay out of the zip, and the files the extension loads stay in", (t) => {
  const root = makeRepo(t, {
    extraFiles: {
      ".DS_Store": "x",
      ".eslintrc.json": "{}",
      "README.md": "# notes",
      "background.js.map": "{}",
      "popup.test.mjs": "",
      "tests/fixture.html": "",
      "node_modules/dep/index.js": "",
      "package.json": "{}",
      "background.js~": "",
      "notes.swp": "",
    },
  });
  const result = checkPackage(path.join(root, "Extension"), "0.6.0-beta.2");
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.files, [
    "background.js",
    "bridge-auth.js",
    "icons/icon128.png",
    "icons/icon16.png",
    "manifest.json",
    "popup.css",
    "popup.html",
    "popup.js",
  ]);
  assert.equal(result.excluded.length, 10);
  assert.equal(devFileReason("icons/icon16.png"), null);
  assert.equal(devFileReason("_locales/en/messages.json"), null);
});

test("a missing referenced file or a private key stops the package", (t) => {
  const root = makeRepo(t, { extraFiles: { "signing.pem": "-----BEGIN PRIVATE KEY-----" } });
  fs.rmSync(path.join(root, "Extension/bridge-auth.js"));
  const errors = checkPackage(path.join(root, "Extension"), "0.6.0-beta.2").errors.join("\n");
  assert.match(errors, /bridge-auth\.js is referenced but missing/);
  assert.match(errors, /signing\.pem looks like a private key/);
});

test("the app version must agree across Models.swift, the release scripts and USEMAC_VERSION", (t) => {
  const root = makeRepo(t);
  assert.deepEqual(resolveAppVersion(root, ""), { version: "0.6.0-beta.2", errors: [] });
  assert.deepEqual(resolveAppVersion(root, "0.6.0-beta.2").errors, []);
  assert.match(resolveAppVersion(root, "0.6.0").errors.join("\n"), /USEMAC_VERSION is 0.6.0/);

  fs.writeFileSync(path.join(root, "scripts/bundle-app.sh"), 'APP_VERSION="${USEMAC_VERSION:-0.6.0-beta.1}"\n');
  assert.match(resolveAppVersion(root, "").errors.join("\n"), /bundle-app\.sh defaults to 0.6.0-beta.1/);
});
