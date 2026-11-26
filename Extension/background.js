importScripts("bridge-auth.js");

const WS_URL = "ws://127.0.0.1:49222/usemac-bridge";
const BRIDGE_ENDPOINT = "127.0.0.1:49222";
const PROTOCOL_VERSION = 2;
// Reported to the UseMac app in the hello message; read from the manifest so it never goes stale.
const EXTENSION_VERSION = (() => {
  try {
    const manifest = chrome.runtime.getManifest();
    return manifest.version_name || manifest.version || "unknown";
  } catch (_) {
    return "unknown";
  }
})();
const KEEPALIVE_ALARM = "usemac-keepalive";
const VIEWPORT_WIDTH = 1280;
const VIEWPORT_HEIGHT = 800;
const IDLE_TIMEOUT_MS = 180000;
const CAPTURE_INTERVAL_MS = 240;
const CAPTURE_STALE_MS = 220;
const METRICS_SETTLE_MS = 60;
const PING_INTERVAL_MS = 20000;
const MAX_RECONNECT_DELAY_MS = 30000;
const KEY_MISMATCH_RETRY_MS = 30000;
const CANCEL_POLL_SLICE_MS = 100;
const CANCELLED_MESSAGE = "Cancelled by UseMac";
const CANCELLED_ERROR = Object.freeze({ code: "CANCELLED", message: CANCELLED_MESSAGE });
const URL_BLOCKED_ERROR = Object.freeze({ code: "URL_BLOCKED", message: "Only http(s) URLs can be opened." });
const PRE_READY_ALLOWED_TYPES = new Set(["hello", "auth", "ping", "pong"]);

const MAX_CONCURRENT_ATTACHED_TABS = 4;

const state = {
  ws: null,
  wsState: "disconnected", // "disconnected" | "connecting" | "connected"
  authState: "unpaired", // "unpaired" | "authenticating" | "ready" | "key_mismatch"
  hasKey: false,
  keyLoaded: false,
  bridgeKeyBytes: null,
  pendingClientNonce: null,
  handshakeKeyBytes: null,
  awaitingAuthResult: false,
  nextReconnectAllowedAt: 0,
  reconnectAttempts: 0,
  reconnectTimer: null,
  pingTimer: null,
  lastPongAt: 0,
  profileName: "Chrome",
  profileInitialized: false,
  tabSessions: new Map(), // tabId -> session
  tabQueues: new Map(), // tabId -> Promise
  cancelGeneration: 0,
  tabCancelGeneration: new Map(), // tabId -> number
  lastTabId: null,
  lastDownloadId: null,
  lastDownloadAt: 0,
  lastDownloadFilename: "",
  downloads: new Map(), // id -> download meta
  openQueue: Promise.resolve()
};

function recordDownloadMeta(item) {
  if (!item || item.id == null) return;
  const prev = state.downloads.get(item.id) || {};
  const next = {
    id: item.id,
    filename: item.filename || prev.filename || "",
    url: item.finalUrl || item.url || prev.url || "",
    state: item.state || prev.state || "in_progress",
    bytesReceived: item.bytesReceived ?? prev.bytesReceived ?? null,
    totalBytes: item.totalBytes ?? prev.totalBytes ?? null,
    mime: item.mime || prev.mime || null,
    startTime: item.startTime || prev.startTime || null
  };
  state.downloads.set(item.id, next);
  if (state.downloads.size > 40) {
    const firstKey = state.downloads.keys().next().value;
    if (firstKey != null) state.downloads.delete(firstKey);
  }
  return next;
}

if (chrome.downloads?.onCreated) {
  chrome.downloads.onCreated.addListener((item) => {
    state.lastDownloadId = item?.id ?? null;
    state.lastDownloadAt = Date.now();
    state.lastDownloadFilename = item?.filename || item?.url || "";
    recordDownloadMeta(item);
  });
}

if (chrome.downloads?.onChanged) {
  chrome.downloads.onChanged.addListener((delta) => {
    if (!delta || delta.id == null) return;
    const prev = state.downloads.get(delta.id) || { id: delta.id, filename: "", state: "in_progress" };
    if (delta.filename?.current) {
      prev.filename = delta.filename.current;
      if (state.lastDownloadId === delta.id) {
        state.lastDownloadFilename = delta.filename.current;
      }
    }
    if (delta.state?.current) {
      prev.state = delta.state.current;
    }
    if (delta.mime?.current) {
      prev.mime = delta.mime.current;
    }
    if (delta.totalBytes?.current != null) {
      prev.totalBytes = delta.totalBytes.current;
    }
    state.downloads.set(delta.id, prev);
  });
}

function getRecordedDownloads(limit = 20) {
  const cap = clamp(Number(limit) || 20, 1, 20);
  return Array.from(state.downloads.values())
    .slice(-cap)
    .reverse()
    .map((it) => ({
      id: it.id,
      filename: it.filename || "",
      url: it.url || null,
      state: it.state || "unknown",
      bytesReceived: Number.isFinite(it.bytesReceived) ? it.bytesReceived : null,
      totalBytes: Number.isFinite(it.totalBytes) ? it.totalBytes : null,
      mime: it.mime || null,
      startTime: it.startTime || null
    }));
}

async function waitForDownloadCompletion(downloadId, timeoutMs = 4500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (chrome.downloads?.search && downloadId != null) {
      try {
        const items = await chrome.downloads.search({ id: downloadId });
        const item = items?.[0];
        if (item) {
          const meta = recordDownloadMeta(item);
          if (item.state === "complete" || item.state === "interrupted") {
            return meta;
          }
        }
      } catch (_) {}
    } else if (downloadId != null) {
      const cached = state.downloads.get(downloadId);
      if (cached && (cached.state === "complete" || cached.state === "interrupted")) {
        return cached;
      }
    }
    await sleep(160);
  }
  return downloadId != null ? state.downloads.get(downloadId) || null : null;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function clamp(val, min, max) {
  return Math.max(min, Math.min(max, val));
}

function getOrCreateTabSession(tabId) {
  let session = state.tabSessions.get(tabId);
  if (!session) {
    session = {
      tabId,
      attached: false,
      streaming: false,
      lastFrameAt: 0,
      capturePumpTimer: null,
      captureInFlight: false,
      idleTimer: null,
      // Metrics emulated while the tab is hidden (or for an explicit viewport request).
      viewportWidth: VIEWPORT_WIDTH,
      viewportHeight: VIEWPORT_HEIGHT,
      deviceScaleFactor: 1,
      // Whether the user can see the tab (see isTabVisibleToUser). A visible tab has no metrics override and
      // keeps its real window size, measured into liveViewport ({ width, height, scale }).
      visibleToUser: false,
      metricsOverridden: false,
      // A hidden tab the user has seen is emulated at its last on-screen size (see hiddenTabMetrics).
      metricsKeepLiveLayout: false,
      explicitViewport: false,
      liveViewport: null,
      visibilitySyncQueued: false,
      visibilitySyncRemeasure: false,
      cursor: { x: 640, y: 400 },
      pendingFileChooser: null,
      childTargets: new Map(), // childSessionId -> { sessionId, targetId, parentSessionId, url, title, type, ready, initPromise }
      executionContexts: new Map(), // `${sessionId||"top"}:${frameId}` -> default main-world contextId
      elementFrameMap: new Map(), // "@bN" -> { sessionId, contextId, frameId, parentSessionId, offsetX, offsetY, url, ancestors }
      lastChildFrames: [], // cached visible child frames from latest discovery
      url: "",
      title: "",
      lastActiveAt: Date.now()
    };
    state.tabSessions.set(tabId, session);
  }
  return session;
}

function enqueueOpenCommand(fn) {
  const next = state.openQueue.then(fn, fn);
  state.openQueue = next.catch(() => {});
  return next;
}

// `countsAsActivity: false` queues housekeeping (visibility syncs) without making the tab look recently used,
// so it does not change which session gets evicted.
function enqueueTabCommand(tabId, fn, { countsAsActivity = true } = {}) {
  const session = state.tabSessions.get(tabId);
  if (session && countsAsActivity) {
    session.lastActiveAt = Date.now();
  }
  const prev = state.tabQueues.get(tabId) || Promise.resolve();
  const next = prev.then(fn, fn);
  const settled = next.catch(() => {});
  state.tabQueues.set(tabId, settled);
  settled.finally(() => {
    if (state.tabQueues.get(tabId) === settled) {
      state.tabQueues.delete(tabId);
    }
  });
  return next;
}

function getTabCancelGen(tabId) {
  return state.tabCancelGeneration.get(tabId) || 0;
}

function createCancelToken(tabId, globalGenOverride = null, tabGenOverride = null) {
  return {
    globalGen: globalGenOverride != null ? globalGenOverride : state.cancelGeneration,
    tabGen: tabGenOverride != null ? tabGenOverride : (tabId != null ? getTabCancelGen(tabId) : 0)
  };
}

function isCancelled(tabId, cancelToken) {
  if (!cancelToken) return false;
  if (state.cancelGeneration > cancelToken.globalGen) {
    return true;
  }
  if (tabId != null && getTabCancelGen(tabId) > cancelToken.tabGen) {
    return true;
  }
  return false;
}

async function sleepCancellable(ms, tabId, cancelToken) {
  const deadline = Date.now() + Math.max(0, ms);
  while (true) {
    if (isCancelled(tabId, cancelToken)) {
      throw CANCELLED_ERROR;
    }
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      break;
    }
    await sleep(Math.min(CANCEL_POLL_SLICE_MS, remaining));
  }
  if (isCancelled(tabId, cancelToken)) {
    throw CANCELLED_ERROR;
  }
}

function handleCancel(targetTabId = null) {
  if (targetTabId != null && typeof targetTabId !== "number") {
    return Promise.resolve();
  }
  if (targetTabId == null) {
    state.cancelGeneration += 1;
    const tabIds = new Set([...state.tabSessions.keys(), ...state.tabQueues.keys()]);
    const detachPromises = [];
    for (const id of tabIds) {
      const session = state.tabSessions.get(id);
      if (session) {
        clearPendingFileChooser(session, null);
      }
      detachPromises.push(enqueueTabCommand(id, () => stopStreamingAndDetach(id, true)));
    }
    return Promise.all(detachPromises);
  }

  state.tabCancelGeneration.set(targetTabId, getTabCancelGen(targetTabId) + 1);
  const session = state.tabSessions.get(targetTabId);
  if (session) {
    clearPendingFileChooser(session, null);
  }
  return enqueueTabCommand(targetTabId, () => stopStreamingAndDetach(targetTabId, true));
}

async function resolveProfileInfo(forceRefresh = false) {
  if (state.profileInitialized && !forceRefresh) {
    return { profileName: state.profileName };
  }

  let storedName = "";
  try {
    const stored = await chrome.storage.local.get(["profileName"]);
    if (typeof stored?.profileName === "string") {
      storedName = stored.profileName.trim();
    }
  } catch (_) {}

  state.profileName = storedName || "Chrome";
  state.profileInitialized = true;
  return { profileName: state.profileName };
}

async function loadPairingKey(forceRefresh = false) {
  if (state.keyLoaded && !forceRefresh) {
    return state.bridgeKeyBytes;
  }

  let storedKey = "";
  try {
    const stored = await chrome.storage.local.get(["bridgeKey"]);
    if (typeof stored?.bridgeKey === "string") {
      storedKey = stored.bridgeKey;
    }
  } catch (_) {}

  const keyBytes = UsemacBridgeAuth.parsePairingKey(storedKey);
  state.bridgeKeyBytes = keyBytes;
  state.hasKey = keyBytes !== null;
  state.keyLoaded = true;
  return keyBytes;
}

function sendWS(payload) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
    return false;
  }
  if (state.authState !== "ready" && !PRE_READY_ALLOWED_TYPES.has(payload?.type)) {
    return false;
  }
  try {
    state.ws.send(JSON.stringify(payload));
    return true;
  } catch (_) {
    return false;
  }
}

async function sendHello(socket = state.ws) {
  await resolveProfileInfo();
  const keyBytes = await loadPairingKey(true);
  if (!socket || state.ws !== socket || socket.readyState !== WebSocket.OPEN) {
    return;
  }
  const clientNonce = UsemacBridgeAuth.randomNonceHex();
  state.pendingClientNonce = clientNonce;
  state.handshakeKeyBytes = keyBytes;
  state.awaitingAuthResult = false;
  state.authState = keyBytes ? "authenticating" : "unpaired";
  sendWS({
    type: "hello",
    protocol: PROTOCOL_VERSION,
    extensionVersion: EXTENSION_VERSION,
    profileName: state.profileName,
    clientNonce,
    hasKey: Boolean(keyBytes)
  });
}

async function sendProfileInfo() {
  if (state.authState !== "ready") {
    return;
  }
  await resolveProfileInfo();
  let tabCount = 0;
  try {
    const allTabs = await chrome.tabs.query({});
    tabCount = Array.isArray(allTabs) ? allTabs.length : 0;
  } catch (_) {}
  if (state.authState !== "ready") {
    return;
  }
  sendWS({
    type: "profile_info",
    profileName: state.profileName,
    tabCount
  });
}

function stopPingTimer() {
  if (state.pingTimer) {
    clearInterval(state.pingTimer);
    state.pingTimer = null;
  }
}

function startPingTimer() {
  stopPingTimer();
  state.pingTimer = setInterval(() => {
    sendWS({ type: "ping", ts: Date.now() });
  }, PING_INTERVAL_MS);
}

function scheduleReconnect(overrideDelayMs = null) {
  if (state.reconnectTimer) {
    return;
  }
  const delay = overrideDelayMs != null
    ? overrideDelayMs
    : Math.min(MAX_RECONNECT_DELAY_MS, Math.round(1500 * Math.pow(1.4, state.reconnectAttempts)));
  if (overrideDelayMs == null) {
    state.reconnectAttempts += 1;
  }
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    connectWS();
  }, delay);
}

function enterKeyMismatch(socket) {
  if (socket && state.ws === socket) {
    try {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
    } catch (_) {}
    state.ws = null;
  }
  state.wsState = "disconnected";
  state.authState = "key_mismatch";
  state.pendingClientNonce = null;
  state.handshakeKeyBytes = null;
  state.awaitingAuthResult = false;
  stopPingTimer();
  state.nextReconnectAllowedAt = Date.now() + KEY_MISMATCH_RETRY_MS;
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
  scheduleReconnect(KEY_MISMATCH_RETRY_MS);
}

async function handleChallenge(socket, msg) {
  if (
    state.ws !== socket ||
    state.authState !== "authenticating" ||
    state.awaitingAuthResult ||
    !state.pendingClientNonce ||
    !state.handshakeKeyBytes
  ) {
    return;
  }

  const clientNonce = state.pendingClientNonce;
  const keyBytes = state.handshakeKeyBytes;
  const serverNonce = msg.serverNonce;
  const receivedServerProof = msg.serverProof;

  if (!UsemacBridgeAuth.isNonceHex(serverNonce) || !UsemacBridgeAuth.isNonceHex(receivedServerProof)) {
    enterKeyMismatch(socket);
    return;
  }

  let expectedServerProof;
  let proofForServer;
  try {
    expectedServerProof = await UsemacBridgeAuth.serverProof(keyBytes, clientNonce, serverNonce);
    if (state.ws !== socket || state.authState !== "authenticating" || state.pendingClientNonce !== clientNonce) {
      return;
    }
    if (!UsemacBridgeAuth.timingSafeEqualHex(expectedServerProof, receivedServerProof)) {
      enterKeyMismatch(socket);
      return;
    }
    proofForServer = await UsemacBridgeAuth.clientProof(keyBytes, clientNonce, serverNonce);
  } catch (_) {
    if (state.ws === socket) {
      enterKeyMismatch(socket);
    }
    return;
  }

  if (state.ws !== socket || state.authState !== "authenticating" || state.pendingClientNonce !== clientNonce) {
    return;
  }

  state.pendingClientNonce = null;
  state.handshakeKeyBytes = null;
  state.awaitingAuthResult = true;
  sendWS({
    type: "auth",
    clientProof: proofForServer
  });
}

function connectWS(force = false) {
  if (force) {
    state.nextReconnectAllowedAt = 0;
  } else if (Date.now() < state.nextReconnectAllowedAt) {
    if (!state.reconnectTimer) {
      scheduleReconnect(Math.max(1000, state.nextReconnectAllowedAt - Date.now()));
    }
    return;
  }

  if (force && state.ws) {
    try {
      state.ws.onopen = null;
      state.ws.onmessage = null;
      state.ws.onerror = null;
      state.ws.onclose = null;
      state.ws.close();
    } catch (_) {}
    state.ws = null;
    state.pendingClientNonce = null;
    state.handshakeKeyBytes = null;
    state.awaitingAuthResult = false;
    if (state.authState === "ready") {
      state.authState = state.hasKey ? "authenticating" : "unpaired";
    }
    stopPingTimer();
  }

  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }

  if (
    state.ws &&
    (state.ws.readyState === WebSocket.OPEN || state.ws.readyState === WebSocket.CONNECTING)
  ) {
    return;
  }

  state.wsState = "connecting";
  let socket;
  try {
    socket = new WebSocket(WS_URL);
  } catch (_) {
    state.wsState = "disconnected";
    if (state.authState === "key_mismatch") {
      state.nextReconnectAllowedAt = Date.now() + KEY_MISMATCH_RETRY_MS;
      scheduleReconnect(KEY_MISMATCH_RETRY_MS);
    } else {
      scheduleReconnect();
    }
    return;
  }

  state.ws = socket;

  socket.onopen = () => {
    if (state.ws !== socket) return;
    state.wsState = "connected";
    state.reconnectAttempts = 0;
    state.lastPongAt = Date.now();
    startPingTimer();
    sendHello(socket);
  };

  socket.onmessage = (event) => {
    if (state.ws !== socket || typeof event.data !== "string") return;
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch (_) {
      return;
    }

    if (msg.type === "pong") {
      state.lastPongAt = Date.now();
      return;
    }

    if (msg.type === "ping") {
      sendWS({ type: "pong", ts: msg.ts ?? Date.now() });
      return;
    }

    if (msg.type === "pairing_required") {
      state.authState = "unpaired";
      state.pendingClientNonce = null;
      state.handshakeKeyBytes = null;
      state.awaitingAuthResult = false;
      return;
    }

    if (msg.type === "challenge") {
      handleChallenge(socket, msg);
      return;
    }

    if (msg.type === "ready") {
      if (state.authState === "authenticating" && state.awaitingAuthResult) {
        state.authState = "ready";
        state.awaitingAuthResult = false;
        state.nextReconnectAllowedAt = 0;
        sendProfileInfo();
      } else if (state.authState === "authenticating") {
        enterKeyMismatch(socket);
      }
      return;
    }

    if (msg.type === "auth_failed") {
      enterKeyMismatch(socket);
      return;
    }

    if (state.authState !== "ready") {
      return;
    }

    if (msg.type === "cancel") {
      handleCancel(msg.tabId ?? null);
      return;
    }

    if (msg.type === "request" && msg.id && msg.command) {
      dispatchDaemonRequest(msg);
    }
  };

  socket.onerror = () => {
    // onclose handles state transition and reconnect scheduling
  };

  socket.onclose = () => {
    if (state.ws !== socket) return;
    state.ws = null;
    state.wsState = "disconnected";
    state.pendingClientNonce = null;
    state.handshakeKeyBytes = null;
    state.awaitingAuthResult = false;
    stopPingTimer();
    if (state.authState === "key_mismatch") {
      state.nextReconnectAllowedAt = Date.now() + KEY_MISMATCH_RETRY_MS;
      scheduleReconnect(KEY_MISMATCH_RETRY_MS);
    } else {
      state.authState = state.hasKey ? "authenticating" : "unpaired";
      scheduleReconnect();
    }
  };
}

function ensureConnected() {
  if (state.reconnectTimer || Date.now() < state.nextReconnectAllowedAt) {
    return;
  }
  if (!state.ws || state.ws.readyState === WebSocket.CLOSED || state.ws.readyState === WebSocket.CLOSING) {
    connectWS();
  }
}

async function sendCDP(tabId, method, params = {}, cdpSessionId = null) {
  const target = cdpSessionId ? { tabId, sessionId: cdpSessionId } : { tabId };
  return chrome.debugger.sendCommand(target, method, params);
}

async function initChildTargetSession(tabId, childSessionId) {
  const session = state.tabSessions.get(tabId);
  if (!session || !session.attached) return;
  const entry = session.childTargets.get(childSessionId);
  if (!entry) return;
  try {
    await sendCDP(tabId, "Runtime.enable", {}, childSessionId);
  } catch (_) {}
  try {
    await sendCDP(tabId, "DOM.enable", {}, childSessionId);
  } catch (_) {}
  try {
    await sendCDP(tabId, "Page.enable", {}, childSessionId);
  } catch (_) {}
  try {
    await sendCDP(tabId, "Target.setAutoAttach", {
      autoAttach: true,
      waitForDebuggerOnStart: false,
      flatten: true
    }, childSessionId);
  } catch (_) {}
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
  session.lastChildFrames = [];
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
      session.lastFrameAt = Date.now();
      const tab = await refreshTabMeta(tabId);
      const viewport = effectiveViewport(session);
      sendWS({
        type: "frame",
        tabId,
        profileName: state.profileName,
        url: tab?.url || session.url,
        title: tab?.title || session.title,
        viewportWidth: viewport.width,
        viewportHeight: viewport.height,
        jpegBase64: res.data
      });
    }
  } catch (_) {
    // Tab may have navigated or detached
  } finally {
    session.captureInFlight = false;
  }
}

