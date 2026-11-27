// The tab indicator: a blue border and a pill ("UseMac is controlling this tab", the current step, Stop) on a tab
// an agent is controlling, while the user can see that tab. Loaded by background.js with importScripts; the
// functions below use its globals (state, sendWS, isTabVisibleToUser) when they run, never at load time.
//
// - It is drawn through the debugger connection UseMac already has, in the "usemac" isolated world, so it needs no
//   new permission. One host element with a closed shadow root, in the top layer when the page supports popovers.
//   Only the pill takes pointer events. The page script below puts the host back if the page removes it.
// - The page script holds a lease: without a renewal from the extension (debugger gone, extension restarted) it
//   hides itself, through a CSS animation even if its JavaScript is gone.
// - Stop and Resume accept only trusted pointer clicks. They share an isolated-world binding with user input.
// - The agent never sees it: observe's DOM walk cannot enter a closed shadow root and the host is outside <body>,
//   agent screenshots hide it while they capture, frames that show it are flagged so the app's vision does not
//   reuse them, and the pill stops taking pointer events while the agent's own pointer passes over it.

const TAB_INDICATOR_WORLD = "usemac";
const TAB_INDICATOR_BINDING = "__usemacTabIndicatorStop";
// Timings (the tests shorten some of them).
const TAB_INDICATOR_TIMING = {
  leaseMs: 12000, // the page hides the indicator unless the extension renews it within this time
  heartbeatMs: 4000, // renewal interval while an indicator is on screen
  stepLingerMs: 2500, // a step label stays this long after the agent's last step
  stoppedLingerMs: 4000, // how long "Stopped" stays before the indicator goes away
  pointerGraceMs: 1000, // the pill ignores pointers this long after the agent's pointer was over it
  agentInputGraceMs: 80, // CDP input can arrive as trusted DOM events even after the command returns
  cdpTimeoutMs: 1500
};
const TAB_INDICATOR_POINTER_MARGIN = 8;
const TAB_INDICATOR_POINTER_METHODS = new Set([
  "Input.dispatchMouseEvent",
  "Input.dispatchDragEvent",
  "Input.dispatchTouchEvent"
]);
const tabIndicatorKeyboardMethods = new Set([
  "Input.dispatchKeyEvent",
  "Input.insertText",
  "DOM.setFileInputFiles" // Chromium dispatches trusted input/change for this DOM command too
]);

let tabIndicatorHeartbeat = null;

