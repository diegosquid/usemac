import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

const TAB = 51;
const URL = "https://example.com/";
let requestCount = 0;

function withSandbox(t, cdp) {
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: URL, active: false }],
    cdp
  });
  t.after(() => sb.dispose());
  return sb;
}

async function request(sb, command, args) {
  const { response } = await sb.request({
    type: "request", id: `drag-dialog-${++requestCount}`, command, tabId: TAB, ...args
  });
  return response;
}

function recordMouseInput(event, input) {
  const { type, x, y, button, buttons, clickCount } = event;
  input.push({ type, x, y, button, buttons, clickCount });
}

test("coordinate drag moves a real CDP mouse with its left button held and animates the preview", async (t) => {
  const mouse = [];
  const sb = withSandbox(t, (_, method, params) => {
    if (method === "Input.dispatchMouseEvent") recordMouseInput(params, mouse);
  });
  const response = await request(sb, "act", {
    returnObservation: false,
    steps: [{ action: "drag", x: 10, y: 20, toX: 90, toY: 100, durationMs: 40 }]
  });
  assert.equal(response.actionResult.stepResults[0].mechanism, "cdp-mouse-drag");
  assert.equal(response.actionResult.success, true);
  assert.equal(mouse.length, 11);
  assert.deepEqual(mouse[0], {
    type: "mouseMoved", x: 10, y: 20, button: "none", buttons: undefined, clickCount: undefined
  });
  assert.deepEqual(mouse[1], {
    type: "mousePressed", x: 10, y: 20, button: "left", buttons: 1, clickCount: 1
  });
  assert.deepEqual(mouse.slice(2, 10), Array.from({ length: 8 }, (_, i) => ({
    type: "mouseMoved", x: 20 + i * 10, y: 30 + i * 10, button: "left", buttons: 1, clickCount: undefined
  })));
  assert.deepEqual(mouse[10], {
    type: "mouseReleased", x: 90, y: 100, button: "left", buttons: 0, clickCount: 1
  });
  const cursor = sb.sent.filter((frame) => frame.type === "cursor");
  assert.deepEqual(cursor.map((frame) => frame.phase), ["down", ...Array(8).fill("move"), "up"]);
  assert.deepEqual([cursor[0].x, cursor[0].y, cursor[0].label], [10, 20, "drag"]);
  assert.deepEqual([cursor.at(-1).x, cursor.at(-1).y, cursor.at(-1).label], [90, 100, "drop"]);
});

test("cancelling a pointer drag releases the pressed mouse at its last position", async (t) => {
  const mouse = [];
  const sb = withSandbox(t, (tabId, method, params) => {
    if (method !== "Input.dispatchMouseEvent") return;
    recordMouseInput(params, mouse);
    if (params.type === "mouseMoved" && params.buttons === 1) sb.call("handleCancel", tabId);
  });
  const response = await request(sb, "act", {
    returnObservation: false,
    steps: [{ action: "drag", x: 10, y: 20, toX: 90, toY: 100, durationMs: 40 }]
  });
  assert.equal(response.error.code, "CANCELLED");
  assert.deepEqual(mouse.map(({ type }) => type), ["mouseMoved", "mousePressed", "mouseMoved", "mouseReleased"]);
  const release = mouse.at(-1);
  assert.deepEqual([release.x, release.y, release.buttons], [20, 30, 0]);
  assert.equal(sb.sent.filter((frame) => frame.type === "cursor").at(-1).phase, "up");
});