function startCapturePump(tabId) {
  const session = getOrCreateTabSession(tabId);
  stopCapturePump(session);
  session.capturePumpTimer = setInterval(() => {
    // A tab the user can see gets its frames from the screencast; polling screenshots there forces repaints.
    if (!session.streaming || !session.attached || session.captureInFlight || session.visibleToUser) {
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
// Chrome does not paint a background tab at a useful size, so a hidden tab gets a metrics override and a screenshot
// pump that keeps the preview fresh. The override is the size the tab last had on screen, so switching away does not
// reflow it (1280x800 for a tab never seen, or an explicit viewport request's size). A tab the
// user is looking at keeps its real window size: no override (forcing 1280 px there leaves white space beside the
// page) and no pump (polling screenshots there forces repaints, which flicker). Its preview comes from the screencast.

function hasExplicitViewport(opts) {
  return opts?.viewportWidth != null || opts?.viewportHeight != null || opts?.deviceScaleFactor != null;
}

// CSS-pixel size and pixel ratio the page lays out into right now: the real window of a visible tab, otherwise the
// emulated metrics.
function effectiveViewport(session) {
  if (session?.liveViewport && !session.metricsOverridden) {
    return session.liveViewport;
  }
  if (session?.liveViewport && session.metricsKeepLiveLayout) {
    // Hidden, but emulating the size it had on screen: same layout, rendered at the override's pixel ratio.
    const zoom = session.liveViewport.zoom || 1;
    return {
      width: session.liveViewport.width,
      height: session.liveViewport.height,
      scale: (session.deviceScaleFactor || 1) * zoom
    };
  }
  return {
    width: session?.viewportWidth || VIEWPORT_WIDTH,
    height: session?.viewportHeight || VIEWPORT_HEIGHT,
    scale: session?.deviceScaleFactor || 1
  };
}

// The user can see a tab when it is the active tab of a window that is not minimized. A failed lookup counts as
// hidden, which keeps the override and the pump.
async function isTabVisibleToUser(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    if (!tab?.active) return false;
    const win = await chrome.windows.get(tab.windowId);
    return Boolean(win) && win.state !== "minimized";
  } catch (_) {
    return false;
  }
}

async function refreshLiveViewport(tabId, session) {
  try {
    const res = await sendCDP(tabId, "Runtime.evaluate", {
      expression: "({ width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio })",
      returnByValue: true
    });
    const v = res?.result?.value;
    if (v && Number(v.width) > 0 && Number(v.height) > 0) {
      // The page zoom turns window pixels into CSS pixels (at 90%, a 1512 px window lays out 1680 px wide).
      let zoom = 1;
      try {
        const z = Number(await chrome.tabs.getZoom(tabId));
        if (z > 0) zoom = z;
      } catch (_) {}
      session.liveViewport = {
        width: Math.round(Number(v.width)),
        height: Math.round(Number(v.height)),
        scale: Number(v.scale) > 0 ? Number(v.scale) : 1,
        zoom
      };
    }
  } catch (_) {}
}

// The metrics a hidden tab is emulated at. An explicit viewport request wins. A tab the user has seen keeps the
// size it had on screen, so leaving it does not reflow the page under the agent or the user. A tab never seen
// gets 1280x800.
function hiddenTabMetrics(session) {
  const live = session.liveViewport;
  if (!session.explicitViewport && live) {
    const zoom = live.zoom || 1;
    const width = Math.round(live.width * zoom);
    const height = Math.round(live.height * zoom);
    const fits = width >= 400 && width <= 3840 && height >= 300 && height <= 2400;
    if (fits) return { width, height, keepsLiveLayout: true };
  }
  return {
    width: session.viewportWidth || VIEWPORT_WIDTH,
    height: session.viewportHeight || VIEWPORT_HEIGHT,
    keepsLiveLayout: false
  };
}

// Puts an attached tab's metrics and capture pump in line with session.visibleToUser.
async function applyVisibilityMetrics(tabId, session) {
  if (session.visibleToUser) {
    stopCapturePump(session);
    await sendCDP(tabId, "Emulation.clearDeviceMetricsOverride");
    session.metricsOverridden = false;
    session.metricsKeepLiveLayout = false;
    await sleep(METRICS_SETTLE_MS);
    await refreshLiveViewport(tabId, session);
    return;
  }
  const metrics = hiddenTabMetrics(session);
  await sendCDP(tabId, "Emulation.setDeviceMetricsOverride", {
    width: metrics.width,
    height: metrics.height,
    deviceScaleFactor: session.deviceScaleFactor || 1,
    mobile: false
  });
  session.metricsOverridden = true;
  session.metricsKeepLiveLayout = metrics.keepsLiveLayout;
  if (session.streaming && !session.capturePumpTimer) {
    startCapturePump(tabId);
  }
}

// Re-checks one attached tab and switches it to the other mode when the user started or stopped seeing it.
// `remeasure` also refreshes a visible tab's window size (resize, or a page with another zoom level).
async function syncTabVisibility(tabId, { remeasure = false } = {}) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached) return;
  const visible = await isTabVisibleToUser(tabId);
  if (state.tabSessions.get(tabId) !== session || !session.attached) return;
  const inMode = visible ? !session.metricsOverridden : session.metricsOverridden;
  if (visible === session.visibleToUser && inMode) {
    if (visible && remeasure) await refreshLiveViewport(tabId, session);
    return;
  }
  session.visibleToUser = visible;
  await applyVisibilityMetrics(tabId, session);
  if (visible && session.streaming) {
    // One fresh frame, so the preview does not keep the hidden-tab layout until the screencast sends one.
    await captureAndEmitFrame(tabId);
  }
}

// Runs in the tab's command queue, so a running command never sees its page reflow halfway. Repeated events
// before it runs collapse into one check.
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

// An explicit viewport request may override a visible tab for one capture; afterwards it gets its real size back.
async function restoreVisibleViewport(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session?.attached || !session.visibleToUser || !session.metricsOverridden) return;
  try {
    await applyVisibilityMetrics(tabId, session);
  } catch (_) {}
}

