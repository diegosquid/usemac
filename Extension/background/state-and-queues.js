// Shared worker state, tab sessions, command queues, and cancellation.

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
const DOWNLOAD_CACHE_MAX = 40;
const DOWNLOAD_HISTORY_MS = 24 * 60 * 60 * 1000;
const PAGE_DOWNLOAD_MAX = 30;
const PAGE_DOWNLOAD_TTL_MS = 15000;
const PAGE_DOWNLOAD_MATCH_MS = 2000;
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
  downloads: new Map(), // id -> download meta
  downloadTabById: new Map(),
  refreshingDownloads: new Map(),
  downloadSearchesInFlight: 0,
  erasedDownloads: new Set(), // tombstones only while a search can still return the erased item
  downloadCreationSequence: 0,
  pendingPageDownloads: [],
  activeDownloadClicks: new Set(),
  openQueue: Promise.resolve()
};

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
      dialogPolicy: null,
      batchDialogs: null,
      lastDialog: null,
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
