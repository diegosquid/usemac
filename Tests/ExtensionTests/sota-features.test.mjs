import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { createBackgroundSandbox } = require("./support/background-sandbox.cjs");
const { createFakePages } = require("./support/fake-page.cjs");
const { fakeJpeg, base64Size } = require("./support/fake-jpeg.cjs");

const TAB = 41;
let reqSeq = 0;
const nextId = () => `sota-${++reqSeq}`;

// Lightweight in-memory DOM host capable of running background.js's real injected page scripts
// (buildFrameIndexExpression, match, waitFor MutationObserver, assert, scrollUntil, fillForm, scanVertical, WebMCP).
function createInteractiveDomHost({ url = "https://app.example.com/dashboard", title = "Dashboard", viewport = { width: 1280, height: 800 }, scrollHeight = 2400 } = {}) {
  const listeners = new Map();
  const scroll = { x: 0, y: 0 };
  const observers = new Set();

  class MiniMutationObserver {
    constructor(cb) {
      this.cb = cb;
      this.active = false;
    }
    observe() {
      this.active = true;
      observers.add(this);
    }
    disconnect() {
      this.active = false;
      observers.delete(this);
    }
    trigger() {
      if (this.active) queueMicrotask(() => { if (this.active) this.cb([]); });
    }
  }

  function notifyMutations() {
    for (const mo of Array.from(observers)) mo.trigger();
  }

  class MiniEvent {
    constructor(type, init = {}) {
      this.type = type;
      this.bubbles = Boolean(init.bubbles);
    }
  }

  class MiniElement {
    constructor(tag, opts = {}) {
      this.tagName = String(tag).toUpperCase();
      this.nodeType = 1;
      this.attributes = new Map();
      this.children = [];
      this.parentElement = null;
      this.parentNode = null;
      this.shadowRoot = null;
      this.style = {
        display: opts.display || "block",
        visibility: opts.visibility || "visible",
        opacity: opts.opacity ?? "1",
        position: opts.position || "static",
        zIndex: opts.zIndex ?? "auto",
        overflowX: opts.overflowX || "visible",
        overflowY: opts.overflowY || "visible",
        cursor: opts.cursor || "auto"
      };
      this._rect = opts.rect || { left: 20, top: 20, width: 120, height: 32 };
      this._text = opts.text ?? "";
      this._value = opts.value ?? "";
      this.type = opts.type || (this.tagName === "INPUT" ? "text" : "");
      this.checked = Boolean(opts.checked);
      this.disabled = Boolean(opts.disabled);
      this.isContentEditable = Boolean(opts.contentEditable);
      this.validationMessage = opts.validationMessage || "";
      this.invalid = Boolean(opts.invalid);
      this.scrollTop = opts.scrollTop || 0;
      this.scrollLeft = opts.scrollLeft || 0;
      this.clientHeight = opts.clientHeight ?? this._rect.height;
      this.clientWidth = opts.clientWidth ?? this._rect.width;
      this.scrollHeight = opts.scrollHeight ?? this.clientHeight;
      this.scrollWidth = opts.scrollWidth ?? this.clientWidth;
      this.options = opts.options || [];
      this.selectedIndex = opts.selectedIndex ?? (this.options.length > 0 ? 0 : -1);
      this.events = [];
      this.clicks = 0;
      this.removedAttrs = [];
      this.onClick = opts.onClick || null;
      this.onScroll = opts.onScroll || null;
      this._connected = opts.connected !== false;
      for (const [k, v] of Object.entries(opts.attrs || {})) {
        this.attributes.set(k, String(v));
      }
      if (opts.id) this.attributes.set("id", opts.id);
      if (opts.className) this.attributes.set("class", opts.className);
      if (opts.role) this.attributes.set("role", opts.role);
      if (opts.name) this.attributes.set("name", opts.name);
      if (opts.placeholder) this.attributes.set("placeholder", opts.placeholder);
      if (opts.ariaLabel) this.attributes.set("aria-label", opts.ariaLabel);
    }

    get isConnected() {
      return this._connected;
    }
    get id() {
      return this.attributes.get("id") || "";
    }
    get className() {
      return this.attributes.get("class") || "";
    }
    get value() {
      return this._value;
    }
    set value(v) {
      this._value = String(v);
      if (this.tagName === "SELECT") {
        const idx = this.options.findIndex((o) => o.value === this._value);
        if (idx >= 0) this.selectedIndex = idx;
      }
    }
    get innerText() {
      if (this._text) return this._text;
      return this.children.map((c) => c.innerText).filter(Boolean).join("\n");
    }
    get textContent() {
      return this.innerText;
    }
    set textContent(v) {
      this._text = String(v);
      notifyMutations();
    }
    getAttribute(name) {
      return this.attributes.has(name) ? this.attributes.get(name) : null;
    }
    setAttribute(name, value) {
      this.attributes.set(name, String(value));
      if (name !== "data-usemac-id") notifyMutations();
    }
    removeAttribute(name) {
      this.removedAttrs.push(name);
      this.attributes.delete(name);
    }
    appendChild(child) {
      child.parentElement = this;
      child.parentNode = this;
      child._connected = this._connected;
      this.children.push(child);
      notifyMutations();
      return child;
    }
    insertBefore(child, ref) {
      child.parentElement = this;
      child.parentNode = this;
      child._connected = this._connected;
      const idx = this.children.indexOf(ref);
      if (idx >= 0) this.children.splice(idx, 0, child);
      else this.children.push(child);
      notifyMutations();
      return child;
    }
    remove() {
      this._connected = false;
      if (this.parentElement) {
        this.parentElement.children = this.parentElement.children.filter((c) => c !== this);
        this.parentElement = null;
      }
      notifyMutations();
    }
    attachShadow() {
      const sr = new MiniElement("#shadow-root", { connected: true });
      sr.host = this;
      this.shadowRoot = sr;
      return sr;
    }
    getBoundingClientRect() {
      const top = this.style.position === "fixed" ? this._rect.top : this._rect.top - scroll.y;
      const left = this.style.position === "fixed" ? this._rect.left : this._rect.left - scroll.x;
      return {
        left,
        top,
        width: this._rect.width,
        height: this._rect.height,
        right: left + this._rect.width,
        bottom: top + this._rect.height,
        x: left,
        y: top
      };
    }
    getClientRects() {
      return this._rect.width >= 2 && this._rect.height >= 2 ? [this.getBoundingClientRect()] : [];
    }
    scrollIntoView() {}
    focus() {
      doc.activeElement = this;
    }
    click() {
      this.clicks += 1;
      if (this.tagName === "INPUT" && (this.type === "checkbox" || this.type === "radio")) {
        this.checked = !this.checked;
      }
      if (this.getAttribute("role") === "checkbox" || this.getAttribute("role") === "switch") {
        this.setAttribute("aria-checked", this.getAttribute("aria-checked") === "true" ? "false" : "true");
      }
      if (typeof this.onClick === "function") this.onClick(this);
      notifyMutations();
    }
    dispatchEvent(ev) {
      this.events.push(ev.type);
      return true;
    }
    closest(sel) {
      let cur = this.parentElement;
      while (cur) {
        if (cur.matches(sel)) return cur;
        cur = cur.parentElement;
      }
      return null;
    }
    matches(selector) {
      return String(selector)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .some((part) => matchesSimpleSelector(this, part));
    }
    querySelectorAll(selector) {
      const out = [];
      const walk = (node) => {
        for (const ch of node.children) {
          if (ch.matches(selector)) out.push(ch);
          walk(ch);
        }
      };
      walk(this);
      return out;
    }
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    }
  }

  function matchesSimpleSelector(el, sel) {
    if (sel === "*") return true;
    // Handle descendant combinator (e.g. "[role=\"listbox\"] li" or "article p")
    const parts = sel.split(/\s+/).filter(Boolean);
    if (parts.length > 1) {
      const last = parts[parts.length - 1];
      if (!matchesCompound(el, last)) return false;
      let ancestor = el.parentElement;
      let pIdx = parts.length - 2;
      while (ancestor && pIdx >= 0) {
        if (matchesCompound(ancestor, parts[pIdx])) pIdx--;
        ancestor = ancestor.parentElement;
      }
      return pIdx < 0;
    }
    return matchesCompound(el, sel);
  }

  function matchesCompound(el, sel) {
    let rest = sel;
    if (rest === ":invalid") return Boolean(el.invalid || el.validationMessage);
    if (rest.includes(":invalid")) {
      if (!el.invalid && !el.validationMessage) return false;
      rest = rest.replace(":invalid", "");
    }
    // Extract attribute selectors [...]
    const attrRegex = /\[([^\]=*^$|~]+)(?:([*^$|~]?=)"?([^"\]]*)"?)?\]/g;
    let m;
    while ((m = attrRegex.exec(rest)) !== null) {
      const [, name, op, val] = m;
      const actual = el.getAttribute(name);
      if (!op) {
        if (actual == null) return false;
      } else if (op === "=") {
        if (actual !== val) return false;
      } else if (op === "*=") {
        if (!actual || !actual.includes(val)) return false;
      }
    }
    rest = rest.replace(attrRegex, "");
    // Extract #id and .class
    const idMatch = rest.match(/#([a-zA-Z0-9_-]+)/);
    if (idMatch) {
      if (el.id !== idMatch[1]) return false;
      rest = rest.replace(idMatch[0], "");
    }
    const clsMatches = rest.match(/\.([a-zA-Z0-9_-]+)/g) || [];
    for (const cm of clsMatches) {
      const wanted = cm.slice(1);
      if (!el.className.split(/\s+/).includes(wanted)) return false;
      rest = rest.replace(cm, "");
    }
    if (rest && rest !== "*") {
      if (el.tagName.toLowerCase() !== rest.toLowerCase()) return false;
    }
    return true;
  }

  const documentElement = new MiniElement("html", { rect: { left: 0, top: 0, width: viewport.width, height: scrollHeight } });
  const body = new MiniElement("body", { rect: { left: 0, top: 0, width: viewport.width, height: scrollHeight } });
  documentElement.appendChild(body);
  Object.defineProperty(documentElement, "scrollHeight", { get: () => scrollHeight });
  Object.defineProperty(documentElement, "scrollTop", { get: () => scroll.y, set: (v) => { scroll.y = v; } });
  Object.defineProperty(body, "scrollHeight", { get: () => scrollHeight });

  const doc = {
    title,
    documentElement,
    body,
    scrollingElement: documentElement,
    visibilityState: "visible",
    activeElement: body,
    modelContext: null,
    hasFocus: () => true,
    getElementById: (id) => documentElement.querySelector(`#${id}`),
    querySelector: (s) => documentElement.querySelector(s),
    querySelectorAll: (s) => documentElement.querySelectorAll(s),
    elementFromPoint: (x, y) => {
      const flat = [];
      const collect = (node) => {
        for (const ch of node.children) {
          flat.push(ch);
          if (ch.shadowRoot) collect(ch.shadowRoot);
          collect(ch);
        }
      };
      collect(documentElement);
      for (let i = flat.length - 1; i >= 0; i--) {
        const el = flat[i];
        if (el.style.display === "none" || el.style.visibility === "hidden") continue;
        const r = el.getBoundingClientRect();
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom && el !== body && el !== documentElement) {
          return el;
        }
      }
      return body;
    }
  };

  class HTMLInputElement {}
  class HTMLTextAreaElement {}
  class HTMLSelectElement {}

  const win = {
    document: doc,
    location: { href: url },
    navigator: { modelContext: null },
    Event: MiniEvent,
    MutationObserver: MiniMutationObserver,
    HTMLInputElement,
    HTMLTextAreaElement,
    HTMLSelectElement,
    WeakMap,
    WeakRef,
    Map,
    Set,
    Promise,
    performance,
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    requestAnimationFrame: (cb) => setTimeout(cb, 1),
    getComputedStyle: (el) => el?.style || { display: "block", visibility: "visible", opacity: "1", overflowY: "visible", overflowX: "visible" },
    scrollTo: (opts) => {
      if (typeof opts === "object" && opts) {
        if (opts.left != null) scroll.x = Math.max(0, opts.left);
        if (opts.top != null) scroll.y = Math.max(0, Math.min(scrollHeight - viewport.height, opts.top));
      }
    }
  };
  Object.defineProperty(win, "innerWidth", { get: () => viewport.width, enumerable: true });
  Object.defineProperty(win, "innerHeight", { get: () => viewport.height, enumerable: true });
  Object.defineProperty(win, "devicePixelRatio", { get: () => 2, enumerable: true });
  Object.defineProperty(win, "scrollX", { get: () => scroll.x, enumerable: true });
  Object.defineProperty(win, "scrollY", { get: () => scroll.y, enumerable: true });
  win.window = win;
  win.globalThis = win;
  vm.createContext(win);

  function cdp(tabId, method, params) {
    if (method === "Runtime.evaluate") {
      try {
        const val = vm.runInContext(String(params?.expression || ""), win);
        if (params?.awaitPromise && val && typeof val.then === "function") {
          return val.then((resolved) => ({ result: { value: resolved === undefined ? undefined : JSON.parse(JSON.stringify(resolved)) } }));
        }
        return { result: { value: val === undefined ? undefined : JSON.parse(JSON.stringify(val)) } };
      } catch (err) {
        return { exceptionDetails: { text: String(err?.message || err) } };
      }
    }
    if (method === "Input.dispatchMouseEvent") {
      if (params?.type === "mouseWheel") {
        const maxY = Math.max(0, scrollHeight - viewport.height);
        scroll.y = Math.max(0, Math.min(maxY, scroll.y + (Number(params.deltaY) || 0)));
        scroll.x = Math.max(0, scroll.x + (Number(params.deltaX) || 0));
      }
      if (params?.type === "mousePressed") {
        const hit = doc.elementFromPoint(params.x, params.y);
        if (hit && typeof hit.click === "function") hit.click();
      }
      return {};
    }
    if (method === "Input.insertText") {
      const active = doc.activeElement;
      if (active && "value" in active) active.value = (active.value || "") + String(params?.text || "");
      return {};
    }
    if (method === "Page.captureScreenshot") {
      return { data: fakeJpeg(viewport.width * 2, viewport.height * 2) };
    }
    return undefined;
  }

  return {
    win,
    doc,
    body,
    scroll,
    MiniElement,
    notifyMutations,
    setUrl(nextUrl) {
      win.location.href = nextUrl;
    },
    cdp
  };
}