// --- Page script ----------------------------------------------------------------------------------------------------
// Runs in the "usemac" isolated world of the top document through Runtime.callFunctionOn. It must stay
// self-contained: it is sent as source text. Returns { mounted, shown, pill: {x, y, width, height} | null }.
function usemacTabIndicatorPage(cmd) {
  const KEY = "__usemacTabIndicator";
  const VERSION = 3;
  let ctl = globalThis[KEY];
  if (!ctl || ctl.version !== VERSION) {
    if (ctl && typeof ctl.destroy === "function") {
      try {
        ctl.destroy();
      } catch (_) {}
    }
    ctl = createController();
    globalThis[KEY] = ctl;
  }
  return ctl.apply(cmd || {});

  function createController() {
    const doc = document;
    const BLUE = "#1a73e8"; // Chrome's "blue" tab group color, the UseMac group (USEMAC_GROUP_COLOR)
    const HOST_CSS =
      "all: initial !important; position: fixed !important; inset: 0 !important; width: auto !important;" +
      " height: auto !important; margin: 0 !important; padding: 0 !important; border: 0 !important;" +
      " background: transparent !important; overflow: visible !important; z-index: 2147483647 !important;" +
      " pointer-events: none !important; contain: layout style !important; color-scheme: normal !important;";
    const CSS = `
      .frame { position: fixed; inset: 0; pointer-events: none; visibility: visible;
        animation-duration: var(--lease, 12000ms); animation-timing-function: linear; animation-fill-mode: forwards; }
      .frame[data-lease="a"] { animation-name: usemac-lease-a; }
      .frame[data-lease="b"] { animation-name: usemac-lease-b; }
      @keyframes usemac-lease-a { from { visibility: visible; } to { visibility: hidden; } }
      @keyframes usemac-lease-b { from { visibility: visible; } to { visibility: hidden; } }
      .edge { position: absolute; background: ${BLUE}; box-shadow: 0 0 14px 4px rgba(26, 115, 232, 0.42); }
      .edge.top { top: 0; left: 0; right: 0; height: 3px; }
      .edge.bottom { bottom: 0; left: 0; right: 0; height: 3px; }
      .edge.left { top: 0; bottom: 0; left: 0; width: 3px; }
      .edge.right { top: 0; bottom: 0; right: 0; width: 3px; }
      .frame.active .edge { animation: usemac-glow 1400ms ease-in-out 2; }
      @keyframes usemac-glow { 50% { box-shadow: 0 0 22px 8px rgba(26, 115, 232, 0.6); } }
      .pill { position: absolute; top: 10px; left: 50%; transform: translateX(-50%); box-sizing: border-box;
        display: flex; align-items: center; gap: 8px; height: 30px; max-width: calc(100vw - 32px);
        padding: 0 4px 0 12px; border-radius: 15px; background: ${BLUE}; color: #fff;
        font: 500 12.5px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        letter-spacing: 0; white-space: nowrap; box-shadow: 0 2px 10px rgba(0, 0, 0, 0.22);
        pointer-events: auto; user-select: none; -webkit-user-select: none; cursor: default; }
      .dot { flex: none; width: 7px; height: 7px; border-radius: 50%; background: #fff; }
      .text { overflow: hidden; text-overflow: ellipsis; }
      .stop, .resume { all: unset; flex: none; box-sizing: border-box; height: 22px; padding: 0 10px; border-radius: 11px;
        background: #fff; color: #174ea6; cursor: pointer;
        font: 600 12px/22px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
      .stop:hover { background: #e8f0fe; }
      .stop[hidden], .resume[hidden] { display: none; }
      .frame.user_paused .edge { background: #d97706; box-shadow: 0 0 14px 4px rgba(217, 119, 6, 0.35); }
      .frame.user_paused .pill { background: #b45309; }
      .resume { color: #92400e; }
      .resume:hover { background: #fef3c7; }
      .frame.stopped .edge { background: #80868b; box-shadow: none; }
      .frame.stopped .pill { background: #3c4043; padding-right: 12px; }
      .frame.stopped .dot { background: #f28b82; }
      .frame.inert .pill { pointer-events: none; }
      @media (prefers-reduced-motion: reduce) { .frame.active .edge { animation: none; } }
    `;

    let host = null;
    let frameEl = null;
    let pillEl = null;
    let textEl = null;
    let stopEl = null;
    let resumeEl = null;
    let observer = null;
    let leaseTimer = null;
    let leaseFlip = false;
    let wanted = false;
    let shown = false;
    let captureHidden = false;
    let inert = false;
    let mode = "active";
    let step = "";
    let token = "";
    let binding = "";
    const userInputEvents = ["pointerdown", "mousedown", "keydown", "input"];
    const inputDocuments = new Set();
    const readds = [];

    function build() {
      host = doc.createElement("usemac-tab-indicator");
      host.setAttribute("aria-hidden", "true");
      if (typeof host.showPopover === "function") host.setAttribute("popover", "manual");
      const shadow = host.attachShadow({ mode: "closed" });
      const style = doc.createElement("style");
      style.textContent = CSS;
      frameEl = doc.createElement("div");
      for (const side of ["top", "right", "bottom", "left"]) {
        const edge = doc.createElement("div");
        edge.className = "edge " + side;
        frameEl.appendChild(edge);
      }
      pillEl = doc.createElement("div");
      pillEl.className = "pill";
      const dot = doc.createElement("span");
      dot.className = "dot";
      textEl = doc.createElement("span");
      textEl.className = "text";
      stopEl = doc.createElement("button");
      stopEl.className = "stop";
      stopEl.setAttribute("type", "button");
      stopEl.setAttribute("tabindex", "-1");
      stopEl.textContent = "Stop";
      resumeEl = doc.createElement("button");
      resumeEl.className = "resume";
      resumeEl.setAttribute("type", "button");
      resumeEl.setAttribute("tabindex", "-1");
      resumeEl.textContent = "Resume";
      pillEl.appendChild(dot);
      pillEl.appendChild(textEl);
      pillEl.appendChild(resumeEl);
      pillEl.appendChild(stopEl);
      frameEl.appendChild(pillEl);
      shadow.appendChild(style);
      shadow.appendChild(frameEl);
      for (const type of ["pointerdown", "pointerup", "mousedown", "mouseup", "click", "dblclick", "auxclick", "contextmenu"]) {
        pillEl.addEventListener(type, onPillEvent);
      }
    }

    // Clicks on the pill never reach the page, and pressing it does not move the page's focus.
    function onPillEvent(event) {
      event.stopPropagation();
      if (event.type === "mousedown" || event.type === "contextmenu") event.preventDefault();
      if (event.type !== "click") return;
      event.preventDefault();
      // A real pointer click only: not a script (isTrusted), not a keyboard or accessibility press (detail 0).
      if (!event.isTrusted || !(event.detail >= 1)) return;
      if (inert || captureHidden || !shown) return;
      if (event.target === stopEl && (mode === "active" || mode === "user_paused")) {
        reportAction("stop");
      } else if (event.target === resumeEl && mode === "user_paused") {
        reportAction("resume");
      }
    }

    function onUserInput(event) {
      if (!event.isTrusted || !shown || mode !== "active" || captureHidden || doc.visibilityState === "hidden") return;
      if (event.target === host || pillEl.contains(event.target) || event.composedPath?.().includes(host)) return;
      reportAction("user_input", event.type);
    }

    function onFrameLoad(event) {
      if (event.target?.localName === "iframe") syncInputDocuments();
    }

    function syncInputDocuments() {
      const current = new Set([doc]);
      for (const inputDoc of current) {
        for (const iframe of inputDoc.querySelectorAll("iframe")) {
          try {
            const child = iframe.contentDocument;
            if (child) current.add(child);
          } catch (_) {}
        }
        if (inputDocuments.has(inputDoc)) continue;
        for (const type of userInputEvents) inputDoc.addEventListener(type, onUserInput, true);
        inputDoc.addEventListener("load", onFrameLoad, true);
        inputDocuments.add(inputDoc);
      }
      for (const inputDoc of inputDocuments) {
        if (!current.has(inputDoc)) unwatchInputDocument(inputDoc);
      }
    }

    function unwatchInputDocument(inputDoc) {
      for (const type of userInputEvents) inputDoc.removeEventListener(type, onUserInput, true);
      inputDoc.removeEventListener("load", onFrameLoad, true);
      inputDocuments.delete(inputDoc);
    }

    function reportAction(action, eventType) {
      const report = globalThis[binding];
      if (typeof report === "function") {
        try {
          report(JSON.stringify({ token, action, eventType }));
        } catch (_) {}
      }
    }

    function mount() {
      if (!host) build();
      const parent = doc.documentElement;
      if (parent && !host.isConnected) {
        // Hosts left by an older world (another controller) would stack up: keep only this one.
        for (const stale of Array.from(doc.querySelectorAll("usemac-tab-indicator"))) {
          if (stale !== host) stale.remove();
        }
        parent.appendChild(host);
      }
      watch();
      syncInputDocuments();
    }

    // Put the host back when the page removes it (or replaces <html>), but do not fight a page that keeps doing it.
    function watch() {
      if (observer || typeof MutationObserver !== "function") return;
      observer = new MutationObserver(() => {
        if (!wanted || !host || host.isConnected) return;
        const now = Date.now();
        while (readds.length && now - readds[0] > 10000) readds.shift();
        if (readds.length >= 20) {
          unmount();
          return;
        }
        readds.push(now);
        mount();
        paint();
        if (doc.documentElement && observer) {
          observer.observe(doc.documentElement, { childList: true });
        }
      });
      observer.observe(doc, { childList: true });
      if (doc.documentElement) observer.observe(doc.documentElement, { childList: true });
    }

    // Writes only what changed: the host's style attribute is visible to the page's mutation observers.
    function paint() {
      if (!host) return;
      const visible = shown && !captureHidden;
      const hostCss = HOST_CSS + (visible ? " display: block !important;" : " display: none !important;");
      if (host.getAttribute("style") !== hostCss) host.setAttribute("style", hostCss);
      if (visible && host.isConnected && typeof host.showPopover === "function") {
        try {
          if (!host.matches(":popover-open")) host.showPopover();
        } catch (_) {}
      }
      const frameClass = "frame " + mode + (inert ? " inert" : "");
      if (frameEl.className !== frameClass) frameEl.className = frameClass;
      let text = step ? "UseMac is controlling this tab · " + step : "UseMac is controlling this tab";
      if (mode === "stopped") text = "Stopped";
      if (mode === "user_paused") text = "You're using this tab, agent paused";
      if (textEl.textContent !== text) textEl.textContent = text;
      stopEl.toggleAttribute("hidden", mode === "stopped");
      resumeEl.toggleAttribute("hidden", mode !== "user_paused");
    }

    // Restarting the CSS lease animation means switching between two identical keyframes (no reflow needed).
    function lease(ms) {
      const leaseMs = Math.max(1000, Number(ms) || 12000);
      if (leaseTimer) clearTimeout(leaseTimer);
      leaseTimer = setTimeout(unmount, leaseMs + 250);
      leaseFlip = !leaseFlip;
      frameEl.style.setProperty("--lease", leaseMs + "ms");
      frameEl.setAttribute("data-lease", leaseFlip ? "a" : "b");
    }

    function unmount() {
      wanted = false;
      shown = false;
      if (leaseTimer) clearTimeout(leaseTimer);
      leaseTimer = null;
      if (observer) observer.disconnect();
      observer = null;
      for (const inputDoc of inputDocuments) unwatchInputDocument(inputDoc);
      if (host) host.remove();
    }

    // Two frames, so the capture that follows paints without the indicator. A hidden page paints nothing anyway.
    function settle() {
      if (doc.visibilityState !== "visible" || typeof requestAnimationFrame !== "function") return Promise.resolve();
      return new Promise((resolve) => {
        let done = false;
        const finish = () => {
          if (!done) {
            done = true;
            resolve();
          }
        };
        requestAnimationFrame(() => requestAnimationFrame(finish));
        setTimeout(finish, 120);
      });
    }

    function report() {
      const mounted = Boolean(host && host.isConnected);
      const visible = mounted && shown && !captureHidden;
      let pill = null;
      if (visible) {
        const r = pillEl.getBoundingClientRect();
        pill = { x: r.left, y: r.top, width: r.width, height: r.height };
      }
      return { mounted, shown: visible, pill };
    }

    function apply(command) {
      switch (command.op) {
        case "render":
          token = String(command.token || "");
          binding = String(command.binding || "");
          mode = command.mode === "stopped" || command.mode === "user_paused" ? command.mode : "active";
          step = String(command.step || "").slice(0, 80);
          shown = Boolean(command.show);
          wanted = true;
          mount();
          paint();
          if (shown) lease(command.lease);
          else if (leaseTimer) {
            clearTimeout(leaseTimer);
            leaseTimer = null;
          }
          break;
        case "capture":
          captureHidden = Boolean(command.hidden);
          paint();
          if (captureHidden) return settle().then(report);
          break;
        case "inert":
          inert = Boolean(command.inert);
          if (host) paint();
          break;
        case "remove":
          unmount();
          break;
        default:
          break;
      }
      return report();
    }

    return { version: VERSION, apply, destroy: unmount };
  }
}

