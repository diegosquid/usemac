// Owned tabs, command pipelines, and daemon and popup request dispatch.

// Tabs UseMac itself opened (new tab or new window). Only these are closed when a task completes; tabs the
// user had open (reached through tabId) are never closed. Kept in session storage so a service-worker
// restart does not forget them.
const OWNED_TABS_KEY = "usemacOwnedTabIds";
let ownedTabIdsUpdates = Promise.resolve();

// A restore, an open, and a task cleanup can arrive on different command queues.
function enqueueOwnedTabIdsUpdate(update) {
  const next = ownedTabIdsUpdates.then(update);
  ownedTabIdsUpdates = next.catch(() => {});
  return next;
}

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
  return enqueueOwnedTabIdsUpdate(async () => {
    const ids = await loadOwnedTabIds();
    ids.add(tabId);
    await saveOwnedTabIds(ids);
  });
}

async function forgetOwnedTab(tabId) {
  return enqueueOwnedTabIdsUpdate(async () => {
    const ids = await loadOwnedTabIds();
    if (ids.delete(tabId)) await saveOwnedTabIds(ids);
  });
}

async function syncOwnedTabIdsFromDaemon(tabIds) {
  if (!Array.isArray(tabIds) || tabIds.length === 0) return;
  const candidates = new Set(tabIds.filter((id) => Number.isInteger(id) && id > 0));
  return enqueueOwnedTabIdsUpdate(async () => {
    const owned = await loadOwnedTabIds();
    const previousSize = owned.size;
    for (const id of candidates) {
      if (!owned.has(id) && await getTabOrNull(id)) owned.add(id);
    }
    if (owned.size !== previousSize) await saveOwnedTabIds(owned);
  });
}

function httpDownloadOrigin(url) {
  if (!url) return null;
  try {
    const origin = new URL(url).origin;
    return /^https?:\/\//.test(origin) ? origin : null;
  } catch (_) {
    return null;
  }
}

function downloadMatchesOrigin(download, origin) {
  return Boolean(origin) && [download.referrer, download.originalUrl, download.finalUrl, download.url]
    .some((url) => httpDownloadOrigin(url) === origin);
}

async function queryActiveDownloads() {
  if (!chrome.downloads?.search) return Array.from(state.downloads.values());
  try {
    return await searchDownloads({ state: "in_progress" }, false);
  } catch (_) {
    return null;
  }
}

