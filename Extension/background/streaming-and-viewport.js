// CDP sessions, viewport tracking, and live preview streaming.

async function sendCDP(tabId, method, params = {}, cdpSessionId = null) {
  const target = cdpSessionId ? { tabId, sessionId: cdpSessionId } : { tabId };
  const pointer = TAB_INDICATOR_POINTER_METHODS.has(method);
  if (pointer && !cdpSessionId) await tabIndicatorBeforeAgentPointer(tabId, method, params);
  const kind = pointer && !(method === "Input.dispatchMouseEvent" && params.type === "mouseMoved")
    ? "pointer"
    : tabIndicatorKeyboardMethods.has(method) ? "keyboard" : null;
  if (!kind) return chrome.debugger.sendCommand(target, method, params);
  const input = beginTabIndicatorAgentInput(tabId, kind);
  try {
    return await chrome.debugger.sendCommand(target, method, params);
  } finally {
    endTabIndicatorAgentInput(tabId, kind, input);
  }
}

async function initChildTargetSession(tabId, childSessionId) {
  const session = state.tabSessions.get(tabId);
  if (!session || !session.attached) return;
  const entry = session.childTargets.get(childSessionId);
  if (!entry) return;
  await Promise.all([
    sendCDP(tabId, "Runtime.enable", {}, childSessionId).catch(() => {}),
    sendCDP(tabId, "DOM.enable", {}, childSessionId).catch(() => {}),
    sendCDP(tabId, "Page.enable", {}, childSessionId).catch(() => {}),
    sendCDP(tabId, "Network.enable", { maxPostDataSize: 0 }, childSessionId).catch(() => {}),
    sendCDP(tabId, "Target.setAutoAttach", {
      autoAttach: true,
      waitForDebuggerOnStart: false,
      flatten: true
    }, childSessionId).catch(() => {})
  ]);
  entry.ready = true;
}

function pruneChildTarget(session, childSessionId) {
  if (!session || !childSessionId) return;
  const toDelete = [childSessionId];
  for (let i = 0; i < toDelete.length; i++) {
    const sid = toDelete[i];
    session.childTargets.delete(sid);
    for (const [otherSid, info] of session.childTargets.entries()) {
      if (info.parentSessionId === sid && !toDelete.includes(otherSid)) {
        toDelete.push(otherSid);
      }
    }
    const prefix = `${sid}:`;
    for (const ctxKey of Array.from(session.executionContexts.keys())) {
      if (ctxKey.startsWith(prefix)) {
        session.executionContexts.delete(ctxKey);
      }
    }
  }
}

function clearSessionFrameState(session) {
  if (!session) return;
  session.childTargets?.clear();
  session.executionContexts?.clear();
  session.elementFrameMap?.clear();
  session.frameSlots?.clear();
  session.nextFrameSlot = 1;
  session.lastChildFrames = [];
  session.lastSnapshot = null;
  session.networkPending?.clear();
  session.networkRing = [];
  session.networkErrors = [];
  session.documentId = (session.documentId || 0) + 1;
  session.topLoaderId = null;
  session.navigating = false;
  if (session.previewDebounceTimer) {
    clearTimeout(session.previewDebounceTimer);
    session.previewDebounceTimer = null;
  }
}

async function refreshTabMeta(tabId) {
  const session = state.tabSessions.get(tabId);
  try {
    const tab = await chrome.tabs.get(tabId);
    if (session) {
      session.url = tab.url || session.url || "";
      session.title = tab.title || session.title || "";
    }
    return tab;
  } catch (_) {
    return null;
  }
}

function clearIdleTimer(session) {
  if (session?.idleTimer) {
    clearTimeout(session.idleTimer);
    session.idleTimer = null;
  }
}

function resetIdleTimer(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session) return;
  clearIdleTimer(session);
  markTabControlled(tabId);
  session.lastActiveAt = Date.now();
  session.idleTimer = setTimeout(() => {
    session.idleTimer = null;
    enqueueTabCommand(tabId, () => stopStreamingAndDetach(tabId, true, "idle"));
  }, IDLE_TIMEOUT_MS);
}

function stopCapturePump(session) {
  if (session?.capturePumpTimer) {
    clearInterval(session.capturePumpTimer);
    session.capturePumpTimer = null;
  }
}

function emitPreviewFrameData(tabId, jpegBase64, indicatorOverride = undefined) {
  const session = state.tabSessions.get(tabId);
  if (!session || !jpegBase64) return;
  session.lastFrameAt = Date.now();
  const viewport = effectiveViewport(session);
  sendWS({
    type: "frame",
    tabId,
    profileName: state.profileName,
    url: session.url,
    title: session.title,
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    jpegBase64,
    indicator: indicatorOverride !== undefined ? indicatorOverride : tabIndicatorFrameFlag(tabId)
  });
}