const TAB_INDICATOR_PAGE_SOURCE = usemacTabIndicatorPage.toString();
// Tiny dispatcher used once TAB_INDICATOR_PAGE_SOURCE has bootstrapped __usemacTabIndicator in a contextId.
const TAB_INDICATOR_FAST_CALL_SOURCE =
  "function(cmd){const c=globalThis.__usemacTabIndicator;return c&&c.version===3?c.apply(cmd||{}):{__usemacUnbootstrapped:true};}";

// --- Extension side -------------------------------------------------------------------------------------------------

function tabIndicatorState(session) {
  if (!session.tabIndicator) {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    session.tabIndicator = {
      controlled: false, // an agent command used this tab since its control last ended
      stopped: false, // the kill switch or Pause stopped the agent: "Stopped" for a few seconds
      userPaused: false,
      userPausedWaiters: [],
      agentPointerDepth: 0,
      suppressPointerUntil: 0,
      agentKeyboardDepth: 0,
      suppressKeyboardUntil: 0,
      step: null,
      stepTimer: null,
      stoppedTimer: null,
      inert: false,
      inertTimer: null,
      mainFrameId: null,
      contextId: null, // the "usemac" isolated world of the current top document
      bootstrappedContextId: null, // contextId where TAB_INDICATOR_PAGE_SOURCE was already evaluated
      bindingAdded: false,
      mounted: false,
      everMounted: false,
      shown: false,
      pill: null,
      token: Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join(""),
      renderQueued: false,
      renderChain: Promise.resolve()
    };
  }
  return session.tabIndicator;
}

