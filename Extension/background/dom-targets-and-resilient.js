// DOM target resolution, input descriptors, and resilient action steps.

function emitCursor(tabId, x, y, phase, label = null) {
  noteTabIndicatorStep(tabId, label);
  const viewport = effectiveViewport(state.tabSessions.get(tabId));
  sendWS({
    type: "cursor",
    tabId,
    x: Math.round(x * 10) / 10,
    y: Math.round(y * 10) / 10,
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    phase,
    label
  });
}

async function moveCursorSmoothly(tabId, targetX, targetY, label = null) {
  const session = getOrCreateTabSession(tabId);
  // Clamp to the page's measured size only: the fallback size must not cut off clicks on a wider page.
  const maxW = session.liveViewport?.width ?? Infinity;
  const maxH = session.liveViewport?.height ?? Infinity;
  const tx = clamp(Number(targetX), 0, maxW);
  const ty = clamp(Number(targetY), 0, maxH);
  session.cursor = { x: tx, y: ty };
  emitCursor(tabId, tx, ty, "move", label);
  await sendCDP(tabId, "Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: tx,
    y: ty,
    button: "none"
  });
  return { x: tx, y: ty };
}

function usemacIdSelectorLiteral(elementId) {
  const escapedId = String(elementId).replace(/["\\]/g, "\\$&");
  return JSON.stringify(`[data-usemac-id="${escapedId}"]`);
}

function hasNonEmptyMatch(match) {
  if (!match || typeof match !== "object") return false;
  const nonBlank = (v) => typeof v === "string" && v.trim() !== "";
  return nonBlank(match.role) || nonBlank(match.title) || nonBlank(match.value) || nonBlank(match.text);
}

function formatMatchDesc(match) {
  if (!match || typeof match !== "object") return "match";
  const parts = [];
  if (match.role) parts.push(`role=${match.role}`);
  if (match.title) parts.push(`title="${match.title}"`);
  if (match.value) parts.push(`value="${match.value}"`);
  if (match.text) parts.push(`text="${match.text}"`);
  if (Number.isFinite(match.index) && match.index > 0) parts.push(`index=${match.index}`);
  return parts.join(", ") || "match";
}

function findElementExprJs({ elementId = null, selector = null }) {
  if (elementId) {
    return `findByUsemacId(${JSON.stringify(String(elementId))}, document)`;
  }
  if (selector) {
    return `queryOneDeep(document, ${JSON.stringify(String(selector))})`;
  }
  return "null";
}

async function resolveInSpecificFrame(tabId, frameMeta, { elementId = null, selector = null }, scrollOwnerIntoView = true, scrollTargetIntoView = true) {
  let offsetX = 0;
  let offsetY = 0;
  if (frameMeta && frameMeta.frameId != null) {
    const fRect = await computeFrameViewportRect(tabId, frameMeta, scrollOwnerIntoView);
    if (!fRect || !fRect.visible) {
      return null;
    }
    offsetX = fRect.x;
    offsetY = fRect.y;
  }
  const lookupExpr = findElementExprJs({ elementId, selector });
  const res = await evalInFrame(tabId, frameMeta, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const el = ${lookupExpr};
    if (!el) return null;
    ${scrollTargetIntoView ? "el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });" : ""}
    const rect = el.getBoundingClientRect();
    const label = (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.tagName || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      label
    };
  })()`).catch(() => null);
  const point = res?.result?.value;
  if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    return null;
  }
  return {
    x: point.x + offsetX,
    y: point.y + offsetY,
    label: point.label || null,
    elementId: elementId || null,
    frameMeta: frameMeta || null
  };
}

async function resolveMatchInSpecificFrame(tabId, session, frameMeta, match, remainingSkip = 0, scrollOwnerIntoView = true) {
  let offsetX = 0;
  let offsetY = 0;
  if (frameMeta && frameMeta.frameId != null) {
    const fRect = await computeFrameViewportRect(tabId, frameMeta, scrollOwnerIntoView);
    if (!fRect || !fRect.visible) {
      return { found: false, matchCount: 0 };
    }
    offsetX = fRect.x;
    offsetY = fRect.y;
  }
  const idBase = frameMeta?.frameId ? getFrameSlot(session, frameMeta.frameId) * 10000 + 1 : 1;
  const matchLit = JSON.stringify(match);
  const res = await evalInFrame(tabId, frameMeta, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const spec = ${matchLit};
    const skip = ${Math.max(0, Number(remainingSkip) || 0)};
    const reg = getUsemacRefRegistry(${idBase});
    const roots = collectRoots(document);
    const labelMap = new Map();
    const labelNodes = queryAllInRoots(roots, 'label[for]');
    for (let i = 0; i < labelNodes.length; i++) {
      const f = labelNodes[i].getAttribute('for');
      if (f && !labelMap.has(f)) {
        const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
        if (t) labelMap.set(f, t);
      }
    }
    const sel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
    const candidates = queryAllInRoots(roots, sel);
    let matchCount = 0;
    for (let i = 0; i < candidates.length; i++) {
      const el = candidates[i];
      const st = window.getComputedStyle(el);
      if (!st || st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2 || el.getClientRects().length === 0) continue;
      if (!matchesElementSpec(el, spec, labelMap)) continue;
      if (matchCount === skip) {
        const id = assignUsemacNodeId(el, reg);
        if (el.getAttribute('data-usemac-id') !== id) el.setAttribute('data-usemac-id', id);
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        const label = (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.tagName || '').replace(/\\s+/g, ' ').trim().slice(0, 40);
        return {
          found: true,
          matchCount: matchCount + 1,
          id,
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
          label
        };
      }
      matchCount += 1;
    }
    return { found: false, matchCount };
  })()`).catch(() => null);
  const v = res?.result?.value;
  if (!v) return { found: false, matchCount: 0 };
  if (v.found && Number.isFinite(v.x) && Number.isFinite(v.y)) {
    if (v.id) {
      const targetFrameMeta = frameMeta || {
        sessionId: null, contextId: null, frameId: null, parentSessionId: null,
        offsetX: 0, offsetY: 0, isOOPIF: false, hops: []
      };
      session.elementFrameMap.set(v.id, targetFrameMeta);
    }
    return {
      found: true,
      matchCount: v.matchCount,
      target: {
        x: v.x + offsetX,
        y: v.y + offsetY,
        label: v.label || null,
        elementId: v.id || null,
        frameMeta: frameMeta || null
      }
    };
  }
  return { found: false, matchCount: v.matchCount || 0 };
}