async function captureAndEmitFrame(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session || !session.attached || session.captureInFlight) {
    return;
  }
  session.captureInFlight = true;
  try {
    const res = await sendCDP(tabId, "Page.captureScreenshot", {
      format: "jpeg",
      quality: 74,
      optimizeForSpeed: true
    });
    if (res?.data) {
      if (!session.url && !session.title) {
        await refreshTabMeta(tabId);
      }
      emitPreviewFrameData(tabId, res.data);
    }
  } catch (_) {
    // Tab may have navigated or detached
  } finally {
    session.captureInFlight = false;
  }
}

function schedulePreviewFrame(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session || !session.attached) return;
  if (session.previewDebounceTimer) {
    clearTimeout(session.previewDebounceTimer);
  }
  session.previewDebounceTimer = setTimeout(() => {
    session.previewDebounceTimer = null;
    captureAndEmitFrame(tabId).catch(() => {});
  }, PREVIEW_DEBOUNCE_MS);
}

function startCapturePump(tabId) {
  const session = getOrCreateTabSession(tabId);
  stopCapturePump(session);
  session.capturePumpTimer = setInterval(() => {
    // A tab the user can see gets its frames from the screencast; polling screenshots there forces repaints.
    // A covered window's tab is the exception (see checkCoveredWhileVisible).
    const onScreen = session.visibleToUser && !session.coveredWhileVisible;
    if (!session.streaming || !session.attached || session.captureInFlight || onScreen) {
      return;
    }
    if (Date.now() - session.lastFrameAt > CAPTURE_STALE_MS) {
      captureAndEmitFrame(tabId);
    }
  }, CAPTURE_INTERVAL_MS);
}

function clearPendingFileChooser(session, value = null) {
  if (session?.pendingFileChooser) {
    const pending = session.pendingFileChooser;
    session.pendingFileChooser = null;
    if (pending.timer) clearTimeout(pending.timer);
    pending.resolve(value);
  }
}

function waitForFileChooser(tabId, timeoutMs = 2600) {
  const session = getOrCreateTabSession(tabId);
  clearPendingFileChooser(session, null);
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (session.pendingFileChooser?.timer === timer) {
        session.pendingFileChooser = null;
      }
      resolve(null);
    }, timeoutMs);
    session.pendingFileChooser = { resolve, timer };
  });
}

// `reason` tells the UseMac preview whether the tab is gone ("closed", "stopped", "detached") or only stopped
// streaming while it stays open ("idle", "evicted"), in which case its card is kept with the last frame.
async function stopStreamingAndDetach(tabId, emitStopped = true, reason = "stopped") {
  if (tabId == null) {
    const allIds = Array.from(state.tabSessions.keys());
    for (const id of allIds) {
      await stopStreamingAndDetach(id, emitStopped, reason);
    }
    return;
  }

  const session = state.tabSessions.get(tabId);
  if (!session) return;

  await tabIndicatorBeforeDetach(tabId, session);
  clearIdleTimer(session);
  stopCapturePump(session);
  clearPendingFileChooser(session, null);
  clearSessionFrameState(session);
  const wasStreamingOrAttached = session.streaming || session.attached;
  session.streaming = false;
  session.attached = false;

  try {
    await sendCDP(tabId, "Page.stopScreencast");
  } catch (_) {}
  try {
    await chrome.debugger.detach({ tabId });
  } catch (_) {}

  state.tabSessions.delete(tabId);
  if (state.lastTabId === tabId) {
    const remaining = Array.from(state.tabSessions.keys());
    state.lastTabId = remaining.length > 0 ? remaining[remaining.length - 1] : null;
  }
  if (emitStopped && wasStreamingOrAttached) {
    sendWS({ type: "stream_stopped", tabId, reason });
  }
}

async function evictOldestSessionIfNeeded(keepingTabId) {
  const attached = Array.from(state.tabSessions.values())
    .filter((s) => s.attached && s.tabId !== keepingTabId)
    .sort((a, b) => a.lastActiveAt - b.lastActiveAt);

  while (attached.length >= MAX_CONCURRENT_ATTACHED_TABS) {
    const oldest = attached.shift();
    if (oldest) {
      await stopStreamingAndDetach(oldest.tabId, true, "evicted");
    }
  }
}

// --- Visible vs hidden tabs ---------------------------------------------------------------------------------------
// UseMac never changes a tab's size: every tab lays out at the size Chrome gives it, and coordinates use that real
// size (see refreshLiveViewport). Visibility only decides where preview frames come from. A hidden tab gets a
// screenshot pump that keeps the preview fresh. A tab the user is looking at gets no pump (polling screenshots there
// forces repaints, which flicker); its preview comes from the screencast.

