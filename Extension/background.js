importScripts("bridge-auth.js");
importScripts("tab-indicator.js");

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
// UseMac never changes a tab's size. These are only reported while a page could not be measured yet (see
// refreshLiveViewport); nothing applies them to the page.
const FALLBACK_VIEWPORT_WIDTH = 1280;
const FALLBACK_VIEWPORT_HEIGHT = 800;
// Below this (CSS px, either side) a measured size is not usable: a tab Chrome has not laid out yet.
const MIN_USABLE_VIEWPORT = 100;
const IDLE_TIMEOUT_MS = 180000;
const CAPTURE_INTERVAL_MS = 240;
const CAPTURE_STALE_MS = 220;
const DEFAULT_SCREENSHOT_MAX_WIDTH = 1280;
const DEFAULT_SCREENSHOT_MAX_HEIGHT = 800;
const NETWORK_RING_MAX = 25;
const NETWORK_ERRORS_MAX = 50;
const PREVIEW_DEBOUNCE_MS = 80;
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
  cancelledRequestIds: new Set(), // bounded set of requestIds cancelled individually on timeout
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
      // Whether the user can see the tab (see isTabVisibleToUser). Only decides where preview frames come from.
      visibleToUser: false,
      // The page's real size, as last measured: { width, height, scale, zoom } (see refreshLiveViewport).
      liveViewport: null,
      // A visible tab whose window is covered polls again (see checkCoveredWhileVisible).
      lastScreencastFrameAt: 0,
      coveredWhileVisible: false,
      coverProbeAt: 0,
      coverProbeInFlight: false,
      stallWatchTimer: null,
      visibilitySyncQueued: false,
      visibilitySyncRemeasure: false,
      cursor: { x: 640, y: 400 },
      pendingFileChooser: null,
      childTargets: new Map(), // childSessionId -> { sessionId, targetId, parentSessionId, url, title, type, ready, initPromise }
      executionContexts: new Map(), // `${sessionId||"top"}:${frameId}` -> default main-world contextId
      elementFrameMap: new Map(), // "@bN" -> { sessionId, contextId, frameId, parentSessionId, offsetX, offsetY, url, ancestors }
      frameSlots: new Map(), // frameId -> stable slot number >= 1 for non-colliding parallel @bN ranges
      nextFrameSlot: 1,
      lastChildFrames: [], // cached visible child frames from latest discovery
      lastSnapshot: null, // { url, elementsById: Map<id, ElementNode>, tablesHash, textHash, timestampMs }
      networkPending: new Map(), // requestId -> { requestId, url, method, resourceType, timestampMs }
      networkRing: [], // last 25 XHR/Fetch JSON responses for the current document
      networkErrors: [], // recent 4xx/5xx or failed XHR/Fetch responses
      documentId: 1,
      topLoaderId: null,
      navigating: false,
      previewDebounceTimer: null,
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

function createCancelToken(tabId, globalGenOverride = null, tabGenOverride = null, requestId = null) {
  return {
    globalGen: globalGenOverride != null ? globalGenOverride : state.cancelGeneration,
    tabGen: tabGenOverride != null ? tabGenOverride : (tabId != null ? getTabCancelGen(tabId) : 0),
    requestId: typeof requestId === "string" && requestId ? requestId : null
  };
}

