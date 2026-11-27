import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");
const TAB = 61;
const PAGE = "https://example.com/form";
const NEXT = "https://example.com/next";

// Execute the extension's actual frame scripts, then send trusted events as Chrome CDP would.
function withClickPage(t, { link = false, receive = true, moveAfterScroll = false, inFrame = false, cover = null, coverFrame = null, onRelease, onKeyDown } = {}) {
  const listeners = new Map();
  const observers = new Set();
  const timers = new Map();
  const input = [];
  const overlay = { localName: "aside" };
  const rect = { left: 60, top: 100, width: 80, height: 40 };
  const queries = [];
  let owner = { x: 0, y: 0 };
  let contextDestroyed = false;
  let reflowPending = false;
  let scrolls = 0;
  let coverClicks = 0;
  const frameCover = { localName: "button", click() { coverClicks++; } };
  const frameElement = {
    ownerDocument: {
      elementFromPoint: (x, y) => coverFrame?.(x, y) ? frameCover : frameElement,
      defaultView: { getComputedStyle: () => ({ opacity: "1" }) }
    },
    getBoundingClientRect: () => ({ left: owner.x, top: owner.y, width: 600, height: 600 })
  };
  const el = {
    localName: link ? "a" : "button",
    tagName: link ? "A" : "BUTTON",
    attributes: new Map(link ? [["href", NEXT]] : []),
    getAttribute(name) { return this.attributes.get(name) ?? null; },
    contains(hit) { return hit === this; },
    closest(selector) { return this.matches(selector) ? this : null; },
    matches(selector) {
      return selector.split(",").map((part) => part.trim()).includes(link ? "a[href]" : "button");
    },
    getBoundingClientRect() { return { ...rect }; },
    scrollIntoView() {
      scrolls++;
      reflowPending = moveAfterScroll;
    }
  };
  const document = {
    body: { innerText: "A loaded page with enough content for the tab-load check to return immediately." },
    activeElement: null,
    title: "Form",
    visibilityState: "visible",
    documentElement: {},
    querySelector: (selector) => selector === "#target" ? el : null,
    elementFromPoint: (x, y) => {
      if (cover?.(x, y)) return overlay;
      const inside = x >= rect.left && x < rect.left + rect.width && y >= rect.top && y < rect.top + rect.height;
      return inside ? el : null;
    }
  };
  document.activeElement = document.body;
  const context = vm.createContext({
    document,
    location: { href: PAGE },
    scrollX: 0,
    scrollY: 0,
    setTimeout(fn, delay) {
      const timer = setTimeout(() => { timers.delete(timer); fn(); }, delay);
      timers.set(timer, delay);
      return timer;
    },
    clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); },
    requestAnimationFrame(callback) {
      if (reflowPending) {
        rect.left = 260;
        rect.top = 180;
        if (inFrame) owner = { x: 110, y: 100 };
        reflowPending = false;
      }
      callback();
    },
    addEventListener(type, fn, capture) {
      assert.equal(capture, true);
      listeners.set(type, fn);
    },
    removeEventListener(type, fn, capture) {
      assert.equal(capture, true);
      if (listeners.get(type) === fn) listeners.delete(type);
    },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; }
      observe() { observers.add(this); }
      disconnect() { observers.delete(this); }
    }
  });
  context.window = context;
  const fixture = {
    el,
    document,
    mutate() {
      for (const observer of observers) observer.callback([{ type: "attributes", target: el }]);
    },
    navigate() {
      sb.tabs.get(TAB).url = NEXT;
      context.location.href = NEXT;
    },
    destroyContext() {
      contextDestroyed = true;
      listeners.clear();
      observers.clear();
      for (const timer of timers.keys()) context.clearTimeout(timer);
    }
  };
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, url: PAGE }],
    cdp(tabId, method, params) {
      if (inFrame && method === "DOM.getFrameOwner") return { backendNodeId: 31 };
      if (inFrame && method === "DOM.resolveNode") return { object: { objectId: "frame-owner" } };
      if (inFrame && method === "Runtime.callFunctionOn" && params.objectId === "frame-owner") {
        const checkOwner = vm.runInContext(`(${params.functionDeclaration})`, context);
        return { result: { value: checkOwner.call(frameElement, ...params.arguments.map(({ value }) => value)) } };
      }
      if (method === "Runtime.evaluate") {
        queries.push(params);
        if (contextDestroyed && params.expression.startsWith('globalThis["__usemacClickProbe_')) {
          throw new Error("Cannot find context with specified id");
        }
        if (inFrame && params.contextId == null && params.expression.includes('queryOneDeep(document, "#target")')) {
          return { result: { value: null } };
        }
        return Promise.resolve(vm.runInContext(params.expression, context)).then((value) => ({ result: { value } }));
      }
      if (method === "Input.dispatchKeyEvent" && params.type !== "keyUp") onKeyDown?.(sb);
      if (method !== "Input.dispatchMouseEvent" || params.type === "mouseMoved") return;
      const { type, x, y, clickCount, button } = params;
      input.push({ type, x, y, clickCount, button });
      const hit = inFrame && coverFrame?.(x, y) ? frameCover : document.elementFromPoint(x - owner.x, y - owner.y);
      if (type === "mouseReleased") hit?.click?.();
      if (receive && hit) {
        const type = params.type === "mousePressed" ? "pointerdown" : "click";
        listeners.get(type)?.({ isTrusted: true, target: hit, composedPath: () => [hit, document, context] });
      }
      if (type === "mouseReleased") onRelease?.(fixture, sb);
    }
  });
  if (inFrame) {
    owner = { x: 40, y: 30 };
    sb.eval(`
      getOrCreateTabSession(${TAB}).lastChildFrames = [{
        contextId: 42, frameId: "child", offsetX: 40, offsetY: 30,
        hops: [{ frameId: "child" }]
      }];
    `);
  }
  t.after(() => {
    sb.dispose();
    for (const timer of timers.keys()) clearTimeout(timer);
  });

  return async (steps = [{ action: "click", selector: "#target" }], expectedPresses = 1) => {
    const { response } = await sb.request({ command: "act", id: "click-effect", tabId: TAB, returnObservation: false, steps });
    assert.equal(response.ok, true, JSON.stringify(response.error));
    assert.equal(response.actionResult.success, true, JSON.stringify(response.actionResult.stepResults));
    assert.equal(input.filter(({ type }) => type === "mousePressed").length, expectedPresses);
    assert.equal(input.filter(({ type }) => type === "mouseReleased").length, expectedPresses);
    assert.equal(listeners.size, 0, "probe removed its click listeners");
    assert.equal(observers.size, 0, "probe disconnected its observer");
    assert.ok(!Array.from(timers.values()).includes(2000), "probe cleared its timeout");
    return { result: response.actionResult.stepResults[0], input, scrolls, queries, coverClicks };
  };
}

