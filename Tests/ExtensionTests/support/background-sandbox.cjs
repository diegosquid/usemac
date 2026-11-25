// Loads the real Extension/background.js into an isolated vm context with an in-memory `chrome` API (tabs, windows,
// tab groups, debugger), so node:test files can drive daemon requests and inspect which chrome.* calls they made.
// Unlike run-background-in-node.cjs (used by the Swift interop tests) nothing here opens a real socket: responses
// the extension sends to the daemon are captured in `sandbox.sent`.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const extensionDir = path.resolve(__dirname, "..", "..", "..", "Extension");
const CHROME_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

function makeEvent() {
  const listeners = new Set();
  return {
    addListener: (fn) => listeners.add(fn),
    removeListener: (fn) => listeners.delete(fn),
    hasListener: (fn) => listeners.has(fn),
    emit: (...args) => {
      for (const fn of Array.from(listeners)) fn(...args);
    }
  };
}

function clone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;

  constructor(url) {
    this.url = url;
    this.readyState = FakeWebSocket.CONNECTING;
    this.sentFrames = [];
  }

  send(text) {
    this.sentFrames.push(JSON.parse(text));
  }

  close() {
    this.readyState = FakeWebSocket.CLOSED;
  }
}

/**
 * @param {object} options
 * @param {Array<object>} options.tabs  Initial tabs: { id, windowId, url, title?, active?, pinned?, status? }.
 * @param {Array<object>} [options.windows]  Initial windows: { id, focused? }. Derived from tabs when omitted.
 * @param {boolean} [options.fileAccess]  Result of chrome.extension.isAllowedFileSchemeAccess().
 * @param {(tabId:number, tab:object) => string|null} [options.attachError]  Message chrome.debugger.attach rejects with.
 * @param {(tabId:number, method:string, params:object) => any} [options.cdp]  CDP command results (default {}).
 * @param {string} [options.userAgent]
 */
