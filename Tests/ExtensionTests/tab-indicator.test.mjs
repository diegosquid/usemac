import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");
const { createFakePages, FakeDocument, PILL_RECT } = require("./support/fake-page.cjs");

// The border and pill on a tab UseMac controls (#27), drawn through the debugger into the "usemac" isolated world.
// The fake pages run the real page script (usemacTabIndicatorPage) against a small DOM.
const VISIBLE = 31;
const HIDDEN = 32;
const JPEG = "/9j/4AAQSkZJRgABAQ==";
const ACTIVE_TEXT = "UseMac is controlling this tab";
const USER_PAUSED_TEXT = "You're using this tab, agent paused";

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
const indicator = (sb, tabId) => JSON.parse(sb.eval(
  `JSON.stringify(state.tabSessions.get(${tabId})?.tabIndicator || null, (key, value) => key.endsWith("Timer") ? undefined : value)`
));

function holdActWaitStep(sb) {
  sb.eval("sleepCancellable = () => new Promise((resolve) => { globalThis.releaseActWaitStep = resolve; });");
  return () => waitFor(() => sb.eval("typeof releaseActWaitStep === 'function'"), "first step to start");
}

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

test("trusted input outside the pill pauses the agent and shows Resume next to Stop", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const resume = page.part("resume");
  assert.equal(resume.hasAttribute("hidden"), true);
  page.document.body.dispatch("input", { isTrusted: false });
  page.part("stop").dispatch("pointerdown");
  assert.equal(indicator(sb, VISIBLE).userPaused, false);

  page.document.body.dispatch("keydown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "user paused pill");
  assert.match(page.part("frame").className, /user_paused/);
  assert.equal(resume.textContent, "Resume");
  assert.equal(resume.hasAttribute("hidden"), false);
  assert.equal(page.part("stop").hasAttribute("hidden"), false);
  resume.dispatch("click", { isTrusted: false });
  resume.dispatch("click", { detail: 0 });
  assert.equal(indicator(sb, VISIBLE).userPaused, true);

  resume.dispatch("click");
  await waitFor(() => page.text === ACTIVE_TEXT, "active pill");
  assert.equal(resume.hasAttribute("hidden"), true);
  await sb.deliver({ type: "tab_control", state: "ended" });
  await waitFor(() => page.host === null, "pill removal");
  for (const type of ["pointerdown", "mousedown", "keydown", "input"]) {
    assert.equal(page.document.captureListeners.get(type).size, 0, `${type} listener removed`);
  }
});

test("browser_act waits between steps until the user clicks Resume", async (t) => {
  let pressed = 0;
  const { sb, pages } = withSandbox(t, {
    fallback: (_, method, params) => {
      if (method === "Input.dispatchMouseEvent" && params.type === "mousePressed") pressed++;
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const waitForFirstStep = holdActWaitStep(sb);
  const pending = command(sb, {
    command: "act", tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "wait", ms: 1 }, { action: "click", x: 100, y: 300 }]
  });
  await waitForFirstStep();
  page.document.body.dispatch("pointerdown");
  sb.eval("releaseActWaitStep()");
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "second step blocked");
  assert.equal(page.text, USER_PAUSED_TEXT);
  assert.equal(pressed, 0);

  page.part("resume").dispatch("click");
  const response = await pending;
  assert.equal(response.actionResult.success, true);
  assert.equal(pressed, 1);
  assert.equal(indicator(sb, VISIBLE).userPausedWaiters.length, 0);
});

test("trusted DOM events from CDP input and its grace window do not pause the agent", async (t) => {
  let trustedInput = 0;
  const { sb, pages } = withSandbox(t, {
    fallback(tabId, method, params, pages) {
      if (method === "Input.insertText" || (method === "Input.dispatchMouseEvent" && params.type === "mousePressed")) {
        const ind = indicator(sb, VISIBLE);
        assert.ok((method === "Input.insertText" ? ind.agentKeyboardDepth : ind.agentPointerDepth) > 0);
        pages.page(tabId).document.body.dispatch(method === "Input.insertText" ? "input" : "pointerdown");
        trustedInput++;
      }
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const response = await command(sb, {
    command: "act", tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "click", x: 100, y: 300 }, { action: "type", text: "hello" }]
  });
  assert.equal(response.actionResult.success, true, JSON.stringify(response.actionResult.stepResults));
  assert.equal(trustedInput, 2);
  const { token, agentKeyboardDepth, agentPointerDepth, suppressKeyboardUntil } = indicator(sb, VISIBLE);
  assert.equal(agentKeyboardDepth, 0);
  assert.equal(agentPointerDepth, 0);
  assert.equal(sb.eval("TAB_INDICATOR_TIMING.agentInputGraceMs"), 80);
  assert.ok(Date.now() < suppressKeyboardUntil);
  sb.debuggerEvent(VISIBLE, "Runtime.bindingCalled", {
    name: "__usemacTabIndicatorStop", executionContextId: page.world.id,
    payload: JSON.stringify({ token, action: "user_input", eventType: "input" })
  });
  assert.equal(indicator(sb, VISIBLE).userPaused, false, "a delayed binding event was also suppressed");
  await waitFor(() => Date.now() >= suppressKeyboardUntil, "input grace to expire");
  page.document.body.dispatch("input");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "user input works after grace");
});

