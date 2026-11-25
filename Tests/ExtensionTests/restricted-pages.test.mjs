import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");

const STORE_URL = "https://chrome.google.com/webstore/devconsole/0b1c/abc/edit";
const NEW_STORE_URL = "https://chromewebstore.google.com/detail/usemac/abcdefghijklmnop";

let requestCounter = 0;
const nextId = () => `req-${++requestCounter}`;

function withSandbox(t, options) {
  const sandbox = createBackgroundSandbox(options);
  t.after(() => sandbox.dispose());
  return sandbox;
}

// --- URL classification ------------------------------------------------------------------------------------------

test("restrictedPageReason flags browser-internal schemes and lets web pages through", (t) => {
  const sb = withSandbox(t, { tabs: [] });
  const reason = (url, opts) => sb.call("restrictedPageReason", url, opts);

  for (const url of [
    "chrome://settings/",
    "chrome://newtab/",
    "chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html",
    "chrome-untrusted://print/",
    "chrome-search://local-ntp/local-ntp.html",
    "devtools://devtools/bundled/inspector.html",
    "view-source:https://example.com/",
    "edge://settings",
    "brave://rewards",
    "opera://settings",
    "about:settings"
  ]) {
    assert.equal(reason(url), "browser_page", url);
  }

  for (const url of [
    "https://example.com/",
    "http://localhost:8080/app",
    "https://www.google.com/search?q=chrome.google.com",
    "https://mail.google.com/mail/u/0/",
    "https://mychromewebstore.google.com/",
    "https://chrome.google.com.example.net/webstore",
    "about:blank",
    "about:srcdoc",
    "data:text/html,<p>hi</p>",
    "blob:https://example.com/0f6c1b9e-1d1f-4d34-9a07-4b1c2a8e9c10",
    "",
    "not a url",
    null
  ]) {
    assert.equal(reason(url), null, String(url));
  }
});

test("restrictedPageReason flags extension stores, including the whole chrome.google.com host", (t) => {
  const sb = withSandbox(t, { tabs: [] });
  const reason = (url, opts) => sb.call("restrictedPageReason", url, opts);

  assert.equal(reason(STORE_URL), "extension_store");
  assert.equal(reason("https://chrome.google.com/webstore/category/extensions"), "extension_store");
  assert.equal(reason(NEW_STORE_URL), "extension_store");
  assert.equal(reason("https://CHROMEWEBSTORE.google.com./"), "extension_store");

  // Other browsers' stores are only restricted in that browser.
  const edgeStore = "https://microsoftedge.microsoft.com/addons/detail/abc";
  assert.equal(reason(edgeStore, { browser: "chrome" }), null);
  assert.equal(reason(edgeStore, { browser: "edge" }), "extension_store");
  assert.equal(reason("https://addons.opera.com/en/extensions/", { browser: "opera" }), "extension_store");
  assert.equal(reason("https://addons.opera.com/en/extensions/", { browser: "chrome" }), null);
});

test("file:// pages are restricted unless the user allowed file URL access", (t) => {
  const sb = withSandbox(t, { tabs: [] });
  assert.equal(sb.call("restrictedPageReason", "file:///Users/me/report.html"), "file_access");
  assert.equal(sb.call("restrictedPageReason", "file:///Users/me/report.html", { fileAccess: true }), null);
});

test("detectBrowserFlavor recognizes Edge and Opera user agents", (t) => {
  const sb = withSandbox(t, { tabs: [] });
  const flavor = (userAgent) => sb.call("detectBrowserFlavor", { userAgent });
  assert.equal(flavor("Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"), "chrome");
  assert.equal(flavor("Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"), "edge");
  assert.equal(flavor("Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36 OPR/115.0.0.0"), "opera");
});

test("isRestrictedChromeError matches Chrome's refusal messages only", (t) => {
  const sb = withSandbox(t, { tabs: [] });
  const matches = (msg) => sb.call("isRestrictedChromeError", msg);
  assert.equal(matches("The extensions gallery cannot be scripted."), true);
  assert.equal(matches("Cannot access a chrome:// URL"), true);
  assert.equal(matches("Cannot access a chrome-extension:// URL of different extension"), true);
  assert.equal(matches("Cannot attach to this target."), true);
  assert.equal(matches("This page cannot be scripted due to an ExtensionsSettings policy."), true);
  assert.equal(matches("Cannot access contents of url \"file:///x.html\". Extension manifest must request permission to access this host."), true);
  assert.equal(matches({ message: "The extensions gallery cannot be scripted." }), true);

  assert.equal(matches("Another debugger is already attached to the tab with id: 3."), false);
  assert.equal(matches("No tab with id: 4."), false);
  assert.equal(matches(""), false);
  assert.equal(matches(undefined), false);
});