function beginTabIndicatorAgentInput(tabId, kind = "all") {
  const ind = state.tabSessions.get(tabId)?.tabIndicator;
  if (!ind) return null;
  if (kind !== "keyboard") ind.agentPointerDepth += 1;
  if (kind !== "pointer") ind.agentKeyboardDepth += 1;
  return ind;
}

function endTabIndicatorAgentInput(tabId, kind = "all", ind = state.tabSessions.get(tabId)?.tabIndicator) {
  if (!ind || state.tabSessions.get(tabId)?.tabIndicator !== ind) return;
  const until = Date.now() + TAB_INDICATOR_TIMING.agentInputGraceMs;
  if (kind !== "keyboard") {
    ind.agentPointerDepth -= 1;
    ind.suppressPointerUntil = until;
  }
  if (kind !== "pointer") {
    ind.agentKeyboardDepth -= 1;
    ind.suppressKeyboardUntil = until;
  }
}

function clearTabIndicatorUserPause(ind, cancelled = false) {
  ind.userPaused = false;
  for (const finish of ind.userPausedWaiters.splice(0)) finish(cancelled);
}

function clearAllTabIndicatorUserPauses(cancelled = false) {
  for (const [tabId, { tabIndicator: ind }] of state.tabSessions) {
    if (!ind || (!ind.userPaused && ind.userPausedWaiters.length === 0)) continue;
    clearTabIndicatorUserPause(ind, cancelled);
    scheduleTabIndicatorRender(tabId);
  }
}