function isCancelled(tabId, cancelToken) {
  if (!cancelToken) return false;
  if (cancelToken.requestId && state.cancelledRequestIds.has(cancelToken.requestId)) {
    return true;
  }
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

function handleCancel(targetTabId = null, requestId = null) {
  if (typeof requestId === "string" && requestId) {
    state.cancelledRequestIds.add(requestId);
    if (state.cancelledRequestIds.size > 128) {
      const oldest = state.cancelledRequestIds.values().next().value;
      if (oldest != null) state.cancelledRequestIds.delete(oldest);
    }
    if (targetTabId == null) {
      return Promise.resolve();
    }
  }
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
    extensionId: typeof chrome.runtime.id === "string" ? chrome.runtime.id : undefined,
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
        state.appExtensionStatus = msg.extensionStatus && typeof msg.extensionStatus === "object" ? msg.extensionStatus : null;
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
      handleCancel(msg.tabId ?? null, msg.requestId ?? null);
      return;
    }

    if (msg.type === "tab_control") {
      handleTabControlMessage(msg);
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
  if (!cdpSessionId && TAB_INDICATOR_POINTER_METHODS.has(method)) await tabIndicatorBeforeAgentPointer(tabId, method, params);
  const target = cdpSessionId ? { tabId, sessionId: cdpSessionId } : { tabId };
  return chrome.debugger.sendCommand(target, method, params);
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
    if (!nextLoaderId || nextLoaderId !== session.topLoaderId) {
      session.topLoaderId = nextLoaderId;
      session.documentId = (session.documentId || 0) + 1;
      session.networkRing = [];
      session.networkPending.clear();
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
  if (method === "Network.requestWillBeSent" && !source.sessionId) {
    const reqId = params?.requestId;
    const reqType = params?.type || "";
    const reqUrl = params?.request?.url || "";
    if (reqId && (reqType === "XHR" || reqType === "Fetch")) {
      session.networkPending.set(reqId, {
        requestId: reqId,
        url: reqUrl,
        method: params?.request?.method || "GET",
        resourceType: reqType,
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
    if (params?.requestId) session.networkPending.delete(params.requestId);
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
    const prevUrl = session.url || "";
    const nextUrl = tab?.url || changeInfo.url || session.url;
    if (changeInfo.url && prevUrl && nextUrl.split("#")[0] !== prevUrl.split("#")[0]) {
      session.documentId = (session.documentId || 0) + 1;
      session.networkRing = [];
      session.networkPending.clear();
    }
    session.url = nextUrl;
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

const USEMAC_GROUP_TITLE = "UseMac";
const USEMAC_GROUP_COLOR = "blue";

// One UseMac group per window. Commands for different tabs run at the same time (each tab has its own queue, and
// opens have theirs), and Chrome only lets a new group take its title after it exists. Two calls that both looked
// for the titled group before either had set it each made one, so a window could end up with several UseMac
// groups side by side. Group changes now take turns, and a window that already has several is folded back into
// one on its next use.
let usemacGroupChain = Promise.resolve();

function withUsemacGroupLock(fn) {
  const next = usemacGroupChain.then(fn, fn);
  usemacGroupChain = next.catch(() => {});
  return next;
}

// The group each window's UseMac tabs are in, so folding keeps the one agents already use. Kept in session
// storage so a service-worker restart remembers it; only trusted while that window still has a UseMac group with
// that id (it may have closed, moved to another window, or been renamed by the user, and then it is theirs).
const USEMAC_GROUPS_KEY = "usemacGroupIdsByWindow";
let usemacGroupIdsByWindow = null;

async function rememberedUsemacGroupIds() {
  if (!usemacGroupIdsByWindow) {
    try {
      const stored = await chrome.storage.session.get(USEMAC_GROUPS_KEY);
      const value = stored?.[USEMAC_GROUPS_KEY];
      usemacGroupIdsByWindow = value && typeof value === "object" ? value : {};
    } catch (_) {
      usemacGroupIdsByWindow = {};
    }
  }
  return usemacGroupIdsByWindow;
}

async function rememberUsemacGroup(windowId, groupId) {
  const remembered = await rememberedUsemacGroupIds();
  const key = String(windowId);
  if ((remembered[key] ?? null) === (groupId ?? null)) return;
  if (groupId == null) {
    delete remembered[key];
  } else {
    remembered[key] = groupId;
  }
  try {
    await chrome.storage.session.set({ [USEMAC_GROUPS_KEY]: remembered });
  } catch (_) {}
}

// Moves the tabs of every other UseMac group in the window into one; Chrome drops the groups left empty. Keeps the
// remembered group, else the leftmost. Returns the kept group and the ids of the tabs it moved. If Chrome refuses
// the move (the user is dragging a tab), the kept group is still used and the next call tries again.
async function foldUsemacGroups(groups, preferredId) {
  const entries = [];
  for (const group of groups) {
    let tabs = [];
    try {
      tabs = (await chrome.tabs.query({ groupId: group.id })) || [];
    } catch (_) {}
    const firstIndex = tabs.reduce((min, t) => Math.min(min, t.index ?? Infinity), Infinity);
    entries.push({ group, tabs, firstIndex });
  }
  const keeper =
    entries.find((e) => e.group.id === preferredId) || entries.slice().sort((a, b) => a.firstIndex - b.firstIndex)[0];
  const strays = entries
    .filter((e) => e !== keeper)
    .flatMap((e) => e.tabs)
    .filter((t) => !t.pinned)
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .map((t) => t.id);
  if (strays.length > 0) {
    try {
      await chrome.tabs.group({ groupId: keeper.group.id, tabIds: strays });
    } catch (_) {
      return { group: keeper.group, movedTabIds: new Set() };
    }
  }
  return { group: keeper.group, movedTabIds: new Set(strays) };
}

// The window's UseMac group ({ group, movedTabIds }), folding duplicates into one, or null when it has none. Call
// with the group lock held. Throws when Chrome cannot list the groups, so the caller does not make another one.
async function findUsemacGroupInWindow(windowId) {
  if (!chrome.tabGroups?.query || windowId == null) return null;
  const groups = (await chrome.tabGroups.query({ windowId, title: USEMAC_GROUP_TITLE })) || [];
  if (groups.length === 0) {
    await rememberUsemacGroup(windowId, null);
    return null;
  }
  const preferredId = (await rememberedUsemacGroupIds())[String(windowId)];
  const found =
    groups.length > 1 ? await foldUsemacGroups(groups, preferredId) : { group: groups[0], movedTabIds: new Set() };
  await rememberUsemacGroup(windowId, found.group.id);
  return found;
}

async function ensureTabInUsemacGroup(tabId) {
  if (tabId == null || !chrome.tabs?.group || !chrome.tabGroups?.update) {
    return;
  }
  try {
    await withUsemacGroupLock(() => groupTabWithUsemac(tabId));
  } catch (_) {
    // Non-fatal: tab may be closing, pinned, or in a popup window that disallows tab groups
  }
}

async function groupTabWithUsemac(tabId) {
  const tab = await chrome.tabs.get(tabId);
  if (!tab || tab.pinned || tab.windowId == null) {
    return;
  }
  const existing = await findUsemacGroupInWindow(tab.windowId);
  if (existing) {
    if (tab.groupId === existing.group.id || existing.movedTabIds.has(tabId)) {
      return;
    }
    await chrome.tabs.group({ groupId: existing.group.id, tabIds: [tabId] });
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
    await rememberUsemacGroup(tab.windowId, groupId);
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
  if (action === "wait") return Boolean(step.selector || step.text || hasNonEmptyMatch(step.match));
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
function collectRoots(root, maxRoots = 140) {
  const roots = [root];
  const visited = new Set([root]);
  for (let q = 0; q < roots.length && roots.length < maxRoots; q++) {
    const cur = roots[q];
    if (!cur) continue;
    try {
      const all = cur.querySelectorAll('*');
      for (let i = 0; i < all.length && roots.length < maxRoots; i++) {
        const sr = all[i].shadowRoot;
        if (sr && !visited.has(sr)) {
          visited.add(sr);
          roots.push(sr);
        }
      }
    } catch (_) {}
  }
  return roots;
}

function queryAllInRoots(roots, sel) {
  const out = [];
  const seenNodes = new Set();
  for (let r = 0; r < roots.length; r++) {
    const cur = roots[r];
    if (!cur) continue;
    try {
      const matched = cur.querySelectorAll(sel);
      for (let i = 0; i < matched.length; i++) {
        if (!seenNodes.has(matched[i])) {
          seenNodes.add(matched[i]);
          out.push(matched[i]);
        }
      }
    } catch (_) {}
  }
  return out;
}

function queryAllDeep(root, sel, maxRoots = 140) {
  return queryAllInRoots(collectRoots(root, maxRoots), sel);
}

function queryOneDeep(root, sel, maxRoots = 140) {
  try {
    const direct = root.querySelector(sel);
    if (direct) return direct;
  } catch (_) {}
  const roots = collectRoots(root, maxRoots);
  for (let i = 1; i < roots.length; i++) {
    try {
      const hit = roots[i].querySelector(sel);
      if (hit) return hit;
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

function getUsemacRefRegistry(idBase = 1) {
  let reg = globalThis.__usemacRefRegistry;
  if (!reg || !(reg.nodeToId instanceof WeakMap) || !(reg.idToNode instanceof Map)) {
    const nodeToId = globalThis.__usemacNodeIds instanceof WeakMap ? globalThis.__usemacNodeIds : new WeakMap();
    reg = {
      nodeToId,
      idToNode: new Map(),
      nextCounter: Math.max(1, Number(idBase) || 1)
    };
    globalThis.__usemacRefRegistry = reg;
    globalThis.__usemacNodeIds = nodeToId;
  } else {
    globalThis.__usemacNodeIds = reg.nodeToId;
    if (Number(idBase) > reg.nextCounter) {
      reg.nextCounter = Number(idBase);
    }
  }
  if (reg.idToNode.size > 1500) {
    for (const [k, v] of reg.idToNode.entries()) {
      const el = typeof WeakRef === 'function' && v instanceof WeakRef ? v.deref() : v;
      if (!el || !el.isConnected) reg.idToNode.delete(k);
    }
  }
  return reg;
}

function lookupUsemacNodeId(el, reg) {
  let id = reg.nodeToId.get(el);
  if (id) return id;
  const attr = el.getAttribute ? el.getAttribute('data-usemac-id') : null;
  if (attr && /^@b\\d+$/.test(attr)) {
    reg.nodeToId.set(el, attr);
    reg.idToNode.set(attr, typeof WeakRef === 'function' ? new WeakRef(el) : el);
    const num = parseInt(attr.slice(2), 10);
    if (Number.isFinite(num) && num >= reg.nextCounter) reg.nextCounter = num + 1;
    return attr;
  }
  return null;
}

function assignUsemacNodeId(el, reg) {
  const existing = lookupUsemacNodeId(el, reg);
  if (existing) return existing;
  const id = '@b' + (reg.nextCounter++);
  reg.nodeToId.set(el, id);
  reg.idToNode.set(id, typeof WeakRef === 'function' ? new WeakRef(el) : el);
  return id;
}

function findByUsemacId(id, root = document) {
  if (!id) return null;
  const reg = globalThis.__usemacRefRegistry;
  if (reg && reg.idToNode instanceof Map && reg.idToNode.has(id)) {
    const ref = reg.idToNode.get(id);
    const el = typeof WeakRef === 'function' && ref instanceof WeakRef ? ref.deref() : ref;
    if (el && el.isConnected) return el;
    reg.idToNode.delete(id);
  }
  const escaped = String(id).replace(/["\\\\]/g, '\\\\$&');
  const found = queryOneDeep(root, '[data-usemac-id="' + escaped + '"]');
  if (found && reg) {
    reg.nodeToId.set(found, id);
    reg.idToNode.set(id, typeof WeakRef === 'function' ? new WeakRef(found) : found);
  }
  return found;
}

function normalizeMatchText(str) {
  if (str == null) return '';
  let s = String(str);
  try { s = s.normalize('NFD').replace(/[\\u0300-\\u036f]/g, ''); } catch (_) {}
  return s.toLowerCase().replace(/\\s+/g, ' ').trim();
}

function mapElementRole(el) {
  const tag = (el.tagName || '').toLowerCase();
  const ariaRole = (el.getAttribute ? (el.getAttribute('role') || '') : '').toLowerCase();
  if (tag === 'a' || ariaRole === 'link') return 'AXLink';
  if (ariaRole === 'checkbox' || ariaRole === 'switch' || ariaRole === 'menuitemcheckbox') return 'AXCheckBox';
  if (ariaRole === 'radio' || ariaRole === 'tab' || ariaRole === 'menuitemradio') return 'AXRadioButton';
  if (ariaRole === 'combobox' || ariaRole === 'listbox' || tag === 'select') return 'AXPopUpButton';
  if (ariaRole === 'menuitem' || ariaRole === 'option' || ariaRole === 'treeitem') return 'AXMenuItem';
  if (ariaRole === 'slider') return 'AXSlider';
  if (ariaRole === 'spinbutton' || ariaRole === 'textbox' || ariaRole === 'searchbox') return 'AXTextField';
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

function roleMatchesQuery(el, mappedRole, wantedRole) {
  if (!wantedRole) return true;
  const w = normalizeMatchText(wantedRole);
  if (!w) return true;
  const mr = normalizeMatchText(mappedRole);
  const tag = normalizeMatchText(el.tagName || '');
  const aria = normalizeMatchText(el.getAttribute ? (el.getAttribute('role') || '') : '');
  if (w === mr || w === tag || (aria && w === aria)) return true;
  const stripped = w.startsWith('ax') ? w.slice(2) : w;
  const mrStripped = mr.startsWith('ax') ? mr.slice(2) : mr;
  if (stripped === mrStripped) return true;
  const aliases = {
    btn: 'axbutton', button: 'axbutton',
    link: 'axlink', a: 'axlink',
    input: 'axtextfield', textbox: 'axtextfield', textfield: 'axtextfield', textarea: 'axtextfield', searchbox: 'axtextfield', text: 'axtextfield',
    checkbox: 'axcheckbox', switch: 'axcheckbox',
    radio: 'axradiobutton', tab: 'axradiobutton',
    select: 'axpopupbutton', combobox: 'axpopupbutton', dropdown: 'axpopupbutton', popup: 'axpopupbutton', listbox: 'axpopupbutton',
    menuitem: 'axmenuitem', option: 'axmenuitem', treeitem: 'axmenuitem',
    heading: 'axheading', h1: 'axheading', h2: 'axheading', h3: 'axheading',
    slider: 'axslider',
    file: 'axfileupload', fileupload: 'axfileupload'
  };
  if (aliases[stripped] && aliases[stripped] === mr) return true;
  return false;
}

function extractElementTitleValue(el, labelMap) {
  const tag = (el.tagName || '').toLowerCase();
  let labelFromFor = null;
  if ((tag === 'input' || tag === 'textarea' || tag === 'select') && el.id) {
    if (labelMap && labelMap.has(el.id)) {
      labelFromFor = labelMap.get(el.id);
    } else {
      const lbl = document.querySelector ? document.querySelector('label[for="' + String(el.id).replace(/["\\\\]/g, '\\\\$&') + '"]') : null;
      if (lbl) labelFromFor = lbl.innerText || lbl.textContent;
    }
  }
  if (!labelFromFor && (tag === 'input' || tag === 'textarea' || tag === 'select') && el.closest) {
    const parentLbl = el.closest('label');
    if (parentLbl) labelFromFor = parentLbl.innerText || parentLbl.textContent;
  }
  let labelFromAriaBy = null;
  const ariaBy = el.getAttribute ? el.getAttribute('aria-labelledby') : null;
  if (ariaBy) {
    const parts = ariaBy.split(/\\s+/).map((rid) => document.getElementById?.(rid)?.innerText || '').filter(Boolean);
    if (parts.length > 0) labelFromAriaBy = parts.join(' ');
  }
  const rawTitle =
    (el.getAttribute && el.getAttribute('aria-label')) ||
    labelFromAriaBy ||
    el.innerText ||
    el.textContent ||
    labelFromFor ||
    (el.getAttribute && el.getAttribute('placeholder')) ||
    (el.getAttribute && el.getAttribute('title')) ||
    (el.getAttribute && el.getAttribute('alt')) ||
    (el.getAttribute && el.getAttribute('name')) ||
    '';
  const title = String(rawTitle).replace(/\\s+/g, ' ').trim();

  let value = '';
  if (tag === 'select') {
    const selectedOpt = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
    value = selectedOpt ? (selectedOpt.text || selectedOpt.value || '').trim() : String(el.value || '');
  } else if (tag === 'input' || tag === 'textarea') {
    if (el.type === 'checkbox' || el.type === 'radio') {
      value = el.checked ? 'checked=true' : 'checked=false';
    } else if (el.type !== 'password' && el.type !== 'file') {
      value = String(el.value || '');
    }
  } else if (el.isContentEditable) {
    value = String(el.innerText || '').replace(/\\s+/g, ' ').trim();
  }
  return { title, value };
}

function matchesElementSpec(el, spec, labelMap, precomputed) {
  if (!spec || typeof spec !== 'object') return false;
  const mappedRole = precomputed?.role || mapElementRole(el);
  if (spec.role && !roleMatchesQuery(el, mappedRole, spec.role)) return false;
  const info = precomputed || extractElementTitleValue(el, labelMap);
  const exact = spec.exact === true;
  const cmp = (haystack, needle) => {
    const h = normalizeMatchText(haystack);
    const n = normalizeMatchText(needle);
    if (!n) return true;
    return exact ? h === n : h.includes(n);
  };
  if (spec.title != null && String(spec.title).trim() !== '') {
    const desc = (el.getAttribute && (el.getAttribute('aria-description') || el.getAttribute('title') || el.getAttribute('placeholder'))) || '';
    if (!cmp(info.title, spec.title) && !cmp(desc, spec.title)) return false;
  }
  if (spec.value != null && String(spec.value).trim() !== '') {
    if (!cmp(info.value, spec.value)) return false;
  }
  if (spec.text != null && String(spec.text).trim() !== '') {
    const combined = [info.title, info.value, (el.innerText || '').slice(0, 200)].filter(Boolean);
    if (!combined.some((part) => cmp(part, spec.text))) return false;
  }
  return true;
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

function getFrameSlot(session, frameId) {
  if (!session || !frameId) return 1;
  let slot = session.frameSlots.get(frameId);
  if (slot == null) {
    slot = session.nextFrameSlot++;
    session.frameSlots.set(frameId, slot);
  }
  return slot;
}

function hashString(str) {
  if (!str) return null;
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16);
}

function framesSignificantlyChanged(a, b) {
  if (!a && !b) return false;
  if (!a || !b) return true;
  return (
    Math.abs((a.x || 0) - (b.x || 0)) >= 5 ||
    Math.abs((a.y || 0) - (b.y || 0)) >= 5 ||
    Math.abs((a.width || 0) - (b.width || 0)) >= 5 ||
    Math.abs((a.height || 0) - (b.height || 0)) >= 5
  );
}

function elementNodeChanged(prev, cur) {
  return (
    prev.role !== cur.role ||
    (prev.title ?? null) !== (cur.title ?? null) ||
    (prev.value ?? null) !== (cur.value ?? null) ||
    Boolean(prev.enabled) !== Boolean(cur.enabled) ||
    Boolean(prev.focused) !== Boolean(cur.focused) ||
    Boolean(prev.offscreen) !== Boolean(cur.offscreen) ||
    framesSignificantlyChanged(prev.frame, cur.frame)
  );
}

function computeSnapshotDiff(prevElementsById, currentElements) {
  if (!prevElementsById || !(prevElementsById instanceof Map)) return null;
  const added = [];
  const changed = [];
  const removedIds = [];
  const curIds = new Set();

  for (const el of currentElements) {
    curIds.add(el.id);
    const prev = prevElementsById.get(el.id);
    if (!prev) {
      added.push(el);
    } else if (elementNodeChanged(prev, el)) {
      changed.push(el);
    }
  }
  for (const prevId of prevElementsById.keys()) {
    if (!curIds.has(prevId)) {
      removedIds.push(prevId);
    }
  }

  const parts = [];
  if (added.length > 0) parts.push(`+${added.length} added`);
  if (changed.length > 0) parts.push(`~${changed.length} changed`);
  if (removedIds.length > 0) parts.push(`-${removedIds.length} removed`);
  const summary = parts.length > 0 ? parts.join(", ") : "No element changes";

  const denom = Math.max(prevElementsById.size, currentElements.length, 1);
  const churn = (added.length + changed.length + removedIds.length) / denom;
  return {
    diff: { added, removedIds, changed, summary },
    churn
  };
}

function hasActiveFilter(filter) {
  if (!filter || typeof filter !== "object") return false;
  return Boolean(
    (typeof filter.role === "string" && filter.role.trim()) ||
    (typeof filter.text === "string" && filter.text.trim()) ||
    (typeof filter.selector === "string" && filter.selector.trim()) ||
    filter.viewportOnly === true
  );
}

function buildFrameIndexExpression({
  idBase = 1,
  limit = 280,
  includeText = true,
  includeTables = true,
  includeOffscreen = false,
  filter = null,
  curVpW = FALLBACK_VIEWPORT_WIDTH,
  curVpH = FALLBACK_VIEWPORT_HEIGHT,
  topVpW = FALLBACK_VIEWPORT_WIDTH,
  topVpH = FALLBACK_VIEWPORT_HEIGHT,
  isTopFrame = true,
  offsetX = 0,
  offsetY = 0
}) {
  const filterLit = filter && typeof filter === "object" ? JSON.stringify(filter) : "null";
  return `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const idBase = ${Number(idBase) || 1};
      const limit = ${limit};
      const includeText = ${includeText ? "true" : "false"};
      const includeTables = ${includeTables ? "true" : "false"};
      const includeOffscreen = ${includeOffscreen ? "true" : "false"};
      const filter = ${filterLit};
      const isTopFrame = ${isTopFrame ? "true" : "false"};
      const offsetX = ${Number(offsetX) || 0};
      const offsetY = ${Number(offsetY) || 0};
      const topVpW = ${Number(topVpW) || FALLBACK_VIEWPORT_WIDTH};
      const topVpH = ${Number(topVpH) || FALLBACK_VIEWPORT_HEIGHT};

      const reg = getUsemacRefRegistry(idBase);
      // Single ShadowRoot pass across the document (reused by all queries below).
      const roots = collectRoots(document);

      const vw = window.innerWidth || ${curVpW};
      const vh = window.innerHeight || ${curVpH};

      // Pre-index <label for="..."> once across all roots instead of querying per input.
      const labelMap = new Map();
      const labelNodes = queryAllInRoots(roots, 'label[for]');
      for (let i = 0; i < labelNodes.length; i++) {
        const lbl = labelNodes[i];
        const forId = lbl.getAttribute('for');
        if (forId && !labelMap.has(forId)) {
          const t = (lbl.innerText || lbl.textContent || '').replace(/\\s+/g, ' ').trim();
          if (t) labelMap.set(forId, t);
        }
      }

      const selector = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
      const nodes = queryAllInRoots(roots, selector);
      const activeEl = getDeepActiveElement();

      function mapActions(role) {
        if (role === 'AXTextField') return ['AXConfirm', 'AXSetValue'];
        if (role === 'AXHeading') return [];
        if (role === 'AXFileUpload') return ['AXUploadFile'];
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

      function isRectInViewport(rect) {
        const localVis = rect.bottom > 0 && rect.top < vh && rect.right > 0 && rect.left < vw;
        if (!localVis) return false;
        if (!isTopFrame) {
          const absLeft = rect.left + offsetX;
          const absTop = rect.top + offsetY;
          const absRight = absLeft + rect.width;
          const absBottom = absTop + rect.height;
          return absBottom > 0 && absTop < topVpH && absRight > 0 && absLeft < topVpW;
        }
        return true;
      }

      function matchesObservationFilter(el, role, title, value, offscreen) {
        if (!filter) return true;
        if (filter.viewportOnly === true && offscreen) return false;
        if (filter.role && !roleMatchesQuery(el, role, filter.role)) return false;
        if (filter.selector) {
          try {
            if (!el.matches || !el.matches(filter.selector)) return false;
          } catch (_) {
            return false;
          }
        }
        if (filter.text && String(filter.text).trim() !== '') {
          const needle = normalizeMatchText(filter.text);
          const hayTitle = normalizeMatchText(title || '');
          const hayVal = normalizeMatchText(value || '');
          if (!hayTitle.includes(needle) && !hayVal.includes(needle)) return false;
        }
        return true;
      }

      // --- PASS 1: READ-ONLY (batch all DOM/layout reads before any attribute writes) ---
      const seenElements = new Set();
      const inViewportDrafts = [];
      const offscreenDrafts = [];

      function collectElementDraft(el, forcedRole = null, forcedTitle = null, bypassFilter = false) {
        if (!el || seenElements.has(el)) return null;
        const rect = el.getBoundingClientRect();
        if (!isVisibleRect(el, rect)) return null;

        const role = forcedRole || mapElementRole(el);
        const tag = el.tagName.toLowerCase();
        const isFocused = activeEl === el;

        let labelFromFor = null;
        if (!forcedTitle && (tag === 'input' || tag === 'textarea' || tag === 'select') && el.id) {
          labelFromFor = labelMap.get(el.id) || null;
        }
        if (!forcedTitle && !labelFromFor && (tag === 'input' || tag === 'textarea' || tag === 'select') && el.closest) {
          const pLbl = el.closest('label');
          if (pLbl) labelFromFor = pLbl.innerText || pLbl.textContent || null;
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

        const offscreen = !isRectInViewport(rect);
        if (!bypassFilter && !matchesObservationFilter(el, role, title, value, offscreen)) {
          return null;
        }

        seenElements.add(el);
        const enabled = !el.disabled && el.getAttribute('aria-disabled') !== 'true';
        const draft = {
          el,
          id: lookupUsemacNodeId(el, reg),
          role,
          title,
          value,
          roleDescription: el.getAttribute('role') || tag,
          enabled,
          focused: isFocused,
          offscreen,
          frame: {
            x: Math.round((rect.left + offsetX) * 10) / 10,
            y: Math.round((rect.top + offsetY) * 10) / 10,
            width: Math.round(rect.width * 10) / 10,
            height: Math.round(rect.height * 10) / 10
          },
          actions: mapActions(role)
        };
        if (offscreen) offscreenDrafts.push(draft);
        else inViewportDrafts.push(draft);
        return draft;
      }

      // Cap scan generously so offscreen elements before in-viewport ones never starve in-viewport discovery.
      const maxScan = Math.max(limit * 4, 1200);
      for (let i = 0; i < nodes.length && (inViewportDrafts.length + offscreenDrafts.length) < maxScan; i++) {
        collectElementDraft(nodes[i]);
      }

      // Always expose <input type="file"> controls even when hidden behind styled upload buttons/dropzones
      const fileInputDrafts = [];
      const fileInputs = queryAllInRoots(roots, 'input[type="file"]');
      for (let i = 0; i < fileInputs.length && fileInputDrafts.length < 16; i++) {
        const fi = fileInputs[i];
        if (seenElements.has(fi)) continue;
        let labelText = fi.getAttribute('aria-label') || fi.getAttribute('title') || '';
        if (!labelText && fi.id) {
          labelText = labelMap.get(fi.id) || '';
        }
        if (!labelText && fi.closest) {
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
        const fiTitle = cleanText(labelText, 120) || 'File upload input';
        const fiVal = metaParts.length > 0 ? metaParts.join(';') : null;
        const fiOffscreen = !isRectInViewport(anchorRect);
        if (!matchesObservationFilter(fi, 'AXFileUpload', fiTitle, fiVal, fiOffscreen)) continue;
        seenElements.add(fi);
        fileInputDrafts.push({
          el: fi,
          id: lookupUsemacNodeId(fi, reg),
          role: 'AXFileUpload',
          title: fiTitle,
          value: fiVal,
          roleDescription: 'input[type=file]',
          enabled: !fi.disabled,
          focused: activeEl === fi,
          offscreen: fiOffscreen,
          frame: {
            x: Math.round(((anchorRect.left || 0) + offsetX) * 10) / 10,
            y: Math.round(((anchorRect.top || 0) + offsetY) * 10) / 10,
            width: Math.round((anchorRect.width || 0) * 10) / 10,
            height: Math.round((anchorRect.height || 0) * 10) / 10
          },
          actions: ['AXUploadFile']
        });
      }

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

      function detectBlockingOverlayReadOnly() {
        const candidates = [];
        const probePoints = [
          [vw * 0.5, vh * 0.5],
          [vw * 0.5, vh * 0.3],
          [vw * 0.5, vh * 0.25],
          [vw * 0.5, vh * 0.7],
          [vw * 0.5, vh * 0.9]
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
            const clsId = (((cur.className && typeof cur.className === 'string' ? cur.className : '') + ' ' + (cur.id || '')).toLowerCase());
            const isCookieConsent = /cookie|consent|gdpr|onetrust|cookiebot|didomi|quantcast|privacy-banner|lgpd/.test(clsId);
            if (isDialog || isCookieConsent || ((pos === 'fixed' || pos === 'sticky') && (Number.isFinite(z) && z >= 10))) {
              const r = cur.getBoundingClientRect();
              const area = r.width * r.height;
              const isHeaderOrNav = (r.height < 110 && r.top <= 10 && r.width > vw * 0.85 && !isDialog && !isCookieConsent);
              const isWorkspaceIframe = cur.tagName?.toLowerCase() === 'iframe' && r.width > vw * 0.5 && r.height > vh * 0.5;
              if (!isHeaderOrNav && !isWorkspaceIframe && r.width >= 200 && r.height >= 60 && area > 18000 && st.display !== 'none' && st.visibility !== 'hidden' && parseFloat(st.opacity) > 0.05) {
                seen.add(cur);
                candidates.push({ el: cur, rect: r, z: Number.isFinite(z) ? z : 10, isDialog, isCookieConsent });
              }
            }
            cur = cur.parentElement;
          }
        }

        for (const [px, py] of probePoints) {
          const hit = document.elementFromPoint ? document.elementFromPoint(px, py) : null;
          if (hit) considerContainer(hit);
        }

        const explicitDialogs = queryAllInRoots(roots, '[role="dialog"], [aria-modal="true"], dialog[open], [id*="cookie"], [class*="cookie"], [id*="consent"], [class*="consent"], [id*="onetrust"], [id*="didomi"], div[class*="modal"], div[class*="popup"], div[class*="notification"], div[id*="onesignal"], div[id*="push"], div[class*="banner"]');
        for (let i = 0; i < explicitDialogs.length && i < 40; i++) {
          considerContainer(explicitDialogs[i]);
        }

        if (candidates.length === 0) return null;
        candidates.sort((a, b) => (b.isCookieConsent ? 2 : 0) - (a.isCookieConsent ? 2 : 0) || (b.isDialog ? 1 : 0) - (a.isDialog ? 1 : 0) || b.z - a.z);
        const top = candidates[0];
        const container = top.el;
        const cr = top.rect;

        let summary = cleanText(container.innerText || container.getAttribute('aria-label') || container.tagName, 140);
        if (!summary && container.tagName?.toLowerCase() === 'iframe') {
          summary = 'Cross-origin iframe overlay (' + (container.src || 'iframe').slice(0, 60) + ')';
        }
        if (!summary) summary = 'Modal/overlay covering viewport';

        const containerTextLower = (summary || '').toLowerCase();
        const isCookieText = top.isCookieConsent || /cookie|consent|gdpr|privacy|privacidade|lgpd|we use cookies|usamos cookies/.test(containerTextLower);

        let closeEl = null;
        let closeRect = null;
        const dismissRegex = /^(x|×|✕|✖|fechar|close|não|nao|agora não|agora nao|recusar|rejeitar|dispensar|cancelar|dismiss|no thanks|not now|reject|reject all|decline|skip)$/i;
        const acceptConsentRegex = /^(accept|accept all|allow all|agree|i agree|got it|ok|aceitar|aceitar todos|concordo|entendi)$/i;
        const innerCandidates = queryAllDeep(container, 'button, a, [role="button"], span, div, svg, i');
        let bestScore = -1;

        for (let i = 0; i < innerCandidates.length && i < 120; i++) {
          const c = innerCandidates[i];
          const r = c.getBoundingClientRect();
          if (!isVisibleRect(c, r)) continue;
          if (r.width > 260 || r.height > 80) continue;
          const label = ((c.getAttribute('aria-label') || '') + ' ' + (c.getAttribute('title') || '') + ' ' + (c.innerText || '')).replace(/\\s+/g, ' ').trim();
          const cls = ((c.className && typeof c.className === 'string' ? c.className : '') + ' ' + (c.id || '')).toLowerCase();
          let score = 0;
          if (dismissRegex.test(label)) score += 10;
          if (isCookieText && acceptConsentRegex.test(label)) score += 11;
          if (/close|fechar|dismiss|cancel|decline|reject|deny|later/.test(cls) || /close|fechar|agora não|não obrigad|recusar|rejeitar|no thanks|not now|reject all/i.test(label)) score += 6;
          if (isCookieText && (/accept|allow|agree|consent|onetrust-accept/.test(cls) || /accept all|aceitar todos|allow all/i.test(label))) score += 7;
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
            closeRect = r;
          }
        }

        const hasAction = Boolean(closeEl && bestScore >= 5);
        return {
          summary,
          closeEl: hasAction ? closeEl : null,
          closeRect: hasAction ? closeRect : null,
          highConfidence: Boolean(hasAction && (isCookieText || bestScore >= 10)),
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

        const htmlTables = queryAllInRoots(roots, 'table');
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

        const grids = queryAllInRoots(roots, '[role="grid"], [role="table"], [role="treegrid"]');
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

      // WebMCP discovery (navigator.modelContext / document.modelContext)
      let webMcpTools = null;
      if (isTopFrame) {
        try {
          const mc = (typeof navigator !== 'undefined' && navigator?.modelContext) || document?.modelContext || null;
          if (mc) {
            let rawTools = null;
            if (typeof mc.getTools === 'function') rawTools = mc.getTools();
            else if (typeof mc.listTools === 'function') rawTools = mc.listTools();
            else if (Array.isArray(mc.tools)) rawTools = mc.tools;
            else if (mc.tools && typeof mc.tools === 'object') rawTools = Object.keys(mc.tools);
            if (Array.isArray(rawTools)) {
              const names = rawTools
                .map((t) => (typeof t === 'string' ? t : (t?.name || t?.id || '')))
                .map((s) => String(s).trim())
                .filter(Boolean);
              if (names.length > 0) webMcpTools = Array.from(new Set(names)).slice(0, 50);
            }
          }
        } catch (_) {}
      }

      const overlayRaw = detectBlockingOverlayReadOnly();
      const tablesMarkdown = extractTablesMarkdown();
      const readableText = extractReadableText();

      // Sort in-viewport first; respect includeOffscreen (default false) and report offscreenCount.
      const allowOffscreen = includeOffscreen && filter?.viewportOnly !== true;
      const offscreenCount = offscreenDrafts.length + fileInputDrafts.filter((d) => d.offscreen).length;
      const orderedDrafts = allowOffscreen
        ? inViewportDrafts.concat(offscreenDrafts).slice(0, limit)
        : inViewportDrafts.slice(0, limit);
      const visibleFileInputs = allowOffscreen ? fileInputDrafts : fileInputDrafts.filter((d) => !d.offscreen);
      const selectedDrafts = orderedDrafts.concat(visibleFileInputs);

      // Ensure overlay close control is included if detected
      let overlayCloseDraft = null;
      if (overlayRaw?.closeEl) {
        overlayCloseDraft = selectedDrafts.find((d) => d.el === overlayRaw.closeEl) || null;
        if (!overlayCloseDraft) {
          const br = overlayRaw.closeRect;
          overlayCloseDraft = {
            el: overlayRaw.closeEl,
            id: lookupUsemacNodeId(overlayRaw.closeEl, reg),
            role: 'AXButton',
            title: cleanText(overlayRaw.closeEl.getAttribute('aria-label') || overlayRaw.closeEl.innerText || 'Close overlay', 40) || 'Close overlay',
            value: null,
            roleDescription: overlayRaw.closeEl.getAttribute('role') || overlayRaw.closeEl.tagName.toLowerCase(),
            enabled: !overlayRaw.closeEl.disabled,
            focused: activeEl === overlayRaw.closeEl,
            offscreen: false,
            frame: {
              x: Math.round((br.left + offsetX) * 10) / 10,
              y: Math.round((br.top + offsetY) * 10) / 10,
              width: Math.round(br.width * 10) / 10,
              height: Math.round(br.height * 10) / 10
            },
            actions: ['AXPress']
          };
          selectedDrafts.unshift(overlayCloseDraft);
        }
      }

      // --- PASS 2: WRITE-ONLY (assign stable @bN IDs + batch data-usemac-id writes with zero layout thrash) ---
      const elements = [];
      let focusedElementId = null;
      for (let i = 0; i < selectedDrafts.length; i++) {
        const d = selectedDrafts[i];
        const id = d.id || assignUsemacNodeId(d.el, reg);
        d.id = id;
        if (d.el.getAttribute && d.el.getAttribute('data-usemac-id') !== id) {
          d.el.setAttribute('data-usemac-id', id);
        }
        if (d.focused) focusedElementId = id;
        const nodeObj = {
          id,
          role: d.role,
          title: d.title,
          value: d.value,
          roleDescription: d.roleDescription,
          enabled: d.enabled,
          focused: d.focused,
          frame: d.frame,
          actions: d.actions
        };
        if (d.offscreen) nodeObj.offscreen = true;
        elements.push(nodeObj);
      }

      let blockingOverlay = null;
      let overlayHighConfidence = false;
      if (overlayRaw) {
        let closeElementId = null;
        let closeX = null;
        let closeY = null;
        if (overlayCloseDraft && overlayRaw.closeRect) {
          closeElementId = overlayCloseDraft.id;
          closeX = Math.round((overlayRaw.closeRect.left + offsetX + overlayRaw.closeRect.width / 2) * 10) / 10;
          closeY = Math.round((overlayRaw.closeRect.top + offsetY + overlayRaw.closeRect.height / 2) * 10) / 10;
        }
        overlayHighConfidence = Boolean(overlayRaw.highConfidence);
        blockingOverlay = {
          summary: overlayRaw.summary,
          closeElementId,
          closeX,
          closeY,
          frame: overlayRaw.frame,
          blocksScroll: overlayRaw.blocksScroll
        };
      }

      const pageState = {
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
      };
      if (webMcpTools && webMcpTools.length > 0) {
        pageState.webMcpTools = webMcpTools;
      }

      return {
        title: document.title || '',
        url: window.location.href || '',
        hasFocus: typeof document.hasFocus === 'function' ? document.hasFocus() : false,
        focusedElementId,
        elements,
        offscreenCount,
        overlayHighConfidence,
        pageState
      };
    })()`;
}

// Observes the page at its real size. viewportWidth/viewportHeight/deviceScaleFactor on the request are ignored
// for layout (UseMac never resizes a tab); for includeScreenshot, viewportWidth/viewportHeight act as a downscale box
// defaulting to 1280x800 (unless fullResolution: true).
async function observeTab(tabId, maxElements = 280, options = {}) {
  const start = performance.now();
  const rawMode = typeof options.observationMode === "string" ? options.observationMode.trim().toLowerCase() : null;
  const effectiveMode = rawMode || (options.returnDiffOnly === true ? "delta" : "full");
  if (effectiveMode === "none") {
    const tab = await refreshTabMeta(tabId);
    return { tab, screenshotBase64: null, screenshotWidth: null, screenshotHeight: null, snapshot: null, overlayHighConfidence: false };
  }

  const limit = clamp(Number(maxElements) || 280, 1, 600);
  const includeText = effectiveMode === "interactive" ? options.includeText === true : options.includeText !== false;
  const includeTables = effectiveMode === "interactive" ? options.includeTables === true : options.includeTables !== false;
  const includeOffscreen = options.includeOffscreen === true;
  const filter = hasActiveFilter(options.filter) ? options.filter : null;

  const session = getOrCreateTabSession(tabId);
  await refreshLiveViewport(tabId, session);
  const { width: curVpW, height: curVpH } = effectiveViewport(session);

  // Run top-frame DOM index and child-frame discovery in parallel.
  const [evalResult, childFrames] = await Promise.all([
    sendCDP(tabId, "Runtime.evaluate", {
      expression: buildFrameIndexExpression({
        idBase: 1,
        limit,
        includeText,
        includeTables,
        includeOffscreen,
        filter,
        curVpW,
        curVpH,
        topVpW: curVpW,
        topVpH: curVpH,
        isTopFrame: true,
        offsetX: 0,
        offsetY: 0
      }),
      returnByValue: true,
      awaitPromise: false
    }),
    discoverChildFrames(tabId).catch(() => [])
  ]);

  if (evalResult?.exceptionDetails) {
    throw new Error(evalResult.exceptionDetails.text || "DOM observation failed.");
  }

  const pageData = evalResult?.result?.value || {
    title: "",
    url: "",
    focusedElementId: null,
    elements: [],
    offscreenCount: 0,
    overlayHighConfidence: false,
    pageState: null
  };

  const mergedElements = Array.isArray(pageData.elements) ? pageData.elements.slice() : [];
  let totalOffscreenCount = Number(pageData.offscreenCount) || 0;
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

  const tableBlocks = pageData.pageState?.tablesMarkdown ? [pageData.pageState.tablesMarkdown] : [];
  const textBlocks = pageData.pageState?.readableText ? [pageData.pageState.readableText] : [];
  const mergedScrollables = Array.isArray(pageData.pageState?.scrollableContainers)
    ? pageData.pageState.scrollableContainers.slice()
    : [];
  let mergedOverlay = pageData.pageState?.blockingOverlay || null;
  let overlayHighConfidence = Boolean(pageData.overlayHighConfidence);

  // Index all discovered child frames in parallel using non-colliding stable slot-based ID ranges.
  const hardCap = Math.min(600, Math.max(limit + 120, 360));
  if (childFrames.length > 0 && mergedElements.length < hardCap) {
    const childOutputs = await Promise.all(
      childFrames.map(async (frameMeta) => {
        const isLargeWorkspaceFrame = frameMeta.width >= 300 && frameMeta.height >= 200;
        const frameBudget = isLargeWorkspaceFrame ? Math.min(200, hardCap) : 80;
        const slot = getFrameSlot(session, frameMeta.frameId);
        const idBase = slot * 10000 + 1;
        try {
          const childRes = await evalInFrame(
            tabId,
            frameMeta,
            buildFrameIndexExpression({
              idBase,
              limit: frameBudget,
              includeText,
              includeTables,
              includeOffscreen,
              filter,
              curVpW: Math.round(frameMeta.width) || curVpW,
              curVpH: Math.round(frameMeta.height) || curVpH,
              topVpW: curVpW,
              topVpH: curVpH,
              isTopFrame: false,
              offsetX: frameMeta.offsetX,
              offsetY: frameMeta.offsetY
            })
          );
          return { frameMeta, isLargeWorkspaceFrame, childData: childRes?.result?.value || null };
        } catch (_) {
          return { frameMeta, isLargeWorkspaceFrame, childData: null };
        }
      })
    );

    for (const { frameMeta, isLargeWorkspaceFrame, childData } of childOutputs) {
      if (!childData) continue;
      if (mergedElements.length >= hardCap) break;
      const remaining = hardCap - mergedElements.length;
      const childEls = (Array.isArray(childData.elements) ? childData.elements : []).slice(0, remaining);
      for (const el of childEls) {
        mergedElements.push(el);
        session.elementFrameMap.set(el.id, frameMeta);
      }
      totalOffscreenCount += Number(childData.offscreenCount) || 0;

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
          overlayHighConfidence = Boolean(childData.overlayHighConfidence);
        }
        if (isLargeWorkspaceFrame && pageData.pageState) {
          if (cs.canScrollDown) pageData.pageState.canScrollDown = true;
          if (cs.canScrollUp) pageData.pageState.canScrollUp = true;
          if (cs.canScrollRight) pageData.pageState.canScrollRight = true;
          if (cs.canScrollLeft) pageData.pageState.canScrollLeft = true;
        }
      }
    }
  }

  // Stable sort: in-viewport elements first, offscreen elements second (preserving reading order inside each bucket).
  mergedElements.sort((a, b) => (a.offscreen ? 1 : 0) - (b.offscreen ? 1 : 0));

  const fullTablesMarkdown = tableBlocks.length > 0 ? tableBlocks.join("\n\n").slice(0, 6500) : null;
  const fullReadableText = textBlocks.length > 0 ? textBlocks.join("\n\n").slice(0, 6000) : null;
  if (pageData.pageState) {
    pageData.pageState.tablesMarkdown = fullTablesMarkdown;
    pageData.pageState.readableText = fullReadableText;
    pageData.pageState.scrollableContainers = mergedScrollables;
    pageData.pageState.blockingOverlay = mergedOverlay;
  }

  const tab = await refreshTabMeta(tabId);
  const currentUrl = tab?.url || pageData.url || session.url || "";
  const prevSnap = session.lastSnapshot;
  const diffInfo = prevSnap ? computeSnapshotDiff(prevSnap.elementsById, mergedElements) : null;
  const sameUrl = Boolean(prevSnap && prevSnap.url && prevSnap.url === currentUrl);
  const tablesHash = hashString(fullTablesMarkdown);
  const textHash = hashString(fullReadableText);

  let useDiffOnly = false;
  if (prevSnap && diffInfo) {
    if (effectiveMode === "delta") {
      useDiffOnly = true;
    } else if (effectiveMode === "auto") {
      useDiffOnly = sameUrl && diffInfo.churn < 0.4;
    }
  }

  // Omit unchanged tables/readableText in delta or same-URL auto mode to slash token bloat.
  if (pageData.pageState && prevSnap && sameUrl && (useDiffOnly || effectiveMode === "auto")) {
    if (tablesHash && prevSnap.tablesHash === tablesHash) {
      pageData.pageState.tablesMarkdown = null;
      pageData.pageState.tablesSummary = "unchanged";
    }
    if (textHash && prevSnap.textHash === textHash) {
      pageData.pageState.readableText = null;
    }
  }

  // Update session baseline when not narrowed by a custom filter.
  if (!filter) {
    const nextMap = new Map();
    for (const el of mergedElements) nextMap.set(el.id, el);
    session.lastSnapshot = {
      url: currentUrl,
      elementsById: nextMap,
      tablesHash: includeTables ? tablesHash : (sameUrl ? prevSnap?.tablesHash ?? null : null),
      textHash: includeText ? textHash : (sameUrl ? prevSnap?.textHash ?? null : null),
      timestampMs: Date.now()
    };
  }

  const latencyMs = Math.round((performance.now() - start) * 100) / 100;
  const windowTitle = tab?.title || pageData.title || "";

  let screenshotBase64 = null;
  let screenshotWidth = null;
  let screenshotHeight = null;
  if (options.includeScreenshot) {
    try {
      const cap = await withTabIndicatorHidden(tabId, () => sendCDP(tabId, "Page.captureScreenshot", {
        format: "jpeg",
        quality: 82,
        fromSurface: true
      }));
      if (cap?.data) {
        const viewport = effectiveViewport(session);
        const pixelRatio = viewport.scale || 1;
        let shot = jpegShot(cap.data, {
          width: Math.round(viewport.width * pixelRatio),
          height: Math.round(viewport.height * pixelRatio)
        });
        const fitBox = screenshotBox(options);
        if (fitBox) {
          const fitted = sizeInBox(shot.width, shot.height, fitBox);
          if (shot.estimated || fitted.width !== shot.width || fitted.height !== shot.height) {
            const scaled = await fitJpegInBox(shot.data, fitBox, 82).catch(() => null);
            if (scaled) shot = scaled;
          }
        }
        screenshotBase64 = shot.data;
        screenshotWidth = shot.width;
        screenshotHeight = shot.height;
        // Reuse this capture for the preview frame (no indicator since it was captured with indicator hidden).
        emitPreviewFrameData(tabId, shot.data, false);
      }
    } catch (_) {}
  }

  const snapshot = {
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
    elements: useDiffOnly ? [] : mergedElements,
    diff: diffInfo ? diffInfo.diff : null,
    pageState: pageData.pageState || null
  };
  if (totalOffscreenCount > 0) {
    snapshot.offscreenCount = totalOffscreenCount;
  }

  return {
    tab,
    screenshotBase64,
    screenshotWidth,
    screenshotHeight,
    overlayHighConfidence,
    snapshot
  };
}

function emitCursor(tabId, x, y, phase, label = null) {
  noteTabIndicatorStep(tabId, label);
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
  // Clamp to the page's measured size only: the fallback size must not cut off clicks on a wider page.
  const maxW = session.liveViewport?.width ?? Infinity;
  const maxH = session.liveViewport?.height ?? Infinity;
  const tx = clamp(Number(targetX), 0, maxW);
  const ty = clamp(Number(targetY), 0, maxH);
  session.cursor = { x: tx, y: ty };
  emitCursor(tabId, tx, ty, "move", label);
  await sendCDP(tabId, "Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: tx,
    y: ty,
    button: "none"
  });
  return { x: tx, y: ty };
}

function usemacIdSelectorLiteral(elementId) {
  const escapedId = String(elementId).replace(/["\\]/g, "\\$&");
  return JSON.stringify(`[data-usemac-id="${escapedId}"]`);
}

function hasNonEmptyMatch(match) {
  if (!match || typeof match !== "object") return false;
  const nonBlank = (v) => typeof v === "string" && v.trim() !== "";
  return nonBlank(match.role) || nonBlank(match.title) || nonBlank(match.value) || nonBlank(match.text);
}

function formatMatchDesc(match) {
  if (!match || typeof match !== "object") return "match";
  const parts = [];
  if (match.role) parts.push(`role=${match.role}`);
  if (match.title) parts.push(`title="${match.title}"`);
  if (match.value) parts.push(`value="${match.value}"`);
  if (match.text) parts.push(`text="${match.text}"`);
  if (Number.isFinite(match.index) && match.index > 0) parts.push(`index=${match.index}`);
  return parts.join(", ") || "match";
}

function findElementExprJs({ elementId = null, selector = null }) {
  if (elementId) {
    return `findByUsemacId(${JSON.stringify(String(elementId))}, document)`;
  }
  if (selector) {
    return `queryOneDeep(document, ${JSON.stringify(String(selector))})`;
  }
  return "null";
}

async function resolveInSpecificFrame(tabId, frameMeta, { elementId = null, selector = null }, scrollOwnerIntoView = true) {
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
  const lookupExpr = findElementExprJs({ elementId, selector });
  const res = await evalInFrame(tabId, frameMeta, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const el = ${lookupExpr};
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
    elementId: elementId || null,
    frameMeta: frameMeta || null
  };
}

async function resolveMatchInSpecificFrame(tabId, session, frameMeta, match, remainingSkip = 0, scrollOwnerIntoView = true) {
  let offsetX = 0;
  let offsetY = 0;
  if (frameMeta && frameMeta.frameId != null) {
    const fRect = await computeFrameViewportRect(tabId, frameMeta, scrollOwnerIntoView);
    if (!fRect || !fRect.visible) {
      return { found: false, matchCount: 0 };
    }
    offsetX = fRect.x;
    offsetY = fRect.y;
  }
  const idBase = frameMeta?.frameId ? getFrameSlot(session, frameMeta.frameId) * 10000 + 1 : 1;
  const matchLit = JSON.stringify(match);
  const res = await evalInFrame(tabId, frameMeta, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const spec = ${matchLit};
    const skip = ${Math.max(0, Number(remainingSkip) || 0)};
    const reg = getUsemacRefRegistry(${idBase});
    const roots = collectRoots(document);
    const labelMap = new Map();
    const labelNodes = queryAllInRoots(roots, 'label[for]');
    for (let i = 0; i < labelNodes.length; i++) {
      const f = labelNodes[i].getAttribute('for');
      if (f && !labelMap.has(f)) {
        const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
        if (t) labelMap.set(f, t);
      }
    }
    const sel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
    const candidates = queryAllInRoots(roots, sel);
    let matchCount = 0;
    for (let i = 0; i < candidates.length; i++) {
      const el = candidates[i];
      const st = window.getComputedStyle(el);
      if (!st || st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2 || el.getClientRects().length === 0) continue;
      if (!matchesElementSpec(el, spec, labelMap)) continue;
      if (matchCount === skip) {
        const id = assignUsemacNodeId(el, reg);
        if (el.getAttribute('data-usemac-id') !== id) el.setAttribute('data-usemac-id', id);
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        const label = (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.tagName || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
        return {
          found: true,
          matchCount: matchCount + 1,
          id,
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
          label
        };
      }
      matchCount += 1;
    }
    return { found: false, matchCount };
  })()`).catch(() => null);
  const v = res?.result?.value;
  if (!v) return { found: false, matchCount: 0 };
  if (v.found && Number.isFinite(v.x) && Number.isFinite(v.y)) {
    if (v.id) {
      const targetFrameMeta = frameMeta || {
        sessionId: null, contextId: null, frameId: null, parentSessionId: null,
        offsetX: 0, offsetY: 0, isOOPIF: false, hops: []
      };
      session.elementFrameMap.set(v.id, targetFrameMeta);
    }
    return {
      found: true,
      matchCount: v.matchCount,
      target: {
        x: v.x + offsetX,
        y: v.y + offsetY,
        label: v.label || null,
        elementId: v.id || null,
        frameMeta: frameMeta || null
      }
    };
  }
  return { found: false, matchCount: v.matchCount || 0 };
}

async function resolveMatchCenter(tabId, match) {
  const session = getOrCreateTabSession(tabId);
  const desiredIndex = Math.max(0, Number(match?.index) || 0);
  let remaining = desiredIndex;

  const topRes = await resolveMatchInSpecificFrame(tabId, session, null, match, remaining, false);
  if (topRes.found) return topRes.target;
  remaining -= topRes.matchCount;

  let frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveMatchInSpecificFrame(tabId, session, frameMeta, match, remaining, true);
    if (hit.found) return hit.target;
    remaining -= hit.matchCount;
  }
  // Fresh discovery pass in case an iframe mounted since last observe
  if (session.lastChildFrames && session.lastChildFrames.length > 0) {
    const freshFrames = await discoverChildFrames(tabId).catch(() => []);
    for (const frameMeta of freshFrames) {
      if (frames.some((f) => f.frameId === frameMeta.frameId && f.sessionId === frameMeta.sessionId)) continue;
      const hit = await resolveMatchInSpecificFrame(tabId, session, frameMeta, match, remaining, true);
      if (hit.found) return hit.target;
      remaining -= hit.matchCount;
    }
  }
  throw {
    code: "ELEMENT_NOT_FOUND",
    message: `No element matched {${formatMatchDesc(match)}} in tab ${tabId}.`
  };
}

async function resolveSelectorCenter(tabId, cssSelector) {
  const topHit = await resolveInSpecificFrame(tabId, null, { selector: cssSelector }, false);
  if (topHit) return topHit;

  const session = getOrCreateTabSession(tabId);
  let frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveInSpecificFrame(tabId, frameMeta, { selector: cssSelector }, true);
    if (hit) return hit;
  }
  // One fresh discovery pass in case a new OOPIF mounted after last observe
  frames = await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveInSpecificFrame(tabId, frameMeta, { selector: cssSelector }, true);
    if (hit) return hit;
  }
  throw { code: "ELEMENT_NOT_FOUND", message: `Selector ${cssSelector} not found in tab ${tabId}.` };
}

async function resolveElementCenter(tabId, elementId) {
  const session = getOrCreateTabSession(tabId);
  const mappedFrame = session.elementFrameMap.get(elementId);
  if (mappedFrame) {
    const mappedHit = await resolveInSpecificFrame(tabId, mappedFrame, { elementId }, true);
    if (mappedHit) return mappedHit;
  }

  // Fallback: top frame then all discovered child frames
  if (!mappedFrame || mappedFrame.frameId != null) {
    const topHit = await resolveInSpecificFrame(tabId, null, { elementId }, false);
    if (topHit) return topHit;
  }
  const frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    if (mappedFrame && frameMeta === mappedFrame) continue;
    const hit = await resolveInSpecificFrame(tabId, frameMeta, { elementId }, true);
    if (hit) return hit;
  }
  throw { code: "ELEMENT_NOT_FOUND", message: `Element ${elementId} not found in tab ${tabId}.` };
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
  if (typeof step.elementId === "string" && step.elementId.trim() !== "") {
    return resolveElementCenter(tabId, step.elementId.trim());
  }
  if (typeof step.selector === "string" && step.selector.trim() !== "") {
    return resolveSelectorCenter(tabId, step.selector.trim());
  }
  if (hasNonEmptyMatch(step.match)) {
    return resolveMatchCenter(tabId, step.match);
  }
  if (Number.isFinite(step.x) && Number.isFinite(step.y)) {
    return { x: Number(step.x), y: Number(step.y), label: null };
  }
  return null;
}

// True when a step says where to act: a non-blank elementId, selector, match, or a full point.
function stepNamesTarget(step) {
  const named = (value) => typeof value === "string" && value.trim() !== "";
  return named(step?.elementId) || named(step?.selector) || hasNonEmptyMatch(step?.match) || (Number.isFinite(step?.x) && Number.isFinite(step?.y));
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
    pagedown: { key: "PageDown", code: "PageDown", keyCode: 34 },
    // Same names as native pressKey (Sources/UseMacEngine/NativeKeyMap.swift); NativeKeyMapTests checks both tables.
    forwarddelete: { key: "Delete", code: "Delete", keyCode: 46 },
    f1: { key: "F1", code: "F1", keyCode: 112 },
    f2: { key: "F2", code: "F2", keyCode: 113 },
    f3: { key: "F3", code: "F3", keyCode: 114 },
    f4: { key: "F4", code: "F4", keyCode: 115 },
    f5: { key: "F5", code: "F5", keyCode: 116 },
    f6: { key: "F6", code: "F6", keyCode: 117 },
    f7: { key: "F7", code: "F7", keyCode: 118 },
    f8: { key: "F8", code: "F8", keyCode: 119 },
    f9: { key: "F9", code: "F9", keyCode: 120 },
    f10: { key: "F10", code: "F10", keyCode: 121 },
    f11: { key: "F11", code: "F11", keyCode: 122 },
    f12: { key: "F12", code: "F12", keyCode: 123 }
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

// The same names as native pressKey and the daemon's sensitive-shortcut check (ModifierAliases.swift);
// ModifierAliasesTests fails when the two lists differ, so a ⌘/⌃ spelling can't skip the check.
function buildModifierMask(modifiers) {
  if (!Array.isArray(modifiers)) return 0;
  let mask = 0;
  for (const mod of modifiers) {
    const m = String(mod).trim().toLowerCase();
    if (m === "alt" || m === "opt" || m === "option") mask |= 1;
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
  await sendCDP(tabId, "Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x,
    y,
    button,
    clickCount
  });
}

function buildWaitForMutationPromiseJs({ selector = null, elementId = null, match = null, text = null, gone = false, timeoutMs = 5000 }) {
  const selLit = selector ? JSON.stringify(String(selector)) : "null";
  const elIdLit = elementId ? JSON.stringify(String(elementId)) : "null";
  const matchLit = hasNonEmptyMatch(match) ? JSON.stringify(match) : "null";
  const txtLit = text ? JSON.stringify(String(text)) : "null";
  const goneLit = gone ? "true" : "false";
  const ms = clamp(Number(timeoutMs) || 5000, 50, 30000);
  return `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const sel = ${selLit};
    const elId = ${elIdLit};
    const spec = ${matchLit};
    const txt = ${txtLit};
    const txtNorm = txt ? normalizeMatchText(txt) : null;
    const gone = ${goneLit};
    const timeoutMs = ${ms};

    function isElVisible(el) {
      if (!el || !el.isConnected) return false;
      const r = el.getBoundingClientRect();
      const st = window.getComputedStyle(el);
      return Boolean(st && st.display !== 'none' && st.visibility !== 'hidden' && parseFloat(st.opacity) !== 0 && r.width >= 2 && r.height >= 2);
    }

    function isPresent() {
      if (elId) {
        const el = findByUsemacId(elId, document);
        if (!isElVisible(el)) return false;
        if (!txtNorm) return true;
        return normalizeMatchText(el.innerText || el.textContent || el.value || '').includes(txtNorm);
      }
      if (sel) {
        const el = queryOneDeep(document, sel);
        if (!isElVisible(el)) return false;
        if (!txtNorm) return true;
        return normalizeMatchText(el.innerText || el.textContent || el.value || '').includes(txtNorm);
      }
      if (spec) {
        const roots = collectRoots(document);
        const labelMap = new Map();
        const labelNodes = queryAllInRoots(roots, 'label[for]');
        for (let i = 0; i < labelNodes.length; i++) {
          const f = labelNodes[i].getAttribute('for');
          if (f && !labelMap.has(f)) {
            const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
            if (t) labelMap.set(f, t);
          }
        }
        const candSel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
        const cands = queryAllInRoots(roots, candSel);
        const targetIndex = Math.max(0, Number(spec.index) || 0);
        let seen = 0;
        for (let i = 0; i < cands.length; i++) {
          const el = cands[i];
          if (!isElVisible(el)) continue;
          if (!matchesElementSpec(el, spec, labelMap)) continue;
          if (seen === targetIndex) {
            if (!txtNorm) return true;
            return normalizeMatchText(el.innerText || el.textContent || el.value || '').includes(txtNorm);
          }
          seen++;
        }
        return false;
      }
      if (txtNorm) {
        const roots = collectRoots(document);
        for (let r = 0; r < roots.length; r++) {
          const chunk = r === 0
            ? (document.body?.innerText || document.documentElement?.textContent || '')
            : (roots[r].textContent || '');
          if (normalizeMatchText(chunk).includes(txtNorm)) return true;
        }
        return false;
      }
      return true;
    }

    function satisfied() {
      const present = isPresent();
      return gone ? !present : present;
    }

    const started = performance.now();
    if (satisfied()) {
      return Promise.resolve({ matched: true, elapsedMs: 0 });
    }

    return new Promise((resolve) => {
      let done = false;
      let mo = null;
      let timer = null;
      let fallback = null;
      const finish = (matched) => {
        if (done) return;
        done = true;
        if (mo) try { mo.disconnect(); } catch (_) {}
        if (timer) clearTimeout(timer);
        if (fallback) clearInterval(fallback);
        resolve({ matched, elapsedMs: Math.round((performance.now() - started) * 100) / 100 });
      };
      if (typeof MutationObserver === 'function' && document.documentElement) {
        mo = new MutationObserver(() => {
          if (satisfied()) finish(true);
        });
        const obsOpts = { childList: true, subtree: true, attributes: true, characterData: true };
        try { mo.observe(document.documentElement, obsOpts); } catch (_) {}
        const roots = collectRoots(document);
        for (let i = 1; i < roots.length; i++) {
          try { mo.observe(roots[i], obsOpts); } catch (_) {}
        }
      }
      fallback = setInterval(() => {
        if (satisfied()) finish(true);
      }, 200);
      timer = setTimeout(() => finish(false), timeoutMs);
    });
  })()`;
}

async function runWaitForStep(tabId, step, cancelToken = null) {
  const timeoutMs = clamp(Number(step.timeoutMs ?? step.durationMs ?? 5000), 50, 30000);
  const gone = step.gone === true;
  const desc = step.selector || step.elementId || (hasNonEmptyMatch(step.match) ? `{${formatMatchDesc(step.match)}}` : null) || (step.text ? `"${step.text}"` : "condition");
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    if (isCancelled(tabId, cancelToken)) {
      throw CANCELLED_ERROR;
    }
    const remaining = Math.max(50, deadline - Date.now());
    const expr = buildWaitForMutationPromiseJs({
      selector: step.selector || null,
      elementId: step.elementId || null,
      match: step.match || null,
      text: step.text || null,
      gone,
      timeoutMs: remaining
    });

    const session = getOrCreateTabSession(tabId);
    const childFrames = session.lastChildFrames || [];
    const frames = [null, ...childFrames];

    // Race MutationObserver Promise(s) against cancellation without polling overhead.
    let cancelTimer = null;
    const cancelRace = new Promise((resolve) => {
      if (!cancelToken) return;
      cancelTimer = setInterval(() => {
        if (isCancelled(tabId, cancelToken)) {
          clearInterval(cancelTimer);
          cancelTimer = null;
          resolve({ cancelled: true });
        }
      }, CANCEL_POLL_SLICE_MS);
    });

    try {
      if (gone || frames.length === 1) {
        // Single frame (fast path) or gone check on top frame
        const evalPromise = evalInFrame(tabId, null, expr, { returnByValue: true, awaitPromise: true })
          .then((r) => ({ res: r?.result?.value || null }))
          .catch((err) => ({ err }));
        const outcome = await Promise.race([evalPromise, cancelRace]);
        if (outcome?.cancelled || isCancelled(tabId, cancelToken)) {
          throw CANCELLED_ERROR;
        }
        if (outcome?.res?.matched === true) {
          if (gone && childFrames.length > 0) {
            // Also verify none of the child frames still show the element
            const childCheckExpr = buildWaitForMutationPromiseJs({
              selector: step.selector || null,
              elementId: step.elementId || null,
              match: step.match || null,
              text: step.text || null,
              gone: true,
              timeoutMs: Math.max(50, deadline - Date.now())
            });
            const childChecks = await Promise.all(
              childFrames.map((f) => evalInFrame(tabId, f, childCheckExpr, { returnByValue: true, awaitPromise: true }).catch(() => null))
            );
            if (childChecks.every((c) => c?.result?.value?.matched !== false)) {
              return { mechanism: "mutation-observer", message: `${desc} is gone` };
            }
          } else {
            return {
              mechanism: "mutation-observer",
              message: gone ? `${desc} is gone` : `Matched ${desc}`
            };
          }
        }
        if (outcome?.err) {
          // Execution context may have been destroyed by a navigation: retry briefly until deadline.
          await sleepCancellable(Math.min(80, Math.max(0, deadline - Date.now())), tabId, cancelToken);
          continue;
        }
        if (outcome?.res && outcome.res.matched === false) {
          break;
        }
        // Fallback when mock sandbox returns {} (no JS evaluation)
        if (!outcome?.res) {
          break;
        }
      } else {
        // Multiple frames for appearance: resolve as soon as ANY frame's MutationObserver matches!
        const framePromises = frames.map((fMeta) =>
          evalInFrame(tabId, fMeta, expr, { returnByValue: true, awaitPromise: true })
            .then((r) => {
              if (r?.result?.value?.matched === true) {
                return { matched: true, isChild: Boolean(fMeta) };
              }
              return new Promise(() => {}); // wait for other frames or timeout
            })
            .catch(() => new Promise(() => {}))
        );
        const timeoutPromise = sleep(remaining).then(() => ({ matched: false }));
        const outcome = await Promise.race([...framePromises, timeoutPromise, cancelRace]);
        if (outcome?.cancelled || isCancelled(tabId, cancelToken)) {
          throw CANCELLED_ERROR;
        }
        if (outcome?.matched) {
          return {
            mechanism: outcome.isChild ? "mutation-observer (iframe)" : "mutation-observer",
            message: `Matched ${desc}`
          };
        }
        break;
      }
    } finally {
      if (cancelTimer) clearInterval(cancelTimer);
    }
  }

  if (isCancelled(tabId, cancelToken)) {
    throw CANCELLED_ERROR;
  }
  throw {
    code: "WAIT_TIMEOUT",
    message: `Timed out after ${timeoutMs}ms waiting for ${desc}${gone ? " to disappear" : ""}`
  };
}

async function executeAssertStep(tabId, step) {
  const session = getOrCreateTabSession(tabId);
  const tabInfo = await refreshTabMeta(tabId);
  const actualUrl = tabInfo?.url || session.url || "";
  const actualTitle = tabInfo?.title || session.title || "";
  const failures = [];
  let resolvedElementId = null;

  if (typeof step.expectUrl === "string" && step.expectUrl.trim() !== "") {
    const wanted = step.expectUrl.trim();
    if (!actualUrl.toLowerCase().includes(wanted.toLowerCase())) {
      failures.push(`Expected URL to contain "${wanted}", got "${actualUrl}"`);
    }
  }

  const needsDomCheck =
    (typeof step.expectTitle === "string" && step.expectTitle.trim() !== "") ||
    (typeof step.expectText === "string" && step.expectText.trim() !== "") ||
    (typeof step.expectNotText === "string" && step.expectNotText.trim() !== "") ||
    hasNonEmptyMatch(step.match) ||
    (typeof step.selector === "string" && step.selector.trim() !== "") ||
    (typeof step.elementId === "string" && step.elementId.trim() !== "");

  if (needsDomCheck) {
    const checkSpec = {
      expectTitle: typeof step.expectTitle === "string" ? step.expectTitle.trim() : "",
      expectText: typeof step.expectText === "string" ? step.expectText.trim() : "",
      expectNotText: typeof step.expectNotText === "string" ? step.expectNotText.trim() : "",
      selector: typeof step.selector === "string" ? step.selector.trim() : "",
      elementId: typeof step.elementId === "string" ? step.elementId.trim() : "",
      match: hasNonEmptyMatch(step.match) ? step.match : null
    };
    const specLit = JSON.stringify(checkSpec);
    const frameCheckExpr = `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const s = ${specLit};
      const title = document.title || '';
      const roots = collectRoots(document);
      const textParts = [document.body?.innerText || document.documentElement?.textContent || ''];
      for (let r = 1; r < roots.length; r++) {
        if (roots[r]?.textContent) textParts.push(roots[r].textContent);
      }
      const bodyNorm = normalizeMatchText(textParts.join(' '));
      const hasExpectText = s.expectText ? bodyNorm.includes(normalizeMatchText(s.expectText)) : null;
      const hasNotText = s.expectNotText ? bodyNorm.includes(normalizeMatchText(s.expectNotText)) : null;

      function isElVisible(el) {
        if (!el || !el.isConnected) return false;
        const r = el.getBoundingClientRect();
        const st = window.getComputedStyle(el);
        return Boolean(st && st.display !== 'none' && st.visibility !== 'hidden' && parseFloat(st.opacity) !== 0 && r.width >= 2 && r.height >= 2);
      }

      let elementFound = null;
      let elementId = null;
      if (s.elementId || s.selector || s.match) {
        let hit = null;
        if (s.elementId) {
          const el = findByUsemacId(s.elementId, document);
          if (isElVisible(el)) hit = el;
        } else if (s.selector) {
          const el = queryOneDeep(document, s.selector);
          if (isElVisible(el)) hit = el;
        } else if (s.match) {
          const roots = collectRoots(document);
          const labelMap = new Map();
          const labelNodes = queryAllInRoots(roots, 'label[for]');
          for (let i = 0; i < labelNodes.length; i++) {
            const f = labelNodes[i].getAttribute('for');
            if (f && !labelMap.has(f)) {
              const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
              if (t) labelMap.set(f, t);
            }
          }
          const candSel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
          const cands = queryAllInRoots(roots, candSel);
          const idx = Math.max(0, Number(s.match.index) || 0);
          let seen = 0;
          for (let i = 0; i < cands.length; i++) {
            if (!isElVisible(cands[i])) continue;
            if (!matchesElementSpec(cands[i], s.match, labelMap)) continue;
            if (seen === idx) { hit = cands[i]; break; }
            seen++;
          }
        }
        elementFound = Boolean(hit);
        if (hit) {
          const reg = getUsemacRefRegistry(1);
          elementId = lookupUsemacNodeId(hit, reg) || hit.getAttribute('data-usemac-id') || null;
        }
      }
      return { title, hasExpectText, hasNotText, elementFound, elementId };
    })()`;

    const frames = [null, ...(session.lastChildFrames || [])];
    const results = await Promise.all(
      frames.map((f) => evalInFrame(tabId, f, frameCheckExpr).then((r) => r?.result?.value || null).catch(() => null))
    );
    const topRes = results[0];
    const docTitle = topRes?.title || actualTitle;

    if (checkSpec.expectTitle) {
      if (!docTitle.toLowerCase().includes(checkSpec.expectTitle.toLowerCase())) {
        failures.push(`Expected title to contain "${checkSpec.expectTitle}", got "${docTitle}"`);
      }
    }
    if (checkSpec.expectText) {
      const foundText = results.some((r) => r?.hasExpectText === true);
      if (!foundText) {
        failures.push(`Expected text "${checkSpec.expectText}" not found on page`);
      }
    }
    if (checkSpec.expectNotText) {
      const foundForbidden = results.some((r) => r?.hasNotText === true);
      if (foundForbidden) {
        failures.push(`Unexpected text "${checkSpec.expectNotText}" was found on page`);
      }
    }
    if (checkSpec.elementId || checkSpec.selector || checkSpec.match) {
      const hitRes = results.find((r) => r?.elementFound === true) || null;
      const found = Boolean(hitRes);
      if (hitRes?.elementId) resolvedElementId = hitRes.elementId;
      const desc = checkSpec.selector || checkSpec.elementId || `{${formatMatchDesc(checkSpec.match)}}`;
      if (step.gone === true) {
        if (found) failures.push(`Expected element ${desc} to be gone, but it is still visible`);
      } else {
        if (!found) failures.push(`Expected element ${desc} not found`);
      }
    }
  }

  if (failures.length > 0) {
    throw { code: "ASSERTION_FAILED", message: failures.join("; ") };
  }
  return {
    mechanism: "cdp-assert",
    message: "Assertion passed",
    resolvedElementId
  };
}

async function executeScrollUntilStep(tabId, step, cancelToken = null) {
  const session = getOrCreateTabSession(tabId);
  const maxScrolls = clamp(Number(step.maxScrolls) || 8, 1, 30);
  const deltaY = Number.isFinite(Number(step.deltaY)) && Number(step.deltaY) !== 0
    ? Number(step.deltaY)
    : (Number.isFinite(Number(step.deltaX)) && Number(step.deltaX) !== 0 ? 0 : 600);
  const deltaX = Number.isFinite(Number(step.deltaX)) ? Number(step.deltaX) : 0;

  const checkSpec = {
    elementId: typeof step.elementId === "string" ? step.elementId.trim() : "",
    selector: typeof step.selector === "string" ? step.selector.trim() : "",
    match: hasNonEmptyMatch(step.match) ? step.match : null,
    text: typeof step.text === "string" ? step.text.trim() : ""
  };
  if (!checkSpec.elementId && !checkSpec.selector && !checkSpec.match && !checkSpec.text) {
    throw { code: "INVALID_REQUEST", message: "scrollUntil requires match, selector, elementId, or text." };
  }
  const specLit = JSON.stringify(checkSpec);
  const desc = checkSpec.selector || checkSpec.elementId || (checkSpec.match ? `{${formatMatchDesc(checkSpec.match)}}` : `"${checkSpec.text}"`);

  const probeInViewportExpr = `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const s = ${specLit};
    const vw = window.innerWidth || 1280;
    const vh = window.innerHeight || 800;
    const sx = window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0;
    const sy = window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0;

    function isVisibleInViewport(el) {
      if (!el || !el.isConnected) return false;
      const st = window.getComputedStyle(el);
      if (!st || st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return false;
      return r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw;
    }

    let hit = null;
    if (s.elementId) {
      const el = findByUsemacId(s.elementId, document);
      if (isVisibleInViewport(el)) hit = el;
    } else if (s.selector) {
      const el = queryOneDeep(document, s.selector);
      if (isVisibleInViewport(el)) hit = el;
    } else if (s.match) {
      const roots = collectRoots(document);
      const labelMap = new Map();
      const labelNodes = queryAllInRoots(roots, 'label[for]');
      for (let i = 0; i < labelNodes.length; i++) {
        const f = labelNodes[i].getAttribute('for');
        if (f && !labelMap.has(f)) {
          const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
          if (t) labelMap.set(f, t);
        }
      }
      const candSel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
      const cands = queryAllInRoots(roots, candSel);
      const idx = Math.max(0, Number(s.match.index) || 0);
      let seen = 0;
      for (let i = 0; i < cands.length; i++) {
        if (!matchesElementSpec(cands[i], s.match, labelMap)) continue;
        if (seen === idx) {
          if (isVisibleInViewport(cands[i])) hit = cands[i];
          break;
        }
        seen++;
      }
    } else if (s.text) {
      const needle = normalizeMatchText(s.text);
      const all = document.querySelectorAll('h1, h2, h3, h4, p, a, button, li, td, th, span, div, label, [role="row"], [role="gridcell"]');
      for (let i = 0; i < all.length && i < 1200; i++) {
        const el = all[i];
        if (!isVisibleInViewport(el)) continue;
        if (el.children.length > 6) continue;
        if (normalizeMatchText(el.innerText || el.textContent || '').includes(needle)) {
          hit = el;
          break;
        }
      }
    }

    let id = null;
    if (hit) {
      const reg = getUsemacRefRegistry(1);
      id = assignUsemacNodeId(hit, reg);
      if (hit.getAttribute && hit.getAttribute('data-usemac-id') !== id) hit.setAttribute('data-usemac-id', id);
    }
    return { found: Boolean(hit), id, scrollX: sx, scrollY: sy };
  })()`;

  const vp = effectiveViewport(session);
  const scrollXPt = Number.isFinite(step.x) ? Number(step.x) : Math.round(vp.width / 2);
  const scrollYPt = Number.isFinite(step.y) ? Number(step.y) : Math.round(vp.height / 2);
  let totalDeltaX = 0;
  let totalDeltaY = 0;

  for (let i = 0; i <= maxScrolls; i++) {
    if (isCancelled(tabId, cancelToken)) throw CANCELLED_ERROR;
    const probeRes = await evalInFrame(tabId, null, probeInViewportExpr).catch(() => null);
    const probe = probeRes?.result?.value;
    if (probe?.found) {
      if (probe.id) {
        session.elementFrameMap.set(probe.id, {
          sessionId: null, contextId: null, frameId: null, parentSessionId: null,
          offsetX: 0, offsetY: 0, isOOPIF: false, hops: []
        });
      }
      return {
        mechanism: "cdp-scroll-until",
        message: `Found ${desc} after ${i} scroll(s)`,
        scrollDeltaX: totalDeltaX,
        scrollDeltaY: totalDeltaY,
        resolvedElementId: probe.id || null
      };
    }
    if (i === maxScrolls) break;

    const beforeX = probe?.scrollX ?? 0;
    const beforeY = probe?.scrollY ?? 0;
    await sendCDP(tabId, "Input.dispatchMouseEvent", {
      type: "mouseWheel",
      x: scrollXPt,
      y: scrollYPt,
      deltaX,
      deltaY
    });
    await waitForAnimationFrames(tabId, 40);

    const afterRes = await evalInFrame(tabId, null, `({
      scrollX: window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0,
      scrollY: window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0
    })`).catch(() => null);
    const after = afterRes?.result?.value;
    if (after) {
      const dx = Math.round((after.scrollX - beforeX) * 10) / 10;
      const dy = Math.round((after.scrollY - beforeY) * 10) / 10;
      totalDeltaX += dx;
      totalDeltaY += dy;
      // Hit end of scroll (no movement)
      if (Math.abs(dx) < 2 && Math.abs(dy) < 2) {
        // One final check in case an inner scrollable container moved instead of window
        const finalProbe = await evalInFrame(tabId, null, probeInViewportExpr).catch(() => null);
        if (finalProbe?.result?.value?.found) {
          return {
            mechanism: "cdp-scroll-until",
            message: `Found ${desc} after ${i + 1} scroll(s)`,
            scrollDeltaX: totalDeltaX,
            scrollDeltaY: totalDeltaY,
            resolvedElementId: finalProbe.result.value.id || null
          };
        }
        throw {
          code: "ELEMENT_NOT_FOUND",
          message: `scrollUntil reached end of scroll after ${i + 1} scroll(s) without finding ${desc}`
        };
      }
    }
  }

  throw {
    code: "ELEMENT_NOT_FOUND",
    message: `scrollUntil did not find ${desc} within ${maxScrolls} scroll(s)`
  };
}

async function executeFillFormStep(tabId, step, cancelToken = null) {
  const fields = Array.isArray(step.fields) ? step.fields : [];
  if (fields.length === 0) {
    throw { code: "INVALID_REQUEST", message: "fillForm requires a non-empty 'fields' array." };
  }

  const session = getOrCreateTabSession(tabId);
  const childFrames = session.lastChildFrames || [];
  const candidateFrames = [null, ...childFrames];
  const filledSummaries = [];
  const fieldErrors = [];

  for (let fi = 0; fi < fields.length; fi++) {
    if (isCancelled(tabId, cancelToken)) throw CANCELLED_ERROR;
    const field = fields[fi];
    if (!field || typeof field !== "object") continue;
    const fieldDesc = field.label || field.selector || field.elementId || (hasNonEmptyMatch(field.match) ? formatMatchDesc(field.match) : `field[${fi}]`);
    const fieldLit = JSON.stringify(field);

    let outcome = null;
    for (const fMeta of candidateFrames) {
      const res = await evalInFrame(tabId, fMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const f = ${fieldLit};
        const roots = collectRoots(document);
        const labelMap = new Map();
        const labelNodes = queryAllInRoots(roots, 'label[for]');
        for (let i = 0; i < labelNodes.length; i++) {
          const forId = labelNodes[i].getAttribute('for');
          if (forId && !labelMap.has(forId)) {
            const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
            if (t) labelMap.set(forId, t);
          }
        }

        function isInteractable(el) {
          if (!el || !el.isConnected) return false;
          const st = window.getComputedStyle(el);
          if (!st || st.display === 'none' || st.visibility === 'hidden') return false;
          const r = el.getBoundingClientRect();
          return r.width >= 2 && r.height >= 2;
        }

        function findControl() {
          if (f.elementId && String(f.elementId).trim()) {
            const el = findByUsemacId(String(f.elementId).trim(), document);
            if (el) return el;
          }
          if (f.selector && String(f.selector).trim()) {
            const el = queryOneDeep(document, String(f.selector).trim());
            if (el) return el;
          }
          const controlSel = 'input, textarea, select, [contenteditable="true"], [role="combobox"], [role="textbox"], [role="searchbox"], [role="checkbox"], [role="switch"], [role="radio"], [aria-haspopup="listbox"]';
          const controls = queryAllInRoots(roots, controlSel);
          if (f.match && typeof f.match === 'object') {
            const idx = Math.max(0, Number(f.match.index) || 0);
            let seen = 0;
            for (let i = 0; i < controls.length; i++) {
              if (!isInteractable(controls[i])) continue;
              if (!matchesElementSpec(controls[i], f.match, labelMap)) continue;
              if (seen === idx) return controls[i];
              seen++;
            }
          }
          if (f.label && String(f.label).trim()) {
            const targetNorm = normalizeMatchText(f.label);
            let best = null;
            let bestScore = 0;
            for (let i = 0; i < controls.length; i++) {
              const c = controls[i];
              if (!isInteractable(c)) continue;
              const info = extractElementTitleValue(c, labelMap);
              const cands = [
                info.title,
                c.getAttribute?.('aria-label') || '',
                c.getAttribute?.('placeholder') || '',
                c.getAttribute?.('name') || '',
                c.id ? (labelMap.get(c.id) || '') : ''
              ];
              for (const cand of cands) {
                const n = normalizeMatchText(cand);
                if (!n) continue;
                if (n === targetNorm) return c;
                if (n.includes(targetNorm) && bestScore < 2) { best = c; bestScore = 2; }
                else if (targetNorm.includes(n) && n.length >= 3 && bestScore < 1) { best = c; bestScore = 1; }
              }
            }
            if (best) return best;
          }
          return null;
        }

        const el = findControl();
        if (!el) return { found: false };

        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const tag = (el.tagName || '').toLowerCase();
        const ariaRole = (el.getAttribute?.('role') || '').toLowerCase();
        const isCombobox = ariaRole === 'combobox' || el.getAttribute?.('aria-haspopup') === 'listbox';

        if (isCombobox && tag !== 'select') {
          el.focus();
          el.click();
          const wantedVal = f.value != null ? String(f.value) : '';
          if (wantedVal) {
            const filterInput = tag === 'input' ? el : el.querySelector?.('input');
            if (filterInput) {
              const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
              if (setter) setter.call(filterInput, wantedVal);
              else filterInput.value = wantedVal;
              filterInput.dispatchEvent(new Event('input', { bubbles: true }));
            }
          }
          return { found: true, kind: 'combobox', wanted: wantedVal };
        }

        if (tag === 'select') {
          const wanted = String(f.value ?? '').trim();
          const wantedLower = wanted.toLowerCase();
          const opts = Array.from(el.options || []);
          const opt =
            opts.find((o) => o.value === wanted) ||
            opts.find((o) => (o.value || '').toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase().includes(wantedLower));
          if (!opt) {
            const sample = opts.slice(0, 10).map((o) => (o.text || o.value || '').trim()).join(', ');
            return { found: true, ok: false, error: 'No matching <option> for "' + wanted + '" (available: ' + sample + ')' };
          }
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set;
          if (setter) setter.call(el, opt.value);
          else el.value = opt.value;
          opt.selected = true;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { found: true, ok: true, kind: 'select', detail: (opt.text || opt.value).trim() };
        }

        const isCheckable =
          (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) ||
          ariaRole === 'checkbox' || ariaRole === 'switch' || ariaRole === 'radio';
        if (isCheckable) {
          let desired;
          if (typeof f.checked === 'boolean') {
            desired = f.checked;
          } else {
            const lower = String(f.value ?? 'true').trim().toLowerCase();
            desired = ['true', 'checked', 'on', '1', 'yes'].includes(lower);
          }
          const current = tag === 'input' ? Boolean(el.checked) : el.getAttribute('aria-checked') === 'true';
          if (current !== desired) el.click();
          const finalState = tag === 'input' ? Boolean(el.checked) : el.getAttribute('aria-checked') === 'true';
          return { found: true, ok: true, kind: 'check', detail: 'checked=' + finalState };
        }

        const valStr = String(f.value ?? '');
        el.focus();
        if (tag === 'textarea' || tag === 'input') {
          const proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) setter.call(el, valStr);
          else el.value = valStr;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.dispatchEvent(new Event('blur', { bubbles: false }));
          return { found: true, ok: true, kind: tag, detail: valStr.length + ' chars' };
        }
        if (el.isContentEditable) {
          el.textContent = valStr;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { found: true, ok: true, kind: 'contenteditable', detail: valStr.length + ' chars' };
        }
        return { found: true, ok: false, error: 'Unsupported form control: ' + tag };
      })()`).catch(() => null);

      const v = res?.result?.value;
      if (v?.found) {
        outcome = { ...v, frameMeta: fMeta };
        break;
      }
    }

    if (!outcome) {
      fieldErrors.push(`Field "${fieldDesc}" not found`);
      continue;
    }

    if (outcome.kind === "combobox") {
      // Wait via MutationObserver Promise (up to 350ms) for [role="option"] to appear, then click the matching option.
      const wantedLit = JSON.stringify(outcome.wanted || "");
      const comboRes = await evalInFrame(tabId, outcome.frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const wantedNorm = normalizeMatchText(${wantedLit});
        function findOption() {
          const roots = collectRoots(document);
          const opts = queryAllInRoots(roots, '[role="option"], [role="listbox"] li');
          let partial = null;
          for (let i = 0; i < opts.length; i++) {
            const o = opts[i];
            const st = window.getComputedStyle(o);
            if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
            const r = o.getBoundingClientRect();
            if (r.width < 2 || r.height < 2) continue;
            const txt = normalizeMatchText(o.innerText || o.textContent || o.getAttribute('aria-label') || '');
            if (!wantedNorm || txt === wantedNorm) return o;
            if (!partial && txt.includes(wantedNorm)) partial = o;
          }
          return partial;
        }
        const immediate = findOption();
        if (immediate) {
          immediate.click();
          return Promise.resolve({ ok: true, detail: (immediate.innerText || immediate.textContent || '').trim() });
        }
        return new Promise((resolve) => {
          let done = false;
          let mo = null;
          const finish = (res) => {
            if (done) return;
            done = true;
            if (mo) try { mo.disconnect(); } catch (_) {}
            clearTimeout(timer);
            resolve(res);
          };
          if (typeof MutationObserver === 'function' && document.documentElement) {
            mo = new MutationObserver(() => {
              const hit = findOption();
              if (hit) {
                hit.click();
                finish({ ok: true, detail: (hit.innerText || hit.textContent || '').trim() });
              }
            });
            mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
          }
          const timer = setTimeout(() => {
            const hit = findOption();
            if (hit) {
              hit.click();
              finish({ ok: true, detail: (hit.innerText || hit.textContent || '').trim() });
            } else {
              finish({ ok: false, error: 'No [role="option"] matched "' + ${wantedLit} + '"' });
            }
          }, 350);
        });
      })()`, { returnByValue: true, awaitPromise: true }).catch(() => null);
      const cv = comboRes?.result?.value;
      if (cv?.ok) {
        filledSummaries.push(`${fieldDesc}=${cv.detail}`);
      } else {
        fieldErrors.push(`${fieldDesc}: ${cv?.error || "combobox option not found"}`);
      }
      continue;
    }

    if (outcome.ok === false) {
      fieldErrors.push(`${fieldDesc}: ${outcome.error || "failed"}`);
    } else {
      filledSummaries.push(`${fieldDesc}`);
    }
  }

  // Optional submit action
  if (fieldErrors.length === 0 && (hasNonEmptyMatch(step.submitMatch) || (typeof step.submitSelector === "string" && step.submitSelector.trim() !== ""))) {
    const submitStep = {
      action: "click",
      match: hasNonEmptyMatch(step.submitMatch) ? step.submitMatch : undefined,
      selector: typeof step.submitSelector === "string" && step.submitSelector.trim() !== "" ? step.submitSelector.trim() : undefined
    };
    await executeActionStep(tabId, submitStep, cancelToken);
  } else {
    await waitForAnimationFrames(tabId, 40);
  }

  // Automatically surface HTML5 validation errors, aria-invalid fields, and visible alerts
  const validationRes = await evalInFrame(tabId, null, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const roots = collectRoots(document);
    const errors = [];
    const seen = new Set();
    const pushErr = (s) => {
      const clean = String(s || '').replace(/\\s+/g, ' ').trim().slice(0, 160);
      if (clean && !seen.has(clean)) { seen.add(clean); errors.push(clean); }
    };
    const invalids = queryAllInRoots(roots, ':invalid, [aria-invalid="true"]');
    for (let i = 0; i < invalids.length && errors.length < 10; i++) {
      const el = invalids[i];
      const tag = (el.tagName || '').toLowerCase();
      if (tag === 'form' || tag === 'fieldset') continue;
      const name = el.getAttribute('aria-label') || el.getAttribute('name') || el.getAttribute('placeholder') || el.id || tag;
      let msg = el.validationMessage || '';
      const errId = el.getAttribute('aria-errormessage') || el.getAttribute('aria-describedby');
      if (!msg && errId) {
        msg = errId.split(/\\s+/).map((id) => document.getElementById(id)?.innerText || '').filter(Boolean).join(' ');
      }
      if (msg) pushErr(name + ': ' + msg);
      else if (el.getAttribute('aria-invalid') === 'true') pushErr(name + ': invalid');
    }
    const alerts = queryAllInRoots(roots, '[role="alert"], [aria-live="assertive"]');
    for (let i = 0; i < alerts.length && errors.length < 12; i++) {
      const a = alerts[i];
      const st = window.getComputedStyle(a);
      if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
      const txt = (a.innerText || a.textContent || '').trim();
      if (txt) pushErr('alert: ' + txt);
    }
    return errors;
  })()`).catch(() => null);
  const validationErrors = Array.isArray(validationRes?.result?.value) ? validationRes.result.value : [];

  if (fieldErrors.length > 0) {
    const detail = validationErrors.length > 0 ? `; validation: ${validationErrors.join(" | ")}` : "";
    throw { code: "FORM_FILL_FAILED", message: `${fieldErrors.join("; ")}${detail}` };
  }

  const msgParts = [`Filled ${filledSummaries.length} field(s)`];
  if (validationErrors.length > 0) {
    msgParts.push(`validationErrors=[${validationErrors.join(" | ")}]`);
  }
  return {
    mechanism: "cdp-fill-form",
    message: msgParts.join(" · "),
    blockedWarning: validationErrors.length > 0 ? `Form validation errors: ${validationErrors.join(" | ")}` : null
  };
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

  if (action === "assert") {
    return executeAssertStep(tabId, step);
  }

  if (action === "scrollUntil") {
    return executeScrollUntilStep(tabId, step, cancelToken);
  }

  if (action === "fillForm") {
    return executeFillFormStep(tabId, step, cancelToken);
  }

  if (action === "waitFor") {
    return runWaitForStep(tabId, step, cancelToken);
  }

  if (action === "scrollIntoView") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw { code: "ELEMENT_NOT_FOUND", message: "scrollIntoView requires elementId, selector, or match." };
    }
    return {
      mechanism: "cdp-scroll-into-view",
      message: target.label || null,
      resolvedElementId: target.elementId || null
    };
  }

  if (action === "click" || action === "doubleClick" || action === "rightClick") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error(`${action} requires elementId, selector, match, or (x, y).`);
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
    const session = getOrCreateTabSession(tabId);
    const beforeUrl = session.url || "";
    session.navigating = false;
    const pt = await moveCursorSmoothly(tabId, target.x, target.y, label);
    emitCursor(tabId, pt.x, pt.y, "click", label);

    if (action === "click") {
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
    } else if (action === "doubleClick") {
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 2);
    } else {
      await dispatchMouseClick(tabId, pt.x, pt.y, "right", 1);
    }

    // Event-driven post-click settle: double-rAF (~16-33ms) + navigation/download detection instead of blind 140ms sleep.
    await waitForAnimationFrames(tabId, 40);
    if (state.lastDownloadAt >= clickStartAt) {
      const dl = await waitForDownloadCompletion(state.lastDownloadId, 4500);
      const path = dl?.filename || state.lastDownloadFilename || null;
      return {
        mechanism: "cdp-mouse (download)",
        message: path ? `Download ${dl?.state || "started"}: ${path}` : "Download started",
        downloadPath: path,
        resolvedElementId: target.elementId || null
      };
    }
    const afterTab = await refreshTabMeta(tabId);
    if (session.navigating || (afterTab && (afterTab.status === "loading" || (beforeUrl && afterTab.url && afterTab.url !== beforeUrl)))) {
      await waitForTabLoad(tabId, 3200);
      return {
        mechanism: "cdp-mouse (navigated)",
        message: afterTab?.url || session.url || null,
        resolvedElementId: target.elementId || null
      };
    }
    return { mechanism: "cdp-mouse", message: null, resolvedElementId: target.elementId || null };
  }

  if (action === "hover") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error("hover requires elementId, selector, match, or (x, y).");
    }
    const label = target.label ? `Hovering ${target.label}` : "Hovering";
    const pt = await moveCursorSmoothly(tabId, target.x, target.y, label);
    emitCursor(tabId, pt.x, pt.y, "hover", label);
    await waitForAnimationFrames(tabId, 40);
    return {
      mechanism: "cdp-hover",
      message: target.label || `(${Math.round(pt.x)}, ${Math.round(pt.y)})`,
      resolvedElementId: target.elementId || null
    };
  }

  if (action === "focus") {
    const target = await resolveStepTarget(tabId, step);
    const resolvedId = target?.elementId || step.elementId || null;
    if (resolvedId || step.selector) {
      const lookupExpr = findElementExprJs({ elementId: resolvedId, selector: resolvedId ? null : step.selector });
      await evalInFrame(tabId, target?.frameMeta || null, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = ${lookupExpr};
        if (el) el.focus();
      })()`);
    }
    if (target) {
      await moveCursorSmoothly(tabId, target.x, target.y, "Focusing");
    }
    return { mechanism: "cdp-focus", message: null, resolvedElementId: resolvedId };
  }

  if (action === "setValue" || action === "type") {
    // setValue replaces a field's text, so it must name the field: without one it used to select-all and type into
    // whatever had focus. Typing into the focused element is what "type" is for.
    if (action === "setValue" && !stepNamesTarget(step)) {
      throw {
        code: "INVALID_REQUEST",
        message: "setValue names no field: pass elementId (an @bN id from browser_observe), match, or selector. Nothing was typed. To type into the focused field, use type."
      };
    }
    const session = getOrCreateTabSession(tabId);
    const text = step.text ?? "";
    const target = await resolveStepTarget(tabId, step);
    const frameMeta = target?.frameMeta || null;
    const resolvedId = target?.elementId || (typeof step.elementId === "string" && step.elementId.trim() ? step.elementId.trim() : null);
    const hasDomRef = Boolean(resolvedId || (typeof step.selector === "string" && step.selector.trim()));
    const lookupExpr = findElementExprJs({ elementId: resolvedId, selector: resolvedId ? null : step.selector });

    // Single collapsed eval for setValue on DOM targets: handles <select>, checkbox/radio, OR focuses & clears text input!
    if (action === "setValue" && hasDomRef) {
      const textLit = JSON.stringify(String(text));
      const prepRes = await evalInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = ${lookupExpr};
        if (!el) return { handled: false, cleared: false };
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
        el.focus();
        if ('value' in el && el.type !== 'file') {
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
        return { handled: false, cleared: true };
      })()`);
      const sv = prepRes?.result?.value;
      if (sv?.handled) {
        if (!sv.ok) throw new Error(sv.error || "Failed to select option.");
        return {
          mechanism: sv.mechanism || "cdp-select",
          message: sv.message || null,
          resolvedElementId: resolvedId
        };
      }
    }

    if (target) {
      const pt = await moveCursorSmoothly(tabId, target.x, target.y, "Typing");
      emitCursor(tabId, pt.x, pt.y, "type", "Typing");
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
    } else {
      emitCursor(tabId, session.cursor.x, session.cursor.y, "type", "Typing");
    }

    if (action === "setValue" && !hasDomRef) {
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
    }

    // Single finalization eval: dispatches 'change', plus OOPIF fallback value sync ONLY when frameMeta?.isOOPIF === true.
    if (hasDomRef) {
      const isOOPIF = frameMeta?.isOOPIF === true;
      const textLit = JSON.stringify(String(text));
      const isSetValue = action === "setValue" ? "true" : "false";
      await evalInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = ${lookupExpr};
        if (!el) return;
        if (${isOOPIF ? "true" : "false"} && ${text.length > 0 ? "true" : "false"} && 'value' in el && el.type !== 'file') {
          const wanted = ${textLit};
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
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()`).catch(() => {});
    }

    return {
      mechanism: frameMeta?.isOOPIF === true ? "cdp-input (iframe)" : "cdp-input",
      message: null,
      resolvedElementId: resolvedId
    };
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
    await waitForAnimationFrames(tabId, 45);

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
      await waitForAnimationFrames(tabId, 35);
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
    if (step.selector || step.text || hasNonEmptyMatch(step.match)) {
      return runWaitForStep(tabId, { ...step, timeoutMs: step.timeoutMs ?? step.durationMs ?? 6000 }, cancelToken);
    }
    const ms = clamp(Number(step.durationMs ?? step.ms ?? 500), 0, 30000);
    await sleepCancellable(ms, tabId, cancelToken);
    return { mechanism: "timer", message: null };
  }

  if (action === "uploadFile") {
    const files = Array.isArray(step.files) ? step.files.filter((f) => typeof f === "string" && f.trim().length > 0) : [];
    if (files.length === 0) {
      throw new Error("uploadFile requires a non-empty 'files' array of local file paths.");
    }

    let resolvedUploadId = typeof step.elementId === "string" && step.elementId.trim() ? step.elementId.trim() : null;
    if (!resolvedUploadId && !step.selector && hasNonEmptyMatch(step.match)) {
      const mTarget = await resolveMatchCenter(tabId, step.match).catch(() => null);
      if (mTarget?.elementId) resolvedUploadId = mTarget.elementId;
    }

    const lookupTargetJs = resolvedUploadId
      ? `findByUsemacId(${JSON.stringify(resolvedUploadId)}, document)`
      : step.selector
        ? `queryOneDeep(document, ${JSON.stringify(String(step.selector))})`
        : "null";
    const hasExplicitTarget = Boolean(resolvedUploadId || step.selector);

    const findInputExpr = `(() => {
      ${QUERY_DEEP_HELPER_JS}
      let target = ${lookupTargetJs};
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
      } else if (!${hasExplicitTarget ? "true" : "false"}) {
        const all = queryAllDeep(document, 'input[type="file"]');
        if (all.length >= 1) input = all[0];
      }
      return input || null;
    })()`;

    // Tier 1: Direct <input type="file"> across top frame and child OOPIFs/iframes (zero Finder!)
    const session = getOrCreateTabSession(tabId);
    const candidateFrames = [];
    const mappedFrame = resolvedUploadId ? session.elementFrameMap.get(resolvedUploadId) : null;
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
            await waitForAnimationFrames(tabId, 40);
            return {
              mechanism: frameMeta?.isOOPIF ? "cdp-file-input (iframe)" : "cdp-file-input",
              message: `Uploaded ${files.length} file(s): ${files.map((f) => f.split("/").pop()).join(", ")}`,
              resolvedElementId: resolvedUploadId
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
      throw new Error("uploadFile found no <input type='file'> and no clickable target (provide elementId, selector, match, or x/y).");
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
        await waitForAnimationFrames(tabId, 40);
        return {
          mechanism: "cdp-file-chooser",
          message: `Uploaded ${files.length} file(s) via intercepted chooser: ${files.map((f) => f.split("/").pop()).join(", ")}`,
          resolvedElementId: target.elementId || resolvedUploadId
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
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "dragOver",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "drop",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await waitForAnimationFrames(tabId, 40);
    return {
      mechanism: "cdp-drag-drop",
      message: `Dropped ${files.length} file(s) at (${Math.round(pt.x)}, ${Math.round(pt.y)}): ${files.map((f) => f.split("/").pop()).join(", ")}`,
      resolvedElementId: target.elementId || resolvedUploadId
    };
  }

  if (action === "target") {
    const target = await resolveStepTarget(tabId, step);
    if (target) {
      await moveCursorSmoothly(tabId, target.x, target.y, "Targeting");
    }
    return { mechanism: "cdp-target", message: null, resolvedElementId: target?.elementId || null };
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
      await waitForAnimationFrames(tabId, 45);
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

async function extractTablesWithVerticalScan(tabId, scopeSelector = null, maxChars = 16000, frameMeta = null) {
  const scopeLit = scopeSelector ? JSON.stringify(String(scopeSelector)) : "null";
  const scrollerProbe = await evalInFrame(tabId, frameMeta, `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const root = ${scopeLit} ? queryOneDeep(document, ${scopeLit}) : document;
      if (!root) return null;
      const candidates = queryAllDeep(root, '[role="grid"], [role="table"], [role="treegrid"], div, section, tbody');
      let best = null;
      let bestScore = 0;
      for (let i = 0; i < candidates.length && i < 800; i++) {
        const el = candidates[i];
        const st = window.getComputedStyle(el);
        if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
        if (st.overflowY !== 'auto' && st.overflowY !== 'scroll') continue;
        const overflow = el.scrollHeight - el.clientHeight;
        if (overflow <= 40 || el.clientWidth < 160 || el.clientHeight < 80) continue;
        const hasGrid = el.matches?.('[role="grid"], [role="table"], [role="treegrid"], tbody')
          || Boolean(el.querySelector?.('[role="gridcell"], [role="cell"], [role="row"], td, tr'))
          || Boolean(el.closest?.('[role="grid"], [role="table"], [role="treegrid"], table'));
        const score = overflow + (hasGrid ? 100000 : 0);
        if (score > bestScore) {
          bestScore = score;
          best = el;
        }
      }
      if (best) {
        best.setAttribute('data-usemac-vscan', '1');
        return {
          isWindow: false,
          origTop: best.scrollTop,
          clientHeight: best.clientHeight,
          scrollHeight: best.scrollHeight
        };
      }
      const se = document.scrollingElement || document.documentElement;
      if (se && se.scrollHeight > window.innerHeight + 40) {
        return {
          isWindow: true,
          origTop: window.scrollY || se.scrollTop || 0,
          clientHeight: window.innerHeight || se.clientHeight,
          scrollHeight: se.scrollHeight
        };
      }
      return null;
    })()`).catch(() => null);

  const info = scrollerProbe?.result?.value;
  if (!info || info.scrollHeight <= info.clientHeight + 40) {
    const single = await extractTablesSinglePass(tabId, scopeSelector, frameMeta);
    const fmt = formatExtractedTablesToMarkdown(single, maxChars);
    return { ...fmt, scannedSteps: 1 };
  }

  const maxScrollTop = info.scrollHeight - info.clientHeight;
  const stepPx = Math.max(200, Math.round(info.clientHeight * 0.7));
  const positions = [0];
  for (let y = stepPx; y < maxScrollTop; y += stepPx) {
    positions.push(y);
    if (positions.length >= 14) break;
  }
  if (positions[positions.length - 1] < maxScrollTop) {
    positions.push(maxScrollTop);
  }

  let headers = null;
  const seenRows = new Set();
  const mergedRows = [];
  let stepsDone = 0;

  try {
    for (const pos of positions) {
      await evalInFrame(tabId, frameMeta, info.isWindow
        ? `window.scrollTo({ top: ${pos}, behavior: 'instant' })`
        : `(() => {
            ${QUERY_DEEP_HELPER_JS}
            const el = queryOneDeep(document, '[data-usemac-vscan="1"]');
            if (el) el.scrollTop = ${pos};
          })()`);
      await waitForAnimationFrames(tabId, 45);
      stepsDone += 1;

      const passTables = await extractTablesSinglePass(tabId, scopeSelector, frameMeta);
      const primary = passTables.sort((a, b) => (b.rows?.length || 0) - (a.rows?.length || 0))[0];
      if (!primary || !primary.rows || primary.rows.length < 2) continue;

      if (!headers) {
        headers = primary.rows[0].cells.map((c, idx) => (c.text || "").trim() || `Col ${idx + 1}`);
      }
      for (let r = 1; r < primary.rows.length; r++) {
        const row = primary.rows[r];
        const vals = row.cells.map((c) => c.text || "");
        const dedupKey = row.rowKey && row.rowKey.startsWith("aria:")
          ? row.rowKey
          : vals.join("\u001f");
        if (seenRows.has(dedupKey)) continue;
        seenRows.add(dedupKey);
        mergedRows.push(vals);
      }
    }
  } finally {
    await evalInFrame(tabId, frameMeta, info.isWindow
      ? `window.scrollTo({ top: ${info.origTop}, behavior: 'instant' })`
      : `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const el = queryOneDeep(document, '[data-usemac-vscan="1"]');
          if (el) {
            el.scrollTop = ${info.origTop};
            el.removeAttribute('data-usemac-vscan');
          }
        })()`).catch(() => {});
  }

  if (!headers || headers.length < 2 || mergedRows.length === 0) {
    const fallback = await extractTablesSinglePass(tabId, scopeSelector, frameMeta);
    const fmt = formatExtractedTablesToMarkdown(fallback, maxChars);
    return { ...fmt, scannedSteps: stepsDone };
  }

  const colCount = Math.max(headers.length, ...mergedRows.map((r) => r.length));
  const normHeaders = headers.slice();
  while (normHeaders.length < colCount) normHeaders.push(`Col ${normHeaders.length + 1}`);
  const headerLine = "| " + normHeaders.join(" | ") + " |";
  const sepLine = "| " + normHeaders.map(() => "---").join(" | ") + " |";
  const bodyLines = mergedRows.map((vals) => {
    const row = vals.slice();
    while (row.length < colCount) row.push("");
    return "| " + row.join(" | ") + " |";
  });

  const md = [headerLine, sepLine, ...bodyLines].join("\n").slice(0, maxChars);
  return {
    markdown: md,
    rowCount: mergedRows.length,
    columnCount: colCount,
    scannedSteps: stepsDone
  };
}

async function extractNetworkResponses(tabId, { urlFilter = null, maxChars = 16000 } = {}) {
  const session = getOrCreateTabSession(tabId);
  const filterLower = typeof urlFilter === "string" ? urlFilter.trim().toLowerCase() : "";
  const matching = (session.networkRing || [])
    .filter((entry) => entry.documentId == null || entry.documentId === session.documentId)
    .filter((entry) => !filterLower || String(entry.url || "").toLowerCase().includes(filterLower))
    .slice()
    .reverse(); // newest first

  const items = [];
  let approxLen = 2; // "[]"
  for (const entry of matching) {
    if (!entry.bodyLoaded && entry.requestId) {
      try {
        const res = await sendCDP(tabId, "Network.getResponseBody", { requestId: entry.requestId });
        let rawBody = res?.body ?? null;
        if (rawBody != null && res?.base64Encoded) {
          try { rawBody = atob(rawBody); } catch (_) {}
        }
        if (typeof rawBody === "string") {
          try {
            entry.body = JSON.parse(rawBody);
          } catch (_) {
            entry.body = rawBody;
          }
        } else {
          entry.body = rawBody;
        }
      } catch (_) {
        entry.body = null;
      }
      entry.bodyLoaded = true;
    }

    const record = {
      url: entry.url,
      method: entry.method,
      status: entry.status,
      contentType: entry.contentType,
      timestampMs: entry.timestampMs,
      body: entry.body
    };
    let serialized = JSON.stringify(record);
    const budgetRemaining = maxChars - approxLen - 1;
    if (budgetRemaining <= 60) break;
    if (serialized.length > budgetRemaining) {
      // Trim oversized body while preserving structured metadata as valid JSON
      const metaOnly = { ...record, body: null, truncated: true };
      const metaLen = JSON.stringify(metaOnly).length;
      const bodyBudget = Math.max(0, budgetRemaining - metaLen - 32);
      if (bodyBudget > 20 && record.body != null) {
        const rawStr = typeof record.body === "string" ? record.body : JSON.stringify(record.body);
        metaOnly.body = rawStr.slice(0, bodyBudget) + "...";
      }
      serialized = JSON.stringify(metaOnly);
      if (serialized.length > budgetRemaining) break;
      items.push(metaOnly);
      approxLen += serialized.length + 1;
      break;
    }
    items.push(record);
    approxLen += serialized.length + 1;
  }

  return {
    jsonResult: JSON.stringify(items).slice(0, maxChars),
    count: items.length
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
  // Non-blocking debounced preview refresh.
  schedulePreviewFrame(tab.id);
  const tabInfo = await refreshTabMeta(tab.id);

  let tablesMarkdown = null;
  let rowCount = null;
  let columnCount = null;
  let scannedHorizontalSteps = null;
  let text = null;
  let jsonResult = null;
  let downloads = null;

  const needsChildFrames = mode !== "network" && (mode !== "eval" || (req.frameIndex != null && Number(req.frameIndex) > 0));
  const childFrames = needsChildFrames ? await discoverChildFrames(tab.id).catch(() => []) : [];

  if (mode === "network") {
    const netRes = await extractNetworkResponses(tab.id, {
      urlFilter: req.urlFilter || null,
      maxChars
    });
    jsonResult = netRes.jsonResult;
    rowCount = netRes.count;
  } else if (mode === "eval") {
    const expr = String(req.expression || "").trim();
    if (!expr) {
      throw { code: "INVALID_ARGUMENT", message: "extract mode 'eval' requires expression." };
    }
    let targetFrameMeta = null;
    if (req.frameIndex != null && Number(req.frameIndex) > 0) {
      const idx = Math.floor(Number(req.frameIndex)) - 1;
      if (idx < 0 || idx >= childFrames.length) {
        throw {
          code: "INVALID_ARGUMENT",
          message: `frameIndex ${req.frameIndex} is out of range (discovered ${childFrames.length} child frame(s); 0 is top frame).`
        };
      }
      targetFrameMeta = childFrames[idx];
    }
    const evalRes = await evalInFrame(tab.id, targetFrameMeta, expr, {
      returnByValue: true,
      awaitPromise: true
    });
    if (evalRes?.exceptionDetails) {
      const excText = evalRes.exceptionDetails.exception?.description || evalRes.exceptionDetails.text || "JS evaluation failed";
      throw { code: "EVAL_ERROR", message: excText };
    }
    const val = evalRes?.result?.value;
    // Compact JSON without 2-space indent bloat.
    const serialized = typeof val === "string" ? val : JSON.stringify(val ?? null);
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
      if (req.scanVertical) {
        const scanned = await extractTablesWithVerticalScan(tab.id, req.selector || null, remainingChars, fMeta);
        if (scanned.markdown) {
          mdParts.push(scanned.markdown);
          totalRows += scanned.rowCount || 0;
          maxCols = Math.max(maxCols, scanned.columnCount || 0);
        }
        totalSteps = Math.max(totalSteps, scanned.scannedSteps || 1);
      } else if (req.scanHorizontal) {
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
    throw { code: "INVALID_ARGUMENT", message: `Unsupported extract mode: ${mode}. Use auto, tables, text, kpis, eval, network, or downloads.` };
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

// --- Screenshot size --------------------------------------------------------------------------------------------
// A screenshot shows the page at its real size. viewportWidth/viewportHeight on a screenshot request are a box in
// image pixels: a bigger capture is scaled down to fit inside it, keeping its aspect ratio (never scaled up).
// deviceScaleFactor is ignored.

function screenshotBox(req) {
  const width = Number(req?.viewportWidth) > 0 ? Math.round(Number(req.viewportWidth)) : null;
  const height = Number(req?.viewportHeight) > 0 ? Math.round(Number(req.viewportHeight)) : null;
  if (width || height) return { width, height };
  if (req?.fullResolution === true || req?.fullPage === true) return null;
  return { width: DEFAULT_SCREENSHOT_MAX_WIDTH, height: DEFAULT_SCREENSHOT_MAX_HEIGHT };
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

// Width and height from a JPEG's frame header, or null when there is none. The header sits near the start, so only
// the first 48 KB are decoded.
function jpegSize(base64) {
  let bytes;
  try {
    bytes = base64ToBytes(String(base64).slice(0, 65536));
  } catch (_) {
    return null;
  }
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 <= bytes.length) {
    if (bytes[i] !== 0xff) return null;
    const marker = bytes[i + 1];
    // SOF0..SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      const height = (bytes[i + 5] << 8) | bytes[i + 6];
      const width = (bytes[i + 7] << 8) | bytes[i + 8];
      return width > 0 && height > 0 ? { width, height } : null;
    }
    i += 2 + ((bytes[i + 2] << 8) | bytes[i + 3]);
  }
  return null;
}

// The size an image of width x height gets inside `box`: the same when it fits, otherwise scaled down.
function sizeInBox(width, height, box) {
  let w = width;
  let h = height;
  if (box.width && w > box.width) {
    h = (h * box.width) / w;
    w = box.width;
  }
  if (box.height && h > box.height) {
    w = (w * box.height) / h;
    h = box.height;
  }
  return {
    width: clamp(Math.round(w), 1, box.width || Infinity),
    height: clamp(Math.round(h), 1, box.height || Infinity)
  };
}

// Scales a JPEG down to fit inside `box` (createImageBitmap and OffscreenCanvas, which the service worker has).
// Throws when the image can't be decoded.
async function fitJpegInBox(base64, box, quality) {
  const bitmap = await createImageBitmap(new Blob([base64ToBytes(base64)], { type: "image/jpeg" }));
  try {
    const target = sizeInBox(bitmap.width, bitmap.height, box);
    if (target.width === bitmap.width && target.height === bitmap.height) {
      return { data: base64, width: bitmap.width, height: bitmap.height };
    }
    const canvas = new OffscreenCanvas(target.width, target.height);
    const ctx = canvas.getContext("2d");
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(bitmap, 0, 0, target.width, target.height);
    const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: quality / 100 });
    return { data: bytesToBase64(new Uint8Array(await blob.arrayBuffer())), ...target };
  } finally {
    bitmap.close?.();
  }
}

// The image and its size: from the JPEG header, or `estimate` (marked estimated) when the header can't be read.
function jpegShot(data, estimate) {
  const size = jpegSize(data);
  return size ? { data, ...size } : { data, ...estimate, estimated: true };
}

// --- Element and full-page screenshots ----------------------------------------------------------------------------
// Neither one makes Chrome draw more than is on screen: Page.captureScreenshot never gets captureBeyondViewport. An
// element is scrolled into view when it is not fully on screen, then captured with a clip inside the viewport. A full
// page is scrolled through one viewport at a time and the captures are stitched. Both put every scroll position back
// afterwards, also when the capture fails.

// Full-page limits. A page taller than maxHeight (CSS px), or one that needs more than maxTiles captures or more than
// timeBudgetMs, is cut and the response says so (screenshotTruncated). The stitched image stays under maxSide pixels
// per side and maxPixels in total, so a very long page is drawn at a lower pixel density. settleMs is the wait
// between a scroll and its capture. Tests change these.
const FULL_PAGE_LIMITS = {
  maxHeight: 16384,
  maxTiles: 40,
  timeBudgetMs: 12000,
  maxSide: 16384,
  maxPixels: 32 * 1024 * 1024,
  settleMs: 50,
  tileQuality: 95
};

// The top-level page's scroll position, its viewport without scrollbars, the window's inner size and the height
// the window can scroll through (CSS px).
const PAGE_SCROLL_METRICS_JS = `(() => {
  const de = document.documentElement;
  const se = document.scrollingElement || de;
  const vp = document.compatMode === 'BackCompat' && document.body ? document.body : de;
  return {
    x: window.scrollX || 0,
    y: window.scrollY || 0,
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    viewWidth: Math.min(window.innerWidth, (vp && vp.clientWidth) || window.innerWidth),
    viewHeight: Math.min(window.innerHeight, (vp && vp.clientHeight) || window.innerHeight),
    contentHeight: Math.max(se ? se.scrollHeight : 0, window.innerHeight)
  };
})()`;

// Scrolls the window to (x, y) at once (no smooth scrolling) and returns where it ended up.
function scrollPageToJs(x, y) {
  const left = Number(x) || 0;
  const top = Number(y) || 0;
  return `(() => {
    window.scrollTo({ left: ${left}, top: ${top}, behavior: 'instant' });
    return { x: window.scrollX || 0, y: window.scrollY || 0 };
  })()`;
}

const SHOT_SCROLL_KEY_JS = "Symbol.for('usemac.shotScroll')";

// Finds the element, remembers the scroll position of the window and of every ancestor, and scrolls it into view
// only when it is not fully on screen: centered when it fits, its top-left corner first when it is bigger than the
// view. `topBox` is the top-level viewport in this frame's coordinates (null in the top frame). Returns the
// element's size and the part of it inside this frame's viewport and its scrolling ancestors.
function elementShotScrollJs(lookupExpr, topBox) {
  return `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const el = ${lookupExpr};
    if (!el) return null;
    const de = document.documentElement;
    const body = document.body;
    const se = document.scrollingElement || de;
    const parentOf = (n) => n.assignedSlot || n.parentNode || n.host || null;
    const ancestors = [];
    for (let n = parentOf(el); n; n = parentOf(n)) {
      if (n.nodeType === 1) ancestors.push(n);
    }
    globalThis[${SHOT_SCROLL_KEY_JS}] = {
      x: window.scrollX || 0,
      y: window.scrollY || 0,
      els: ancestors.filter((n) => n !== se).map((n) => [n, n.scrollLeft, n.scrollTop])
    };
    const vp = document.compatMode === 'BackCompat' && body ? body : de;
    const rootStyle = getComputedStyle(de);
    const rootVisible = rootStyle.overflowX === 'visible' && rootStyle.overflowY === 'visible';
    const clipBoxes = () => {
      const boxes = [{ left: 0, top: 0, right: vp.clientWidth || window.innerWidth, bottom: vp.clientHeight || window.innerHeight }];
      for (const n of ancestors) {
        if (n === de || n === se || (n === body && rootVisible)) continue;
        const cs = getComputedStyle(n);
        if (cs.overflowX === 'visible' && cs.overflowY === 'visible') continue;
        const r = n.getBoundingClientRect();
        const left = r.left + n.clientLeft;
        const top = r.top + n.clientTop;
        boxes.push({ left, top, right: left + n.clientWidth, bottom: top + n.clientHeight });
      }
      return boxes;
    };
    const rectOf = () => {
      const r = el.getBoundingClientRect();
      const width = Math.max(4, r.width);
      const height = Math.max(4, r.height);
      return { left: r.left, top: r.top, right: r.left + width, bottom: r.top + height, width, height };
    };
    const inside = (r, b) => r.left >= b.left - 0.5 && r.top >= b.top - 0.5 && r.right <= b.right + 0.5 && r.bottom <= b.bottom + 0.5;
    const topBox = ${JSON.stringify(topBox || null)};
    let rect = rectOf();
    let boxes = clipBoxes();
    const fitBoxes = topBox ? boxes.concat([topBox]) : boxes;
    let scrolled = false;
    if (!fitBoxes.every((b) => inside(rect, b))) {
      const viewW = Math.min(...fitBoxes.map((b) => b.right - b.left));
      const viewH = Math.min(...fitBoxes.map((b) => b.bottom - b.top));
      el.scrollIntoView({
        block: rect.height > viewH + 0.5 ? 'start' : 'center',
        inline: rect.width > viewW + 0.5 ? 'start' : 'center',
        behavior: 'instant'
      });
      scrolled = true;
      rect = rectOf();
      boxes = clipBoxes();
    }
    const vis = { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
    for (const b of boxes) {
      vis.left = Math.max(vis.left, b.left);
      vis.top = Math.max(vis.top, b.top);
      vis.right = Math.min(vis.right, b.right);
      vis.bottom = Math.min(vis.bottom, b.bottom);
    }
    return { scrolled, width: rect.width, height: rect.height, visible: vis };
  })()`;
}

// Puts back the scroll positions elementShotScrollJs remembered in this frame.
const RESTORE_SHOT_SCROLL_JS = `(() => {
  const key = ${SHOT_SCROLL_KEY_JS};
  const saved = globalThis[key];
  if (!saved) return false;
  delete globalThis[key];
  for (const [n, left, top] of saved.els) {
    if (n.scrollLeft !== left || n.scrollTop !== top) {
      try { n.scrollTo({ left, top, behavior: 'instant' }); } catch (_) {}
    }
  }
  if ((window.scrollX || 0) !== saved.x || (window.scrollY || 0) !== saved.y) {
    window.scrollTo({ left: saved.x, top: saved.y, behavior: 'instant' });
  }
  return true;
})()`;

// The value of a page script, or a throw when it failed.
async function pageScriptValue(tabId, frameMeta, expression) {
  const res = await evalInFrame(tabId, frameMeta, expression);
  if (res?.exceptionDetails) {
    throw new Error(res.exceptionDetails.exception?.description || res.exceptionDetails.text || "Page script failed");
  }
  return res?.result?.value;
}

async function pageScrollMetrics(tabId) {
  const page = await pageScriptValue(tabId, null, PAGE_SCROLL_METRICS_JS);
  if (!page || !(page.viewWidth > 0) || !(page.viewHeight > 0) || !(page.innerWidth > 0) || !(page.innerHeight > 0)) {
    throw { code: "CAPTURE_FAILED", message: "Couldn't measure the page for the screenshot." };
  }
  return page;
}

// Screenshot of an element (selector or @bID). The element is scrolled into view only when it is not fully on
// screen, captured with a clip inside the viewport, and every scroll position is put back afterwards. An element
// bigger than the view (or still partly hidden) comes back as the part on screen, from its top-left corner, with
// truncated: true.
async function captureElementScreenshot(tabId, session, req, quality, pixelRatio) {
  const lookupExpr = findElementExprJs({ elementId: req.elementId || null, selector: req.elementId ? null : req.selector });
  const candidateFrames = [];
  const mapped = req.elementId ? session.elementFrameMap.get(req.elementId) : null;
  if (mapped) candidateFrames.push(mapped);
  if (!mapped || mapped.frameId != null) candidateFrames.push(null);
  const childFrames = session.lastChildFrames?.length
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const f of childFrames) {
    if (f !== mapped) candidateFrames.push(f);
  }

  const before = await pageScriptValue(tabId, null, PAGE_SCROLL_METRICS_JS).catch(() => null);
  let found = null;
  try {
    for (const fMeta of candidateFrames) {
      const child = Boolean(fMeta && fMeta.frameId != null);
      let offset = { x: 0, y: 0 };
      if (child) {
        const fRect = await computeFrameViewportRect(tabId, fMeta, false);
        if (!fRect || !fRect.visible) continue;
        offset = fRect;
      }
      const topBox = child && before
        ? { left: -offset.x, top: -offset.y, right: before.viewWidth - offset.x, bottom: before.viewHeight - offset.y }
        : null;
      const info = await pageScriptValue(tabId, fMeta, elementShotScrollJs(lookupExpr, topBox)).catch(() => null);
      if (!info) continue;
      found = { fMeta, child, info, offset };
      if (child && info.scrolled) {
        // Scrolling inside the frame can move the frame itself; measure it again.
        const fRect = await computeFrameViewportRect(tabId, fMeta, true);
        if (fRect?.visible) found.offset = fRect;
      }
      break;
    }
    if (!found) {
      throw { code: "ELEMENT_NOT_FOUND", message: `Screenshot target ${req.elementId || req.selector} not found.` };
    }

    const page = await pageScrollMetrics(tabId);
    const { info, offset } = found;
    const left = Math.max(0, info.visible.left + offset.x);
    const top = Math.max(0, info.visible.top + offset.y);
    const right = Math.min(page.viewWidth, info.visible.right + offset.x);
    const bottom = Math.min(page.viewHeight, info.visible.bottom + offset.y);
    if (right - left < 1 || bottom - top < 1) {
      throw {
        code: "ELEMENT_NOT_FOUND",
        message: `Screenshot target ${req.elementId || req.selector} is not on screen, even after scrolling to it.`
      };
    }
    // Clip coordinates are page coordinates: the viewport rect plus the scroll position.
    const clip = { x: page.x + left, y: page.y + top, width: right - left, height: bottom - top, scale: 1 };
    const cap = await withTabIndicatorHidden(tabId, () => sendCDP(tabId, "Page.captureScreenshot", {
      format: "jpeg",
      quality,
      fromSurface: true,
      clip
    }));
    if (!cap?.data) {
      throw { code: "CAPTURE_FAILED", message: "CDP Page.captureScreenshot returned empty data." };
    }
    const shot = jpegShot(cap.data, {
      width: Math.round(clip.width * pixelRatio),
      height: Math.round(clip.height * pixelRatio)
    });
    shot.truncated = clip.width < info.width - 1 || clip.height < info.height - 1;
    return shot;
  } finally {
    if (found) {
      await pageScriptValue(tabId, found.fMeta, RESTORE_SHOT_SCROLL_JS).catch(() => {});
      if (found.child && before) {
        await pageScriptValue(tabId, null, scrollPageToJs(before.x, before.y)).catch(() => {});
      }
    }
  }
}

// The stitched image's size for a page of width x height device pixels: inside the agent's box when there is one,
// and always inside FULL_PAGE_LIMITS.maxSide per side and maxPixels in total.
function stitchedImageSize(width, height, fitBox) {
  let size = fitBox ? sizeInBox(width, height, fitBox) : { width: Math.max(1, Math.round(width)), height: Math.max(1, Math.round(height)) };
  size = sizeInBox(size.width, size.height, { width: FULL_PAGE_LIMITS.maxSide, height: FULL_PAGE_LIMITS.maxSide });
  const pixels = size.width * size.height;
  if (pixels > FULL_PAGE_LIMITS.maxPixels) {
    const k = Math.sqrt(FULL_PAGE_LIMITS.maxPixels / pixels);
    size = { width: Math.max(1, Math.floor(size.width * k)), height: Math.max(1, Math.floor(size.height * k)) };
  }
  return size;
}

// Full-page screenshot: scrolls the window down one viewport at a time from the top, captures each viewport as it
// is on screen and draws the captures one under the other, at the tab's width. Fixed and sticky elements show in
// every capture. A page that fits in one viewport, or that scrolls inside an element instead of the window, is one
// plain capture. The scroll position is put back afterwards, also when a capture fails.
async function captureFullPageScreenshot(tabId, quality, fitBox, pixelRatio) {
  const page = await pageScrollMetrics(tabId);
  const viewW = page.viewWidth;
  const viewH = page.viewHeight;
  const pageH = page.contentHeight;
  if (pageH <= viewH + 1) {
    const cap = await withTabIndicatorHidden(tabId, () => sendCDP(tabId, "Page.captureScreenshot", {
      format: "jpeg",
      quality,
      fromSurface: true
    }));
    if (!cap?.data) {
      throw { code: "CAPTURE_FAILED", message: "CDP Page.captureScreenshot returned empty data." };
    }
    const shot = jpegShot(cap.data, { width: Math.round(page.innerWidth * pixelRatio), height: Math.round(page.innerHeight * pixelRatio) });
    shot.truncated = false;
    return shot;
  }

  const wanted = Math.min(pageH, FULL_PAGE_LIMITS.maxHeight);
  let truncated = pageH > wanted;
  const startedAt = performance.now();
  let canvas = null;
  let ctx = null;
  let scaleX = 1;
  let scaleY = 1;
  let covered = 0;
  let tiles = 0;
  try {
    await withTabIndicatorHidden(tabId, async () => {
      while (covered < wanted - 0.5) {
        if (tiles >= FULL_PAGE_LIMITS.maxTiles || (tiles > 0 && performance.now() - startedAt > FULL_PAGE_LIMITS.timeBudgetMs)) {
          truncated = true;
          break;
        }
        const at = await pageScriptValue(tabId, null, scrollPageToJs(0, covered));
        const scrollTop = Number(at?.y) || 0;
        if (FULL_PAGE_LIMITS.settleMs > 0) await sleep(FULL_PAGE_LIMITS.settleMs);
        const cap = await sendCDP(tabId, "Page.captureScreenshot", {
          format: "jpeg",
          quality: FULL_PAGE_LIMITS.tileQuality,
          fromSurface: true
        });
        if (!cap?.data) {
          throw { code: "CAPTURE_FAILED", message: "CDP Page.captureScreenshot returned empty data." };
        }
        tiles++;
        const bitmap = await createImageBitmap(new Blob([base64ToBytes(cap.data)], { type: "image/jpeg" }));
        try {
          // Device pixels per CSS px in this capture (the page's pixel ratio, zoom included).
          const ratioX = bitmap.width / page.innerWidth;
          const ratioY = bitmap.height / page.innerHeight;
          if (!canvas) {
            const size = stitchedImageSize(viewW * ratioX, wanted * ratioY, fitBox);
            canvas = new OffscreenCanvas(size.width, size.height);
            ctx = canvas.getContext("2d");
            ctx.imageSmoothingQuality = "high";
            // White, not transparent (black in a JPEG), where a capture leaves a gap.
            ctx.fillStyle = "#ffffff";
            ctx.fillRect(0, 0, size.width, size.height);
            scaleX = size.width / viewW;
            scaleY = size.height / wanted;
          }
          // This capture shows page rows scrollTop .. scrollTop + viewH; draw the ones not drawn yet. (A page that
          // snaps its scroll can land past `covered`; those rows stay white.)
          const from = Math.max(covered, scrollTop);
          const to = Math.min(scrollTop + viewH, wanted);
          if (to <= covered + 0.5) break; // the page did not scroll any further: it ends here
          const destTop = Math.round(from * scaleY);
          const destBottom = Math.round(to * scaleY);
          ctx.drawImage(
            bitmap,
            0, (from - scrollTop) * ratioY, viewW * ratioX, (to - from) * ratioY,
            0, destTop, Math.round(viewW * scaleX), destBottom - destTop
          );
          covered = to;
        } finally {
          bitmap.close?.();
        }
      }
    });
  } finally {
    await pageScriptValue(tabId, null, scrollPageToJs(page.x, page.y)).catch(() => {});
  }
  if (!canvas || covered < 1) {
    throw { code: "CAPTURE_FAILED", message: "The full-page screenshot captured nothing." };
  }
  const height = Math.round(covered * scaleY);
  if (height < canvas.height) {
    // The page ended before it was expected to (it got shorter while it was scrolled): drop the empty rows.
    const cropped = new OffscreenCanvas(canvas.width, Math.max(1, height));
    cropped.getContext("2d").drawImage(canvas, 0, 0);
    canvas = cropped;
  }
  const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: quality / 100 });
  return {
    data: bytesToBase64(new Uint8Array(await blob.arrayBuffer())),
    width: canvas.width,
    height: canvas.height,
    truncated
  };
}

async function handleScreenshotCommand(req, preResolvedTab = null) {
  const start = performance.now();
  const tab = preResolvedTab || await resolveTargetTab(req.tabId);
  await assertTabScriptable(tab.id);
  if (req.tabId != null) {
    await ensureTabInUsemacGroup(tab.id);
  }
  await ensureAttached(tab.id);
  resetIdleTimer(tab.id);
  schedulePreviewFrame(tab.id);

  const session = getOrCreateTabSession(tab.id);
  await refreshLiveViewport(tab.id, session);
  const quality = clamp(Number(req.quality) || 84, 30, 100);
  const fitBox = screenshotBox(req);
  // The page's pixel ratio, to estimate the image size when the JPEG header can't be read.
  const viewport = effectiveViewport(session);
  const pixelRatio = viewport.scale || 1;

  let shot;
  if (req.elementId || req.selector) {
    shot = await captureElementScreenshot(tab.id, session, req, quality, pixelRatio);
  } else if (req.fullPage === true) {
    shot = await captureFullPageScreenshot(tab.id, quality, fitBox, pixelRatio);
  } else {
    const captureParams = {
      format: "jpeg",
      quality,
      fromSurface: true
    };
    const r = req.region;
    if (r && Number.isFinite(Number(r.width)) && Number.isFinite(Number(r.height)) && Number(r.width) >= 1 && Number(r.height) >= 1) {
      captureParams.clip = {
        x: Math.max(0, Number(r.x) || 0),
        y: Math.max(0, Number(r.y) || 0),
        width: Number(r.width),
        height: Number(r.height),
        scale: 1
      };
    }
    const cap = await withTabIndicatorHidden(tab.id, () => sendCDP(tab.id, "Page.captureScreenshot", captureParams));
    if (!cap?.data) {
      throw { code: "CAPTURE_FAILED", message: "CDP Page.captureScreenshot returned empty data." };
    }
    const estW = captureParams.clip ? captureParams.clip.width : viewport.width;
    const estH = captureParams.clip ? captureParams.clip.height : viewport.height;
    shot = jpegShot(cap.data, {
      width: Math.round(estW * pixelRatio),
      height: Math.round(estH * pixelRatio)
    });
  }

  if (fitBox) {
    const fitted = sizeInBox(shot.width, shot.height, fitBox);
    if (shot.estimated || fitted.width !== shot.width || fitted.height !== shot.height) {
      // If the image can't be decoded here, the capture is returned as it is, with its own size.
      const scaled = await fitJpegInBox(shot.data, fitBox, quality).catch(() => null);
      if (scaled) shot = { ...scaled, truncated: shot.truncated };
    }
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
    screenshotBase64: shot.data,
    screenshotWidth: shot.width,
    screenshotHeight: shot.height,
    screenshotLatencyMs: latencyMs,
    // The image doesn't show all of the element or page: see captureElementScreenshot and captureFullPageScreenshot.
    screenshotTruncated: shot.truncated === true,
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
  // closeTabIds: the finished task's own tabs. Only those close, so a tab another agent's task opened stays open.
  const only = Array.isArray(req.closeTabIds) ? new Set(req.closeTabIds.map(Number)) : null;
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
    if (only && !only.has(tabId)) continue;
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

function collectBatchNetworkErrors(session, sinceMs) {
  if (!session || !Array.isArray(session.networkErrors) || session.networkErrors.length === 0) {
    return null;
  }
  const out = [];
  const seen = new Set();
  for (const err of session.networkErrors) {
    if (err.timestampMs < sinceMs) continue;
    const statusPart = err.status > 0
      ? `${err.status}${err.statusText ? " " + err.statusText : ""}`
      : (err.statusText || "failed");
    const line = `${err.method || "GET"} ${err.url || "(unknown)"} -> ${statusPart}`;
    if (!seen.has(line)) {
      seen.add(line);
      out.push(line);
    }
    if (out.length >= 15) break;
  }
  return out.length > 0 ? out : null;
}

async function runActionStepsPipeline(tabId, steps, { stopOnError = true, cancelToken = null } = {}) {
  const stepResults = [];
  let allSucceeded = true;
  let cancelled = false;

  for (let i = 0; i < steps.length; i++) {
    if (isCancelled(tabId, cancelToken)) {
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
    resetIdleTimer(tabId);

    try {
      if (stepNeedsDebugger(step)) {
        const blocked = await restrictedPageErrorIfDetached(tabId);
        if (blocked) throw blocked;
      }
      const outcome = await executeActionStep(tabId, step, cancelToken);
      const entry = {
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
      };
      if (outcome.resolvedElementId) {
        entry.resolvedElementId = outcome.resolvedElementId;
      }
      stepResults.push(entry);
    } catch (err) {
      if (err?.code === "URL_BLOCKED") {
        throw err;
      }
      if (err?.code === "CANCELLED" || isCancelled(tabId, cancelToken)) {
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
      // A step that navigated onto a restricted page makes Chrome detach the debugger; say so instead of
      // reporting "Debugger is not attached" for the next step.
      let mapped = await toRestrictedPageErrorIfNeeded(err, tabId);
      if (mapped?.code !== "RESTRICTED_PAGE" && stepNeedsDebugger(step)) {
        mapped = (await restrictedPageErrorIfDetached(tabId)) || mapped;
      }
      const restricted = mapped?.code === "RESTRICTED_PAGE";

      // Resilient optional step: skip cleanly and continue unless blocked by security/restriction.
      if (step?.optional === true && !restricted) {
        stepResults.push({
          index: i,
          action: step.action,
          success: true,
          skipped: true,
          mechanism: "optional-skipped",
          latencyMs: Math.round((performance.now() - stepStart) * 100) / 100,
          message: err?.message || String(err)
        });
        continue;
      }

      allSucceeded = false;
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

  return { stepResults, allSucceeded, cancelled };
}

async function handleOpenCommand(req, cancelToken = null) {
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

  // Enforce URL rule on any inline navigation steps before opening the tab.
  const openSteps = Array.isArray(req.steps) ? req.steps : [];
  for (const st of openSteps) {
    if (st && (st.action === "openURL" || st.action === "navigate")) {
      assertAllowedUrl(st.url || st.text);
    }
  }

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
  const restrictedResponse = (tabNow, reason, actionResult = null) => ({
    type: "response",
    id: req.id,
    ok: true,
    tabId: tab.id,
    windowId: tabNow.windowId ?? tab.windowId ?? null,
    profileName: state.profileName,
    url: tabNow.url || targetUrl,
    title: tabNow.title || "",
    restricted: true,
    snapshot: actionResult ? null : restrictedPageSnapshot(tabNow, reason),
    actionResult,
    error: null
  });
  const restriction = await tabRestrictionReason(current);
  if (restriction) {
    return restrictedResponse(current, restriction);
  }

  let tabInfo;
  let snapshot;
  let overlayHighConfidence = false;
  let actionResult = null;
  let screenshotBase64 = null;
  let screenshotWidth = null;
  let screenshotHeight = null;
  const openObserveOpts = {
    includeText: req.includeText !== false,
    includeTables: req.includeTables !== false,
    includeOffscreen: req.includeOffscreen === true,
    filter: req.filter || null,
    returnDiffOnly: req.returnDiffOnly === true,
    observationMode: req.observationMode || null,
    includeScreenshot: req.includeScreenshot === true || req.returnImageContent === true,
    fullResolution: req.fullResolution === true,
    viewportWidth: req.viewportWidth,
    viewportHeight: req.viewportHeight
  };

  try {
    if (req.stream !== false) {
      await ensureStreaming(tab.id);
    } else {
      await ensureAttached(tab.id);
      resetIdleTimer(tab.id);
    }

    const initial = await observeTab(
      tab.id,
      req.maxElements || 280,
      openSteps.length > 0
        ? { includeText: false, includeTables: false, includeOffscreen: req.includeOffscreen === true, observationMode: "interactive" }
        : openObserveOpts
    );
    tabInfo = initial.tab;
    snapshot = initial.snapshot;
    overlayHighConfidence = initial.overlayHighConfidence;
    screenshotBase64 = initial.screenshotBase64;
    screenshotWidth = initial.screenshotWidth;
    screenshotHeight = initial.screenshotHeight;

    // Auto-dismiss high-confidence cookie/consent overlay if requested.
    if (req.autoDismissOverlays === true && overlayHighConfidence) {
      const ov = snapshot?.pageState?.blockingOverlay;
      if (ov && (ov.closeElementId || (Number.isFinite(ov.closeX) && Number.isFinite(ov.closeY)))) {
        try {
          await executeActionStep(tab.id, {
            action: "click",
            elementId: ov.closeElementId || undefined,
            x: ov.closeElementId ? undefined : ov.closeX,
            y: ov.closeElementId ? undefined : ov.closeY
          }, cancelToken);
          await waitForAnimationFrames(tab.id, 40);
          if (openSteps.length === 0) {
            const refreshed = await observeTab(tab.id, req.maxElements || 280, openObserveOpts);
            tabInfo = refreshed.tab || tabInfo;
            snapshot = refreshed.snapshot;
            screenshotBase64 = refreshed.screenshotBase64;
            screenshotWidth = refreshed.screenshotWidth;
            screenshotHeight = refreshed.screenshotHeight;
          }
        } catch (_) {}
      }
    }

    // Inline steps execution right inside browser_open!
    if (openSteps.length > 0) {
      const batchStart = performance.now();
      const batchStartWallMs = Date.now();
      const session = getOrCreateTabSession(tab.id);
      const { stepResults, allSucceeded, cancelled } = await runActionStepsPipeline(tab.id, openSteps, {
        stopOnError: req.stopOnError !== false,
        cancelToken
      });

      if (cancelled || isCancelled(tab.id, cancelToken)) {
        const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;
        return {
          type: "response",
          id: req.id,
          ok: false,
          tabId: tab.id,
          windowId: tabInfo?.windowId ?? current.windowId ?? null,
          profileName: state.profileName,
          url: session.url || targetUrl,
          title: session.title || "",
          snapshot: null,
          actionResult: {
            success: false,
            totalLatencyMs,
            stepResults,
            observation: null
          },
          error: { code: "CANCELLED", message: CANCELLED_MESSAGE }
        };
      }

      const finalTab = await getTabOrNull(tab.id);
      const finalRestriction = finalTab ? await tabRestrictionReason(finalTab) : null;
      if (finalRestriction) {
        const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;
        return restrictedResponse(finalTab, finalRestriction, {
          success: allSucceeded,
          totalLatencyMs,
          stepResults,
          observation: null,
          agentFeedback: restrictedPageFeedback(finalTab, finalRestriction)
        });
      }

      const finalObs = await observeTab(tab.id, req.maxElements || 280, {
        ...openObserveOpts,
        observationMode: req.observationMode || (req.returnDiffOnly === true ? "delta" : "full")
      });
      tabInfo = finalObs.tab || tabInfo;
      snapshot = finalObs.snapshot;
      screenshotBase64 = finalObs.screenshotBase64;
      screenshotWidth = finalObs.screenshotWidth;
      screenshotHeight = finalObs.screenshotHeight;
      if (!screenshotBase64) {
        schedulePreviewFrame(tab.id);
      }

      const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;
      const networkErrors = collectBatchNetworkErrors(session, batchStartWallMs);
      actionResult = {
        success: allSucceeded,
        totalLatencyMs,
        stepResults,
        observation: snapshot
      };
      if (networkErrors) actionResult.networkErrors = networkErrors;
    }
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
    title: tabInfo?.title || snapshot?.app?.windowTitle || "",
    screenshotBase64: screenshotBase64 || null,
    screenshotWidth: screenshotWidth ?? null,
    screenshotHeight: screenshotHeight ?? null,
    snapshot,
    actionResult,
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
  const { tab: tabInfo, snapshot, screenshotBase64, screenshotWidth, screenshotHeight } = await observeTab(tab.id, req.maxElements || 280, {
    includeText: req.includeText !== false,
    includeTables: req.includeTables !== false,
    includeOffscreen: req.includeOffscreen === true,
    filter: req.filter || null,
    returnDiffOnly: req.returnDiffOnly === true,
    observationMode: req.observationMode || null,
    includeScreenshot: req.includeScreenshot === true || req.returnImageContent === true,
    fullResolution: req.fullResolution === true,
    viewportWidth: req.viewportWidth,
    viewportHeight: req.viewportHeight
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
    screenshotWidth: screenshotWidth ?? null,
    screenshotHeight: screenshotHeight ?? null,
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
  const wantScreenshot = req.includeScreenshot === true || req.returnImageContent === true;

  const batchStart = performance.now();
  const batchStartWallMs = Date.now();
  const { stepResults, allSucceeded, cancelled } = await runActionStepsPipeline(tab.id, steps, {
    stopOnError,
    cancelToken
  });

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

  resetIdleTimer(tab.id);

  let observation = null;
  let tabInfo = await refreshTabMeta(tab.id);
  let screenshotBase64 = null;
  let screenshotWidth = null;
  let screenshotHeight = null;
  let screenshotLatencyMs = null;

  // Determine observationMode: "auto" is the default on browser_act when returnObservation is true.
  const effectiveActObsMode = !returnObservation
    ? "none"
    : (req.observationMode || (req.returnDiffOnly === true ? "delta" : "auto"));

  if (effectiveActObsMode !== "none") {
    const observed = await observeTab(tab.id, req.maxElements || 280, {
      observationMode: effectiveActObsMode,
      returnDiffOnly: req.returnDiffOnly === true,
      includeText: req.includeText !== false,
      includeTables: req.includeTables !== false,
      includeOffscreen: req.includeOffscreen === true,
      filter: req.filter || null,
      includeScreenshot: wantScreenshot,
      fullResolution: req.fullResolution === true,
      viewportWidth: req.viewportWidth,
      viewportHeight: req.viewportHeight
    });
    observation = observed.snapshot;
    tabInfo = observed.tab || tabInfo;
    if (observed.screenshotBase64) {
      screenshotBase64 = observed.screenshotBase64;
      screenshotWidth = observed.screenshotWidth;
      screenshotHeight = observed.screenshotHeight;
    } else {
      schedulePreviewFrame(tab.id);
    }
  } else if (wantScreenshot) {
    const shotStart = performance.now();
    try {
      const cap = await withTabIndicatorHidden(tab.id, () => sendCDP(tab.id, "Page.captureScreenshot", {
        format: "jpeg",
        quality: 82,
        fromSurface: true
      }));
      if (cap?.data) {
        const viewport = effectiveViewport(session);
        const pixelRatio = viewport.scale || 1;
        let shot = jpegShot(cap.data, {
          width: Math.round(viewport.width * pixelRatio),
          height: Math.round(viewport.height * pixelRatio)
        });
        const fitBox = screenshotBox(req);
        if (fitBox) {
          const fitted = sizeInBox(shot.width, shot.height, fitBox);
          if (shot.estimated || fitted.width !== shot.width || fitted.height !== shot.height) {
            const scaled = await fitJpegInBox(shot.data, fitBox, 82).catch(() => null);
            if (scaled) shot = scaled;
          }
        }
        screenshotBase64 = shot.data;
        screenshotWidth = shot.width;
        screenshotHeight = shot.height;
        screenshotLatencyMs = Math.round((performance.now() - shotStart) * 100) / 100;
        emitPreviewFrameData(tab.id, shot.data, false);
      }
    } catch (_) {}
  } else {
    schedulePreviewFrame(tab.id);
  }

  const totalLatencyMs = Math.round((performance.now() - batchStart) * 100) / 100;
  const networkErrors = collectBatchNetworkErrors(session, batchStartWallMs);
  const actionResult = {
    success: allSucceeded,
    totalLatencyMs,
    stepResults,
    observation
  };
  if (networkErrors) {
    actionResult.networkErrors = networkErrors;
  }

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
    actionResult,
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
  if (req.command === "reload_extension") {
    handleDaemonRequest(req);
    return;
  }
  if (req.command === "tabs" || req.command === "close_owned_tabs" || (req.command === "extract" && String(req.mode || "").toLowerCase() === "downloads")) {
    handleDaemonRequest(req);
    return;
  }

  const reqGlobalGen = state.cancelGeneration;

  if (req.command === "open") {
    const reqTabGen = req.tabId != null ? getTabCancelGen(req.tabId) : null;
    const cancelToken = createCancelToken(req.tabId ?? null, reqGlobalGen, reqTabGen, req.id);
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

// Answers first, then reloads, so the daemon gets the answer before the socket closes. Chrome restarts the service
// worker with the code now in the extension's folder, which reconnects and pairs again on its own (the key is in
// chrome.storage.local). Debugger sessions end, and the list of tabs UseMac opened (chrome.storage.session) is lost.
function handleReloadExtensionCommand(req) {
  const startedAt = Date.now();
  const reloadWhenSent = () => {
    const pending = state.ws && state.ws.readyState === WebSocket.OPEN ? state.ws.bufferedAmount : 0;
    if (pending > 0 && Date.now() - startedAt < 1000) {
      setTimeout(reloadWhenSent, 50);
      return;
    }
    try {
      chrome.runtime.reload();
    } catch (_) {}
  };
  setTimeout(reloadWhenSent, 150);
  return {
    type: "response",
    id: req.id,
    ok: true,
    tabId: null,
    profileName: state.profileName,
    extensionVersion: EXTENSION_VERSION,
    url: null,
    title: null,
    snapshot: null,
    actionResult: null,
    error: null
  };
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
        response = await handleOpenCommand(req, cancelToken);
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
      case "reload_extension":
        response = handleReloadExtensionCommand(req);
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
          endpoint: BRIDGE_ENDPOINT,
          extensionStatus: state.authState === "ready" ? state.appExtensionStatus || null : null
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