// CSS-pixel size and pixel ratio the page lays out into, as last measured. Until a measurement works this is
// FALLBACK_VIEWPORT_WIDTH x FALLBACK_VIEWPORT_HEIGHT, which is only reported, never applied.
function effectiveViewport(session) {
  return session?.liveViewport || { width: FALLBACK_VIEWPORT_WIDTH, height: FALLBACK_VIEWPORT_HEIGHT, scale: 1 };
}

// The user can see a tab when it is the active tab of a window that is not minimized. A failed lookup counts as
// hidden, which keeps the pump.
async function isTabVisibleToUser(tabId, knownTab = null) {
  try {
    const tab = knownTab || await chrome.tabs.get(tabId);
    if (!tab?.active) return false;
    const win = await chrome.windows.get(tab.windowId);
    return Boolean(win) && win.state !== "minimized";
  } catch (_) {
    return false;
  }
}

// Measures the page's real size into session.liveViewport. A tab Chrome has not laid out yet can report 0x0 (or
// close to it): then the tab's size in Chrome is used instead, and if that is not known either the last
// measurement stays.
async function refreshLiveViewport(tabId, session, knownTab = null) {
  const [evalRes, zoomVal] = await Promise.all([
    sendCDP(tabId, "Runtime.evaluate", {
      expression: "({ width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio })",
      returnByValue: true
    }).catch(() => null),
    chrome.tabs.getZoom(tabId).catch(() => 1)
  ]);
  const measured = evalRes?.result?.value || null;
  // The page zoom turns window pixels into CSS pixels (at 90%, a 1512 px window lays out 1680 px wide).
  const z = Number(zoomVal);
  const zoom = z > 0 ? z : 1;
  let width = Number(measured?.width) || 0;
  let height = Number(measured?.height) || 0;
  const scale = Number(measured?.scale) > 0 ? Number(measured.scale) : session.liveViewport?.scale || 1;
  if (width < MIN_USABLE_VIEWPORT || height < MIN_USABLE_VIEWPORT) {
    let tab = knownTab;
    if (!tab || !(Number(tab.width) > 0) || !(Number(tab.height) > 0)) {
      try {
        tab = await chrome.tabs.get(tabId);
      } catch (_) {}
    }
    width = Number(tab?.width) / zoom || 0;
    height = Number(tab?.height) / zoom || 0;
    if (width < MIN_USABLE_VIEWPORT || height < MIN_USABLE_VIEWPORT) return;
  }
  session.liveViewport = { width: Math.round(width), height: Math.round(height), scale, zoom };
}

// Puts an attached tab's capture pump in line with session.visibleToUser.
function applyCapturePump(tabId, session) {
  if (session.visibleToUser) {
    stopCapturePump(session);
  } else if (session.streaming && !session.capturePumpTimer) {
    startCapturePump(tabId);
  }
}

// Re-checks one attached tab and switches its pump when the user started or stopped seeing it. `remeasure` also
// refreshes its size (window resize, or a page with another zoom level).
async function syncTabVisibility(tabId, { remeasure = false } = {}) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached) return;
  const visible = await isTabVisibleToUser(tabId);
  if (state.tabSessions.get(tabId) !== session || !session.attached) return;
  const changed = visible !== session.visibleToUser;
  session.visibleToUser = visible;
  if (changed || remeasure) await refreshLiveViewport(tabId, session);
  if (!changed) return;
  applyCapturePump(tabId, session);
  if (visible && session.streaming) {
    // One fresh frame, so the preview does not wait for the screencast's next one.
    await captureAndEmitFrame(tabId);
  }
}

// Runs in the tab's command queue, so a running command never sees the measured size change halfway. Repeated
// events before it runs collapse into one check.
function scheduleVisibilitySync(tabId, { remeasure = false } = {}) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached) return;
  session.visibilitySyncRemeasure = session.visibilitySyncRemeasure || remeasure;
  if (session.visibilitySyncQueued) return;
  session.visibilitySyncQueued = true;
  enqueueTabCommand(tabId, async () => {
    session.visibilitySyncQueued = false;
    const remeasureNow = session.visibilitySyncRemeasure;
    session.visibilitySyncRemeasure = false;
    await syncTabVisibility(tabId, { remeasure: remeasureNow });
  }, { countsAsActivity: false }).catch(() => {});
}

function scheduleVisibilitySyncForAttachedTabs(options) {
  for (const [tabId, session] of state.tabSessions) {
    if (session.attached) scheduleVisibilitySync(tabId, options);
  }
}