function cancelTabIndicatorUserPause(tabId, ind) {
  if (!ind?.userPaused) return;
  // The running step may not have reached the pause gate yet. Cancel its token as well as any current waiters.
  state.tabCancelGeneration.set(tabId, getTabCancelGen(tabId) + 1);
  clearTabIndicatorUserPause(ind, true);
}

function resumeTabIndicatorUserPause(tabId) {
  const ind = state.tabSessions.get(tabId)?.tabIndicator;
  if (!ind?.userPaused) return;
  clearTabIndicatorUserPause(ind);
  scheduleTabIndicatorRender(tabId);
}

async function waitIfTabUserPaused(tabId, cancelToken) {
  const ind = state.tabSessions.get(tabId)?.tabIndicator;
  while (ind?.userPaused && !isCancelled(tabId, cancelToken)) {
    let finish;
    let cancelTimer;
    try {
      const stopped = await new Promise((resolve) => {
        finish = resolve;
        ind.userPausedWaiters.push(finish);
        if (cancelToken) {
          cancelTimer = setInterval(() => {
            if (isCancelled(tabId, cancelToken)) finish(true);
          }, CANCEL_POLL_SLICE_MS);
        }
      });
      if (stopped) throw CANCELLED_ERROR;
    } finally {
      clearInterval(cancelTimer);
      const index = ind.userPausedWaiters.indexOf(finish);
      if (index !== -1) ind.userPausedWaiters.splice(index, 1);
    }
  }
  if (isCancelled(tabId, cancelToken)) throw CANCELLED_ERROR;
}

function clearTabIndicatorTimers(ind) {
  for (const key of ["stepTimer", "stoppedTimer", "inertTimer"]) {
    if (ind[key]) clearTimeout(ind[key]);
    ind[key] = null;
  }
}

// Called for every agent command on a tab (resetIdleTimer): the tab is controlled until the task ends. A "Stopped"
// pill keeps its few seconds even if a batch that was already running goes on under Pause.
function markTabControlled(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached) return;
  const ind = tabIndicatorState(session);
  if (ind.controlled || ind.stopped) return;
  ind.controlled = true;
  scheduleTabIndicatorRender(tabId);
}

// The label of the step the agent is running ("Clicking Save"), from the cursor events (emitCursor).
function noteTabIndicatorStep(tabId, label) {
  if (!label) return;
  const ind = state.tabSessions.get(tabId)?.tabIndicator;
  if (!ind?.controlled || ind.stopped) return;
  const step = String(label).replace(/\s+/g, " ").trim().slice(0, 60);
  if (!step) return;
  if (ind.stepTimer) clearTimeout(ind.stepTimer);
  ind.stepTimer = setTimeout(() => {
    ind.stepTimer = null;
    if (ind.step) {
      ind.step = null;
      scheduleTabIndicatorRender(tabId);
    }
  }, TAB_INDICATOR_TIMING.stepLingerMs);
  if (ind.step === step) return;
  ind.step = step;
  scheduleTabIndicatorRender(tabId);
}

// Daemon -> extension `tab_control` (docs/BRIDGE-PROTOCOL.md): "stopped" when the kill switch or Pause stops the
// agent, "ended" when a task completes (keepTabIds: tabs other running tasks still own).
function handleTabControlMessage(msg) {
  if (msg?.state === "stopped") {
    for (const [tabId, session] of state.tabSessions) {
      const ind = session.tabIndicator;
      if (!ind?.controlled) continue;
      ind.stopped = true;
      cancelTabIndicatorUserPause(tabId, ind);
      ind.step = null;
      if (ind.stoppedTimer) clearTimeout(ind.stoppedTimer);
      ind.stoppedTimer = setTimeout(() => {
        ind.stoppedTimer = null;
        if (!ind.stopped) return;
        ind.stopped = false;
        ind.controlled = false;
        scheduleTabIndicatorRender(tabId);
      }, TAB_INDICATOR_TIMING.stoppedLingerMs);
      scheduleTabIndicatorRender(tabId);
    }
    return;
  }
  if (msg?.state === "ended") {
    const keep = new Set((Array.isArray(msg.keepTabIds) ? msg.keepTabIds : []).map(Number));
    for (const [tabId, session] of state.tabSessions) {
      const ind = session.tabIndicator;
      if (!ind || keep.has(tabId) || (!ind.controlled && !ind.stopped)) continue;
      ind.controlled = false;
      ind.stopped = false;
      cancelTabIndicatorUserPause(tabId, ind);
      ind.step = null;
      clearTabIndicatorTimers(ind);
      scheduleTabIndicatorRender(tabId);
    }
  }
}