// --- Commands on restricted tabs fail fast -----------------------------------------------------------------------

test("observe, extract, screenshot and act on a Web Store tab answer RESTRICTED_PAGE without touching the debugger", async (t) => {
  const sb = withSandbox(t, {
    tabs: [
      { id: 101, windowId: 1, url: STORE_URL, active: false },
      { id: 102, windowId: 1, url: "https://example.com/", active: true }
    ]
  });

  const requests = [
    { command: "observe", tabId: 101 },
    { command: "extract", tabId: 101, mode: "text" },
    { command: "extract", tabId: 101, mode: "eval", expression: "1 + 1" },
    { command: "screenshot", tabId: 101 },
    { command: "act", tabId: 101, steps: [{ action: "click", elementId: "@b3" }] }
  ];
  for (const req of requests) {
    const { response, elapsedMs } = await sb.request({ type: "request", id: nextId(), ...req });
    assert.equal(response.ok, false, req.command);
    assert.equal(response.error.code, "RESTRICTED_PAGE", req.command);
    assert.ok(elapsedMs < 1000, `${req.command} took ${elapsedMs} ms`);
    const msg = response.error.message;
    assert.match(msg, /Chrome does not allow extensions to script this page/);
    assert.match(msg, /extension store page/);
    assert.ok(msg.includes(STORE_URL), msg);
    assert.ok(msg.includes(`browser_open {"tabId":101,"url":"","activate":true}`), msg);
    assert.ok(msg.includes(`"newWindow":true`), msg);
    assert.ok(msg.includes(`native observe/act with app "Google Chrome"`), msg);
  }

  assert.equal(sb.callsTo("debugger.attach").length, 0);
  assert.equal(sb.callsTo("debugger.sendCommand").length, 0);
  // The user's tab is not pulled into the UseMac group for a command that cannot run.
  assert.equal(sb.callsTo("tabs.group").length, 0);
});

test("a restricted tab that is already active is pointed straight at native observe/act", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 111, windowId: 1, url: NEW_STORE_URL, active: true }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 111 });
  assert.equal(response.error.code, "RESTRICTED_PAGE");
  assert.match(response.error.message, /use native observe\/act with app "Google Chrome": it is already the active tab of its window/);
  assert.ok(!response.error.message.includes(`"activate":true`), response.error.message);
});

test("the native app name follows the browser the extension runs in", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 121, windowId: 1, url: "edge://settings", active: false }],
    userAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"
  });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 121 });
  assert.match(response.error.message, /app "Microsoft Edge"/);
});

test("chrome:// tabs get RESTRICTED_PAGE without a newWindow suggestion (browser_open only opens http(s))", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 201, windowId: 1, url: "chrome://settings/passwords", active: false }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 201 });
  assert.equal(response.error.code, "RESTRICTED_PAGE");
  assert.match(response.error.message, /browser-internal page: chrome:\/\/settings\/passwords/);
  assert.ok(!response.error.message.includes("newWindow"), response.error.message);
  assert.equal(sb.callsTo("debugger.attach").length, 0);
});

test("a tab navigating to a restricted page is judged by its pendingUrl", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 301, windowId: 1, url: "https://example.com/", pendingUrl: NEW_STORE_URL, status: "loading", active: true }]
  });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 301 });
  assert.equal(response.error.code, "RESTRICTED_PAGE");
  assert.equal(sb.callsTo("debugger.attach").length, 0);
});

test("Chrome attach refusals on URLs not in the list are mapped to RESTRICTED_PAGE", async (t) => {
  const refusals = {
    401: "Cannot attach to this target.",
    402: "This page cannot be scripted due to an ExtensionsSettings policy."
  };
  const sb = withSandbox(t, {
    tabs: [
      { id: 401, windowId: 1, url: "https://intranet.example.com/", active: true },
      { id: 402, windowId: 1, url: "https://blocked.example.com/", active: false }
    ],
    attachError: (tabId) => refusals[tabId] || null
  });

  const first = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 401 });
  assert.equal(first.response.error.code, "RESTRICTED_PAGE");
  assert.match(first.response.error.message, /Chrome refused to let the extension script it/);
  assert.match(first.response.error.message, /\(Chrome: Cannot attach to this target\.\)/);

  const second = await sb.request({ type: "request", id: nextId(), command: "screenshot", tabId: 402 });
  assert.equal(second.response.error.code, "RESTRICTED_PAGE");
  assert.match(second.response.error.message, /blocked for extensions by browser policy/);
});