// --- 1. Stable @bN Refs + Real SnapshotDiff + returnDiffOnly + observationMode + Offscreen + Filter ---

test("stable @bN refs survive DOM insertions without wiping data-usemac-id, and SnapshotDiff ignores <5px jitter", async (t) => {
  const host = createInteractiveDomHost();
  const saveBtn = new host.MiniElement("button", { id: "save", text: "Save", rect: { left: 20, top: 40, width: 100, height: 32 } });
  const nameInput = new host.MiniElement("input", { id: "name", placeholder: "Name", value: "Alice", rect: { left: 20, top: 90, width: 200, height: 32 } });
  const offscreenBtn = new host.MiniElement("button", { id: "footer-btn", text: "Load More", rect: { left: 20, top: 1800, width: 120, height: 32 } });
  host.body.appendChild(saveBtn);
  host.body.appendChild(nameInput);
  host.body.appendChild(offscreenBtn);

  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://app.example.com/dashboard", title: "Dashboard", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => host.cdp(tabId, method, params)
  });
  t.after(() => sb.dispose());

  // First observe: default includeOffscreen=false omits offscreenBtn and reports offscreenCount=1.
  const first = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB })).response;
  assert.equal(first.ok, true, JSON.stringify(first.error));
  assert.equal(first.snapshot.elements.length, 2);
  assert.equal(first.snapshot.offscreenCount, 1);
  const saveId1 = first.snapshot.elements.find((e) => e.title === "Save").id;
  const nameId1 = first.snapshot.elements.find((e) => e.title === "Name").id;
  assert.equal(saveId1, "@b1");
  assert.equal(nameId1, "@b2");

  // Sub-5px frame jitter (3px) -> diff should report NO changes!
  saveBtn._rect.left += 3;
  saveBtn._rect.top += 2;
  const jitter = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB, returnDiffOnly: true })).response;
  assert.equal(jitter.ok, true);
  assert.deepEqual(jitter.snapshot.elements, [], "returnDiffOnly empties elements array");
  assert.equal(jitter.snapshot.diff.summary, "No element changes");
  assert.deepEqual(jitter.snapshot.diff.added, []);
  assert.deepEqual(jitter.snapshot.diff.changed, []);
  assert.deepEqual(jitter.snapshot.diff.removedIds, []);

  // Insert a new button BEFORE saveBtn and edit nameInput's value: existing nodes MUST keep @b1 and @b2!
  const newBtn = new host.MiniElement("button", { id: "new-top", text: "New Action", rect: { left: 20, top: 5, width: 100, height: 24 } });
  host.body.insertBefore(newBtn, saveBtn);
  nameInput.value = "Bob";

  const second = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB, observationMode: "delta" })).response;
  assert.equal(second.ok, true);
  assert.deepEqual(second.snapshot.elements, []);
  assert.equal(second.snapshot.diff.added.length, 1);
  assert.equal(second.snapshot.diff.added[0].title, "New Action");
  assert.equal(second.snapshot.diff.added[0].id, "@b3", "new node gets next monotonic id");
  assert.equal(second.snapshot.diff.changed.length, 1);
  assert.equal(second.snapshot.diff.changed[0].id, nameId1, "unchanged DOM node kept its exact @b2 ref");
  assert.equal(second.snapshot.diff.changed[0].value, "Bob");
  assert.deepEqual(saveBtn.removedAttrs, [], "data-usemac-id is never wiped on observe");

  // includeOffscreen: true sorts in-viewport first, tags offscreen: true on offscreen elements.
  const withOff = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB, includeOffscreen: true })).response;
  assert.equal(withOff.snapshot.elements.length, 4);
  assert.equal(withOff.snapshot.elements.at(-1).title, "Load More");
  assert.equal(withOff.snapshot.elements.at(-1).offscreen, true);
  assert.equal(withOff.snapshot.elements[0].offscreen, undefined);

  // filter: { role, text } narrows returned elements cleanly.
  const filtered = (await sb.request({
    type: "request",
    id: nextId(),
    command: "observe",
    tabId: TAB,
    filter: { role: "button", text: "Save" }
  })).response;
  assert.equal(filtered.snapshot.elements.length, 1);
  assert.equal(filtered.snapshot.elements[0].id, saveId1);
});