// --- Covered windows ----------------------------------------------------------------------------------------------
// isTabVisibleToUser cannot tell a window covered by other windows (or on another Space) from one on screen, and
// Chrome stops painting a page it knows is occluded, so its screencast goes quiet and the preview froze until the
// next command. A quiet screencast alone proves nothing (a static page sends no frames either, and polling a tab
// on screen flickers), so when frames stop the watch asks the page: document.visibilityState is "hidden" only when
// Chrome is not showing it. Then the tab goes back to screenshot polling, at its real size like every tab, until
// the page reports "visible" again.
const SCREENCAST_STALL_MS = 1000;
const COVER_CHECK_INTERVAL_MS = CAPTURE_INTERVAL_MS;
const COVER_PROBE_INTERVAL_MS = 1000;

function startScreencastStallWatch(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session || session.stallWatchTimer) return;
  session.stallWatchTimer = setInterval(() => {
    if (state.tabSessions.get(tabId) !== session || !session.attached || !session.streaming) {
      clearInterval(session.stallWatchTimer);
      session.stallWatchTimer = null;
      session.coveredWhileVisible = false;
      return;
    }
    checkCoveredWhileVisible(tabId, session).catch(() => {});
  }, COVER_CHECK_INTERVAL_MS);
}

async function probePageHidden(tabId) {
  try {
    const res = await sendCDP(tabId, "Runtime.evaluate", {
      expression: "document.visibilityState",
      returnByValue: true
    });
    const value = res?.result?.value;
    return value === "hidden" ? true : value === "visible" ? false : null;
  } catch (_) {
    return null;
  }
}

async function checkCoveredWhileVisible(tabId, session) {
  if (!session.visibleToUser) {
    // Hidden tabs already poll (applyCapturePump); the cover state starts over when the tab is shown again.
    session.coveredWhileVisible = false;
    return;
  }
  if (session.coverProbeInFlight) return;
  const now = Date.now();
  const lastScreencastFrameAt = session.lastScreencastFrameAt || 0;
  if (session.coveredWhileVisible) {
    if (!session.capturePumpTimer) startCapturePump(tabId);
    // Re-check about once a second, and at once when the screencast speaks again (the window may be back on top).
    const frameSinceProbe = lastScreencastFrameAt > (session.coverProbeAt || 0);
    if (!frameSinceProbe && now - (session.coverProbeAt || 0) < COVER_PROBE_INTERVAL_MS) return;
  } else {
    if (now - lastScreencastFrameAt < SCREENCAST_STALL_MS) return;
    if (now - (session.coverProbeAt || 0) < COVER_PROBE_INTERVAL_MS) return;
  }
  session.coverProbeInFlight = true;
  session.coverProbeAt = now;
  let hidden;
  try {
    hidden = await probePageHidden(tabId);
  } finally {
    session.coverProbeInFlight = false;
  }
  if (state.tabSessions.get(tabId) !== session || !session.attached || !session.streaming || !session.visibleToUser) {
    return;
  }
  if (hidden === true && !session.coveredWhileVisible) {
    session.coveredWhileVisible = true;
    startCapturePump(tabId);
    await captureAndEmitFrame(tabId);
  } else if (hidden === false && session.coveredWhileVisible) {
    session.coveredWhileVisible = false;
    stopCapturePump(session);
  }
}

async function ensureAttached(tabId) {
  const existing = state.tabSessions.get(tabId);
  if (existing?.attached) {
    existing.lastActiveAt = Date.now();
    state.lastTabId = tabId;
    return;
  }

  // Fail fast (before evicting other sessions) on pages Chrome will refuse to attach to.
  const tab = await assertTabScriptable(tabId);

  const session = getOrCreateTabSession(tabId);
  session.lastActiveAt = Date.now();
  state.lastTabId = tabId;

  await evictOldestSessionIfNeeded(tabId);

  try {
    await chrome.debugger.attach({ tabId }, "1.3");
  } catch (err) {
    throw await toRestrictedPageErrorIfNeeded(err, tabId);
  }
  session.attached = true;
  if (tab) {
    session.url = tab.url || session.url || "";
    session.title = tab.title || session.title || "";
  }

  // Parallel cold attach: enable all CDP domains + focus emulation + auto-attach + viewport/visibility in one wave.
  const [, , , , , , frameTreeRes, visible] = await Promise.all([
    sendCDP(tabId, "Page.enable"),
    sendCDP(tabId, "Runtime.enable"),
    sendCDP(tabId, "DOM.enable"),
    sendCDP(tabId, "Network.enable", { maxPostDataSize: 0 }).catch(() => {}),
    sendCDP(tabId, "Target.setAutoAttach", {
      autoAttach: true,
      waitForDebuggerOnStart: false,
      flatten: true
    }).catch(() => {}),
    sendCDP(tabId, "Emulation.setFocusEmulationEnabled", { enabled: true }).catch(() => {}),
    sendCDP(tabId, "Page.getFrameTree").catch(() => null),
    isTabVisibleToUser(tabId, tab),
    refreshLiveViewport(tabId, session, tab)
  ]);

  session.topLoaderId ||= frameTreeRes?.frameTree?.frame?.loaderId || null;
  session.visibleToUser = visible;
  // Wait briefly for OOPIF Target.attachedToTarget events ONLY when Page.getFrameTree actually reports child frames.
  if (Array.isArray(frameTreeRes?.frameTree?.childFrames) && frameTreeRes.frameTree.childFrames.length > 0) {
    await sleep(25);
  }
}

