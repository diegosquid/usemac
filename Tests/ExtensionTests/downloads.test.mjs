import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

const TAB = 51;
const PAGE = "https://app.example.com/report";
const BLOB = "blob:https://app.example.com/export";
const LOCAL_PATH = "/Users/test/Downloads/report.csv";
const CLICK = { action: "click", x: 120, y: 120 };
let sequence = 0;

function sandbox(t, options = {}) {
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: PAGE, active: true }],
    ...options
  });
  t.after(() => sb.dispose());
  return sb;
}

function download(id, fields = {}) {
  return {
    id,
    url: "https://app.example.com/download",
    referrer: PAGE,
    state: "in_progress",
    filename: "",
    bytesReceived: 0,
    totalBytes: 128,
    mime: "text/csv",
    startTime: new Date().toISOString(),
    ...fields
  };
}

function request(sb, command, fields = {}) {
  return sb.request({ type: "request", id: `download-test-${++sequence}`, command, ...fields });
}

async function extractDownloads(sb, fields = {}) {
  const { response } = await request(sb, "extract", { mode: "downloads", ...fields });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  return response;
}

function act(sb, steps = [CLICK], tabId = TAB, id = `download-act-${++sequence}`) {
  return sb.request({ type: "request", id, command: "act", tabId, steps, returnObservation: false });
}

test("downloads extraction reads a cold worker's profile, orders newest first and caps at 20 within 24 hours", async (t) => {
  const downloadStore = new Map();
  const first = sandbox(t, { downloadStore });
  const now = Date.now();
  for (let id = 1; id <= 23; id++) {
    first.downloads.create(download(id, { startTime: new Date(now - (24 - id) * 1000).toISOString() }));
  }
  first.downloads.create(download(24, { startTime: new Date(now - 25 * 60 * 60 * 1000).toISOString() }));
  first.dispose();

  const cold = sandbox(t, { downloadStore, tabs: [] });
  assert.equal(cold.eval("state.downloads.size"), 0);
  const { extractResult } = await extractDownloads(cold);
  assert.deepEqual(extractResult.downloads.map((item) => item.id), Array.from({ length: 20 }, (_, i) => 23 - i));
  assert.deepEqual(cold.callsTo("downloads.search").map(({ args: [query] }) => [query.orderBy, query.limit]), [
    [["-startTime"], 20]
  ]);
  const cutoff = Date.parse(cold.callsTo("downloads.search")[0].args[0].startedAfter);
  assert.ok(cutoff >= now - 86400000 && cutoff <= Date.now() - 86400000);
  assert.deepEqual(Object.keys(extractResult.downloads[0]).sort(), [
    "bytesReceived", "error", "filename", "id", "mime", "originalUrl", "referrer", "startTime", "state", "totalBytes", "url"
  ]);
  cold.downloads.erase(1);
  cold.downloads.erase(2);
  cold.downloads.erase(3);
  cold.downloads.erase(4);
  assert.equal((await extractDownloads(cold)).extractResult.downloads.some(({ id }) => id === 24), false);
});

test("downloads extraction retries without startedAfter but still filters older records", async (t) => {
  const old = download(1, { startTime: new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString() });
  const recent = download(2);
  const sb = sandbox(t, {
    downloadStore: new Map([[1, old], [2, recent]]),
    downloadSearch: (query, found) => {
      if ("startedAfter" in query) throw new Error("Unknown option startedAfter");
      return found;
    }
  });
  assert.deepEqual((await extractDownloads(sb)).extractResult.downloads.map(({ id }) => id), [2]);
  assert.equal(sb.callsTo("downloads.search").length, 2);
  assert.deepEqual(sb.callsTo("downloads.search")[1].args[0], { orderBy: ["-startTime"], limit: 20 });
});

