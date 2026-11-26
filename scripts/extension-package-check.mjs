#!/usr/bin/env node
// Checks Extension/ before scripts/package-extension.sh zips it for the Chrome Web Store. Prints the app version
// on stdout and, with --list-out, writes the files that go in the zip there (one per line, relative to
// Extension/). Exits 1 with every problem on stderr.
//
//   node scripts/extension-package-check.mjs [--root <repo>] [--app-version <x.y.z[-pre]>] [--list-out <file>]
//
// The rules:
// - manifest.json has a numeric `version` (1 to 4 dot-separated integers, 0-65535, no leading zeros). A beta
//   suffix goes only in `version_name`.
// - `version` is the app version without its pre-release suffix, and `version_name` spells the whole app version
//   ("0.6.0 beta 2" for 0.6.0-beta.2; absent or "0.6.0" for 0.6.0). The app version is UseMacDefaults.version in
//   Sources/UseMacProtocol/Models.swift; the defaults in scripts/bundle-app.sh and scripts/release-dmg.sh, and
//   USEMAC_VERSION (--app-version) when it is set, must agree with it.
// - No `key` or `update_url` in the manifest: the store assigns both.
// - Dev files (dotfiles, docs, source maps, tests, package manifests, editor leftovers) stay out of the zip, and a
//   private key (*.pem) anywhere in Extension/ stops the package.
// - Every file the manifest, the HTML pages and importScripts() refer to is in the zip.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEV_FILE_RULES = [
  { test: (segments) => segments.some((s) => s.startsWith(".")), why: "dotfile" },
  { test: (segments) => segments.some((s) => s === "__MACOSX"), why: "macOS archive metadata" },
  {
    test: (segments) => segments.slice(0, -1).some((s) => ["node_modules", "test", "tests", "__tests__"].includes(s)),
    why: "test or dependency folder",
  },
  { test: (segments, base) => /\.(test|spec)\.[cm]?[jt]s$/.test(base), why: "test file" },
  { test: (segments, base) => /\.(map|md|markdown|ts|tsx|log|tmp|bak|swp|orig|rej|zip|crx)$/.test(base), why: "dev file" },
  { test: (segments, base) => base.endsWith("~"), why: "editor backup" },
  {
    test: (segments, base) =>
      ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "tsconfig.json", "jsconfig.json"].includes(base),
    why: "package manifest",
  },
];

/** Why a file under Extension/ stays out of the store zip, or null when it belongs in it. */
export function devFileReason(relPath) {
  const segments = relPath.split("/").filter(Boolean);
  const base = segments[segments.length - 1] || "";
  for (const rule of DEV_FILE_RULES) {
    if (rule.test(segments, base)) return rule.why;
  }
  return null;
}

/** Chrome's `version` rule: 1 to 4 dot-separated integers in 0..65535, non-zero ones without a leading zero. */
export function isChromeVersion(value) {
  if (typeof value !== "string" || !/^\d+(\.\d+){0,3}$/.test(value)) return false;
  return value.split(".").every((part) => (part === "0" || !part.startsWith("0")) && Number(part) <= 65535);
}

/** "0.6.0-beta.2" and "0.6.0 beta 2" both become "0 6 0 beta 2". */
function versionWords(value) {
  return String(value).toLowerCase().replace(/[\s._-]+/g, " ").trim();
}

/** Splits an app version ("0.6.0-beta.2") into the manifest `version` and the `version_name` it implies. */
export function manifestVersionsFor(appVersion) {
  const text = String(appVersion || "").trim();
  const dash = text.indexOf("-");
  const core = dash === -1 ? text : text.slice(0, dash);
  const prerelease = dash === -1 ? "" : text.slice(dash + 1);
  return {
    version: core,
    versionName: prerelease ? `${core} ${versionWords(prerelease)}` : null,
  };
}

