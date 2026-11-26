import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

const TAB = 31;
let counter = 0;
const nextId = () => `input-${++counter}`;

// Records every CDP Input.* command with its params, so a test can tell whether anything was typed or pressed.
function withSandbox(t) {
  const input = [];
  const sandbox = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "http://127.0.0.1:8000/form.html", active: false }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => {
      if (method.startsWith("Input.")) input.push({ method, params: JSON.parse(JSON.stringify(params ?? {})) });
      return undefined;
    }
  });
  t.after(() => sandbox.dispose());
  return { sb: sandbox, input };
}

async function act(sb, steps) {
  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps
  });
  return response;
}

const typed = (input) =>
  input.filter((c) => c.method === "Input.insertText" || c.method === "Input.dispatchKeyEvent");

// --- setValue must name its field ----------------------------------------------------------------------------------

test("setValue with an empty, blank or missing target fails with INVALID_REQUEST and types nothing", async (t) => {
  const targetless = [
    { action: "setValue", elementId: "", text: "secret" },
    { action: "setValue", elementId: "   ", text: "secret" },
    { action: "setValue", selector: "", text: "secret" },
    { action: "setValue", text: "secret" },
    { action: "setValue", elementId: "", selector: " ", text: "secret" },
    // Empty match names no target.
    { action: "setValue", match: {}, text: "secret" },
    { action: "setValue", match: { role: "  " }, text: "secret" },
    // Half a point is no point.
    { action: "setValue", x: 40, text: "secret" }
  ];
  for (const step of targetless) {
    const { sb, input } = withSandbox(t);
    const response = await act(sb, [step]);
    const label = JSON.stringify(step);
    const [result] = response.actionResult.stepResults;
    assert.equal(result.success, false, label);
    assert.equal(result.errorCode, "INVALID_REQUEST", label);
    assert.match(result.message, /setValue names no field: pass elementId .* or selector/, label);
    assert.match(result.message, /use type/, label);
    assert.equal(response.actionResult.success, false, label);
    assert.deepEqual(typed(input), [], `${label} typed or pressed keys: ${JSON.stringify(typed(input))}`);
  }
});

test("a targetless setValue stops the batch before later steps run", async (t) => {
  const { sb, input } = withSandbox(t);
  const response = await act(sb, [
    { action: "setValue", elementId: "", text: "first" },
    { action: "type", text: "second" }
  ]);
  const results = response.actionResult.stepResults;
  assert.equal(results.length, 1, JSON.stringify(results));
  assert.equal(results[0].errorCode, "INVALID_REQUEST");
  assert.deepEqual(typed(input), []);
});

test("setValue at a point still clicks there and replaces the text", async (t) => {
  const { sb, input } = withSandbox(t);
  const response = await act(sb, [{ action: "setValue", x: 120, y: 80, text: "Ada" }]);
  const [result] = response.actionResult.stepResults;
  assert.equal(result.success, true, JSON.stringify(result));
  const pressed = input.filter((c) => c.method === "Input.dispatchMouseEvent" && c.params.type === "mousePressed");
  assert.deepEqual(pressed.map((c) => [c.params.x, c.params.y]), [[120, 80]]);
  const inserted = input.filter((c) => c.method === "Input.insertText").map((c) => c.params.text);
  assert.deepEqual(inserted, ["Ada"]);
});

test("type without a target still types into the focused element", async (t) => {
  const { sb, input } = withSandbox(t);
  const response = await act(sb, [{ action: "type", text: "hello" }]);
  assert.equal(response.actionResult.stepResults[0].success, true, JSON.stringify(response.actionResult));
  assert.deepEqual(
    input.filter((c) => c.method === "Input.insertText").map((c) => c.params.text),
    ["hello"]
  );
});