test("browser_act observationMode 'auto' returns diff-only + tablesSummary='unchanged' on low churn, and falls back on navigation or >=40% churn", async (t) => {
  const host = createInteractiveDomHost();
  const table = new host.MiniElement("table", { rect: { left: 10, top: 200, width: 600, height: 120 } });
  const tr1 = new host.MiniElement("tr");
  tr1.appendChild(new host.MiniElement("th", { text: "Name" }));
  tr1.appendChild(new host.MiniElement("th", { text: "Score" }));
  const tr2 = new host.MiniElement("tr");
  tr2.appendChild(new host.MiniElement("td", { text: "Alpha" }));
  tr2.appendChild(new host.MiniElement("td", { text: "99" }));
  table.appendChild(tr1);
  table.appendChild(tr2);
  host.body.appendChild(table);

  const btns = [];
  for (let i = 0; i < 6; i++) {
    const b = new host.MiniElement("button", { id: `b${i}`, text: `Btn ${i}`, rect: { left: 20 + i * 90, top: 20, width: 80, height: 30 } });
    host.body.appendChild(b);
    btns.push(b);
  }

  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://app.example.com/list", title: "List", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => host.cdp(tabId, method, params)
  });
  t.after(() => sb.dispose());

  // Initial full observe establishes baseline + table hash.
  const initObs = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB })).response;
  assert.equal(initObs.snapshot.elements.length, 6);
  assert.match(initObs.snapshot.pageState.tablesMarkdown, /Alpha/);

  // Low-churn mutation (1 of 6 buttons changes = 16.7% < 40%) -> act defaults to observationMode: "auto" -> diff-only!
  btns[0].onClick = () => { btns[0]._text = "Btn 0 Clicked"; };
  const lowChurnAct = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    steps: [{ action: "click", selector: "#b0" }]
  })).response;
  assert.equal(lowChurnAct.ok, true, JSON.stringify(lowChurnAct.error));
  const obs1 = lowChurnAct.actionResult.observation;
  assert.deepEqual(obs1.elements, [], "auto mode omits unchanged elements when churn < 40%");
  assert.equal(obs1.diff.changed.length, 1);
  assert.equal(obs1.diff.changed[0].title, "Btn 0 Clicked");
  assert.equal(obs1.pageState.tablesMarkdown, null, "unchanged table omitted");
  assert.equal(obs1.pageState.tablesSummary, "unchanged");

  // High-churn mutation (4 of 6 buttons removed = 66% >= 40%) -> auto mode falls back to full interactive snapshot!
  btns[1].onClick = () => {
    btns[2].remove();
    btns[3].remove();
    btns[4].remove();
    btns[5].remove();
  };
  const highChurnAct = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    steps: [{ action: "click", selector: "#b1" }]
  })).response;
  const obs2 = highChurnAct.actionResult.observation;
  assert.equal(obs2.elements.length, 2, "auto mode falls back to full elements when churn >= 40%");
  assert.equal(obs2.diff.removedIds.length, 4);

  // observationMode: "none" skips observe completely
  const noneAct = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    observationMode: "none",
    steps: [{ action: "wait", durationMs: 1 }]
  })).response;
  assert.equal(noneAct.actionResult.observation, null);
});