// Renders run one at a time per tab, and events that arrive meanwhile collapse into one more render.
function scheduleTabIndicatorRender(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached) return;
  const ind = tabIndicatorState(session);
  if (ind.renderQueued) return;
  ind.renderQueued = true;
  ind.renderChain = ind.renderChain
    .then(async () => {
      ind.renderQueued = false;
      await renderTabIndicatorNow(tabId, session);
    })
    .catch(() => {});
}

function refreshTabIndicators() {
  for (const [tabId, session] of state.tabSessions) {
    const ind = session.tabIndicator;
    if (session.attached && ind && (ind.controlled || ind.stopped || ind.mounted)) {
      scheduleTabIndicatorRender(tabId);
    }
  }
}

async function renderTabIndicatorNow(tabId, session) {
  const current = () => state.tabSessions.get(tabId) === session && session.attached;
  if (!current()) return;
  const ind = tabIndicatorState(session);
  const wanted = ind.controlled || ind.stopped;
  const visible = wanted ? await isTabVisibleToUser(tabId) : false;
  if (!current()) return;
  if (!wanted) {
    if (ind.mounted) await callTabIndicatorPage(tabId, session, { op: "remove" }, { create: false });
    ind.mounted = false;
    ind.shown = false;
    ind.pill = null;
  } else if (!visible && !ind.mounted) {
    // Never drawn into a page the user has not looked at while it was controlled.
    ind.shown = false;
    ind.pill = null;
  } else {
    const result = await callTabIndicatorPage(tabId, session, {
      op: "render",
      show: visible,
      mode: ind.stopped ? "stopped" : ind.userPaused ? "user_paused" : "active",
      step: ind.stopped ? "" : ind.step || "",
      lease: ind.stopped ? TAB_INDICATOR_TIMING.stoppedLingerMs : TAB_INDICATOR_TIMING.leaseMs,
      binding: TAB_INDICATOR_BINDING,
      token: ind.token
    });
    applyTabIndicatorReport(ind, result);
  }
  updateTabIndicatorHeartbeat();
}

function applyTabIndicatorReport(ind, result) {
  if (!result) {
    ind.shown = false;
    ind.pill = null;
    return;
  }
  ind.mounted = Boolean(result.mounted);
  if (ind.mounted) ind.everMounted = true;
  ind.shown = Boolean(result.shown);
  ind.pill = result.pill || null;
}

// While an indicator is on screen, renew its lease (and re-check that the user still sees it).
function updateTabIndicatorHeartbeat() {
  let any = false;
  for (const session of state.tabSessions.values()) {
    if (session.attached && session.tabIndicator?.shown && !session.tabIndicator.stopped) {
      any = true;
      break;
    }
  }
  if (any && !tabIndicatorHeartbeat) {
    tabIndicatorHeartbeat = setInterval(() => {
      for (const [tabId, session] of state.tabSessions) {
        if (session.attached && session.tabIndicator?.shown && !session.tabIndicator.stopped) {
          scheduleTabIndicatorRender(tabId);
        }
      }
      updateTabIndicatorHeartbeat();
    }, TAB_INDICATOR_TIMING.heartbeatMs);
  } else if (!any && tabIndicatorHeartbeat) {
    clearInterval(tabIndicatorHeartbeat);
    tabIndicatorHeartbeat = null;
  }
}

// CDP for the indicator bypasses sendCDP (and its pointer hook), and never waits long on a stuck page.
async function tabIndicatorCDP(tabId, method, params) {
  let timer = null;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("Tab indicator CDP timeout")), TAB_INDICATOR_TIMING.cdpTimeoutMs);
  });
  try {
    return await Promise.race([chrome.debugger.sendCommand({ tabId }, method, params), timeout]);
  } finally {
    clearTimeout(timer);
  }
}