async function resolveMatchCenter(tabId, match) {
  const session = getOrCreateTabSession(tabId);
  const desiredIndex = Math.max(0, Number(match?.index) || 0);
  let remaining = desiredIndex;

  const topRes = await resolveMatchInSpecificFrame(tabId, session, null, match, remaining, false);
  if (topRes.found) return topRes.target;
  remaining -= topRes.matchCount;

  let frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveMatchInSpecificFrame(tabId, session, frameMeta, match, remaining, true);
    if (hit.found) return hit.target;
    remaining -= hit.matchCount;
  }
  // Fresh discovery pass in case an iframe mounted since last observe
  if (session.lastChildFrames && session.lastChildFrames.length > 0) {
    const freshFrames = await discoverChildFrames(tabId).catch(() => []);
    for (const frameMeta of freshFrames) {
      if (frames.some((f) => f.frameId === frameMeta.frameId && f.sessionId === frameMeta.sessionId)) continue;
      const hit = await resolveMatchInSpecificFrame(tabId, session, frameMeta, match, remaining, true);
      if (hit.found) return hit.target;
      remaining -= hit.matchCount;
    }
  }
  throw {
    code: "ELEMENT_NOT_FOUND",
    message: `No element matched {${formatMatchDesc(match)}} in tab ${tabId}.`
  };
}

async function resolveSelectorCenter(tabId, cssSelector) {
  const topHit = await resolveInSpecificFrame(tabId, null, { selector: cssSelector }, false);
  if (topHit) return topHit;

  const session = getOrCreateTabSession(tabId);
  let frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveInSpecificFrame(tabId, frameMeta, { selector: cssSelector }, true);
    if (hit) return hit;
  }
  // One fresh discovery pass in case a new OOPIF mounted after last observe
  frames = await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    const hit = await resolveInSpecificFrame(tabId, frameMeta, { selector: cssSelector }, true);
    if (hit) return hit;
  }
  throw { code: "ELEMENT_NOT_FOUND", message: `Selector ${cssSelector} not found in tab ${tabId}.` };
}

async function resolveElementCenter(tabId, elementId) {
  const session = getOrCreateTabSession(tabId);
  const mappedFrame = session.elementFrameMap.get(elementId);
  if (mappedFrame) {
    const mappedHit = await resolveInSpecificFrame(tabId, mappedFrame, { elementId }, true);
    if (mappedHit) return mappedHit;
  }

  // Fallback: top frame then all discovered child frames
  if (!mappedFrame || mappedFrame.frameId != null) {
    const topHit = await resolveInSpecificFrame(tabId, null, { elementId }, false);
    if (topHit) return topHit;
  }
  const frames = session.lastChildFrames && session.lastChildFrames.length > 0
    ? session.lastChildFrames
    : await discoverChildFrames(tabId).catch(() => []);
  for (const frameMeta of frames) {
    if (mappedFrame && frameMeta === mappedFrame) continue;
    const hit = await resolveInSpecificFrame(tabId, frameMeta, { elementId }, true);
    if (hit) return hit;
  }
  throw { code: "ELEMENT_NOT_FOUND", message: `Element ${elementId} not found in tab ${tabId}.` };
}

function findChildFrameAtPoint(session, x, y) {
  const frames = session?.lastChildFrames;
  if (!Array.isArray(frames) || frames.length === 0) return null;
  // Prefer smallest (deepest nested) frame containing (x, y)
  let best = null;
  let bestArea = Infinity;
  for (const f of frames) {
    if (
      x >= f.offsetX &&
      x <= f.offsetX + f.width &&
      y >= f.offsetY &&
      y <= f.offsetY + f.height
    ) {
      const area = f.width * f.height;
      if (area < bestArea) {
        bestArea = area;
        best = f;
      }
    }
  }
  return best;
}

async function resolveStepTarget(tabId, step) {
  if (typeof step.elementId === "string" && step.elementId.trim() !== "") {
    return resolveElementCenter(tabId, step.elementId.trim());
  }
  if (typeof step.selector === "string" && step.selector.trim() !== "") {
    return resolveSelectorCenter(tabId, step.selector.trim());
  }
  if (hasNonEmptyMatch(step.match)) {
    return resolveMatchCenter(tabId, step.match);
  }
  if (Number.isFinite(step.x) && Number.isFinite(step.y)) {
    return { x: Number(step.x), y: Number(step.y), label: null };
  }
  return null;
}

function dragDestinationStep(step) {
  return {
    elementId: step.toElementId,
    selector: step.toSelector,
    match: step.toMatch,
    x: step.toX,
    y: step.toY
  };
}

function resolveDragDestination(tabId, step) {
  return resolveStepTarget(tabId, dragDestinationStep(step));
}

function stepNamesDOMTarget(step) {
  const named = (value) => typeof value === "string" && value.trim() !== "";
  return named(step?.elementId) || named(step?.selector) || hasNonEmptyMatch(step?.match);
}

// Sent to the target frame, including for elements inside open shadow roots.
function clickHitAtPoint(root, x, y) {
  let hit = root.elementFromPoint?.(x, y) || null;
  if (hit?.localName === "usemac-tab-indicator") {
    // CDP makes the pill inert for the actual pointer event; test the page beneath it.
    hit = root.elementsFromPoint?.(x, y).find((node) => node !== hit) || null;
  }
  while (hit?.shadowRoot) {
    const inner = hit.shadowRoot.elementFromPoint?.(x, y);
    if (!inner || inner === hit) break;
    hit = inner;
  }
  return hit;
}