test("WebSocket teardown cancels paused batches before a late Resume", async (t) => {
  for (const [name, drop] of [
    ["socket close", "state.ws.onclose()"],
    ["key mismatch", "enterKeyMismatch(state.ws)"],
    ["forced reconnect", "connectWS(true)"],
    ["keepalive replacing a closing socket", "state.ws.readyState = WebSocket.CLOSING; ensureConnected()"]
  ]) {
    await t.test(name, async (t) => {
      let presses = 0;
      const { sb, pages } = withSandbox(t, {
        fallback: (_, method, params) => {
          if (method === "Input.dispatchMouseEvent" && params.type === "mousePressed") presses++;
        }
      });
      await observe(sb, VISIBLE);
      const page = pages.page(VISIBLE);
      await waitFor(() => page.shown, "the indicator to show");
      page.document.body.dispatch("keydown");
      await waitFor(() => page.text === USER_PAUSED_TEXT, "the paused indicator");
      const { token, contextId } = indicator(sb, VISIBLE);
      const start = () => sb.deliver({
        type: "request", command: "act", id: nextId(), tabId: VISIBLE, returnObservation: false,
        steps: [{ action: "click", x: 100, y: 300 }]
      });
      await start();
      await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "act blocked");
      const waitingBatch = sb.eval(`state.tabQueues.get(${VISIBLE})`);
      await start();
      await waitFor(() => waitingBatch !== sb.eval(`state.tabQueues.get(${VISIBLE})`), "second batch queued");

      sb.eval(drop);
      assert.equal(indicator(sb, VISIBLE).userPaused, false);
      assert.equal(indicator(sb, VISIBLE).userPausedWaiters.length, 0);
      await waitFor(() => !sb.attached.has(VISIBLE) && page.host === null, "cancelled work detached without Resume");
      assert.equal(presses, 0);

      sb.call("connectWS", true);
      sb.markReady();
      await observe(sb, VISIBLE);
      await waitFor(() => page.shown, "new session's indicator");
      sb.debuggerEvent(VISIBLE, "Runtime.bindingCalled", {
        name: "__usemacTabIndicatorStop", executionContextId: contextId,
        payload: JSON.stringify({ token, action: "resume" })
      });
      const fresh = await command(sb, {
        command: "act", tabId: VISIBLE, returnObservation: false,
        steps: [{ action: "click", x: 300, y: 300 }]
      });
      assert.equal(fresh.actionResult.success, true);
      assert.equal(presses, 1, "only the new session's click ran");
    });
  }
});