async function ensureTabIndicatorContext(tabId, ind) {
  if (!ind.bindingAdded) {
    // Exposed only in contexts named "usemac": the page's own scripts cannot call it.
    await tabIndicatorCDP(tabId, "Runtime.addBinding", {
      name: TAB_INDICATOR_BINDING,
      executionContextName: TAB_INDICATOR_WORLD
    });
    ind.bindingAdded = true;
  }
  if (ind.contextId != null) return ind.contextId;
  if (!ind.mainFrameId) {
    const tree = await tabIndicatorCDP(tabId, "Page.getFrameTree", {});
    ind.mainFrameId = tree?.frameTree?.frame?.id || null;
  }
  if (!ind.mainFrameId) return null;
  const world = await tabIndicatorCDP(tabId, "Page.createIsolatedWorld", {
    frameId: ind.mainFrameId,
    worldName: TAB_INDICATOR_WORLD,
    grantUniveralAccess: false
  });
  ind.contextId = world?.executionContextId ?? null;
  ind.bootstrappedContextId = null;
  return ind.contextId;
}

async function callTabIndicatorPage(tabId, session, cmd, { create = true } = {}) {
  const ind = tabIndicatorState(session);
  for (let attempt = 0; attempt < 2; attempt++) {
    let contextId = null;
    try {
      contextId = create ? await ensureTabIndicatorContext(tabId, ind) : ind.contextId;
    } catch (_) {
      return null;
    }
    if (contextId == null) return null;
    try {
      const useFastCall = ind.bootstrappedContextId === contextId;
      let res = await tabIndicatorCDP(tabId, "Runtime.callFunctionOn", {
        functionDeclaration: useFastCall ? TAB_INDICATOR_FAST_CALL_SOURCE : TAB_INDICATOR_PAGE_SOURCE,
        executionContextId: contextId,
        arguments: [{ value: cmd }],
        returnByValue: true,
        awaitPromise: true,
        silent: true
      });
      if (res?.exceptionDetails) return null;
      let val = res?.result?.value ?? null;
      if (useFastCall && val && val.__usemacUnbootstrapped === true) {
        ind.bootstrappedContextId = null;
        res = await tabIndicatorCDP(tabId, "Runtime.callFunctionOn", {
          functionDeclaration: TAB_INDICATOR_PAGE_SOURCE,
          executionContextId: contextId,
          arguments: [{ value: cmd }],
          returnByValue: true,
          awaitPromise: true,
          silent: true
        });
        if (res?.exceptionDetails) return null;
        val = res?.result?.value ?? null;
      }
      if (!res?.exceptionDetails) {
        ind.bootstrappedContextId = contextId;
      }
      return val;
    } catch (err) {
      if (/timeout/i.test(String(err?.message || ""))) return null;
      // The document changed under us (a navigation): make a new world, once.
      if (ind.contextId === contextId) {
        ind.contextId = null;
        ind.bootstrappedContextId = null;
      }
      if (!create) return null;
    }
  }
  return null;
}

// stopStreamingAndDetach runs this before the debugger goes away: there is no way to reach the page after that.
// A "Stopped" pill is painted and left for its linger (its lease hides and removes it); anything else is removed.
async function tabIndicatorBeforeDetach(tabId, session) {
  const ind = session?.tabIndicator;
  if (!ind) return;
  try {
    await ind.renderChain;
  } catch (_) {}
  clearTabIndicatorTimers(ind);
  if (ind.stopped && ind.controlled) {
    const visible = await isTabVisibleToUser(tabId);
    if (visible || ind.mounted) {
      await callTabIndicatorPage(tabId, session, {
        op: "render",
        show: visible,
        mode: "stopped",
        step: "",
        lease: TAB_INDICATOR_TIMING.stoppedLingerMs,
        binding: TAB_INDICATOR_BINDING,
        token: ind.token
      });
    }
  } else if (ind.mounted) {
    await callTabIndicatorPage(tabId, session, { op: "remove" }, { create: false });
  }
  ind.controlled = false;
  ind.stopped = false;
  ind.mounted = false;
  ind.shown = false;
  ind.pill = null;
  clearTabIndicatorUserPause(ind, true);
  updateTabIndicatorHeartbeat();
}

// Agent screenshots (observe, act and screenshot captures) never show the indicator. The capture waits until the
// page has painted without it.
async function withTabIndicatorHidden(tabId, capture) {
  const session = state.tabSessions.get(tabId);
  const ind = session?.tabIndicator;
  if (!ind?.mounted && !ind?.shown) return capture();
  await callTabIndicatorPage(tabId, session, { op: "capture", hidden: true }, { create: false });
  try {
    return await capture();
  } finally {
    callTabIndicatorPage(tabId, session, { op: "capture", hidden: false }, { create: false })
      .then((result) => {
        if (result) applyTabIndicatorReport(ind, result);
      })
      .catch(() => {});
  }
}