function hasRunningDownloadFrom(tab, activeDownloads) {
  const origin = httpDownloadOrigin(tab.url);
  return activeDownloads.some((download) => download.state === "in_progress" &&
    (state.downloadTabById.get(download.id) === tab.id || downloadMatchesOrigin(download, origin)));
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
  const activeDownloads = await queryActiveDownloads();
  const keepReason = (tab, windowId = focusedWindowId) => {
    if (keep.has(tab.id)) return "asked to keep";
    if (tab.active && tab.windowId === windowId) return "the user is looking at it";
    if (!activeDownloads) return "download status unavailable";
    const observed = new Map(activeDownloads.map((download) => [download.id, download]));
    for (const download of state.downloads.values()) observed.set(download.id, download);
    return hasRunningDownloadFrom(tab, Array.from(observed.values())) ? "a download is still running" : null;
  };

  for (const tabId of owned) {
    const tab = await getTabOrNull(tabId);
    if (!tab) {
      owned.delete(tabId);
      continue;
    }
    if (only && !only.has(tabId)) continue;
    let reason = keepReason(tab);
    if (reason) {
      kept.push({ tabId, title: tab.title || "", reason });
      continue;
    }
    try {
      await withUsemacGroupLock(async () => {
        const current = await chrome.tabs.get(tabId);
        reason = keepReason(current);
        if (reason) return;
        if (current.groupId != null && current.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE) {
          const group = await chrome.tabGroups.get(current.groupId);
          if (group.title === USEMAC_GROUP_TITLE) {
            // Closing the last tab of a WINDOW archives its group in Chrome's Saved Tab Groups.
            // Those closed groups are invisible to tabGroups.query, so folding open groups never
            // removes them. Ungroup our closing tab first: an empty group is then deleted, not saved.
            // Never ungroup a tab the user moved into a group of their own.
            await chrome.tabs.ungroup([tabId]);
          }
        }
        // Downloads/user activation may arrive during the async group operations. Check again and
        // don't yield between this final decision and remove. The group lock also excludes regrouping.
        const finalTab = await chrome.tabs.get(tabId);
        let focused;
        try {
          focused = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
        } catch (_) {}
        reason = focused ? keepReason(finalTab, focused.focused ? focused.id : null) : "window focus unavailable";
        if (!reason) await chrome.tabs.remove(tabId);
      });
      if (reason) {
        kept.push({ tabId, title: tab.title || "", reason });
        continue;
      }
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

  const clicks = [];
  try {
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
        await waitIfTabUserPaused(tabId, cancelToken);
        if (stepNeedsDebugger(step)) {
          const blocked = await restrictedPageErrorIfDetached(tabId);
          if (blocked) throw blocked;
        }
        const previousClickCount = clicks.length;
        const outcome = await executeActionStep(tabId, step, cancelToken, clicks);
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
        if (outcome.effect != null) entry.effect = outcome.effect;
        if (outcome.warning != null) entry.warning = outcome.warning;
        stepResults.push(entry);
        if (clicks.length > previousClickCount) {
          const click = clicks[clicks.length - 1];
          click.stepIndex = i;
          click.hasDownload = Boolean(entry.downloadPath);
        }
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

    // Match downloads that began during an existing wait to the preceding click, without adding another wait.
    for (let i = 0; i < clicks.length && !isCancelled(tabId, cancelToken); i++) {
      const click = clicks[i];
      if (click.stepIndex == null || click.hasDownload) continue;
      const endSequence = clicks[i + 1]?.creationSequence;
      for (const download of clickDownloads(click, endSequence)) {
        if (download.state !== "complete") continue;
        let path = completedDownloadPath(download);
        if (!download.filename) {
          await refreshDownload(download.id);
          if (isCancelled(tabId, cancelToken)) break;
          const refreshed = clickDownloads(click, endSequence).find((d) => d.id === download.id);
          path = completedDownloadPath(refreshed);
        }
        if (!path) continue;
        const entry = stepResults[click.stepIndex];
        const navigationNote = entry.mechanism === "cdp-mouse (navigated)" && entry.message;
        entry.mechanism = "cdp-mouse (download)";
        entry.downloadPath = path;
        entry.effect = "changed";
        entry.warning = null;
        entry.message = navigationNote ? `Navigated to ${navigationNote} · Download complete: ${path}` : `Download complete: ${path}`;
        break;
      }
    }
  } finally {
    for (const click of clicks) state.activeDownloadClicks.delete(click);
  }

  return { stepResults, allSucceeded, cancelled };
}

function requestDialogPolicy(req) {
  const action = req.dialogAction == null ? null : String(req.dialogAction).toLowerCase();
  if (action !== null && action !== "accept" && action !== "dismiss") {
    throw { code: "INVALID_REQUEST", message: 'dialogAction must be "accept" or "dismiss".' };
  }
  const promptText = req.dialogPromptText == null ? null : String(req.dialogPromptText);
  return action !== null || promptText !== null ? { action, promptText } : null;
}

async function withDialogCapture(session, policy, run) {
  const dialogs = [];
  const startedAt = performance.now();
  session.dialogPolicy = policy;
  session.batchDialogs = dialogs;
  try {
    const response = await run();
    if (!dialogs.length) return response;

    const actionResult = response.actionResult ??= {
      success: response.ok,
      totalLatencyMs: Math.round((performance.now() - startedAt) * 100) / 100,
      stepResults: [],
      observation: response.snapshot
    };
    actionResult.dialogs = dialogs.map(({ autoDefault, ...dialog }) => dialog);
    for (const snapshot of new Set([response.snapshot, actionResult.observation])) {
      if (snapshot) snapshot.pageState = pageStateWithLastDialog(snapshot.pageState, session);
    }
    const dismissed = dialogs.find((d) => d.autoDefault && !d.accepted && (d.type === "confirm" || d.type === "prompt"));
    if (dismissed && !actionResult.agentFeedback) {
      actionResult.agentFeedback = {
        severity: "warning",
        trigger: "js_dialog_dismissed",
        diagnosis: `Dismissed ${dismissed.type} dialog ("${dismissed.message}") by default.`,
        suggestedAction: 'Pass dialogAction: "accept" (and dialogPromptText for prompts) if you intended to confirm this dialog.',
        source: "cdp-dialog",
        latencyMs: 0.1
      };
    }
    return response;
  } finally {
    session.dialogPolicy = null;
    session.batchDialogs = null;
  }
}

async function handleOpenCommand(req, cancelToken = null) {
  const dialogPolicy = requestDialogPolicy(req);
  const targetUrl = typeof req.url === "string" ? req.url.trim() : "";
  const activate = req.activate === true;
  const newWindow = req.newWindow === true;

  if (!targetUrl) {
    if (req.tabId != null && activate && !newWindow) {
      return { ...(await handleActivateTabCommand(req)), createdTab: false };
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
  // New scriptable tabs start blank so Page.enable is listening before the site's first script runs.
  const createUrl = restrictedPageReason(targetUrl) ? targetUrl : "about:blank";
  if (isCancelled(req.tabId ?? null, cancelToken)) throw CANCELLED_ERROR;
  if (newWindow) {
    const createdWin = await createUsemacWindow(createUrl);
    tab = createdWin?.tabs?.[0];
    if (!tab) {
      throw { code: "WINDOW_ERROR", message: "Failed to create a UseMac Chrome window." };
    }
    createdByUsemac = true;
  } else {
    const windows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    if (isCancelled(req.tabId ?? null, cancelToken)) throw CANCELLED_ERROR;
    if (windows.length === 0) {
      const createdWin = await createUsemacWindow(createUrl);
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
          url: createUrl,
          active: activate
        });
        createdByUsemac = true;
      } else {
        tab = await resolveTargetTab(req.tabId);
      }
    }
  }

  return enqueueTabCommand(tab.id, () => {
    const needsNavigation = !createdByUsemac || createUrl !== targetUrl;
    const armDialogs = state.tabSessions.get(tab.id)?.attached
      || !restrictedPageReason(targetUrl) || (!createdByUsemac && dialogPolicy?.action != null);
    const run = () => navigateAndObserveOpenTab(req, tab, targetUrl, {
      openSteps, needsNavigation, armDialogs, createdByUsemac, cancelToken
    });
    if (!armDialogs) return run();
    const session = getOrCreateTabSession(tab.id);
    return withDialogCapture(session, dialogPolicy, run);
  });
}

async function navigateAndObserveOpenTab(req, tab, targetUrl, {
  openSteps, needsNavigation, armDialogs, createdByUsemac, cancelToken
}) {
  if (createdByUsemac) {
    await markTabOwned(tab.id);
  }
  if (needsNavigation) {
    if (req.tabId != null) await waitIfTabUserPaused(tab.id, cancelToken);
    if (isCancelled(tab.id, cancelToken)) throw CANCELLED_ERROR;

    // Attach while still on the previous document so beforeunload cannot block tabs.update.
    const current = (await getTabOrNull(tab.id)) || tab;
    if (armDialogs && !(await tabRestrictionReason(current))) {
      try {
        await ensureAttached(tab.id);
      } catch (err) {
        // The old page may become restricted between our check and debugger attachment.
        // Still let the explicit navigation leave it.
        const mapped = await toRestrictedPageErrorIfNeeded(err, tab.id);
        if (mapped?.code !== "RESTRICTED_PAGE") throw err;
      }
    }
    if (isCancelled(tab.id, cancelToken)) throw CANCELLED_ERROR;
    if (createdByUsemac && current.url === "about:blank" && state.tabSessions.get(tab.id)?.attached) {
      // The blank document is only there to arm dialog capture. Do not leave it in the tab's history.
      const result = await sendCDP(tab.id, "Runtime.evaluate", {
        expression: `location.replace(${JSON.stringify(targetUrl)})`
      });
      if (result.exceptionDetails) throw new Error("Could not navigate the new Chrome tab.");
    } else {
      const update = { url: targetUrl };
      if (!createdByUsemac && req.activate === true) update.active = true;
      tab = await chrome.tabs.update(tab.id, update);
    }
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
    createdTab: Boolean(createdByUsemac),
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
        await waitIfTabUserPaused(tab.id, cancelToken);
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
        } catch (err) {
          if (err?.code === "CANCELLED") throw err;
        }
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
          createdTab: Boolean(createdByUsemac),
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
    createdTab: Boolean(createdByUsemac),
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
  const dialogPolicy = requestDialogPolicy(req);
  const tab = preResolvedTab || await resolveTargetTab(req.tabId);
  await assertTabScriptable(tab.id);
  await ensureTabInUsemacGroup(tab.id);
  const session = getOrCreateTabSession(tab.id);
  return withDialogCapture(session, dialogPolicy, () => executeActBatch(req, tab, session, cancelToken));
}

async function executeActBatch(req, tab, session, cancelToken) {
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
  if (req.command === "tabs" || req.command === "close_owned_tabs" || (req.command === "extract" && String(req.mode || "auto").trim().toLowerCase() === "downloads")) {
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
    // A paused batch owns the tab's queue. Cancel its wait before queuing an explicit detach.
    for (const [id, session] of state.tabSessions) {
      if (req.tabId == null || req.tabId === id) cancelTabIndicatorUserPause(id, session.tabIndicator);
    }
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
      const cancelToken = createCancelToken(tab.id, reqGlobalGen, reqTabGen != null ? reqTabGen : getTabCancelGen(tab.id), req.id);
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
        response = await enqueueOwnedTabIdsUpdate(() => handleCloseOwnedTabsCommand(req));
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