test("other attach failures keep their original error", async (t) => {
  const sb = withSandbox(t, {
    tabs: [{ id: 501, windowId: 1, url: "https://example.com/", active: true }],
    attachError: () => "Another debugger is already attached to the tab with id: 501."
  });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 501 });
  assert.equal(response.error.code, "EXTENSION_ERROR");
  assert.match(response.error.message, /Another debugger is already attached/);
});

test("file:// tabs follow the file URL access setting", async (t) => {
  const denied = withSandbox(t, { tabs: [{ id: 601, windowId: 1, url: "file:///tmp/a.html", active: true }] });
  const blocked = await denied.request({ type: "request", id: nextId(), command: "observe", tabId: 601 });
  assert.equal(blocked.response.error.code, "RESTRICTED_PAGE");
  assert.match(blocked.response.error.message, /Allow access to file URLs/);

  const allowed = withSandbox(t, { tabs: [{ id: 602, windowId: 1, url: "file:///tmp/a.html", active: true }], fileAccess: true });
  const ok = await allowed.request({ type: "request", id: nextId(), command: "observe", tabId: 602 });
  assert.equal(ok.response.ok, true, JSON.stringify(ok.response.error));
  assert.equal(allowed.callsTo("debugger.attach").length, 1);
});

// --- Tab listing -------------------------------------------------------------------------------------------------

test("tabs listing marks restricted tabs with restricted: true and leaves others unmarked", async (t) => {
  const sb = withSandbox(t, {
    tabs: [
      { id: 701, windowId: 1, url: STORE_URL, active: true },
      { id: 702, windowId: 1, url: "chrome://extensions/", active: false },
      { id: 703, windowId: 1, url: "https://example.com/", active: false },
      { id: 704, windowId: 1, url: "file:///tmp/a.html", active: false }
    ]
  });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "tabs" });
  const byId = Object.fromEntries(response.tabs.map((tab) => [tab.tabId, tab]));
  assert.equal(byId[701].restricted, true);
  assert.equal(byId[702].restricted, true);
  assert.equal("restricted" in byId[703], false);
  assert.equal(byId[704].restricted, true);
});

// --- browser_open: activate ----------------------------------------------------------------------------------------

test("open with tabId, empty url and activate only activates the tab, without focusing the window or the debugger", async (t) => {
  const sb = withSandbox(t, {
    tabs: [
      { id: 801, windowId: 1, url: "https://mail.example.com/", active: true },
      { id: 802, windowId: 1, url: STORE_URL, active: false }
    ]
  });
  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "open",
    url: "",
    tabId: 802,
    newTab: false,
    stream: true,
    activate: true
  });

  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.tabId, 802);
  assert.equal(response.windowId, 1);
  assert.equal(response.url, STORE_URL);
  assert.equal(response.restricted, true);
  assert.equal(response.snapshot.elements.length, 0);
  assert.equal(response.snapshot.agentFeedback.trigger, "restricted_page");
  assert.match(response.snapshot.agentFeedback.suggestedAction, /now the active tab of its window/);
  assert.match(response.snapshot.agentFeedback.suggestedAction, /app "Google Chrome"/);

  assert.deepEqual(sb.callsTo("tabs.update").map((c) => c.args), [[802, { active: true }]]);
  assert.equal(sb.tabs.get(802).active, true);
  assert.equal(sb.tabs.get(801).active, false);
  assert.equal(sb.tabs.get(802).url, STORE_URL, "no navigation");
  assert.equal(sb.callsTo("windows.update").length, 0, "must not focus the Chrome window");
  assert.equal(sb.callsTo("debugger.attach").length, 0);
  assert.equal(sb.callsTo("tabs.group").length, 0, "the user's tab stays where it is");
});

