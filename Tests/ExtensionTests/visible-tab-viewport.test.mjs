import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

// A tab the user is looking at keeps its real window size and gets no screenshot polling; a hidden tab keeps the
// 1280x800 metrics override and the capture pump (CAPTURE_INTERVAL_MS = 240 ms).
const PUMP_WINDOW_MS = 650; // at least two pump ticks
const SET = "Emulation.setDeviceMetricsOverride";
const CLEAR = "Emulation.clearDeviceMetricsOverride";
const VISIBLE = 11;
const HIDDEN = 12;
const JPEG = "/9j/4AAQSkZJRgABAQ==";

let counter = 0;
const nextId = () => `visible-${++counter}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function withSandbox(t, options = {}) {
  const sandbox = createBackgroundSandbox({
    tabs: [
      { id: VISIBLE, windowId: 1, url: "https://example.com/visible", active: true },
      { id: HIDDEN, windowId: 1, url: "https://example.com/hidden", active: false }
    ],
    windows: [{ id: 1, focused: true }],
    ...options
  });
  t.after(() => sandbox.dispose());
  return sandbox;
}

const cdpMethods = (sb, tabId) =>
  sb.callsTo("debugger.sendCommand").filter((c) => c.args[0] === tabId).map((c) => c.args[1]);
const metricsCalls = (sb, tabId) => cdpMethods(sb, tabId).filter((m) => m === SET || m === CLEAR);
const screenshotCount = (sb, tabId) => cdpMethods(sb, tabId).filter((m) => m === "Page.captureScreenshot").length;
const pumpRunning = (sb, tabId) => sb.eval(`Boolean(state.tabSessions.get(${tabId})?.capturePumpTimer)`);

async function waitFor(predicate, message, timeoutMs = 2000) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) throw new Error(`Timed out waiting for: ${message}`);
    await sleep(10);
  }
}

// Visibility re-checks run in the tabs' command queues; once those are empty they are done.
const queuesIdle = (sb) => waitFor(() => sb.eval("state.tabQueues.size === 0"), "tab queues to drain");

async function observe(sb, tabId, extra = {}) {
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId, ...extra });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  return response;
}

async function assertPumpPolls(sb, tabId) {
  assert.equal(pumpRunning(sb, tabId), true, `tab ${tabId} has a capture pump`);
  const before = screenshotCount(sb, tabId);
  await sleep(PUMP_WINDOW_MS);
  assert.ok(screenshotCount(sb, tabId) > before, `tab ${tabId} is polled for screenshots`);
}

async function assertNoPolling(sb, tabId) {
  assert.equal(pumpRunning(sb, tabId), false, `tab ${tabId} has no capture pump`);
  const before = screenshotCount(sb, tabId);
  await sleep(PUMP_WINDOW_MS);
  assert.equal(screenshotCount(sb, tabId), before, `tab ${tabId} gets no polling screenshots`);
}

test("a hidden tab gets the 1280x800 metrics override and the screenshot pump", async (t) => {
  const overrides = [];
  const sb = withSandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === SET) overrides.push([tabId, params.width, params.height]);
    }
  });
  await observe(sb, HIDDEN);

  assert.deepEqual(metricsCalls(sb, HIDDEN), [SET]);
  assert.deepEqual(overrides, [[HIDDEN, 1280, 800]]);
  await assertPumpPolls(sb, HIDDEN);
});

test("the active tab of a normal window keeps its real size and is not polled for screenshots", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);

  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR]);
  assert.ok(cdpMethods(sb, VISIBLE).includes("Page.startScreencast"), "frames come from the screencast");
  assert.ok(screenshotCount(sb, VISIBLE) <= 1, "at most the one frame sent when streaming starts");
  await assertNoPolling(sb, VISIBLE);
});

test("the active tab of a minimized window counts as hidden", async (t) => {
  const sb = withSandbox(t, { windows: [{ id: 1, focused: false, state: "minimized" }] });
  await observe(sb, VISIBLE);

  assert.deepEqual(metricsCalls(sb, VISIBLE), [SET]);
  await assertPumpPolls(sb, VISIBLE);
});

test("switching tabs moves the override and the pump to the tab the user left", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);
  await observe(sb, HIDDEN);
  assert.equal(pumpRunning(sb, VISIBLE), false);
  assert.equal(pumpRunning(sb, HIDDEN), true);

  sb.activateTab(HIDDEN);
  await queuesIdle(sb);

  assert.deepEqual(metricsCalls(sb, HIDDEN), [SET, CLEAR], "the tab the user switched to loses the override");
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET], "the tab the user left gets it");
  await Promise.all([assertNoPolling(sb, HIDDEN), assertPumpPolls(sb, VISIBLE)]);

  // And back again.
  sb.activateTab(VISIBLE);
  await queuesIdle(sb);
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET, CLEAR]);
  assert.deepEqual(metricsCalls(sb, HIDDEN), [SET, CLEAR, SET]);
  await Promise.all([assertNoPolling(sb, VISIBLE), assertPumpPolls(sb, HIDDEN)]);
});

test("minimizing and restoring the window switches its active tab between the two modes", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);

  sb.setWindowState(1, "minimized");
  await queuesIdle(sb);
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET]);
  assert.equal(pumpRunning(sb, VISIBLE), true);

  sb.setWindowState(1, "normal");
  await queuesIdle(sb);
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET, CLEAR]);
  await assertNoPolling(sb, VISIBLE);
});

test("events that change nothing do not touch the metrics", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);
  await observe(sb, HIDDEN);

  sb.events.windowsFocusChanged.emit(1);
  sb.events.windowsBoundsChanged.emit({ id: 1 });
  sb.events.tabsUpdated.emit(VISIBLE, { status: "complete" }, sb.tabs.get(VISIBLE));
  await queuesIdle(sb);

  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR]);
  assert.deepEqual(metricsCalls(sb, HIDDEN), [SET]);
  assert.equal(pumpRunning(sb, VISIBLE), false);
  assert.equal(pumpRunning(sb, HIDDEN), true);
});

test("an explicit viewport screenshot overrides a visible tab for the capture, then clears it again", async (t) => {
  const overrides = [];
  const sb = withSandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === SET) overrides.push([tabId, params.width, params.height]);
      if (method === "Page.captureScreenshot") return { data: JPEG };
      return undefined;
    }
  });
  await observe(sb, VISIBLE);

  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "screenshot",
    tabId: VISIBLE,
    viewportWidth: 1024,
    viewportHeight: 768
  });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.screenshotWidth, 1024);
  assert.equal(response.screenshotHeight, 768);

  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET, CLEAR]);
  assert.deepEqual(overrides, [[VISIBLE, 1024, 768]]);
  const methods = cdpMethods(sb, VISIBLE);
  const set = methods.lastIndexOf(SET);
  const shot = methods.lastIndexOf("Page.captureScreenshot");
  const clear = methods.lastIndexOf(CLEAR);
  assert.ok(set < shot && shot < clear, `override, capture, then clear (got ${set}, ${shot}, ${clear})`);
  assert.equal(sb.eval(`state.tabSessions.get(${VISIBLE}).metricsOverridden`), false);
  await assertNoPolling(sb, VISIBLE);
});

test("an explicit viewport observe restores a visible tab, and still sticks on a hidden one", async (t) => {
  const overrides = [];
  const sb = withSandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === SET) overrides.push([tabId, params.width, params.height]);
    }
  });
  await observe(sb, VISIBLE);
  const visible = await observe(sb, VISIBLE, { viewportWidth: 1100, viewportHeight: 700 });
  assert.equal(visible.snapshot.app.windowBounds.width, 1100, "observed at the requested size");
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET, CLEAR]);

  await observe(sb, HIDDEN, { viewportWidth: 1100, viewportHeight: 700 });
  assert.deepEqual(metricsCalls(sb, HIDDEN), [SET, SET], "a hidden tab keeps the requested override");
  assert.deepEqual(overrides, [
    [VISIBLE, 1100, 700],
    [HIDDEN, 1280, 800],
    [HIDDEN, 1100, 700]
  ]);
});

test("a visible tab reports its real window size to the preview and does not clamp clicks to 1280 px", async (t) => {
  const mouse = [];
  const sb = withSandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === "Runtime.evaluate" && String(params?.expression).includes("devicePixelRatio")) {
        return { result: { value: { width: 1728, height: 1004, scale: 2 } } };
      }
      if (method === "Page.captureScreenshot") return { data: JPEG };
      if (method === "Input.dispatchMouseEvent" && params.type === "mousePressed") mouse.push([params.x, params.y]);
      return undefined;
    }
  });
  const observed = await observe(sb, VISIBLE);
  assert.equal(observed.snapshot.app.windowBounds.width, 1728);
  assert.equal(observed.snapshot.app.windowBounds.height, 1004);

  const frame = sb.sent.filter((f) => f.type === "frame" && f.tabId === VISIBLE).at(-1);
  assert.ok(frame, "a preview frame was sent");
  assert.deepEqual([frame.viewportWidth, frame.viewportHeight], [1728, 1004]);

  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: VISIBLE,
    returnObservation: false,
    steps: [{ action: "click", x: 1500, y: 900 }]
  });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.deepEqual(mouse, [[1500, 900]]);
});

// A page zoomed to 90% in a 1512x680 window lays out at 1680x756 CSS pixels.
const LIVE = { width: 1680, height: 756, scale: 1.8 };
const ZOOM = 0.9;
const liveViewportCdp = (overrides, extra = () => undefined) => (tabId, method, params) => {
  if (method === SET) overrides.push([tabId, params.width, params.height]);
  if (method === "Runtime.evaluate" && String(params?.expression || "").includes("window.innerWidth, height: window.innerHeight")) {
    return { result: { value: LIVE } };
  }
  return extra(tabId, method, params);
};

test("a tab the user has seen keeps its on-screen layout when it goes to the background", async (t) => {
  const overrides = [];
  const sb = withSandbox(t, { cdp: liveViewportCdp(overrides), zoom: () => ZOOM });
  await observe(sb, VISIBLE);
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR]);

  sb.activateTab(HIDDEN);
  await queuesIdle(sb);

  // Emulated at the window size it had (1680x756 CSS at 90% = 1512x680), not 1280x800, so nothing reflows.
  assert.deepEqual(overrides.filter(([id]) => id === VISIBLE), [[VISIBLE, 1512, 680]]);
  const viewport = JSON.parse(sb.eval(`JSON.stringify(effectiveViewport(state.tabSessions.get(${VISIBLE})))`));
  assert.equal(viewport.width, 1680, "coordinates still use the on-screen layout");
  assert.equal(viewport.height, 756);
  await assertPumpPolls(sb, VISIBLE);

  sb.activateTab(VISIBLE);
  await queuesIdle(sb);
  assert.deepEqual(metricsCalls(sb, VISIBLE), [CLEAR, SET, CLEAR]);
  await assertNoPolling(sb, VISIBLE);
});

test("a tab opened in the background, never seen, still gets 1280x800", async (t) => {
  const overrides = [];
  const sb = withSandbox(t, { cdp: liveViewportCdp(overrides), zoom: () => ZOOM });
  await observe(sb, HIDDEN);
  assert.deepEqual(overrides, [[HIDDEN, 1280, 800]]);
});

test("an explicit viewport request still sets a seen tab's hidden size", async (t) => {
  const overrides = [];
  const sb = withSandbox(t, { cdp: liveViewportCdp(overrides), zoom: () => ZOOM });
  await observe(sb, VISIBLE);
  await observe(sb, VISIBLE, { viewportWidth: 1100, viewportHeight: 700 });

  sb.activateTab(HIDDEN);
  await queuesIdle(sb);

  assert.deepEqual(overrides.filter(([id]) => id === VISIBLE), [[VISIBLE, 1100, 700], [VISIBLE, 1100, 700]]);
});
