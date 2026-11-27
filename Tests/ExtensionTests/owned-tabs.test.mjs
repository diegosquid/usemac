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

test("close_owned_tabs with closeTabIds closes only the finished task's tabs", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 551, windowId: 1, url: "https://mail.example.com/", active: true }],
    windows: [{ id: 1, focused: true }]
  });
  const mine = await openTab(sb);
  const kept = await openTab(sb);
  // Another agent's task opened this one after the daemon built its keep list.
  const theirs = await openTab(sb);

  const { response } = await sb.request({
    type: "request", id: nextId(), command: "close_owned_tabs", keepTabIds: [kept], closeTabIds: [mine, kept]
  });
  assert.equal(response.ok, true);
  assert.deepEqual(response.closedTabs.map((c) => c.tabId), [mine]);
  assert.deepEqual(response.keptTabs.map((k) => [k.tabId, k.reason]), [[kept, "asked to keep"]]);
  assert.deepEqual(sb.callsTo("tabs.remove").map((c) => c.args[0]), [mine], "the other task's tab stays open");

  // It is still owned: a later cleanup without closeTabIds (no task) closes it as before.
  const again = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs", keepTabIds: [] });
  assert.deepEqual(again.response.closedTabs.map((c) => c.tabId).sort(), [kept, theirs].sort());
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

test("finishing tasks in their own windows does not accumulate closed saved UseMac groups", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 751, windowId: 1, url: "https://example.com/", active: true }],
    windows: [{ id: 1, focused: true }]
  });
  for (let cycle = 0; cycle < 3; cycle++) {
    const owned = await openTab(sb, { newWindow: true });
    const { response } = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs", closeTabIds: [owned] });
    assert.deepEqual(response.closedTabs.map((tab) => tab.tabId), [owned]);
    assert.equal(sb.savedGroups.size, 0, "no closed saved group left on the bookmarks bar");
    assert.equal(sb.tabs.has(751), true, "the user's original tab stays open");
  }
});

test("cleanup does not ungroup an owned tab moved into the user's group", async (t) => {
  const sb = withSandbox(t, {
    tabs: [
      { id: 761, windowId: 1, url: "https://example.com/", groupId: 81 },
      { id: 762, windowId: 1, url: "https://example.com/user", groupId: 81, active: true }
    ],
    groups: [{ id: 81, windowId: 1, title: "Work", color: "red" }],
    session: { usemacOwnedTabIds: [761] }
  });
  await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs" });
  assert.equal(sb.callsTo("tabs.ungroup").length, 0);
  assert.equal(sb.tabs.get(762).groupId, 81);
});

test("a failed ungroup keeps the tab for retry instead of saving another closed group", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 771, windowId: 1, url: "https://example.com/", active: true }] });
  const owned = await openTab(sb, { newWindow: true });
  sb.chrome.tabs.ungroup = async () => { throw new Error("Tabs cannot be edited right now"); };
  const { response } = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs" });
  assert.deepEqual(response.closedTabs, []);
  assert.equal(response.keptTabs[0].tabId, owned);
  assert.equal(sb.callsTo("tabs.remove").length, 0);
});

test("a download starting during ungroup keeps the tab open", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 781, windowId: 1, url: "https://example.com/", active: true }] });
  const owned = await openTab(sb, { newWindow: true });
  const ungroup = sb.chrome.tabs.ungroup;
  sb.chrome.tabs.ungroup = async (ids) => {
    await ungroup(ids);
    sb.downloads.create({ id: 1, url: PAGE + "/download", state: "in_progress" });
  };
  const { response } = await sb.request({ type: "request", id: nextId(), command: "close_owned_tabs" });
  assert.deepEqual(response.closedTabs, []);
  assert.deepEqual(response.keptTabs.map(({ tabId, reason }) => [tabId, reason]), [[owned, "a download is still running"]]);
  assert.equal(sb.callsTo("tabs.remove").length, 0);
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

const DOWNLOAD_TAB = 851;
const DOWNLOAD_PAGE = "https://app.example.com/reports";

function withOwnedDownloadTab(t, url = DOWNLOAD_PAGE, options = {}) {
  return withSandbox(t, {
    tabs: [{ id: DOWNLOAD_TAB, windowId: 1, url }],
    session: { usemacOwnedTabIds: [DOWNLOAD_TAB] },
    ...options
  });
}

