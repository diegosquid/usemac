import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");
const { createScrollPage } = require("./support/fake-scroll-page.cjs");
const { base64Size } = require("./support/fake-jpeg.cjs");

// Element and full-page screenshots never make Chrome draw more than is on screen: no captureBeyondViewport and no
// Emulation.setDeviceMetricsOverride. An element is scrolled into view only when needed and captured with a clip
// inside the viewport; a full page is scrolled through and stitched from viewport captures. Every scroll goes back
// afterwards, also when a capture fails.
const TAB = 21;
const SET = "Emulation.setDeviceMetricsOverride";

let counter = 0;
const nextId = () => `shot-${++counter}`;

function withPage(t, pageOptions, { limits = { settleMs: 0 } } = {}) {
  const page = createScrollPage(pageOptions);
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://example.com/long", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => page.cdp(tabId, method, params)
  });
  for (const [key, value] of Object.entries(limits)) sb.eval(`FULL_PAGE_LIMITS.${key} = ${Number(value)}`);
  t.after(() => sb.dispose());
  return { sb, page };
}

async function screenshot(sb, extra) {
  const { response } = await sb.request({ type: "request", id: nextId(), command: "screenshot", tabId: TAB, ...extra });
  return response;
}

function assertViewportUntouched(sb, page) {
  const sets = sb.callsTo("debugger.sendCommand").filter((c) => c.args[1] === SET);
  assert.deepEqual(sets, [], "no Emulation.setDeviceMetricsOverride");
  for (const shot of page.captures) {
    assert.notEqual(shot.params.captureBeyondViewport, true, `captureBeyondViewport in ${JSON.stringify(shot.params)}`);
  }
}

// A clip is in page coordinates; at capture time it must lie inside the viewport.
function assertClipOnScreen(shot, viewport) {
  const { clip } = shot.params;
  const left = clip.x - shot.scroll.x;
  const top = clip.y - shot.scroll.y;
  assert.ok(left >= 0 && top >= 0, `clip starts on screen: ${JSON.stringify(shot)}`);
  assert.ok(left + clip.width <= viewport.width && top + clip.height <= viewport.height, `clip ends on screen: ${JSON.stringify(shot)}`);
}

// --- Full page ------------------------------------------------------------------------------------------------

test("a full-page screenshot scrolls through the page, stitches viewport captures and puts the scroll back", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 3000 },
    dpr: 2,
    scroll: { x: 0, y: 450 }
  });

  const shot = await screenshot(sb, { fullPage: true });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [2000, 6000]);
  assert.deepEqual(base64Size(shot.screenshotBase64), { width: 2000, height: 6000 });
  assert.equal(shot.screenshotTruncated, false);

  // One capture per viewport, from the top; the last one is as far as the page scrolls (3000 - 800).
  assert.deepEqual(page.shots.map((s) => s.scroll.y), [0, 800, 1600, 2200]);
  assert.ok(page.shots.every((s) => s.params.clip === undefined), "viewport captures, no clip");
  assert.deepEqual(sb.drawImageCalls.map((d) => d.args), [
    [0, 0, 2000, 1600, 0, 0, 2000, 1600],
    [0, 0, 2000, 1600, 0, 1600, 2000, 1600],
    [0, 0, 2000, 1600, 0, 3200, 2000, 1600],
    // Rows 2400..3000 are the bottom 600 px of the capture at 2200.
    [0, 400, 2000, 1200, 0, 4800, 2000, 1200]
  ]);
  assert.ok(sb.drawImageCalls.every((d) => d.canvas[0] === 2000 && d.canvas[1] === 6000));
  assert.deepEqual(sb.canvasDraws, [[2000, 6000]], "encoded once");

  assert.deepEqual(page.scroll, { x: 0, y: 450 }, "the scroll position is back");
  assert.deepEqual(page.scrolls.at(-1), { x: 0, y: 450, via: "window.scrollTo" });
  assertViewportUntouched(sb, page);
});

