// Chrome MV3 classic service worker. These scripts share one global scope.
// Keep imports synchronous so Chrome can register event listeners at startup.

importScripts("bridge-auth.js");
importScripts("tab-indicator.js");

// Shared state and event sources.
importScripts("background/state-and-queues.js");
importScripts("background/downloads.js");
importScripts("background/ws-bridge.js");
importScripts("background/streaming-and-viewport.js");

// Tab selection and page interactions.
importScripts("background/tabs-and-restrictions.js");
importScripts("background/dom-frames.js");
importScripts("background/dom-observe.js");
importScripts("background/dom-targets-and-resilient.js");
importScripts("background/dom-actions.js");
importScripts("background/dom-extract-and-screenshots.js");

// Command entry points can use all of the helpers above.
importScripts("background/commands-and-rpc.js");

// Register lifecycle handlers before starting the bridge on this wake.

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
