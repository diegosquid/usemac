const versionText = document.getElementById("versionText");
const statusBadge = document.getElementById("statusBadge");
const statusText = document.getElementById("statusText");
const profileInput = document.getElementById("profileInput");
const saveIndicator = document.getElementById("saveIndicator");
const pairingCollapsed = document.getElementById("pairingCollapsed");
const pairingExpanded = document.getElementById("pairingExpanded");
const pairingKeyInput = document.getElementById("pairingKeyInput");
const pairBtn = document.getElementById("pairBtn");
const changeKeyBtn = document.getElementById("changeKeyBtn");
const pairingError = document.getElementById("pairingError");
const tabsList = document.getElementById("tabsList");
const tabsEmpty = document.getElementById("tabsEmpty");
const stopAllBtn = document.getElementById("stopAllBtn");
const endpointMeta = document.getElementById("endpointMeta");
const reconnectBtn = document.getElementById("reconnectBtn");

const FORMAT_ERROR_TEXT = "That doesn't look like a usemac pairing key.";
const MISMATCH_ERROR_TEXT = "This key doesn't match the usemac app running on this Mac. Copy the key again.";

let saveTimer = null;
let lastSavedValue = "";
let editingKey = false;
let formatErrorActive = false;
let lastTabsSignature = "";
let lastState = null;

function initVersion() {
  try {
    const version = chrome.runtime.getManifest()?.version || "";
    versionText.textContent = version ? `v${version}` : "";
  } catch (_) {
    versionText.textContent = "";
  }
}

function extractHost(url) {
  if (!url) return "";
  try {
    const parsed = new URL(url);
    return parsed.host || url;
  } catch (_) {
    return url;
  }
}

function setStatusBadge(variantClass, text) {
  statusBadge.classList.remove(
    "status-connected",
    "status-waiting",
    "status-error",
    "status-disconnected"
  );
  statusBadge.classList.add(variantClass);
  statusText.textContent = text;
}

function renderStatus(state) {
  const wsState = state?.wsState || "disconnected";
  const authState = state?.authState || "unpaired";
  const hasKey = Boolean(state?.hasKey);
  const tabs = Array.isArray(state?.tabs) ? state.tabs : [];

  if (authState === "ready" && tabs.length > 0) {
    const label = tabs.length === 1 ? "Controlling 1 tab" : `Controlling ${tabs.length} tabs`;
    setStatusBadge("status-connected", label);
  } else if (authState === "ready") {
    setStatusBadge("status-connected", "Connected");
  } else if (authState === "unpaired") {
    setStatusBadge("status-waiting", "Pairing required");
  } else if (authState === "key_mismatch") {
    setStatusBadge("status-error", "Key doesn't match");
  } else if (wsState === "connecting" || (wsState === "connected" && authState === "authenticating")) {
    setStatusBadge("status-waiting", "Connecting…");
  } else {
    setStatusBadge("status-disconnected", "usemac app not running");
  }

  const showExpandedPairing =
    authState === "unpaired" || authState === "key_mismatch" || !hasKey || editingKey;
  pairingCollapsed.hidden = showExpandedPairing;
  pairingExpanded.hidden = !showExpandedPairing;

  if (formatErrorActive) {
    pairingError.textContent = FORMAT_ERROR_TEXT;
    pairingError.hidden = false;
  } else if (authState === "key_mismatch") {
    pairingError.textContent = MISMATCH_ERROR_TEXT;
    pairingError.hidden = false;
  } else {
    pairingError.textContent = "";
    pairingError.hidden = true;
  }

  renderTabs(tabs);

  endpointMeta.textContent = state?.endpoint || "127.0.0.1:49222";
  reconnectBtn.hidden = authState === "ready";
}

function renderTabs(tabs) {
  stopAllBtn.disabled = tabs.length === 0;
  tabsEmpty.hidden = tabs.length > 0;
  tabsList.hidden = tabs.length === 0;

  const signature = JSON.stringify(
    tabs.map((t) => [t.tabId, t.title || "", t.url || ""])
  );
  if (signature === lastTabsSignature) {
    return;
  }
  lastTabsSignature = signature;

  while (tabsList.firstChild) {
    tabsList.removeChild(tabsList.firstChild);
  }

  for (const tab of tabs) {
    const row = document.createElement("div");
    row.className = "tab-row";

    const info = document.createElement("div");
    info.className = "tab-info";

    const titleEl = document.createElement("span");
    titleEl.className = "tab-title";
    titleEl.textContent = tab.title || tab.url || `Tab #${tab.tabId}`;

    const hostEl = document.createElement("span");
    hostEl.className = "tab-host";
    hostEl.textContent = extractHost(tab.url);

    info.appendChild(titleEl);
    info.appendChild(hostEl);

    const releaseBtn = document.createElement("button");
    releaseBtn.type = "button";
    releaseBtn.className = "btn-subtle btn-release";
    releaseBtn.textContent = "Release";
    releaseBtn.addEventListener("click", async () => {
      releaseBtn.disabled = true;
      try {
        await chrome.runtime.sendMessage({ type: "releaseTab", tabId: tab.tabId });
      } catch (_) {}
      await loadState();
    });

    row.appendChild(info);
    row.appendChild(releaseBtn);
    tabsList.appendChild(row);
  }
}