test("a full-page screenshot stops at 16384 CSS px, keeps the image under 16384 px a side and says it was cut", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 40000 },
    dpr: 2
  });

  const shot = await screenshot(sb, { fullPage: true });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.equal(shot.screenshotTruncated, true);
  // 1000 x 16384 CSS px at a pixel ratio of 2 would be 2000 x 32768: drawn at half that.
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [1000, 16384]);
  assert.equal(page.shots.length, Math.ceil(16384 / 800));
  assert.equal(page.shots.at(-1).scroll.y, 16000);
  const last = sb.drawImageCalls.at(-1).args;
  assert.equal(last[5] + last[7], 16384, "the last capture ends at the bottom of the image");
  assert.deepEqual(page.scroll, { x: 0, y: 0 });
  assertViewportUntouched(sb, page);
});

test("a full-page screenshot stops after the most captures it may take and drops the rows it never drew", async (t) => {
  const { sb, page } = withPage(
    t,
    { viewport: { width: 1000, height: 800 }, content: { width: 1000, height: 3000 }, dpr: 2, scroll: { x: 0, y: 900 } },
    { limits: { settleMs: 0, maxTiles: 3 } }
  );

  const shot = await screenshot(sb, { fullPage: true });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.equal(shot.screenshotTruncated, true);
  assert.equal(page.shots.length, 3);
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [2000, 4800]);
  assert.deepEqual(base64Size(shot.screenshotBase64), { width: 2000, height: 4800 });
  assert.deepEqual(page.scroll, { x: 0, y: 900 });
  assertViewportUntouched(sb, page);
});

test("a full-page screenshot with a box is drawn straight at the box size", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 3000 },
    dpr: 2
  });

  const shot = await screenshot(sb, { fullPage: true, viewportWidth: 1280, viewportHeight: 800 });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  // 2000 x 6000 scaled down to fit 1280 x 800.
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [267, 800]);
  assert.deepEqual(sb.canvasDraws, [[267, 800]], "one stitched canvas, not re-encoded to fit");
  assert.equal(shot.screenshotTruncated, false);
  assertViewportUntouched(sb, page);
});

test("a full-page screenshot puts the scroll back when a capture fails halfway", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 3000 },
    dpr: 2,
    scroll: { x: 0, y: 450 },
    failCapture: (index) => index === 2
  });

  const shot = await screenshot(sb, { fullPage: true });
  assert.equal(shot.ok, false);
  assert.match(shot.error.message, /Capture failed/);
  assert.deepEqual(page.shots.map((s) => s.scroll.y), [0, 800, 1600]);
  assert.deepEqual(page.scroll, { x: 0, y: 450 }, "the scroll position is back");
  assertViewportUntouched(sb, page);
});

test("a page that fits in one viewport is one plain capture, without scrolling", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 700 },
    dpr: 2
  });

  const shot = await screenshot(sb, { fullPage: true });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [2000, 1600]);
  assert.equal(shot.screenshotTruncated, false);
  assert.equal(page.shots.length, 1);
  assert.deepEqual(page.scrolls, []);
  assert.deepEqual(sb.canvasDraws, []);
  assertViewportUntouched(sb, page);
});

// --- Elements -------------------------------------------------------------------------------------------------

test("an element on screen is captured with a clip inside the viewport, without scrolling", async (t) => {
  const viewport = { width: 1000, height: 800 };
  const { sb, page } = withPage(t, {
    viewport,
    content: { width: 1000, height: 3000 },
    dpr: 2,
    scroll: { x: 0, y: 450 },
    elements: { "#chart": { left: 100, top: 600, width: 300, height: 200 } }
  });

  const shot = await screenshot(sb, { selector: "#chart" });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.equal(page.shots.length, 1);
  assert.deepEqual(page.shots[0].params.clip, { x: 100, y: 600, width: 300, height: 200, scale: 1 });
  assertClipOnScreen(page.shots[0], viewport);
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [600, 400]);
  assert.equal(shot.screenshotTruncated, false);
  assert.deepEqual(page.intoView, [], "not scrolled into view");
  assert.deepEqual(page.scrolls, [], "nothing scrolled at all");
  assertViewportUntouched(sb, page);
});