async function refreshClickTargetPoint(tabId, target, lookupExpr) {
  const { frameMeta } = target;
  const result = await evalInFrame(tabId, frameMeta, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const hitAtPoint = ${clickHitAtPoint.toString()};
    const el = ${lookupExpr};
    if (!el) return { missing: true };
    const rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return { missing: true };
    const control = el.closest?.('a[href], [role="link"], button, [role="button"], input, label, select, textarea, summary');
    const isLink = Boolean(el.closest?.('a[href], [role="link"]'));
    const candidates = [[0.5, 0.5], [0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]]
      .map(([x, y]) => ({ x: rect.left + rect.width * x, y: rect.top + rect.height * y }));
    if (typeof document.elementFromPoint !== 'function') return { missing: true };
    const hitsTarget = (hit) => Boolean(hit && (hit === el || el.contains(hit) || (hit === el.parentElement && hit === control)));
    const points = [];
    let obstructedBy = null;
    for (const candidate of candidates) {
      const hit = hitAtPoint(document, candidate.x, candidate.y);
      if (hitsTarget(hit)) points.push(candidate);
      else obstructedBy ??= hit?.localName || null;
    }
    return { points, isLink, fullyObstructed: points.length === 0, obstructedBy };
  })()`);
  const checked = result?.result?.value;
  if (!checked || checked.missing || result?.exceptionDetails || !Array.isArray(checked.points)) {
    throw { code: "ELEMENT_NOT_FOUND", message: "The click target could not be rechecked. Observe again before retrying." };
  }
  if (checked?.fullyObstructed) {
    return { ...target, fullyObstructed: true, obstructedBy: checked.obstructedBy };
  }
  const frame = frameMeta?.frameId != null ? await computeFrameViewportRect(tabId, frameMeta, false, checked.points) : null;
  if (frame && !frame.visible) {
    throw { code: "ELEMENT_NOT_FOUND", message: "The click target's frame is no longer visible. Observe again before retrying." };
  }
  const point = checked.points.find((_, i) => !frame?.pointObstructions?.[i]);
  if (!point) return { ...target, frameObstructedBy: frame.pointObstructions[0] };
  return { ...target, x: point.x + (frame?.x || 0), y: point.y + (frame?.y || 0), isLink: checked.isLink };
}

const clickProbeLifetimeMs = 2000;

// Runs in the clicked frame. Read and dispose together; the timeout also covers a lost CDP connection.
function installClickProbe(key, el, watchTarget, lifetimeMs) {
  if (typeof window.addEventListener !== "function") return false;
  const events = ["pointerdown", "mousedown", "click", "auxclick", "dblclick"];
  const readState = () => el && JSON.stringify([
    el.checked, el.getAttribute("aria-expanded"), el.getAttribute("aria-selected"),
    el.getAttribute("aria-pressed"), el.disabled, el.value, el.open ?? el.closest?.("details")?.open
  ]);
  const beforeHref = location.href;
  const beforeTitle = document.title;
  const beforeActive = document.activeElement;
  const beforeScrollX = window.scrollX;
  const beforeScrollY = window.scrollY;
  const beforeState = readState();
  const linkControl = el?.closest?.('a[href], [role="link"]') || null;
  let sawEvent = false;
  let mutated = false;
  const targetParent = el?.parentElement;
  const parentIsControl = targetParent?.matches?.('a[href], [role="link"], button, [role="button"], input, label, select, textarea, summary');
  const onEvent = (event) => {
    if (!event.isTrusted) return;
    if (watchTarget && !event.composedPath().includes(el) && !(parentIsControl && event.target === targetParent)) return;
    sawEvent = true;
    removeListeners();
  };
  const removeListeners = () => {
    for (const type of events) window.removeEventListener(type, onEvent, true);
  };
  const observer = typeof MutationObserver === "function" && document.documentElement
    ? new MutationObserver((records) => {
      // Ignore the extension's own UI becoming inert/visible or renewing its lease.
      const isIndicator = (node) => node.localName === "usemac-tab-indicator";
      if (!records.some((record) => {
        if (isIndicator(record.target)) return false;
        if (record.type !== "childList") return true;
        return [...record.addedNodes, ...record.removedNodes].some((node) => !isIndicator(node));
      })) return;
      mutated = true;
      observer.disconnect();
    })
    : null;
  const dispose = () => {
    clearTimeout(timer);
    removeListeners();
    observer?.disconnect();
    delete globalThis[key];
  };
  const timer = setTimeout(dispose, lifetimeMs);
  globalThis[key] = () => {
    try {
      const active = document.activeElement;
      const focusedClickedLink = Boolean(
        linkControl && active && (active === el || el?.contains?.(active) || active === linkControl)
      );
      return {
        sawEvent, mutated,
        stateChanged: beforeState !== readState(),
        urlChanged: beforeHref !== location.href || beforeTitle !== document.title,
        scrollChanged: beforeScrollX !== window.scrollX || beforeScrollY !== window.scrollY,
        focusChanged: beforeActive !== active && !focusedClickedLink
      };
    } finally {
      dispose();
    }
  };
  for (const type of events) window.addEventListener(type, onEvent, true);
  observer?.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
  return true;
}

function clickProbeContextLost(message) {
  return /context.*(?:destroyed|not found)|cannot find (?:execution )?context|inspected target navigated|session with given id not found/i
    .test(message || "");
}

// True when a step says where to act: a non-blank elementId, selector, match, or a full point.
function stepNamesTarget(step) {
  return stepNamesDOMTarget(step) || (Number.isFinite(step?.x) && Number.isFinite(step?.y));
}

function buildKeyDescriptor(keyName) {
  const raw = String(keyName || "");
  const lower = raw.toLowerCase();
  const special = {
    enter: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
    return: { key: "Enter", code: "Enter", keyCode: 13, text: "\r" },
    tab: { key: "Tab", code: "Tab", keyCode: 9 },
    escape: { key: "Escape", code: "Escape", keyCode: 27 },
    esc: { key: "Escape", code: "Escape", keyCode: 27 },
    backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
    delete: { key: "Delete", code: "Delete", keyCode: 46 },
    space: { key: " ", code: "Space", keyCode: 32, text: " " },
    " ": { key: " ", code: "Space", keyCode: 32, text: " " },
    arrowup: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
    up: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
    arrowdown: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
    down: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
    arrowleft: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
    left: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
    arrowright: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
    right: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
    home: { key: "Home", code: "Home", keyCode: 36 },
    end: { key: "End", code: "End", keyCode: 35 },
    pageup: { key: "PageUp", code: "PageUp", keyCode: 33 },
    pagedown: { key: "PageDown", code: "PageDown", keyCode: 34 },
    // Same names as native pressKey (Sources/UseMacEngine/NativeKeyMap.swift); NativeKeyMapTests checks both tables.
    forwarddelete: { key: "Delete", code: "Delete", keyCode: 46 },
    f1: { key: "F1", code: "F1", keyCode: 112 },
    f2: { key: "F2", code: "F2", keyCode: 113 },
    f3: { key: "F3", code: "F3", keyCode: 114 },
    f4: { key: "F4", code: "F4", keyCode: 115 },
    f5: { key: "F5", code: "F5", keyCode: 116 },
    f6: { key: "F6", code: "F6", keyCode: 117 },
    f7: { key: "F7", code: "F7", keyCode: 118 },
    f8: { key: "F8", code: "F8", keyCode: 119 },
    f9: { key: "F9", code: "F9", keyCode: 120 },
    f10: { key: "F10", code: "F10", keyCode: 121 },
    f11: { key: "F11", code: "F11", keyCode: 122 },
    f12: { key: "F12", code: "F12", keyCode: 123 }
  };

  if (special[lower]) {
    return special[lower];
  }

  if (raw.length === 1) {
    const codePoint = raw.toUpperCase().charCodeAt(0);
    const isLetter = codePoint >= 65 && codePoint <= 90;
    const isDigit = codePoint >= 48 && codePoint <= 57;
    return {
      key: raw,
      code: isLetter ? `Key${raw.toUpperCase()}` : isDigit ? `Digit${raw}` : raw,
      keyCode: codePoint,
      text: raw
    };
  }

  return { key: raw, code: raw, keyCode: 0 };
}

// The same names as native pressKey and the daemon's sensitive-shortcut check (ModifierAliases.swift);
// ModifierAliasesTests fails when the two lists differ, so a ⌘/⌃ spelling can't skip the check.
function buildModifierMask(modifiers) {
  if (!Array.isArray(modifiers)) return 0;
  let mask = 0;
  for (const mod of modifiers) {
    const m = String(mod).trim().toLowerCase();
    if (m === "alt" || m === "opt" || m === "option") mask |= 1;
    else if (m === "control" || m === "ctrl") mask |= 2;
    else if (m === "meta" || m === "command" || m === "cmd") mask |= 4;
    else if (m === "shift") mask |= 8;
  }
  return mask;
}

async function dispatchMouseClick(tabId, x, y, button = "left", count = 1) {
  // A doubleClick explicitly requests two pairs. Never repeat a pair based on the observed effect.
  for (let clickCount = 1; clickCount <= count; clickCount++) {
    await sendCDP(tabId, "Input.dispatchMouseEvent", { type: "mousePressed", x, y, button, clickCount });
    await sendCDP(tabId, "Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button, clickCount });
  }
}

function buildWaitForMutationPromiseJs({ selector = null, elementId = null, match = null, text = null, gone = false, timeoutMs = 5000 }) {
  const selLit = selector ? JSON.stringify(String(selector)) : "null";
  const elIdLit = elementId ? JSON.stringify(String(elementId)) : "null";
  const matchLit = hasNonEmptyMatch(match) ? JSON.stringify(match) : "null";
  const txtLit = text ? JSON.stringify(String(text)) : "null";
  const goneLit = gone ? "true" : "false";
  const ms = clamp(Number(timeoutMs) || 5000, 50, 30000);
  return `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const sel = ${selLit};
    const elId = ${elIdLit};
    const spec = ${matchLit};
    const txt = ${txtLit};
    const txtNorm = txt ? normalizeMatchText(txt) : null;
    const gone = ${goneLit};
    const timeoutMs = ${ms};

    function isElVisible(el) {
      if (!el || !el.isConnected) return false;
      const r = el.getBoundingClientRect();
      const st = window.getComputedStyle(el);
      return Boolean(st && st.display !== 'none' && st.visibility !== 'hidden' && parseFloat(st.opacity) !== 0 && r.width >= 2 && r.height >= 2);
    }

    function isPresent() {
      if (elId) {
        const el = findByUsemacId(elId, document);
        if (!isElVisible(el)) return false;
        if (!txtNorm) return true;
        return normalizeMatchText(el.innerText || el.textContent || el.value || '').includes(txtNorm);
      }
      if (sel) {
        const el = queryOneDeep(document, sel);
        if (!isElVisible(el)) return false;
        if (!txtNorm) return true;
        return normalizeMatchText(el.innerText || el.textContent || el.value || '').includes(txtNorm);
      }
      if (spec) {
        const roots = collectRoots(document);
        const labelMap = new Map();
        const labelNodes = queryAllInRoots(roots, 'label[for]');
        for (let i = 0; i < labelNodes.length; i++) {
          const f = labelNodes[i].getAttribute('for');
          if (f && !labelMap.has(f)) {
            const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
            if (t) labelMap.set(f, t);
          }
        }
        const candSel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
        const cands = queryAllInRoots(roots, candSel);
        const targetIndex = Math.max(0, Number(spec.index) || 0);
        let seen = 0;
        for (let i = 0; i < cands.length; i++) {
          const el = cands[i];
          if (!isElVisible(el)) continue;
          if (!matchesElementSpec(el, spec, labelMap)) continue;
          if (seen === targetIndex) {
            if (!txtNorm) return true;
            return normalizeMatchText(el.innerText || el.textContent || el.value || '').includes(txtNorm);
          }
          seen++;
        }
        return false;
      }
      if (txtNorm) {
        const roots = collectRoots(document);
        for (let r = 0; r < roots.length; r++) {
          const chunk = r === 0
            ? (document.body?.innerText || document.documentElement?.textContent || '')
            : (roots[r].textContent || '');
          if (normalizeMatchText(chunk).includes(txtNorm)) return true;
        }
        return false;
      }
      return true;
    }

    function satisfied() {
      const present = isPresent();
      return gone ? !present : present;
    }

    const started = performance.now();
    if (satisfied()) {
      return Promise.resolve({ matched: true, elapsedMs: 0 });
    }

    return new Promise((resolve) => {
      let done = false;
      let mo = null;
      let timer = null;
      let fallback = null;
      const finish = (matched) => {
        if (done) return;
        done = true;
        if (mo) try { mo.disconnect(); } catch (_) {}
        if (timer) clearTimeout(timer);
        if (fallback) clearInterval(fallback);
        resolve({ matched, elapsedMs: Math.round((performance.now() - started) * 100) / 100 });
      };
      if (typeof MutationObserver === 'function' && document.documentElement) {
        mo = new MutationObserver(() => {
          if (satisfied()) finish(true);
        });
        const obsOpts = { childList: true, subtree: true, attributes: true, characterData: true };
        try { mo.observe(document.documentElement, obsOpts); } catch (_) {}
        const roots = collectRoots(document);
        for (let i = 1; i < roots.length; i++) {
          try { mo.observe(roots[i], obsOpts); } catch (_) {}
        }
      }
      fallback = setInterval(() => {
        if (satisfied()) finish(true);
      }, 200);
      timer = setTimeout(() => finish(false), timeoutMs);
    });
  })()`;
}

async function runWaitForStep(tabId, step, cancelToken = null) {
  const timeoutMs = clamp(Number(step.timeoutMs ?? step.durationMs ?? 5000), 50, 30000);
  const gone = step.gone === true;
  const desc = step.selector || step.elementId || (hasNonEmptyMatch(step.match) ? `{${formatMatchDesc(step.match)}}` : null) || (step.text ? `"${step.text}"` : "condition");
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    if (isCancelled(tabId, cancelToken)) {
      throw CANCELLED_ERROR;
    }
    const remaining = Math.max(50, deadline - Date.now());
    const expr = buildWaitForMutationPromiseJs({
      selector: step.selector || null,
      elementId: step.elementId || null,
      match: step.match || null,
      text: step.text || null,
      gone,
      timeoutMs: remaining
    });

    const session = getOrCreateTabSession(tabId);
    const childFrames = session.lastChildFrames || [];
    const frames = [null, ...childFrames];

    // Race MutationObserver Promise(s) against cancellation without polling overhead.
    let cancelTimer = null;
    const cancelRace = new Promise((resolve) => {
      if (!cancelToken) return;
      cancelTimer = setInterval(() => {
        if (isCancelled(tabId, cancelToken)) {
          clearInterval(cancelTimer);
          cancelTimer = null;
          resolve({ cancelled: true });
        }
      }, CANCEL_POLL_SLICE_MS);
    });

    try {
      if (gone || frames.length === 1) {
        // Single frame (fast path) or gone check on top frame
        const evalPromise = evalInFrame(tabId, null, expr, { returnByValue: true, awaitPromise: true })
          .then((r) => ({ res: r?.result?.value || null }))
          .catch((err) => ({ err }));
        const outcome = await Promise.race([evalPromise, cancelRace]);
        if (outcome?.cancelled || isCancelled(tabId, cancelToken)) {
          throw CANCELLED_ERROR;
        }
        if (outcome?.res?.matched === true) {
          if (gone && childFrames.length > 0) {
            // Also verify none of the child frames still show the element
            const childCheckExpr = buildWaitForMutationPromiseJs({
              selector: step.selector || null,
              elementId: step.elementId || null,
              match: step.match || null,
              text: step.text || null,
              gone: true,
              timeoutMs: Math.max(50, deadline - Date.now())
            });
            const childChecks = await Promise.all(
              childFrames.map((f) => evalInFrame(tabId, f, childCheckExpr, { returnByValue: true, awaitPromise: true }).catch(() => null))
            );
            if (childChecks.every((c) => c?.result?.value?.matched !== false)) {
              return { mechanism: "mutation-observer", message: `${desc} is gone` };
            }
          } else {
            return {
              mechanism: "mutation-observer",
              message: gone ? `${desc} is gone` : `Matched ${desc}`
            };
          }
        }
        if (outcome?.err) {
          // Execution context may have been destroyed by a navigation: retry briefly until deadline.
          await sleepCancellable(Math.min(80, Math.max(0, deadline - Date.now())), tabId, cancelToken);
          continue;
        }
        if (outcome?.res && outcome.res.matched === false) {
          break;
        }
        // Fallback when mock sandbox returns {} (no JS evaluation)
        if (!outcome?.res) {
          break;
        }
      } else {
        // Multiple frames for appearance: resolve as soon as ANY frame's MutationObserver matches!
        const framePromises = frames.map((fMeta) =>
          evalInFrame(tabId, fMeta, expr, { returnByValue: true, awaitPromise: true })
            .then((r) => {
              if (r?.result?.value?.matched === true) {
                return { matched: true, isChild: Boolean(fMeta) };
              }
              return new Promise(() => {}); // wait for other frames or timeout
            })
            .catch(() => new Promise(() => {}))
        );
        const timeoutPromise = sleep(remaining).then(() => ({ matched: false }));
        const outcome = await Promise.race([...framePromises, timeoutPromise, cancelRace]);
        if (outcome?.cancelled || isCancelled(tabId, cancelToken)) {
          throw CANCELLED_ERROR;
        }
        if (outcome?.matched) {
          return {
            mechanism: outcome.isChild ? "mutation-observer (iframe)" : "mutation-observer",
            message: `Matched ${desc}`
          };
        }
        break;
      }
    } finally {
      if (cancelTimer) clearInterval(cancelTimer);
    }
  }

  if (isCancelled(tabId, cancelToken)) {
    throw CANCELLED_ERROR;
  }
  throw {
    code: "WAIT_TIMEOUT",
    message: `Timed out after ${timeoutMs}ms waiting for ${desc}${gone ? " to disappear" : ""}`
  };
}

async function executeAssertStep(tabId, step) {
  const session = getOrCreateTabSession(tabId);
  const tabInfo = await refreshTabMeta(tabId);
  const actualUrl = tabInfo?.url || session.url || "";
  const actualTitle = tabInfo?.title || session.title || "";
  const failures = [];
  let resolvedElementId = null;

  if (typeof step.expectUrl === "string" && step.expectUrl.trim() !== "") {
    const wanted = step.expectUrl.trim();
    if (!actualUrl.toLowerCase().includes(wanted.toLowerCase())) {
      failures.push(`Expected URL to contain "${wanted}", got "${actualUrl}"`);
    }
  }

  const needsDomCheck =
    (typeof step.expectTitle === "string" && step.expectTitle.trim() !== "") ||
    (typeof step.expectText === "string" && step.expectText.trim() !== "") ||
    (typeof step.expectNotText === "string" && step.expectNotText.trim() !== "") ||
    hasNonEmptyMatch(step.match) ||
    (typeof step.selector === "string" && step.selector.trim() !== "") ||
    (typeof step.elementId === "string" && step.elementId.trim() !== "");

  if (needsDomCheck) {
    const checkSpec = {
      expectTitle: typeof step.expectTitle === "string" ? step.expectTitle.trim() : "",
      expectText: typeof step.expectText === "string" ? step.expectText.trim() : "",
      expectNotText: typeof step.expectNotText === "string" ? step.expectNotText.trim() : "",
      selector: typeof step.selector === "string" ? step.selector.trim() : "",
      elementId: typeof step.elementId === "string" ? step.elementId.trim() : "",
      match: hasNonEmptyMatch(step.match) ? step.match : null
    };
    const specLit = JSON.stringify(checkSpec);
    const frameCheckExpr = `(() => {
      ${QUERY_DEEP_HELPER_JS}
      const s = ${specLit};
      const title = document.title || '';
      const roots = collectRoots(document);
      const textParts = [document.body?.innerText || document.documentElement?.textContent || ''];
      for (let r = 1; r < roots.length; r++) {
        if (roots[r]?.textContent) textParts.push(roots[r].textContent);
      }
      const bodyNorm = normalizeMatchText(textParts.join(' '));
      const hasExpectText = s.expectText ? bodyNorm.includes(normalizeMatchText(s.expectText)) : null;
      const hasNotText = s.expectNotText ? bodyNorm.includes(normalizeMatchText(s.expectNotText)) : null;

      function isElVisible(el) {
        if (!el || !el.isConnected) return false;
        const r = el.getBoundingClientRect();
        const st = window.getComputedStyle(el);
        return Boolean(st && st.display !== 'none' && st.visibility !== 'hidden' && parseFloat(st.opacity) !== 0 && r.width >= 2 && r.height >= 2);
      }

      let elementFound = null;
      let elementId = null;
      if (s.elementId || s.selector || s.match) {
        let hit = null;
        if (s.elementId) {
          const el = findByUsemacId(s.elementId, document);
          if (isElVisible(el)) hit = el;
        } else if (s.selector) {
          const el = queryOneDeep(document, s.selector);
          if (isElVisible(el)) hit = el;
        } else if (s.match) {
          const roots = collectRoots(document);
          const labelMap = new Map();
          const labelNodes = queryAllInRoots(roots, 'label[for]');
          for (let i = 0; i < labelNodes.length; i++) {
            const f = labelNodes[i].getAttribute('for');
            if (f && !labelMap.has(f)) {
              const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
              if (t) labelMap.set(f, t);
            }
          }
          const candSel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
          const cands = queryAllInRoots(roots, candSel);
          const idx = Math.max(0, Number(s.match.index) || 0);
          let seen = 0;
          for (let i = 0; i < cands.length; i++) {
            if (!isElVisible(cands[i])) continue;
            if (!matchesElementSpec(cands[i], s.match, labelMap)) continue;
            if (seen === idx) { hit = cands[i]; break; }
            seen++;
          }
        }
        elementFound = Boolean(hit);
        if (hit) {
          const reg = getUsemacRefRegistry(1);
          elementId = lookupUsemacNodeId(hit, reg) || hit.getAttribute('data-usemac-id') || null;
        }
      }
      return { title, hasExpectText, hasNotText, elementFound, elementId };
    })()`;

    const frames = [null, ...(session.lastChildFrames || [])];
    const results = await Promise.all(
      frames.map((f) => evalInFrame(tabId, f, frameCheckExpr).then((r) => r?.result?.value || null).catch(() => null))
    );
    const topRes = results[0];
    const docTitle = topRes?.title || actualTitle;

    if (checkSpec.expectTitle) {
      if (!docTitle.toLowerCase().includes(checkSpec.expectTitle.toLowerCase())) {
        failures.push(`Expected title to contain "${checkSpec.expectTitle}", got "${docTitle}"`);
      }
    }
    if (checkSpec.expectText) {
      const foundText = results.some((r) => r?.hasExpectText === true);
      if (!foundText) {
        failures.push(`Expected text "${checkSpec.expectText}" not found on page`);
      }
    }
    if (checkSpec.expectNotText) {
      const foundForbidden = results.some((r) => r?.hasNotText === true);
      if (foundForbidden) {
        failures.push(`Unexpected text "${checkSpec.expectNotText}" was found on page`);
      }
    }
    if (checkSpec.elementId || checkSpec.selector || checkSpec.match) {
      const hitRes = results.find((r) => r?.elementFound === true) || null;
      const found = Boolean(hitRes);
      if (hitRes?.elementId) resolvedElementId = hitRes.elementId;
      const desc = checkSpec.selector || checkSpec.elementId || `{${formatMatchDesc(checkSpec.match)}}`;
      if (step.gone === true) {
        if (found) failures.push(`Expected element ${desc} to be gone, but it is still visible`);
      } else {
        if (!found) failures.push(`Expected element ${desc} not found`);
      }
    }
  }

  if (failures.length > 0) {
    throw { code: "ASSERTION_FAILED", message: failures.join("; ") };
  }
  return {
    mechanism: "cdp-assert",
    message: "Assertion passed",
    resolvedElementId
  };
}

async function executeScrollUntilStep(tabId, step, cancelToken = null) {
  const session = getOrCreateTabSession(tabId);
  const maxScrolls = clamp(Number(step.maxScrolls) || 8, 1, 30);
  const deltaY = Number.isFinite(Number(step.deltaY)) && Number(step.deltaY) !== 0
    ? Number(step.deltaY)
    : (Number.isFinite(Number(step.deltaX)) && Number(step.deltaX) !== 0 ? 0 : 600);
  const deltaX = Number.isFinite(Number(step.deltaX)) ? Number(step.deltaX) : 0;

  const checkSpec = {
    elementId: typeof step.elementId === "string" ? step.elementId.trim() : "",
    selector: typeof step.selector === "string" ? step.selector.trim() : "",
    match: hasNonEmptyMatch(step.match) ? step.match : null,
    text: typeof step.text === "string" ? step.text.trim() : ""
  };
  if (!checkSpec.elementId && !checkSpec.selector && !checkSpec.match && !checkSpec.text) {
    throw { code: "INVALID_REQUEST", message: "scrollUntil requires match, selector, elementId, or text." };
  }
  const specLit = JSON.stringify(checkSpec);
  const desc = checkSpec.selector || checkSpec.elementId || (checkSpec.match ? `{${formatMatchDesc(checkSpec.match)}}` : `"${checkSpec.text}"`);

  const probeInViewportExpr = `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const s = ${specLit};
    const vw = window.innerWidth || 1280;
    const vh = window.innerHeight || 800;
    const sx = window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0;
    const sy = window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0;

    function isVisibleInViewport(el) {
      if (!el || !el.isConnected) return false;
      const st = window.getComputedStyle(el);
      if (!st || st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return false;
      return r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw;
    }

    let hit = null;
    if (s.elementId) {
      const el = findByUsemacId(s.elementId, document);
      if (isVisibleInViewport(el)) hit = el;
    } else if (s.selector) {
      const el = queryOneDeep(document, s.selector);
      if (isVisibleInViewport(el)) hit = el;
    } else if (s.match) {
      const roots = collectRoots(document);
      const labelMap = new Map();
      const labelNodes = queryAllInRoots(roots, 'label[for]');
      for (let i = 0; i < labelNodes.length; i++) {
        const f = labelNodes[i].getAttribute('for');
        if (f && !labelMap.has(f)) {
          const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
          if (t) labelMap.set(f, t);
        }
      }
      const candSel = 'a[href], button, input, textarea, select, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="switch"], [role="radio"], [role="combobox"], [role="listbox"], [role="option"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="treeitem"], [role="slider"], [role="spinbutton"], [role="textbox"], [role="searchbox"], [contenteditable="true"], summary, h1, h2, h3';
      const cands = queryAllInRoots(roots, candSel);
      const idx = Math.max(0, Number(s.match.index) || 0);
      let seen = 0;
      for (let i = 0; i < cands.length; i++) {
        if (!matchesElementSpec(cands[i], s.match, labelMap)) continue;
        if (seen === idx) {
          if (isVisibleInViewport(cands[i])) hit = cands[i];
          break;
        }
        seen++;
      }
    } else if (s.text) {
      const needle = normalizeMatchText(s.text);
      const all = document.querySelectorAll('h1, h2, h3, h4, p, a, button, li, td, th, span, div, label, [role="row"], [role="gridcell"]');
      for (let i = 0; i < all.length && i < 1200; i++) {
        const el = all[i];
        if (!isVisibleInViewport(el)) continue;
        if (el.children.length > 6) continue;
        if (normalizeMatchText(el.innerText || el.textContent || '').includes(needle)) {
          hit = el;
          break;
        }
      }
    }

    let id = null;
    if (hit) {
      const reg = getUsemacRefRegistry(1);
      id = assignUsemacNodeId(hit, reg);
      if (hit.getAttribute && hit.getAttribute('data-usemac-id') !== id) hit.setAttribute('data-usemac-id', id);
    }
    return { found: Boolean(hit), id, scrollX: sx, scrollY: sy };
  })()`;

  const vp = effectiveViewport(session);
  const scrollXPt = Number.isFinite(step.x) ? Number(step.x) : Math.round(vp.width / 2);
  const scrollYPt = Number.isFinite(step.y) ? Number(step.y) : Math.round(vp.height / 2);
  let totalDeltaX = 0;
  let totalDeltaY = 0;

  for (let i = 0; i <= maxScrolls; i++) {
    await waitIfTabUserPaused(tabId, cancelToken);
    const probeRes = await evalInFrame(tabId, null, probeInViewportExpr).catch(() => null);
    const probe = probeRes?.result?.value;
    if (probe?.found) {
      if (probe.id) {
        session.elementFrameMap.set(probe.id, {
          sessionId: null, contextId: null, frameId: null, parentSessionId: null,
          offsetX: 0, offsetY: 0, isOOPIF: false, hops: []
        });
      }
      return {
        mechanism: "cdp-scroll-until",
        message: `Found ${desc} after ${i} scroll(s)`,
        scrollDeltaX: totalDeltaX,
        scrollDeltaY: totalDeltaY,
        resolvedElementId: probe.id || null
      };
    }
    if (i === maxScrolls) break;

    const beforeX = probe?.scrollX ?? 0;
    const beforeY = probe?.scrollY ?? 0;
    await sendCDP(tabId, "Input.dispatchMouseEvent", {
      type: "mouseWheel",
      x: scrollXPt,
      y: scrollYPt,
      deltaX,
      deltaY
    });
    await waitForAnimationFrames(tabId, 40);

    const afterRes = await evalInFrame(tabId, null, `({
      scrollX: window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0,
      scrollY: window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0
    })`).catch(() => null);
    const after = afterRes?.result?.value;
    if (after) {
      const dx = Math.round((after.scrollX - beforeX) * 10) / 10;
      const dy = Math.round((after.scrollY - beforeY) * 10) / 10;
      totalDeltaX += dx;
      totalDeltaY += dy;
      // Hit end of scroll (no movement)
      if (Math.abs(dx) < 2 && Math.abs(dy) < 2) {
        // One final check in case an inner scrollable container moved instead of window
        const finalProbe = await evalInFrame(tabId, null, probeInViewportExpr).catch(() => null);
        if (finalProbe?.result?.value?.found) {
          return {
            mechanism: "cdp-scroll-until",
            message: `Found ${desc} after ${i + 1} scroll(s)`,
            scrollDeltaX: totalDeltaX,
            scrollDeltaY: totalDeltaY,
            resolvedElementId: finalProbe.result.value.id || null
          };
        }
        throw {
          code: "ELEMENT_NOT_FOUND",
          message: `scrollUntil reached end of scroll after ${i + 1} scroll(s) without finding ${desc}`
        };
      }
    }
  }

  throw {
    code: "ELEMENT_NOT_FOUND",
    message: `scrollUntil did not find ${desc} within ${maxScrolls} scroll(s)`
  };
}

async function executeFillFormStep(tabId, step, cancelToken = null) {
  const fields = Array.isArray(step.fields) ? step.fields : [];
  if (fields.length === 0) {
    throw { code: "INVALID_REQUEST", message: "fillForm requires a non-empty 'fields' array." };
  }

  const session = getOrCreateTabSession(tabId);
  const childFrames = session.lastChildFrames || [];
  const candidateFrames = [null, ...childFrames];
  const filledSummaries = [];
  const fieldErrors = [];

  for (let fi = 0; fi < fields.length; fi++) {
    await waitIfTabUserPaused(tabId, cancelToken);
    const field = fields[fi];
    if (!field || typeof field !== "object") continue;
    const fieldDesc = field.label || field.selector || field.elementId || (hasNonEmptyMatch(field.match) ? formatMatchDesc(field.match) : `field[${fi}]`);
    const fieldLit = JSON.stringify(field);

    let outcome = null;
    for (const fMeta of candidateFrames) {
      const res = await evalAgentInputInFrame(tabId, fMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const f = ${fieldLit};
        const roots = collectRoots(document);
        const labelMap = new Map();
        const labelNodes = queryAllInRoots(roots, 'label[for]');
        for (let i = 0; i < labelNodes.length; i++) {
          const forId = labelNodes[i].getAttribute('for');
          if (forId && !labelMap.has(forId)) {
            const t = (labelNodes[i].innerText || labelNodes[i].textContent || '').replace(/\\s+/g, ' ').trim();
            if (t) labelMap.set(forId, t);
          }
        }

        function isInteractable(el) {
          if (!el || !el.isConnected) return false;
          const st = window.getComputedStyle(el);
          if (!st || st.display === 'none' || st.visibility === 'hidden') return false;
          const r = el.getBoundingClientRect();
          return r.width >= 2 && r.height >= 2;
        }

        function findControl() {
          if (f.elementId && String(f.elementId).trim()) {
            const el = findByUsemacId(String(f.elementId).trim(), document);
            if (el) return el;
          }
          if (f.selector && String(f.selector).trim()) {
            const el = queryOneDeep(document, String(f.selector).trim());
            if (el) return el;
          }
          const controlSel = 'input, textarea, select, [contenteditable="true"], [role="combobox"], [role="textbox"], [role="searchbox"], [role="checkbox"], [role="switch"], [role="radio"], [aria-haspopup="listbox"]';
          const controls = queryAllInRoots(roots, controlSel);
          if (f.match && typeof f.match === 'object') {
            const idx = Math.max(0, Number(f.match.index) || 0);
            let seen = 0;
            for (let i = 0; i < controls.length; i++) {
              if (!isInteractable(controls[i])) continue;
              if (!matchesElementSpec(controls[i], f.match, labelMap)) continue;
              if (seen === idx) return controls[i];
              seen++;
            }
          }
          if (f.label && String(f.label).trim()) {
            const targetNorm = normalizeMatchText(f.label);
            let best = null;
            let bestScore = 0;
            for (let i = 0; i < controls.length; i++) {
              const c = controls[i];
              if (!isInteractable(c)) continue;
              const info = extractElementTitleValue(c, labelMap);
              const cands = [
                info.title,
                c.getAttribute?.('aria-label') || '',
                c.getAttribute?.('placeholder') || '',
                c.getAttribute?.('name') || '',
                c.id ? (labelMap.get(c.id) || '') : ''
              ];
              for (const cand of cands) {
                const n = normalizeMatchText(cand);
                if (!n) continue;
                if (n === targetNorm) return c;
                if (n.includes(targetNorm) && bestScore < 2) { best = c; bestScore = 2; }
                else if (targetNorm.includes(n) && n.length >= 3 && bestScore < 1) { best = c; bestScore = 1; }
              }
            }
            if (best) return best;
          }
          return null;
        }

        const el = findControl();
        if (!el) return { found: false };

        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const tag = (el.tagName || '').toLowerCase();
        const ariaRole = (el.getAttribute?.('role') || '').toLowerCase();
        const isCombobox = ariaRole === 'combobox' || el.getAttribute?.('aria-haspopup') === 'listbox';

        if (isCombobox && tag !== 'select') {
          el.focus();
          el.click();
          const wantedVal = f.value != null ? String(f.value) : '';
          if (wantedVal) {
            const filterInput = tag === 'input' ? el : el.querySelector?.('input');
            if (filterInput) {
              const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
              if (setter) setter.call(filterInput, wantedVal);
              else filterInput.value = wantedVal;
              filterInput.dispatchEvent(new Event('input', { bubbles: true }));
            }
          }
          return { found: true, kind: 'combobox', wanted: wantedVal };
        }

        if (tag === 'select') {
          const wanted = String(f.value ?? '').trim();
          const wantedLower = wanted.toLowerCase();
          const opts = Array.from(el.options || []);
          const opt =
            opts.find((o) => o.value === wanted) ||
            opts.find((o) => (o.value || '').toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase().includes(wantedLower));
          if (!opt) {
            const sample = opts.slice(0, 10).map((o) => (o.text || o.value || '').trim()).join(', ');
            return { found: true, ok: false, error: 'No matching <option> for "' + wanted + '" (available: ' + sample + ')' };
          }
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set;
          if (setter) setter.call(el, opt.value);
          else el.value = opt.value;
          opt.selected = true;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { found: true, ok: true, kind: 'select', detail: (opt.text || opt.value).trim() };
        }

        const isCheckable =
          (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) ||
          ariaRole === 'checkbox' || ariaRole === 'switch' || ariaRole === 'radio';
        if (isCheckable) {
          let desired;
          if (typeof f.checked === 'boolean') {
            desired = f.checked;
          } else {
            const lower = String(f.value ?? 'true').trim().toLowerCase();
            desired = ['true', 'checked', 'on', '1', 'yes'].includes(lower);
          }
          const current = tag === 'input' ? Boolean(el.checked) : el.getAttribute('aria-checked') === 'true';
          if (current !== desired) el.click();
          const finalState = tag === 'input' ? Boolean(el.checked) : el.getAttribute('aria-checked') === 'true';
          return { found: true, ok: true, kind: 'check', detail: 'checked=' + finalState };
        }

        const valStr = String(f.value ?? '');
        el.focus();
        if (tag === 'textarea' || tag === 'input') {
          const proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) setter.call(el, valStr);
          else el.value = valStr;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.dispatchEvent(new Event('blur', { bubbles: false }));
          return { found: true, ok: true, kind: tag, detail: valStr.length + ' chars' };
        }
        if (el.isContentEditable) {
          el.textContent = valStr;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { found: true, ok: true, kind: 'contenteditable', detail: valStr.length + ' chars' };
        }
        return { found: true, ok: false, error: 'Unsupported form control: ' + tag };
      })()`).catch(() => null);

      const v = res?.result?.value;
      if (v?.found) {
        outcome = { ...v, frameMeta: fMeta };
        break;
      }
    }

    if (!outcome) {
      fieldErrors.push(`Field "${fieldDesc}" not found`);
      continue;
    }

    if (outcome.kind === "combobox") {
      await waitIfTabUserPaused(tabId, cancelToken);
      // Wait via MutationObserver Promise (up to 350ms) for [role="option"] to appear, then click the matching option.
      const wantedLit = JSON.stringify(outcome.wanted || "");
      const comboRes = await evalAgentInputInFrame(tabId, outcome.frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const wantedNorm = normalizeMatchText(${wantedLit});
        function findOption() {
          const roots = collectRoots(document);
          const opts = queryAllInRoots(roots, '[role="option"], [role="listbox"] li');
          let partial = null;
          for (let i = 0; i < opts.length; i++) {
            const o = opts[i];
            const st = window.getComputedStyle(o);
            if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
            const r = o.getBoundingClientRect();
            if (r.width < 2 || r.height < 2) continue;
            const txt = normalizeMatchText(o.innerText || o.textContent || o.getAttribute('aria-label') || '');
            if (!wantedNorm || txt === wantedNorm) return o;
            if (!partial && txt.includes(wantedNorm)) partial = o;
          }
          return partial;
        }
        const immediate = findOption();
        if (immediate) {
          immediate.click();
          return Promise.resolve({ ok: true, detail: (immediate.innerText || immediate.textContent || '').trim() });
        }
        return new Promise((resolve) => {
          let done = false;
          let mo = null;
          const finish = (res) => {
            if (done) return;
            done = true;
            if (mo) try { mo.disconnect(); } catch (_) {}
            clearTimeout(timer);
            resolve(res);
          };
          if (typeof MutationObserver === 'function' && document.documentElement) {
            mo = new MutationObserver(() => {
              const hit = findOption();
              if (hit) {
                hit.click();
                finish({ ok: true, detail: (hit.innerText || hit.textContent || '').trim() });
              }
            });
            mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
          }
          const timer = setTimeout(() => {
            const hit = findOption();
            if (hit) {
              hit.click();
              finish({ ok: true, detail: (hit.innerText || hit.textContent || '').trim() });
            } else {
              finish({ ok: false, error: 'No [role="option"] matched "' + ${wantedLit} + '"' });
            }
          }, 350);
        });
      })()`, { returnByValue: true, awaitPromise: true }).catch(() => null);
      const cv = comboRes?.result?.value;
      if (cv?.ok) {
        filledSummaries.push(`${fieldDesc}=${cv.detail}`);
      } else {
        fieldErrors.push(`${fieldDesc}: ${cv?.error || "combobox option not found"}`);
      }
      continue;
    }

    if (outcome.ok === false) {
      fieldErrors.push(`${fieldDesc}: ${outcome.error || "failed"}`);
    } else {
      filledSummaries.push(`${fieldDesc}`);
    }
  }

  // Optional submit action
  if (fieldErrors.length === 0 && (hasNonEmptyMatch(step.submitMatch) || (typeof step.submitSelector === "string" && step.submitSelector.trim() !== ""))) {
    await waitIfTabUserPaused(tabId, cancelToken);
    const submitStep = {
      action: "click",
      match: hasNonEmptyMatch(step.submitMatch) ? step.submitMatch : undefined,
      selector: typeof step.submitSelector === "string" && step.submitSelector.trim() !== "" ? step.submitSelector.trim() : undefined
    };
    await executeActionStep(tabId, submitStep, cancelToken);
  } else {
    await waitForAnimationFrames(tabId, 40);
  }

  // Automatically surface HTML5 validation errors, aria-invalid fields, and visible alerts
  const validationRes = await evalInFrame(tabId, null, `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const roots = collectRoots(document);
    const errors = [];
    const seen = new Set();
    const pushErr = (s) => {
      const clean = String(s || '').replace(/\\s+/g, ' ').trim().slice(0, 160);
      if (clean && !seen.has(clean)) { seen.add(clean); errors.push(clean); }
    };
    const invalids = queryAllInRoots(roots, ':invalid, [aria-invalid="true"]');
    for (let i = 0; i < invalids.length && errors.length < 10; i++) {
      const el = invalids[i];
      const tag = (el.tagName || '').toLowerCase();
      if (tag === 'form' || tag === 'fieldset') continue;
      const name = el.getAttribute('aria-label') || el.getAttribute('name') || el.getAttribute('placeholder') || el.id || tag;
      let msg = el.validationMessage || '';
      const errId = el.getAttribute('aria-errormessage') || el.getAttribute('aria-describedby');
      if (!msg && errId) {
        msg = errId.split(/\\s+/).map((id) => document.getElementById(id)?.innerText || '').filter(Boolean).join(' ');
      }
      if (msg) pushErr(name + ': ' + msg);
      else if (el.getAttribute('aria-invalid') === 'true') pushErr(name + ': invalid');
    }
    const alerts = queryAllInRoots(roots, '[role="alert"], [aria-live="assertive"]');
    for (let i = 0; i < alerts.length && errors.length < 12; i++) {
      const a = alerts[i];
      const st = window.getComputedStyle(a);
      if (!st || st.display === 'none' || st.visibility === 'hidden') continue;
      const txt = (a.innerText || a.textContent || '').trim();
      if (txt) pushErr('alert: ' + txt);
    }
    return errors;
  })()`).catch(() => null);
  const validationErrors = Array.isArray(validationRes?.result?.value) ? validationRes.result.value : [];

  if (fieldErrors.length > 0) {
    const detail = validationErrors.length > 0 ? `; validation: ${validationErrors.join(" | ")}` : "";
    throw { code: "FORM_FILL_FAILED", message: `${fieldErrors.join("; ")}${detail}` };
  }

  const msgParts = [`Filled ${filledSummaries.length} field(s)`];
  if (validationErrors.length > 0) {
    msgParts.push(`validationErrors=[${validationErrors.join(" | ")}]`);
  }
  return {
    mechanism: "cdp-fill-form",
    message: msgParts.join(" · "),
    blockedWarning: validationErrors.length > 0 ? `Form validation errors: ${validationErrors.join(" | ")}` : null
  };
}