test("a link that navigates reports a changed click", async (t) => {
  const click = withClickPage(t, { link: true, onRelease: ({ navigate }) => navigate() });
  const { result } = await click();
  assert.equal(result.effect, "changed");
  assert.equal(result.mechanism, "cdp-mouse (navigated)");
  assert.equal(result.message, NEXT);
  assert.equal(result.warning, undefined);
});

test("a button's DOM mutation reports a changed click", async (t) => {
  const { result } = await withClickPage(t, { onRelease: ({ mutate }) => mutate() })();
  assert.equal(result.effect, "changed");
  assert.equal(result.mechanism, "cdp-mouse");
  assert.equal(result.warning, undefined);
});

test("a network request without a DOM change reports a changed click", async (t) => {
  const click = withClickPage(t, {
    onRelease: (_, sb) => sb.debuggerEvent(TAB, "Network.requestWillBeSent", {
      requestId: "save", type: "Fetch", request: { url: PAGE + "/save", method: "POST" }
    })
  });
  const { result } = await click();
  assert.equal(result.effect, "changed");
  assert.equal(result.warning, undefined);
});

test("a click the page did not receive reports no effect and is never retried", async (t) => {
  const { result } = await withClickPage(t, { receive: false })();
  assert.equal(result.effect, "none");
  assert.match(result.warning, /did not receive the click event.*Observe again before retrying/);
});

test("a received link click without an observable effect reports none and is never retried", async (t) => {
  const { result } = await withClickPage(t, { link: true })();
  assert.equal(result.effect, "none");
  assert.match(result.warning, /Clicked the link, but no navigation, download, network request, or DOM change was observed/);
});

test("focusing the clicked link itself does not mask a no-effect link click, while moving focus elsewhere counts as changed", async (t) => {
  const selfFocused = withClickPage(t, {
    link: true,
    onRelease: ({ document, el }) => { document.activeElement = el; }
  });
  const { result: deadLink } = await selfFocused();
  assert.equal(deadLink.effect, "none");
  assert.match(deadLink.warning, /Clicked the link, but no navigation, download, network request, or DOM change was observed/);

  const skipTarget = { localName: "section" };
  const skipLink = withClickPage(t, {
    link: true,
    onRelease: ({ document }) => { document.activeElement = skipTarget; }
  });
  const { result: moved } = await skipLink();
  assert.equal(moved.effect, "changed");
  assert.equal(moved.warning, undefined);
});

