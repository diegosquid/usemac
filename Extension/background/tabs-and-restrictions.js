// UseMac tab groups, tab resolution, and restricted page handling.

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

function restrictedPageGuidance(tab, { activated = false } = {}) {
  const tabId = tab?.id ?? null;
  const url = effectiveTabUrl(tab);
  const tabRef = tabId != null ? String(tabId) : "<tabId>";
  const appName = BROWSER_APP_NAMES[BROWSER_FLAVOR] || "Google Chrome";
  let text;
  if (activated) {
    text = `The tab is now the active tab of its window. Use native observe/act with app "${appName}" to work on it.`;
  } else if (tab?.active) {
    text = `use native observe/act with app "${appName}": it is already the active tab of its window, and native observe only sees the active tab of each window.`;
  } else {
    text = `make it the active tab of its window with browser_open {"tabId":${tabRef},"url":"","activate":true}`;
    if (/^https?:/i.test(url)) {
      text += ` (or open it in a separate UseMac window with browser_open ${JSON.stringify({ url, newWindow: true })})`;
    }
    text += `, then use native observe/act with app "${appName}" (native observe only sees the active tab of each window).`;
  }
  text += ` The native route requires the ${appName} window to be visible on screen. In the background, the browser may omit the AXWebArea or fields may ignore setValue.`;
  text += ` If observe shows only the browser toolbar or setValue returns effect: "none", use "foreground": true to briefly focus the window, act, and restore the previous focus.`;
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
  const guidance = restrictedPageGuidance(tab, { activated });
  const suggestedAction = activated
    ? guidance
    : `To work on it, ${guidance}`;
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