async function loadState() {
  try {
    const state = await chrome.runtime.sendMessage({ type: "getState" });
    lastState = state;
    renderStatus(state);
    if (document.activeElement !== profileInput) {
      profileInput.value = state?.profileName || "";
      lastSavedValue = profileInput.value;
    }
  } catch (_) {
    lastState = { wsState: "disconnected", authState: "authenticating", hasKey: true, tabs: [] };
    renderStatus(lastState);
  }
}

async function saveProfileName(value) {
  const trimmed = value.trim();
  if (trimmed === lastSavedValue) return;
  try {
    const res = await chrome.runtime.sendMessage({
      type: "setProfileName",
      profileName: trimmed
    });
    if (res?.ok) {
      lastSavedValue = res.profileName ?? trimmed;
      if (!trimmed && res.profileName) {
        profileInput.value = res.profileName;
      }
      saveIndicator.textContent = "Saved";
      setTimeout(() => {
        if (saveIndicator.textContent === "Saved") {
          saveIndicator.textContent = "";
        }
      }, 1200);
    }
  } catch (_) {}
}

async function submitPairingKey() {
  const key = pairingKeyInput.value;
  pairBtn.disabled = true;
  try {
    const res = await chrome.runtime.sendMessage({
      type: "setPairingKey",
      key
    });
    if (res?.ok) {
      formatErrorActive = false;
      editingKey = false;
      pairingKeyInput.value = "";
      await loadState();
    } else if (res?.error === "invalid_format") {
      formatErrorActive = true;
      renderStatus(lastState || { wsState: "disconnected", authState: "unpaired", hasKey: false, tabs: [] });
    }
  } catch (_) {
  } finally {
    pairBtn.disabled = false;
  }
}

profileInput.addEventListener("input", () => {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    saveProfileName(profileInput.value);
  }, 300);
});

profileInput.addEventListener("blur", () => {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  saveProfileName(profileInput.value);
});

profileInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    if (saveTimer) {
      clearTimeout(saveTimer);
      saveTimer = null;
    }
    saveProfileName(profileInput.value);
    profileInput.blur();
  }
});

changeKeyBtn.addEventListener("click", () => {
  editingKey = true;
  formatErrorActive = false;
  pairingKeyInput.value = "";
  renderStatus(lastState || { wsState: "connected", authState: "ready", hasKey: true, tabs: [] });
  pairingKeyInput.focus();
});

pairingKeyInput.addEventListener("input", () => {
  if (formatErrorActive) {
    formatErrorActive = false;
    if (lastState) {
      renderStatus(lastState);
    } else {
      pairingError.textContent = "";
      pairingError.hidden = true;
    }
  }
});

pairingKeyInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    submitPairingKey();
  } else if (e.key === "Escape" && editingKey && lastState?.hasKey && lastState?.authState !== "key_mismatch") {
    editingKey = false;
    formatErrorActive = false;
    pairingKeyInput.value = "";
    renderStatus(lastState);
  }
});

pairBtn.addEventListener("click", () => {
  submitPairingKey();
});

stopAllBtn.addEventListener("click", async () => {
  stopAllBtn.disabled = true;
  try {
    await chrome.runtime.sendMessage({ type: "stopAll" });
  } catch (_) {}
  await loadState();
});

reconnectBtn.addEventListener("click", async () => {
  reconnectBtn.disabled = true;
  reconnectBtn.textContent = "Connecting…";
  try {
    await chrome.runtime.sendMessage({ type: "reconnect" });
  } catch (_) {}
  setTimeout(async () => {
    await loadState();
    reconnectBtn.disabled = false;
    reconnectBtn.textContent = "Reconnect";
  }, 450);
});

initVersion();
loadState();
const pollTimer = setInterval(loadState, 1000);
window.addEventListener("unload", () => clearInterval(pollTimer));