async function applyViewportMetrics(tabId, width = null, height = null, scale = null) {
  const session = getOrCreateTabSession(tabId);
  const nextW = width != null ? clamp(Math.round(Number(width)), 400, 3840) : session.viewportWidth;
  const nextH = height != null ? clamp(Math.round(Number(height)), 300, 2400) : session.viewportHeight;
  const nextScale = scale != null ? clamp(Number(scale), 1, 3) : session.deviceScaleFactor;

  if (
    session.attached &&
    session.metricsOverridden &&
    session.explicitViewport &&
    nextW === session.viewportWidth &&
    nextH === session.viewportHeight &&
    Math.abs(nextScale - session.deviceScaleFactor) < 0.01
  ) {
    return;
  }

  session.viewportWidth = nextW;
  session.viewportHeight = nextH;
  session.deviceScaleFactor = nextScale;
  // From now on this size is also the tab's hidden size, as before (see hiddenTabMetrics).
  session.explicitViewport = true;
  session.metricsKeepLiveLayout = false;

  if (session.attached) {
    await sendCDP(tabId, "Emulation.setDeviceMetricsOverride", {
      width: nextW,
      height: nextH,
      deviceScaleFactor: nextScale,
      mobile: false
    });
    session.metricsOverridden = true;
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
  await assertTabScriptable(tabId);

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
  await refreshTabMeta(tabId);

  await sendCDP(tabId, "Page.enable");
  await sendCDP(tabId, "Runtime.enable");
  await sendCDP(tabId, "DOM.enable");
  try {
    await sendCDP(tabId, "Target.setAutoAttach", {
      autoAttach: true,
      waitForDebuggerOnStart: false,
      flatten: true
    });
  } catch (_) {
    // Non-fatal on older Chrome builds without flattened OOPIF auto-attach
  }
  session.visibleToUser = await isTabVisibleToUser(tabId);
  await applyVisibilityMetrics(tabId, session);
  await sendCDP(tabId, "Emulation.setFocusEmulationEnabled", { enabled: true });
  // Give already-loaded OOPIF targets a brief moment to emit Target.attachedToTarget
  await sleep(35);
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
    await captureAndEmitFrame(tabId);
  }
  resetIdleTimer(tabId);
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (!source || source.tabId == null) {
    return;
  }
  const session = state.tabSessions.get(source.tabId);
  if (!session || !session.attached) {
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
  if (method === "Page.screencastFrame" && !source.sessionId && params?.data) {
    const sessionId = params.sessionId;
    if (sessionId !== undefined) {
      sendCDP(source.tabId, "Page.screencastFrameAck", { sessionId }).catch(() => {});
    }
    session.lastFrameAt = Date.now();
    const viewport = effectiveViewport(session);
    sendWS({
      type: "frame",
      tabId: source.tabId,
      profileName: state.profileName,
      url: session.url,
      title: session.title,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      jpegBase64: params.data
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

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const session = state.tabSessions.get(tabId);
  if (session && (changeInfo.url || changeInfo.title || tab)) {
    session.url = tab?.url || changeInfo.url || session.url;
    session.title = tab?.title || changeInfo.title || session.title;
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
  const session = state.tabSessions.get(tabId);
  if (session) {
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

  await sleep(160);
  // Brief SPA mount settle if debugger is already attached and body is still sparse
  const session = state.tabSessions.get(tabId);
  if (session?.attached) {
    const settleDeadline = Date.now() + 700;
    while (Date.now() < settleDeadline) {
      try {
        const probe = await sendCDP(tabId, "Runtime.evaluate", {
          expression: `(() => {
            const len = (document.body?.innerText || '').trim().length;
            const busy = Boolean(document.querySelector('[aria-busy="true"], [role="progressbar"]'));
            return { len, busy };
          })()`,
          returnByValue: true
        });
        const v = probe?.result?.value;
        if (v && v.len >= 60 && !v.busy) break;
      } catch (_) {
        break;
      }
      await sleep(140);
    }
  }
  return refreshTabMeta(tabId);
}

const USEMAC_GROUP_TITLE = "UseMac";
const USEMAC_GROUP_COLOR = "blue";

async function findUsemacGroupInWindow(windowId) {
  if (!chrome.tabGroups?.query || windowId == null) return null;
  try {
    const groups = await chrome.tabGroups.query({ windowId, title: USEMAC_GROUP_TITLE });
    return groups && groups.length > 0 ? groups[0] : null;
  } catch (_) {
    return null;
  }
}

async function ensureTabInUsemacGroup(tabId) {
  if (tabId == null || !chrome.tabs?.group || !chrome.tabGroups?.update) {
    return;
  }
  try {
    const tab = await chrome.tabs.get(tabId);
    if (!tab || tab.pinned || tab.windowId == null) {
      return;
    }
    const existingGroup = await findUsemacGroupInWindow(tab.windowId);
    if (existingGroup) {
      if (tab.groupId === existingGroup.id) {
        return;
      }
      await chrome.tabs.group({ groupId: existingGroup.id, tabIds: [tabId] });
      return;
    }
    const groupId = await chrome.tabs.group({
      createProperties: { windowId: tab.windowId },
      tabIds: [tabId]
    });
    if (groupId != null && groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE) {
      await chrome.tabGroups.update(groupId, {
        title: USEMAC_GROUP_TITLE,
        color: USEMAC_GROUP_COLOR,
        collapsed: false
      });
    }
  } catch (_) {
    // Non-fatal: tab may be closing, pinned, or in a popup window that disallows tab groups
  }
}

async function resolveTargetTab(requestedTabId) {
  if (requestedTabId != null) {
    const tab = await chrome.tabs.get(requestedTabId);
    return tab;
  }
  if (state.lastTabId != null) {
    try {
      return await chrome.tabs.get(state.lastTabId);
    } catch (_) {
      state.lastTabId = null;
    }
  }
  if (chrome.tabGroups?.query) {
    try {
      const groups = await chrome.tabGroups.query({ title: USEMAC_GROUP_TITLE });
      if (groups && groups.length > 0) {
        for (const group of groups) {
          const groupTabs = await chrome.tabs.query({ groupId: group.id });
          const candidate = groupTabs?.find((t) => t.active) || groupTabs?.[groupTabs.length - 1];
          if (candidate) {
            return candidate;
          }
        }
      }
    } catch (_) {}
  }
  throw {
    code: "NO_USEMAC_TAB",
    message: "No UseMac tab is open. Call browser_open first, or pass a tabId from browser_tabs."
  };
}

function assertAllowedUrl(url) {
  if (typeof url !== "string") {
    throw URL_BLOCKED_ERROR;
  }
  if (url === "about:blank") {
    return url;
  }
  let parsed;
  try {
    parsed = new URL(url);
  } catch (_) {
    throw URL_BLOCKED_ERROR;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw URL_BLOCKED_ERROR;
  }
  return url;
}

// --- Restricted pages -------------------------------------------------------------------------------------------
// Chrome refuses chrome.debugger.attach (and therefore every CDP command UseMac uses) on browser-internal pages,
// extension stores and, without "Allow access to file URLs", file:// pages. chrome.tabs.* and chrome.windows.* still
// work there, so navigation and tab activation keep working; observe/extract/screenshot/act answer RESTRICTED_PAGE.

// Schemes the debugger may attach to. Every other scheme (chrome:, chrome-extension:, devtools:, view-source:,
// edge:, brave:, ...) is browser-internal. about: is special-cased below.
const SCRIPTABLE_SCHEMES = new Set(["http:", "https:", "data:", "blob:", "filesystem:", "chrome-error:"]);

// Extension stores. `browsers: null` means every Chromium browser refuses it. Chrome treats the whole
// chrome.google.com host as the legacy Web Store origin, including /webstore/devconsole.
const EXTENSION_STORE_HOSTS = [
  { host: "chrome.google.com", browsers: null },
  { host: "chromewebstore.google.com", browsers: null },
  { host: "microsoftedge.microsoft.com", browsers: ["edge"] },
  { host: "addons.opera.com", browsers: ["opera"] }
];

const RESTRICTED_REASON_TEXT = {
  extension_store: "extension store page",
  browser_page: "browser-internal page",
  file_access: "file:// page without file URL access",
  policy: "blocked for extensions by browser policy",
  refused: "Chrome refused to let the extension script it"
};

// Error strings Chrome returns from chrome.debugger.attach / sendCommand on pages extensions may not script.
const RESTRICTED_ERROR_PATTERNS = [
  /cannot be scripted/i,
  /Cannot access a [a-z][a-z0-9+.-]*:(\/\/)? ?URL/i,
  /Cannot attach to this target/i,
  /Cannot access contents of (the page|url)/i
];

// Errors that only mean "the debugger went away"; they point at a restricted page when the tab is now on one.
const DETACHED_ERROR_PATTERNS = [/Debugger is not attached/i, /Detached while handling command/i, /target closed/i];

function detectBrowserFlavor(nav = typeof navigator !== "undefined" ? navigator : null) {
  const ua = String(nav?.userAgent || "");
  if (/\bEdg(e|A|iOS)?\//.test(ua)) return "edge";
  if (/\bOPR\//.test(ua)) return "opera";
  if (nav?.brave && typeof nav.brave.isBrave === "function") return "brave";
  return "chrome";
}

const BROWSER_FLAVOR = detectBrowserFlavor();
const BROWSER_APP_NAMES = { chrome: "Google Chrome", edge: "Microsoft Edge", brave: "Brave Browser", opera: "Opera" };

function hostMatchesDomain(host, domain) {
  return host === domain || host.endsWith(`.${domain}`);
}

// Returns null when the debugger can script `url`, otherwise a reason key from RESTRICTED_REASON_TEXT.
// options.fileAccess: whether the user allowed file URL access; options.browser: "chrome" | "edge" | "opera" | "brave".
function restrictedPageReason(url, options = {}) {
  if (typeof url !== "string" || url.trim() === "") {
    return null;
  }
  let parsed;
  try {
    parsed = new URL(url.trim());
  } catch (_) {
    return null;
  }
  const protocol = parsed.protocol.toLowerCase();
  if (protocol === "http:" || protocol === "https:") {
    const host = parsed.hostname.toLowerCase().replace(/\.$/, "");
    const browser = options.browser || BROWSER_FLAVOR;
    for (const store of EXTENSION_STORE_HOSTS) {
      if (store.browsers && !store.browsers.includes(browser)) continue;
      if (hostMatchesDomain(host, store.host)) return "extension_store";
    }
    return null;
  }
  if (protocol === "about:") {
    const page = parsed.pathname.toLowerCase();
    return page === "blank" || page === "srcdoc" ? null : "browser_page";
  }
  if (protocol === "file:") {
    return options.fileAccess === true ? null : "file_access";
  }
  return SCRIPTABLE_SCHEMES.has(protocol) ? null : "browser_page";
}

function isRestrictedChromeError(errOrMessage) {
  const msg = typeof errOrMessage === "string" ? errOrMessage : errOrMessage?.message;
  return typeof msg === "string" && RESTRICTED_ERROR_PATTERNS.some((re) => re.test(msg));
}

async function fileSchemeAccessAllowed() {
  try {
    if (typeof chrome.extension?.isAllowedFileSchemeAccess === "function") {
      return (await chrome.extension.isAllowedFileSchemeAccess()) === true;
    }
  } catch (_) {}
  return false;
}

// A tab that is navigating reports its destination in pendingUrl; that is the page any command would hit.
function effectiveTabUrl(tab) {
  return tab?.pendingUrl || tab?.url || "";
}

async function tabRestrictionReason(tab) {
  const url = effectiveTabUrl(tab);
  if (!url) return null;
  const fileAccess = /^file:/i.test(url) ? await fileSchemeAccessAllowed() : false;
  return restrictedPageReason(url, { fileAccess });
}

async function getTabOrNull(tabId) {
  if (tabId == null) return null;
  try {
    return (await chrome.tabs.get(tabId)) || null;
  } catch (_) {
    return null;
  }
}

function restrictedPageGuidance(tab) {
  const tabId = tab?.id ?? null;
  const url = effectiveTabUrl(tab);
  const tabRef = tabId != null ? String(tabId) : "<tabId>";
  const appName = BROWSER_APP_NAMES[BROWSER_FLAVOR] || "Google Chrome";
  let text;
  if (tab?.active) {
    text = `use native observe/act with app "${appName}": it is already the active tab of its window, and native observe only sees the active tab of each window.`;
  } else {
    text = `make it the active tab of its window with browser_open {"tabId":${tabRef},"url":"","activate":true}`;
    if (/^https?:/i.test(url)) {
      text += ` (or open it in a separate UseMac window with browser_open ${JSON.stringify({ url, newWindow: true })})`;
    }
    text += `, then use native observe/act with app "${appName}" (native observe only sees the active tab of each window).`;
  }
  text += ` To leave the page, call browser_open with this tabId and another URL.`;
  return text;
}

function restrictedPageError(tab, reason, chromeMessage = null) {
  const tabId = tab?.id ?? null;
  const url = effectiveTabUrl(tab);
  const what = RESTRICTED_REASON_TEXT[reason] || RESTRICTED_REASON_TEXT.refused;
  let message = `Chrome does not allow extensions to script this page (${what}${url ? `: ${url}` : ""})`;
  message += tabId != null ? `, so tab ${tabId} cannot be observed or operated through the extension.` : ".";
  message += ` To work on it, ${restrictedPageGuidance(tab)}`;
  if (reason === "file_access") {
    message += ` Alternatively enable "Allow access to file URLs" for UseMac Browser Bridge in chrome://extensions.`;
  }
  if (chromeMessage) {
    message += ` (Chrome: ${chromeMessage})`;
  }
  return { code: "RESTRICTED_PAGE", message };
}

function restrictedReasonFromChromeMessage(msg) {
  if (/policy/i.test(msg)) return "policy";
  if (/extensions gallery/i.test(msg)) return "extension_store";
  if (/Cannot access a [a-z]/i.test(msg)) return "browser_page";
  return null;
}

// Turns a raw Chrome error into RESTRICTED_PAGE when it comes from a page extensions may not script.
// Errors UseMac threw itself (objects with a code) pass through unchanged.
async function toRestrictedPageErrorIfNeeded(err, tabId) {
  if (!err || err.code === "RESTRICTED_PAGE" || (typeof err.code === "string" && err.code !== "EXTENSION_ERROR")) {
    return err;
  }
  const msg = typeof err === "string" ? err : String(err.message || err);
  const restrictedError = isRestrictedChromeError(msg);
  const detached = !restrictedError && DETACHED_ERROR_PATTERNS.some((re) => re.test(msg));
  if (!restrictedError && !detached) {
    return err;
  }
  const tab = await getTabOrNull(tabId);
  const urlReason = tab ? await tabRestrictionReason(tab) : null;
  if (restrictedError) {
    return restrictedPageError(tab || (tabId != null ? { id: tabId } : null), urlReason || restrictedReasonFromChromeMessage(msg) || "refused", msg);
  }
  return urlReason ? restrictedPageError(tab, urlReason) : err;
}

// Throws RESTRICTED_PAGE before anything attaches the debugger to (or groups) a tab Chrome will not let us script.
async function assertTabScriptable(tabId) {
  const tab = await getTabOrNull(tabId);
  if (!tab) return null;
  const reason = await tabRestrictionReason(tab);
  if (reason) {
    throw restrictedPageError(tab, reason);
  }
  return tab;
}

function restrictedPageFeedback(tab, reason, { activated = false } = {}) {
  const what = RESTRICTED_REASON_TEXT[reason] || RESTRICTED_REASON_TEXT.refused;
  const url = effectiveTabUrl(tab);
  const tabRef = tab?.id != null ? `Tab ${tab.id}` : "This tab";
  const diagnosis = `${tabRef} is on a page Chrome does not let extensions script (${what}${url ? `: ${url}` : ""}). ` +
    `browser_observe, browser_extract, browser_screenshot and browser_act will answer RESTRICTED_PAGE there; ` +
    `navigation and tab activation still work.`;
  const appName = BROWSER_APP_NAMES[BROWSER_FLAVOR] || "Google Chrome";
  const suggestedAction = activated
    ? `The tab is now the active tab of its window. Use native observe/act with app "${appName}" to work on it. To leave the page, call browser_open with this tabId and another URL.`
    : `To work on it, ${restrictedPageGuidance(tab)}`;
  return {
    severity: "warning",
    trigger: "restricted_page",
    diagnosis,
    suggestedAction,
    source: "chrome-extension",
    latencyMs: 0
  };
}

// openURL/navigate use chrome.tabs.update and a plain wait only sleeps; every other step talks to the debugger.
function stepNeedsDebugger(step) {
  const action = step?.action;
  if (action === "openURL" || action === "navigate") return false;
  if (action === "wait") return Boolean(step.selector || step.text);
  return true;
}

// Chrome force-detaches the debugger when a tab commits a restricted page. Returns RESTRICTED_PAGE in that state
// (so steps say why instead of "Element not found"), otherwise null.
async function restrictedPageErrorIfDetached(tabId) {
  if (state.tabSessions.get(tabId)?.attached) return null;
  const tab = await getTabOrNull(tabId);
  const reason = tab ? await tabRestrictionReason(tab) : null;
  return reason ? restrictedPageError(tab, reason) : null;
}

// Stand-in for an observation on pages the extension cannot read: no elements, only the guidance above.
function restrictedPageSnapshot(tab, reason, options = {}) {
  return {
    app: {
      pid: 0,
      name: `Chrome (${state.profileName})`,
      bundleId: "com.google.Chrome",
      isActive: false,
      isHidden: false,
      windowTitle: tab?.title || ""
    },
    timestampMs: Date.now(),
    latencyMs: 0,
    fromHotCache: false,
    focusedElementId: null,
    elements: [],
    pageState: null,
    agentFeedback: restrictedPageFeedback(tab, reason, options)
  };
}

const QUERY_DEEP_HELPER_JS = `
function queryAllDeep(root, sel, maxRoots = 140) {
  const out = [];
  const seenNodes = new Set();
  const visited = new Set();
  const queue = [root];
  while (queue.length > 0 && visited.size < maxRoots) {
    const cur = queue.shift();
    if (!cur || visited.has(cur)) continue;
    visited.add(cur);
    try {
      const matched = cur.querySelectorAll(sel);
      for (let i = 0; i < matched.length; i++) {
        if (!seenNodes.has(matched[i])) {
          seenNodes.add(matched[i]);
          out.push(matched[i]);
        }
      }
    } catch (_) {}
    try {
      const all = cur.querySelectorAll('*');
      for (let i = 0; i < all.length && visited.size + queue.length < maxRoots; i++) {
        if (all[i].shadowRoot && !visited.has(all[i].shadowRoot)) {
          queue.push(all[i].shadowRoot);
        }
      }
    } catch (_) {}
  }
  return out;
}

function queryOneDeep(root, sel, maxRoots = 140) {
  try {
    const direct = root.querySelector(sel);
    if (direct) return direct;
  } catch (_) {}
  const visited = new Set([root]);
  const queue = [];
  try {
    const all = root.querySelectorAll('*');
    for (let i = 0; i < all.length && queue.length < maxRoots; i++) {
      if (all[i].shadowRoot) queue.push(all[i].shadowRoot);
    }
  } catch (_) {}
  while (queue.length > 0 && visited.size < maxRoots) {
    const cur = queue.shift();
    if (!cur || visited.has(cur)) continue;
    visited.add(cur);
    try {
      const hit = cur.querySelector(sel);
      if (hit) return hit;
    } catch (_) {}
    try {
      const all = cur.querySelectorAll('*');
      for (let i = 0; i < all.length && visited.size + queue.length < maxRoots; i++) {
        if (all[i].shadowRoot && !visited.has(all[i].shadowRoot)) {
          queue.push(all[i].shadowRoot);
        }
      }
    } catch (_) {}
  }
  return null;
}

function getDeepActiveElement() {
  let active = document.activeElement;
  while (active && active.shadowRoot && active.shadowRoot.activeElement) {
    active = active.shadowRoot.activeElement;
  }
  return active;
}
`;

async function evalInFrame(tabId, frameMeta, expression, opts = {}) {
  const cdpSessionId = frameMeta?.sessionId || null;
  const params = {
    expression,
    returnByValue: opts.returnByValue !== false,
    awaitPromise: opts.awaitPromise === true
  };
  if (frameMeta?.contextId != null) {
    params.contextId = frameMeta.contextId;
  }
  return sendCDP(tabId, "Runtime.evaluate", params, cdpSessionId);
}

async function getFrameOwnerRect(tabId, frameId, parentSessionId = null, fallbackUrl = "", scrollOwnerIntoView = false) {
  let owner = null;
  if (frameId) {
    try {
      owner = await sendCDP(tabId, "DOM.getFrameOwner", { frameId }, parentSessionId);
    } catch (_) {
      try {
        await sendCDP(tabId, "DOM.getDocument", { depth: 0 }, parentSessionId);
        owner = await sendCDP(tabId, "DOM.getFrameOwner", { frameId }, parentSessionId);
      } catch (_) {}
    }
  }

  if (owner?.backendNodeId != null) {
    let objectId = null;
    try {
      const resolved = await sendCDP(tabId, "DOM.resolveNode", { backendNodeId: owner.backendNodeId }, parentSessionId);
      objectId = resolved?.object?.objectId || null;
      if (objectId) {
        const res = await sendCDP(tabId, "Runtime.callFunctionOn", {
          objectId,
          arguments: [{ value: Boolean(scrollOwnerIntoView) }],
          functionDeclaration: `function(scrollIfHidden) {
            if (scrollIfHidden) {
              const ir = this.getBoundingClientRect();
              if (ir.bottom < 0 || ir.top > window.innerHeight || ir.right < 0 || ir.left > window.innerWidth) {
                try { this.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (_) {}
              }
            }
            let cur = this;
            let x = 0;
            let y = 0;
            let width = 0;
            let height = 0;
            let first = true;
            let visible = true;
            const title = (this.getAttribute && (this.getAttribute('title') || this.getAttribute('aria-label') || this.name)) || '';
            while (cur) {
              const win = cur.ownerDocument?.defaultView || window;
              const cs = win.getComputedStyle(cur);
              const r = cur.getBoundingClientRect();
              if (!cs || cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0 || r.width < 2 || r.height < 2) {
                visible = false;
                break;
              }
              const bl = parseFloat(cs.borderLeftWidth) || 0;
              const bt = parseFloat(cs.borderTopWidth) || 0;
              const pl = parseFloat(cs.paddingLeft) || 0;
              const pt = parseFloat(cs.paddingTop) || 0;
              x += r.left + bl + pl;
              y += r.top + bt + pt;
              if (first) {
                width = r.width;
                height = r.height;
                first = false;
              }
              try {
                cur = win.frameElement || null;
              } catch (_) {
                cur = null;
              }
            }
            return { visible: visible && width >= 24 && height >= 20, x, y, width, height, title };
          }`,
          returnByValue: true
        }, parentSessionId);
        if (res?.result?.value) {
          return res.result.value;
        }
      }
    } catch (_) {
    } finally {
      if (objectId) {
        sendCDP(tabId, "Runtime.releaseObject", { objectId }, parentSessionId).catch(() => {});
      }
    }
  }

  // Fallback: match visible <iframe> in parentSessionId by URL/origin
  if (fallbackUrl && fallbackUrl !== "about:blank") {
    const urlLit = JSON.stringify(String(fallbackUrl));
    try {
      const fb = await sendCDP(tabId, "Runtime.evaluate", {
        expression: `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const wanted = ${urlLit};
          let wantedOrigin = '';
          try { wantedOrigin = new URL(wanted).origin; } catch (_) {}
          const iframes = queryAllDeep(document, 'iframe');
          let best = null;
          let bestScore = -1;
          for (let i = 0; i < iframes.length; i++) {
            const f = iframes[i];
            const cs = window.getComputedStyle(f);
            const r = f.getBoundingClientRect();
            if (!cs || cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0) continue;
            if (r.width < 24 || r.height < 20) continue;
            const src = f.src || f.getAttribute('src') || '';
            let score = 0;
            if (src === wanted) score = 10;
            else if (wanted && src && (wanted.startsWith(src) || src.startsWith(wanted))) score = 7;
            else if (wantedOrigin && src.startsWith(wantedOrigin)) score = 4;
            if (score > bestScore) {
              bestScore = score;
              const bl = parseFloat(cs.borderLeftWidth) || 0;
              const bt = parseFloat(cs.borderTopWidth) || 0;
              const pl = parseFloat(cs.paddingLeft) || 0;
              const pt = parseFloat(cs.paddingTop) || 0;
              best = {
                visible: true,
                x: r.left + bl + pl,
                y: r.top + bt + pt,
                width: r.width,
                height: r.height,
                title: f.getAttribute('title') || f.getAttribute('aria-label') || f.name || ''
              };
            }
          }
          return bestScore >= 4 ? best : null;
        })()`,
        returnByValue: true
      }, parentSessionId);
      if (fb?.result?.value) {
        return fb.result.value;
      }
    } catch (_) {}
  }

  return null;
}

async function computeFrameViewportRect(tabId, frameMeta, scrollOwnerIntoView = false) {
  if (!frameMeta || !Array.isArray(frameMeta.hops) || frameMeta.hops.length === 0) {
    return { visible: true, x: 0, y: 0, width: 0, height: 0, title: "" };
  }
  let totalX = 0;
  let totalY = 0;
  let lastW = 0;
  let lastH = 0;
  let lastTitle = "";
  for (let i = 0; i < frameMeta.hops.length; i++) {
    const hop = frameMeta.hops[i];
    const rect = await getFrameOwnerRect(
      tabId,
      hop.frameId,
      hop.parentSessionId,
      hop.url || "",
      scrollOwnerIntoView && i === frameMeta.hops.length - 1
    );
    if (!rect || !rect.visible) {
      return {
        visible: false,
        x: frameMeta.offsetX || totalX,
        y: frameMeta.offsetY || totalY,
        width: frameMeta.width || lastW,
        height: frameMeta.height || lastH,
        title: lastTitle
      };
    }
    totalX += rect.x;
    totalY += rect.y;
    lastW = rect.width;
    lastH = rect.height;
    lastTitle = rect.title || lastTitle;
  }
  frameMeta.offsetX = totalX;
  frameMeta.offsetY = totalY;
  frameMeta.width = lastW;
  frameMeta.height = lastH;
  return { visible: true, x: totalX, y: totalY, width: lastW, height: lastH, title: lastTitle };
}

async function resolveSameOriginContextId(tabId, session, cdpSessionId, frameId) {
  const key = `${cdpSessionId || "top"}:${frameId}`;
  const cached = session.executionContexts.get(key);
  if (cached != null) {
    return cached;
  }
  try {
    const world = await sendCDP(tabId, "Page.createIsolatedWorld", {
      frameId,
      worldName: "usemac",
      grantUniveralAccess: false
    }, cdpSessionId);
    if (world?.executionContextId != null) {
      return world.executionContextId;
    }
  } catch (_) {}
  return null;
}

async function discoverChildFrames(tabId) {
  const session = state.tabSessions.get(tabId);
  if (!session || !session.attached) return [];

  // Ensure any recently attached OOPIF targets have enabled Runtime/DOM
  const pendingInits = [];
  for (const entry of session.childTargets.values()) {
    if (!entry.ready && entry.initPromise) {
      pendingInits.push(entry.initPromise);
    }
  }
  if (pendingInits.length > 0) {
    await Promise.race([Promise.allSettled(pendingInits), sleep(450)]);
  }

  const discovered = [];
  const visitedFrameIds = new Set();
  const MAX_FRAMES = 14;
  const MAX_DEPTH = 4;

  async function walkSession(cdpSessionId, parentOffsetX, parentOffsetY, parentHops, depth) {
    if (depth > MAX_DEPTH || discovered.length >= MAX_FRAMES) return;

    // 1. Cross-origin OOPIFs whose direct parent target is cdpSessionId
    const directOopifs = Array.from(session.childTargets.values()).filter(
      (t) => (t.parentSessionId || null) === (cdpSessionId || null)
    );
    for (const oopif of directOopifs) {
      if (discovered.length >= MAX_FRAMES) break;
      if (oopif.url && (oopif.url.startsWith("chrome-extension://") || oopif.url.startsWith("devtools://"))) {
        continue;
      }
      if (oopif.targetId) visitedFrameIds.add(oopif.targetId);
      const rect = await getFrameOwnerRect(tabId, oopif.targetId, cdpSessionId, oopif.url, false);
      if (!rect || !rect.visible || rect.width < 32 || rect.height < 20) {
        continue;
      }
      const absX = parentOffsetX + rect.x;
      const absY = parentOffsetY + rect.y;
      const hops = [...parentHops, { frameId: oopif.targetId, parentSessionId: cdpSessionId, url: oopif.url || "" }];
      const frameMeta = {
        sessionId: oopif.sessionId,
        contextId: null,
        frameId: oopif.targetId,
        parentSessionId: cdpSessionId,
        offsetX: absX,
        offsetY: absY,
        width: rect.width,
        height: rect.height,
        url: oopif.url || "",
        title: rect.title || oopif.title || "",
        isOOPIF: true,
        hops
      };
      discovered.push(frameMeta);
      await walkSession(oopif.sessionId, absX, absY, hops, depth + 1);
    }

    // 2. Same-origin child frames inside cdpSessionId via Page.getFrameTree
    let frameTree = null;
    try {
      const ftRes = await sendCDP(tabId, "Page.getFrameTree", {}, cdpSessionId);
      frameTree = ftRes?.frameTree || null;
    } catch (_) {}

    if (frameTree && Array.isArray(frameTree.childFrames)) {
      const queue = [...frameTree.childFrames];
      while (queue.length > 0 && discovered.length < MAX_FRAMES) {
        const node = queue.shift();
        if (!node || !node.frame) continue;
        if (Array.isArray(node.childFrames)) {
          for (const child of node.childFrames) queue.push(child);
        }
        const f = node.frame;
        if (!f.id || visitedFrameIds.has(f.id)) continue;
        visitedFrameIds.add(f.id);
        if (f.url && (f.url.startsWith("chrome-extension://") || f.url.startsWith("devtools://"))) {
          continue;
        }
        const rect = await getFrameOwnerRect(tabId, f.id, cdpSessionId, f.url || "", false);
        if (!rect || !rect.visible || rect.width < 32 || rect.height < 20) {
          continue;
        }
        const contextId = await resolveSameOriginContextId(tabId, session, cdpSessionId, f.id);
        if (contextId == null) continue;
        const absX = parentOffsetX + rect.x;
        const absY = parentOffsetY + rect.y;
        const hops = [...parentHops, { frameId: f.id, parentSessionId: cdpSessionId, url: f.url || "" }];
        discovered.push({
          sessionId: cdpSessionId,
          contextId,
          frameId: f.id,
          parentSessionId: cdpSessionId,
          offsetX: absX,
          offsetY: absY,
          width: rect.width,
          height: rect.height,
          url: f.url || "",
          title: rect.title || f.name || "",
          isOOPIF: false,
          hops
        });
      }
    }
  }

  await walkSession(null, 0, 0, [], 0);
  // Sort largest visible frames first so main workspace iframes (e.g. OCI console) get priority budget
  discovered.sort((a, b) => (b.width * b.height) - (a.width * a.height));
  session.lastChildFrames = discovered;
  return discovered;
}

function buildFrameIndexExpression({
  startIndex = 1,
  limit = 280,
  includeText = true,
  includeTables = true,
  curVpW = VIEWPORT_WIDTH,
  curVpH = VIEWPORT_HEIGHT,
  isTopFrame = true,
  offsetX = 0,
  offsetY = 0
}) {
  return `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const startIndex = ${startIndex};
      const limit = ${limit};
      const includeText = ${includeText ? "true" : "false"};
      const includeTables = ${includeTables ? "true" : "false"};
      const isTopFrame = ${isTopFrame ? "true" : "false"};
      const offsetX = ${Number(offsetX) || 0};
      const offsetY = ${Number(offsetY) || 0};

      const prev = queryAllDeep(document, '[data-usemac-id]');
      for (let i = 0; i < prev.length; i++) {
        prev[i].removeAttribute('data-usemac-id');
      }

      const selector = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [contenteditable="true"], summary, h1, h2, h3';
      const nodes = queryAllDeep(document, selector);
      const elements = [];
      let focusedElementId = null;
      const activeEl = getDeepActiveElement();

      function mapRole(el) {
        const tag = el.tagName.toLowerCase();
        const ariaRole = (el.getAttribute('role') || '').toLowerCase();
        if (tag === 'a' || ariaRole === 'link') return 'AXLink';
        if (ariaRole === 'checkbox' || ariaRole === 'switch' || ariaRole === 'menuitemcheckbox') return 'AXCheckBox';
        if (ariaRole === 'radio' || ariaRole === 'tab' || ariaRole === 'menuitemradio') return 'AXRadioButton';
        if (ariaRole === 'combobox' || ariaRole === 'listbox' || tag === 'select') return 'AXPopUpButton';
        if (ariaRole === 'menuitem' || ariaRole === 'option' || ariaRole === 'treeitem') return 'AXMenuItem';
        if (ariaRole === 'slider') return 'AXSlider';
        if (ariaRole === 'spinbutton') return 'AXTextField';
        if (tag === 'button' || tag === 'summary' || ariaRole === 'button') return 'AXButton';
        if (tag === 'h1' || tag === 'h2' || tag === 'h3') return 'AXHeading';
        if (tag === 'input') {
          const t = (el.type || 'text').toLowerCase();
          if (t === 'file') return 'AXFileUpload';
          if (t === 'checkbox') return 'AXCheckBox';
          if (t === 'radio') return 'AXRadioButton';
          if (t === 'button' || t === 'submit' || t === 'reset') return 'AXButton';
          return 'AXTextField';
        }
        if (tag === 'textarea' || el.isContentEditable) return 'AXTextField';
        return 'AXGroup';
      }

      function mapActions(role) {
        if (role === 'AXTextField') return ['AXConfirm', 'AXSetValue'];
        if (role === 'AXHeading') return [];
        return ['AXPress'];
      }

      function cleanText(str, maxLen = 140) {
        if (!str) return null;
        const s = String(str).replace(/\\s+/g, ' ').trim();
        if (!s) return null;
        return s.length > maxLen ? s.slice(0, maxLen) + '...' : s;
      }

      function isVisibleRect(el, rect) {
        const style = window.getComputedStyle(el);
        if (!style || style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) === 0) {
          return false;
        }
        if (!rect || rect.width < 2 || rect.height < 2) return false;
        if (el.getClientRects().length === 0) return false;
        return true;
      }

      function addElement(el, forcedRole = null, forcedTitle = null) {
        const existingId = el.getAttribute('data-usemac-id');
        if (existingId) return existingId;
        const rect = el.getBoundingClientRect();
        if (!isVisibleRect(el, rect)) return null;

        const id = '@b' + (startIndex + elements.length);
        el.setAttribute('data-usemac-id', id);

        const role = forcedRole || mapRole(el);
        const tag = el.tagName.toLowerCase();
        const isFocused = activeEl === el;
        if (isFocused) focusedElementId = id;

        let labelFromFor = null;
        if (!forcedTitle && (tag === 'input' || tag === 'textarea' || tag === 'select') && el.id) {
          const lbl = queryOneDeep(document, 'label[for="' + el.id.replace(/["\\\\]/g, '\\\\$&') + '"]');
          if (lbl) labelFromFor = lbl.innerText || lbl.textContent;
        }
        let labelFromAriaBy = null;
        const ariaBy = el.getAttribute('aria-labelledby');
        if (!forcedTitle && ariaBy) {
          const parts = ariaBy.split(/\\s+/).map((rid) => document.getElementById(rid)?.innerText || '').filter(Boolean);
          if (parts.length > 0) labelFromAriaBy = parts.join(' ');
        }

        const title = forcedTitle || cleanText(
          el.getAttribute('aria-label') ||
          labelFromAriaBy ||
          el.innerText ||
          el.textContent ||
          labelFromFor ||
          el.getAttribute('placeholder') ||
          el.getAttribute('title') ||
          el.getAttribute('alt') ||
          el.getAttribute('name')
        );

        let value = null;
        if (tag === 'select') {
          const selectedOpt = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
          const optLabel = selectedOpt ? (selectedOpt.text || selectedOpt.value || '').trim() : (el.value || '');
          value = optLabel !== '' ? String(optLabel) : null;
        } else if (tag === 'input' || tag === 'textarea') {
          const acAttr = (el.getAttribute('autocomplete') || '').toLowerCase();
          const acTokens = acAttr ? acAttr.split(/\\s+/) : [];
          const isSensitiveAutocomplete = acTokens.some((tok) =>
            tok === 'cc-number' ||
            tok === 'cc-csc' ||
            tok === 'cc-exp' ||
            tok === 'cc-exp-month' ||
            tok === 'cc-exp-year' ||
            tok === 'one-time-code' ||
            tok === 'current-password' ||
            tok === 'new-password'
          );
          if (el.type === 'password' || isSensitiveAutocomplete) {
            value = el.value ? '••••' : null;
          } else if (el.type === 'checkbox' || el.type === 'radio') {
            value = el.checked ? 'checked=true' : 'checked=false';
          } else if (el.type === 'file') {
            const parts = [];
            if (el.files && el.files.length > 0) {
              parts.push('files=' + Array.from(el.files).map((f) => f.name).join(','));
            }
            if (el.accept) parts.push('accept=' + el.accept);
            if (el.multiple) parts.push('multiple=true');
            value = parts.length > 0 ? parts.join(';') : null;
          } else {
            value = el.value !== '' ? String(el.value) : null;
          }
        } else if (el.isContentEditable) {
          value = cleanText(el.innerText, 200);
        } else {
          const states = [];
          const ariaChecked = el.getAttribute('aria-checked');
          const ariaSelected = el.getAttribute('aria-selected');
          const ariaExpanded = el.getAttribute('aria-expanded');
          const ariaValueNow = el.getAttribute('aria-valuenow');
          if (ariaChecked != null) states.push('checked=' + ariaChecked);
          if (ariaSelected === 'true') states.push('selected=true');
          if (ariaExpanded != null) states.push('expanded=' + ariaExpanded);
          if (ariaValueNow != null) states.push('val=' + ariaValueNow);
          if (states.length > 0) value = states.join(',');
        }

        const enabled = !el.disabled && el.getAttribute('aria-disabled') !== 'true';

        elements.push({
          id,
          role,
          title,
          value,
          roleDescription: el.getAttribute('role') || tag,
          enabled,
          focused: isFocused,
          frame: {
            x: Math.round((rect.left + offsetX) * 10) / 10,
            y: Math.round((rect.top + offsetY) * 10) / 10,
            width: Math.round(rect.width * 10) / 10,
            height: Math.round(rect.height * 10) / 10
          },
          actions: mapActions(role)
        });
        return id;
      }

      for (let i = 0; i < nodes.length && elements.length < limit; i++) {
        addElement(nodes[i]);
      }

      // Always expose <input type="file"> controls even when hidden behind styled upload buttons/dropzones
      const fileInputs = queryAllDeep(document, 'input[type="file"]');
      for (let i = 0; i < fileInputs.length && elements.length < limit + 16; i++) {
        const fi = fileInputs[i];
        if (fi.getAttribute('data-usemac-id')) continue;
        const id = '@b' + (startIndex + elements.length);
        fi.setAttribute('data-usemac-id', id);

        let labelText = fi.getAttribute('aria-label') || fi.getAttribute('title') || '';
        if (!labelText && fi.id) {
          const explicitLbl = queryOneDeep(document, 'label[for="' + fi.id.replace(/["\\\\]/g, '\\\\$&') + '"]');
          if (explicitLbl) labelText = explicitLbl.innerText || explicitLbl.textContent || '';
        }
        if (!labelText) {
          const parentLbl = fi.closest('label');
          if (parentLbl) labelText = parentLbl.innerText || parentLbl.textContent || '';
        }
        let anchorRect = fi.getBoundingClientRect();
        const isHiddenInput = !isVisibleRect(fi, anchorRect);
        if (!labelText || isHiddenInput) {
          let ancestor = fi.parentElement;
          for (let depth = 0; depth < 3 && ancestor && ancestor !== document.body; depth++) {
            const ar = ancestor.getBoundingClientRect();
            if (isHiddenInput && ar.width >= 16 && ar.height >= 16) {
              anchorRect = ar;
            }
            if (!labelText) {
              const cand = (ancestor.innerText || ancestor.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();
              if (cand && cand.length <= 120) labelText = cand;
            }
            if (!isHiddenInput && labelText) break;
            ancestor = ancestor.parentElement;
          }
        }

        const metaParts = [];
        if (fi.files && fi.files.length > 0) {
          metaParts.push('files=' + Array.from(fi.files).map((f) => f.name).join(','));
        }
        if (fi.accept) metaParts.push('accept=' + fi.accept);
        if (fi.multiple) metaParts.push('multiple=true');
        if (isHiddenInput) metaParts.push('hidden=true');

        elements.push({
          id,
          role: 'AXFileUpload',
          title: cleanText(labelText, 120) || 'File upload input',
          value: metaParts.length > 0 ? metaParts.join(';') : null,
          roleDescription: 'input[type=file]',
          enabled: !fi.disabled,
          focused: activeEl === fi,
          frame: {
            x: Math.round(((anchorRect.left || 0) + offsetX) * 10) / 10,
            y: Math.round(((anchorRect.top || 0) + offsetY) * 10) / 10,
            width: Math.round((anchorRect.width || 0) * 10) / 10,
            height: Math.round((anchorRect.height || 0) * 10) / 10
          },
          actions: ['AXUploadFile']
        });
      }

      const vw = window.innerWidth || ${curVpW};
      const vh = window.innerHeight || ${curVpH};
      const docEl = document.documentElement;
      const bodyEl = document.body;
      const scrollX = Math.round(window.scrollX || docEl?.scrollLeft || bodyEl?.scrollLeft || 0);
      const scrollY = Math.round(window.scrollY || docEl?.scrollTop || bodyEl?.scrollTop || 0);
      const scrollHeight = Math.round(Math.max(
        docEl?.scrollHeight || 0,
        bodyEl?.scrollHeight || 0,
        vh
      ));
      const scrollWidth = Math.round(Math.max(
        docEl?.scrollWidth || 0,
        bodyEl?.scrollWidth || 0,
        vw
      ));
      const htmlOverflow = docEl ? window.getComputedStyle(docEl).overflowY : '';
      const bodyOverflow = bodyEl ? window.getComputedStyle(bodyEl).overflowY : '';
      const scrollLocked = (htmlOverflow === 'hidden' || bodyOverflow === 'hidden');
      const canScrollDown = !scrollLocked && (scrollY + vh < scrollHeight - 8);
      const canScrollUp = !scrollLocked && (scrollY > 4);
      const canScrollRight = scrollX + vw < scrollWidth - 8;
      const canScrollLeft = scrollX > 4;

      function findScrollableContainers() {
        const found = [];
        const all = document.querySelectorAll('div, section, main, [role="grid"], [role="table"], [role="region"]');
        for (let i = 0; i < all.length && i < 600; i++) {
          const el = all[i];
          const st = window.getComputedStyle(el);
          if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
          const canX = (st.overflowX === 'auto' || st.overflowX === 'scroll') && el.scrollWidth > el.clientWidth + 24;
          const canY = (st.overflowY === 'auto' || st.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 24;
          if (!canX && !canY) continue;
          const r = el.getBoundingClientRect();
          if (r.width < 180 || r.height < 80) continue;
          if (r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) continue;
          const role = el.getAttribute('role') || el.tagName.toLowerCase();
          const cx = Math.round(r.left + offsetX + r.width / 2);
          const cy = Math.round(r.top + offsetY + r.height / 2);
          const axes = [];
          if (canX) axes.push('x=' + Math.round(el.scrollLeft) + '/' + Math.round(el.scrollWidth - el.clientWidth));
          if (canY) axes.push('y=' + Math.round(el.scrollTop) + '/' + Math.round(el.scrollHeight - el.clientHeight));
          found.push({
            area: r.width * r.height + (canX ? 500000 : 0),
            desc: role + '(' + axes.join(',') + ') at (' + cx + ',' + cy + ')'
          });
        }
        found.sort((a, b) => b.area - a.area);
        const dedup = [];
        const seen = new Set();
        for (const item of found) {
          if (seen.has(item.desc)) continue;
          seen.add(item.desc);
          dedup.push(item.desc);
          if (dedup.length >= 6) break;
        }
        return dedup;
      }

      const scrollableContainers = findScrollableContainers();

      function detectBlockingOverlay() {
        const candidates = [];
        const probePoints = [
          [vw * 0.5, vh * 0.5],
          [vw * 0.5, vh * 0.3],
          [vw * 0.5, vh * 0.25],
          [vw * 0.5, vh * 0.7]
        ];
        const seen = new Set();

        function considerContainer(el) {
          let cur = el;
          while (cur && cur !== document.body && cur !== document.documentElement) {
            if (seen.has(cur)) break;
            const st = window.getComputedStyle(cur);
            const pos = st?.position;
            const z = parseInt(st?.zIndex, 10);
            const isDialog = cur.getAttribute?.('role') === 'dialog' || cur.getAttribute?.('aria-modal') === 'true' || cur.tagName?.toLowerCase() === 'dialog';
            if (isDialog || ((pos === 'fixed' || pos === 'sticky') && (Number.isFinite(z) && z >= 10))) {
              const r = cur.getBoundingClientRect();
              const area = r.width * r.height;
              const isHeaderOrNav = (r.height < 110 && r.top <= 10 && r.width > vw * 0.85 && !isDialog);
              // Do not misclassify main workspace iframes as blocking overlays when we index their contents
              const isWorkspaceIframe = cur.tagName?.toLowerCase() === 'iframe' && r.width > vw * 0.5 && r.height > vh * 0.5;
              if (!isHeaderOrNav && !isWorkspaceIframe && r.width >= 200 && r.height >= 90 && area > 22000 && st.display !== 'none' && st.visibility !== 'hidden' && parseFloat(st.opacity) > 0.05) {
                seen.add(cur);
                candidates.push({ el: cur, rect: r, z: Number.isFinite(z) ? z : 10, isDialog });
              }
            }
            cur = cur.parentElement;
          }
        }

        for (const [px, py] of probePoints) {
          const hit = document.elementFromPoint(px, py);
          if (hit) considerContainer(hit);
        }

        const explicitDialogs = queryAllDeep(document, '[role="dialog"], [aria-modal="true"], dialog[open], div[class*="modal"], div[class*="popup"], div[class*="notification"], div[id*="onesignal"], div[id*="push"], div[class*="banner"]');
        for (let i = 0; i < explicitDialogs.length && i < 40; i++) {
          considerContainer(explicitDialogs[i]);
        }

        if (candidates.length === 0) return null;
        candidates.sort((a, b) => (b.isDialog ? 1 : 0) - (a.isDialog ? 1 : 0) || b.z - a.z);
        const top = candidates[0];
        const container = top.el;
        const cr = top.rect;

        let summary = cleanText(container.innerText || container.getAttribute('aria-label') || container.tagName, 140);
        if (!summary && container.tagName?.toLowerCase() === 'iframe') {
          summary = 'Cross-origin iframe overlay (' + (container.src || 'iframe').slice(0, 60) + ')';
        }
        if (!summary) summary = 'Modal/overlay covering viewport';

        let closeEl = null;
        const dismissRegex = /^(x|×|✕|✖|fechar|close|não|nao|agora não|agora nao|recusar|rejeitar|dispensar|cancelar|dismiss|no thanks|not now|reject|decline|skip)$/i;
        const innerCandidates = queryAllDeep(container, 'button, a, [role="button"], span, div, svg, i');
        let bestScore = -1;

        for (let i = 0; i < innerCandidates.length && i < 120; i++) {
          const c = innerCandidates[i];
          const r = c.getBoundingClientRect();
          if (!isVisibleRect(c, r)) continue;
          if (r.width > 240 || r.height > 80) continue;
          const label = ((c.getAttribute('aria-label') || '') + ' ' + (c.getAttribute('title') || '') + ' ' + (c.innerText || '')).replace(/\\s+/g, ' ').trim();
          const cls = ((c.className && typeof c.className === 'string' ? c.className : '') + ' ' + (c.id || '')).toLowerCase();
          let score = 0;
          if (dismissRegex.test(label)) score += 10;
          if (/close|fechar|dismiss|cancel|decline|reject|deny|later/.test(cls) || /close|fechar|agora não|não obrigad|recusar|rejeitar|no thanks|not now/i.test(label)) score += 6;
          const nearTopRight = (r.right >= cr.right - 64 && r.top <= cr.top + 64 && r.width <= 48 && r.height <= 48);
          if (nearTopRight) {
            const st = window.getComputedStyle(c);
            if (st.cursor === 'pointer' || c.tagName === 'BUTTON' || c.getAttribute('role') === 'button' || /^[x×✕✖]$/i.test(label)) {
              score += 5;
            }
          }
          if (score > bestScore) {
            bestScore = score;
            closeEl = c;
          }
        }

        let closeElementId = null;
        let closeX = null;
        let closeY = null;
        if (closeEl && bestScore >= 5) {
          closeElementId = addElement(closeEl, 'AXButton', cleanText(closeEl.getAttribute('aria-label') || closeEl.innerText || 'Close overlay', 40) || 'Close overlay');
          const br = closeEl.getBoundingClientRect();
          closeX = Math.round((br.left + offsetX + br.width / 2) * 10) / 10;
          closeY = Math.round((br.top + offsetY + br.height / 2) * 10) / 10;
        }

        return {
          summary,
          closeElementId,
          closeX,
          closeY,
          frame: {
            x: Math.round((cr.left + offsetX) * 10) / 10,
            y: Math.round((cr.top + offsetY) * 10) / 10,
            width: Math.round(cr.width * 10) / 10,
            height: Math.round(cr.height * 10) / 10
          },
          blocksScroll: scrollLocked || (cr.width >= vw * 0.7 && cr.height >= vh * 0.7)
        };
      }

      function formatCellText(cell) {
        if (!cell) return '';
        const parts = [];
        const sw = cell.querySelector('input[type="checkbox"], [role="switch"], [role="checkbox"]');
        if (sw) {
          const checked = sw.tagName === 'INPUT' ? sw.checked : sw.getAttribute('aria-checked') === 'true';
          const rawTxt = (cell.innerText || '').replace(/\\s+/g, ' ').trim();
          if (!rawTxt) return checked ? '[ON]' : '[OFF]';
          parts.push(checked ? '[ON]' : '[OFF]');
        }
        const txt = (cell.innerText || cell.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();
        if (txt) parts.push(txt);
        return parts.join(' ').replace(/\\|/g, '/').slice(0, 96);
      }

      function rowsToMarkdown(rows, maxRows = 60, maxCols = 24) {
        if (!rows || rows.length === 0) return '';
        const cleanRows = rows
          .map((r) => r.slice(0, maxCols))
          .filter((r) => r.some((c) => c && c.trim().length > 0))
          .slice(0, maxRows);
        if (cleanRows.length < 2) return '';
        const colCount = Math.max(...cleanRows.map((r) => r.length));
        if (colCount < 2) return '';
        const norm = cleanRows.map((r) => {
          const out = r.slice();
          while (out.length < colCount) out.push('');
          return out;
        });
        const header = '| ' + norm[0].map((c, i) => c || ('Col ' + (i + 1))).join(' | ') + ' |';
        const sep = '| ' + norm[0].map(() => '---').join(' | ') + ' |';
        const body = norm.slice(1).map((r) => '| ' + r.join(' | ') + ' |');
        return [header, sep, ...body].join('\\n');
      }

      function extractTablesMarkdown(maxChars = 5500) {
        if (!includeTables) return null;
        const blocks = [];
        let totalLen = 0;

        const htmlTables = queryAllDeep(document, 'table');
        for (let t = 0; t < htmlTables.length && blocks.length < 4 && totalLen < maxChars; t++) {
          const table = htmlTables[t];
          const tr = table.getBoundingClientRect();
          if (!isVisibleRect(table, tr)) continue;
          const rows = [];
          const trNodes = table.querySelectorAll('tr');
          for (let i = 0; i < trNodes.length && rows.length < 60; i++) {
            const cells = Array.from(trNodes[i].querySelectorAll('th, td')).map(formatCellText);
            if (cells.length >= 2) rows.push(cells);
          }
          const md = rowsToMarkdown(rows);
          if (md) {
            blocks.push(md);
            totalLen += md.length + 4;
          }
        }

        const grids = queryAllDeep(document, '[role="grid"], [role="table"], [role="treegrid"]');
        for (let g = 0; g < grids.length && blocks.length < 4 && totalLen < maxChars; g++) {
          const grid = grids[g];
          const gr = grid.getBoundingClientRect();
          if (!isVisibleRect(grid, gr)) continue;
          const rowEls = grid.querySelectorAll('[role="row"]');
          if (rowEls.length < 2) continue;
          const rowBuckets = new Map();
          const rowOrder = [];
          for (let i = 0; i < rowEls.length && rowOrder.length < 80; i++) {
            const rowEl = rowEls[i];
            const rr = rowEl.getBoundingClientRect();
            if (!isVisibleRect(rowEl, rr)) continue;
            const cellEls = rowEl.querySelectorAll('[role="columnheader"], [role="rowheader"], [role="gridcell"], [role="cell"]');
            if (cellEls.length === 0) continue;
            const ariaIdx = rowEl.getAttribute('aria-rowindex');
            const key = ariaIdx ? ('idx:' + ariaIdx) : ('y:' + Math.round(rr.top / 4));
            if (!rowBuckets.has(key)) {
              rowBuckets.set(key, []);
              rowOrder.push(key);
            }
            const bucket = rowBuckets.get(key);
            for (let c = 0; c < cellEls.length; c++) {
              const cell = cellEls[c];
              const cr = cell.getBoundingClientRect();
              if (!isVisibleRect(cell, cr)) continue;
              bucket.push({ x: cr.left, text: formatCellText(cell) });
            }
          }
          const rows = rowOrder.map((k) => {
            const sorted = rowBuckets.get(k).sort((a, b) => a.x - b.x);
            return sorted.map((item) => item.text);
          });
          const md = rowsToMarkdown(rows);
          if (md) {
            blocks.push(md);
            totalLen += md.length + 4;
          }
        }

        return blocks.length > 0 ? blocks.join('\\n\\n').slice(0, maxChars) : null;
      }

      function extractReadableText() {
        if (!includeText) return null;
        const textCap = isTopFrame ? 4400 : 2800;
        const primary = document.querySelectorAll('article p, main p, [role="main"] p');
        const source = primary.length >= 2 ? primary : document.querySelectorAll('p');
        const chunks = [];
        const seenText = new Set();
        let totalLen = 0;
        for (let i = 0; i < source.length && totalLen < textCap; i++) {
          const p = source[i];
          const st = window.getComputedStyle(p);
          if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
          const txt = (p.innerText || '').replace(/\\s+/g, ' ').trim();
          if (txt.length < 32) continue;
          if (seenText.has(txt)) continue;
          seenText.add(txt);
          chunks.push(txt);
          totalLen += txt.length + 2;
        }
        if (chunks.length >= 3 && totalLen >= 300) {
          return chunks.join('\\n\\n').slice(0, textCap);
        }

        const root = document.querySelector('main, [role="main"]') || document.body;
        if (!root) return chunks.length > 0 ? chunks.join('\\n\\n').slice(0, textCap) : null;
        const raw = (root.innerText || '');
        const lines = raw.split(/\\n+/).map((l) => l.replace(/\\s+/g, ' ').trim()).filter((l) => l.length > 0);
        const out = [];
        const seenLines = new Set();
        let outLen = 0;
        for (let i = 0; i < lines.length && outLen < textCap; i++) {
          const line = lines[i];
          if (line.length === 1 && !/[0-9%]/.test(line)) continue;
          if (seenLines.has(line) && line.length < 40) continue;
          seenLines.add(line);
          out.push(line);
          outLen += line.length + 1;
        }
        return out.length > 0 ? out.join('\\n').slice(0, textCap) : null;
      }

      const blockingOverlay = detectBlockingOverlay();
      const tablesMarkdown = extractTablesMarkdown();
      const readableText = extractReadableText();

      return {
        title: document.title || '',
        url: window.location.href || '',
        hasFocus: typeof document.hasFocus === 'function' ? document.hasFocus() : false,
        focusedElementId,
        elements,
        pageState: {
          scrollX,
          scrollY,
          scrollHeight,
          scrollWidth,
          viewportWidth: vw,
          viewportHeight: vh,
          canScrollDown,
          canScrollUp,
          canScrollRight,
          canScrollLeft,
          scrollLocked,
          blockingOverlay,
          readableText,
          tablesMarkdown,
          scrollableContainers
        }
      };
    })()`;
}

async function observeTab(tabId, maxElements = 280, options = {}) {
  try {
    return await observeTabNow(tabId, maxElements, options);
  } finally {
    // An explicit viewport may have overridden a tab the user is looking at; give it its real size back.
    if (hasExplicitViewport(options)) await restoreVisibleViewport(tabId);
  }
}

async function observeTabNow(tabId, maxElements = 280, options = {}) {
  const start = performance.now();
  const limit = clamp(Number(maxElements) || 280, 1, 600);
  const includeText = options.includeText !== false;
  const includeTables = options.includeTables !== false;

  if (hasExplicitViewport(options)) {
    await applyViewportMetrics(
      tabId,
      options.viewportWidth ?? null,
      options.viewportHeight ?? null,
      options.deviceScaleFactor ?? null
    );
    await sleep(90);
  }

  const session = getOrCreateTabSession(tabId);
  const { width: curVpW, height: curVpH } = effectiveViewport(session);
  session.elementFrameMap.clear();

  const evalResult = await sendCDP(tabId, "Runtime.evaluate", {
    expression: buildFrameIndexExpression({
      startIndex: 1,
      limit,
      includeText,
      includeTables,
      curVpW,
      curVpH,
      isTopFrame: true,
      offsetX: 0,
      offsetY: 0
    }),
    returnByValue: true,
    awaitPromise: false
  });

  if (evalResult?.exceptionDetails) {
    throw new Error(evalResult.exceptionDetails.text || "DOM observation failed.");
  }

  const pageData = evalResult?.result?.value || {
    title: "",
    url: "",
    focusedElementId: null,
    elements: [],
    pageState: null
  };

  const mergedElements = Array.isArray(pageData.elements) ? pageData.elements.slice() : [];
  let focusedElementId = pageData.focusedElementId || null;
  const topFrameMeta = {
    sessionId: null,
    contextId: null,
    frameId: null,
    parentSessionId: null,
    offsetX: 0,
    offsetY: 0,
    width: curVpW,
    height: curVpH,
    url: pageData.url || "",
    isOOPIF: false,
    hops: []
  };
  for (const el of mergedElements) {
    session.elementFrameMap.set(el.id, topFrameMeta);
  }

  // Traverse cross-origin OOPIFs and same-origin child iframes and unify @bN refs + text + tables
  const childFrames = await discoverChildFrames(tabId).catch(() => []);
  const tableBlocks = pageData.pageState?.tablesMarkdown ? [pageData.pageState.tablesMarkdown] : [];
  const textBlocks = pageData.pageState?.readableText ? [pageData.pageState.readableText] : [];
  const mergedScrollables = Array.isArray(pageData.pageState?.scrollableContainers)
    ? pageData.pageState.scrollableContainers.slice()
    : [];
  let mergedOverlay = pageData.pageState?.blockingOverlay || null;

  for (const frameMeta of childFrames) {
    const hardCap = Math.min(600, Math.max(limit + 120, 360));
    if (mergedElements.length >= hardCap) break;
    const isLargeWorkspaceFrame = frameMeta.width >= 300 && frameMeta.height >= 200;
    const remaining = Math.max(limit - mergedElements.length, isLargeWorkspaceFrame ? 120 : 40);
    const frameBudget = Math.min(remaining, hardCap - mergedElements.length);
    if (frameBudget <= 0) break;

    let childRes = null;
    try {
      childRes = await evalInFrame(
        tabId,
        frameMeta,
        buildFrameIndexExpression({
          startIndex: mergedElements.length + 1,
          limit: frameBudget,
          includeText,
          includeTables,
          curVpW: Math.round(frameMeta.width) || curVpW,
          curVpH: Math.round(frameMeta.height) || curVpH,
          isTopFrame: false,
          offsetX: frameMeta.offsetX,
          offsetY: frameMeta.offsetY
        })
      );
    } catch (_) {
      continue;
    }

    const childData = childRes?.result?.value;
    if (!childData) continue;

    const childEls = Array.isArray(childData.elements) ? childData.elements : [];
    for (const el of childEls) {
      mergedElements.push(el);
      session.elementFrameMap.set(el.id, frameMeta);
    }

    if (childData.focusedElementId && (!focusedElementId || childData.hasFocus)) {
      focusedElementId = childData.focusedElementId;
    }

    const cs = childData.pageState;
    if (cs) {
      if (cs.tablesMarkdown && tableBlocks.join("\n\n").length < 6200) {
        tableBlocks.push(cs.tablesMarkdown);
      }
      if (cs.readableText && textBlocks.join("\n\n").length < 5600) {
        let frameLabel = frameMeta.title || childData.title || "";
        if (!frameLabel && frameMeta.url) {
          try {
            const u = new URL(frameMeta.url);
            frameLabel = u.host + (u.pathname && u.pathname !== "/" ? u.pathname.slice(0, 40) : "");
          } catch (_) {
            frameLabel = frameMeta.url.slice(0, 48);
          }
        }
        const header = frameLabel ? `[iframe: ${frameLabel}]` : "[iframe]";
        textBlocks.push(`${header}\n${cs.readableText}`);
      }
      if (Array.isArray(cs.scrollableContainers)) {
        for (const sc of cs.scrollableContainers) {
          if (mergedScrollables.length < 8 && !mergedScrollables.includes(sc)) {
            mergedScrollables.push(sc);
          }
        }
      }
      if (!mergedOverlay && cs.blockingOverlay) {
        mergedOverlay = cs.blockingOverlay;
      }
      if (isLargeWorkspaceFrame && pageData.pageState) {
        if (cs.canScrollDown) pageData.pageState.canScrollDown = true;
        if (cs.canScrollUp) pageData.pageState.canScrollUp = true;
        if (cs.canScrollRight) pageData.pageState.canScrollRight = true;
        if (cs.canScrollLeft) pageData.pageState.canScrollLeft = true;
      }
    }
  }

  if (pageData.pageState) {
    pageData.pageState.tablesMarkdown = tableBlocks.length > 0 ? tableBlocks.join("\n\n").slice(0, 6500) : null;
    pageData.pageState.readableText = textBlocks.length > 0 ? textBlocks.join("\n\n").slice(0, 6000) : null;
    pageData.pageState.scrollableContainers = mergedScrollables;
    pageData.pageState.blockingOverlay = mergedOverlay;
  }

  const tab = await refreshTabMeta(tabId);
  const latencyMs = Math.round((performance.now() - start) * 100) / 100;
  const windowTitle = tab?.title || pageData.title || "";

  let screenshotBase64 = null;
  if (options.includeScreenshot) {
    try {
      const cap = await sendCDP(tabId, "Page.captureScreenshot", {
        format: "jpeg",
        quality: 82,
        fromSurface: true
      });
      if (cap?.data) {
        screenshotBase64 = cap.data;
      }
    } catch (_) {}
  }

  return {
    tab,
    screenshotBase64,
    snapshot: {
      app: {
        pid: 0,
        name: `Chrome (${state.profileName})`,
        bundleId: "com.google.Chrome",
        isActive: false,
        isHidden: false,
        windowTitle,
        windowBounds: {
          x: 0,
          y: 0,
          width: curVpW,
          height: curVpH
        }
      },
      timestampMs: Date.now(),
      latencyMs,
      fromHotCache: false,
      focusedElementId,
      elements: mergedElements,
      pageState: pageData.pageState || null
    }
  };
}

function emitCursor(tabId, x, y, phase, label = null) {
  const viewport = effectiveViewport(state.tabSessions.get(tabId));
  sendWS({
    type: "cursor",
    tabId,
    x: Math.round(x * 10) / 10,
    y: Math.round(y * 10) / 10,
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    phase,
    label
  });
}

async function moveCursorSmoothly(tabId, targetX, targetY, label = null) {
  const session = getOrCreateTabSession(tabId);
  const { width: maxW, height: maxH } = effectiveViewport(session);
  const tx = clamp(Number(targetX), 0, maxW);
  const ty = clamp(Number(targetY), 0, maxH);
  const startX = clamp(session.cursor.x, 0, maxW);
  const startY = clamp(session.cursor.y, 0, maxH);
  const steps = 3;

  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    const ix = startX + (tx - startX) * t;
    const iy = startY + (ty - startY) * t;
    session.cursor = { x: ix, y: iy };
    emitCursor(tabId, ix, iy, "move", label);
    await sendCDP(tabId, "Input.dispatchMouseEvent", {
      type: "mouseMoved",
      x: ix,
      y: iy,
      button: "none"
    });
    await sleep(18);
  }
  return { x: tx, y: ty };
}

function usemacIdSelectorLiteral(elementId) {
  const escapedId = String(elementId).replace(/["\\]/g, "\\$&");
  return JSON.stringify(`[data-usemac-id="${escapedId}"]`);
}

async function resolveInSpecificFrame(tabId, frameMeta, selectorLit, scrollOwnerIntoView = true) {
  let offsetX = 0;
  let offsetY = 0;
  if (frameMeta && frameMeta.frameId != null) {
    const fRect = await computeFrameViewportRect(tabId, frameMeta, scrollOwnerIntoView);
    if (!fRect || !fRect.visible) {
      return null;
    }
    offsetX = fRect.x;
    offsetY = fRect.y;
  }
  const res = await evalInFrame(tabId, frameMeta, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const el = queryOneDeep(document, ${selectorLit});
    if (!el) return null;
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const rect = el.getBoundingClientRect();
    const label = (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.tagName || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      label
    };
  })()`).catch(() => null);
  const point = res?.result?.value;
  if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    return null;
  }
  return {
    x: point.x + offsetX,
    y: point.y + offsetY,
    label: point.label || null,
    frameMeta: frameMeta || null
  };
}

async function resolveSelectorCenter(tabId, cssSelector) {
  const selectorLit = JSON.stringify(String(cssSelector));
  const topHit = await resolveInSpecificFrame(tabId, null, selectorLit, false);
  if (topHit) return topHit;

  const session = getOrCreateTabSession(tabId);
  let frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveInSpecificFrame(tabId, frameMeta, selectorLit, true);
    if (hit) return hit;
  }
  // One fresh discovery pass in case a new OOPIF mounted after last observe
  frames = await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveInSpecificFrame(tabId, frameMeta, selectorLit, true);
    if (hit) return hit;
  }
  throw new Error(`Selector ${cssSelector} not found in tab ${tabId}.`);
}

async function resolveElementCenter(tabId, elementId) {
  const selectorLit = usemacIdSelectorLiteral(elementId);
  const session = getOrCreateTabSession(tabId);
  const mappedFrame = session.elementFrameMap.get(elementId);
  if (mappedFrame) {
    const mappedHit = await resolveInSpecificFrame(tabId, mappedFrame, selectorLit, true);
    if (mappedHit) return mappedHit;
  }

  // Fallback: top frame then all discovered child frames
  if (!mappedFrame || mappedFrame.frameId != null) {
    const topHit = await resolveInSpecificFrame(tabId, null, selectorLit, false);
    if (topHit) return topHit;
  }
  const frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    if (mappedFrame && frameMeta === mappedFrame) continue;
    const hit = await resolveInSpecificFrame(tabId, frameMeta, selectorLit, true);
    if (hit) return hit;
  }
  throw new Error(`Element ${elementId} not found in tab ${tabId}.`);
}

function findChildFrameAtPoint(session, x, y) {
  const frames = session?.lastChildFrames;
  if (!Array.isArray(frames) || frames.length === 0) return null;
  // Prefer smallest (deepest nested) frame containing (x, y)
  let best = null;
  let bestArea = Infinity;
  for (const f of frames) {
    if (
      x >= f.offsetX &&
      x <= f.offsetX + f.width &&
      y >= f.offsetY &&
      y <= f.offsetY + f.height
    ) {
      const area = f.width * f.height;
      if (area < bestArea) {
        bestArea = area;
        best = f;
      }
    }
  }
  return best;
}

async function resolveStepTarget(tabId, step) {
  if (step.elementId) {
    return resolveElementCenter(tabId, step.elementId);
  }
  if (step.selector) {
    return resolveSelectorCenter(tabId, step.selector);
  }
  if (Number.isFinite(step.x) && Number.isFinite(step.y)) {
    return { x: Number(step.x), y: Number(step.y), label: null };
  }
  return null;
}

function buildKeyDescriptor(keyName) {
  const raw = String(keyName || "");
  const lower = raw.toLowerCase();
  const special = {
    enter: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
    return: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
    tab: { key: "Tab", code: "Tab", keyCode: 9 },
    escape: { key: "Escape", code: "Escape", keyCode: 27 },
    esc: { key: "Escape", code: "Escape", keyCode: 27 },
    backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
    delete: { key: "Delete", code: "Delete", keyCode: 46 },
    space: { key: " ", code: "Space", keyCode: 32, text: " " },
    " ": { key: " ", code: "Space", keyCode: 32, text: " " },
    arrowup: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
    up: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
    arrowdown: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
    down: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
    arrowleft: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
    left: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
    arrowright: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
    right: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
    home: { key: "Home", code: "Home", keyCode: 36 },
    end: { key: "End", code: "End", keyCode: 35 },
    pageup: { key: "PageUp", code: "PageUp", keyCode: 33 },
    pagedown: { key: "PageDown", code: "PageDown", keyCode: 34 }
  };

  if (special[lower]) {
    return special[lower];
  }

  if (raw.length === 1) {
    const codePoint = raw.toUpperCase().charCodeAt(0);
    const isLetter = codePoint >= 65 && codePoint <= 90;
    const isDigit = codePoint >= 48 && codePoint <= 57;
    return {
      key: raw,
      code: isLetter ? `Key${raw.toUpperCase()}` : isDigit ? `Digit${raw}` : raw,
      keyCode: codePoint,
      text: raw
    };
  }

  return { key: raw, code: raw, keyCode: 0 };
}

function buildModifierMask(modifiers) {
  if (!Array.isArray(modifiers)) return 0;
  let mask = 0;
  for (const mod of modifiers) {
    const m = String(mod).toLowerCase();
    if (m === "alt" || m === "option") mask |= 1;
    else if (m === "control" || m === "ctrl") mask |= 2;
    else if (m === "meta" || m === "command" || m === "cmd") mask |= 4;
    else if (m === "shift") mask |= 8;
  }
  return mask;
}

async function dispatchMouseClick(tabId, x, y, button = "left", clickCount = 1) {
  await sendCDP(tabId, "Input.dispatchMouseEvent", {
    type: "mousePressed",
    x,
    y,
    button,
    clickCount
  });
  await sleep(25);
  await sendCDP(tabId, "Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x,
    y,
    button,
    clickCount
  });
}

async function executeActionStep(tabId, step, cancelToken = null) {
  const action = step.action;

  if (action === "openURL" || action === "navigate") {
    const targetUrl = step.url || step.text;
    if (!targetUrl) {
      throw new Error(`${action} requires url.`);
    }
    assertAllowedUrl(targetUrl);
    await chrome.tabs.update(tabId, { url: targetUrl });
    await waitForTabLoad(tabId, 3500);
    return { mechanism: "tabs-update", message: null };
  }

  if (action === "click" || action === "doubleClick" || action === "rightClick") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error(`${action} requires elementId or (x, y).`);
    }
    const label =
      action === "doubleClick"
        ? "Double-clicking"
        : action === "rightClick"
          ? "Right-clicking"
          : target.label
            ? `Clicking ${target.label}`
            : "Clicking";
    const clickStartAt = Date.now();
    const beforeTab = await refreshTabMeta(tabId);
    const pt = await moveCursorSmoothly(tabId, target.x, target.y, label);
    emitCursor(tabId, pt.x, pt.y, "click", label);

    if (action === "click") {
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
    } else if (action === "doubleClick") {
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
      await sleep(25);
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 2);
    } else {
      await dispatchMouseClick(tabId, pt.x, pt.y, "right", 1);
    }

    // Smart post-click settle: detect triggered navigation or download without blind 3s sleeps
    await sleep(140);
    if (state.lastDownloadAt >= clickStartAt) {
      const dl = await waitForDownloadCompletion(state.lastDownloadId, 4500);
      const path = dl?.filename || state.lastDownloadFilename || null;
      return {
        mechanism: "cdp-mouse (download)",
        message: path ? `Download ${dl?.state || "started"}: ${path}` : "Download started",
        downloadPath: path
      };
    }
    const afterTab = await refreshTabMeta(tabId);
    if (afterTab && (afterTab.status === "loading" || (beforeTab?.url && afterTab.url !== beforeTab.url))) {
      await waitForTabLoad(tabId, 3200);
      return { mechanism: "cdp-mouse (navigated)", message: afterTab.url || null };
    }
    return { mechanism: "cdp-mouse", message: null };
  }

  if (action === "hover") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error("hover requires elementId, selector, or (x, y).");
    }
    const label = target.label ? `Hovering ${target.label}` : "Hovering";
    const pt = await moveCursorSmoothly(tabId, target.x, target.y, label);
    emitCursor(tabId, pt.x, pt.y, "hover", label);
    await sendCDP(tabId, "Input.dispatchMouseEvent", {
      type: "mouseMoved",
      x: pt.x,
      y: pt.y,
      button: "none"
    });
    await sleep(140);
    return { mechanism: "cdp-hover", message: target.label || `(${Math.round(pt.x)}, ${Math.round(pt.y)})` };
  }

  if (action === "focus") {
    const target = await resolveStepTarget(tabId, step);
    if (step.elementId || step.selector) {
      const selectorLit = step.elementId
        ? usemacIdSelectorLiteral(step.elementId)
        : JSON.stringify(String(step.selector));
      await evalInFrame(tabId, target?.frameMeta || null, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = queryOneDeep(document, ${selectorLit});
        if (el) el.focus();
      })()`);
    }
    if (target) {
      await moveCursorSmoothly(tabId, target.x, target.y, "Focusing");
    }
    return { mechanism: "cdp-focus", message: null };
  }

  if (action === "setValue" || action === "type") {
    const session = getOrCreateTabSession(tabId);
    const text = step.text ?? "";
    const target = await resolveStepTarget(tabId, step);
    const frameMeta = target?.frameMeta || null;

    // Native <select> and checkbox/radio handling in setValue (React-safe, OOPIF + Shadow DOM aware)
    if (action === "setValue" && (step.elementId || step.selector)) {
      const selLit = step.elementId
        ? usemacIdSelectorLiteral(step.elementId)
        : JSON.stringify(String(step.selector));
      const textLit = JSON.stringify(String(text));
      const specialRes = await evalInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = queryOneDeep(document, ${selLit});
        if (!el) return { handled: false };
        const tag = (el.tagName || '').toLowerCase();
        if (tag === 'select') {
          const wanted = ${textLit}.trim();
          const wantedLower = wanted.toLowerCase();
          const opts = Array.from(el.options || []);
          let match =
            opts.find((o) => o.value === wanted) ||
            opts.find((o) => (o.value || '').toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase().includes(wantedLower));
          if (!match) {
            const sample = opts.slice(0, 12).map((o) => (o.text || o.value || '').trim()).join(', ');
            return { handled: true, ok: false, error: 'No matching <option> for "' + wanted + '". Available: ' + sample };
          }
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set;
          if (setter) setter.call(el, match.value);
          else el.value = match.value;
          match.selected = true;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { handled: true, ok: true, mechanism: 'cdp-select', message: 'Selected "' + (match.text || match.value).trim() + '"' };
        }
        if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
          const lower = ${textLit}.trim().toLowerCase();
          if (['true', 'false', 'checked', 'unchecked', 'on', 'off', '1', '0'].includes(lower)) {
            const desired = ['true', 'checked', 'on', '1'].includes(lower);
            if (Boolean(el.checked) !== desired) {
              el.click();
            }
            return { handled: true, ok: true, mechanism: 'cdp-toggle', message: 'checked=' + Boolean(el.checked) };
          }
        }
        return { handled: false };
      })()`);
      const sv = specialRes?.result?.value;
      if (sv?.handled) {
        if (!sv.ok) throw new Error(sv.error || "Failed to select option.");
        return { mechanism: sv.mechanism || "cdp-select", message: sv.message || null };
      }
    }

    if (target) {
      const pt = await moveCursorSmoothly(tabId, target.x, target.y, "Typing");
      emitCursor(tabId, pt.x, pt.y, "type", "Typing");
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
    } else {
      emitCursor(tabId, session.cursor.x, session.cursor.y, "type", "Typing");
    }

    if (action === "setValue") {
      if (step.elementId || step.selector) {
        const selectorLit = step.elementId
          ? usemacIdSelectorLiteral(step.elementId)
          : JSON.stringify(String(step.selector));
        await evalInFrame(tabId, frameMeta, `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const el = queryOneDeep(document, ${selectorLit});
          if (!el) return;
          el.focus();
          if ('value' in el) {
            const proto = el.tagName === 'TEXTAREA'
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            if (setter) setter.call(el, '');
            else el.value = '';
            el.dispatchEvent(new Event('input', { bubbles: true }));
          } else if (el.isContentEditable) {
            el.textContent = '';
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
        })()`);
      } else {
        await sendCDP(tabId, "Input.dispatchKeyEvent", {
          type: "keyDown",
          key: "a",
          code: "KeyA",
          windowsVirtualKeyCode: 65,
          modifiers: 4
        });
        await sendCDP(tabId, "Input.dispatchKeyEvent", {
          type: "keyUp",
          key: "a",
          code: "KeyA",
          windowsVirtualKeyCode: 65,
          modifiers: 4
        });
        await sendCDP(tabId, "Input.dispatchKeyEvent", {
          type: "keyDown",
          key: "Backspace",
          code: "Backspace",
          windowsVirtualKeyCode: 8
        });
        await sendCDP(tabId, "Input.dispatchKeyEvent", {
          type: "keyUp",
          key: "Backspace",
          code: "Backspace",
          windowsVirtualKeyCode: 8
        });
      }
    }

    if (text.length > 0) {
      let inserted = false;
      if (frameMeta?.sessionId) {
        try {
          await sendCDP(tabId, "Input.insertText", { text }, frameMeta.sessionId);
          inserted = true;
        } catch (_) {}
      }
      if (!inserted) {
        await sendCDP(tabId, "Input.insertText", { text });
      }
      // Guarantee OOPIF / Shadow DOM inputs updated even if compositor focus lagged
      if (frameMeta && (step.elementId || step.selector)) {
        const selectorLit = step.elementId
          ? usemacIdSelectorLiteral(step.elementId)
          : JSON.stringify(String(step.selector));
        const textLit = JSON.stringify(String(text));
        const isSetValue = action === "setValue" ? "true" : "false";
        await evalInFrame(tabId, frameMeta, `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const el = queryOneDeep(document, ${selectorLit});
          if (!el) return;
          const wanted = ${textLit};
          if ('value' in el && el.type !== 'file') {
            const cur = String(el.value || '');
            if (cur === '' || (${isSetValue} && cur !== wanted && !cur.includes(wanted))) {
              const nextVal = ${isSetValue} ? wanted : (cur + wanted);
              const proto = el.tagName === 'TEXTAREA'
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
              if (setter) setter.call(el, nextVal);
              else el.value = nextVal;
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
          }
        })()`).catch(() => {});
      }
    }

    if (step.elementId || step.selector) {
      const selectorLit = step.elementId
        ? usemacIdSelectorLiteral(step.elementId)
        : JSON.stringify(String(step.selector));
      await evalInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = queryOneDeep(document, ${selectorLit});
        if (el) {
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
      })()`).catch(() => {});
    }

    return { mechanism: frameMeta?.isOOPIF ? "cdp-input (iframe)" : "cdp-input", message: null };
  }

  if (action === "pressKey") {
    const session = getOrCreateTabSession(tabId);
    const desc = buildKeyDescriptor(step.key || "");
    const modifiers = buildModifierMask(step.modifiers);
    emitCursor(tabId, session.cursor.x, session.cursor.y, "type", `Key ${desc.key}`);

    await sendCDP(tabId, "Input.dispatchKeyEvent", {
      type: desc.text && modifiers === 0 ? "keyDown" : "rawKeyDown",
      key: desc.key,
      code: desc.code,
      windowsVirtualKeyCode: desc.keyCode,
      nativeVirtualKeyCode: desc.keyCode,
      modifiers,
      text: modifiers === 0 ? desc.text : undefined,
      unmodifiedText: desc.text
    });
    await sleep(20);
    await sendCDP(tabId, "Input.dispatchKeyEvent", {
      type: "keyUp",
      key: desc.key,
      code: desc.code,
      windowsVirtualKeyCode: desc.keyCode,
      nativeVirtualKeyCode: desc.keyCode,
      modifiers
    });
    return { mechanism: "cdp-key", message: null };
  }

  if (action === "scroll") {
    const session = getOrCreateTabSession(tabId);
    const target = await resolveStepTarget(tabId, step);
    const pt = target
      ? await moveCursorSmoothly(tabId, target.x, target.y, "Scrolling")
      : { ...session.cursor };
    emitCursor(tabId, pt.x, pt.y, "scroll", "Scrolling");

    const requestedDeltaX = Number(step.deltaX || 0);
    const requestedDeltaY = Number(step.deltaY || 0);
    const selectorLit = step.selector ? JSON.stringify(String(step.selector)) : "null";
    const scrollFrameMeta = (target?.frameMeta && target.frameMeta.frameId != null)
      ? target.frameMeta
      : findChildFrameAtPoint(session, pt.x, pt.y);
    const localPtX = scrollFrameMeta ? (pt.x - scrollFrameMeta.offsetX) : pt.x;
    const localPtY = scrollFrameMeta ? (pt.y - scrollFrameMeta.offsetY) : pt.y;

    const beforeEval = await evalInFrame(tabId, scrollFrameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const y = window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0;
        const x = window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0;
        const sh = Math.max(document.documentElement?.scrollHeight || 0, document.body?.scrollHeight || 0);
        const sw = Math.max(document.documentElement?.scrollWidth || 0, document.body?.scrollWidth || 0);
        const vh = window.innerHeight || 800;
        const vw = window.innerWidth || 1280;
        const sel = ${selectorLit};
        const hit = sel ? queryOneDeep(document, sel) : document.elementFromPoint(${localPtX}, ${localPtY});
        let hitScrollTop = 0;
        let hitScrollLeft = 0;
        let hitScrollableY = false;
        let hitScrollableX = false;
        let cur = hit;
        while (cur && cur !== document.body && cur !== document.documentElement) {
          const st = window.getComputedStyle(cur);
          if (!hitScrollableY && (st.overflowY === 'auto' || st.overflowY === 'scroll') && cur.scrollHeight > cur.clientHeight + 4) {
            hitScrollTop = cur.scrollTop;
            hitScrollableY = true;
          }
          if (!hitScrollableX && (st.overflowX === 'auto' || st.overflowX === 'scroll') && cur.scrollWidth > cur.clientWidth + 4) {
            hitScrollLeft = cur.scrollLeft;
            hitScrollableX = true;
          }
          if (hitScrollableY && hitScrollableX) break;
          cur = cur.parentElement;
        }
        const htmlOv = window.getComputedStyle(document.documentElement).overflowY;
        const bodyOv = document.body ? window.getComputedStyle(document.body).overflowY : '';
        return {
          scrollX: x,
          scrollY: y,
          scrollWidth: sw,
          scrollHeight: sh,
          vw,
          vh,
          hitScrollLeft,
          hitScrollTop,
          hitScrollableX,
          hitScrollableY,
          locked: htmlOv === 'hidden' || bodyOv === 'hidden'
        };
      })()`).catch(() => null);

    const before = beforeEval?.result?.value || {
      scrollX: 0, scrollY: 0, scrollWidth: 0, scrollHeight: 0, vw: 1280, vh: 800,
      hitScrollLeft: 0, hitScrollTop: 0, hitScrollableX: false, hitScrollableY: false, locked: false
    };

    await sendCDP(tabId, "Input.dispatchMouseEvent", {
      type: "mouseWheel",
      x: pt.x,
      y: pt.y,
      deltaX: requestedDeltaX,
      deltaY: requestedDeltaY
    });
    await sleep(95);

    // If horizontal scroll was requested on an inner container and CDP wheel didn't move it, apply direct scrollBy fallback
    if (Math.abs(requestedDeltaX) >= 10) {
      await evalInFrame(tabId, scrollFrameMeta, `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const sel = ${selectorLit};
          const hit = sel ? queryOneDeep(document, sel) : document.elementFromPoint(${localPtX}, ${localPtY});
          let cur = hit;
          while (cur && cur !== document.body && cur !== document.documentElement) {
            const st = window.getComputedStyle(cur);
            if ((st.overflowX === 'auto' || st.overflowX === 'scroll') && cur.scrollWidth > cur.clientWidth + 4) {
              if (Math.abs(cur.scrollLeft - ${before.hitScrollLeft}) < 2) {
                cur.scrollLeft += ${requestedDeltaX};
              }
              return;
            }
            cur = cur.parentElement;
          }
        })()`).catch(() => null);
      await sleep(60);
    }

    const afterEval = await evalInFrame(tabId, scrollFrameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const y = window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0;
        const x = window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0;
        const sel = ${selectorLit};
        const hit = sel ? queryOneDeep(document, sel) : document.elementFromPoint(${localPtX}, ${localPtY});
        let hitScrollTop = 0;
        let hitScrollLeft = 0;
        let gotY = false;
        let gotX = false;
        let overlayHit = null;
        let cur = hit;
        while (cur && cur !== document.body && cur !== document.documentElement) {
          const st = window.getComputedStyle(cur);
          if (!gotY && (st.overflowY === 'auto' || st.overflowY === 'scroll') && cur.scrollHeight > cur.clientHeight + 4) {
            hitScrollTop = cur.scrollTop;
            gotY = true;
          }
          if (!gotX && (st.overflowX === 'auto' || st.overflowX === 'scroll') && cur.scrollWidth > cur.clientWidth + 4) {
            hitScrollLeft = cur.scrollLeft;
            gotX = true;
          }
          const z = parseInt(st.zIndex, 10);
          if (!overlayHit && (cur.getAttribute?.('role') === 'dialog' || cur.getAttribute?.('aria-modal') === 'true' || (st.position === 'fixed' && Number.isFinite(z) && z >= 10))) {
            const r = cur.getBoundingClientRect();
            if (r.height >= 90 && r.width >= 200) {
              overlayHit = (cur.innerText || cur.tagName || 'overlay').replace(/\\s+/g, ' ').trim().slice(0, 100);
            }
          }
          cur = cur.parentElement;
        }
        return { scrollX: x, scrollY: y, hitScrollLeft, hitScrollTop, overlayHit };
      })()`).catch(() => null);

    const after = afterEval?.result?.value || {
      scrollX: before.scrollX, scrollY: before.scrollY,
      hitScrollLeft: before.hitScrollLeft, hitScrollTop: before.hitScrollTop, overlayHit: null
    };
    const winDeltaY = Math.round((after.scrollY - before.scrollY) * 10) / 10;
    const containerDeltaY = Math.round((after.hitScrollTop - before.hitScrollTop) * 10) / 10;
    const actualDeltaY = Math.abs(winDeltaY) >= Math.abs(containerDeltaY) ? winDeltaY : containerDeltaY;

    const winDeltaX = Math.round((after.scrollX - before.scrollX) * 10) / 10;
    const containerDeltaX = Math.round((after.hitScrollLeft - before.hitScrollLeft) * 10) / 10;
    const actualDeltaX = Math.abs(winDeltaX) >= Math.abs(containerDeltaX) ? winDeltaX : containerDeltaX;

    const wantedDown = requestedDeltaY > 20 && (before.scrollY + before.vh < before.scrollHeight - 10 || before.locked || before.hitScrollableY);
    const wantedUp = requestedDeltaY < -20 && (before.scrollY > 10 || before.hitScrollTop > 4);
    const wantedHoriz = Math.abs(requestedDeltaX) > 20 && (before.scrollWidth > before.vw + 10 || before.hitScrollableX);
    let blockedWarning = null;
    if ((wantedDown || wantedUp) && Math.abs(actualDeltaY) < 4 && Math.abs(actualDeltaX) < 4) {
      if (after.overlayHit) {
        blockedWarning = `Scroll moved 0px — blocked by overlay: "${after.overlayHit}". Dismiss it (or call vision_query) before scrolling.`;
      } else if (before.locked && !before.hitScrollableY) {
        blockedWarning = "Scroll moved 0px — document scroll is locked (overflow: hidden), likely by a modal or popup banner.";
      } else {
        blockedWarning = `Scroll moved 0px at (${Math.round(pt.x)}, ${Math.round(pt.y)}) despite page height ${Math.round(before.scrollHeight)}px — a banner, iframe, or fixed element may be intercepting wheel events.`;
      }
    } else if (wantedHoriz && Math.abs(actualDeltaX) < 4 && Math.abs(requestedDeltaY) < 20) {
      blockedWarning = `Horizontal scroll moved 0px at (${Math.round(pt.x)}, ${Math.round(pt.y)}) — target the scrollable grid container (see ScrollContainers) or use browser_extract(mode: 'tables', scanHorizontal: true).`;
    }

    const msgParts = [];
    if (requestedDeltaY !== 0 || actualDeltaY !== 0) msgParts.push(`scrollDeltaY=${actualDeltaY}px (y=${Math.round(after.scrollY)})`);
    if (requestedDeltaX !== 0 || actualDeltaX !== 0) msgParts.push(`scrollDeltaX=${actualDeltaX}px (x=${Math.round(after.hitScrollLeft || after.scrollX)})`);

    return {
      mechanism: "cdp-wheel",
      message: blockedWarning ? blockedWarning : (msgParts.join(", ") || "scrolled"),
      scrollDeltaX: actualDeltaX,
      scrollDeltaY: actualDeltaY,
      blockedWarning
    };
  }

  if (action === "wait") {
    const ms = clamp(Number(step.durationMs ?? (step.selector || step.text ? 6000 : 500)), 0, 30000);
    if (step.selector || step.text) {
      const selLit = step.selector ? JSON.stringify(String(step.selector)) : "null";
      const txtLit = step.text ? JSON.stringify(String(step.text).toLowerCase()) : "null";
      const checkExpr = `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const sel = ${selLit};
        const txt = ${txtLit};
        if (sel) {
          const el = queryOneDeep(document, sel);
          if (!el) return false;
          const r = el.getBoundingClientRect();
          const st = window.getComputedStyle(el);
          if (!st || st.display === 'none' || st.visibility === 'hidden' || r.width < 2 || r.height < 2) return false;
          if (!txt) return true;
          return (el.innerText || '').toLowerCase().includes(txt);
        }
        if (txt) {
          return (document.body?.innerText || '').toLowerCase().includes(txt);
        }
        return true;
      })()`;
      const deadline = Date.now() + ms;
      let pollCount = 0;
      while (Date.now() < deadline) {
        if (isCancelled(tabId, cancelToken)) {
          throw CANCELLED_ERROR;
        }
        const topRes = await evalInFrame(tabId, null, checkExpr).catch(() => null);
        if (topRes?.result?.value === true) {
          return { mechanism: "wait-for", message: step.selector ? `Matched ${step.selector}` : `Matched text "${step.text}"` };
        }
        const session = getOrCreateTabSession(tabId);
        const childFrames = (pollCount % 3 === 0 || !session.lastChildFrames?.length)
          ? await discoverChildFrames(tabId).catch(() => session.lastChildFrames || [])
          : session.lastChildFrames;
        for (const frameMeta of childFrames) {
          if (isCancelled(tabId, cancelToken)) {
            throw CANCELLED_ERROR;
          }
          const childRes = await evalInFrame(tabId, frameMeta, checkExpr).catch(() => null);
          if (childRes?.result?.value === true) {
            return { mechanism: "wait-for (iframe)", message: step.selector ? `Matched ${step.selector}` : `Matched text "${step.text}"` };
          }
        }
        pollCount += 1;
        await sleepCancellable(Math.min(150, Math.max(0, deadline - Date.now())), tabId, cancelToken);
      }
      if (isCancelled(tabId, cancelToken)) {
        throw CANCELLED_ERROR;
      }
      throw new Error(`Timed out after ${ms}ms waiting for ${step.selector || step.text}`);
    }
    await sleepCancellable(ms, tabId, cancelToken);
    return { mechanism: "timer", message: null };
  }

  if (action === "uploadFile") {
    const files = Array.isArray(step.files) ? step.files.filter((f) => typeof f === "string" && f.trim().length > 0) : [];
    if (files.length === 0) {
      throw new Error("uploadFile requires a non-empty 'files' array of local file paths.");
    }

    const selLit = step.elementId
      ? usemacIdSelectorLiteral(step.elementId)
      : step.selector
        ? JSON.stringify(String(step.selector))
        : "null";

    const findInputExpr = `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const sel = ${selLit};
      let target = sel ? queryOneDeep(document, sel) : null;
      let input = null;
      if (target) {
        if (target.tagName === 'INPUT' && target.type === 'file') {
          input = target;
        } else if (target.tagName === 'LABEL' && target.control && target.control.type === 'file') {
          input = target.control;
        } else {
          input = queryOneDeep(target, 'input[type="file"]');
        }
        if (!input && target.parentElement) {
          const siblingInputs = queryAllDeep(target.parentElement, 'input[type="file"]');
          if (siblingInputs.length === 1) input = siblingInputs[0];
        }
      } else if (!sel) {
        const all = queryAllDeep(document, 'input[type="file"]');
        if (all.length >= 1) input = all[0];
      }
      return input || null;
    })()`;

    // Tier 1: Direct <input type="file"> across top frame and child OOPIFs/iframes (zero Finder!)
    const session = getOrCreateTabSession(tabId);
    const candidateFrames = [];
    const mappedFrame = step.elementId ? session.elementFrameMap.get(step.elementId) : null;
    if (mappedFrame) candidateFrames.push(mappedFrame);
    if (!mappedFrame || mappedFrame.frameId != null) candidateFrames.push(null);
    const extraFrames = session.lastChildFrames?.length
      ? session.lastChildFrames
      : await discoverChildFrames(tabId).catch(() => []);
    for (const f of extraFrames) {
      if (f !== mappedFrame) candidateFrames.push(f);
    }

    for (const frameMeta of candidateFrames) {
      const cdpSessionId = frameMeta?.sessionId || null;
      const directEval = await evalInFrame(tabId, frameMeta, findInputExpr, { returnByValue: false }).catch(() => null);
      const directObjectId = directEval?.result?.objectId;
      if (directObjectId) {
        try {
          const desc = await sendCDP(tabId, "DOM.describeNode", { objectId: directObjectId }, cdpSessionId);
          const backendNodeId = desc?.node?.backendNodeId;
          if (backendNodeId != null) {
            await sendCDP(tabId, "DOM.setFileInputFiles", {
              backendNodeId,
              files
            }, cdpSessionId);
            await sendCDP(tabId, "Runtime.callFunctionOn", {
              objectId: directObjectId,
              functionDeclaration: `function() {
                this.dispatchEvent(new Event('input', { bubbles: true }));
                this.dispatchEvent(new Event('change', { bubbles: true }));
              }`,
              returnByValue: true
            }, cdpSessionId).catch(() => {});
            await sleep(120);
            return {
              mechanism: frameMeta?.isOOPIF ? "cdp-file-input (iframe)" : "cdp-file-input",
              message: `Uploaded ${files.length} file(s): ${files.map((f) => f.split("/").pop()).join(", ")}`
            };
          }
        } finally {
          await sendCDP(tabId, "Runtime.releaseObject", { objectId: directObjectId }, cdpSessionId).catch(() => {});
        }
      }
    }

    // Tier 2: Intercept dynamic file chooser dialog before macOS Finder opens!
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error("uploadFile found no <input type='file'> and no clickable target (provide elementId, selector, or x/y).");
    }

    const pt = await moveCursorSmoothly(tabId, target.x, target.y, "Uploading");
    emitCursor(tabId, pt.x, pt.y, "click", "Uploading");
    const targetSessionId = target.frameMeta?.sessionId || null;

    await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: true }).catch(() => {});
    if (targetSessionId) {
      await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: true }, targetSessionId).catch(() => {});
    }
    let chooserEvent = null;
    try {
      const chooserPromise = waitForFileChooser(tabId, 2600);
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
      chooserEvent = await chooserPromise;
      if (chooserEvent?.backendNodeId != null) {
        await sendCDP(tabId, "DOM.setFileInputFiles", {
          backendNodeId: chooserEvent.backendNodeId,
          files
        }, chooserEvent.sessionId || targetSessionId || null);
        await sleep(140);
        return {
          mechanism: "cdp-file-chooser",
          message: `Uploaded ${files.length} file(s) via intercepted chooser: ${files.map((f) => f.split("/").pop()).join(", ")}`
        };
      }
    } finally {
      await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: false }).catch(() => {});
      if (targetSessionId) {
        await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: false }, targetSessionId).catch(() => {});
      }
    }

    // Tier 3: Synthetic drag-and-drop fallback for pure ondrop dropzones without <input>
    const dragData = { items: [], files, dragOperationsMask: 1 };
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "dragEnter",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await sleep(40);
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "dragOver",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await sleep(40);
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "drop",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await sleep(140);
    return {
      mechanism: "cdp-drag-drop",
      message: `Dropped ${files.length} file(s) at (${Math.round(pt.x)}, ${Math.round(pt.y)}): ${files.map((f) => f.split("/").pop()).join(", ")}`
    };
  }

  if (action === "target") {
    const target = await resolveStepTarget(tabId, step);
    if (target) {
      await moveCursorSmoothly(tabId, target.x, target.y, "Targeting");
    }
    return { mechanism: "cdp-target", message: null };
  }

  throw new Error(`Unsupported action step: ${action}`);
}

