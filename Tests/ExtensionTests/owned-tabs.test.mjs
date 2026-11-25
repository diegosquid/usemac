import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

// Restricted pages open without attaching the debugger, which keeps these tests about tab ownership only.
const PAGE = "https://chromewebstore.google.com/detail/usemac/abcdefghijklmnop";

let counter = 0;
const nextId = () => `owned-${++counter}`;

function withSandbox(t, options) {
  const sandbox = createBackgroundSandbox(options);
  t.after(() => sandbox.dispose());
  return sandbox;
}

async function openTab(sb, extra = {}) {
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: PAGE, stream: false, ...extra });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  return response.tabId;
}

test("close_owned_tabs closes only tabs UseMac opened, and keeps the ones asked for", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 501, windowId: 1, url: "https://mail.example.com/", active: true }],
    windows: [{ id: 1, focused: true }]
  });
  const first = await openTab(sb);
  const second = await openTab(sb);
  // A user tab reached through tabId is used, but it is not UseMac's to close.
  await sb.request({ type: "request", id: nextId(), command: "open", url: "", tabId: 501, activate: true });

  const { response } = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs", keepTabIds: [first] });
  assert.equal(response.ok, true);
  assert.deepEqual(response.closedTabs.map((c) => c.tabId), [second]);
  assert.deepEqual(response.keptTabs.map((k) => [k.tabId, k.reason]), [[first, "asked to keep"]]);
  assert.deepEqual(sb.callsTo("tabs.remove").map((c) => c.args[0]), [second]);

  // The kept tab is still owned: a later cleanup closes it, and never touches the user's tab.
  const again = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs", keepTabIds: [] });
  assert.deepEqual(again.response.closedTabs.map((c) => c.tabId), [first]);
  assert.ok(!sb.callsTo("tabs.remove").some((c) => c.args[0] === 501));
});

test("close_owned_tabs keeps the UseMac tab the user is looking at", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 601, windowId: 1, url: "https://example.com/", active: true }],
    windows: [{ id: 1, focused: true }]
  });
  const visible = await openTab(sb, { activate: true });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs" });
  assert.deepEqual(response.closedTabs, []);
  assert.deepEqual(response.keptTabs.map((k) => [k.tabId, k.reason]), [[visible, "the user is looking at it"]]);
  assert.equal(sb.callsTo("tabs.remove").length, 0);
});

test("a tab closed by the user is forgotten", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 701, windowId: 1, url: "https://example.com/", active: true }],
    windows: [{ id: 1, focused: true }]
  });
  const owned = await openTab(sb);
  await sb.chrome.tabs.remove(owned);
  const { response } = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs" });
  assert.deepEqual(response.closedTabs, []);
  assert.deepEqual(response.keptTabs, []);
});

test("the tab list marks UseMac's own tabs, never the user's", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 801, windowId: 1, url: "https://forum.example.com/weekend", active: true }],
    windows: [{ id: 1, focused: true }]
  });
  const owned = await openTab(sb);
  const { response } = await sb.request({ type: "request", id: nextId(), command: "tabs" });
  const byId = Object.fromEntries(response.tabs.map((tab) => [tab.tabId, tab]));
  assert.equal(byId[owned].usemac, true);
  assert.equal(byId[801].usemac, undefined);
});
