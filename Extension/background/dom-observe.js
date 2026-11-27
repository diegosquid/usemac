// Frame indexes and browser observation snapshots.

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
    pageState: pageStateWithLastDialog(pageData.pageState || null, session)
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

function pageStateWithLastDialog(pageState, session) {
  if (!session.lastDialog) return pageState;
  if (!pageState) {
    const { width, height } = effectiveViewport(session);
    pageState = {
      scrollX: 0, scrollY: 0, scrollHeight: 0,
      viewportWidth: width, viewportHeight: height,
      canScrollDown: false, canScrollUp: false, scrollLocked: false
    };
  }
  return { ...pageState, lastDialog: session.lastDialog };
}