// sendCDP calls this before the agent's own pointer events. One that lands on (or near) the pill would hit it
// instead of the page, so the pill stops taking pointer events until the agent's pointer has been away for a second.
async function tabIndicatorBeforeAgentPointer(tabId, method, params) {
  const session = state.tabSessions.get(tabId);
  const ind = session?.tabIndicator;
  if (!ind?.shown || !ind.pill) return;
  const point = method === "Input.dispatchTouchEvent" ? params?.touchPoints?.[0] : params;
  const x = Number(point?.x);
  const y = Number(point?.y);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return;
  const m = TAB_INDICATOR_POINTER_MARGIN;
  const r = ind.pill;
  if (x < r.x - m || x > r.x + r.width + m || y < r.y - m || y > r.y + r.height + m) return;
  if (ind.inertTimer) clearTimeout(ind.inertTimer);
  ind.inertTimer = setTimeout(() => {
    ind.inertTimer = null;
    ind.inert = false;
    if (state.tabSessions.get(tabId) === session && session.attached) {
      callTabIndicatorPage(tabId, session, { op: "inert", inert: false }, { create: false }).catch(() => {});
    }
  }, TAB_INDICATOR_TIMING.pointerGraceMs);
  if (ind.inert) return;
  ind.inert = true;
  await callTabIndicatorPage(tabId, session, { op: "inert", inert: true }, { create: false });
}

// `frame` messages carry `indicator: true` while the indicator is on screen, so the app does not reuse them where
// the agent would see it (vision).
function tabIndicatorFrameFlag(tabId) {
  return state.tabSessions.get(tabId)?.tabIndicator?.shown ? true : undefined;
}

function handleTabIndicatorBinding(tabId, session, params) {
  const ind = session.tabIndicator;
  if (ind.contextId == null || params.executionContextId !== ind.contextId) return;
  let payload = null;
  try {
    payload = JSON.parse(params.payload);
  } catch (_) {}
  if (!payload || payload.token !== ind.token) return;
  if (!ind.controlled || ind.stopped || !ind.shown) return;
  if (payload.action === "user_input") {
    if (ind.userPaused) return;
    const { eventType } = payload;
    const now = Date.now();
    if (eventType === "pointerdown" || eventType === "mousedown") {
      if (ind.agentPointerDepth > 0 || now < ind.suppressPointerUntil) return;
    } else if (eventType === "keydown" || eventType === "input") {
      if (ind.agentKeyboardDepth > 0 || now < ind.suppressKeyboardUntil) return;
    } else {
      return;
    }
    ind.userPaused = true;
    scheduleTabIndicatorRender(tabId);
  } else if (ind.inert) {
    return;
  } else if (payload.action === "resume") {
    resumeTabIndicatorUserPause(tabId);
  } else if (payload.action === "stop" || payload.action == null) {
    sendWS({ type: "stop_requested", tabId });
    // Cancel the waiting batch and keep queued work paused until the daemon acknowledges Stop.
    for (const finish of ind.userPausedWaiters.splice(0)) finish(true);
  }
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (!source || source.tabId == null || source.sessionId) return;
  const session = state.tabSessions.get(source.tabId);
  const ind = session?.tabIndicator;
  if (!session?.attached || !ind) return;
  if (method === "Page.frameNavigated" && params?.frame && !params.frame.parentId) {
    // A new top document: draw into it again if the tab is still controlled (or clean up a restored one).
    ind.mainFrameId = params.frame.id || ind.mainFrameId;
    ind.contextId = null;
    ind.bootstrappedContextId = null;
    ind.mounted = false;
    ind.shown = false;
    ind.pill = null;
    if (ind.controlled || ind.stopped || ind.everMounted) scheduleTabIndicatorRender(source.tabId);
    return;
  }
  if (method === "Runtime.executionContextDestroyed" && params?.executionContextId === ind.contextId) {
    ind.contextId = null;
    ind.bootstrappedContextId = null;
    return;
  }
  if (method === "Runtime.executionContextsCleared") {
    ind.contextId = null;
    ind.bootstrappedContextId = null;
    return;
  }
  if (method === "Runtime.bindingCalled" && params?.name === TAB_INDICATOR_BINDING) {
    handleTabIndicatorBinding(source.tabId, session, params);
  }
});

// Switching tabs, or focusing, minimizing or restoring a window, shows or hides indicators at once, outside the tab
// command queues (a running command must not delay them).
chrome.tabs.onActivated?.addListener(() => refreshTabIndicators());
chrome.windows?.onFocusChanged?.addListener(() => refreshTabIndicators());