async function handleTabsCommand(req) {
  const query = (req.query || "").trim().toLowerCase();
  const rawTabs = await chrome.tabs.query({});
  const filtered = (rawTabs || []).filter((t) => {
    if (!query) return true;
    const hay = `${t.title || ""} ${t.url || ""}`.toLowerCase();
    return hay.includes(query);
  });
  const fileAccess = filtered.some((t) => /^file:/i.test(effectiveTabUrl(t))) ? await fileSchemeAccessAllowed() : false;
  // Tabs that belong to UseMac (in its tab group, or opened by it). The UseMac preview only shows pixels of
  // these; any other tab is the user's own.
  const usemacGroupIds = new Set();
  try {
    for (const group of (await chrome.tabGroups?.query({ title: USEMAC_GROUP_TITLE })) || []) {
      usemacGroupIds.add(group.id);
    }
  } catch (_) {}
  const ownedIds = await loadOwnedTabIds();
  const tabs = filtered.map((t) => {
    const info = {
      tabId: t.id,
      windowId: t.windowId ?? null,
      index: t.index ?? null,
      title: t.title || "",
      url: t.url || "",
      active: Boolean(t.active),
      pinned: Boolean(t.pinned),
      status: t.status || null,
      profileName: state.profileName
    };
    // Only present when true, so agents know up front that observe/act will answer RESTRICTED_PAGE.
    if (restrictedPageReason(effectiveTabUrl(t), { fileAccess })) {
      info.restricted = true;
    }
    if (ownedIds.has(t.id) || (t.groupId != null && usemacGroupIds.has(t.groupId))) {
      info.usemac = true;
    }
    return info;
  });

  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: state.lastTabId,
    profileName: state.profileName,
    url: null,
    title: null,
    tabs,
    snapshot: null,
    actionResult: null,
    error: null
  };
}