async function ensureStreaming(tabId) {
  await ensureAttached(tabId);
  const session = getOrCreateTabSession(tabId);
  if (!session.streaming) {
    session.streaming = true;
    session.lastFrameAt = 0;
    try {
      await sendCDP(tabId, "Page.startScreencast", {
        format: "jpeg",
        quality: 76,
        maxWidth: 960,
        maxHeight: 600,
        everyNthFrame: 1
      });
    } catch (_) {}
    if (!session.visibleToUser) {
      startCapturePump(tabId);
    }
    startScreencastStallWatch(tabId);
    // Non-blocking initial preview frame so observe/act never stalls waiting on a preview JPEG.
    captureAndEmitFrame(tabId).catch(() => {});
  }
  resetIdleTimer(tabId);
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (!source || source.tabId == null) {
    return;
  }
  if (method === "Page.downloadWillBegin") {
    const at = Date.now();
    prunePageDownloads(at);
    state.pendingPageDownloads.push({
      tabId: source.tabId,
      url: params?.url || "",
      suggestedFilename: params?.suggestedFilename || "",
      at
    });
    if (state.pendingPageDownloads.length > PAGE_DOWNLOAD_MAX) state.pendingPageDownloads.shift();
    return;
  }
  const session = state.tabSessions.get(source.tabId);
  if (!session || !session.attached) {
    return;
  }
  if (method === "Page.javascriptDialogOpening") {
    const dialogType = String(params?.type || "alert");
    const message = String(params?.message ?? "").slice(0, 500);
    const defaultPrompt = typeof params?.defaultPrompt === "string" ? params.defaultPrompt.slice(0, 200) : undefined;
    const action = session.dialogPolicy?.action;
    const accepted = action ? action === "accept" : dialogType === "alert" || dialogType === "beforeunload";
    const promptText = dialogType === "prompt" && accepted
      ? String(session.dialogPolicy?.promptText ?? params?.defaultPrompt ?? "")
      : undefined;
    // Don't queue this behind the in-flight CDP command: that command may be blocked by the dialog.
    sendCDP(source.tabId, "Page.handleJavaScriptDialog", {
      accept: accepted,
      ...(promptText !== undefined ? { promptText } : {})
    }, source.sessionId || null).catch(() => {});
    const dialog = {
      type: dialogType,
      message,
      ...(defaultPrompt ? { defaultPrompt } : {}),
      accepted,
      ...(promptText !== undefined ? { promptText } : {})
    };
    session.lastDialog = dialog;
    session.batchDialogs?.push({ ...dialog, autoDefault: !action });
    return;
  }
  if (method === "Target.attachedToTarget") {
    const childSessionId = params?.sessionId;
    const targetInfo = params?.targetInfo;
    const parentSessionId = source.sessionId || null;
    if (childSessionId && targetInfo && (targetInfo.type === "iframe" || targetInfo.type === "page")) {
      const entry = {
        sessionId: childSessionId,
        targetId: targetInfo.targetId || "",
        parentSessionId,
        url: targetInfo.url || "",
        title: targetInfo.title || "",
        type: targetInfo.type,
        ready: false,
        initPromise: null
      };
      session.childTargets.set(childSessionId, entry);
      entry.initPromise = initChildTargetSession(source.tabId, childSessionId).catch(() => {});
    }
    if (params?.waitingForDebugger && childSessionId) {
      sendCDP(source.tabId, "Runtime.runIfWaitingForDebugger", {}, childSessionId).catch(() => {});
    }
    return;
  }
  if (method === "Target.detachedFromTarget") {
    if (params?.sessionId) {
      pruneChildTarget(session, params.sessionId);
    }
    return;
  }
  if (method === "Target.targetInfoChanged" && params?.targetInfo?.targetId) {
    for (const info of session.childTargets.values()) {
      if (info.targetId === params.targetInfo.targetId) {
        if (params.targetInfo.url != null) info.url = params.targetInfo.url;
        if (params.targetInfo.title != null) info.title = params.targetInfo.title;
      }
    }
    return;
  }
  if (method === "Runtime.executionContextCreated" && params?.context) {
    const ctx = params.context;
    const frameId = ctx?.auxData?.frameId;
    if (frameId && ctx?.auxData?.isDefault) {
      const key = `${source.sessionId || "top"}:${frameId}`;
      session.executionContexts.set(key, ctx.id);
    }
    return;
  }
  if (method === "Runtime.executionContextDestroyed" && params?.executionContextId != null) {
    const destroyedId = params.executionContextId;
    const prefix = `${source.sessionId || "top"}:`;
    for (const [k, v] of session.executionContexts.entries()) {
      if (k.startsWith(prefix) && v === destroyedId) {
        session.executionContexts.delete(k);
      }
    }
    return;
  }
  if (method === "Runtime.executionContextsCleared") {
    const prefix = `${source.sessionId || "top"}:`;
    for (const k of Array.from(session.executionContexts.keys())) {
      if (k.startsWith(prefix)) {
        session.executionContexts.delete(k);
      }
    }
    return;
  }
  if (method === "Page.fileChooserOpened") {
    clearPendingFileChooser(session, { ...(params || {}), sessionId: source.sessionId || null });
    return;
  }
  if ((method === "Page.frameStartedNavigating" || method === "Page.frameStartedLoading") && !source.sessionId) {
    session.navigating = true;
    sendWS({ type: "tab_url", tabId: source.tabId, loading: true });
    return;
  }
  if (method === "Page.loadEventFired" && !source.sessionId) {
    session.navigating = false;
    return;
  }
  if (method === "Page.frameNavigated" && !source.sessionId && params?.frame && !params.frame.parentId) {
    session.navigating = false;
    const nextLoaderId = params.frame.loaderId || null;
    if (nextLoaderId && nextLoaderId !== session.topLoaderId) {
      // Without an initial loader, a frame event for the URL we already attached to only establishes a baseline.
      if (session.topLoaderId || (params.frame.url && session.url && params.frame.url !== session.url)) {
        session.documentId += 1;
        session.networkRing = [];
        session.networkPending.clear();
      }
      session.topLoaderId = nextLoaderId;
    }
    if (params.frame.url) session.url = params.frame.url;
    sendWS({
      type: "tab_url",
      tabId: source.tabId,
      url: params.frame.url || session.url || "",
      loading: false
    });
    return;
  }
  if (method === "Network.requestWillBeSent") {
    session.networkRequestSeq = (session.networkRequestSeq || 0) + 1;
    if (source.sessionId) return;
    const reqId = params?.requestId;
    const reqType = params?.type || "";
    const reqUrl = params?.request?.url || "";
    if (reqId && (reqType === "XHR" || reqType === "Fetch")) {
      session.networkPending.set(reqId, {
        requestId: reqId,
        url: reqUrl,
        method: params?.request?.method || "GET",
        resourceType: reqType,
        loaderId: params?.loaderId || null,
        documentId: session.documentId,
        timestampMs: Date.now()
      });
      if (session.networkPending.size > 200) {
        const oldestKey = session.networkPending.keys().next().value;
        if (oldestKey != null) session.networkPending.delete(oldestKey);
      }
    }
    return;
  }
  if (method === "Network.responseReceived" && !source.sessionId) {
    const reqId = params?.requestId;
    const pending = reqId ? session.networkPending.get(reqId) : null;
    const loaderId = params?.loaderId || pending?.loaderId || null;
    if (pending && pending.documentId !== session.documentId) return;
    if (!pending && session.topLoaderId && loaderId && loaderId !== session.topLoaderId) return;
    const reqType = params?.type || pending?.resourceType || "";
    const resp = params?.response || {};
    const status = Number(resp.status) || 0;
    const url = resp.url || pending?.url || "";
    const reqMethod = pending?.method || "GET";
    const headers = resp.headers || {};
    let contentType = resp.mimeType || "";
    for (const [k, v] of Object.entries(headers)) {
      if (k.toLowerCase() === "content-type" && typeof v === "string") {
        contentType = v;
        break;
      }
    }
    const isXhrFetch = reqType === "XHR" || reqType === "Fetch" || Boolean(pending);
    if (isXhrFetch) {
      const now = Date.now();
      if (status >= 400) {
        session.networkErrors.push({
          url,
          method: reqMethod,
          status,
          statusText: resp.statusText || "",
          timestampMs: now
        });
        if (session.networkErrors.length > NETWORK_ERRORS_MAX) {
          session.networkErrors.splice(0, session.networkErrors.length - NETWORK_ERRORS_MAX);
        }
      }
      const isJson = /json/i.test(contentType);
      if (reqId && (isJson || status >= 400)) {
        session.networkRing.push({
          url,
          method: reqMethod,
          status,
          contentType,
          requestId: reqId,
          documentId: session.documentId,
          timestampMs: now,
          finished: false,
          bodyLoaded: false,
          body: null
        });
        if (session.networkRing.length > NETWORK_RING_MAX) {
          session.networkRing.splice(0, session.networkRing.length - NETWORK_RING_MAX);
        }
      }
    }
    return;
  }
  if (method === "Network.loadingFinished" && !source.sessionId) {
    if (params?.requestId) {
      const entry = session.networkRing.findLast((entry) => entry.requestId === params.requestId);
      if (entry) entry.finished = true;
      session.networkPending.delete(params.requestId);
    }
    return;
  }
  if (method === "Network.loadingFailed" && !source.sessionId) {
    const reqId = params?.requestId;
    const pending = reqId ? session.networkPending.get(reqId) : null;
    if (reqId) session.networkPending.delete(reqId);
    if (pending && !params?.canceled) {
      session.networkErrors.push({
        url: pending.url,
        method: pending.method,
        status: 0,
        statusText: params?.errorText || "Network error",
        timestampMs: Date.now()
      });
      if (session.networkErrors.length > NETWORK_ERRORS_MAX) {
        session.networkErrors.splice(0, session.networkErrors.length - NETWORK_ERRORS_MAX);
      }
    }
    return;
  }
  if (method === "Page.screencastFrame" && !source.sessionId && params?.data) {
    const sessionId = params.sessionId;
    if (sessionId !== undefined) {
      sendCDP(source.tabId, "Page.screencastFrameAck", { sessionId }).catch(() => {});
    }
    session.lastFrameAt = Date.now();
    session.lastScreencastFrameAt = session.lastFrameAt;
    const viewport = effectiveViewport(session);
    sendWS({
      type: "frame",
      tabId: source.tabId,
      profileName: state.profileName,
      url: session.url,
      title: session.title,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      jpegBase64: params.data,
      indicator: tabIndicatorFrameFlag(source.tabId)
    });
  }
});