function closeOwned(sb) {
  return sb.request({ type: "request", id: nextId(), command: "close_owned_tabs" });
}

async function assertDownloadKeepsTab(sb) {
  const { response } = await closeOwned(sb);
  assert.equal(response.ok, true);
  assert.deepEqual(response.closedTabs, []);
  assert.deepEqual(response.keptTabs.map(({ tabId, reason }) => [tabId, reason]), [
    [DOWNLOAD_TAB, "a download is still running"]
  ]);
  assert.equal(sb.callsTo("tabs.remove").length, 0);
}

test("close_owned_tabs keeps a tab with a download redirected from its origin to a CDN", async (t) => {
  const sb = withOwnedDownloadTab(t);
  sb.downloads.create({
    id: 1,
    url: "https://app.example.com/download",
    finalUrl: "https://cdn.example.net/report?signature=abc",
    state: "in_progress"
  });
  await assertDownloadKeepsTab(sb);
  assert.deepEqual(sb.callsTo("downloads.search").map(({ args: [query] }) => query), [{ state: "in_progress" }]);
});

test("close_owned_tabs finds an active Blob download after a service-worker restart", async (t) => {
  const downloadStore = new Map();
  const first = withOwnedDownloadTab(t, DOWNLOAD_PAGE, { downloadStore });
  first.downloads.create({ id: 1, url: "blob:https://app.example.com/report", state: "in_progress" });
  first.dispose();

  const cold = withOwnedDownloadTab(t, DOWNLOAD_PAGE, { downloadStore, session: first.session });
  assert.equal(cold.eval("state.downloads.size"), 0);
  await assertDownloadKeepsTab(cold);
  assert.deepEqual(cold.callsTo("downloads.search").map(({ args: [query] }) => query), [{ state: "in_progress" }]);
});

test("close_owned_tabs rechecks downloads created while tabs.get is pending", async (t) => {
  let downloadCreated = false;
  let sb;
  sb = withOwnedDownloadTab(t, DOWNLOAD_PAGE, {
    apiDelayMs: (api) => {
      if (api !== "tabs.get" || downloadCreated) return 0;
      downloadCreated = true;
      assert.equal(sb.callsTo("downloads.search").length, 1);
      sb.downloads.create({ id: 1, url: "https://app.example.com/download", state: "in_progress" });
      return 10;
    }
  });
  await assertDownloadKeepsTab(sb);
  assert.equal(downloadCreated, true);
});

test("close_owned_tabs does not match a download and a tab solely on opaque origins", async (t) => {
  const sb = withOwnedDownloadTab(t, "data:text/html,local");
  sb.downloads.create({
    id: 1, url: "blob:null/other-document", referrer: "data:text/html,other", state: "in_progress"
  });
  const { response } = await closeOwned(sb);
  assert.equal(response.ok, true);
  assert.deepEqual(response.closedTabs.map(({ tabId }) => tabId), [DOWNLOAD_TAB]);
  assert.deepEqual(response.keptTabs, []);
});

test("close_owned_tabs keeps candidate tabs when the download status query fails", async (t) => {
  const sb = withOwnedDownloadTab(t, DOWNLOAD_PAGE, {
    downloadSearch: () => { throw new Error("downloads service unavailable"); }
  });
  const { response } = await closeOwned(sb);
  assert.equal(response.ok, true);
  assert.deepEqual(response.closedTabs, []);
  assert.deepEqual(response.keptTabs.map(({ tabId, reason }) => [tabId, reason]), [
    [DOWNLOAD_TAB, "download status unavailable"]
  ]);
  assert.equal(sb.callsTo("tabs.remove").length, 0);
});

test("close_owned_tabs uses the Page download association even without a matching origin", async (t) => {
  const sb = withOwnedDownloadTab(t);
  const url = "https://cdn.example.net/report";
  sb.debuggerEvent(DOWNLOAD_TAB, "Page.downloadWillBegin", { url, suggestedFilename: "report.csv" });
  sb.downloads.create({ id: 1, url, state: "in_progress" });
  await assertDownloadKeepsTab(sb);
});