test("hover over the pill does not suppress a human key or pointer event", async (t) => {
  let receiveHover;
  const { sb, pages } = withSandbox(t, {
    fallback: (_, method, params) => {
      if (method === "Input.dispatchMouseEvent" && params.type === "mouseMoved") receiveHover?.();
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const hover = () => command(sb, {
    command: "act", tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "hover", x: PILL_RECT.left + 10, y: PILL_RECT.top + 10 }]
  });
  receiveHover = () => page.document.body.dispatch("keydown");
  assert.equal((await hover()).actionResult.success, true);
  await waitFor(() => page.text === USER_PAUSED_TEXT, "human key during hover pauses");

  sb.call("resumeTabIndicatorUserPause", VISIBLE);
  await waitFor(() => page.text === ACTIVE_TEXT || page.text.startsWith(ACTIVE_TEXT + " ·"), "agent resumed");
  receiveHover = null;
  await hover();
  page.document.body.dispatch("pointerdown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "human pointer after hover pauses");
});

test("fillForm pauses between fields after a human pointer event", async (t) => {
  const fields = [];
  const { sb, pages } = withSandbox(t, {
    fallback: (tabId, method, params, pages) => {
      if (method !== "Runtime.evaluate") return;
      const field = params.expression.match(/const f = (\{"selector":"#\w+","value":"\w+"\});/);
      if (!field) return;
      fields.push(JSON.parse(field[1]).selector);
      if (fields.length === 1) pages.page(tabId).document.body.dispatch("pointerdown");
      return { result: { value: { found: true, ok: true, kind: "input" } } };
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const pending = command(sb, {
    command: "act", tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "fillForm", fields: [{ selector: "#given", value: "Ada" }, { selector: "#family", value: "Lovelace" }] }]
  });
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1 && page.text === USER_PAUSED_TEXT, "second field blocked");
  assert.deepEqual(fields, ["#given"]);
  page.part("resume").dispatch("click");
  assert.equal((await pending).actionResult.success, true);
  assert.deepEqual(fields, ["#given", "#family"]);
});

test("scrollUntil pauses between iterations after a human key event", async (t) => {
  let wheels = 0;
  const { sb, pages } = withSandbox(t, {
    fallback(tabId, method, params, pages) {
      if (method === "Input.dispatchMouseEvent" && params.type === "mouseWheel") {
        wheels++;
        if (wheels === 1) pages.page(tabId).document.body.dispatch("keydown");
      }
      if (method !== "Runtime.evaluate") return;
      if (params.expression.includes("found: Boolean(hit), id, scrollX: sx, scrollY: sy")) {
        return { result: { value: { found: wheels === 2, scrollX: 0, scrollY: wheels * 600 } } };
      }
      if (params.expression.startsWith("({") && params.expression.includes("scrollY: window.scrollY")) {
        return { result: { value: { scrollX: 0, scrollY: wheels * 600 } } };
      }
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const pending = command(sb, {
    command: "act", tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "scrollUntil", selector: "#result" }]
  });
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1 && page.text === USER_PAUSED_TEXT, "next scroll blocked");
  assert.equal(wheels, 1);
  page.part("resume").dispatch("click");
  assert.equal((await pending).actionResult.success, true);
  assert.equal(wheels, 2);
});

test("trusted input in same-origin iframes pauses the agent and listeners are removed", async (t) => {
  const { sb, pages } = withSandbox(t);
  const page = pages.page(VISIBLE);
  const child = new FakeDocument();
  const iframe = page.document.createElement("iframe");
  iframe.contentDocument = child;
  page.document.body.appendChild(iframe);
  const crossOrigin = page.document.createElement("iframe");
  Object.defineProperty(crossOrigin, "contentDocument", {
    get() { throw new Error("Cross-origin frame"); }
  });
  page.document.body.appendChild(crossOrigin);

  await observe(sb, VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  child.body.dispatch("keydown", { isTrusted: false });
  assert.equal(indicator(sb, VISIBLE).userPaused, false);
  child.body.dispatch("keydown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "input in the iframe pauses the agent");
  page.part("resume").dispatch("click");
  await waitFor(() => page.text === ACTIVE_TEXT, "agent resumed");
  const replacement = new FakeDocument();
  iframe.contentDocument = replacement;
  iframe.dispatch("load");
  replacement.body.dispatch("pointerdown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "input in the new iframe document pauses the agent");

  await sb.deliver({ type: "tab_control", state: "ended" });
  await waitFor(() => page.host === null, "the indicator to be removed");
  for (const doc of [page.document, child, replacement]) {
    for (const type of ["pointerdown", "mousedown", "keydown", "input", "load"]) {
      assert.equal(doc.captureListeners.get(type).size, 0, `${type} listener removed`);
    }
  }
});

test("browser_open waits for Resume before navigating an existing paused tab", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  page.document.body.dispatch("keydown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "the paused indicator");
  const url = "https://example.com/next";
  const pending = command(sb, { command: "open", tabId: VISIBLE, url, stream: false });
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "navigation blocked");
  assert.equal(sb.callsTo("tabs.update").length, 0);
  page.part("resume").dispatch("click");
  const response = await pending;
  assert.equal(response.createdTab, false);
  assert.equal(sb.tabs.get(VISIBLE).url, url);
});

test("browser_open waits for Resume before auto-dismissing an overlay", async (t) => {
  let presses = 0;
  const { sb, pages } = withSandbox(t, {
    fallback: (_, method, params) => {
      if (method === "Input.dispatchMouseEvent" && params.type === "mousePressed") presses++;
    }
  });
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  sb.eval(`
    const originalObserveTab = observeTab;
    observeTab = async (...args) => {
      const result = await originalObserveTab(...args);
      if (!globalThis.releaseOverlayObservation) {
        await new Promise((resolve) => { globalThis.releaseOverlayObservation = resolve; });
        result.overlayHighConfidence = true;
        result.snapshot = { pageState: { blockingOverlay: { closeX: 100, closeY: 300 } } };
      }
      return result;
    };
  `);
  const pending = command(sb, {
    command: "open", tabId: VISIBLE, url: "https://example.com/next", stream: false, autoDismissOverlays: true
  });
  await waitFor(() => sb.eval("typeof releaseOverlayObservation === 'function'"), "overlay observation held");
  page.document.body.dispatch("keydown");
  sb.eval("releaseOverlayObservation()");
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1 && page.text === USER_PAUSED_TEXT, "overlay click blocked");
  assert.equal(presses, 0);
  page.part("resume").dispatch("click");
  await pending;
  assert.equal(presses, 1);
});

test("Stop cancels a waiting browser_act without executing its blocked step", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  page.document.body.dispatch("mousedown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "user paused pill");
  const pending = sb.request({
    command: "act", id: nextId(), tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "click", x: 100, y: 300 }]
  });
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "act blocked");
  page.part("stop").dispatch("click");
  assert.deepEqual(stopRequests(sb), [{ type: "stop_requested", tabId: VISIBLE }]);
  const { response } = await pending;
  assert.equal(response.error?.code, "CANCELLED");
  assert.equal(response.actionResult.stepResults[0].mechanism, "cancelled");
  assert.ok(!sb.callsTo("debugger.sendCommand").some(({ args }) => args[1] === "Input.dispatchMouseEvent"));
});