test("activate-only on a normal tab returns no snapshot and does not attach", async (t) => {
  const sb = withSandbox(t, {
    tabs: [
      { id: 811, windowId: 3, url: "https://example.com/a", active: false },
      { id: 812, windowId: 3, url: "https://example.com/b", active: true }
    ]
  });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: "", tabId: 811, activate: true });
  assert.equal(response.ok, true);
  assert.equal(response.tabId, 811);
  assert.equal(response.windowId, 3);
  assert.equal(response.snapshot, null);
  assert.equal("restricted" in response, false);
  assert.equal(sb.tabs.get(811).active, true);
  assert.equal(sb.callsTo("debugger.attach").length, 0);
});

test("open with an empty url and no activate is rejected", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 821, windowId: 1, url: "https://example.com/", active: true }] });
  for (const req of [
    { command: "open", url: "", tabId: 821 },
    { command: "open", url: "  ", activate: true },
    { command: "open", url: "", tabId: 821, activate: true, newWindow: true }
  ]) {
    const { response } = await sb.request({ type: "request", id: nextId(), ...req });
    assert.equal(response.ok, false);
    assert.equal(response.error.code, "INVALID_ARGUMENT", JSON.stringify(req));
  }
  assert.equal(sb.callsTo("tabs.update").length, 0);
});

test("open with tabId, url and activate navigates and activates in one tabs.update", async (t) => {
  const sb = withSandbox(t, {
    tabs: [
      { id: 831, windowId: 1, url: "https://example.com/", active: true },
      { id: 832, windowId: 1, url: "https://example.com/other", active: false }
    ]
  });
  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "open",
    url: NEW_STORE_URL,
    tabId: 832,
    newTab: false,
    stream: true,
    activate: true
  });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.deepEqual(sb.callsTo("tabs.update")[0].args, [832, { url: NEW_STORE_URL, active: true }]);
  assert.equal(sb.tabs.get(832).active, true);
});

// --- browser_open: navigation onto restricted pages -----------------------------------------------------------------

test("open with tabId onto a restricted URL navigates with tabs.update and skips attach and streaming", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 901, windowId: 1, url: "https://example.com/", active: true }] });
  const { response, elapsedMs } = await sb.request({
    type: "request",
    id: nextId(),
    command: "open",
    url: STORE_URL,
    tabId: 901,
    newTab: false,
    stream: true
  });

  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.tabId, 901);
  assert.equal(response.url, STORE_URL);
  assert.equal(response.restricted, true);
  assert.equal(response.snapshot.agentFeedback.trigger, "restricted_page");
  // The user's active tab was navigated, so it is already what native observe sees.
  assert.match(response.snapshot.agentFeedback.suggestedAction, /already the active tab of its window/);
  assert.ok(elapsedMs < 1500, `open took ${elapsedMs} ms`);

  assert.deepEqual(sb.callsTo("tabs.update")[0].args, [901, { url: STORE_URL }]);
  assert.equal(sb.callsTo("debugger.attach").length, 0);
  assert.equal(sb.callsTo("debugger.sendCommand").length, 0, "no Page.startScreencast on a restricted page");
});

test("open of a restricted URL in a new tab works and tracks the tab as the UseMac tab", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 911, windowId: 1, url: "https://example.com/", active: true }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: NEW_STORE_URL, newTab: true, stream: true });

  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.restricted, true);
  const created = sb.callsTo("tabs.create");
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].args[0], { windowId: 1, url: NEW_STORE_URL, active: false });
  // Opened in the background, so the guidance says how to activate it.
  assert.ok(response.snapshot.agentFeedback.suggestedAction.includes(`browser_open {"tabId":${response.tabId},"url":"","activate":true}`));
  assert.equal(sb.tabs.get(response.tabId).groupId !== -1, true, "grouped into UseMac");
  assert.equal(sb.eval("state.lastTabId"), response.tabId);
  assert.equal(sb.callsTo("debugger.attach").length, 0);

  // A later command without tabId lands on that tab and fails fast instead of hanging.
  const observe = await sb.request({ type: "request", id: nextId(), command: "observe" });
  assert.equal(observe.response.error.code, "RESTRICTED_PAGE");
  assert.equal(observe.response.tabId, response.tabId);
});

test("open of a normal URL still attaches, streams and observes", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 921, windowId: 1, url: "https://example.com/", active: true }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: "https://example.org/", newTab: true, stream: true });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal("restricted" in response, false);
  assert.ok(response.snapshot, "snapshot from observeTab");
  assert.equal(response.windowId, 1);
  assert.equal(sb.callsTo("debugger.attach").length, 1);
  assert.ok(sb.callsTo("debugger.sendCommand").some((c) => c.args[1] === "Page.startScreencast"));
});