chrome.debugger.onDetach.addListener((source) => {
  if (!source || source.tabId == null) {
    return;
  }
  const detachedTabId = source.tabId;
  const session = state.tabSessions.get(detachedTabId);
  if (!session) {
    return;
  }
  if (source.sessionId) {
    pruneChildTarget(session, source.sessionId);
    return;
  }
  if (session.tabIndicator) clearTabIndicatorUserPause(session.tabIndicator, true);
  clearIdleTimer(session);
  stopCapturePump(session);
  clearPendingFileChooser(session, null);
  clearSessionFrameState(session);
  session.streaming = false;
  session.attached = false;
  state.tabSessions.delete(detachedTabId);
  if (state.lastTabId === detachedTabId) {
    const remaining = Array.from(state.tabSessions.keys());
    state.lastTabId = remaining.length > 0 ? remaining[remaining.length - 1] : null;
  }
  sendWS({ type: "stream_stopped", tabId: detachedTabId, reason: "detached" });
});

chrome.tabs.onCreated?.addListener((tab) => {
  if (!tab || tab.id == null) return;
  sendWS({
    type: "tab_url",
    tabId: tab.id,
    windowId: tab.windowId ?? null,
    url: tab.url || tab.pendingUrl || "",
    pendingUrl: tab.pendingUrl || null,
    title: tab.title || "",
    active: Boolean(tab.active)
  });
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const session = state.tabSessions.get(tabId);
  if (session && (changeInfo.url || changeInfo.title || tab)) {
    session.url = tab?.url || changeInfo.url || session.url;
    session.title = tab?.title || changeInfo.title || session.title;
  }
  if (session && changeInfo?.status === "loading") {
    session.navigating = true;
  } else if (session && changeInfo?.status === "complete") {
    session.navigating = false;
  }
  if (changeInfo.url || changeInfo.title || changeInfo.status === "loading" || changeInfo.status === "complete") {
    const loading = changeInfo.status === "loading"
      ? true
      : (changeInfo.status === "complete" ? false : undefined);
    sendWS({
      type: "tab_url",
      tabId,
      windowId: tab?.windowId ?? null,
      url: tab?.url || changeInfo.url || "",
      pendingUrl: tab?.pendingUrl || null,
      title: tab?.title || changeInfo.title || "",
      active: typeof tab?.active === "boolean" ? tab.active : undefined,
      loading
    });
  }
  if (session?.attached && changeInfo?.status === "complete") {
    scheduleVisibilitySync(tabId, { remeasure: true });
  }
});

