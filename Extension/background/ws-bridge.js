// Profile identity, pairing, and the daemon WebSocket connection.

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

let extensionInstanceIdPromise = null;

function getOrCreateExtensionInstanceId() {
  if (!extensionInstanceIdPromise) {
    extensionInstanceIdPromise = (async () => {
      const stored = await chrome.storage.local.get(["usemacExtensionInstanceId"]);
      const existing = stored?.usemacExtensionInstanceId;
      if (typeof existing === "string" && /^[0-9a-f]{32}$/.test(existing)) return existing;
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      const id = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
      await chrome.storage.local.set({ usemacExtensionInstanceId: id });
      return id;
    })().catch(() => {
      // Don't advertise a transient identity if storage is unavailable. Retry on the next hello.
      extensionInstanceIdPromise = null;
      return undefined;
    });
  }
  return extensionInstanceIdPromise;
}

async function sendHello(socket = state.ws) {
  await resolveProfileInfo();
  const keyBytes = await loadPairingKey(true);
  const extensionInstanceId = await getOrCreateExtensionInstanceId();
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
    extensionInstanceId,
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

function cancelDisconnectedSessionWork() {
  handleCancel(null, null).catch(() => {});
  clearAllTabIndicatorUserPauses(true);
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
  cancelDisconnectedSessionWork();
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

  // The keepalive can replace a closing socket before its onclose callback runs.
  if (state.ws && (force || state.ws.readyState === WebSocket.CLOSING || state.ws.readyState === WebSocket.CLOSED)) {
    cancelDisconnectedSessionWork();
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
        if (Array.isArray(msg.ownedTabIds) && msg.ownedTabIds.length > 0) {
          syncOwnedTabIdsFromDaemon(msg.ownedTabIds);
        }
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

    if (msg.type === "sync_owned_tabs") {
      syncOwnedTabIdsFromDaemon(msg.tabIds);
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
    cancelDisconnectedSessionWork();
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