async function extractTablesSinglePass(tabId, scopeSelector = null, frameMeta = null) {
  const scopeLit = scopeSelector ? JSON.stringify(String(scopeSelector)) : "null";
  const evalRes = await evalInFrame(tabId, frameMeta, `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const scope = ${scopeLit} ? queryOneDeep(document, ${scopeLit}) : document;
      if (!scope) return { tables: [] };

      function isVisible(el) {
        const st = window.getComputedStyle(el);
        if (!st || st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
        const r = el.getBoundingClientRect();
        return r.width >= 2 && r.height >= 2;
      }

      function cellText(cell) {
        if (!cell) return '';
        const parts = [];
        const sw = cell.querySelector('input[type="checkbox"], [role="switch"], [role="checkbox"]');
        if (sw) {
          const checked = sw.tagName === 'INPUT' ? sw.checked : sw.getAttribute('aria-checked') === 'true';
          const rawTxt = (cell.innerText || '').replace(/\\s+/g, ' ').trim();
          if (!rawTxt) return checked ? '[ON]' : '[OFF]';
          parts.push(checked ? '[ON]' : '[OFF]');
        }
        const txt = (cell.innerText || cell.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();
        if (txt) parts.push(txt);
        return parts.join(' ').replace(/\\|/g, '/').slice(0, 120);
      }

      const tables = [];

      // 1. HTML tables
      const htmlTables = queryAllDeep(scope, 'table');
      for (let t = 0; t < htmlTables.length && tables.length < 8; t++) {
        const table = htmlTables[t];
        if (!isVisible(table)) continue;
        const rows = [];
        const trs = table.querySelectorAll('tr');
        for (let i = 0; i < trs.length && rows.length < 200; i++) {
          const cells = Array.from(trs[i].querySelectorAll('th, td')).map((c, idx) => ({
            colKey: 'h:' + idx,
            text: cellText(c)
          }));
          if (cells.length >= 2 && cells.some((c) => c.text.length > 0)) {
            rows.push({ rowKey: 'r:' + i, cells });
          }
        }
        if (rows.length >= 2) tables.push({ kind: 'table', rows });
      }

      // 2. ARIA grids/tables
      const grids = queryAllDeep(scope, '[role="grid"], [role="table"], [role="treegrid"]');
      for (let g = 0; g < grids.length && tables.length < 8; g++) {
        const grid = grids[g];
        if (!isVisible(grid)) continue;
        const rowEls = grid.querySelectorAll('[role="row"]');
        if (rowEls.length < 2) continue;
        const buckets = new Map();
        const order = [];
        for (let i = 0; i < rowEls.length && order.length < 220; i++) {
          const rowEl = rowEls[i];
          if (!isVisible(rowEl)) continue;
          const rr = rowEl.getBoundingClientRect();
          const cellEls = rowEl.querySelectorAll('[role="columnheader"], [role="rowheader"], [role="gridcell"], [role="cell"]');
          if (cellEls.length === 0) continue;
          const ariaIdx = rowEl.getAttribute('aria-rowindex');
          const key = ariaIdx ? ('aria:' + ariaIdx) : ('y:' + Math.round(rr.top / 4));
          if (!buckets.has(key)) {
            buckets.set(key, []);
            order.push(key);
          }
          const b = buckets.get(key);
          for (let c = 0; c < cellEls.length; c++) {
            const cell = cellEls[c];
            if (!isVisible(cell)) continue;
            const cr = cell.getBoundingClientRect();
            const ariaCol = cell.getAttribute('aria-colindex') || cell.getAttribute('data-col-id') || cell.getAttribute('data-testid') || '';
            b.push({ x: Math.round(cr.left), ariaCol, text: cellText(cell) });
          }
        }
        const rows = order.map((k) => {
          const sorted = buckets.get(k).sort((a, b) => a.x - b.x);
          return {
            rowKey: k,
            cells: sorted.map((item, idx) => ({
              colKey: item.ariaCol || ('x:' + idx),
              text: item.text
            }))
          };
        }).filter((r) => r.cells.length >= 2 && r.cells.some((c) => c.text.length > 0));
        if (rows.length >= 2) tables.push({ kind: 'grid', rows });
      }

      return { tables };
    })()`).catch(() => null);
  return evalRes?.result?.value?.tables || [];
}

