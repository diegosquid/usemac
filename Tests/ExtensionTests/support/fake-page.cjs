// A small fake page for the tab indicator tests: just enough DOM (elements, a closed shadow root, popovers, mutation
// observers, events) to run the indicator's page script (usemacTabIndicatorPage in Extension/tab-indicator.js) the
// way Chrome would through the debugger: Page.createIsolatedWorld, Runtime.addBinding and Runtime.callFunctionOn in
// the "usemac" world of the top document. Use it as (part of) the sandbox's `cdp` option.
"use strict";

const vm = require("node:vm");

const PILL_RECT = { left: 640, top: 10, width: 320, height: 30 };

class FakeNode {
  constructor(doc) {
    this.ownerDocument = doc;
    this.parentNode = null;
    this.childNodes = [];
    this.observers = [];
    this.listeners = new Map();
    this.captureListeners = new Map();
  }

  addEventListener(type, fn, capture = false) {
    const listeners = capture ? this.captureListeners : this.listeners;
    if (!listeners.has(type)) listeners.set(type, new Set());
    listeners.get(type).add(fn);
  }

  removeEventListener(type, fn, capture = false) {
    const listeners = capture ? this.captureListeners : this.listeners;
    listeners.get(type)?.delete(fn);
  }

  get isConnected() {
    let node = this;
    while (node) {
      if (node instanceof FakeDocument) return true;
      node = node.parentNode || node.hostElement || null;
    }
    return false;
  }

  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    this.childNodes.push(child);
    child.parentNode = this;
    this.notify();
    return child;
  }

  removeChild(child) {
    const index = this.childNodes.indexOf(child);
    if (index >= 0) {
      this.childNodes.splice(index, 1);
      child.parentNode = null;
      this.notify();
    }
    return child;
  }

  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }

  notify() {
    for (const observer of this.observers) observer.queue(this);
  }

  contains(node) {
    while (node) {
      if (node === this) return true;
      node = node.parentNode;
    }
    return false;
  }

  /** Light-DOM descendants with that tag (never inside shadow roots, like the real querySelectorAll). */
  querySelectorAll(tag) {
    const out = [];
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (child.tagName && child.tagName.toLowerCase() === String(tag).toLowerCase()) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }
}

class FakeStyle {
  constructor(element) {
    this.element = element;
    this.props = {};
  }

  setProperty(name, value) {
    this.props[name] = String(value);
  }

  get cssText() {
    return this.element.getAttribute("style") || "";
  }

  set cssText(value) {
    this.element.setAttribute("style", value);
  }
}

class FakeElement extends FakeNode {
  constructor(doc, tag) {
    super(doc);
    this.tagName = String(tag).toUpperCase();
    this.attributes = new Map();
    this.style = new FakeStyle(this);
    this.text = "";
    this.shadow = null;
    this.popoverOpen = false;
    this.rect = { left: 0, top: 0, width: 0, height: 0 };
  }