test("a received non-link click without an observable effect is unverified", async (t) => {
  const { result } = await withClickPage(t)();
  assert.equal(result.effect, "unverified");
  assert.equal(result.warning, undefined);
});

test("a click re-reads coordinates after the reflow queued by scrollIntoView", async (t) => {
  const { input, result, scrolls } = await withClickPage(t, { moveAfterScroll: true })();
  assert.deepEqual(input.map(({ x, y }) => [x, y]), [[300, 200], [300, 200]]);
  assert.equal(scrolls, 1);
  assert.equal(result.effect, "unverified", "the page received the click at the new point");
});

test("DOM clicks refresh iframe offsets and install and read the probe in the target context", async (t) => {
  const { input, result, queries } = await withClickPage(t, { inFrame: true, moveAfterScroll: true })();
  assert.deepEqual(input.map(({ x, y }) => [x, y]), [[410, 300], [410, 300]]);
  assert.equal(result.effect, "unverified");
  const probeQueries = queries.filter(({ expression }) => expression.includes("__usemacClickProbe_"));
  assert.deepEqual(probeQueries.map(({ contextId }) => contextId), [42, 42]);
});

test("a click that destroys its probe context counts as navigation without a second click", async (t) => {
  const { result } = await withClickPage(t, { onRelease: ({ destroyContext }) => destroyContext() })();
  assert.equal(result.mechanism, "cdp-mouse (navigated)");
  assert.equal(result.effect, "changed");
  assert.equal(result.warning, undefined);
});

test("blocked centers use an interior point, and fully covered targets explain the obstruction", async (t) => {
  const partiallyCovered = withClickPage(t, { cover: (x, y) => x === 100 && y === 120 });
  const { input, result } = await partiallyCovered();
  assert.deepEqual(input.map(({ x, y }) => [x, y]), [[80, 110], [80, 110]]);
  assert.equal(result.effect, "unverified");

  const fullyCovered = withClickPage(t, { cover: () => true });
  const { result: blocked } = await fullyCovered(undefined, 0);
  assert.equal(blocked.mechanism, "cdp-mouse (obstructed)");
  assert.equal(blocked.effect, "none");
  assert.match(blocked.warning, /covered by aside/);
});

test("a DOM click skips an iframe target covered by a button in the parent document", async (t) => {
  // Only cover the target's region: checking the center of the iframe itself would miss this button.
  const click = withClickPage(t, { inFrame: true, coverFrame: (x, y) => x >= 100 && x <= 180 && y >= 130 && y <= 170 });
  const { result, coverClicks } = await click(undefined, 0);
  assert.equal(result.mechanism, "cdp-mouse (obstructed)");
  assert.equal(result.effect, "none");
  assert.match(result.warning, /Skipped click because the target is completely covered by button/);
  assert.equal(coverClicks, 0);
});

test("explicit coordinates still click the control at the supplied point", async (t) => {
  const click = withClickPage(t, { inFrame: true, coverFrame: () => true });
  const { result, coverClicks } = await click([{ action: "click", x: 140, y: 150 }]);
  assert.equal(result.mechanism, "cdp-mouse");
  assert.equal(coverClicks, 1);
});

test("doubleClick sends exactly two numbered pairs, and rightClick sends just one right pair", async (t) => {
  const doubleClick = withClickPage(t);
  const rightClick = withClickPage(t);
  const left = await doubleClick([{ action: "doubleClick", selector: "#target" }], 2);
  const right = await rightClick([{ action: "rightClick", selector: "#target" }]);
  assert.deepEqual(left.input.map(({ button, clickCount }) => [button, clickCount]), [["left", 1], ["left", 1], ["left", 2], ["left", 2]]);
  assert.deepEqual(right.input.map(({ button, clickCount }) => [button, clickCount]), [["right", 1], ["right", 1]]);
});

test("a later download promotes a no-effect link result and clears its warning", async (t) => {
  const filename = "/Users/test/Downloads/report.csv";
  const click = withClickPage(t, {
    link: true,
    onKeyDown: (sb) => sb.downloads.create({
      id: 17, url: PAGE + "/report.csv", referrer: PAGE, state: "complete", filename
    })
  });
  const { result } = await click([{ action: "click", selector: "#target" }, { action: "pressKey", key: "space" }]);
  assert.equal(result.effect, "changed");
  assert.equal(result.mechanism, "cdp-mouse (download)");
  assert.equal(result.downloadPath, filename);
  assert.equal(result.warning, null);
});
