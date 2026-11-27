import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");
const { createFakePages, PILL_RECT } = require("./support/fake-page.cjs");

// The border and pill on a tab UseMac controls (#27), drawn through the debugger into the "usemac" isolated world.
// The fake pages run the real page script (usemacTabIndicatorPage) against a small DOM.
const VISIBLE = 31;
const HIDDEN = 32;
const JPEG = "/9j/4AAQSkZJRgABAQ==";
const ACTIVE_TEXT = "UseMac is controlling this tab";

let counter = 0;
const nextId = () => `indicator-${++counter}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(predicate, message, timeoutMs = 2000) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) throw new Error(`Timed out waiting for: ${message}`);
    await sleep(5);
  }
  return Date.now() - startedAt;
}

/** `fallback` answers the CDP calls the fake page does not (screenshots, input). */
function withSandbox(t, { fallback = () => undefined, timing = {} } = {}) {
  const pages = createFakePages((tabId, method, params) => {
    const answer = fallback(tabId, method, params, pages);
    if (answer !== undefined) return answer;
    if (method === "Page.captureScreenshot") return { data: JPEG };
    return undefined;
  });
  const sb = createBackgroundSandbox({
    tabs: [
      { id: VISIBLE, windowId: 1, url: "https://example.com/visible", active: true },
      { id: HIDDEN, windowId: 1, url: "https://example.com/hidden", active: false }
    ],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => pages.cdp(tabId, method, params)
  });
  pages.attach(sb);
  for (const [key, value] of Object.entries(timing)) sb.eval(`TAB_INDICATOR_TIMING.${key} = ${Number(value)}`);
  t.after(() => {
    pages.dispose();
    sb.dispose();
  });
  return { sb, pages };
}

async function command(sb, req) {
  const { response } = await sb.request({ type: "request", id: nextId(), ...req });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  return response;
}

const observe = (sb, tabId, extra = {}) => command(sb, { command: "observe", tabId, ...extra });
const stopRequests = (sb) => sb.sent.filter((f) => f.type === "stop_requested");
const indicator = (sb, tabId) => JSON.parse(sb.eval(`JSON.stringify(state.tabSessions.get(${tabId})?.tabIndicator || null)`));

test("a controlled tab the user sees gets the border and the pill, in a closed shadow root outside <body>", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  const host = page.host;
  assert.equal(host.parentNode, page.document.documentElement, "a child of <html>, not of <body>");
  assert.equal(page.document.body.contains(host), false);
  assert.equal(host.shadow.mode, "closed");
  assert.equal(host.shadowRoot, null, "page scripts cannot reach inside");
  assert.equal(host.getAttribute("aria-hidden"), "true");
  const style = host.getAttribute("style");
  assert.match(style, /position: fixed !important/);
  assert.match(style, /z-index: 2147483647 !important/);
  assert.match(style, /pointer-events: none !important/);
  assert.equal(host.getAttribute("popover"), "manual");
  assert.equal(host.popoverOpen, true, "in the top layer");
  assert.equal(page.text, ACTIVE_TEXT);
  const stop = page.part("stop");
  assert.equal(stop.textContent, "Stop");
  assert.equal(stop.hasAttribute("hidden"), false);
  assert.equal(stop.getAttribute("tabindex"), "-1", "not reachable with Tab");
  // Main-world DOM queries (what observe's walk uses) find no part of it.
  assert.equal(page.document.querySelectorAll("button").length, 0);
  assert.equal(page.document.body.querySelectorAll("usemac-tab-indicator").length, 0);

  // The binding exists only in the "usemac" world.
  const bindings = sb.callsTo("debugger.sendCommand").filter((c) => c.args[1] === "Runtime.addBinding");
  assert.equal(bindings.length, 1);
  assert.deepEqual(indicator(sb, VISIBLE).pill, { x: PILL_RECT.left, y: PILL_RECT.top, width: PILL_RECT.width, height: PILL_RECT.height });
});

test("a controlled tab in the background is left alone until the user switches to it", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, HIDDEN);
  await sleep(80);
  assert.equal(pages.page(HIDDEN).host, null, "nothing drawn into a page the user cannot see");
  assert.equal(pages.page(HIDDEN).calls.length, 0);

  sb.activateTab(HIDDEN);
  const elapsed = await waitFor(() => pages.page(HIDDEN).shown, "the indicator to show", 200);
  assert.ok(elapsed <= 200, `shown within 200 ms (took ${elapsed} ms)`);
  assert.equal(pages.page(VISIBLE).host, null, "a tab the agent never used gets nothing");
});

test("switching away or minimizing hides it, and coming back shows it again", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  sb.activateTab(HIDDEN);
  await waitFor(() => !page.shown, "the indicator to hide");
  assert.ok(page.host, "kept in the page, hidden");

  sb.activateTab(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show again");

  sb.setWindowState(1, "minimized");
  await waitFor(() => !page.shown, "hidden in a minimized window");
  sb.setWindowState(1, "normal");
  await waitFor(() => page.shown, "shown in the restored window");
});

test("a navigation draws it again into the new document", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const firstDocument = page.document;

  pages.navigate(VISIBLE);
  assert.notEqual(page.document, firstDocument);
  await waitFor(() => page.shown, "the indicator in the new document");
  assert.equal(page.text, ACTIVE_TEXT);
  const worlds = sb.callsTo("debugger.sendCommand").filter((c) => c.args[0] === VISIBLE && c.args[1] === "Page.createIsolatedWorld");
  assert.equal(worlds.length, 2, "one isolated world per document");
});

test("the page removing the host gets it back", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const host = page.host;

  host.remove();
  assert.equal(host.isConnected, false);
  await waitFor(() => host.isConnected, "the host to be put back");
  assert.equal(page.shown, true);
});

test("task_complete (tab_control ended) removes it, except on tabs other tasks still own", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  await sb.deliver({ type: "tab_control", state: "ended", keepTabIds: [VISIBLE] });
  await sleep(60);
  assert.equal(page.shown, true, "kept: another running task owns the tab");

  await sb.deliver({ type: "tab_control", state: "ended", keepTabIds: [] });
  await waitFor(() => page.host === null, "the indicator to be removed");
  assert.equal(indicator(sb, VISIBLE).controlled, false);

  // The next agent command on the tab brings it back.
  await observe(sb, VISIBLE);
  await waitFor(() => page.shown, "the indicator for the next task");
});

test("the kill switch shows Stopped before the debugger goes, then the page removes it", async (t) => {
  const { sb, pages } = withSandbox(t, { timing: { stoppedLingerMs: 1000 } });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  // What tripping the kill switch sends: tab_control "stopped", then cancel for every tab.
  await sb.deliver({ type: "tab_control", state: "stopped" });
  await sb.deliver({ type: "cancel", tabId: null });
  await waitFor(() => !sb.attached.has(VISIBLE), "the debugger to detach");

  assert.equal(page.text, "Stopped");
  assert.equal(page.part("stop").hasAttribute("hidden"), true, "no Stop button");
  assert.match(page.part("frame").className, /stopped/);
  assert.equal(page.shown, true, "still on screen for its linger");
  assert.equal(page.part("frame").style.props["--lease"], "1000ms", "its lease hides it without the extension");
  await waitFor(() => page.host === null, "the page script to remove it", 2500);
});

test("Pause shows Stopped, then the indicator goes away and comes back with the next command", async (t) => {
  const { sb, pages } = withSandbox(t, { timing: { stoppedLingerMs: 300 } });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  await sb.deliver({ type: "tab_control", state: "stopped" });
  await waitFor(() => page.text === "Stopped", "Stopped");
  assert.equal(sb.attached.has(VISIBLE), true, "Pause does not detach");

  await waitFor(() => page.host === null, "the indicator to go away", 1500);
  await observe(sb, VISIBLE);
  await waitFor(() => page.shown && page.text === ACTIVE_TEXT, "the indicator for the resumed agent");
});

test("the pill shows the current step and drops it shortly after the last one", async (t) => {
  const { sb, pages } = withSandbox(t, { timing: { stepLingerMs: 300 } });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  sb.call("emitCursor", VISIBLE, 100, 300, "click", "Clicking Save");
  await waitFor(() => page.text === `${ACTIVE_TEXT} · Clicking Save`, "the step in the pill");
  await waitFor(() => page.text === ACTIVE_TEXT, "the step to clear", 1500);

  // A real act step labels the pill too.
  await command(sb, { command: "act", tabId: VISIBLE, returnObservation: false, steps: [{ action: "click", x: 100, y: 300 }] });
  assert.ok(
    page.calls.some((c) => c?.op === "render" && c.step === "Clicking"),
    `a render with the step (got ${JSON.stringify(page.calls.map((c) => c?.step))})`
  );
});

test("Stop reports stop_requested for a trusted click only", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const stop = page.part("stop");

  const scripted = stop.dispatch("click", { isTrusted: false });
  const keyboard = stop.dispatch("click", { detail: 0 });
  await sleep(30);
  assert.equal(stopRequests(sb).length, 0, "a script or a keyboard press does not stop the agent");
  assert.equal(scripted.reachedPage, false, "clicks on the pill never reach the page");
  assert.equal(keyboard.reachedPage, false);

  // A binding call that does not carry this tab's token is ignored.
  sb.debuggerEvent(VISIBLE, "Runtime.bindingCalled", {
    name: "__usemacTabIndicatorStop",
    payload: JSON.stringify({ token: "forged" }),
    executionContextId: page.world.id
  });
  await sleep(30);
  assert.equal(stopRequests(sb).length, 0);

  const mousedown = stop.dispatch("mousedown");
  assert.equal(mousedown.defaultPrevented, true, "pressing it does not move the page's focus");
  stop.dispatch("click");
  await waitFor(() => stopRequests(sb).length === 1, "stop_requested");
  assert.deepEqual(stopRequests(sb)[0], { type: "stop_requested", tabId: VISIBLE });
});

test("agent screenshots never show it: it is hidden while observe, act and screenshot capture", async (t) => {
  const shownAtCapture = [];
  const { sb, pages } = withSandbox(t, {
    fallback: (tabId, method, params, fakePages) => {
      if (method === "Page.captureScreenshot" && tabId === VISIBLE) {
        shownAtCapture.push(fakePages.page(VISIBLE).shown);
        return { data: JPEG };
      }
      return undefined;
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  shownAtCapture.length = 0;

  await command(sb, { command: "screenshot", tabId: VISIBLE });
  await observe(sb, VISIBLE, { includeScreenshot: true });
  await command(sb, { command: "act", tabId: VISIBLE, returnObservation: false, includeScreenshot: true, steps: [{ action: "wait", ms: 10 }] });

  // The act's own preview frame (captureAndEmitFrame) is for the user and may show it; the three agent captures may not.
  const agentCaptures = page.calls.filter((c) => c?.op === "capture" && c.hidden === true).length;
  assert.equal(agentCaptures, 3, "each agent capture hid the indicator first");
  assert.ok(shownAtCapture.filter((shown) => shown === false).length >= 3, JSON.stringify(shownAtCapture));
  await waitFor(() => page.shown, "the indicator to come back after the captures");
});

test("frames that show the indicator are flagged, so the app's vision does not reuse them", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, HIDDEN);
  await observe(sb, VISIBLE);
  await waitFor(() => pages.page(VISIBLE).shown, "the indicator to show");

  sb.debuggerEvent(VISIBLE, "Page.screencastFrame", { data: JPEG, sessionId: 1 });
  sb.debuggerEvent(HIDDEN, "Page.screencastFrame", { data: JPEG, sessionId: 2 });
  const frames = sb.sent.filter((f) => f.type === "frame");
  assert.equal(frames.filter((f) => f.tabId === VISIBLE).at(-1).indicator, true);
  assert.equal("indicator" in frames.filter((f) => f.tabId === HIDDEN).at(-1), false);
});

test("the agent's own pointer passes through the pill to the page", async (t) => {
  const inertAtPress = [];
  const { sb, pages } = withSandbox(t, {
    timing: { pointerGraceMs: 300 },
    fallback: (tabId, method, params, fakePages) => {
      if (method === "Input.dispatchMouseEvent" && params.type === "mousePressed") {
        inertAtPress.push(/inert/.test(fakePages.page(tabId).part("frame")?.className || ""));
      }
      return undefined;
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  // A click on the page somewhere else leaves the pill alone.
  await command(sb, { command: "act", tabId: VISIBLE, returnObservation: false, steps: [{ action: "click", x: 200, y: 500 }] });
  // A click where the pill is goes to the page under it.
  const x = PILL_RECT.left + PILL_RECT.width / 2;
  const y = PILL_RECT.top + PILL_RECT.height / 2;
  await command(sb, { command: "act", tabId: VISIBLE, returnObservation: false, steps: [{ action: "click", x, y }] });
  assert.deepEqual(inertAtPress, [false, true]);

  // While it passes pointers through, Stop does nothing.
  page.part("stop").dispatch("click");
  await sleep(30);
  assert.equal(stopRequests(sb).length, 0);

  await waitFor(() => !/inert/.test(page.part("frame").className), "the pill to take pointers again", 1500);
  page.part("stop").dispatch("click");
  await waitFor(() => stopRequests(sb).length === 1, "stop_requested");
});

test("releasing the tab or its idle timeout removes it (no Stopped pill)", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");

  await sb.call("stopStreamingAndDetach", VISIBLE, true, "idle");
  assert.equal(page.host, null, "removed before the debugger detached");
  assert.equal(sb.attached.has(VISIBLE), false);
});

test("without renewals the page script hides itself (lease)", async (t) => {
  const { sb, pages } = withSandbox(t, { timing: { leaseMs: 1000, heartbeatMs: 60000 } });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const frame = page.part("frame");
  assert.equal(frame.style.props["--lease"], "1000ms");
  assert.match(frame.getAttribute("data-lease"), /^[ab]$/, "the CSS lease animation runs");

  // The debugger goes away without a word (the user cancelled Chrome's debugging bar).
  sb.attached.delete(VISIBLE);
  sb.chrome.debugger.onDetach.emit({ tabId: VISIBLE }, "canceled_by_user");
  await waitFor(() => page.host === null, "the page script to remove it", 2500);
});