// --- 2. Resilient browser_act Steps: match, waitFor (MutationObserver), optional, assert, scrollUntil, fillForm ---

test("resilient steps: match (Shadow DOM), optional, assert, waitFor MutationObserver, scrollUntil, and fillForm with combobox + validation", async (t) => {
  const host = createInteractiveDomHost({ url: "https://app.example.com/checkout", title: "Checkout", scrollHeight: 2600 });

  // Shadow DOM button resolved by semantic match
  const shadowHost = new host.MiniElement("div", { rect: { left: 10, top: 10, width: 200, height: 50 } });
  const sr = shadowHost.attachShadow();
  const shadowBtn = new host.MiniElement("button", { text: "Confirm Order", rect: { left: 30, top: 20, width: 140, height: 32 } });
  let shadowClicked = false;
  shadowBtn.onClick = () => { shadowClicked = true; };
  sr.appendChild(shadowBtn);
  host.body.appendChild(shadowHost);

  // Form fields: text input, select, checkbox, custom combobox, and submit button with validation alert
  const emailInput = new host.MiniElement("input", { id: "email", placeholder: "Email", rect: { left: 20, top: 80, width: 200, height: 30 } });
  const planSelect = new host.MiniElement("select", {
    id: "plan",
    ariaLabel: "Plan",
    rect: { left: 20, top: 120, width: 200, height: 30 },
    options: [
      { value: "free", text: "Free", selected: true },
      { value: "pro", text: "Pro Plan", selected: false }
    ]
  });
  const agreeBox = new host.MiniElement("input", { id: "agree", type: "checkbox", ariaLabel: "Accept Terms", rect: { left: 20, top: 160, width: 20, height: 20 } });
  const combo = new host.MiniElement("div", { id: "country", role: "combobox", ariaLabel: "Country", rect: { left: 20, top: 200, width: 200, height: 30 } });
  let selectedCountry = null;
  combo.onClick = () => {
    setTimeout(() => {
      const opt1 = new host.MiniElement("div", { role: "option", text: "Canada", rect: { left: 20, top: 235, width: 200, height: 24 } });
      const opt2 = new host.MiniElement("div", { role: "option", text: "Brazil", rect: { left: 20, top: 260, width: 200, height: 24 } });
      opt2.onClick = () => { selectedCountry = "Brazil"; };
      host.body.appendChild(opt1);
      host.body.appendChild(opt2);
    }, 10);
  };
  const submitBtn = new host.MiniElement("button", { id: "submit", text: "Submit Form", rect: { left: 20, top: 300, width: 120, height: 32 } });
  let submitted = false;
  submitBtn.onClick = () => {
    submitted = true;
    emailInput.invalid = true;
    emailInput.validationMessage = "Invalid email domain";
    const alertEl = new host.MiniElement("div", { role: "alert", text: "Please check your email", rect: { left: 20, top: 340, width: 250, height: 24 } });
    host.body.appendChild(alertEl);
  };

  // Far below-the-fold target for scrollUntil
  const deepTarget = new host.MiniElement("button", { id: "deep-cta", text: "Download Invoice", rect: { left: 40, top: 1700, width: 160, height: 36 } });

  for (const el of [emailInput, planSelect, agreeBox, combo, submitBtn, deepTarget]) {
    host.body.appendChild(el);
  }

  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://app.example.com/checkout", title: "Checkout", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => host.cdp(tabId, method, params)
  });
  t.after(() => sb.dispose());

  // 1) optional missing click + Shadow DOM match click + assert
  const batch1 = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [
      { action: "click", match: { role: "button", title: "Nonexistent Banner" }, optional: true },
      { action: "click", match: { role: "button", title: "Confirm Order" } },
      { action: "assert", expectUrl: "/checkout", expectTitle: "Checkout", expectText: "Confirm Order", expectNotText: "Fatal Crash" }
    ]
  })).response;
  assert.equal(batch1.ok, true, JSON.stringify(batch1));
  assert.equal(batch1.actionResult.success, true);
  assert.equal(batch1.actionResult.stepResults[0].success, true);
  assert.equal(batch1.actionResult.stepResults[0].skipped, true);
  assert.equal(shadowClicked, true, "Shadow DOM button clicked via live match");
  assert.ok(batch1.actionResult.stepResults[1].resolvedElementId, "resolvedElementId reported");
  assert.equal(batch1.actionResult.stepResults[2].mechanism, "cdp-assert");

  // 2) Failing assert returns clear ASSERTION_FAILED
  const badAssert = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{ action: "assert", expectText: "Does Not Exist" }]
  })).response;
  assert.equal(badAssert.actionResult.success, false);
  assert.equal(badAssert.actionResult.stepResults[0].errorCode, "ASSERTION_FAILED");
  assert.match(badAssert.actionResult.stepResults[0].message, /Expected text "Does Not Exist" not found/);

  // 3) waitFor powered by MutationObserver Promise wakes fast (<100ms, well below legacy 150ms polling!)
  setTimeout(() => {
    const toast = new host.MiniElement("div", { id: "saved-toast", text: "Order Confirmed!", rect: { left: 20, top: 400, width: 200, height: 30 } });
    host.body.appendChild(toast);
  }, 15);
  const waitStart = performance.now();
  const waitRes = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{ action: "waitFor", selector: "#saved-toast", timeoutMs: 2000 }]
  })).response;
  const waitElapsed = performance.now() - waitStart;
  assert.equal(waitRes.actionResult.success, true, JSON.stringify(waitRes.actionResult));
  assert.equal(waitRes.actionResult.stepResults[0].mechanism, "mutation-observer");
  assert.ok(waitElapsed < 140, `MutationObserver wake took ${waitElapsed}ms (should be far faster than 150ms poll)`);

  // waitFor gone: true
  setTimeout(() => {
    host.doc.getElementById("saved-toast")?.remove();
  }, 15);
  const goneRes = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{ action: "waitFor", selector: "#saved-toast", gone: true, timeoutMs: 2000 }]
  })).response;
  assert.equal(goneRes.actionResult.success, true);

  // 4) fillForm with input, select, checkbox, combobox, submitMatch, and automatic validation/alert surfacing
  const formRes = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{
      action: "fillForm",
      fields: [
        { label: "Email", value: "ada@example.com" },
        { label: "Plan", value: "Pro Plan" },
        { label: "Accept Terms", checked: true },
        { label: "Country", value: "Brazil" }
      ],
      submitMatch: { role: "button", title: "Submit Form" }
    }]
  })).response;
  assert.equal(formRes.actionResult.success, true, JSON.stringify(formRes.actionResult));
  assert.equal(emailInput.value, "ada@example.com");
  assert.equal(planSelect.value, "pro");
  assert.equal(agreeBox.checked, true);
  assert.equal(selectedCountry, "Brazil", "custom combobox opened and selected [role=option]");
  assert.equal(submitted, true);
  assert.match(formRes.actionResult.stepResults[0].blockedWarning, /Invalid email domain/);
  assert.match(formRes.actionResult.stepResults[0].blockedWarning, /Please check your email/);

  // 5) scrollUntil scrolls down until deep-cta enters viewport
  const scrollRes = (await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{ action: "scrollUntil", match: { role: "button", title: "Download Invoice" }, maxScrolls: 6, deltaY: 500 }]
  })).response;
  assert.equal(scrollRes.actionResult.success, true, JSON.stringify(scrollRes.actionResult));
  assert.equal(scrollRes.actionResult.stepResults[0].mechanism, "cdp-scroll-until");
  assert.ok(host.scroll.y >= 1000, `scrolled down to reveal deep button (scrollY=${host.scroll.y})`);
});