/** Problems with manifest.json for a store upload of this app version. */
export function checkManifest(manifest, appVersion) {
  const errors = [];
  if (!manifest || typeof manifest !== "object") return ["manifest.json is not a JSON object"];
  if ("key" in manifest) errors.push('manifest.json must not contain "key" (the store assigns the extension ID)');
  if ("update_url" in manifest) errors.push('manifest.json must not contain "update_url" (the store sets it)');

  const { version, version_name: versionName } = manifest;
  if (!isChromeVersion(version)) {
    errors.push(
      `manifest.json "version" must be 1 to 4 dot-separated integers (got ${JSON.stringify(version)}); ` +
        'put a beta suffix in "version_name" only'
    );
  }
  if (versionName !== undefined && (typeof versionName !== "string" || !versionName.trim())) {
    errors.push('manifest.json "version_name" must be a non-empty string when present');
  }

  const expected = manifestVersionsFor(appVersion);
  if (!isChromeVersion(expected.version)) {
    errors.push(`app version ${JSON.stringify(appVersion)} does not start with a numeric x.y.z version`);
    return errors;
  }
  if (version !== expected.version) {
    errors.push(`manifest.json "version" is ${JSON.stringify(version)}, but the app is ${appVersion} (expected "${expected.version}")`);
  }
  if (expected.versionName) {
    if (typeof versionName !== "string" || versionWords(versionName) !== versionWords(expected.versionName)) {
      errors.push(
        `manifest.json "version_name" is ${JSON.stringify(versionName ?? null)}, but the app is ${appVersion} ` +
          `(expected "${expected.versionName}")`
      );
    }
  } else if (typeof versionName === "string" && versionWords(versionName) !== versionWords(expected.version)) {
    errors.push(
      `manifest.json "version_name" is ${JSON.stringify(versionName)}, but the app is the release ${appVersion} ` +
        `(remove "version_name" or set it to "${expected.version}")`
    );
  }
  return errors;
}

/** Every file under `dir`, relative, with "/" separators, sorted. */
function walk(dir, prefix = "") {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      out.push(...walk(path.join(dir, entry.name), rel));
    } else if (entry.isFile() || entry.isSymbolicLink()) {
      out.push(rel);
    }
  }
  return out.sort();
}

function isLocalReference(ref) {
  return typeof ref === "string" && ref.length > 0 && !/^[a-z][a-z0-9+.-]*:/i.test(ref) && !ref.startsWith("//") &&
    !ref.startsWith("#") && !ref.includes("*");
}

function normalizeRef(fromFile, ref) {
  const clean = ref.split(/[?#]/)[0];
  const joined = clean.startsWith("/") ? clean.slice(1) : path.posix.join(path.posix.dirname(fromFile), clean);
  return path.posix.normalize(joined);
}

/** Files that manifest.json, the packaged HTML pages and importScripts() calls refer to. */
export function referencedFiles(manifest, readFile) {
  const refs = new Set();
  const add = (from, ref) => {
    if (isLocalReference(ref)) refs.add(normalizeRef(from, ref));
  };
  const addIcons = (value) => {
    if (typeof value === "string") add("manifest.json", value);
    else if (value && typeof value === "object") Object.values(value).forEach((v) => add("manifest.json", v));
  };

  const background = manifest.background || {};
  add("manifest.json", background.service_worker);
  (background.scripts || []).forEach((s) => add("manifest.json", s));
  add("manifest.json", background.page);
  addIcons(manifest.icons);
  for (const action of [manifest.action, manifest.browser_action, manifest.page_action]) {
    if (!action) continue;
    add("manifest.json", action.default_popup);
    addIcons(action.default_icon);
  }
  add("manifest.json", manifest.options_page);
  add("manifest.json", manifest.options_ui?.page);
  add("manifest.json", manifest.side_panel?.default_path);
  add("manifest.json", manifest.devtools_page);
  Object.values(manifest.chrome_url_overrides || {}).forEach((v) => add("manifest.json", v));
  for (const script of manifest.content_scripts || []) {
    (script.js || []).forEach((s) => add("manifest.json", s));
    (script.css || []).forEach((s) => add("manifest.json", s));
  }

  // Follow the pages and scripts the manifest names, one level at a time.
  const queue = [...refs];
  const seen = new Set();
  while (queue.length) {
    const file = queue.shift();
    if (seen.has(file)) continue;
    seen.add(file);
    const text = readFile(file);
    if (text == null) continue;
    const found = [];
    if (file.endsWith(".html")) {
      for (const match of text.matchAll(/\s(?:src|href)\s*=\s*["']([^"']+)["']/gi)) found.push(match[1]);
    } else if (file.endsWith(".js")) {
      for (const call of text.matchAll(/importScripts\(([^)]*)\)/g)) {
        for (const literal of call[1].matchAll(/["']([^"']+)["']/g)) found.push(literal[1]);
      }
    }
    for (const ref of found) {
      if (!isLocalReference(ref)) continue;
      const normalized = normalizeRef(file, ref);
      refs.add(normalized);
      queue.push(normalized);
    }
  }
  return [...refs].sort();
}

/** The app version every release file must agree on, or the problems that stop the package. */
export function resolveAppVersion(rootDir, override) {
  const errors = [];
  const sources = [];
  const read = (rel, pattern) => {
    const file = path.join(rootDir, rel);
    if (!fs.existsSync(file)) return;
    const match = fs.readFileSync(file, "utf8").match(pattern);
    if (match) sources.push({ where: rel, version: match[1] });
    else errors.push(`could not find the app version in ${rel}`);
  };
  read("Sources/UseMacProtocol/Models.swift", /public static let version = "([^"]+)"/);
  read("scripts/bundle-app.sh", /APP_VERSION="\$\{USEMAC_VERSION:-([^}]+)\}"/);
  read("scripts/release-dmg.sh", /VERSION="\$\{USEMAC_VERSION:-([^}]+)\}"/);
  if (!sources.length) {
    errors.push("no app version found (Sources/UseMacProtocol/Models.swift)");
    return { version: null, errors };
  }
  const version = sources[0].version;
  for (const source of sources.slice(1)) {
    if (source.version !== version) {
      errors.push(`${source.where} defaults to ${source.version}, but ${sources[0].where} says ${version}`);
    }
  }
  if (override && override !== version) {
    errors.push(`USEMAC_VERSION is ${override}, but ${sources[0].where} says ${version}`);
  }
  return { version, errors };
}