  get localName() {
    return this.tagName.toLowerCase();
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  hasAttribute(name) {
    return this.attributes.has(name);
  }

  toggleAttribute(name, enabled) {
    if (enabled) this.setAttribute(name, "");
    else this.removeAttribute(name);
    return enabled;
  }

  get className() {
    return this.getAttribute("class") || "";
  }

  set className(value) {
    this.setAttribute("class", value);
  }

  get textContent() {
    return this.text + this.childNodes.map((c) => c.textContent || "").join("");
  }

  set textContent(value) {
    this.childNodes = [];
    this.text = String(value);
  }

  attachShadow({ mode }) {
    if (this.shadow) throw new Error("Shadow root cannot be created on a host which already hosts a shadow tree.");
    this.shadow = new FakeShadowRoot(this.ownerDocument, this, mode);
    return this.shadow;
  }

  /** What page scripts see: null for a closed root. */
  get shadowRoot() {
    return this.shadow && this.shadow.mode === "open" ? this.shadow : null;
  }

  showPopover() {
    if (!this.isConnected) throw new Error("Invalid on disconnected popover elements.");
    this.popoverOpen = true;
  }

  matches(selector) {
    if (selector === ":popover-open") return this.popoverOpen && this.isConnected;
    return false;
  }

  removeChild(child) {
    super.removeChild(child);
    child.popoverOpen = false;
    return child;
  }

  /** Dispatches up the shadow-including ancestor chain, like a real event (stopPropagation stops it). */
  dispatch(type, init = {}) {
    let stopped = false;
    let defaultPrevented = false;
    const path = [];
    for (let node = this; node; node = node.parentNode || node.hostElement || null) path.push(node);
    const event = {
      type,
      target: this,
      isTrusted: init.isTrusted !== false,
      detail: init.detail ?? 1,
      composedPath: () => path,
      stopPropagation() {
        stopped = true;
      },
      preventDefault() {
        defaultPrevented = true;
      }
    };
    for (const node of path.slice().reverse()) {
      if (stopped) break;
      for (const fn of node.captureListeners.get(type) || []) fn(event);
    }
    for (const node of path) {
      if (stopped) break;
      for (const fn of node.listeners?.get(type) || []) fn(event);
    }
    return { reachedPage: !stopped, defaultPrevented };
  }

  getBoundingClientRect() {
    return { ...this.rect, x: this.rect.left, y: this.rect.top };
  }

  /** Test helper: the first descendant (shadow-including) whose class list contains `name`. */
  findByClass(name) {
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (child.className && child.className.split(/\s+/).includes(name)) return child;
        const found = walk(child);
        if (found) return found;
      }
      if (node.shadow) return walk(node.shadow);
      return null;
    };
    return walk(this);
  }
}

class FakeShadowRoot extends FakeNode {
  constructor(doc, host, mode) {
    super(doc);
    this.hostElement = host;
    this.mode = mode;
  }
}

class FakeDocument extends FakeNode {
  constructor() {
    super(null);
    this.ownerDocument = this;
    this.visibilityState = "visible";
    const html = new FakeElement(this, "html");
    html.appendChild(new FakeElement(this, "body"));
    this.appendChild(html);
  }

  get documentElement() {
    return this.childNodes.find((n) => n.tagName === "HTML") || null;
  }

  get body() {
    return this.documentElement?.childNodes.find((n) => n.tagName === "BODY") || null;
  }

  createElement(tag) {
    const el = new FakeElement(this, tag);
    if (String(tag).toLowerCase() === "div") el.rect = { left: 0, top: 0, width: 1280, height: 800 };
    return el;
  }
}

class FakeMutationObserver {
  constructor(callback) {
    this.callback = callback;
    this.targets = new Set();
    this.pending = false;
  }

  observe(target) {
    if (!this.targets.has(target)) {
      this.targets.add(target);
      target.observers.push(this);
    }
  }

  disconnect() {
    for (const target of this.targets) {
      target.observers = target.observers.filter((o) => o !== this);
    }
    this.targets.clear();
  }

  queue() {
    if (this.pending) return;
    this.pending = true;
    queueMicrotask(() => {
      this.pending = false;
      if (this.targets.size > 0) this.callback([]);
    });
  }
}

/**
 * One tab's page. `navigate()` replaces the document (and its isolated world), like a new top-level document.
 * @param {object} options
 * @param {(event: object) => void} options.onBinding  Called with Runtime.bindingCalled params.
 */
class FakePage {
  constructor(tabId, { onBinding }) {
    this.tabId = tabId;
    this.onBinding = onBinding;
    this.bindings = new Set();
    this.nextContextId = tabId * 100;
    this.calls = [];
    this.timers = new Set();
    this.navigate();
  }

  dispose() {
    for (const timer of this.timers) {
      clearTimeout(timer);
    }
    this.timers.clear();
  }

  navigate() {
    this.dispose();
    this.document = new FakeDocument();
    this.world = null;
    this.frameId = `frame-${this.tabId}`;
    this.navigations = (this.navigations || 0) + 1;
  }

  /** The indicator host in the current document, if any. */
  get host() {
    return this.document.querySelectorAll("usemac-tab-indicator")[0] || null;
  }

  part(name) {
    return this.host?.findByClass(name) || null;
  }

  get shown() {
    const host = this.host;
    return Boolean(host && /display: block/.test(host.getAttribute("style") || ""));
  }

  get text() {
    return this.part("text")?.textContent || "";
  }

