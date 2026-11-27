// Frame-aware DOM evaluation, geometry, and snapshot diff helpers.

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

async function evalAgentInputInFrame(tabId, frameMeta, expression, opts = {}) {
  const input = beginTabIndicatorAgentInput(tabId, "keyboard");
  try {
    return await evalInFrame(tabId, frameMeta, expression, opts);
  } finally {
    endTabIndicatorAgentInput(tabId, "keyboard", input);
  }
}

// Runs in the owner element's document, not in the iframe being clicked.
function frameOwnerClickObstruction(owner, hitAtPoint, x, y) {
  const hit = hitAtPoint(owner.ownerDocument, x, y);
  return hit === owner ? null : hit?.localName || "an unknown element";
}

async function getFrameOwnerRect(tabId, frameId, parentSessionId = null, fallbackUrl = "", scrollOwnerIntoView = false, clickPoints = null) {
  const hitTestSource = clickPoints ? `
    const hitAtPoint = ${clickHitAtPoint.toString()};
    const obstruction = ${frameOwnerClickObstruction.toString()};
  ` : "";
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
          arguments: [{ value: Boolean(scrollOwnerIntoView) }, { value: clickPoints }],
          functionDeclaration: `function(scrollIfHidden, clickPoints) {
            ${hitTestSource}
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
            const pointObstructions = clickPoints?.map(() => null);
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
              if (clickPoints) {
                for (let i = 0; i < clickPoints.length; i++) {
                  const point = clickPoints[i];
                  pointObstructions[i] ??= obstruction(cur, hitAtPoint, point.x + x, point.y + y);
                }
              }
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
            return { visible: visible && width >= 24 && height >= 20, x, y, width, height, title, pointObstructions };
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
          ${hitTestSource}
          const clickPoints = ${JSON.stringify(clickPoints)};
          const wanted = ${urlLit};
          let wantedOrigin = '';
          try { wantedOrigin = new URL(wanted).origin; } catch (_) {}
          const iframes = queryAllDeep(document, 'iframe');
          let best = null;
          let bestFrame = null;
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
              bestFrame = f;
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
          if (bestScore < 4) return null;
          if (clickPoints) {
            best.pointObstructions = clickPoints.map((point) =>
              obstruction(bestFrame, hitAtPoint, point.x + best.x, point.y + best.y));
          }
          return best;
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

async function computeFrameViewportRect(tabId, frameMeta, scrollOwnerIntoView = false, clickPoints = null) {
  if (!frameMeta || !Array.isArray(frameMeta.hops) || frameMeta.hops.length === 0) {
    return { visible: true, x: 0, y: 0, width: 0, height: 0, title: "" };
  }
  let totalX = 0;
  let totalY = 0;
  let lastW = 0;
  let lastH = 0;
  let lastTitle = "";
  const pointObstructions = clickPoints?.map(() => null);
  for (let i = 0; i < frameMeta.hops.length; i++) {
    // To hit-test a click, walk toward the top document so each parent gets the point in its own coordinates.
    const last = frameMeta.hops.length - 1;
    const index = clickPoints ? last - i : i;
    const hop = frameMeta.hops[index];
    const rect = await getFrameOwnerRect(
      tabId,
      hop.frameId,
      hop.parentSessionId,
      hop.url || "",
      scrollOwnerIntoView && index === last,
      clickPoints?.map((point) => ({ x: point.x + totalX, y: point.y + totalY })) ?? null
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
    if (!clickPoints || i === 0) {
      lastW = rect.width;
      lastH = rect.height;
    }
    lastTitle = clickPoints ? lastTitle || rect.title : rect.title || lastTitle;
    if (pointObstructions) {
      for (let j = 0; j < pointObstructions.length; j++) pointObstructions[j] ??= rect.pointObstructions?.[j] ?? null;
    }
  }
  frameMeta.offsetX = totalX;
  frameMeta.offsetY = totalY;
  frameMeta.width = lastW;
  frameMeta.height = lastH;
  return { visible: true, x: totalX, y: totalY, width: lastW, height: lastH, title: lastTitle, pointObstructions };
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
