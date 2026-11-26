// A page that scrolls, for the screenshot tests: a window with a viewport, a content size and a pixel ratio, and
// elements at fixed page positions. Runtime.evaluate runs the extension's page scripts against it in a vm context,
// so the real scroll-into-view and restore code runs. Page.captureScreenshot returns a fake JPEG the size the capture
// would have and records the scroll position it saw. Use `page.cdp` as (part of) the sandbox's `cdp` option.
"use strict";

const vm = require("node:vm");
const { fakeJpeg } = require("./fake-jpeg.cjs");

const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const clone = (value) => (value == null ? value : JSON.parse(JSON.stringify(value)));

function rectOf(left, top, width, height) {
  return { left, top, width, height, right: left + width, bottom: top + height, x: left, y: top };
}

/**
 * @param {object} options
 * @param {{width:number, height:number}} [options.viewport]  window.innerWidth/innerHeight (CSS px).
 * @param {{width:number, height:number}} [options.content]  The size the window scrolls through (CSS px).
 * @param {number} [options.dpr]  window.devicePixelRatio.
 * @param {{x:number, y:number}} [options.scroll]  The window's scroll position to start with.
 * @param {Object<string, {left:number, top:number, width:number, height:number}>} [options.elements]  Elements by
 *   selector (as the extension queries them, e.g. "#chart" or '[data-usemac-id="@b3"]'), at page coordinates.
 * @param {(index:number, params:object) => boolean} [options.failCapture]  Makes the index-th agent capture (not
 *   counting preview frames) fail.
 */
function createScrollPage(options = {}) {
  const viewport = options.viewport || { width: 1280, height: 800 };
  const content = options.content || { width: viewport.width, height: viewport.height };
  const dpr = options.dpr || 1;
  const scroll = { x: options.scroll?.x || 0, y: options.scroll?.y || 0 };
  const scrolls = []; // every scroll a page script made: { x, y, via }
  const captures = []; // every Page.captureScreenshot: { params, scroll: { x, y } }
  const intoView = []; // the options of every scrollIntoView call

  const maxX = () => Math.max(0, content.width - viewport.width);
  const maxY = () => Math.max(0, content.height - viewport.height);
  function scrollWindow(x, y, via) {
    scroll.x = clamp(Number(x) || 0, 0, maxX());
    scroll.y = clamp(Number(y) || 0, 0, maxY());
    scrolls.push({ x: scroll.x, y: scroll.y, via });
  }

  const style = { overflowX: "visible", overflowY: "visible" };
  const document = { nodeType: 9, compatMode: "CSS1Compat", parentNode: null };
  const documentElement = {
    nodeType: 1,
    parentNode: document,
    clientLeft: 0,
    clientTop: 0,
    get clientWidth() {
      return viewport.width;
    },
    get clientHeight() {
      return viewport.height;
    },
    get scrollWidth() {
      return Math.max(content.width, viewport.width);
    },
    get scrollHeight() {
      return Math.max(content.height, viewport.height);
    },
    get scrollLeft() {
      return scroll.x;
    },
    get scrollTop() {
      return scroll.y;
    },
    scrollTo(opts) {
      scrollWindow(opts.left, opts.top, "documentElement.scrollTo");
    },
    getBoundingClientRect() {
      return rectOf(-scroll.x, -scroll.y, content.width, content.height);
    }
  };
  const body = {
    nodeType: 1,
    parentNode: documentElement,
    clientLeft: 0,
    clientTop: 0,
    clientWidth: content.width,
    clientHeight: content.height,
    scrollLeft: 0,
    scrollTop: 0,
    scrollTo() {},
    getBoundingClientRect() {
      return rectOf(-scroll.x, -scroll.y, content.width, content.height);
    }
  };
  Object.assign(document, { documentElement, body, scrollingElement: documentElement });

  // Where scrollIntoView puts the window for one axis, as Chrome does for a single scroller.
  function aligned(mode, start, size, view, current) {
    if (mode === "start") return start;
    if (mode === "end") return start + size - view;
    if (mode === "center") return start + size / 2 - view / 2;
    if (start >= current && start + size <= current + view) return current;
    return size > view || start < current ? start : start + size - view;
  }

  const elements = new Map();
  for (const [selector, box] of Object.entries(options.elements || {})) {
    elements.set(selector, {
      nodeType: 1,
      parentNode: body,
      scrollLeft: 0,
      scrollTop: 0,
      getBoundingClientRect() {
        return rectOf(box.left - scroll.x, box.top - scroll.y, box.width, box.height);
      },
      scrollIntoView(opts = {}) {
        intoView.push(clone(opts));
        scrollWindow(
          aligned(opts.inline || "nearest", box.left, box.width, viewport.width, scroll.x),
          aligned(opts.block || "start", box.top, box.height, viewport.height, scroll.y),
          "scrollIntoView"
        );
      }
    });
  }
  document.querySelector = (selector) => elements.get(selector) || null;
  document.querySelectorAll = (selector) => (elements.has(selector) ? [elements.get(selector)] : []);

  const context = {
    document,
    console,
    getComputedStyle: () => style,
    scrollTo(a, b) {
      if (a && typeof a === "object") scrollWindow(a.left ?? scroll.x, a.top ?? scroll.y, "window.scrollTo");
      else scrollWindow(a, b, "window.scrollTo");
    }
  };
  for (const [name, get] of Object.entries({
    scrollX: () => scroll.x,
    scrollY: () => scroll.y,
    pageXOffset: () => scroll.x,
    pageYOffset: () => scroll.y,
    innerWidth: () => viewport.width,
    innerHeight: () => viewport.height,
    devicePixelRatio: () => dpr
  })) {
    Object.defineProperty(context, name, { get, enumerable: true });
  }
  context.window = context;
  vm.createContext(context);

  function evaluate(expression) {
    try {
      const value = vm.runInContext(String(expression), context);
      return { result: { type: typeof value, value: clone(value) } };
    } catch (error) {
      return { result: { type: "object", subtype: "error" }, exceptionDetails: { text: String(error?.message || error) } };
    }
  }

  let agentCaptures = 0;
  function capture(params = {}) {
    captures.push({ params: clone(params), scroll: { x: scroll.x, y: scroll.y } });
    if (!params.optimizeForSpeed) {
      const index = agentCaptures++;
      if (options.failCapture && options.failCapture(index, params)) throw new Error("Capture failed");
    }
    const clip = params.clip;
    const width = clip ? clip.width * (clip.scale || 1) * dpr : viewport.width * dpr;
    const height = clip ? clip.height * (clip.scale || 1) * dpr : viewport.height * dpr;
    return { data: fakeJpeg(Math.round(width), Math.round(height)) };
  }

  return {
    scroll,
    scrolls,
    captures,
    intoView,
    /** The agent's captures: every capture except the preview's (those use optimizeForSpeed). */
    get shots() {
      return captures.filter((c) => !c.params.optimizeForSpeed);
    },
    cdp(tabId, method, params) {
      if (method === "Runtime.evaluate") return evaluate(params?.expression);
      if (method === "Page.captureScreenshot") return capture(params);
      return undefined;
    }
  };
}

module.exports = { createScrollPage };
