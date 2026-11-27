// Tab listing, page and network extraction, and screenshot capture.

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
  await ownedTabIdsUpdates;
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
  const docIdAtStart = session.documentId;
  const filterLower = typeof urlFilter === "string" ? urlFilter.trim().toLowerCase() : "";
  const matching = (session.networkRing || [])
    .filter((entry) => entry.documentId == null || entry.documentId === docIdAtStart)
    .filter((entry) => !filterLower || String(entry.url || "").toLowerCase().includes(filterLower))
    .slice()
    .reverse(); // newest first

  const items = [];
  let approxLen = 2; // "[]"
  for (const entry of matching) {
    if (session.documentId !== docIdAtStart) break;
    if (!entry.bodyLoaded && entry.requestId) {
      const wasFinished = entry.finished === true;
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
        entry.bodyLoaded = true;
      } catch (_) {
        // A request can finish while getResponseBody is in flight. If it wasn't finished when
        // we asked, try again on the next extract rather than memoizing a premature failure.
        entry.bodyLoaded = wasFinished;
      }
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

  if (session.documentId !== docIdAtStart) return { jsonResult: "[]", count: 0 };
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
  const mode = String(req.mode || "auto").trim().toLowerCase();
  const maxChars = clamp(Number(req.maxChars) || 16000, 500, 64000);

  if (mode === "downloads") {
    const downloads = await listRecentDownloads(20);
    return {
      type: "response",
      id: req.id,
      ok: true,
      tabId: null,
      profileName: state.profileName,
      url: null,
      title: null,
      extractResult: {
        mode: "downloads",
        tabId: null,
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