// The user switched tabs, or focused, minimized, restored or resized a window: re-check the attached tabs (at most
// MAX_CONCURRENT_ATTACHED_TABS, two lookups each).
chrome.tabs.onActivated?.addListener(() => scheduleVisibilitySyncForAttachedTabs());
chrome.windows?.onFocusChanged?.addListener(() => scheduleVisibilitySyncForAttachedTabs());
chrome.windows?.onBoundsChanged?.addListener(() => scheduleVisibilitySyncForAttachedTabs({ remeasure: true }));

chrome.tabs.onRemoved.addListener((tabId) => {
  forgetOwnedTab(tabId).catch(() => {});
  state.tabCancelGeneration.delete(tabId);
  sendWS({ type: "tab_url", tabId, removed: true });
  const session = state.tabSessions.get(tabId);
  if (session) {
    if (session.tabIndicator) clearTabIndicatorUserPause(session.tabIndicator, true);
    clearIdleTimer(session);
    stopCapturePump(session);
    clearPendingFileChooser(session, null);
    clearSessionFrameState(session);
    session.streaming = false;
    session.attached = false;
    state.tabSessions.delete(tabId);
    if (state.lastTabId === tabId) {
      const remaining = Array.from(state.tabSessions.keys());
      state.lastTabId = remaining.length > 0 ? remaining[remaining.length - 1] : null;
    }
    sendWS({ type: "stream_stopped", tabId, reason: "closed" });
  }
});