function createBackgroundSandbox(options = {}) {
  const calls = [];
  const record = (api, ...args) => calls.push({ api, args: clone(args) });

  const tabs = new Map();
  const windows = new Map();
  const groups = new Map();
  const attached = new Set();
  let nextTabId = 900;
  let nextWindowId = 90;
  let nextGroupId = 700;

  const titleFor = (url) => `Title of ${url}`;

  for (const t of options.tabs || []) {
    tabs.set(t.id, {
      id: t.id,
      windowId: t.windowId ?? 1,
      index: t.index ?? 0,
      url: t.url,
      title: t.title ?? titleFor(t.url),
      active: Boolean(t.active),
      pinned: Boolean(t.pinned),
      status: t.status || "complete",
      groupId: t.groupId ?? -1,
      ...(t.pendingUrl ? { pendingUrl: t.pendingUrl } : {})
    });
  }
  for (const w of options.windows || []) {
    windows.set(w.id, { id: w.id, focused: Boolean(w.focused), type: "normal", state: "normal" });
  }
  for (const t of tabs.values()) {
    if (!windows.has(t.windowId)) {
      windows.set(t.windowId, { id: t.windowId, focused: windows.size === 0, type: "normal", state: "normal" });
    }
  }

  const tabsUpdated = makeEvent();
  const tabsRemoved = makeEvent();
  const debuggerDetached = makeEvent();
  const sessionStore = {};

  function getTabOrThrow(id) {
    const tab = tabs.get(id);
    if (!tab) throw new Error(`No tab with id: ${id}.`);
    return tab;
  }

  function activateInWindow(tab) {
    for (const other of tabs.values()) {
      if (other.windowId === tab.windowId) other.active = false;
    }
    tab.active = true;
  }

  function navigate(tab, url) {
    tab.url = url;
    tab.title = titleFor(url);
    tab.status = "complete";
    delete tab.pendingUrl;
    // Chrome force-detaches the debugger when an attached tab commits a page extensions may not script.
    if (attached.has(tab.id) && sandbox.call("restrictedPageReason", url, { fileAccess: options.fileAccess === true })) {
      attached.delete(tab.id);
      debuggerDetached.emit({ tabId: tab.id }, "target_closed");
    }
  }

  function createTab({ windowId, url, active }) {
    const tab = {
      id: nextTabId++,
      windowId,
      index: Array.from(tabs.values()).filter((t) => t.windowId === windowId).length,
      url,
      title: titleFor(url),
      active: false,
      pinned: false,
      status: "complete",
      groupId: -1
    };
    tabs.set(tab.id, tab);
    if (active) activateInWindow(tab);
    return tab;
  }

  const chrome = {
    runtime: {
      getManifest: () => ({ version: "0.5.0" }),
      onMessage: makeEvent(),
      onInstalled: makeEvent(),
      onStartup: makeEvent()
    },
    storage: {
      local: {
        get: async () => ({}),
        set: async () => {},
        remove: async () => {}
      },
      session: {
        get: async (key) => (key in sessionStore ? { [key]: clone(sessionStore[key]) } : {}),
        set: async (items) => {
          Object.assign(sessionStore, clone(items));
        }
      }
    },
    alarms: { create: () => {}, onAlarm: makeEvent() },
    downloads: { onCreated: makeEvent(), onChanged: makeEvent(), search: async () => [] },
    extension: {
      isAllowedFileSchemeAccess: async () => options.fileAccess === true
    },
    tabs: {
      onUpdated: tabsUpdated,
      onRemoved: tabsRemoved,
      get: async (id) => clone(getTabOrThrow(id)),
      remove: async (id) => {
        record("tabs.remove", id);
        getTabOrThrow(id);
        tabs.delete(id);
        tabsRemoved.emit(id, {});
      },
      query: async (query = {}) => {
        return Array.from(tabs.values())
          .filter((t) => query.groupId == null || t.groupId === query.groupId)
          .filter((t) => query.windowId == null || t.windowId === query.windowId)
          .map(clone);
      },
      create: async (props) => {
        record("tabs.create", props);
        return clone(createTab(props));
      },
      update: async (id, props) => {
        record("tabs.update", id, props);
        const tab = getTabOrThrow(id);
        if (props.url != null) navigate(tab, props.url);
        if (props.active) activateInWindow(tab);
        return clone(tab);
      },
      group: async ({ groupId, tabIds, createProperties }) => {
        record("tabs.group", { groupId, tabIds, createProperties });
        let id = groupId;
        if (id == null) {
          id = nextGroupId++;
          groups.set(id, { id, windowId: createProperties?.windowId, title: "" });
        }
        for (const tabId of tabIds) getTabOrThrow(tabId).groupId = id;
        return id;
      }
    },
    tabGroups: {
      TAB_GROUP_ID_NONE: -1,
      query: async (query = {}) => {
        return Array.from(groups.values())
          .filter((g) => query.windowId == null || g.windowId === query.windowId)
          .filter((g) => query.title == null || g.title === query.title)
          .map(clone);
      },
      update: async (id, props) => {
        record("tabGroups.update", id, props);
        Object.assign(groups.get(id), props);
        return clone(groups.get(id));
      }
    },
    windows: {
      getAll: async () => Array.from(windows.values()).map(clone),
      getLastFocused: async () => clone(Array.from(windows.values()).find((w) => w.focused) || Array.from(windows.values())[0]),
      get: async (id) => clone(windows.get(id)),
      create: async (props) => {
        record("windows.create", props);
        const win = { id: nextWindowId++, focused: Boolean(props.focused), type: props.type || "normal", state: "normal" };
        windows.set(win.id, win);
        const tab = createTab({ windowId: win.id, url: props.url, active: true });
        return { ...clone(win), tabs: [clone(tab)] };
      },
      update: async (id, props) => {
        record("windows.update", id, props);
        Object.assign(windows.get(id), props);
        return clone(windows.get(id));
      }
    },
    debugger: {
      onEvent: makeEvent(),
      onDetach: debuggerDetached,
      attach: async ({ tabId }, version) => {
        record("debugger.attach", tabId, version);
        const tab = getTabOrThrow(tabId);
        const error = options.attachError ? options.attachError(tabId, clone(tab)) : null;
        if (error) throw new Error(error);
        attached.add(tabId);
      },
      detach: async ({ tabId }) => {
        record("debugger.detach", tabId);
        attached.delete(tabId);
      },
      sendCommand: async ({ tabId }, method, params) => {
        record("debugger.sendCommand", tabId, method);
        if (!attached.has(tabId)) {
          throw new Error(`Debugger is not attached to the tab with id: ${tabId}.`);
        }
        const result = options.cdp ? options.cdp(tabId, method, params) : undefined;
        return result === undefined ? {} : result;
      }
    }
  };

  // Every timer the extension starts is tracked so dispose() can stop idle timers and capture pumps.
  const timeouts = new Set();
  const intervals = new Set();
  const context = {
    chrome,
    WebSocket: FakeWebSocket,
    console,
    URL,
    TextEncoder,
    crypto: globalThis.crypto,
    performance,
    navigator: { userAgent: options.userAgent || CHROME_UA },
    setTimeout: (fn, ms, ...args) => {
      const handle = setTimeout(() => {
        timeouts.delete(handle);
        fn(...args);
      }, ms);
      timeouts.add(handle);
      return handle;
    },
    clearTimeout: (handle) => {
      timeouts.delete(handle);
      clearTimeout(handle);
    },
    setInterval: (fn, ms, ...args) => {
      const handle = setInterval(fn, ms, ...args);
      intervals.add(handle);
      return handle;
    },
    clearInterval: (handle) => {
      intervals.delete(handle);
      clearInterval(handle);
    }
  };
  context.self = context;
  vm.createContext(context);
  context.importScripts = (file) => {
    vm.runInContext(fs.readFileSync(path.join(extensionDir, file), "utf8"), context, { filename: file });
  };
  vm.runInContext(fs.readFileSync(path.join(extensionDir, "background.js"), "utf8"), context, {
    filename: "background.js"
  });

  const sandbox = {
    calls,
    chrome,
    tabs,
    windows,
    groups,
    attached,

    /** Calls a top-level function of background.js; plain values come back as outer-realm JSON clones. */
    call(name, ...args) {
      return context[name](...args);
    },

    eval(expression) {
      return vm.runInContext(expression, context);
    },

    callsTo(api) {
      return calls.filter((c) => c.api === api);
    },

    /** Marks the bridge authenticated so the extension sends responses (captured in `sent`). */
    markReady() {
      vm.runInContext(
        `state.ws = state.ws || new WebSocket("ws://test"); state.ws.readyState = WebSocket.OPEN; state.authState = "ready";`,
        context
      );
    },

    get sent() {
      return vm.runInContext("state.ws ? state.ws.sentFrames : []", context);
    },

    /** Sends a daemon request through the real dispatcher and resolves with the extension's response frame. */
    async request(req, timeoutMs = 4000) {
      this.markReady();
      const startedAt = Date.now();
      context.dispatchDaemonRequest(req);
      while (Date.now() - startedAt < timeoutMs) {
        const response = this.sent.find((f) => f.type === "response" && f.id === req.id);
        if (response) {
          return { response: clone(response), elapsedMs: Date.now() - startedAt };
        }
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      throw new Error(`No response to ${req.command} (${req.id}) within ${timeoutMs} ms`);
    },

    dispose() {
      for (const handle of timeouts) clearTimeout(handle);
      for (const handle of intervals) clearInterval(handle);
      timeouts.clear();
      intervals.clear();
    }
  };
  return sandbox;
}

module.exports = { createBackgroundSandbox, CHROME_UA };