// --- 3. browser_open with autoDismissOverlays & steps ---

test("browser_open auto-dismisses high-confidence cookie overlays and executes inline steps", async (t) => {
  const host = createInteractiveDomHost({ url: "https://shop.example.com/", title: "Shop" });

  // Cookie consent banner with high-confidence Accept All button
  const banner = new host.MiniElement("div", {
    id: "cookie-consent-banner",
    className: "cookie-banner",
    role: "dialog",
    position: "fixed",
    zIndex: "9999",
    text: "We use cookies to improve your experience.",
    rect: { left: 100, top: 500, width: 600, height: 140 }
  });
  let cookieAccepted = false;
  const acceptBtn = new host.MiniElement("button", {
    id: "accept-cookies",
    text: "Accept All",
    rect: { left: 500, top: 580, width: 120, height: 36 },
    onClick: () => {
      cookieAccepted = true;
      banner.remove();
    }
  });
  banner.appendChild(acceptBtn);
  host.body.appendChild(banner);

  const searchInput = new host.MiniElement("input", { id: "q", placeholder: "Search products", rect: { left: 40, top: 60, width: 240, height: 32 } });
  host.body.appendChild(searchInput);

  const sb = createBackgroundSandbox({
    tabs: [{ id: 1, windowId: 1, url: "https://example.com/", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => host.cdp(tabId, method, params)
  });
  t.after(() => sb.dispose());

  const openRes = (await sb.request({
    type: "request",
    id: nextId(),
    command: "open",
    url: "https://shop.example.com/",
    autoDismissOverlays: true,
    steps: [
      { action: "setValue", selector: "#q", text: "mechanical keyboard" },
      { action: "assert", expectTitle: "Shop", expectNotText: "We use cookies" }
    ]
  })).response;

  assert.equal(openRes.ok, true, JSON.stringify(openRes.error));
  assert.equal(cookieAccepted, true, "cookie overlay was auto-dismissed");
  assert.equal(searchInput.value, "mechanical keyboard");
  assert.ok(openRes.actionResult, "inline steps returned actionResult");
  assert.equal(openRes.actionResult.success, true);
  assert.equal(openRes.actionResult.stepResults.length, 2);
  assert.ok(openRes.snapshot, "final observation snapshot returned");
  assert.equal(openRes.snapshot.pageState.blockingOverlay, null, "overlay gone in final snapshot");
});

// --- 4. CDP Network Ring-Buffer + browser_extract(mode: "network") + actionResult.networkErrors + scanVertical + eval frameIndex + WebMCP ---

test("CDP Network ring buffer captures last 25 JSON XHR/Fetch responses, serves mode:'network', and attaches 4xx/5xx to browser_act", async (t) => {
  const bodies = new Map();
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://app.example.com/", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => {
      if (method === "Network.getResponseBody") {
        return { body: bodies.get(params.requestId) || "{}", base64Encoded: false };
      }
      return undefined;
    }
  });
  t.after(() => sb.dispose());

  await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB });
  // Confirm Network.enable was sent on attach
  assert.ok(
    sb.callsTo("debugger.sendCommand").some((c) => c.args[0] === TAB && c.args[1] === "Network.enable"),
    "Network.enable attached passively"
  );

  // Feed 30 JSON Fetch responses (ring buffer must keep only the latest 25)
  for (let i = 1; i <= 30; i++) {
    const requestId = `req-${i}`;
    const url = i % 2 === 0 ? `https://api.example.com/v1/orders/${i}` : `https://api.example.com/v1/users/${i}`;
    bodies.set(requestId, JSON.stringify({ id: i, ok: true }));
    sb.debuggerEvent(TAB, "Network.requestWillBeSent", { requestId, type: "Fetch", request: { url, method: "GET" } });
    sb.debuggerEvent(TAB, "Network.responseReceived", {
      requestId,
      type: "Fetch",
      response: { url, status: 200, mimeType: "application/json", headers: { "content-type": "application/json; charset=utf-8" } }
    });
    sb.debuggerEvent(TAB, "Network.loadingFinished", { requestId });
  }

  const ringLen = sb.eval(`state.tabSessions.get(${TAB}).networkRing.length`);
  assert.equal(ringLen, 25, "ring buffer capped at 25 entries");

  // Extract filtered network responses
  const netExtract = (await sb.request({
    type: "request",
    id: nextId(),
    command: "extract",
    tabId: TAB,
    mode: "network",
    urlFilter: "/orders/",
    maxChars: 8000
  })).response;
  assert.equal(netExtract.ok, true, JSON.stringify(netExtract.error));
  const parsed = JSON.parse(netExtract.extractResult.jsonResult);
  assert.ok(parsed.length > 0 && parsed.every((r) => r.url.includes("/orders/")));
  assert.equal(parsed[0].body.id, 30, "newest matching response comes first with lazily fetched parsed JSON body");

  // Trigger a 500 error during a browser_act batch -> attached automatically to actionResult.networkErrors
  const actPromise = sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{ action: "wait", durationMs: 40 }]
  });
  setTimeout(() => {
    sb.debuggerEvent(TAB, "Network.requestWillBeSent", {
      requestId: "err-500",
      type: "XHR",
      request: { url: "https://api.example.com/v1/checkout", method: "POST" }
    });
    sb.debuggerEvent(TAB, "Network.responseReceived", {
      requestId: "err-500",
      type: "XHR",
      response: { url: "https://api.example.com/v1/checkout", status: 500, statusText: "Internal Server Error", mimeType: "application/json" }
    });
  }, 10);
  const actRes = (await actPromise).response;
  assert.ok(Array.isArray(actRes.actionResult.networkErrors), "networkErrors attached");
  assert.match(actRes.actionResult.networkErrors[0], /POST https:\/\/api\.example\.com\/v1\/checkout -> 500 Internal Server Error/);
});

