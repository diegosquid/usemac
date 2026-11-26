import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");
const { fakeJpeg, base64Size } = require("./support/fake-jpeg.cjs");

// UseMac never changes a tab's size. Every tab lays out at the size Chrome gives it and reports that size. A tab the
// user is looking at gets its preview from the screencast; a hidden tab gets the capture pump (CAPTURE_INTERVAL_MS =
// 240 ms). Zero Emulation.*DeviceMetricsOverride calls are sent.
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
const viewportOf = (sb, tabId) =>
  JSON.parse(sb.eval(`JSON.stringify(effectiveViewport(state.tabSessions.get(${tabId})))`));

function assertNeverResized(sb) {
  const sets = sb.callsTo("debugger.sendCommand").filter((c) => c.args[1] === SET);
  assert.deepEqual(sets, [], "no tab ever gets Emulation.setDeviceMetricsOverride");
}

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

async function screenshot(sb, tabId, extra = {}) {
  const { response } = await sb.request({ type: "request", id: nextId(), command: "screenshot", tabId, ...extra });
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

// A Retina window: 1728x1004 CSS px at a pixel ratio of 2, so a capture of the whole tab is 3456x2008.
const RETINA = { width: 1728, height: 1004, scale: 2 };
const retinaCdp = (extra = () => undefined) => (tabId, method, params) => {
  if (method === "Runtime.evaluate" && String(params?.expression || "").includes("window.innerWidth, height: window.innerHeight")) {
    return { result: { value: RETINA } };
  }
  if (method === "Page.captureScreenshot") return { data: fakeJpeg(3456, 2008) };
  return extra(tabId, method, params);
};

test("a hidden tab is never resized and still gets the screenshot pump", async (t) => {
  const sb = withSandbox(t, { cdp: retinaCdp() });
  await observe(sb, HIDDEN);

  assert.deepEqual(metricsCalls(sb, HIDDEN), [], "no device metrics override calls sent");
  assert.deepEqual(viewportOf(sb, HIDDEN), { ...RETINA, zoom: 1 }, "it reports the size Chrome gave it");
  await assertPumpPolls(sb, HIDDEN);
  const frame = sb.sent.filter((f) => f.type === "frame" && f.tabId === HIDDEN).at(-1);
  assert.deepEqual([frame.viewportWidth, frame.viewportHeight], [1728, 1004]);
  assertNeverResized(sb);
});

test("the active tab of a normal window is never resized and is not polled for screenshots", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);

  assert.deepEqual(metricsCalls(sb, VISIBLE), []);
  assert.ok(cdpMethods(sb, VISIBLE).includes("Page.startScreencast"), "frames come from the screencast");
  assert.ok(cdpMethods(sb, VISIBLE).includes("Emulation.setFocusEmulationEnabled"), "focus emulation stays");
  assert.ok(screenshotCount(sb, VISIBLE) <= 1, "at most the one frame sent when streaming starts");
  await assertNoPolling(sb, VISIBLE);
  assertNeverResized(sb);
});

test("the active tab of a minimized window counts as hidden", async (t) => {
  const sb = withSandbox(t, { windows: [{ id: 1, focused: false, state: "minimized" }] });
  await observe(sb, VISIBLE);

  assert.deepEqual(metricsCalls(sb, VISIBLE), []);
  await assertPumpPolls(sb, VISIBLE);
  assertNeverResized(sb);
});

test("switching tabs moves the pump to the tab the user left and resizes neither", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);
  await observe(sb, HIDDEN);
  assert.equal(pumpRunning(sb, VISIBLE), false);
  assert.equal(pumpRunning(sb, HIDDEN), true);

  sb.activateTab(HIDDEN);
  await queuesIdle(sb);
  await Promise.all([assertNoPolling(sb, HIDDEN), assertPumpPolls(sb, VISIBLE)]);

  // And back again.
  sb.activateTab(VISIBLE);
  await queuesIdle(sb);
  await Promise.all([assertNoPolling(sb, VISIBLE), assertPumpPolls(sb, HIDDEN)]);

  assert.deepEqual(metricsCalls(sb, VISIBLE), [], "no device metrics calls");
  assert.deepEqual(metricsCalls(sb, HIDDEN), []);
  assertNeverResized(sb);
});

