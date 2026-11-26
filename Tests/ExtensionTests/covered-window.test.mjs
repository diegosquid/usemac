import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

// The active tab of a window covered by other windows counts as visible (isTabVisibleToUser), but Chrome stops
// painting it, so its screencast goes quiet. When that happens and the page reports document.visibilityState
// "hidden", the tab goes back to screenshot polling at its real size, until the page is visible again.
const SET = "Emulation.setDeviceMetricsOverride";
const CLEAR = "Emulation.clearDeviceMetricsOverride";
const VISIBLE = 21;
const JPEG = "/9j/4AAQSkZJRgABAQ==";
const POLL_WINDOW_MS = 650; // at least two pump ticks (CAPTURE_INTERVAL_MS = 240 ms)

let counter = 0;
const nextId = () => `covered-${++counter}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function withSandbox(t, page) {
  const sb = createBackgroundSandbox({
    tabs: [{ id: VISIBLE, windowId: 1, url: "https://example.com/covered", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => {
      if (method === "Runtime.evaluate" && params?.expression === "document.visibilityState") {
        page.probes += 1;
        return { result: { value: page.visibility } };
      }
      if (method === "Page.captureScreenshot") return { data: JPEG };
      return undefined;
    }
  });
  t.after(() => sb.dispose());
  return sb;
}

const cdpMethods = (sb, tabId) =>
  sb.callsTo("debugger.sendCommand").filter((c) => c.args[0] === tabId).map((c) => c.args[1]);
const metricsCalls = (sb, tabId) => cdpMethods(sb, tabId).filter((m) => m === SET || m === CLEAR);
const screenshotCount = (sb, tabId) => cdpMethods(sb, tabId).filter((m) => m === "Page.captureScreenshot").length;
const pumpRunning = (sb, tabId) => sb.eval(`Boolean(state.tabSessions.get(${tabId})?.capturePumpTimer)`);
const covered = (sb, tabId) => sb.eval(`Boolean(state.tabSessions.get(${tabId})?.coveredWhileVisible)`);

function screencastFrame(sb, tabId) {
  sb.chrome.debugger.onEvent.emit({ tabId }, "Page.screencastFrame", { data: JPEG, sessionId: 1 });
}

async function waitFor(predicate, message, timeoutMs = 2500) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) throw new Error(`Timed out waiting for: ${message}`);
    await sleep(10);
  }
}

async function observe(sb, tabId) {
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  return response;
}

async function assertPolls(sb, tabId) {
  assert.equal(pumpRunning(sb, tabId), true, `tab ${tabId} has a capture pump`);
  const before = screenshotCount(sb, tabId);
  await sleep(POLL_WINDOW_MS);
  assert.ok(screenshotCount(sb, tabId) > before, `tab ${tabId} is polled for screenshots`);
}

async function assertNoPolling(sb, tabId) {
  assert.equal(pumpRunning(sb, tabId), false, `tab ${tabId} has no capture pump`);
  const before = screenshotCount(sb, tabId);
  await sleep(POLL_WINDOW_MS);
  assert.equal(screenshotCount(sb, tabId), before, `tab ${tabId} gets no polling screenshots`);
}

test("a visible tab whose window is covered goes back to screenshot polling at its real size", async (t) => {
  const page = { visibility: "hidden", probes: 0 };
  const sb = withSandbox(t, page);
  await observe(sb, VISIBLE);
  assert.equal(sb.eval(`state.tabSessions.get(${VISIBLE}).visibleToUser`), true, "it still counts as visible");

  await waitFor(() => covered(sb, VISIBLE), "the covered window to be detected");
  await assertPolls(sb, VISIBLE);
  // No metrics override: the page keeps its layout and the user sees no reflow when the window comes back.
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR]);
  const frames = sb.sent.filter((f) => f.type === "frame" && f.tabId === VISIBLE);
  assert.ok(frames.length >= 2, "the preview keeps getting frames");
});

test("polling stops when the covered window comes back on top", async (t) => {
  const page = { visibility: "hidden", probes: 0 };
  const sb = withSandbox(t, page);
  await observe(sb, VISIBLE);
  await waitFor(() => covered(sb, VISIBLE), "the covered window to be detected");

  // The user brings the window back: Chrome paints again and the screencast speaks, which triggers a re-check.
  page.visibility = "visible";
  screencastFrame(sb, VISIBLE);
  await waitFor(() => !covered(sb, VISIBLE), "the window to count as uncovered");
  await assertNoPolling(sb, VISIBLE);
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR]);
});

test("a frame captured while covered does not end polling while the page is still hidden", async (t) => {
  const page = { visibility: "hidden", probes: 0 };
  const sb = withSandbox(t, page);
  await observe(sb, VISIBLE);
  await waitFor(() => covered(sb, VISIBLE), "the covered window to be detected");

  const probesBefore = page.probes;
  screencastFrame(sb, VISIBLE); // e.g. a side effect of a capture
  await waitFor(() => page.probes > probesBefore, "a re-check after the frame");
  assert.equal(covered(sb, VISIBLE), true);
  await assertPolls(sb, VISIBLE);
});

test("a static page on screen (quiet screencast, visible page) is never polled", async (t) => {
  const page = { visibility: "visible", probes: 0 };
  const sb = withSandbox(t, page);
  await observe(sb, VISIBLE);

  await waitFor(() => page.probes >= 1, "the quiet screencast to be checked");
  assert.equal(covered(sb, VISIBLE), false);
  await assertNoPolling(sb, VISIBLE);
  // Probes are throttled to about one a second.
  const probes = page.probes;
  await sleep(500);
  assert.ok(page.probes <= probes + 1, `at most one more probe in 500 ms (got ${page.probes - probes})`);
});

test("a tab whose screencast keeps sending frames is not probed", async (t) => {
  const page = { visibility: "hidden", probes: 0 };
  const sb = withSandbox(t, page);
  // Frames start as soon as the debugger is attached (they are ignored before that).
  const ticker = setInterval(() => screencastFrame(sb, VISIBLE), 60);
  t.after(() => clearInterval(ticker));
  await observe(sb, VISIBLE);
  await sleep(1400);
  clearInterval(ticker);

  assert.equal(page.probes, 0, "no visibility probes while frames arrive");
  assert.equal(covered(sb, VISIBLE), false);
  assert.equal(pumpRunning(sb, VISIBLE), false);
});

test("a covered tab the user switches away from keeps the hidden-tab mode, and starts over when shown", async (t) => {
  const page = { visibility: "hidden", probes: 0 };
  const sb = createBackgroundSandbox({
    tabs: [
      { id: VISIBLE, windowId: 1, url: "https://example.com/covered", active: true },
      { id: 22, windowId: 1, url: "https://example.com/other", active: false }
    ],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => {
      if (method === "Runtime.evaluate" && params?.expression === "document.visibilityState") {
        page.probes += 1;
        return { result: { value: page.visibility } };
      }
      if (method === "Page.captureScreenshot") return { data: JPEG };
      return undefined;
    }
  });
  t.after(() => sb.dispose());
  await observe(sb, VISIBLE);
  await waitFor(() => covered(sb, VISIBLE), "the covered window to be detected");

  sb.activateTab(22);
  await waitFor(() => sb.eval(`state.tabQueues.size === 0`) && !covered(sb, VISIBLE), "the hidden-tab mode");
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET], "a hidden tab gets the override as before");
  await assertPolls(sb, VISIBLE);

  page.visibility = "visible";
  sb.activateTab(VISIBLE);
  await waitFor(() => sb.eval(`state.tabQueues.size === 0`), "the visibility sync");
  await waitFor(() => !pumpRunning(sb, VISIBLE), "the pump to stop");
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET, CLEAR]);
  await assertNoPolling(sb, VISIBLE);
});

test("the watch stops with the stream", async (t) => {
  const page = { visibility: "hidden", probes: 0 };
  const sb = withSandbox(t, page);
  await observe(sb, VISIBLE);
  await waitFor(() => covered(sb, VISIBLE), "the covered window to be detected");
  const session = sb.eval(`globalThis.__coveredSession = state.tabSessions.get(${VISIBLE}); true`);
  assert.equal(session, true);

  await sb.eval(`stopStreamingAndDetach(${VISIBLE}, true, "stopped")`);
  await sleep(400);
  assert.equal(sb.eval("globalThis.__coveredSession.stallWatchTimer"), null);
  assert.equal(sb.eval("globalThis.__coveredSession.capturePumpTimer"), null);
  const probes = page.probes;
  await sleep(1200);
  assert.equal(page.probes, probes, "no probes after the stream stopped");
});