test("tab_control stopped and ended clear the pause and release waiters", async (t) => {
  for (const state of ["stopped", "ended"]) {
    const { sb, pages } = withSandbox(t);
    await observe(sb, VISIBLE);
    const page = pages.page(VISIBLE);
    await waitFor(() => page.shown, "the indicator to show");
    page.document.body.dispatch("keydown");
    const pending = sb.request({
      command: "act", id: nextId(), tabId: VISIBLE, returnObservation: false, steps: [{ action: "wait", ms: 1 }]
    });
    await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "act blocked");
    if (state === "ended") {
      await sb.deliver({ type: "tab_control", state, keepTabIds: [VISIBLE] });
      assert.equal(indicator(sb, VISIBLE).userPausedWaiters.length, 1, "another task still owns the paused tab");
    }
    await sb.deliver({ type: "tab_control", state });
    assert.equal((await pending).response.error?.code, "CANCELLED");
    const ind = indicator(sb, VISIBLE);
    assert.equal(ind.userPaused, false);
    assert.equal(ind.userPausedWaiters.length, 0);
    await waitFor(() => state === "stopped" ? page.text === "Stopped" : page.host === null, "final pill state");
  }
});

test("ending control after user input also blocks the next step of a batch still in flight", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  const waitForFirstStep = holdActWaitStep(sb);
  const pending = sb.request({
    command: "act", id: nextId(), tabId: VISIBLE, returnObservation: false,
    steps: [{ action: "wait", ms: 1 }, { action: "click", x: 100, y: 300 }]
  });
  await waitForFirstStep();
  page.document.body.dispatch("keydown");
  await waitFor(() => page.text === USER_PAUSED_TEXT, "user paused pill");
  assert.equal(indicator(sb, VISIBLE).userPausedWaiters.length, 0, "the current step is still running");
  await sb.deliver({ type: "tab_control", state: "ended" });
  sb.eval("releaseActWaitStep()");
  const { response } = await pending;
  assert.equal(response.error?.code, "CANCELLED");
  assert.equal(response.actionResult.stepResults[1].mechanism, "cancelled");
  assert.ok(!sb.callsTo("debugger.sendCommand").some(({ args }) => args[1] === "Input.dispatchMouseEvent"));
});

test("request cancellation and explicit detach cannot strand a paused action", async (t) => {
  const { sb, pages } = withSandbox(t);
  await observe(sb, VISIBLE);
  const page = pages.page(VISIBLE);
  await waitFor(() => page.shown, "the indicator to show");
  page.document.body.dispatch("pointerdown");
  const start = (id) => sb.request({
    command: "act", id, tabId: VISIBLE, returnObservation: false, steps: [{ action: "wait", ms: 1 }]
  });
  const id = nextId();
  const first = start(id);
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "first act blocked");
  await sb.deliver({ type: "cancel", requestId: id });
  assert.equal((await first).response.error?.code, "CANCELLED");
  assert.equal(indicator(sb, VISIBLE).userPausedWaiters.length, 0);
  assert.equal(indicator(sb, VISIBLE).userPaused, true, "request-only cancellation does not resume the tab");

  const second = start(nextId());
  await waitFor(() => indicator(sb, VISIBLE).userPausedWaiters.length === 1, "another act blocked");
  await command(sb, { command: "stop_stream", tabId: VISIBLE });
  assert.equal((await second).response.error?.code, "CANCELLED");
  assert.equal(page.host, null);
});