  ensureWorld() {
    if (!this.world) {
      const doc = this.document;
      const timers = this.timers;
      const trackedSetTimeout = (cb, ms, ...args) => {
        const id = setTimeout(() => {
          timers.delete(id);
          cb(...args);
        }, ms);
        timers.add(id);
        return id;
      };
      const trackedClearTimeout = (id) => {
        timers.delete(id);
        clearTimeout(id);
      };
      const world = {
        document: doc,
        MutationObserver: FakeMutationObserver,
        setTimeout: trackedSetTimeout,
        clearTimeout: trackedClearTimeout,
        requestAnimationFrame: (cb) => trackedSetTimeout(cb, 1),
        queueMicrotask,
        console
      };
      world.globalThis = world;
      this.world = { id: ++this.nextContextId, context: vm.createContext(world), document: doc };
      this.installBindings();
    }
    return this.world;
  }

  installBindings() {
    if (!this.world) return;
    for (const name of this.bindings) {
      const contextId = this.world.id;
      this.world.context[name] = (payload) => this.onBinding({ name, payload: String(payload), executionContextId: contextId });
    }
  }

  handle(method, params) {
    if (method === "Page.getFrameTree") return { frameTree: { frame: { id: this.frameId } } };
    if (method === "Runtime.addBinding") {
      this.bindings.add(params.name);
      this.installBindings();
      return {};
    }
    if (method === "Page.createIsolatedWorld") {
      if (params.worldName !== "usemac" || params.frameId !== this.frameId) throw new Error("Unexpected world");
      return { executionContextId: this.ensureWorld().id };
    }
    if (method === "Runtime.callFunctionOn") {
      if (!this.world || params.executionContextId !== this.world.id) {
        throw new Error("Cannot find context with specified id");
      }
      this.calls.push(params.arguments?.[0]?.value);
      const fn = vm.runInContext(`(${params.functionDeclaration})`, this.world.context);
      const value = fn(params.arguments?.[0]?.value);
      const finish = (v) => {
        const pill = this.part("pill");
        if (pill) pill.rect = { ...PILL_RECT };
        return { result: { value: v === undefined ? undefined : JSON.parse(JSON.stringify(v)) } };
      };
      // The pill's layout is only known once it is in the document; recompute the reported rect.
      const refresh = (v) => {
        if (v && v.shown) v.pill = { x: PILL_RECT.left, y: PILL_RECT.top, width: PILL_RECT.width, height: PILL_RECT.height };
        return finish(v);
      };
      return value && typeof value.then === "function" ? value.then(refresh) : refresh(value);
    }
    return undefined;
  }
}

/**
 * Pages for the sandbox: `cdp` answers the indicator's CDP calls from a FakePage per tab and passes everything else
 * to `fallback`. Call `attach(sandbox)` once the sandbox exists, so bindings can fire Runtime.bindingCalled.
 */
function createFakePages(fallback = () => undefined) {
  const pages = new Map();
  let sandbox = null;
  const pageFor = (tabId) => {
    if (!pages.has(tabId)) {
      pages.set(
        tabId,
        new FakePage(tabId, {
          onBinding: (params) => sandbox?.chrome.debugger.onEvent.emit({ tabId }, "Runtime.bindingCalled", params)
        })
      );
    }
    return pages.get(tabId);
  };
  return {
    pages,
    page: pageFor,
    attach(sb) {
      sandbox = sb;
    },
    cdp(tabId, method, params) {
      const handled = pageFor(tabId).handle(method, params);
      return handled === undefined ? fallback(tabId, method, params) : handled;
    },
    /** Clears all pending page timers so Node exits immediately after tests finish. */
    dispose() {
      for (const page of pages.values()) {
        page.dispose();
      }
    },
    /** A top-level navigation: a new document, announced like Chrome does. */
    navigate(tabId) {
      const page = pageFor(tabId);
      page.navigate();
      sandbox.chrome.debugger.onEvent.emit({ tabId }, "Runtime.executionContextsCleared", {});
      sandbox.chrome.debugger.onEvent.emit({ tabId }, "Page.frameNavigated", { frame: { id: page.frameId, url: "https://example.com/next" } });
    }
  };
}

module.exports = { createFakePages, FakeDocument, FakeMutationObserver, PILL_RECT };