test("scanVertical merges vertically virtualized table rows, eval uses compact JSON + frameIndex, and WebMCP tools are discovered", async (t) => {
  const host = createInteractiveDomHost({ scrollHeight: 1600 });
  host.win.navigator.modelContext = {
    getTools: () => [{ name: "search_catalog" }, { name: "add_to_cart" }]
  };

  // Virtualized scrollable grid container that swaps visible rows based on scrollTop
  const grid = new host.MiniElement("div", {
    id: "vgrid",
    role: "grid",
    overflowY: "auto",
    rect: { left: 0, top: 0, width: 600, height: 200 },
    clientHeight: 200,
    scrollHeight: 600
  });
  const headerRow = new host.MiniElement("div", { role: "row", attrs: { "aria-rowindex": "1" }, rect: { left: 0, top: 0, width: 600, height: 30 } });
  headerRow.appendChild(new host.MiniElement("div", { role: "columnheader", text: "Item", rect: { left: 0, top: 0, width: 300, height: 30 } }));
  headerRow.appendChild(new host.MiniElement("div", { role: "columnheader", text: "Price", rect: { left: 300, top: 0, width: 300, height: 30 } }));

  const rowData = [
    ["2", "Item A", "$10"],
    ["3", "Item B", "$20"],
    ["4", "Item C", "$30"],
    ["5", "Item D", "$40"]
  ];
  function syncVirtualRows() {
    grid.children = [headerRow];
    const startIdx = grid.scrollTop >= 180 ? 2 : 0;
    for (let i = startIdx; i < startIdx + 2; i++) {
      const [ariaIdx, item, price] = rowData[i];
      const r = new host.MiniElement("div", { role: "row", attrs: { "aria-rowindex": ariaIdx }, rect: { left: 0, top: 30 + (i - startIdx) * 30, width: 600, height: 30 } });
      r.appendChild(new host.MiniElement("div", { role: "gridcell", text: item, rect: { left: 0, top: 30, width: 300, height: 30 } }));
      r.appendChild(new host.MiniElement("div", { role: "gridcell", text: price, rect: { left: 300, top: 30, width: 300, height: 30 } }));
      grid.children.push(r);
    }
  }
  let rawScrollTop = 0;
  Object.defineProperty(grid, "scrollTop", {
    get: () => rawScrollTop,
    set: (v) => {
      rawScrollTop = v;
      syncVirtualRows();
    }
  });
  syncVirtualRows();
  host.body.appendChild(grid);

  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://app.example.com/grid", title: "Grid", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => host.cdp(tabId, method, params)
  });
  t.after(() => sb.dispose());

  // WebMCP discovery on observe
  const obs = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB })).response;
  assert.deepEqual(obs.snapshot.pageState.webMcpTools, ["search_catalog", "add_to_cart"]);

  // scanVertical extracts all 4 virtualized rows and restores scrollTop to 0
  const vScan = (await sb.request({
    type: "request",
    id: nextId(),
    command: "extract",
    tabId: TAB,
    mode: "tables",
    scanVertical: true
  })).response;
  assert.equal(vScan.ok, true, JSON.stringify(vScan.error));
  assert.equal(vScan.extractResult.rowCount, 4);
  assert.match(vScan.extractResult.tablesMarkdown, /Item A/);
  assert.match(vScan.extractResult.tablesMarkdown, /Item D/);
  assert.equal(rawScrollTop, 0, "scrollTop restored after vertical scan");

  // eval uses compact JSON (no 2-space pretty indentation)
  const evalCompact = (await sb.request({
    type: "request",
    id: nextId(),
    command: "extract",
    tabId: TAB,
    mode: "eval",
    expression: "({ a: 1, b: [2, 3] })"
  })).response;
  assert.equal(evalCompact.extractResult.jsonResult, '{"a":1,"b":[2,3]}');

  // eval with out-of-range frameIndex reports clear INVALID_ARGUMENT
  const badFrame = (await sb.request({
    type: "request",
    id: nextId(),
    command: "extract",
    tabId: TAB,
    mode: "eval",
    expression: "1",
    frameIndex: 2
  })).response;
  assert.equal(badFrame.ok, false);
  assert.equal(badFrame.error.code, "INVALID_ARGUMENT");
});