test("stepNamesTarget accepts a non-blank elementId, selector, match, or full point", (t) => {
  const { sb } = withSandbox(t);
  const names = (step) => sb.call("stepNamesTarget", step);
  assert.equal(names({ elementId: "@b2" }), true);
  assert.equal(names({ selector: "#email" }), true);
  assert.equal(names({ match: { role: "textbox" } }), true);
  assert.equal(names({ match: { title: "Email" } }), true);
  assert.equal(names({ match: {} }), false);
  assert.equal(names({ match: { role: "  " } }), false);
  assert.equal(names({ elementId: "", selector: "#email" }), true);
  assert.equal(names({ x: 0, y: 0 }), true);
  assert.equal(names({ elementId: "" }), false);
  assert.equal(names({ elementId: "\t" }), false);
  assert.equal(names({ y: 3 }), false);
  assert.equal(names({ x: "10", y: "20" }), false);
  assert.equal(names({}), false);
});

// --- key names shared with native pressKey -------------------------------------------------------------------------

test("buildKeyDescriptor knows forwarddelete and F1-F12 like native pressKey", (t) => {
  const { sb } = withSandbox(t);
  const key = (name) => sb.call("buildKeyDescriptor", name);
  assert.deepEqual({ ...key("forwarddelete") }, { key: "Delete", code: "Delete", keyCode: 46 });
  assert.deepEqual({ ...key("ForwardDelete") }, { key: "Delete", code: "Delete", keyCode: 46 });
  for (let n = 1; n <= 12; n++) {
    assert.deepEqual({ ...key(`f${n}`) }, { key: `F${n}`, code: `F${n}`, keyCode: 111 + n }, `f${n}`);
    assert.deepEqual({ ...key(`F${n}`) }, { key: `F${n}`, code: `F${n}`, keyCode: 111 + n }, `F${n}`);
  }
  // Unchanged names keep their meaning; "delete" stays the DOM Delete key in Chrome.
  assert.deepEqual({ ...key("delete") }, { key: "Delete", code: "Delete", keyCode: 46 });
  assert.deepEqual({ ...key("Backspace") }, { key: "Backspace", code: "Backspace", keyCode: 8 });
  assert.deepEqual({ ...key("PageDown") }, { key: "PageDown", code: "PageDown", keyCode: 34 });
  assert.deepEqual({ ...key("pageDown") }, { key: "PageDown", code: "PageDown", keyCode: 34 });
});

test("pressKey F5 sends the F5 key with its virtual key code", async (t) => {
  const { sb, input } = withSandbox(t);
  const response = await act(sb, [{ action: "pressKey", key: "F5" }]);
  assert.equal(response.actionResult.stepResults[0].success, true, JSON.stringify(response.actionResult));
  const keys = input.filter((c) => c.method === "Input.dispatchKeyEvent");
  assert.deepEqual(
    keys.map((c) => [c.params.type, c.params.key, c.params.code, c.params.windowsVirtualKeyCode]),
    [
      ["rawKeyDown", "F5", "F5", 116],
      ["keyUp", "F5", "F5", 116]
    ]
  );
});

// --- modifier names shared with native pressKey and the sensitive-shortcut check ---------------------------------

test("buildModifierMask takes the same spellings as ModifierAliases.swift", (t) => {
  const { sb } = withSandbox(t);
  const mask = (mods) => sb.call("buildModifierMask", mods);
  // CDP bits: Alt 1, Ctrl 2, Meta/Command 4, Shift 8.
  for (const name of ["alt", "opt", "option", "Opt"]) assert.equal(mask([name]), 1, name);
  for (const name of ["ctrl", "control"]) assert.equal(mask([name]), 2, name);
  for (const name of ["cmd", "command", "meta", "META", " cmd "]) assert.equal(mask([name]), 4, name);
  assert.equal(mask(["shift"]), 8);
  assert.equal(mask(["meta", "shift", "ctrl", "alt"]), 15);
  assert.equal(mask(["fn", "hyper", "super"]), 0);
  assert.equal(mask(undefined), 0);
});