/** Everything package-extension.sh needs: the files to zip, the dev files left out, and every problem found. */
export function checkPackage(extDir, appVersion) {
  const errors = [];
  const manifestPath = path.join(extDir, "manifest.json");
  let manifest = null;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (error) {
    return { errors: [`cannot read ${manifestPath}: ${error.message}`], files: [], excluded: [], manifest: null };
  }
  errors.push(...checkManifest(manifest, appVersion));

  const files = [];
  const excluded = [];
  for (const rel of walk(extDir)) {
    if (/\.pem$/i.test(rel)) {
      errors.push(`${rel} looks like a private key; move it out of Extension/ before packaging`);
      continue;
    }
    const reason = devFileReason(rel);
    if (reason) excluded.push({ file: rel, reason });
    else files.push(rel);
  }

  const packaged = new Set(files);
  const readFile = (rel) => (packaged.has(rel) ? fs.readFileSync(path.join(extDir, rel), "utf8") : null);
  for (const ref of referencedFiles(manifest, readFile)) {
    if (!packaged.has(ref)) {
      const why = excluded.find((e) => e.file === ref)?.reason;
      errors.push(why ? `${ref} is referenced but left out as a ${why}` : `${ref} is referenced but missing from Extension/`);
    }
  }
  return { errors, files, excluded, manifest };
}

function main(argv) {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  let rootDir = path.resolve(scriptDir, "..");
  let override = process.env.USEMAC_VERSION || "";
  let listOut = null;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--root") rootDir = path.resolve(argv[++i]);
    else if (argv[i] === "--app-version") override = argv[++i] || "";
    else if (argv[i] === "--list-out") listOut = argv[++i];
    else {
      process.stderr.write("Usage: extension-package-check.mjs [--root <repo>] [--app-version <version>] [--list-out <file>]\n");
      return 2;
    }
  }

  const app = resolveAppVersion(rootDir, override.trim());
  const result = app.version ? checkPackage(path.join(rootDir, "Extension"), app.version) : { errors: [], files: [], excluded: [] };
  const errors = [...app.errors, ...result.errors];
  for (const { file, reason } of result.excluded) {
    process.stderr.write(`left out (${reason}): ${file}\n`);
  }
  if (errors.length) {
    for (const error of errors) process.stderr.write(`extension package: ${error}\n`);
    return 1;
  }
  const { version, version_name: versionName } = result.manifest;
  process.stderr.write(`extension ${version}${versionName ? ` (${versionName})` : ""} matches app ${app.version}\n`);
  if (listOut) fs.writeFileSync(listOut, result.files.map((f) => `${f}\n`).join(""));
  process.stdout.write(`${app.version}\n`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