test("an element below the fold is scrolled into view, clipped inside the viewport, and the scroll goes back", async (t) => {
  const viewport = { width: 1000, height: 800 };
  const { sb, page } = withPage(t, {
    viewport,
    content: { width: 1000, height: 3000 },
    dpr: 2,
    scroll: { x: 0, y: 450 },
    elements: { '[data-usemac-id="@b3"]': { left: 100, top: 2000, width: 300, height: 200 } }
  });

  const shot = await screenshot(sb, { elementId: "@b3" });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.deepEqual(page.intoView, [{ block: "center", inline: "center", behavior: "instant" }]);
  assert.equal(page.shots.length, 1);
  // Centered: the window scrolled to 2000 + 100 - 400.
  assert.deepEqual(page.shots[0].scroll, { x: 0, y: 1700 });
  assert.deepEqual(page.shots[0].params.clip, { x: 100, y: 2000, width: 300, height: 200, scale: 1 });
  assertClipOnScreen(page.shots[0], viewport);
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [600, 400]);
  assert.equal(shot.screenshotTruncated, false);
  assert.deepEqual(page.scroll, { x: 0, y: 450 }, "the scroll position is back");
  assertViewportUntouched(sb, page);
});

test("an element bigger than the viewport is captured from its top-left corner and marked truncated", async (t) => {
  const viewport = { width: 1000, height: 800 };
  const { sb, page } = withPage(t, {
    viewport,
    content: { width: 3000, height: 5000 },
    dpr: 2,
    scroll: { x: 30, y: 60 },
    elements: { "#grid": { left: 200, top: 1200, width: 1500, height: 2000 } }
  });

  const shot = await screenshot(sb, { selector: "#grid", fullResolution: true });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.deepEqual(page.intoView, [{ block: "start", inline: "start", behavior: "instant" }]);
  assert.deepEqual(page.shots[0].scroll, { x: 200, y: 1200 });
  // The part that fits: one viewport from the element's top-left corner.
  assert.deepEqual(page.shots[0].params.clip, { x: 200, y: 1200, width: 1000, height: 800, scale: 1 });
  assertClipOnScreen(page.shots[0], viewport);
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [2000, 1600]);
  assert.equal(shot.screenshotTruncated, true);
  assert.deepEqual(page.scroll, { x: 30, y: 60 }, "the scroll position is back");
  assertViewportUntouched(sb, page);
});

test("a truncated element shot that is scaled down to a box stays marked truncated", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 5000 },
    dpr: 2,
    elements: { "#feed": { left: 0, top: 300, width: 1000, height: 2400 } }
  });

  const shot = await screenshot(sb, { selector: "#feed", viewportWidth: 500 });
  assert.equal(shot.ok, true, JSON.stringify(shot.error));
  assert.deepEqual(page.intoView, [{ block: "start", inline: "center", behavior: "instant" }]);
  assert.deepEqual(page.shots[0].params.clip, { x: 0, y: 300, width: 1000, height: 800, scale: 1 });
  assert.deepEqual([shot.screenshotWidth, shot.screenshotHeight], [500, 400]);
  assert.equal(shot.screenshotTruncated, true);
  assert.deepEqual(page.scroll, { x: 0, y: 0 });
  assertViewportUntouched(sb, page);
});

test("an element shot puts the scroll back when the capture fails", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 3000 },
    dpr: 2,
    scroll: { x: 0, y: 450 },
    elements: { "#chart": { left: 100, top: 2000, width: 300, height: 200 } },
    failCapture: () => true
  });

  const shot = await screenshot(sb, { selector: "#chart" });
  assert.equal(shot.ok, false);
  assert.match(shot.error.message, /Capture failed/);
  assert.equal(page.intoView.length, 1, "it was scrolled into view first");
  assert.deepEqual(page.scroll, { x: 0, y: 450 }, "the scroll position is back");
  assertViewportUntouched(sb, page);
});

test("a missing element is ELEMENT_NOT_FOUND and nothing scrolls", async (t) => {
  const { sb, page } = withPage(t, {
    viewport: { width: 1000, height: 800 },
    content: { width: 1000, height: 3000 },
    scroll: { x: 0, y: 450 }
  });

  const shot = await screenshot(sb, { selector: "#missing" });
  assert.equal(shot.ok, false);
  assert.equal(shot.error.code, "ELEMENT_NOT_FOUND");
  assert.deepEqual(page.shots, []);
  assert.deepEqual(page.scrolls, []);
});