test("minimizing and restoring the window switches its active tab's pump", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);

  sb.setWindowState(1, "minimized");
  await queuesIdle(sb);
  assert.equal(pumpRunning(sb, VISIBLE), true);

  sb.setWindowState(1, "normal");
  await queuesIdle(sb);
  await assertNoPolling(sb, VISIBLE);
  assert.deepEqual(metricsCalls(sb, VISIBLE), []);
  assertNeverResized(sb);
});

test("events that change nothing leave the pumps alone", async (t) => {
  const sb = withSandbox(t);
  await observe(sb, VISIBLE);
  await observe(sb, HIDDEN);

  sb.events.windowsFocusChanged.emit(1);
  sb.events.windowsBoundsChanged.emit({ id: 1 });
  sb.events.tabsUpdated.emit(VISIBLE, { status: "complete" }, sb.tabs.get(VISIBLE));
  await queuesIdle(sb);

  assert.equal(pumpRunning(sb, VISIBLE), false);
  assert.equal(pumpRunning(sb, HIDDEN), true);
  assertNeverResized(sb);
});

test("a window resize re-measures every attached tab, hidden ones too", async (t) => {
  let live = { width: 1280, height: 720, scale: 2 };
  const sb = withSandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === "Runtime.evaluate" && String(params?.expression || "").includes("window.innerWidth, height: window.innerHeight")) {
        return { result: { value: live } };
      }
      return undefined;
    }
  });
  await observe(sb, VISIBLE);
  await observe(sb, HIDDEN);
  assert.equal(viewportOf(sb, HIDDEN).width, 1280);

  live = { width: 1600, height: 900, scale: 2 };
  sb.events.windowsBoundsChanged.emit({ id: 1 });
  await queuesIdle(sb);
  assert.deepEqual([viewportOf(sb, VISIBLE).width, viewportOf(sb, VISIBLE).height], [1600, 900]);
  assert.deepEqual([viewportOf(sb, HIDDEN).width, viewportOf(sb, HIDDEN).height], [1600, 900]);
  assertNeverResized(sb);
});

for (const [name, tabId] of [["visible", VISIBLE], ["hidden", HIDDEN]]) {
  test(`observe with viewportWidth/viewportHeight/deviceScaleFactor does not resize a ${name} tab`, async (t) => {
    const sb = withSandbox(t, { cdp: retinaCdp() });
    const observed = await observe(sb, tabId, { viewportWidth: 1100, viewportHeight: 700, deviceScaleFactor: 2 });

    assert.equal(observed.snapshot.app.windowBounds.width, 1728, "observed at the tab's real size");
    assert.equal(observed.snapshot.app.windowBounds.height, 1004);
    assert.deepEqual(metricsCalls(sb, tabId), []);
    assertNeverResized(sb);
  });

  test(`a screenshot with viewportWidth/viewportHeight of a ${name} tab fits that box without resizing the tab`, async (t) => {
    const sb = withSandbox(t, { cdp: retinaCdp() });
    await observe(sb, tabId);

    const shot = await screenshot(sb, tabId, { viewportWidth: 1024, viewportHeight: 768 });
    // 3456x2008 scaled down to fit 1024x768, keeping its aspect ratio.
    assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [1024, 595]);
    assert.deepEqual(base64Size(shot.screenshotBase64), { width: 1024, height: 595 }, "the image itself is that size");
    assert.ok(shot.screenshotWidth <= 1024 && shot.screenshotHeight <= 768);
    assert.deepEqual(sb.canvasDraws, [[1024, 595]]);
    assert.deepEqual(metricsCalls(sb, tabId), []);
    assertNeverResized(sb);
  });
}

test("a screenshot box can be a width or a height alone", async (t) => {
  const sb = withSandbox(t, { cdp: retinaCdp() });
  await observe(sb, VISIBLE);

  const byWidth = await screenshot(sb, VISIBLE, { viewportWidth: 1728 });
  assert.deepEqual([byWidth.screenshotWidth, byWidth.screenshotHeight], [1728, 1004]);
  const byHeight = await screenshot(sb, VISIBLE, { viewportHeight: 500 });
  assert.deepEqual([byHeight.screenshotWidth, byHeight.screenshotHeight], [861, 500]);
  assert.deepEqual(base64Size(byHeight.screenshotBase64), { width: 861, height: 500 });
  assertNeverResized(sb);
});

test("a screenshot that already fits the box is returned as captured, never scaled up", async (t) => {
  const sb = withSandbox(t, { cdp: retinaCdp() });
  await observe(sb, VISIBLE);

  const shot = await screenshot(sb, VISIBLE, { viewportWidth: 4000, viewportHeight: 3000, deviceScaleFactor: 3 });
  assert.equal(shot.screenshotBase64, fakeJpeg(3456, 2008));
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [3456, 2008]);
  assert.deepEqual(sb.canvasDraws, [], "nothing was re-encoded");
  assertNeverResized(sb);
});