function formatExtractedTablesToMarkdown(tables, maxChars = 16000) {
  const parts = [];
  let totalRows = 0;
  let maxCols = 0;
  for (let idx = 0; idx < tables.length; idx++) {
    const rows = tables[idx].rows || [];
    if (rows.length < 2) continue;
    const colCount = Math.max(...rows.map((r) => r.cells.length));
    if (colCount < 2) continue;
    maxCols = Math.max(maxCols, colCount);
    totalRows += rows.length - 1;
    const norm = rows.map((r) => {
      const vals = r.cells.map((c) => c.text || "");
      while (vals.length < colCount) vals.push("");
      return vals;
    });
    const header = "| " + norm[0].map((c, i) => c || `Col ${i + 1}`).join(" | ") + " |";
    const sep = "| " + norm[0].map(() => "---").join(" | ") + " |";
    const body = norm.slice(1).map((r) => "| " + r.join(" | ") + " |");
    parts.push([header, sep, ...body].join("\n"));
  }
  const md = parts.join("\n\n").slice(0, maxChars);
  return { markdown: md || null, rowCount: totalRows, columnCount: maxCols };
}

async function extractTablesWithHorizontalScan(tabId, scopeSelector = null, maxChars = 16000, frameMeta = null) {
  const scopeLit = scopeSelector ? JSON.stringify(String(scopeSelector)) : "null";
  const scrollerProbe = await evalInFrame(tabId, frameMeta, `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const root = ${scopeLit} ? queryOneDeep(document, ${scopeLit}) : document;
      if (!root) return null;
      const candidates = queryAllDeep(root, '[role="grid"], [role="table"], [role="treegrid"], div, section');
      let best = null;
      let bestOverflow = 0;
      for (let i = 0; i < candidates.length && i < 800; i++) {
        const el = candidates[i];
        const st = window.getComputedStyle(el);
        if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
        if (st.overflowX !== 'auto' && st.overflowX !== 'scroll') continue;
        const overflow = el.scrollWidth - el.clientWidth;
        if (overflow <= 40 || el.clientWidth < 200 || el.clientHeight < 80) continue;
        const hasGrid = el.matches?.('[role="grid"], [role="table"], [role="treegrid"]')
          || Boolean(el.querySelector?.('[role="gridcell"], [role="cell"], td, [role="columnheader"]'))
          || Boolean(el.closest?.('[role="grid"], [role="table"], [role="treegrid"]'));
        const score = overflow + (hasGrid ? 100000 : 0);
        if (score > bestOverflow) {
          bestOverflow = score;
          best = el;
        }
      }
      if (!best) return null;
      best.setAttribute('data-usemac-hscan', '1');
      return {
        origLeft: best.scrollLeft,
        clientWidth: best.clientWidth,
        scrollWidth: best.scrollWidth
      };
    })()`).catch(() => null);

  const info = scrollerProbe?.result?.value;
  if (!info || info.scrollWidth <= info.clientWidth + 40) {
    const single = await extractTablesSinglePass(tabId, scopeSelector, frameMeta);
    const fmt = formatExtractedTablesToMarkdown(single, maxChars);
    return { ...fmt, scannedSteps: 1 };
  }

  const maxScrollLeft = info.scrollWidth - info.clientWidth;
  const stepPx = Math.max(240, Math.round(info.clientWidth * 0.65));
  const positions = [0];
  for (let x = stepPx; x < maxScrollLeft; x += stepPx) {
    positions.push(x);
    if (positions.length >= 11) break;
  }
  if (positions[positions.length - 1] < maxScrollLeft) {
    positions.push(maxScrollLeft);
  }

  const mergedHeaders = [];
  const headerIndexByName = new Map();
  const mergedRowsByKey = new Map();
  const mergedRowOrder = [];
  let stepsDone = 0;

  try {
    for (const pos of positions) {
      await evalInFrame(tabId, frameMeta, `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const el = queryOneDeep(document, '[data-usemac-hscan="1"]');
          if (el) el.scrollLeft = ${pos};
        })()`);
      await sleep(180);
      stepsDone += 1;

      const passTables = await extractTablesSinglePass(tabId, scopeSelector, frameMeta);
      const primary = passTables.sort((a, b) => (b.rows?.length || 0) - (a.rows?.length || 0))[0];
      if (!primary || !primary.rows || primary.rows.length < 2) continue;

      const headerRow = primary.rows[0].cells;
      const colMapping = [];
      for (let c = 0; c < headerRow.length; c++) {
        const hText = (headerRow[c].text || "").trim() || `Col ${c + 1}`;
        const hKey = headerRow[c].colKey && !headerRow[c].colKey.startsWith("x:")
          ? `${headerRow[c].colKey}|${hText.toLowerCase()}`
          : hText.toLowerCase();
        let targetCol = headerIndexByName.get(hKey);
        if (targetCol == null) {
          targetCol = mergedHeaders.length;
          headerIndexByName.set(hKey, targetCol);
          mergedHeaders.push(hText);
        }
        colMapping.push(targetCol);
      }

      for (let r = 1; r < primary.rows.length; r++) {
        const row = primary.rows[r];
        const key = row.rowKey;
        if (!mergedRowsByKey.has(key)) {
          mergedRowsByKey.set(key, new Map());
          mergedRowOrder.push(key);
        }
        const rowMap = mergedRowsByKey.get(key);
        for (let c = 0; c < row.cells.length && c < colMapping.length; c++) {
          const val = row.cells[c].text;
          const colIdx = colMapping[c];
          if (val && !rowMap.has(colIdx)) {
            rowMap.set(colIdx, val);
          }
        }
      }
    }
  } finally {
    await evalInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = queryOneDeep(document, '[data-usemac-hscan="1"]');
        if (el) {
          el.scrollLeft = ${info.origLeft};
          el.removeAttribute('data-usemac-hscan');
        }
      })()`).catch(() => {});
  }

  if (mergedHeaders.length < 2 || mergedRowOrder.length === 0) {
    const fallback = await extractTablesSinglePass(tabId, scopeSelector, frameMeta);
    const fmt = formatExtractedTablesToMarkdown(fallback, maxChars);
    return { ...fmt, scannedSteps: stepsDone };
  }

  const headerLine = "| " + mergedHeaders.join(" | ") + " |";
  const sepLine = "| " + mergedHeaders.map(() => "---").join(" | ") + " |";
  const bodyLines = mergedRowOrder.map((k) => {
    const rowMap = mergedRowsByKey.get(k);
    const cells = mergedHeaders.map((_, idx) => rowMap.get(idx) || "");
    return "| " + cells.join(" | ") + " |";
  });

  const md = [headerLine, sepLine, ...bodyLines].join("\n").slice(0, maxChars);
  return {
    markdown: md,
    rowCount: mergedRowOrder.length,
    columnCount: mergedHeaders.length,
    scannedSteps: stepsDone
  };
}

async function extractTextAcrossFrames(tabId, scopeSelector, maxChars, childFrames) {
  const scopeLit = scopeSelector ? JSON.stringify(String(scopeSelector)) : "null";
  const expr = `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const sel = ${scopeLit};
    const root = sel ? queryOneDeep(document, sel) : (document.querySelector('main, [role="main"]') || document.body);
    if (!root) return '';
    return (root.innerText || '').split(/\\n+/).map((l) => l.replace(/\\s+/g, ' ').trim()).filter(Boolean).join('\\n');
  })()`;

  const blocks = [];
  let used = 0;
  const topRes = await evalInFrame(tabId, null, expr).catch(() => null);
  const topTxt = topRes?.result?.value || "";
  if (topTxt) {
    blocks.push(topTxt);
    used += topTxt.length;
  }

  for (const f of childFrames) {
    if (used >= maxChars) break;
    const cRes = await evalInFrame(tabId, f, expr).catch(() => null);
    const cTxt = cRes?.result?.value || "";
    if (!cTxt) continue;
    const label = f.title || f.url || "iframe";
    const chunk = `[iframe: ${label.slice(0, 64)}]\n${cTxt}`;
    blocks.push(chunk);
    used += chunk.length + 2;
  }
  return blocks.length > 0 ? blocks.join("\n\n").slice(0, maxChars) : null;
}

async function extractKpisAcrossFrames(tabId, scopeSelector, maxChars, childFrames) {
  const scopeLit = scopeSelector ? JSON.stringify(String(scopeSelector)) : "null";
  const expr = `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const sel = ${scopeLit};
    const root = sel ? queryOneDeep(document, sel) : (document.querySelector('main, [role="main"]') || document.body);
    if (!root) return '';
    const lines = [];
    const seen = new Set();
    const headings = queryAllDeep(root, 'h1, h2, h3, [role="heading"]');
    for (let i = 0; i < headings.length && i < 20; i++) {
      const t = (headings[i].innerText || '').replace(/\\s+/g, ' ').trim();
      if (t && !seen.has(t)) { seen.add(t); lines.push('# ' + t); }
    }
    const metricRe = /(R\\$|US\\$|\\$|€|£|%|\\d[\\d.,]*\\s*(x|k|m|mil|bi)\\b|\\b\\d{1,3}([.,]\\d{3})+([.,]\\d+)?\\b|\\b\\d+[.,]\\d+\\b)/i;
    const blocks = queryAllDeep(root, 'div, section, article, li, td, [role="gridcell"]');
    for (let i = 0; i < blocks.length && lines.length < 160; i++) {
      const el = blocks[i];
      if (el.children.length > 4) continue;
      const st = window.getComputedStyle(el);
      if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
      const t = (el.innerText || '').replace(/\\s+/g, ' ').trim();
      if (t.length < 2 || t.length > 140) continue;
      if (!metricRe.test(t)) continue;
      if (seen.has(t)) continue;
      seen.add(t);
      lines.push(t);
    }
    return lines.join('\\n');
  })()`;

  const blocks = [];
  let used = 0;
  const topRes = await evalInFrame(tabId, null, expr).catch(() => null);
  const topTxt = topRes?.result?.value || "";
  if (topTxt) {
    blocks.push(topTxt);
    used += topTxt.length;
  }
  for (const f of childFrames) {
    if (used >= maxChars) break;
    const cRes = await evalInFrame(tabId, f, expr).catch(() => null);
    const cTxt = cRes?.result?.value || "";
    if (!cTxt) continue;
    blocks.push(cTxt);
    used += cTxt.length + 2;
  }
  return blocks.length > 0 ? blocks.join("\n\n").slice(0, maxChars) : null;
}

async function handleExtractCommand(req, preResolvedTab = null) {
  const start = performance.now();
  const mode = String(req.mode || "auto").toLowerCase();
  const maxChars = clamp(Number(req.maxChars) || 16000, 500, 64000);

  if (mode === "downloads") {
    const downloads = getRecordedDownloads(20);
    return {
      type: "response",
      id: req.id,
      ok: true,
      tabId: req.tabId ?? state.lastTabId ?? null,
      profileName: state.profileName,
      url: null,
      title: null,
      extractResult: {
        mode: "downloads",
        tabId: req.tabId ?? state.lastTabId ?? null,
        url: null,
        title: null,
        latencyMs: Math.round((performance.now() - start) * 100) / 100,
        downloads
      },
      snapshot: null,
      actionResult: null,
      error: null
    };
  }

  const tab = preResolvedTab || await resolveTargetTab(req.tabId);
  await assertTabScriptable(tab.id);
  if (req.tabId != null) {
    await ensureTabInUsemacGroup(tab.id);
  }
  await ensureAttached(tab.id);
  resetIdleTimer(tab.id);
  // The UseMac preview brings this tab's card to the front: send a fresh frame so it does not show
  // whatever was captured while the page was still loading.
  captureAndEmitFrame(tab.id).catch(() => {});
  const tabInfo = await refreshTabMeta(tab.id);

  let tablesMarkdown = null;
  let rowCount = null;
  let columnCount = null;
  let scannedHorizontalSteps = null;
  let text = null;
  let jsonResult = null;
  let downloads = null;

  const childFrames = mode !== "eval" ? await discoverChildFrames(tab.id).catch(() => []) : [];

  if (mode === "eval") {
    const expr = String(req.expression || "").trim();
    if (!expr) {
      throw { code: "INVALID_ARGUMENT", message: "extract mode 'eval' requires expression." };
    }
    const evalRes = await sendCDP(tab.id, "Runtime.evaluate", {
      expression: expr,
      returnByValue: true,
      awaitPromise: true
    });
    if (evalRes?.exceptionDetails) {
      const excText = evalRes.exceptionDetails.exception?.description || evalRes.exceptionDetails.text || "JS evaluation failed";
      throw { code: "EVAL_ERROR", message: excText };
    }
    const val = evalRes?.result?.value;
    const serialized = typeof val === "string" ? val : JSON.stringify(val ?? null, null, 2);
    jsonResult = (serialized || "null").slice(0, maxChars);
  } else if (mode === "tables" || mode === "auto") {
    const framesToScan = [null, ...childFrames];
    const mdParts = [];
    let totalRows = 0;
    let maxCols = 0;
    let totalSteps = 0;
    for (const fMeta of framesToScan) {
      const remainingChars = maxChars - mdParts.join("\n\n").length;
      if (remainingChars < 200) break;
      if (req.scanHorizontal) {
        const scanned = await extractTablesWithHorizontalScan(tab.id, req.selector || null, remainingChars, fMeta);
        if (scanned.markdown) {
          mdParts.push(scanned.markdown);
          totalRows += scanned.rowCount || 0;
          maxCols = Math.max(maxCols, scanned.columnCount || 0);
        }
        totalSteps = Math.max(totalSteps, scanned.scannedSteps || 1);
      } else {
        const single = await extractTablesSinglePass(tab.id, req.selector || null, fMeta);
        const fmt = formatExtractedTablesToMarkdown(single, remainingChars);
        if (fmt.markdown) {
          mdParts.push(fmt.markdown);
          totalRows += fmt.rowCount || 0;
          maxCols = Math.max(maxCols, fmt.columnCount || 0);
        }
        totalSteps = 1;
      }
    }
    tablesMarkdown = mdParts.length > 0 ? mdParts.join("\n\n").slice(0, maxChars) : null;
    rowCount = totalRows;
    columnCount = maxCols;
    scannedHorizontalSteps = totalSteps || 1;
    if (mode === "auto") {
      const txtBudget = tablesMarkdown ? Math.max(2000, maxChars - tablesMarkdown.length) : maxChars;
      text = await extractTextAcrossFrames(tab.id, req.selector || null, txtBudget, childFrames);
    }
  } else if (mode === "kpis") {
    text = await extractKpisAcrossFrames(tab.id, req.selector || null, maxChars, childFrames);
  } else if (mode === "text") {
    text = await extractTextAcrossFrames(tab.id, req.selector || null, maxChars, childFrames);
  } else {
    throw { code: "INVALID_ARGUMENT", message: `Unsupported extract mode: ${mode}. Use auto, tables, text, kpis, eval, or downloads.` };
  }

  resetIdleTimer(tab.id);
  const latencyMs = Math.round((performance.now() - start) * 100) / 100;

  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    profileName: state.profileName,
    url: tabInfo?.url || null,
    title: tabInfo?.title || null,
    extractResult: {
      mode,
      tabId: tab.id,
      url: tabInfo?.url || null,
      title: tabInfo?.title || null,
      latencyMs,
      tablesMarkdown,
      rowCount,
      columnCount,
      scannedHorizontalSteps,
      text,
      jsonResult,
      downloads
    },
    snapshot: null,
    actionResult: null,
    error: null
  };
}

async function handleScreenshotCommand(req, preResolvedTab = null) {
  const start = performance.now();
  const tab = preResolvedTab || await resolveTargetTab(req.tabId);
  try {
    return await captureTabScreenshot(req, tab, start);
  } finally {
    // An explicit viewport may have overridden a tab the user is looking at; give it its real size back.
    if (hasExplicitViewport(req)) await restoreVisibleViewport(tab.id);
  }
}

async function captureTabScreenshot(req, tab, start) {
  await assertTabScriptable(tab.id);
  if (req.tabId != null) {
    await ensureTabInUsemacGroup(tab.id);
  }
  await ensureAttached(tab.id);
  resetIdleTimer(tab.id);
  captureAndEmitFrame(tab.id).catch(() => {});

  if (hasExplicitViewport(req)) {
    await applyViewportMetrics(
      tab.id,
      req.viewportWidth ?? null,
      req.viewportHeight ?? null,
      req.deviceScaleFactor ?? null
    );
    await sleep(100);
  }

  const session = getOrCreateTabSession(tab.id);
  const scale = session.deviceScaleFactor || 1;
  const quality = clamp(Number(req.quality) || 84, 30, 100);
  const fullPage = req.fullPage === true;

  let clip = undefined;
  const viewport = effectiveViewport(session);
  let outW = Math.round(viewport.width * viewport.scale);
  let outH = Math.round(viewport.height * viewport.scale);

  if (req.elementId || req.selector) {
    const selLit = req.elementId
      ? usemacIdSelectorLiteral(req.elementId)
      : JSON.stringify(String(req.selector));
    const candidateFrames = [];
    const mapped = req.elementId ? session.elementFrameMap.get(req.elementId) : null;
    if (mapped) candidateFrames.push(mapped);
    if (!mapped || mapped.frameId != null) candidateFrames.push(null);
    const childFrames = session.lastChildFrames?.length
      ? session.lastChildFrames
      : await discoverChildFrames(tab.id).catch(() => []);
    for (const f of childFrames) {
      if (f !== mapped) candidateFrames.push(f);
    }

    let box = null;
    for (const fMeta of candidateFrames) {
      let offsetX = 0;
      let offsetY = 0;
      if (fMeta && fMeta.frameId != null) {
        const fRect = await computeFrameViewportRect(tab.id, fMeta, true);
        if (!fRect || !fRect.visible) continue;
        offsetX = fRect.x;
        offsetY = fRect.y;
      }
      const rectEval = await evalInFrame(tab.id, fMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = queryOneDeep(document, ${selLit});
        if (!el) return null;
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        return {
          left: r.left,
          top: r.top,
          width: Math.max(4, r.width),
          height: Math.max(4, r.height)
        };
      })()`).catch(() => null);
      const localBox = rectEval?.result?.value;
      if (localBox) {
        const topScroll = await sendCDP(tab.id, "Runtime.evaluate", {
          expression: `({ sx: window.scrollX || 0, sy: window.scrollY || 0 })`,
          returnByValue: true
        }).catch(() => null);
        const sx = topScroll?.result?.value?.sx || 0;
        const sy = topScroll?.result?.value?.sy || 0;
        box = {
          x: Math.max(0, localBox.left + offsetX + sx),
          y: Math.max(0, localBox.top + offsetY + sy),
          width: localBox.width,
          height: localBox.height
        };
        break;
      }
    }
    if (!box) {
      throw { code: "ELEMENT_NOT_FOUND", message: `Screenshot target ${req.elementId || req.selector} not found.` };
    }
    clip = { x: box.x, y: box.y, width: box.width, height: box.height, scale };
    outW = Math.round(box.width * scale);
    outH = Math.round(box.height * scale);
  } else if (fullPage) {
    const metrics = await sendCDP(tab.id, "Page.getLayoutMetrics").catch(() => null);
    const cs = metrics?.cssContentSize || metrics?.contentSize;
    if (cs && cs.width > 0 && cs.height > 0) {
      const cappedH = Math.min(cs.height, 6000);
      clip = { x: 0, y: 0, width: cs.width, height: cappedH, scale };
      outW = Math.round(cs.width * scale);
      outH = Math.round(cappedH * scale);
    }
  }

  const capParams = {
    format: "jpeg",
    quality,
    fromSurface: true
  };
  if (clip) {
    capParams.clip = clip;
    capParams.captureBeyondViewport = true;
  }

  const cap = await sendCDP(tab.id, "Page.captureScreenshot", capParams);
  if (!cap?.data) {
    throw { code: "CAPTURE_FAILED", message: "CDP Page.captureScreenshot returned empty data." };
  }

  const tabInfo = await refreshTabMeta(tab.id);
  const latencyMs = Math.round((performance.now() - start) * 100) / 100;
  resetIdleTimer(tab.id);

  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    profileName: state.profileName,
    url: tabInfo?.url || session.url,
    title: tabInfo?.title || session.title,
    screenshotBase64: cap.data,
    screenshotWidth: outW,
    screenshotHeight: outH,
    screenshotLatencyMs: latencyMs,
    snapshot: null,
    actionResult: null,
    error: null
  };
}