test("a terminal downloads delta refreshes bytesReceived by id and deduplicates concurrent refreshes", async (t) => {
  let finishSearch;
  const sb = sandbox(t, {
    downloadSearch: (query, found) => query.id == null ? found : new Promise((resolve) => {
      finishSearch = () => resolve(found);
    })
  });
  sb.downloads.create(download(2, { bytesReceived: 30 }));
  sb.downloads.change({ id: 2, state: { current: "complete" } }, { bytesReceived: 93 });
  sb.downloads.change({ id: 2, state: { current: "complete" } });
  assert.equal(sb.eval("state.downloads.get(2).progressStale"), true);
  assert.deepEqual(sb.callsTo("downloads.search").map(({ args: [query] }) => query), [{ id: 2 }]);
  finishSearch();
  await new Promise(setImmediate);
  assert.equal(sb.eval("state.downloads.get(2).progressStale"), false);
  assert.equal(sb.eval("state.downloads.get(2).bytesReceived"), 93);
  const [item] = (await extractDownloads(sb)).extractResult.downloads;
  assert.equal(item.state, "complete");
  assert.equal(item.bytesReceived, 93, "bytesReceived comes from Chrome, not totalBytes");
});

test("a terminal delta schedules a fresh query after an in-flight progress poll", async (t) => {
  let finishPoll;
  const sb = sandbox(t, {
    downloadSearch: (query, found) => {
      if (found[0]?.state !== "in_progress") return found;
      return new Promise((resolve) => { finishPoll = () => resolve(found); });
    }
  });
  sb.downloads.create(download(1, { bytesReceived: 30 }));
  const initialPoll = sb.call("refreshDownload", 1);
  sb.downloads.change({ id: 1, state: { current: "complete" } }, { bytesReceived: 100 });
  assert.equal(sb.callsTo("downloads.search").length, 1);
  finishPoll();
  await initialPoll;
  await new Promise(setImmediate);
  assert.deepEqual(sb.callsTo("downloads.search").map(({ args: [query] }) => query), [{ id: 1 }, { id: 1 }]);
  assert.equal(sb.eval("state.downloads.get(1).bytesReceived"), 100);
  assert.equal(sb.eval("state.downloads.get(1).progressStale"), false);
});

test("download records normalize unknown bytes, preserve redirect origins and clear a removed error", async (t) => {
  const sb = sandbox(t);
  const original = "https://app.example.com/file";
  const final = "https://cdn.example.net/file";
  sb.downloads.create(download(1, { url: original, totalBytes: -1, bytesReceived: -1, error: "NETWORK_FAILED" }));
  let [item] = (await extractDownloads(sb)).extractResult.downloads;
  assert.equal(item.totalBytes, null);
  assert.equal(item.bytesReceived, null);
  assert.equal(item.error, "NETWORK_FAILED");

  sb.downloads.change({
    id: 1,
    filename: { current: LOCAL_PATH },
    finalUrl: { current: final },
    totalBytes: { previous: 64, current: -1 },
    mime: { current: "text/plain" },
    error: { previous: "NETWORK_FAILED" }
  });
  delete sb.chrome.downloads.search;
  [item] = (await extractDownloads(sb)).extractResult.downloads;
  assert.deepEqual(item, {
    id: 1, filename: LOCAL_PATH, url: final, originalUrl: original, referrer: PAGE, state: "in_progress",
    bytesReceived: null, totalBytes: null, mime: "text/plain", startTime: item.startTime, error: null
  });
});

test("failed searches fall back to cached downloads without reporting stale received bytes", async (t) => {
  const sb = sandbox(t, { downloadSearch: () => { throw new Error("profile download search unavailable"); } });
  sb.downloads.create(download(1, { bytesReceived: 64, totalBytes: 128 }));
  sb.downloads.change({ id: 1, state: { current: "interrupted" }, error: { current: "NETWORK_FAILED" } });
  const [item] = (await extractDownloads(sb)).extractResult.downloads;
  assert.equal(item.state, "interrupted");
  assert.equal(item.error, "NETWORK_FAILED");
  assert.equal(item.bytesReceived, null);
  assert.equal(item.totalBytes, 128);
});

test("an older search snapshot cannot downgrade a download after a completion delta", async (t) => {
  let finishListing;
  const sb = sandbox(t, {
    downloadSearch: (query, found) => query.id != null ? found : new Promise((resolve) => {
      finishListing = () => resolve(found);
    })
  });
  sb.downloads.create(download(1, { bytesReceived: 64 }));
  const listing = extractDownloads(sb);
  await new Promise(setImmediate);
  sb.downloads.change({ id: 1, state: { current: "complete" } }, { bytesReceived: 128 });
  finishListing();
  const [item] = (await listing).extractResult.downloads;
  assert.equal(item.state, "complete");
  assert.equal(item.bytesReceived, 128);
});