test("a screenshot without a box defaults to VLM-optimal 1280x800 cap, and fullResolution keeps raw size", async (t) => {
  const sb = withSandbox(t, { cdp: retinaCdp() });
  await observe(sb, HIDDEN);

  const shot = await screenshot(sb, HIDDEN);
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [1280, 744]);
  assert.deepEqual(base64Size(shot.screenshotBase64), { width: 1280, height: 744 });
  assert.deepEqual(sb.canvasDraws, [[1280, 744]]);

  sb.canvasDraws.length = 0;
  const full = await screenshot(sb, HIDDEN, { fullResolution: true });
  assert.deepEqual([full.screenshotWidth, full.screenshotHeight], [3456, 2008]);
  assert.deepEqual(sb.canvasDraws, []);
  assertNeverResized(sb);
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
const liveViewportCdp = (tabId, method, params) => {
  if (method === "Runtime.evaluate" && String(params?.expression || "").includes("window.innerWidth, height: window.innerHeight")) {
    return { result: { value: LIVE } };
  }
  return undefined;
};

test("a zoomed tab keeps its CSS size when it goes to the background and back", async (t) => {
  const sb = withSandbox(t, { cdp: liveViewportCdp, zoom: () => ZOOM });
  await observe(sb, VISIBLE);
  assert.deepEqual(viewportOf(sb, VISIBLE), { ...LIVE, zoom: ZOOM });

  sb.activateTab(HIDDEN);
  await queuesIdle(sb);
  assert.deepEqual(viewportOf(sb, VISIBLE), { ...LIVE, zoom: ZOOM }, "coordinates still use the page's layout");
  await assertPumpPolls(sb, VISIBLE);

  sb.activateTab(VISIBLE);
  await queuesIdle(sb);
  await assertNoPolling(sb, VISIBLE);
  assert.deepEqual(metricsCalls(sb, VISIBLE), []);
  assertNeverResized(sb);
});

test("a tab opened in the background, never seen, reports the size Chrome gave it", async (t) => {
  const sb = withSandbox(t, { cdp: liveViewportCdp, zoom: () => ZOOM });
  const observed = await observe(sb, HIDDEN);
  assert.equal(observed.snapshot.app.windowBounds.width, 1680);
  assert.equal(observed.snapshot.app.windowBounds.height, 756);
  assertNeverResized(sb);
});

test("a tab that reports 0x0 uses its size in Chrome, divided by the zoom", async (t) => {
  const sb = createBackgroundSandbox({
    tabs: [{ id: HIDDEN, windowId: 1, url: "https://example.com/hidden", active: false, width: 1512, height: 680 }],
    windows: [{ id: 1, focused: true }],
    zoom: () => ZOOM,
    cdp: (tabId, method, params) => {
      if (method === "Runtime.evaluate" && String(params?.expression || "").includes("window.innerWidth, height: window.innerHeight")) {
        return { result: { value: { width: 0, height: 0, scale: 1.8 } } };
      }
      return undefined;
    }
  });
  t.after(() => sb.dispose());
  await observe(sb, HIDDEN);
  assert.deepEqual(viewportOf(sb, HIDDEN), { width: 1680, height: 756, scale: 1.8, zoom: ZOOM });
  assertNeverResized(sb);
});

test("a tab with no usable size reports the fallback size and does not clamp clicks to it", async (t) => {
  const mouse = [];
  const sb = withSandbox(t, {
    cdp: (tabId, method, params) => {
      if (method === "Runtime.evaluate" && String(params?.expression || "").includes("window.innerWidth, height: window.innerHeight")) {
        return { result: { value: { width: 3, height: 2, scale: 2 } } };
      }
      if (method === "Input.dispatchMouseEvent" && params.type === "mousePressed") mouse.push([params.x, params.y]);
      return undefined;
    }
  });
  await observe(sb, HIDDEN);
  assert.deepEqual(viewportOf(sb, HIDDEN), { width: 1280, height: 800, scale: 1 }, "only reported, never applied");

  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: HIDDEN,
    returnObservation: false,
    steps: [{ action: "click", x: 1500, y: 900 }]
  });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.deepEqual(mouse, [[1500, 900]]);
  assertNeverResized(sb);
});