// Tabs UseMac itself opened (new tab or new window). Only these are closed when a task completes; tabs the
// user had open (reached through tabId) are never closed. Kept in session storage so a service-worker
// restart does not forget them.
const OWNED_TABS_KEY = "usemacOwnedTabIds";

async function loadOwnedTabIds() {
  try {
    const stored = await chrome.storage.session.get(OWNED_TABS_KEY);
    return new Set(Array.isArray(stored?.[OWNED_TABS_KEY]) ? stored[OWNED_TABS_KEY] : []);
  } catch (_) {
    return new Set();
  }
}

async function saveOwnedTabIds(ids) {
  try {
    await chrome.storage.session.set({ [OWNED_TABS_KEY]: Array.from(ids) });
  } catch (_) {}
}

async function markTabOwned(tabId) {
  if (tabId == null) return;
  const ids = await loadOwnedTabIds();
  ids.add(tabId);
  await saveOwnedTabIds(ids);
}

async function forgetOwnedTab(tabId) {
  const ids = await loadOwnedTabIds();
  if (ids.delete(tabId)) {
    await saveOwnedTabIds(ids);
  }
}

function hasRunningDownloadFrom(tabUrl, busyDownloadUrls) {
  if (!tabUrl || busyDownloadUrls.size === 0) return false;
  let origin;
  try {
    origin = new URL(tabUrl).origin;
  } catch (_) {
    return false;
  }
  return Array.from(busyDownloadUrls).some((u) => {
    try {
      return new URL(u).origin === origin;
    } catch (_) {
      return false;
    }
  });
}

// Closes the tabs UseMac opened, except: tabs listed in keepTabIds, the tab the user is looking at (active in
// the focused window) and tabs with a download still in progress. Returns what was closed and what was kept.
async function handleCloseOwnedTabsCommand(req) {
  const keep = new Set(Array.isArray(req.keepTabIds) ? req.keepTabIds.map(Number) : []);
  const owned = await loadOwnedTabIds();
  const closed = [];
  const kept = [];
  let focusedWindowId = null;
  try {
    const focused = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
    if (focused?.focused) focusedWindowId = focused.id;
  } catch (_) {}
  const busyDownloadUrls = new Set(
    Array.from(state.downloads.values())
      .filter((d) => (d.state || "in_progress") === "in_progress")
      .map((d) => d.url)
      .filter(Boolean)
  );

  for (const tabId of owned) {
    const tab = await getTabOrNull(tabId);
    if (!tab) {
      owned.delete(tabId);
      continue;
    }
    let reason = null;
    if (keep.has(tabId)) reason = "asked to keep";
    else if (tab.active && tab.windowId === focusedWindowId) reason = "the user is looking at it";
    else if (hasRunningDownloadFrom(tab.url, busyDownloadUrls)) {
      reason = "a download is still running";
    }
    if (reason) {
      kept.push({ tabId, title: tab.title || "", reason });
      continue;
    }
    try {
      await chrome.tabs.remove(tabId);
      owned.delete(tabId);
      closed.push({ tabId, title: tab.title || "" });
    } catch (err) {
      kept.push({ tabId, title: tab.title || "", reason: String(err?.message || err) });
    }
  }
  await saveOwnedTabIds(owned);
  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: null,
    profileName: state.profileName,
    url: null,
    title: null,
    closedTabs: closed,
    keptTabs: kept,
    snapshot: null,
    actionResult: null,
    error: null
  };
}

function createUsemacWindow(url) {
  // focused: false keeps the user's current window in front.
  return chrome.windows.create({ url, focused: false, type: "normal" });
}

// open with tabId, an empty url and activate: true. Pure tab management: no navigation, no debugger, and the
// tab is not moved into the UseMac group (it usually is the user's own tab).
async function handleActivateTabCommand(req) {
  const tab = await resolveTargetTab(req.tabId);
  const updated = (await chrome.tabs.update(tab.id, { active: true })) || tab;
  const current = (await getTabOrNull(tab.id)) || updated;
  const reason = await tabRestrictionReason(current);
  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: current.id ?? tab.id,
    windowId: current.windowId ?? null,
    profileName: state.profileName,
    url: current.url || null,
    title: current.title || null,
    restricted: reason ? true : undefined,
    activated: true,
    snapshot: reason ? restrictedPageSnapshot(current, reason, { activated: true }) : null,
    actionResult: null,
    error: null
  };
}