test("an erased download and its tab association cannot be resurrected by an in-flight search", async (t) => {
  let finishListing;
  const sb = sandbox(t, {
    downloadSearch: (query, found) => new Promise((resolve) => { finishListing = () => resolve(found); })
  });
  sb.debuggerEvent(TAB, "Page.downloadWillBegin", { url: BLOB, suggestedFilename: "report.csv" });
  sb.downloads.create(download(3, { url: BLOB }));
  assert.equal(sb.eval("state.downloadTabById.get(3)"), TAB);

  const listing = extractDownloads(sb);
  await new Promise(setImmediate);
  sb.downloads.erase(3);
  finishListing();
  assert.deepEqual((await listing).extractResult.downloads, []);
  assert.equal(sb.eval("state.downloads.has(3)"), false);
  assert.equal(sb.eval("state.downloadTabById.has(3)"), false);
  assert.equal(sb.eval("state.erasedDownloads.size"), 0);
});

test("orphaned downloads deltas still cap the in-memory download cache at 40", (t) => {
  const sb = sandbox(t);
  for (let id = 1; id <= 55; id++) {
    sb.downloads.change({ id, totalBytes: { current: 100 } });
  }
  assert.equal(sb.eval("state.downloads.size"), 40);
  assert.equal(sb.eval("state.downloads.keys().next().value"), 16);
});

test("downloads mode trims whitespace and uses a null tab, URL and title even for a missing requested tab", async (t) => {
  const sb = sandbox(t);
  sb.eval(`state.lastTabId = ${TAB}`);
  const response = await extractDownloads(sb, { mode: " DOWNLOADS ", tabId: 9999 });
  for (const envelope of [response, response.extractResult]) {
    assert.equal(envelope.tabId, null);
    assert.equal(envelope.url, null);
    assert.equal(envelope.title, null);
  }
  assert.equal(response.extractResult.mode, "downloads");
  assert.equal(sb.callsTo("debugger.attach").length, 0);
});

test("a Blob started 460 ms after a click is reconciled during the batch's existing wait", async (t) => {
  let timer;
  let sb;
  sb = sandbox(t, {
    cdp: (tabId, method, params) => {
      if (method !== "Input.dispatchMouseEvent" || params.type !== "mouseReleased") return;
      timer = setTimeout(() => {
        sb.debuggerEvent(tabId, "Page.downloadWillBegin", { url: BLOB, suggestedFilename: "report.csv" }, "child");
        sb.downloads.create(download(4, { url: BLOB, referrer: "", state: "complete" }));
        sb.downloadStore.get(4).filename = LOCAL_PATH;
      }, 460);
    }
  });
  t.after(() => clearTimeout(timer));

  const { response } = await act(sb, [CLICK, { action: "wait", durationMs: 620 }]);
  assert.equal(response.ok, true, JSON.stringify(response.error));
  const [click, wait] = response.actionResult.stepResults;
  assert.equal(click.downloadPath, LOCAL_PATH);
  assert.equal(click.mechanism, "cdp-mouse (download)");
  assert.equal(wait.downloadPath, null);
  assert.deepEqual(sb.callsTo("downloads.search").map(({ args: [query] }) => query), [{ id: 4 }]);
  assert.equal(sb.eval("state.downloadTabById.get(4)"), TAB);
});

test("a download explicitly attributed to another tab never becomes this click's path, even on the same origin", async (t) => {
  let sb;
  sb = sandbox(t, {
    cdp: (tabId, method, params) => {
      if (method !== "Input.dispatchMouseEvent" || params.type !== "mouseReleased") return;
      sb.debuggerEvent(TAB + 1, "Page.downloadWillBegin", { url: BLOB });
      sb.downloads.create(download(5, { url: BLOB, filename: LOCAL_PATH, state: "complete" }));
    }
  });
  const { response } = await act(sb);
  const [click] = response.actionResult.stepResults;
  assert.equal(click.mechanism, "cdp-mouse");
  assert.equal(click.downloadPath, null);
  assert.equal(sb.eval("state.downloadTabById.get(5)"), TAB + 1);
});