// Double requestAnimationFrame settle (~16-33ms on visible tabs, immediate when hidden or in headless/test mocks,
// capped at maxWaitMs so throttled background tabs never stall).
async function waitForAnimationFrames(tabId, maxWaitMs = 40) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached) return;
  try {
    await Promise.race([
      sendCDP(tabId, "Runtime.evaluate", {
        expression: `new Promise((resolve) => {
          if (typeof requestAnimationFrame !== 'function' || document.visibilityState === 'hidden') {
            resolve(true);
            return;
          }
          let done = false;
          const finish = () => { if (!done) { done = true; resolve(true); } };
          requestAnimationFrame(() => requestAnimationFrame(finish));
          setTimeout(finish, ${Math.max(10, Number(maxWaitMs) || 40)});
        })`,
        returnByValue: true,
        awaitPromise: true
      }),
      sleep(maxWaitMs + 25)
    ]);
  } catch (_) {}
}

async function waitForTabLoad(tabId, timeoutMs = 4500) {
  let completed = false;
  try {
    const existing = await chrome.tabs.get(tabId);
    if (existing?.status === "complete" && existing.url && existing.url !== "about:blank") {
      completed = true;
    }
  } catch (_) {
    return null;
  }

  if (!completed) {
    await new Promise((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        chrome.tabs.onUpdated.removeListener(onUpdated);
        clearTimeout(timer);
        resolve();
      };
      const onUpdated = (updatedTabId, info) => {
        if (updatedTabId === tabId && info.status === "complete") {
          finish();
        }
      };
      const timer = setTimeout(finish, timeoutMs);
      chrome.tabs.onUpdated.addListener(onUpdated);
    });
  }

  // Event-driven settle: double-rAF + MutationObserver only if body is sparse/busy (replaces blind 160ms + 700ms poll).
  const session = state.tabSessions.get(tabId);
  if (session?.attached) {
    await waitForAnimationFrames(tabId, 40);
    try {
      await Promise.race([
        sendCDP(tabId, "Runtime.evaluate", {
          expression: `new Promise((resolve) => {
            const ready = () => {
              const len = (document.body?.innerText || '').trim().length;
              const busy = Boolean(document.querySelector('[aria-busy="true"], [role="progressbar"]'));
              return len >= 60 && !busy;
            };
            if (ready() || typeof MutationObserver !== 'function' || !document.documentElement) {
              resolve(true);
              return;
            }
            let done = false;
            let mo = null;
            const finish = () => {
              if (done) return;
              done = true;
              if (mo) try { mo.disconnect(); } catch (_) {}
              clearTimeout(timer);
              resolve(true);
            };
            mo = new MutationObserver(() => { if (ready()) finish(); });
            mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
            const timer = setTimeout(finish, 450);
          })`,
          returnByValue: true,
          awaitPromise: true
        }),
        sleep(500)
      ]);
    } catch (_) {}
  }
  return refreshTabMeta(tabId);
}