// --- browser_open: newWindow ---------------------------------------------------------------------------------------

test("open with newWindow creates an unfocused window, groups its tab and returns tabId and windowId", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 1001, windowId: 1, url: "https://mail.example.com/", active: true }] });
  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "open",
    url: "https://example.org/",
    newTab: true,
    stream: true,
    newWindow: true
  });

  assert.equal(response.ok, true, JSON.stringify(response.error));
  const created = sb.callsTo("windows.create");
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].args[0], { url: "https://example.org/", focused: false, type: "normal" });
  assert.equal(sb.callsTo("tabs.create").length, 0, "no tab added to the user's window");
  assert.equal(sb.callsTo("windows.update").length, 0);

  const tab = sb.tabs.get(response.tabId);
  assert.ok(tab, "tab exists");
  assert.equal(response.windowId, tab.windowId);
  assert.notEqual(tab.windowId, 1);
  assert.notEqual(tab.groupId, -1, "tab is in the UseMac group");
  const group = sb.groups.get(tab.groupId);
  assert.equal(group.windowId, tab.windowId);
  assert.equal(group.title, "UseMac");
  assert.equal(sb.eval("state.lastTabId"), response.tabId);
  assert.equal(sb.tabs.get(1001).active, true, "the user's active tab is untouched");
});

test("open with newWindow on a restricted URL skips the debugger", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 1011, windowId: 1, url: "https://example.com/", active: true }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: STORE_URL, newWindow: true });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.restricted, true);
  assert.equal(typeof response.windowId, "number");
  assert.equal(sb.callsTo("debugger.attach").length, 0);
  // The new window holds only this tab, so it is already active there.
  assert.match(response.snapshot.agentFeedback.suggestedAction, /already the active tab of its window/);
});

test("open with newWindow and tabId is rejected", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 1021, windowId: 1, url: "https://example.com/", active: true }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: "https://example.org/", tabId: 1021, newWindow: true });
  assert.equal(response.error.code, "INVALID_ARGUMENT");
  assert.equal(sb.callsTo("windows.create").length, 0);
});

test("open still applies the URL rule", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 1031, windowId: 1, url: "https://example.com/", active: true }] });
  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: "chrome://settings", newWindow: true });
  assert.equal(response.error.code, "URL_BLOCKED");
  assert.equal(sb.callsTo("windows.create").length, 0);
});

// --- act that navigates onto a restricted page ------------------------------------------------------------------

test("act whose step lands on a restricted page reports RESTRICTED_PAGE for later steps and skips observation", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 1101, windowId: 1, url: "https://example.com/", active: true }] });
  const { response } = await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: 1101,
    stopOnError: true,
    returnObservation: true,
    steps: [
      { action: "openURL", url: NEW_STORE_URL },
      { action: "click", elementId: "@b2" }
    ]
  });

  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.restricted, true);
  const [nav, click] = response.actionResult.stepResults;
  assert.equal(nav.success, true);
  assert.equal(click.success, false);
  assert.equal(click.errorCode, "RESTRICTED_PAGE");
  assert.equal(click.mechanism, "restricted-page");
  assert.match(click.message, /Chrome does not allow extensions to script this page/);
  assert.equal(response.actionResult.success, false);
  assert.equal(response.actionResult.observation, null);
  assert.equal(response.actionResult.agentFeedback.trigger, "restricted_page");
});

test("navigating an attached, streaming tab onto a restricted page stops the stream and keeps the tab tracked", async (t) => {
  const sb = withSandbox(t, { tabs: [{ id: 1201, windowId: 1, url: "https://example.com/", active: true }] });
  const observed = await sb.request({ type: "request", id: nextId(), command: "observe", tabId: 1201 });
  assert.equal(observed.response.ok, true, JSON.stringify(observed.response.error));
  assert.ok(sb.attached.has(1201));

  const { response } = await sb.request({ type: "request", id: nextId(), command: "open", url: STORE_URL, tabId: 1201, newTab: false, stream: true });
  assert.equal(response.ok, true, JSON.stringify(response.error));
  assert.equal(response.restricted, true);
  assert.ok(sb.sent.some((f) => f.type === "stream_stopped" && f.tabId === 1201), "preview stream stopped");
  assert.equal(sb.attached.has(1201), false);
  assert.equal(sb.eval("state.lastTabId"), 1201);
  assert.equal(sb.callsTo("debugger.attach").length, 1, "no re-attach after the navigation");
});