test("HTML5 drag uses DOM events inside an open shadow root and one shared DataTransfer", async (t) => {
  const events = [];
  const mouse = [];
  class SyntheticEvent {
    constructor(type, options) { Object.assign(this, { type }, options); }
  }
  class Transfer {
    data = new Map();
    setData(type, value) { this.data.set(type, value); }
    getData(type) { return this.data.get(type); }
  }
  function element(name, left, top, attributes = {}, draggableParent = null) {
    return {
      tagName: "DIV",
      isConnected: true,
      draggable: attributes.draggable === "true",
      getAttribute: (key) => attributes[key] ?? null,
      getBoundingClientRect: () => ({ left, top, width: 20, height: 10 }),
      scrollIntoView() {},
      closest(selector) {
        assert.equal(selector, '[draggable="true"]');
        return draggableParent;
      },
      dispatchEvent(event) {
        if (event.type === "dragstart") event.dataTransfer.setData("text/plain", "card");
        if (event.type === "drop") assert.equal(event.dataTransfer.getData("text/plain"), "card");
        events.push({ name, event });
      }
    };
  }
  const card = element("card", 10, 20, { draggable: "true" });
  const handle = element("handle", 20, 30, {}, card);
  const destination = element("destination", 90, 100, { "data-usemac-id": "@b2" });
  const shadowRoot = {
    querySelector: (sel) => ({ "#handle": handle, '[data-usemac-id="@b2"]': destination })[sel],
    querySelectorAll: () => []
  };
  const frame = vm.createContext({
    document: { querySelector: () => null, querySelectorAll: () => [{ shadowRoot }] },
    PointerEvent: SyntheticEvent,
    MouseEvent: SyntheticEvent,
    DragEvent: SyntheticEvent,
    DataTransfer: Transfer
  });
  const sb = withSandbox(t, (_, method, params) => {
    if (method === "Input.dispatchMouseEvent") recordMouseInput(params, mouse);
    if (method === "Runtime.evaluate" && (
      params.expression.includes("const el = queryOneDeep(document,") ||
      params.expression.includes("const el = findByUsemacId(") ||
      params.expression.includes("function inspectOrDispatchDOMDrag(")
    )) {
      return { result: { value: vm.runInContext(params.expression, frame) } };
    }
  });
  sb.eval(`getOrCreateTabSession(${TAB}).elementFrameMap.set("@b2", { frameId: null, sessionId: null })`);
  const response = await request(sb, "act", {
    returnObservation: false,
    steps: [{ action: "drag", selector: "#handle", toElementId: "@b2", durationMs: 40 }]
  });
  assert.equal(response.actionResult.stepResults[0].mechanism, "dom-html5-drag");
  assert.deepEqual(mouse, [], "Do not send a second drag through CDP");
  assert.deepEqual(events.map(({ event }) => event.type), [
    "pointerdown", "mousedown", "dragstart", "dragenter", "dragover", "drop", "dragend", "pointerup", "mouseup"
  ]);
  assert.deepEqual(events.map(({ name }) => name), [
    "handle", "handle", "card", "destination", "destination", "destination", "card", "destination", "destination"
  ]);
  assert.ok(events.every(({ event }) => event.bubbles && event.cancelable));
  const transfers = events.filter(({ event }) => event.type.startsWith("drag") || event.type === "drop")
    .map(({ event }) => event.dataTransfer);
  assert.ok(transfers[0] instanceof Transfer);
  assert.equal(new Set(transfers).size, 1);
  assert.deepEqual(events.map(({ event }) => [event.clientX, event.clientY]), [
    [30, 35], [30, 35], [30, 35], [100, 105], [100, 105], [100, 105], [100, 105], [100, 105], [100, 105]
  ]);
});

test("drag rejects an absent endpoint without moving or pressing the mouse, and reports unresolved elements", async (t) => {
  const mouse = [];
  const sb = withSandbox(t, (_, method, params) => {
    if (method === "Input.dispatchMouseEvent") recordMouseInput(params, mouse);
  });
  const steps = [
    { action: "drag", x: 1, match: { text: " " }, toX: 20, toY: 30 },
    { action: "drag", x: 10, y: 10, toX: 20, toSelector: " " },
    { action: "drag", selector: "#missing", toX: 20, toY: 30 },
    { action: "drag", x: 10, y: 10, toElementId: "@b999" }
  ];
  const response = await request(sb, "act", { returnObservation: false, stopOnError: false, steps });
  const results = response.actionResult.stepResults;
  assert.deepEqual(results.map((step) => step.errorCode), [
    "INVALID_REQUEST", "INVALID_REQUEST", "ELEMENT_NOT_FOUND", "ELEMENT_NOT_FOUND"
  ]);
  assert.match(results[0].message, /requires a source/);
  assert.match(results[1].message, /requires a destination/);
  assert.deepEqual(mouse, []);
});

const dialogCases = [
  { type: "alert", accepted: true },
  { type: "beforeunload", accepted: true },
  { type: "confirm", accepted: false, warning: true },
  { type: "prompt", accepted: false, warning: true, defaultPrompt: "initial" },
  { type: "confirm", action: "accept", accepted: true },
  { type: "alert", action: "dismiss", accepted: false },
  { type: "prompt", action: "AcCePt", accepted: true, defaultPrompt: "initial", promptText: "hello" },
  { type: "prompt", action: "accept", accepted: true, defaultPrompt: "initial", useDefault: true }
];