// --- 5. Overhead Crushing: Fast Attach, 1-hop moveCursor, tab-indicator bootstrap cache, tab_url push events, VLM screenshot cap ---

test("cold attach is parallel with zero sleeps/clearDeviceMetricsOverride, moveCursor sends 1 mouseMoved, and tab_url events push over WS", async (t) => {
  const mouseMoves = [];
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://example.com/start", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => {
      if (method === "Input.dispatchMouseEvent" && params?.type === "mouseMoved") {
        mouseMoves.push([params.x, params.y]);
      }
      if (method === "Page.captureScreenshot") {
        return { data: fakeJpeg(3000, 2000) };
      }
      return undefined;
    }
  });
  t.after(() => sb.dispose());

  const start = performance.now();
  const obs = (await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB, returnImageContent: true })).response;
  const elapsed = performance.now() - start;
  assert.equal(obs.ok, true);
  assert.ok(elapsed < 80, `parallel cold attach + observe completed in ${elapsed.toFixed(1)}ms (no 60ms/35ms sleeps)`);

  const cdpMethods = sb.callsTo("debugger.sendCommand").map((c) => c.args[1]);
  assert.ok(cdpMethods.includes("Network.enable"));
  assert.ok(!cdpMethods.includes("Emulation.clearDeviceMetricsOverride"));
  // returnImageContent defaults to VLM-optimal 1280x800 cap (3000x2000 -> 1200x800)
  assert.deepEqual(base64Size(obs.screenshotBase64), { width: 1200, height: 800 });

  // moveCursorSmoothly sends 1 WS cursor event and 1 CDP mouseMoved (not 3!)
  await sb.request({
    type: "request",
    id: nextId(),
    command: "act",
    tabId: TAB,
    returnObservation: false,
    steps: [{ action: "click", x: 320, y: 240 }]
  });
  assert.deepEqual(mouseMoves, [[320, 240]], "single CDP mouseMoved instead of 3-step animated loop");

  // tab_url push events on tabs.onUpdated and tabs.onRemoved
  sb.events.tabsUpdated.emit(TAB, { url: "https://example.com/next", status: "complete" }, { id: TAB, windowId: 1, url: "https://example.com/next", title: "Next", active: true });
  await sb.chrome.tabs.remove(TAB);
  const tabUrlFrames = sb.sent.filter((f) => f.type === "tab_url" && f.tabId === TAB);
  assert.ok(tabUrlFrames.some((f) => f.url === "https://example.com/next" && !f.removed));
  assert.ok(tabUrlFrames.some((f) => f.removed === true));
});