test("an origin match alone is not enough to attach a download during concurrent clicks", async (t) => {
  let arrivals = 0;
  let release;
  const bothClicks = new Promise((resolve) => { release = resolve; });
  let sb;
  sb = sandbox(t, {
    tabs: [
      { id: TAB, url: PAGE, active: true },
      { id: TAB + 1, url: "https://app.example.com/another-page" }
    ],
    cdp: (tabId, method, params) => {
      if (method !== "Input.dispatchMouseEvent" || params.type !== "mouseReleased") return;
      if (++arrivals === 2) {
        sb.downloads.create(download(6, { url: BLOB, filename: LOCAL_PATH, state: "complete" }));
        release();
      }
      return bothClicks;
    }
  });
  for (const { response } of await Promise.all([act(sb), act(sb, [CLICK], TAB + 1)])) {
    assert.equal(response.ok, true, JSON.stringify(response.error));
    assert.equal(response.actionResult.stepResults[0].downloadPath, null);
  }
});

test("interrupted downloads and non-local filenames never become downloadPath or echo a download URL", async (t) => {
  const secretUrl = "https://cdn.example.net/file?token=secret";
  const cases = [
    { state: "interrupted", filename: "", error: "NETWORK_FAILED", message: "Download interrupted (NETWORK_FAILED)" },
    { state: "interrupted", filename: secretUrl, error: secretUrl, message: "Download interrupted" },
    { state: "interrupted", filename: LOCAL_PATH, message: "Download interrupted" },
    { state: "complete", filename: secretUrl, message: "Download complete" },
    { state: "complete", filename: "//cdn.example.net/report.csv", message: "Download complete" },
    { state: "complete", filename: "blob:https://app.example.com/secret", message: "Download complete" },
    { state: "complete", filename: "relative/report.csv", message: "Download complete" }
  ];
  let current = 0;
  let sb;
  sb = sandbox(t, {
    cdp: (tabId, method, params) => {
      if (method !== "Input.dispatchMouseEvent" || params.type !== "mouseReleased") return;
      const { message, ...fields } = cases[current];
      sb.downloads.create(download(current + 1, { finalUrl: secretUrl, ...fields }));
    }
  });
  for (const expected of cases) {
    const { response } = await act(sb);
    const [click] = response.actionResult.stepResults;
    assert.equal(click.mechanism, "cdp-mouse (download)");
    assert.equal(click.downloadPath, null);
    assert.equal(click.message, expected.message);
    current++;
  }
});

test("cancelling a click with an in-progress download stops waiting without publishing a path", async (t) => {
  let startSearch;
  const searched = new Promise((resolve) => { startSearch = resolve; });
  let sb;
  sb = sandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === "Input.dispatchMouseEvent" && params.type === "mouseReleased") {
        sb.downloads.create(download(7, { filename: LOCAL_PATH }));
      }
    },
    downloadSearch: () => {
      startSearch();
      return new Promise(() => {});
    }
  });
  const id = "download-click-to-cancel";
  const pending = act(sb, [CLICK], TAB, id);
  await searched;
  await sb.deliver({ type: "cancel", tabId: null, requestId: id });
  const { response } = await pending;
  assert.equal(response.error?.code, "CANCELLED");
  assert.equal(response.actionResult.stepResults[0].downloadPath ?? null, null);
  assert.equal(sb.eval("state.activeDownloadClicks.size"), 0);
});

test("an ordinary click does not sleep beyond the existing animation-frame guard or query downloads", async (t) => {
  const sb = sandbox(t);
  await request(sb, "observe", { tabId: TAB });
  sb.eval(`
    globalThis.observedSleeps = [];
    const originalSleep = sleep;
    sleep = (ms) => { observedSleeps.push(ms); return originalSleep(ms); };
  `);
  const { response } = await act(sb);
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.actionResult.stepResults[0].mechanism, "cdp-mouse");
  assert.equal(response.actionResult.stepResults[0].downloadPath, null);
  assert.deepEqual(Array.from(sb.eval("observedSleeps")), [65]);
  assert.equal(sb.callsTo("downloads.search").length, 0);
});
