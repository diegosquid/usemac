// Download cache, Chrome download events, and completion waits.

function downloadBytes(value) {
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function normalizeDownload(item) {
  return {
    id: item.id,
    filename: item.filename || "",
    url: item.finalUrl || item.url || null,
    originalUrl: item.url || null,
    finalUrl: item.finalUrl || null,
    referrer: item.referrer || null,
    state: item.state || "in_progress",
    bytesReceived: downloadBytes(item.bytesReceived),
    totalBytes: downloadBytes(item.totalBytes),
    mime: item.mime || null,
    startTime: item.startTime || null,
    error: item.error || null,
    progressStale: false
  };
}

function cacheDownload(download) {
  state.downloads.delete(download.id);
  state.downloads.set(download.id, download);
  if (state.downloads.size > DOWNLOAD_CACHE_MAX) {
    const oldest = state.downloads.values().next().value;
    if (oldest.state !== "in_progress") state.downloadTabById.delete(oldest.id);
    state.downloads.delete(oldest.id);
  }
}

async function searchDownloads(query, updateCache = true) {
  const before = new Map(state.downloads);
  state.downloadSearchesInFlight += 1;
  try {
    const items = await chrome.downloads.search(query);
    const results = [];
    for (const item of items) {
      if (item?.id == null || state.erasedDownloads.has(item.id)) continue;
      const current = state.downloads.get(item.id);
      const snapshot = normalizeDownload(item);
      // A search may have started before a newer delta (including a terminal state).
      if (current && current.state !== "in_progress" && snapshot.state === "in_progress") {
        results.push(current);
        continue;
      }
      if (current) {
        const previous = before.get(item.id);
        if (current !== previous) {
          const snapshotState = snapshot.state;
          for (const field of ["filename", "state", "mime", "totalBytes", "finalUrl", "originalUrl", "error"]) {
            if (current[field] !== previous?.[field]) snapshot[field] = current[field];
          }
          snapshot.url = snapshot.finalUrl || snapshot.originalUrl;
          if (snapshot.state !== snapshotState) {
            snapshot.bytesReceived = current.bytesReceived;
            snapshot.progressStale = current.progressStale;
          }
        }
        snapshot.createdAt = current.createdAt;
        snapshot.creationSequence = current.creationSequence;
      }
      if (updateCache) cacheDownload(snapshot);
      results.push(snapshot);
    }
    return results;
  } finally {
    state.downloadSearchesInFlight -= 1;
    if (state.downloadSearchesInFlight === 0) state.erasedDownloads.clear();
  }
}

function refreshDownload(id, forTerminal = false) {
  if (!chrome.downloads?.search) return Promise.resolve(null);
  const pending = state.refreshingDownloads.get(id);
  if (pending) {
    if (forTerminal && !pending.forTerminal) pending.needsTerminalRefresh = true;
    return pending.promise;
  }
  const refresh = { forTerminal, needsTerminalRefresh: false };
  refresh.promise = searchDownloads({ id })
    .catch(() => null)
    .finally(() => {
      state.refreshingDownloads.delete(id);
      // Polling may have captured an in-progress snapshot just before the completion delta.
      if (refresh.needsTerminalRefresh && state.downloads.get(id)?.progressStale) refreshDownload(id, true);
    });
  state.refreshingDownloads.set(id, refresh);
  return refresh.promise;
}

function prunePageDownloads(now) {
  state.pendingPageDownloads = state.pendingPageDownloads.filter((entry) => now - entry.at <= PAGE_DOWNLOAD_TTL_MS);
}

chrome.downloads?.onCreated?.addListener((item) => {
  if (item?.id == null) return;
  const createdAt = Date.now();
  prunePageDownloads(createdAt);
  const matches = state.pendingPageDownloads.filter((entry) =>
    entry.url && (entry.url === item.url || entry.url === item.finalUrl) &&
    Math.abs(entry.at - createdAt) <= PAGE_DOWNLOAD_MATCH_MS
  );
  if (matches.length === 1) {
    state.downloadTabById.set(item.id, matches[0].tabId);
    state.pendingPageDownloads.splice(state.pendingPageDownloads.indexOf(matches[0]), 1);
  }
  cacheDownload({
    ...normalizeDownload(item),
    createdAt,
    creationSequence: ++state.downloadCreationSequence
  });
});

chrome.downloads?.onChanged?.addListener((delta) => {
  if (delta?.id == null || state.erasedDownloads.has(delta.id)) return;
  const next = { ...(state.downloads.get(delta.id) || normalizeDownload(delta)) };
  if (delta.filename) next.filename = delta.filename.current || "";
  if (delta.state?.current) next.state = delta.state.current;
  if (delta.mime) next.mime = delta.mime.current || null;
  if (delta.totalBytes) next.totalBytes = downloadBytes(delta.totalBytes.current);
  if (delta.url) next.originalUrl = delta.url.current || null;
  if (delta.finalUrl) next.finalUrl = delta.finalUrl.current || null;
  next.url = next.finalUrl || next.originalUrl;
  if (delta.error) next.error = delta.error.current || null;

  const terminal = delta.state?.current === "complete" || delta.state?.current === "interrupted";
  if (terminal) next.progressStale = true;
  cacheDownload(next);
  if (terminal) refreshDownload(delta.id, true);
});

chrome.downloads?.onErased?.addListener((id) => {
  state.downloads.delete(id);
  state.downloadTabById.delete(id);
  if (state.downloadSearchesInFlight > 0) state.erasedDownloads.add(id);
});

async function listRecentDownloads(limit = 20) {
  const cap = clamp(Number(limit) || 20, 1, 20);
  const cutoff = Date.now() - DOWNLOAD_HISTORY_MS;
  if (chrome.downloads?.search) {
    const query = { orderBy: ["-startTime"], limit: cap };
    try {
      await searchDownloads({ ...query, startedAfter: new Date(cutoff).toISOString() });
    } catch (_) {
      // Older API stand-ins may not accept startedAfter. Keep the time filter below either way.
      try { await searchDownloads(query); } catch (_) {}
    }
  }
  const startMs = (download) => Date.parse(download.startTime) || 0;
  return Array.from(state.downloads.values())
    .filter((download) => !download.startTime || startMs(download) >= cutoff)
    .sort((a, b) => startMs(b) - startMs(a) || b.id - a.id)
    .slice(0, cap)
    .map((it) => ({
      id: it.id,
      filename: it.filename,
      url: it.url,
      originalUrl: it.originalUrl,
      referrer: it.referrer,
      state: it.state,
      bytesReceived: it.progressStale ? null : it.bytesReceived,
      totalBytes: it.totalBytes,
      mime: it.mime,
      startTime: it.startTime,
      error: it.error
    }));
}

async function waitForDownloadCompletion(downloadId, timeoutMs, tabId, cancelToken) {
  const deadline = Date.now() + timeoutMs;
  while (true) {
    if (isCancelled(tabId, cancelToken)) throw CANCELLED_ERROR;
    const cached = state.downloads.get(downloadId);
    const remaining = deadline - Date.now();
    if (!cached || cached.state !== "in_progress" || remaining <= 0) return cached || null;
    refreshDownload(downloadId);
    await sleepCancellable(Math.min(160, remaining), tabId, cancelToken);
  }
}