test("tab-indicator.js caches the 9.5KB bootstrap once per contextId and sends tiny fast calls afterwards", async (t) => {
  const fnSizes = [];
  const pages = createFakePages((tabId, method, params) => {
    if (method === "Page.captureScreenshot") return { data: fakeJpeg(1280, 800) };
    return undefined;
  });
  const sb = createBackgroundSandbox({
    tabs: [{ id: TAB, windowId: 1, url: "https://example.com/app", active: true }],
    windows: [{ id: 1, focused: true }],
    cdp: (tabId, method, params) => {
      if (method === "Runtime.callFunctionOn" && typeof params?.functionDeclaration === "string") {
        fnSizes.push(params.functionDeclaration.length);
      }
      return pages.cdp(tabId, method, params);
    }
  });
  pages.attach(sb);
  sb.eval("TAB_INDICATOR_TIMING.leaseMs = 1000");
  t.after(async () => {
    await sb.call("stopStreamingAndDetach", TAB, false).catch(() => {});
    sb.dispose();
  });

  await sb.request({ type: "request", id: nextId(), command: "observe", tabId: TAB });
  // Wait for initial indicator render
  const deadline = Date.now() + 1000;
  while (!pages.page(TAB).shown && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 5));
  }
  assert.equal(pages.page(TAB).shown, true);

  // Trigger multiple subsequent indicator updates (step label + screenshot capture hide/show)
  sb.call("emitCursor", TAB, 100, 100, "click", "Clicking Save");
  await sb.request({ type: "request", id: nextId(), command: "screenshot", tabId: TAB });
  await new Promise((r) => setTimeout(r, 40));

  assert.ok(fnSizes.length >= 3, `expected >=3 indicator calls, got ${fnSizes.length}`);
  assert.ok(fnSizes[0] > 4000, `first call bootstraps full source (${fnSizes[0]} bytes)`);
  for (let i = 1; i < fnSizes.length; i++) {
    assert.ok(fnSizes[i] < 250, `subsequent call #${i} should use tiny fast dispatcher (got ${fnSizes[i]} bytes)`);
  }
});