async function handleOpenCommand(req) {
  const targetUrl = typeof req.url === "string" ? req.url.trim() : "";
  const activate = req.activate === true;
  const newWindow = req.newWindow === true;

  if (!targetUrl) {
    if (req.tabId != null && activate && !newWindow) {
      return handleActivateTabCommand(req);
    }
    throw {
      code: "INVALID_ARGUMENT",
      message: "open requires url. To only switch to a tab, pass tabId with url \"\" and activate: true."
    };
  }
  if (newWindow && req.tabId != null) {
    throw {
      code: "INVALID_ARGUMENT",
      message: "newWindow opens the URL in a new UseMac window and cannot be combined with tabId."
    };
  }
  assertAllowedUrl(targetUrl);

  let tab;
  let createdByUsemac = false;
  if (newWindow) {
    const createdWin = await createUsemacWindow(targetUrl);
    tab = createdWin?.tabs?.[0];
    if (!tab) {
      throw { code: "WINDOW_ERROR", message: "Failed to create a UseMac Chrome window." };
    }
    createdByUsemac = true;
  } else {
    const windows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    if (windows.length === 0) {
      const createdWin = await createUsemacWindow(targetUrl);
      tab = createdWin?.tabs?.[0];
      if (!tab) {
        throw { code: "WINDOW_ERROR", message: "Failed to create background Chrome window." };
      }
      createdByUsemac = true;
    } else {
      const targetWin = windows.find((w) => w.focused) || windows[0];
      if (req.newTab !== false && req.tabId == null) {
        tab = await chrome.tabs.create({
          windowId: targetWin.id,
          url: targetUrl,
          active: activate
        });
        createdByUsemac = true;
      } else {
        const existing = await resolveTargetTab(req.tabId);
        const update = { url: targetUrl };
        if (activate) update.active = true;
        tab = await chrome.tabs.update(existing.id, update);
      }
    }
  }

  if (createdByUsemac) {
    await markTabOwned(tab.id);
  }
  await ensureTabInUsemacGroup(tab.id);
  const loaded = await waitForTabLoad(tab.id, 3000);
  const current = loaded || (await getTabOrNull(tab.id)) || tab;
  // Remember the tab even when no debugger attaches below (restricted pages), so commands without a tabId find
  // it. Set after the load: Chrome's forced detach during navigation onto a restricted page clears lastTabId.
  state.lastTabId = tab.id;

  // Navigation worked, but Chrome will not let the debugger in (and would detach it if it were attached):
  // answer without streaming or observing, with guidance for native Accessibility instead.
  const restrictedResponse = (tabNow, reason) => ({
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    windowId: tabNow.windowId ?? tab.windowId ?? null,
    profileName: state.profileName,
    url: tabNow.url || targetUrl,
    title: tabNow.title || "",
    restricted: true,
    snapshot: restrictedPageSnapshot(tabNow, reason),
    actionResult: null,
    error: null
  });
  const restriction = await tabRestrictionReason(current);
  if (restriction) {
    return restrictedResponse(current, restriction);
  }

  let tabInfo;
  let snapshot;
  try {
    if (req.stream !== false) {
      await ensureStreaming(tab.id);
    } else {
      await ensureAttached(tab.id);
      resetIdleTimer(tab.id);
    }
    ({ tab: tabInfo, snapshot } = await observeTab(tab.id, req.maxElements || 280));
  } catch (err) {
    // Still loading when we checked, then landed on (or redirected to) a restricted page.
    const mapped = await toRestrictedPageErrorIfNeeded(err, tab.id);
    if (mapped?.code !== "RESTRICTED_PAGE") {
      throw err;
    }
    const latest = (await getTabOrNull(tab.id)) || current;
    return restrictedResponse(latest, (await tabRestrictionReason(latest)) || "refused");
  }
  resetIdleTimer(tab.id);

  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    windowId: tabInfo?.windowId ?? current.windowId ?? null,
    profileName: state.profileName,
    url: tabInfo?.url || targetUrl,
    title: tabInfo?.title || snapshot.app.windowTitle || "",
    snapshot,
    actionResult: null,
    error: null
  };
}

async function handleObserveCommand(req, preResolvedTab = null) {
  const tab = preResolvedTab || await resolveTargetTab(req.tabId);
  await assertTabScriptable(tab.id);
  if (req.tabId != null) {
    await ensureTabInUsemacGroup(tab.id);
  }
  const session = getOrCreateTabSession(tab.id);
  await ensureStreaming(tab.id);
  const { tab: tabInfo, snapshot, screenshotBase64 } = await observeTab(tab.id, req.maxElements || 280, {
    includeText: req.includeText !== false,
    includeTables: req.includeTables !== false,
    includeScreenshot: req.includeScreenshot === true,
    viewportWidth: req.viewportWidth ?? null,
    viewportHeight: req.viewportHeight ?? null,
    deviceScaleFactor: req.deviceScaleFactor ?? null
  });
  resetIdleTimer(tab.id);

  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    profileName: state.profileName,
    url: tabInfo?.url || session.url,
    title: tabInfo?.title || session.title,
    snapshot,
    screenshotBase64: screenshotBase64 || null,
    actionResult: null,
    error: null
  };
}

async function handleActCommand(req, preResolvedTab = null, cancelToken = null) {
  const tab = preResolvedTab || await resolveTargetTab(req.tabId);
  await assertTabScriptable(tab.id);
  await ensureTabInUsemacGroup(tab.id);
  const session = getOrCreateTabSession(tab.id);
  await ensureStreaming(tab.id);

  const steps = Array.isArray(req.steps) ? req.steps : [];
  const stopOnError = req.stopOnError !== false;
  const returnObservation = req.returnObservation !== false;

  const batchStart = performance.now();
  const stepResults = [];
  let allSucceeded = true;
  let cancelled = false;

  for (let i = 0; i < steps.length; i++) {
    if (isCancelled(tab.id, cancelToken)) {
      allSucceeded = false;
      cancelled = true;
      for (let j = i; j < steps.length; j++) {
        stepResults.push({
          index: j,
          action: steps[j]?.action,
          success: false,
          mechanism: "cancelled",
          latencyMs: 0,
          message: CANCELLED_MESSAGE
        });
      }
      break;
    }

    const step = steps[i];
    const stepStart = performance.now();
    resetIdleTimer(tab.id);

    try {
      if (stepNeedsDebugger(step)) {
        const blocked = await restrictedPageErrorIfDetached(tab.id);
        if (blocked) throw blocked;
      }
      const outcome = await executeActionStep(tab.id, step, cancelToken);
      stepResults.push({
        index: i,
        action: step.action,
        success: true,
        mechanism: outcome.mechanism,
        latencyMs: Math.round((performance.now() - stepStart) * 100) / 100,
        message: outcome.message ?? null,
        scrollDeltaX: outcome.scrollDeltaX ?? null,
        scrollDeltaY: outcome.scrollDeltaY ?? null,
        blockedWarning: outcome.blockedWarning ?? null,
        downloadPath: outcome.downloadPath ?? null
      });
    } catch (err) {
      if (err?.code === "URL_BLOCKED") {
        throw err;
      }
      if (err?.code === "CANCELLED" || isCancelled(tab.id, cancelToken)) {
        allSucceeded = false;
        cancelled = true;
        stepResults.push({
          index: i,
          action: step.action,
          success: false,
          mechanism: "cancelled",
          latencyMs: Math.round((performance.now() - stepStart) * 100) / 100,
          message: CANCELLED_MESSAGE
        });
        for (let j = i + 1; j < steps.length; j++) {
          stepResults.push({
            index: j,
            action: steps[j]?.action,
            success: false,
            mechanism: "cancelled",
            latencyMs: 0,
            message: CANCELLED_MESSAGE
          });
        }
        break;
      }
      allSucceeded = false;
      // A step that navigated onto a restricted page makes Chrome detach the debugger; say so instead of
      // reporting "Debugger is not attached" for the next step.
      let mapped = await toRestrictedPageErrorIfNeeded(err, tab.id);
      if (mapped?.code !== "RESTRICTED_PAGE" && stepNeedsDebugger(step)) {
        mapped = (await restrictedPageErrorIfDetached(tab.id)) || mapped;
      }
      const restricted = mapped?.code === "RESTRICTED_PAGE";
      stepResults.push({
        index: i,
        action: step.action,
        success: false,
        mechanism: restricted ? "restricted-page" : "cdp-error",
        latencyMs: Math.round((performance.now() - stepStart) * 100) / 100,
        message: restricted ? mapped.message : (err?.message || String(err)),
        errorCode: restricted ? "RESTRICTED_PAGE" : (typeof err?.code === "string" ? err.code : null)
      });
      if (stopOnError) {
        break;
      }
    }
  }

  if (cancelled || isCancelled(tab.id, cancelToken)) {
    const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;
    return {
      type: "response",
      id: req.id,
      ok: false,
      tabId: tab.id,
      profileName: state.profileName,
      url: session.url || tab.url || null,
      title: session.title || tab.title || null,
      screenshotBase64: null,
      screenshotWidth: null,
      screenshotHeight: null,
      screenshotLatencyMs: null,
      snapshot: null,
      actionResult: {
        success: false,
        totalLatencyMs,
        stepResults,
        observation: null
      },
      error: {
        code: "CANCELLED",
        message: CANCELLED_MESSAGE
      }
    };
  }

  // The batch may have navigated onto a restricted page (openURL, or a click on a store link). Chrome detached
  // the debugger there, so skip the CDP observation and frame capture and hand back the guidance instead.
  const finalTab = await getTabOrNull(tab.id);
  const finalRestriction = finalTab ? await tabRestrictionReason(finalTab) : null;
  if (finalRestriction) {
    const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;
    return {
      type: "response",
      id: req.id,
      ok: true,
      tabId: tab.id,
      windowId: finalTab.windowId ?? null,
      profileName: state.profileName,
      url: finalTab.url || null,
      title: finalTab.title || null,
      restricted: true,
      screenshotBase64: null,
      screenshotWidth: null,
      screenshotHeight: null,
      screenshotLatencyMs: null,
      snapshot: null,
      actionResult: {
        success: allSucceeded,
        totalLatencyMs,
        stepResults,
        observation: null,
        agentFeedback: restrictedPageFeedback(finalTab, finalRestriction)
      },
      error: null
    };
  }

  await sleep(40);
  await captureAndEmitFrame(tab.id);
  resetIdleTimer(tab.id);

  let observation = null;
  let tabInfo = await refreshTabMeta(tab.id);
  let screenshotBase64 = null;
  let screenshotWidth = null;
  let screenshotHeight = null;
  let screenshotLatencyMs = null;

  if (returnObservation) {
    const observed = await observeTab(tab.id, req.maxElements || 280, {
      includeScreenshot: req.includeScreenshot === true
    });
    observation = observed.snapshot;
    tabInfo = observed.tab || tabInfo;
    if (observed.screenshotBase64) {
      screenshotBase64 = observed.screenshotBase64;
      const viewport = effectiveViewport(session);
      screenshotWidth = Math.round(viewport.width * viewport.scale);
      screenshotHeight = Math.round(viewport.height * viewport.scale);
    }
  } else if (req.includeScreenshot === true) {
    const shotStart = performance.now();
    try {
      const cap = await sendCDP(tab.id, "Page.captureScreenshot", {
        format: "jpeg",
        quality: 82,
        fromSurface: true
      });
      if (cap?.data) {
        screenshotBase64 = cap.data;
        const viewport = effectiveViewport(session);
        screenshotWidth = Math.round(viewport.width * viewport.scale);
        screenshotHeight = Math.round(viewport.height * viewport.scale);
        screenshotLatencyMs = Math.round((performance.now() - shotStart) * 100) / 100;
      }
    } catch (_) {}
  }

  const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;

  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    profileName: state.profileName,
    url: tabInfo?.url || session.url,
    title: tabInfo?.title || session.title,
    screenshotBase64,
    screenshotWidth,
    screenshotHeight,
    screenshotLatencyMs,
    snapshot: null,
    actionResult: {
      success: allSucceeded,
      totalLatencyMs,
      stepResults,
      observation
    },
    error: null
  };
}

async function handleFocusTabCommand(req) {
  const tab = await resolveTargetTab(req.tabId);
  const updated = await chrome.tabs.update(tab.id, { active: true, highlighted: true });
  const winId = updated?.windowId ?? tab.windowId;
  if (winId != null) {
    const updateInfo = { focused: true };
    try {
      const win = await chrome.windows.get(winId);
      if (win?.state === "minimized") {
        updateInfo.state = "normal";
      }
    } catch (_) {}
    await chrome.windows.update(winId, updateInfo);
  }
  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    profileName: state.profileName,
    url: updated?.url || tab.url || null,
    title: updated?.title || tab.title || null,
    snapshot: null,
    actionResult: null,
    error: null
  };
}

async function handleStopStreamCommand(req) {
  const targetTabId = req.tabId ?? null;
  if (targetTabId != null) {
    await stopStreamingAndDetach(targetTabId, true);
  } else {
    const allIds = Array.from(state.tabSessions.keys());
    for (const id of allIds) {
      await stopStreamingAndDetach(id, true);
    }
  }
  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: targetTabId,
    profileName: state.profileName,
    url: null,
    title: null,
    snapshot: null,
    actionResult: null,
    error: null
  };
}

function sendCancelledResponse(req, tabId = null) {
  sendWS({
    type: "response",
    id: req.id,
    ok: false,
    tabId: tabId ?? req.tabId ?? state.lastTabId ?? null,
    profileName: state.profileName,
    url: null,
    title: null,
    snapshot: null,
    actionResult: null,
    error: {
      code: "CANCELLED",
      message: CANCELLED_MESSAGE
    }
  });
}

function dispatchDaemonRequest(req) {
  if (req.command === "tabs" || req.command === "close_owned_tabs" || (req.command === "extract" && String(req.mode || "").toLowerCase() === "downloads")) {
    handleDaemonRequest(req);
    return;
  }

  const reqGlobalGen = state.cancelGeneration;

  if (req.command === "open") {
    const reqTabGen = req.tabId != null ? getTabCancelGen(req.tabId) : null;
    const cancelToken = createCancelToken(req.tabId ?? null, reqGlobalGen, reqTabGen);
    enqueueOpenCommand(async () => {
      if (isCancelled(req.tabId ?? null, cancelToken)) {
        sendCancelledResponse(req, req.tabId ?? null);
        return;
      }
      await handleDaemonRequest(req, null, cancelToken);
    });
    return;
  }

  if (req.command === "focus_tab") {
    handleDaemonRequest(req);
    return;
  }

  if (req.command === "stop_stream") {
    if (req.tabId != null) {
      const cancelToken = createCancelToken(req.tabId, reqGlobalGen);
      enqueueTabCommand(req.tabId, () => handleDaemonRequest(req, null, cancelToken));
    } else {
      const cancelToken = createCancelToken(null, reqGlobalGen, 0);
      enqueueOpenCommand(() => handleDaemonRequest(req, null, cancelToken));
    }
    return;
  }

  const reqTabGen = req.tabId != null ? getTabCancelGen(req.tabId) : null;

  (async () => {
    try {
      const tab = await resolveTargetTab(req.tabId);
      const cancelToken = createCancelToken(tab.id, reqGlobalGen, reqTabGen != null ? reqTabGen : getTabCancelGen(tab.id));
      if (isCancelled(tab.id, cancelToken)) {
        sendCancelledResponse(req, tab.id);
        return;
      }
      enqueueTabCommand(tab.id, () => handleDaemonRequest(req, tab, cancelToken));
    } catch (err) {
      sendWS({
        type: "response",
        id: req.id,
        ok: false,
        tabId: req.tabId ?? state.lastTabId ?? null,
        profileName: state.profileName,
        url: null,
        title: null,
        snapshot: null,
        actionResult: null,
        error: {
          code: err?.code || "EXTENSION_ERROR",
          message: err?.message || String(err)
        }
      });
    }
  })();
}

async function handleDaemonRequest(req, preResolvedTab = null, cancelToken = null) {
  await resolveProfileInfo();
  const targetTabId = preResolvedTab?.id ?? req.tabId ?? null;
  if (cancelToken && isCancelled(targetTabId, cancelToken)) {
    sendCancelledResponse(req, targetTabId);
    return;
  }
  try {
    let response;
    switch (req.command) {
      case "tabs":
        response = await handleTabsCommand(req);
        break;
      case "open":
        response = await handleOpenCommand(req);
        break;
      case "observe":
        response = await handleObserveCommand(req, preResolvedTab);
        break;
      case "extract":
        response = await handleExtractCommand(req, preResolvedTab);
        break;
      case "screenshot":
        response = await handleScreenshotCommand(req, preResolvedTab);
        break;
      case "act":
        response = await handleActCommand(req, preResolvedTab, cancelToken);
        break;
      case "focus_tab":
        response = await handleFocusTabCommand(req);
        break;
      case "stop_stream":
        response = await handleStopStreamCommand(req);
        break;
      case "close_owned_tabs":
        response = await handleCloseOwnedTabsCommand(req);
        break;
      default:
        throw { code: "UNKNOWN_COMMAND", message: `Unknown command: ${req.command}` };
    }
    sendWS(response);
  } catch (rawErr) {
    let err = rawErr;
    try {
      err = await toRestrictedPageErrorIfNeeded(rawErr, targetTabId);
    } catch (_) {}
    sendWS({
      type: "response",
      id: req.id,
      ok: false,
      tabId: req.tabId ?? preResolvedTab?.id ?? state.lastTabId ?? null,
      profileName: state.profileName,
      url: null,
      title: null,
      snapshot: null,
      actionResult: null,
      error: {
        code: err?.code || "EXTENSION_ERROR",
        message: err?.message || String(err)
      }
    });
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message !== "object") {
    return false;
  }

  if (message.type === "getState") {
    (async () => {
      try {
        await resolveProfileInfo();
        await loadPairingKey();
        if (!state.hasKey && state.authState !== "unpaired") {
          state.authState = "unpaired";
        }
        const attachedSessions = Array.from(state.tabSessions.values()).filter((s) => s.attached);
        const tabs = attachedSessions.map((s) => ({
          tabId: s.tabId,
          title: s.title || "",
          url: s.url || ""
        }));
        sendResponse({
          wsState: state.wsState,
          authState: state.authState,
          hasKey: state.hasKey,
          profileName: state.profileName,
          tabs,
          endpoint: BRIDGE_ENDPOINT
        });
      } catch (_) {
        sendResponse({
          wsState: state.wsState,
          authState: state.authState,
          hasKey: state.hasKey,
          profileName: state.profileName,
          tabs: [],
          endpoint: BRIDGE_ENDPOINT
        });
      }
    })();
    return true;
  }

  if (message.type === "setProfileName") {
    const trimmed = String(message.profileName || "").trim();
    (async () => {
      try {
        if (trimmed) {
          await chrome.storage.local.set({ profileName: trimmed });
          state.profileName = trimmed;
          state.profileInitialized = true;
        } else {
          await chrome.storage.local.remove(["profileName"]);
          state.profileInitialized = false;
          await resolveProfileInfo(true);
        }
        if (state.authState === "ready") {
          await sendProfileInfo();
        }
        sendResponse({
          ok: true,
          profileName: state.profileName
        });
      } catch (err) {
        sendResponse({
          ok: false,
          error: err?.message || String(err),
          profileName: state.profileName
        });
      }
    })();
    return true;
  }

  if (message.type === "setPairingKey") {
    (async () => {
      try {
        const parsed = UsemacBridgeAuth.parsePairingKey(message.key);
        if (!parsed) {
          sendResponse({ ok: false, error: "invalid_format" });
          return;
        }
        const normalized = String(message.key).trim().toLowerCase();
        await chrome.storage.local.set({ bridgeKey: normalized });
        state.bridgeKeyBytes = parsed;
        state.hasKey = true;
        state.keyLoaded = true;
        state.authState = "authenticating";
        state.reconnectAttempts = 0;
        state.nextReconnectAllowedAt = 0;
        connectWS(true);
        sendResponse({ ok: true });
      } catch (err) {
        sendResponse({ ok: false, error: err?.message || String(err) });
      }
    })();
    return true;
  }

  if (message.type === "clearPairingKey") {
    (async () => {
      try {
        await chrome.storage.local.remove(["bridgeKey"]);
        state.bridgeKeyBytes = null;
        state.hasKey = false;
        state.keyLoaded = true;
        state.authState = "unpaired";
        state.reconnectAttempts = 0;
        state.nextReconnectAllowedAt = 0;
        connectWS(true);
        sendResponse({ ok: true });
      } catch (err) {
        sendResponse({ ok: false, error: err?.message || String(err) });
      }
    })();
    return true;
  }

  if (message.type === "releaseTab") {
    (async () => {
      try {
        if (typeof message.tabId === "number") {
          await handleCancel(message.tabId);
        }
        sendResponse({ ok: true });
      } catch (err) {
        sendResponse({ ok: false, error: err?.message || String(err) });
      }
    })();
    return true;
  }

  if (message.type === "stopAll") {
    (async () => {
      try {
        await handleCancel(null);
        sendResponse({ ok: true });
      } catch (err) {
        sendResponse({ ok: false, error: err?.message || String(err) });
      }
    })();
    return true;
  }

  if (message.type === "reconnect") {
    state.reconnectAttempts = 0;
    state.nextReconnectAllowedAt = 0;
    if (state.authState === "key_mismatch") {
      state.authState = state.hasKey ? "authenticating" : "unpaired";
    }
    connectWS(true);
    sendResponse({ ok: true, wsState: state.wsState, authState: state.authState });
    return false;
  }

  return false;
});

function setupKeepaliveAlarm() {
  try {
    chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.5 });
  } catch (_) {}
}

async function bootstrapBridge(forceRefresh = false) {
  await resolveProfileInfo(forceRefresh);
  await loadPairingKey(forceRefresh);
  if (state.authState !== "ready" && state.authState !== "key_mismatch") {
    state.authState = state.hasKey ? "authenticating" : "unpaired";
  }
  connectWS();
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === KEEPALIVE_ALARM) {
    ensureConnected();
  }
});

chrome.runtime.onInstalled.addListener(() => {
  setupKeepaliveAlarm();
  bootstrapBridge(true);
});

chrome.runtime.onStartup.addListener(() => {
  setupKeepaliveAlarm();
  bootstrapBridge(true);
});

setupKeepaliveAlarm();
bootstrapBridge(false);
