import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

const EXTENSION_ID = "gbdlncgdehanogjlemdkbefefdckkmnb";

function withSandbox(t, options = {}) {
  const sandbox = createBackgroundSandbox(options);
  t.after(() => sandbox.dispose());
  sandbox.chrome.runtime.id = EXTENSION_ID;
  sandbox.reloads = 0;
  sandbox.chrome.runtime.reload = () => {
    sandbox.reloads += 1;
  };
  return sandbox;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(condition, timeoutMs = 2000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (condition()) return true;
    await sleep(5);
  }
  return condition();
}

test("hello reports the extension's Chrome ID and stays on protocol 2", async (t) => {
  const sb = withSandbox(t);
  sb.markReady();
  await sb.call("sendHello");
  const hello = sb.sent.find((frame) => frame.type === "hello");
  assert.ok(hello, "no hello frame");
  assert.equal(hello.protocol, 2);
  assert.equal(hello.extensionId, EXTENSION_ID);
  assert.equal(hello.extensionVersion, "0.5.0");
});

test("reload_extension answers first, then reloads, without needing a tab", async (t) => {
  // No tabs at all: a command that went through tab resolution would fail.
  const sb = withSandbox(t, { tabs: [] });
  const { response } = await sb.request({ type: "request", id: "reload-1", command: "reload_extension" });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.error, null);
  assert.equal(response.extensionVersion, "0.5.0");
  assert.equal(sb.reloads, 0, "reloaded before the answer was sent");
  assert.ok(await waitFor(() => sb.reloads === 1), "chrome.runtime.reload() was not called");
  await sleep(250);
  assert.equal(sb.reloads, 1);
});

test("reload_extension waits for the answer to leave the socket", async (t) => {
  const sb = withSandbox(t, { tabs: [] });
  sb.markReady();
  sb.eval("state.ws.bufferedAmount = 512");
  await sb.request({ type: "request", id: "reload-2", command: "reload_extension" });
  await sleep(400);
  assert.equal(sb.reloads, 0);
  sb.eval("state.ws.bufferedAmount = 0");
  assert.ok(await waitFor(() => sb.reloads === 1));
});

test("the app's verdict from `ready` reaches the popup through getState", async (t) => {
  const sb = withSandbox(t);
  assert.ok(await waitFor(() => sb.eval("Boolean(state.ws && state.ws.onmessage)")), "the bridge never opened its socket");
  // Paired (a key is loaded), waiting for `ready` after the auth frame.
  sb.eval(`state.keyLoaded = true; state.hasKey = true; state.ws.readyState = WebSocket.OPEN; state.authState = "authenticating"; state.awaitingAuthResult = true;`);
  const extensionStatus = {
    source: "other_folder",
    bundledVersion: "0.6.0 beta 3",
    outdated: true,
    reloadable: true,
    note: "Loaded from another folder, app updates won't reach it."
  };
  sb.eval(`state.ws.onmessage({ data: ${JSON.stringify(JSON.stringify({ type: "ready", extensionStatus }))} })`);
  assert.equal(sb.eval("state.authState"), "ready");

  const answer = await new Promise((resolve) => {
    sb.chrome.runtime.onMessage.emit({ type: "getState" }, {}, resolve);
  });
  assert.deepEqual(JSON.parse(JSON.stringify(answer.extensionStatus)), extensionStatus);

  // An app that sends no verdict (older UseMac) leaves the popup without a notice.
  sb.eval(`state.authState = "authenticating"; state.awaitingAuthResult = true;`);
  sb.eval(`state.ws.onmessage({ data: ${JSON.stringify(JSON.stringify({ type: "ready" }))} })`);
  const later = await new Promise((resolve) => {
    sb.chrome.runtime.onMessage.emit({ type: "getState" }, {}, resolve);
  });
  assert.equal(later.extensionStatus, null);
});
