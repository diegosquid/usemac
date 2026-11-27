// Loads the real Extension/background.js into an isolated vm context with an in-memory `chrome` API (tabs, windows,
// tab groups, debugger, downloads), so node:test files can drive daemon requests and inspect which chrome.* calls they made.
// Unlike run-background-in-node.cjs (used by the Swift interop tests) nothing here opens a real socket: responses
// the extension sends to the daemon are captured in `sandbox.sent`.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { fakeImageApis } = require("./fake-jpeg.cjs");

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
 * @param {Array<object>} options.tabs  Initial tabs: { id, windowId, url, title?, active?, pinned?, status?,
 *   width?, height? } (width and height: the tab's size as chrome.tabs reports it).
 * @param {Array<object>} [options.windows]  Initial windows: { id, focused?, state? }. Derived from tabs when omitted.
 * @param {boolean} [options.fileAccess]  Result of chrome.extension.isAllowedFileSchemeAccess().
 * @param {(tabId:number, tab:object) => string|null} [options.attachError]  Message chrome.debugger.attach rejects with.
 * @param {(tabId:number, method:string, params:object) => any} [options.cdp]  CDP command results (default {}).
 * @param {string} [options.userAgent]
 * @param {Array<object>} [options.groups]  Initial tab groups: { id, windowId, title?, color? } (tabs join with groupId).
 * @param {object} [options.session]  Initial chrome.storage.session contents, as a restarted service worker finds them.
 * @param {Map<number, object>} [options.downloadStore]  Chrome download records, shareable across worker instances.
 * @param {(query:object, found:Array<object>) => Array<object>|Promise<Array<object>>} [options.downloadSearch]
 *   Optional override to delay a search snapshot, change its results or throw.
 * @param {number|((api:string) => number)} [options.apiDelayMs]  Real latency (ms) for tabs.get, tabs.group and the
 *   tabGroups calls, so concurrent callers interleave the way they do against Chrome. Default 0.
 */
function createBackgroundSandbox(options = {}) {
  const calls = [];
  const record = (api, ...args) => calls.push({ api, args: clone(args) });

  const tabs = new Map();
  const windows = new Map();
  const groups = new Map();
  // Saved groups outlive their window when its last tab closes. Ungrouping instead
  // removes their saved entry too (the distinction the real Chrome UI exposes).
  const savedGroups = new Map();
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
      ...(t.pendingUrl ? { pendingUrl: t.pendingUrl } : {}),
      ...(t.width != null ? { width: t.width, height: t.height } : {})
    });
  }
  for (const g of options.groups || []) {
    groups.set(g.id, { id: g.id, windowId: g.windowId ?? 1, title: g.title ?? "", color: g.color || "grey", collapsed: false });
    savedGroups.set(g.id, clone(groups.get(g.id)));
  }
  for (const w of options.windows || []) {
    windows.set(w.id, { id: w.id, focused: Boolean(w.focused), type: "normal", state: w.state || "normal" });
  }
  for (const t of tabs.values()) {
    if (!windows.has(t.windowId)) {
      windows.set(t.windowId, { id: t.windowId, focused: windows.size === 0, type: "normal", state: "normal" });
    }
  }

  const tabsUpdated = makeEvent();
  const tabsRemoved = makeEvent();
  const tabsActivated = makeEvent();
  const windowsFocusChanged = makeEvent();
  const windowsBoundsChanged = makeEvent();
  const debuggerDetached = makeEvent();
  const sessionStore = clone(options.session || {});
  const downloadStore = options.downloadStore || new Map();
  const downloadsCreated = makeEvent();
  const downloadsChanged = makeEvent();
  const downloadsErased = makeEvent();

  async function apiDelay(api) {
    const ms = typeof options.apiDelayMs === "function" ? options.apiDelayMs(api) : options.apiDelayMs || 0;
    if (ms > 0) await new Promise((resolve) => setTimeout(resolve, ms));
  }

  // Like Chrome, a group that loses its last tab is gone.
  function dropEmptyGroups(preserveSaved = false) {
    for (const id of Array.from(groups.keys())) {
      if (!Array.from(tabs.values()).some((t) => t.groupId === id)) {
        groups.delete(id);
        if (!preserveSaved) savedGroups.delete(id);
      }
    }
  }

  function getTabOrThrow(id) {
    const tab = tabs.get(id);
    if (!tab) throw new Error(`No tab with id: ${id}.`);
    return tab;
  }

  function activateInWindow(tab) {
    const wasActive = tab.active;
    for (const other of tabs.values()) {
      if (other.windowId === tab.windowId) other.active = false;
    }
    tab.active = true;
    // Like Chrome, a tab that becomes the active one of its window fires tabs.onActivated.
    if (!wasActive) tabsActivated.emit({ tabId: tab.id, windowId: tab.windowId });
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
    downloads: {
      onCreated: downloadsCreated,
      onChanged: downloadsChanged,
      onErased: downloadsErased,
      search: async (query = {}) => {
        record("downloads.search", query);
        let found = Array.from(downloadStore.values())
          .filter((item) => query.id == null || item.id === query.id)
          .filter((item) => query.state == null || item.state === query.state)
          .filter((item) => !query.startedAfter || Date.parse(item.startTime) > Date.parse(query.startedAfter));
        const order = query.orderBy?.[0];
        if (order === "startTime" || order === "-startTime") {
          const direction = order === "-startTime" ? -1 : 1;
          found.sort((a, b) => direction * (Date.parse(a.startTime) - Date.parse(b.startTime) || a.id - b.id));
        }
        if (query.limit != null) found = found.slice(0, query.limit);
        const snapshot = found.map(clone);
        return options.downloadSearch ? options.downloadSearch(clone(query), snapshot) : snapshot;
      }
    },
    extension: {
      isAllowedFileSchemeAccess: async () => options.fileAccess === true
    },
    tabs: {
      onUpdated: tabsUpdated,
      onRemoved: tabsRemoved,
      onActivated: tabsActivated,
      get: async (id) => {
        await apiDelay("tabs.get");
        return clone(getTabOrThrow(id));
      },
      getZoom: async (id) => {
        getTabOrThrow(id);
        return options.zoom ? options.zoom(id) : 1;
      },
      remove: async (id) => {
        record("tabs.remove", id);
        const tab = getTabOrThrow(id);
        const closesWindow = Array.from(tabs.values()).filter((t) => t.windowId === tab.windowId).length === 1;
        tabs.delete(id);
        dropEmptyGroups(closesWindow);
        tabsRemoved.emit(id, {});
      },
      ungroup: async (tabIds) => {
        record("tabs.ungroup", tabIds);
        await apiDelay("tabs.ungroup");
        for (const id of Array.isArray(tabIds) ? tabIds : [tabIds]) getTabOrThrow(id).groupId = -1;
        dropEmptyGroups();
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
        await apiDelay("tabs.group");
        let id = groupId;
        if (id == null) {
          id = nextGroupId++;
          const windowId = createProperties?.windowId ?? getTabOrThrow(tabIds[0]).windowId;
          groups.set(id, { id, windowId, title: "", color: "grey", collapsed: false });
          savedGroups.set(id, clone(groups.get(id)));
        } else if (!groups.has(id)) {
          throw new Error(`No group with id: ${id}.`);
        }
        // A tab grouped into a group of another window moves to that window, as in Chrome.
        for (const tabId of tabIds) {
          const tab = getTabOrThrow(tabId);
          tab.groupId = id;
          tab.windowId = groups.get(id).windowId;
        }
        dropEmptyGroups();
        return id;
      }
    },
    tabGroups: {
      TAB_GROUP_ID_NONE: -1,
      query: async (query = {}) => {
        record("tabGroups.query", query);
        await apiDelay("tabGroups.query");
        return Array.from(groups.values())
          .filter((g) => query.windowId == null || g.windowId === query.windowId)
          .filter((g) => query.title == null || g.title === query.title)
          .map(clone);
      },
      get: async (id) => {
        await apiDelay("tabGroups.get");
        if (!groups.has(id)) throw new Error(`No group with id: ${id}.`);
        return clone(groups.get(id));
      },
      update: async (id, props) => {
        record("tabGroups.update", id, props);
        await apiDelay("tabGroups.update");
        if (!groups.has(id)) throw new Error(`No group with id: ${id}.`);
        Object.assign(groups.get(id), props);
        savedGroups.set(id, clone(groups.get(id)));
        return clone(groups.get(id));
      }
    },
    windows: {
      WINDOW_ID_NONE: -1,
      onFocusChanged: windowsFocusChanged,
      onBoundsChanged: windowsBoundsChanged,
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
        record("debugger.sendCommand", tabId, method, params);
        if (!attached.has(tabId)) {
          throw new Error(`Debugger is not attached to the tab with id: ${tabId}.`);
        }
        const result = options.cdp ? await options.cdp(tabId, method, params) : undefined;
        const replace = method === "Runtime.evaluate" && /^location\.replace\((.*)\)$/.exec(params?.expression);
        if (replace && !result?.exceptionDetails) navigate(getTabOrThrow(tabId), JSON.parse(replace[1]));
        return result === undefined ? {} : result;
      }
    }
  };

  // Every timer the extension starts is tracked so dispose() can stop idle timers and capture pumps.
  const timeouts = new Set();
  const intervals = new Set();
  // Canvas sizes the extension encoded (a screenshot scaled down to fit a box, or a stitched full page), as
  // [width, height], and every drawImage call on a canvas (see fakeImageApis).
  const canvasDraws = [];
  const drawImageCalls = [];
  const context = {
    chrome,
    WebSocket: FakeWebSocket,
    console,
    URL,
    TextEncoder,
    atob,
    btoa,
    Blob,
    ...fakeImageApis(canvasDraws, drawImageCalls),
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
  context.importScripts = (...files) => {
    for (const file of files) {
      vm.runInContext(fs.readFileSync(path.join(extensionDir, file), "utf8"), context, { filename: file });
    }
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
    savedGroups,
    attached,
    canvasDraws,
    drawImageCalls,
    downloadStore,

    /** Browser-side downloads persist in the shared store, but events go only to this worker. */
    downloads: {
      create(item) {
        downloadStore.set(item.id, clone(item));
        downloadsCreated.emit(clone(item));
      },
      change(delta, extraChanges = {}) {
        const item = { ...(downloadStore.get(delta.id) || { id: delta.id }), ...clone(extraChanges) };
        for (const [name, change] of Object.entries(delta)) {
          if (name === "id") continue;
          if (Object.hasOwn(change, "current")) item[name] = change.current;
          else delete item[name];
        }
        downloadStore.set(delta.id, item);
        downloadsChanged.emit(clone(delta));
      },
      erase(id) {
        downloadStore.delete(id);
        downloadsErased.emit(id);
      }
    },

    /** Calls a top-level worker function; plain values come back as outer-realm JSON clones. */
    call(name, ...args) {
      return context[name](...args);
    },

    eval(expression) {
      return vm.runInContext(expression, context);
    },

    callsTo(api) {
      return calls.filter((c) => c.api === api);
    },

    /** chrome.* events the tests fire by hand, as Chrome would after a user action. */
    events: {
      tabsActivated,
      tabsUpdated,
      windowsFocusChanged,
      windowsBoundsChanged
    },

    /** The user clicks a tab: it becomes the active tab of its window (fires tabs.onActivated). */
    activateTab(tabId) {
      activateInWindow(getTabOrThrow(tabId));
    },

    /** Session storage as the extension last wrote it. */
    session: sessionStore,

    /** The user drags a tab out of its group (or Chrome ungroups it). */
    ungroupTab(tabId) {
      getTabOrThrow(tabId).groupId = -1;
      dropEmptyGroups();
    },

    /** The user minimizes or restores a window ("minimized" | "normal" | ...); focus leaves or returns to it. */
    setWindowState(windowId, windowState) {
      const win = windows.get(windowId);
      win.state = windowState;
      win.focused = windowState !== "minimized";
      windowsFocusChanged.emit(win.focused ? windowId : -1);
    },

    /** Marks the bridge authenticated so the extension sends responses (captured in `sent`). */
    markReady() {
      vm.runInContext(
        // The real connectWS installs the socket handlers (deliver() uses them); the fake socket never opens.
        `if (!state.ws) connectWS(true); state.ws.readyState = WebSocket.OPEN; state.authState = "ready";`,
        context
      );
    },

    get sent() {
      return vm.runInContext("state.ws ? state.ws.sentFrames : []", context);
    },

    /** Delivers a daemon -> extension frame (e.g. `cancel`, `tab_control`) through the real socket handler. */
    async deliver(message, timeoutMs = 2000) {
      const startedAt = Date.now();
      while (!vm.runInContext("typeof state.ws?.onmessage === 'function'", context)) {
        if (Date.now() - startedAt > timeoutMs) throw new Error("The extension never set up its socket handler");
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      this.markReady();
      context.__deliverText = JSON.stringify(message);
      vm.runInContext("state.ws.onmessage({ data: __deliverText })", context);
    },

    /** A CDP event from the debugger, either top-level or from a child session. */
    debuggerEvent(tabId, method, params = {}, sessionId = null) {
      chrome.debugger.onEvent.emit(sessionId ? { tabId, sessionId } : { tabId }, method, params);
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
