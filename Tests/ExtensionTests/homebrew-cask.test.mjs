import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CASK = path.join(REPO, "Casks/usemac.rb");
const UPDATER = path.join(REPO, "scripts/update-homebrew-cask.py");
const SOURCE = fs.readFileSync(CASK, "utf8");
const SHA256 = "ab".repeat(32);

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "usemac-homebrew-cask-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const cask = path.join(root, "usemac.rb");
  fs.writeFileSync(cask, SOURCE);
  return { root, cask };
}

function run(...args) {
  const result = spawnSync("python3", [UPDATER, ...args], { encoding: "utf8" });
  assert.ifError(result.error);
  return result;
}

test("the repository cask passes the default check without writes", () => {
  const result = run("--check");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /OK/);
  assert.equal(fs.readFileSync(CASK, "utf8"), SOURCE);
});

test("update replaces only the version and checksum, lowercases hex, and is idempotent", (t) => {
  const { cask } = fixture(t);
  const args = ["--version", "2.3.4", "--sha256", SHA256.toUpperCase()];
  const expected = SOURCE
    .replace(/^(  version )"[^"]+"/m, '$1"2.3.4"')
    .replace(/^(  sha256 )"[^"]+"/m, `$1"${SHA256}"`);
  for (let attempt = 0; attempt < 2; attempt++) {
    const result = run(cask, ...args);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(cask, "utf8"), expected);
  }
  const result = run(cask, "--check", "--expect-version", "2.3.4");
  assert.equal(result.status, 0, result.stderr);
});

test("prereleases are rejected unless explicitly allowed", (t) => {
  const { cask } = fixture(t);
  const args = ["--version", "2.3.4-beta.1", "--sha256", SHA256];
  const rejected = run(cask, ...args);
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, /invalid version/);
  assert.equal(fs.readFileSync(cask, "utf8"), SOURCE);
  const allowed = run(cask, ...args, "--allow-prerelease");
  assert.equal(allowed.status, 0, allowed.stderr);
  assert.equal(run(cask, "--check").status, 1);
  const check = run(cask, "--check", "--allow-prerelease", "--expect-version", "2.3.4-beta.1");
  assert.equal(check.status, 0, check.stderr);
});

test("invalid checksums are rejected without writing", (t) => {
  const { cask } = fixture(t);
  for (const checksum of ["abc", "z".repeat(64)]) {
    const result = run(cask, "--version", "2.3.4", "--sha256", checksum);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /invalid sha256/);
    assert.equal(fs.readFileSync(cask, "utf8"), SOURCE);
  }
});

test("check matches the named DMG in SHA256SUMS and rejects mismatches", (t) => {
  const { root, cask } = fixture(t);
  const update = run(cask, "--version", "2.3.4", "--sha256", SHA256);
  assert.equal(update.status, 0, update.stderr);
  const sums = path.join(root, "SHA256SUMS.txt");
  const checksum = "01".repeat(32);
  const args = ["--check", "--sums-file", sums];
  fs.writeFileSync(sums, `${checksum}  usemac-chrome-extension-v2.3.4.zip\n${SHA256}  usemac-2.3.4-arm64.dmg\n`);
  const match = run(cask, ...args);
  assert.equal(match.status, 0, match.stderr);
  fs.writeFileSync(sums, `${SHA256}  usemac-chrome-extension-v2.3.4.zip\n${checksum}  usemac-2.3.4-arm64.dmg\n`);
  const mismatch = run(cask, ...args);
  assert.equal(mismatch.status, 1);
  assert.match(mismatch.stderr, /SHA256SUMS mismatch/);
});

test("check rejects the wrong version and missing required stanzas", (t) => {
  const { cask } = fixture(t);
  const mismatch = run(cask, "--check", "--expect-version", "9.9.9");
  assert.equal(mismatch.status, 1);
  assert.match(mismatch.stderr, /expected version 9\.9\.9/);
  fs.writeFileSync(cask, SOURCE.replace("auto_updates true", "# auto_updates true"));
  const missing = run(cask, "--check");
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /missing cask stanza: auto_updates true/);
});

test("a Ruby syntax error stops both check and update without modifying the cask", (t) => {
  const { cask } = fixture(t);
  const invalid = SOURCE.replace(/end\s*$/, "");
  fs.writeFileSync(cask, invalid);
  for (const args of [["--check"], ["--version", "2.3.4", "--sha256", SHA256]]) {
    const result = run(cask, ...args);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /ruby -c failed/);
    assert.equal(fs.readFileSync(cask, "utf8"), invalid);
  }
});

test("release and local preflight reject a mismatched default checksum; beta skips the cask", (t) => {
  const { root, cask } = fixture(t);
  for (const dir of ["Casks", "dist", "scripts", "docs/release-notes"]) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  fs.renameSync(cask, path.join(root, "Casks/usemac.rb"));
  fs.copyFileSync(UPDATER, path.join(root, "scripts/update-homebrew-cask.py"));
  const release = path.join(root, "scripts/release-dmg.sh");
  fs.copyFileSync(path.join(REPO, "scripts/release-dmg.sh"), release);

  const version = SOURCE.match(/^  version "([^"]+)"/m)[1];
  const checksum = SOURCE.match(/^  sha256 "([^"]+)"/m)[1];
  const sums = path.join(root, `dist/usemac-${version}-SHA256SUMS.txt`);
  const dmg = `usemac-${version}-arm64.dmg`;
  const beta = "2.3.4-beta.1";
  const signUpdate = path.join(root, "scripts/sign_update");
  fs.writeFileSync(signUpdate, "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  fs.writeFileSync(path.join(root, `docs/release-notes/${beta}.html`), "");

  const env = {
    PATH: `${path.dirname(signUpdate)}:${process.env.PATH}`,
    USEMAC_SIGN_IDENTITY: "Developer ID Application: Test",
    USEMAC_SPARKLE_PUBLIC_KEY: "test",
    USEMAC_VERSION: beta,
  };
  const preflight = (...args) => spawnSync("bash", [release, "--check", ...args], { encoding: "utf8", env });

  fs.writeFileSync(sums, `${checksum.toUpperCase()}  ${dmg}\n`);
  const local = preflight("--local");
  assert.equal(local.status, 0, local.stderr);

  fs.writeFileSync(sums, `${"0".repeat(64)}  ${dmg}\n`);
  for (const [mode, flag] of [["local", "--local"], ["release", "--skip-notarize"]]) {
    const result = preflight(flag);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /SHA256SUMS mismatch/);
    assert.match(result.stderr, new RegExp(`${mode} preflight: Homebrew cask validation failed`));
  }

  const result = preflight("--github-beta");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Beta preflight OK/);
});