for (const { type, action, accepted, warning, defaultPrompt, promptText, useDefault } of dialogCases) {
  test(`act unblocks ${type} with ${action ?? "the default policy"}${useDefault ? " and default prompt text" : ""}`, async (t) => {
    const message = "Continue?";
    const handled = [];
    let eventFired = false;
    let resumeInput;
    const blockedInput = new Promise((resolve) => { resumeInput = resolve; });
    const sb = withSandbox(t, (tabId, method, params) => {
      if (method === "Input.dispatchKeyEvent" && !eventFired) {
        eventFired = true;
        sb.debuggerEvent(tabId, "Page.javascriptDialogOpening", { type, message, defaultPrompt }, "child-session");
        return blockedInput;
      }
      if (method === "Page.handleJavaScriptDialog") {
        handled.push(JSON.parse(JSON.stringify(params)));
        resumeInput({});
      }
    });
    const targets = [];
    const sendCommand = sb.chrome.debugger.sendCommand;
    sb.chrome.debugger.sendCommand = (target, method, params) => {
      if (method === "Page.handleJavaScriptDialog") targets.push(target.sessionId);
      return sendCommand(target, method, params);
    };
    const args = { dialogAction: action, dialogPromptText: promptText, steps: [{ action: "pressKey", key: "enter" }] };
    const response = await request(sb, "act", args);
    const expectedText = useDefault ? defaultPrompt : promptText;
    const expected = {
      type, message, accepted,
      ...(defaultPrompt === undefined ? {} : { defaultPrompt }),
      ...(expectedText === undefined ? {} : { promptText: expectedText })
    };
    assert.equal(response.actionResult.success, true);
    assert.deepEqual(handled, [{ accept: accepted, ...(expectedText === undefined ? {} : { promptText: expectedText }) }]);
    assert.deepEqual(targets, ["child-session"]);
    assert.deepEqual(response.actionResult.dialogs, [expected]);
    assert.deepEqual(response.actionResult.observation.pageState.lastDialog, expected);
    assert.equal(response.actionResult.agentFeedback?.trigger, warning ? "js_dialog_dismissed" : undefined);
    assert.deepEqual(
      JSON.parse(sb.eval(`JSON.stringify([state.tabSessions.get(${TAB}).dialogPolicy, state.tabSessions.get(${TAB}).batchDialogs])`)),
      [null, null]
    );
    const observed = await request(sb, "observe", {});
    assert.deepEqual(observed.snapshot.pageState.lastDialog, expected);
  });
}

test("open pre-arms a new tab so load-time dialogs are captured even without inline steps", async (t) => {
  const handled = [];
  let resumeNavigation;
  const updateFinished = new Promise((resolve) => { resumeNavigation = resolve; });
  const sb = withSandbox(t, async (tabId, method, params) => {
    if (method === "Page.handleJavaScriptDialog") {
      handled.push(params.accept);
      resumeNavigation();
    }
    if (method === "Runtime.evaluate" && params.expression === `location.replace(${JSON.stringify(URL)})`) {
      assert.equal(sb.tabs.get(tabId).url, "about:blank");
      assert.ok(sb.callsTo("debugger.sendCommand").some(({ args }) => args[0] === tabId && args[1] === "Page.enable"));
      sb.debuggerEvent(tabId, "Page.javascriptDialogOpening", { type: "confirm", message: "At startup" });
      await updateFinished;
    }
  });
  const response = await request(sb, "open", { tabId: null, url: URL, stream: false });
  const expected = { type: "confirm", message: "At startup", accepted: false };
  assert.equal(response.ok, true, JSON.stringify(response));
  assert.deepEqual(handled, [false]);
  assert.deepEqual(response.actionResult.dialogs, [expected]);
  assert.deepEqual(response.actionResult.observation.pageState.lastDialog, expected);
  assert.deepEqual(response.snapshot.pageState.lastDialog, expected);
  assert.equal(response.actionResult.agentFeedback.trigger, "js_dialog_dismissed");
});

test("open on an existing tab captures beforeunload before a restricted destination forces detach", async (t) => {
  const restrictedUrl = "https://chromewebstore.google.com/detail/usemac/abcdefghijklmnop";
  const handled = [];
  const sb = withSandbox(t, (_, method, params) => {
    if (method === "Page.handleJavaScriptDialog") handled.push(params.accept);
  });
  const update = sb.chrome.tabs.update;
  sb.chrome.tabs.update = async (tabId, props) => {
    assert.ok(sb.attached.has(tabId));
    sb.debuggerEvent(tabId, "Page.javascriptDialogOpening", { type: "beforeunload", message: "" });
    return update(tabId, props);
  };
  const response = await request(sb, "open", { url: restrictedUrl, dialogAction: "accept" });
  assert.equal(response.restricted, true, JSON.stringify(response));
  assert.deepEqual(handled, [true]);
  assert.deepEqual(response.actionResult.dialogs, [{ type: "beforeunload", message: "", accepted: true }]);
  assert.equal(response.actionResult.observation.agentFeedback.trigger, "restricted_page");
  assert.equal(sb.attached.has(TAB), false);
});

test("open and act reject invalid dialog policies before running steps or navigation", async (t) => {
  const sb = withSandbox(t);
  const open = await request(sb, "open", { url: URL, dialogAction: "" });
  const act = await request(sb, "act", { dialogAction: "maybe", steps: [{ action: "click", x: 1, y: 2 }] });
  assert.equal(open.error.code, "INVALID_REQUEST");
  assert.equal(act.error.code, "INVALID_REQUEST");
  assert.equal(sb.callsTo("tabs.update").length, 0);
  assert.equal(sb.callsTo("debugger.attach").length, 0);
});
