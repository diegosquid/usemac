// Action step execution and download correlation for clicks.

function beginDownloadClick(tabId, tabUrl) {
  const click = {
    tabId,
    origin: httpDownloadOrigin(tabUrl),
    startedAt: Date.now(),
    creationSequence: state.downloadCreationSequence,
    allowOriginFallback: true
  };
  for (const other of state.activeDownloadClicks) {
    if (other.tabId === tabId) continue;
    click.allowOriginFallback = false;
    other.allowOriginFallback = false;
  }
  state.activeDownloadClicks.add(click);
  return click;
}

function clickDownloads(click, endSequence = Infinity) {
  const associated = [];
  const sameOrigin = [];
  for (const download of state.downloads.values()) {
    if (download.createdAt == null || download.createdAt < click.startedAt ||
        download.creationSequence <= click.creationSequence || download.creationSequence > endSequence) continue;
    const associatedTab = state.downloadTabById.get(download.id);
    if (associatedTab === click.tabId) {
      associated.push(download);
    } else if (associatedTab == null && click.allowOriginFallback && downloadMatchesOrigin(download, click.origin)) {
      sameOrigin.push(download);
    }
  }
  return associated.concat(sameOrigin);
}

function isValidLocalDownloadPath(path) {
  return typeof path === "string" && /^(?:\/(?!\/)|~\/|[A-Za-z]:\\)/.test(path);
}

function completedDownloadPath(download) {
  return download?.state === "complete" && isValidLocalDownloadPath(download.filename) ? download.filename : null;
}

// Evaluated in the frame containing both endpoints, including open shadow roots.
function inspectOrDispatchDOMDrag(sourceEl, destinationEl, dispatch) {
  if (!sourceEl || !destinationEl) return { missing: true };
  const draggable = sourceEl.draggable === true ? sourceEl : sourceEl.closest('[draggable="true"]');
  const center = (el) => {
    const rect = el.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  };
  const source = center(sourceEl);
  const destination = center(destinationEl);
  if (!dispatch || draggable?.draggable !== true) {
    return { source, destination, html5: draggable?.draggable === true };
  }

  const dataTransfer = new DataTransfer();
  const events = (point, buttons) => ({
    clientX: point.x, clientY: point.y, button: 0, buttons,
    bubbles: true, cancelable: true, composed: true
  });
  const start = events(source, 1);
  const end = events(destination, 0);
  const pointer = { pointerId: 1, pointerType: "mouse", isPrimary: true };
  sourceEl.dispatchEvent(new PointerEvent("pointerdown", { ...start, ...pointer }));
  sourceEl.dispatchEvent(new MouseEvent("mousedown", start));
  draggable.dispatchEvent(new DragEvent("dragstart", { ...start, dataTransfer }));
  destinationEl.dispatchEvent(new DragEvent("dragenter", { ...events(destination, 1), dataTransfer }));
  destinationEl.dispatchEvent(new DragEvent("dragover", { ...events(destination, 1), dataTransfer }));
  destinationEl.dispatchEvent(new DragEvent("drop", { ...end, dataTransfer }));
  draggable.dispatchEvent(new DragEvent("dragend", { ...end, dataTransfer }));
  destinationEl.dispatchEvent(new PointerEvent("pointerup", { ...end, ...pointer }));
  destinationEl.dispatchEvent(new MouseEvent("mouseup", end));
  return { html5: true };
}

async function executeDragStep(tabId, step, cancelToken) {
  const destinationStep = dragDestinationStep(step);
  if (!stepNamesTarget(step)) {
    throw { code: "INVALID_REQUEST", message: "drag requires a source: pass elementId, selector, match, or both x and y." };
  }
  if (!stepNamesTarget(destinationStep)) {
    throw { code: "INVALID_REQUEST", message: "drag requires a destination: pass toElementId, toSelector, toMatch, or both toX and toY." };
  }
  let source = await resolveStepTarget(tabId, step);
  const destination = await resolveDragDestination(tabId, step);
  const frame = source.frameMeta;
  const bothElements = stepNamesDOMTarget(step) && stepNamesDOMTarget(destinationStep);
  const sameFrame = bothElements
    && (frame?.frameId ?? null) === (destination.frameMeta?.frameId ?? null)
    && (frame?.sessionId ?? null) === (destination.frameMeta?.sessionId ?? null);
  const sourceLocator = { elementId: source.elementId, selector: step.selector?.trim?.() };
  const inspect = (dispatch) => `(() => {
    ${QUERY_DEEP_HELPER_JS}
    const source = ${findElementExprJs(sourceLocator)};
    const destination = ${findElementExprJs({ elementId: destination.elementId, selector: step.toSelector?.trim?.() })};
    return (${inspectOrDispatchDOMDrag.toString()})(source, destination, ${dispatch});
  })()`;
  const readDragResult = (result) => {
    if (result?.exceptionDetails) throw new Error("Could not inspect or dispatch HTML5 drag events.");
    const value = result?.result?.value;
    if (!value || value.missing) {
      throw { code: "ELEMENT_NOT_FOUND", message: "The drag source or destination no longer exists." };
    }
    return value;
  };
  let html5 = false;
  if (sameFrame) {
    const current = readDragResult(await evalInFrame(tabId, frame, inspect(false)));
    // Resolving the destination may have scrolled the document. Use both centers from the same layout.
    const offset = await computeFrameViewportRect(tabId, frame);
    if (!offset.visible) throw { code: "ELEMENT_NOT_FOUND", message: "The drag frame is no longer visible." };
    for (const [target, point] of [[source, current.source], [destination, current.destination]]) {
      target.x = point.x + offset.x;
      target.y = point.y + offset.y;
    }
    html5 = current.html5;
  } else if (bothElements) {
    // Destination scrolling can move the source's frame. Re-read without scrolling it back into place.
    source = await resolveInSpecificFrame(tabId, frame, sourceLocator, false, false);
    if (!source) throw { code: "ELEMENT_NOT_FOUND", message: "The drag source is no longer visible." };
  }
  const duration = clamp(step.durationMs ?? 160, 40, 2000);
  const session = getOrCreateTabSession(tabId);
  const input = beginTabIndicatorAgentInput(tabId, "pointer");
  let point = { x: source.x, y: source.y };
  let pressed = false;
  const dispatchMouse = (type, params) =>
    sendCDP(tabId, "Input.dispatchMouseEvent", { type, ...point, ...params });
  try {
    if (isCancelled(tabId, cancelToken)) throw CANCELLED_ERROR;
    if (!html5) await dispatchMouse("mouseMoved", { button: "none" });
    session.cursor = point;
    emitCursor(tabId, point.x, point.y, "down", "drag");
    if (!html5) {
      pressed = true;
      await dispatchMouse("mousePressed", { button: "left", buttons: 1, clickCount: 1 });
    }
    for (let i = 1; i <= 8; i++) {
      await sleepCancellable(duration / 8, tabId, cancelToken);
      point = {
        x: source.x + (destination.x - source.x) * i / 8,
        y: source.y + (destination.y - source.y) * i / 8
      };
      session.cursor = point;
      emitCursor(tabId, point.x, point.y, "move", "drag");
      if (!html5) await dispatchMouse("mouseMoved", { button: "left", buttons: 1 });
    }
    if (html5) {
      const result = readDragResult(await evalAgentInputInFrame(tabId, frame, inspect(true)));
      if (!result.html5) throw new Error("The drag source is no longer draggable.");
    } else {
      await dispatchMouse("mouseReleased", { button: "left", buttons: 0, clickCount: 1 });
      pressed = false;
    }
    return { mechanism: html5 ? "dom-html5-drag" : "cdp-mouse-drag", resolvedElementId: source.elementId };
  } finally {
    if (pressed) {
      await dispatchMouse("mouseReleased", { button: "left", buttons: 0, clickCount: 1 }).catch(() => {});
    }
    emitCursor(tabId, point.x, point.y, "up", "drop");
    endTabIndicatorAgentInput(tabId, "pointer", input);
  }
}

async function executeActionStep(tabId, step, cancelToken = null, batchClicks = null) {
  const action = step.action;

  if (action === "openURL" || action === "navigate") {
    const targetUrl = step.url || step.text;
    if (!targetUrl) {
      throw new Error(`${action} requires url.`);
    }
    assertAllowedUrl(targetUrl);
    await chrome.tabs.update(tabId, { url: targetUrl });
    await waitForTabLoad(tabId, 3500);
    return { mechanism: "tabs-update", message: null };
  }

  if (action === "assert") {
    return executeAssertStep(tabId, step);
  }

  if (action === "scrollUntil") {
    return executeScrollUntilStep(tabId, step, cancelToken);
  }

  if (action === "fillForm") {
    return executeFillFormStep(tabId, step, cancelToken);
  }

  if (action === "waitFor") {
    return runWaitForStep(tabId, step, cancelToken);
  }

  if (action === "drag") {
    return executeDragStep(tabId, step, cancelToken);
  }

  if (action === "scrollIntoView") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw { code: "ELEMENT_NOT_FOUND", message: "scrollIntoView requires elementId, selector, or match." };
    }
    return {
      mechanism: "cdp-scroll-into-view",
      message: target.label || null,
      resolvedElementId: target.elementId || null
    };
  }

  if (action === "click" || action === "doubleClick" || action === "rightClick") {
    const session = getOrCreateTabSession(tabId);
    const elementId = typeof step.elementId === "string" ? step.elementId.trim() : "";
    const selector = typeof step.selector === "string" ? step.selector.trim() : "";
    const hasDomTarget = Boolean(elementId || selector || hasNonEmptyMatch(step.match));
    if (hasDomTarget) {
      const tab = await refreshTabMeta(tabId);
      if (session.navigating || tab?.status === "loading") await waitForTabLoad(tabId, 1200);
    }
    let target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error(`${action} requires elementId, selector, match, or (x, y).`);
    }
    const resolvedElementId = target.elementId || null;
    const lookupExpr = findElementExprJs({ elementId: resolvedElementId, selector });
    const label =
      action === "doubleClick"
        ? "Double-clicking"
        : action === "rightClick"
          ? "Right-clicking"
          : target.label
            ? `Clicking ${target.label}`
            : "Clicking";
    const targetDocumentId = session.documentId;
    let pt = await moveCursorSmoothly(tabId, target.x, target.y, label);
    if (hasDomTarget) {
      // Both scrollIntoView and pointer hover can move the element. Recheck after both have settled.
      await waitForAnimationFrames(tabId, 40);
      await waitIfTabUserPaused(tabId, cancelToken);
      target = await refreshClickTargetPoint(tabId, target, lookupExpr);
      if (target.fullyObstructed || target.frameObstructedBy) {
        const who = target.frameObstructedBy || target.obstructedBy || "an unknown element";
        return {
          mechanism: "cdp-mouse (obstructed)",
          message: null,
          effect: "none",
          warning: `Skipped click because the target is completely covered by ${who}. Dismiss the overlay or observe again before retrying.`,
          resolvedElementId
        };
      }
      // Do not clamp a hit-tested point to a possibly stale viewport and send the click somewhere else.
      pt = { x: target.x, y: target.y };
      session.cursor = pt;
    }
    emitCursor(tabId, pt.x, pt.y, "click", label);

    const frameMeta = hasDomTarget ? target.frameMeta : findChildFrameAtPoint(session, pt.x, pt.y);
    const pointX = pt.x - (frameMeta?.offsetX || 0);
    const pointY = pt.y - (frameMeta?.offsetY || 0);
    const probeKey = JSON.stringify("__usemacClickProbe_" + crypto.randomUUID());
    const probeDeadline = Date.now() + clickProbeLifetimeMs;
    const setup = await evalInFrame(tabId, frameMeta, `(() => {
      ${hasDomTarget ? QUERY_DEEP_HELPER_JS : ""}
      const el = ${hasDomTarget ? lookupExpr : `(${clickHitAtPoint.toString()})(document, ${pointX}, ${pointY})`};
      if (${hasDomTarget} && !el) return { missing: true };
      if (${!hasDomTarget} && (el?.localName === 'iframe' || el?.localName === 'frame')) return null;
      return {
        installed: (${installClickProbe.toString()})(${probeKey}, el, ${hasDomTarget}, ${clickProbeLifetimeMs}),
        isLink: Boolean(el?.closest?.('a[href], [role="link"]'))
      };
    })()`).catch((err) => {
      if (hasDomTarget && clickProbeContextLost(String(err?.message || err))) throw err;
      return null;
    });
    const { installed = false, isLink = target.isLink, missing = false } = setup?.result?.value || {};
    if (missing) {
      throw { code: "ELEMENT_NOT_FOUND", message: "The click target disappeared before dispatch. Observe again before retrying." };
    }
    const beforeUrl = session.url || "";
    const beforeDocumentId = session.documentId;
    const beforeNetSeq = session.networkRequestSeq || 0;
    session.navigating = false;
    const click = beginDownloadClick(tabId, beforeUrl);
    batchClicks?.push(click);
    try {
      let probe = null;
      let lostContext = false;
      try {
        if (isCancelled(tabId, cancelToken)) throw CANCELLED_ERROR;
        if (hasDomTarget && session.documentId !== targetDocumentId) {
          throw { code: "ELEMENT_NOT_FOUND", message: "The page changed before the click. Observe again before retrying." };
        }
        await dispatchMouseClick(tabId, pt.x, pt.y, action === "rightClick" ? "right" : "left", action === "doubleClick" ? 2 : 1);
        await waitForAnimationFrames(tabId, 40);
      } finally {
        if (installed) {
          try {
            const result = await evalInFrame(tabId, frameMeta, `globalThis[${probeKey}]?.() ?? null`);
            probe = result?.result?.value;
            // Runtime.evaluate without an explicit context can succeed in a new document instead of throwing.
            lostContext = (probe === null && Date.now() < probeDeadline) ||
              clickProbeContextLost(result?.exceptionDetails?.exception?.description || result?.exceptionDetails?.text);
          } catch (err) {
            lostContext = clickProbeContextLost(String(err?.message || err));
          }
        }
      }

      // Poll only for an observed, eligible download.
      const [download] = clickDownloads(click);
      if (download) {
        const finalDownload = await waitForDownloadCompletion(download.id, 4500, tabId, cancelToken);
        const downloadPath = completedDownloadPath(finalDownload);
        const status = finalDownload?.state || "unavailable";
        const error = finalDownload?.error;
        const detail = downloadPath ? `: ${downloadPath}`
          : status === "interrupted" && /^[A-Z][A-Z0-9_]*$/.test(error || "") ? ` (${error})` : "";
        return {
          mechanism: "cdp-mouse (download)",
          message: `Download ${status}${detail}`,
          downloadPath,
          resolvedElementId,
          effect: "changed"
        };
      }
      const afterTab = await refreshTabMeta(tabId);
      if (lostContext || session.documentId !== beforeDocumentId || session.navigating ||
          (afterTab && (afterTab.status === "loading" || (beforeUrl && afterTab.url && afterTab.url !== beforeUrl)))) {
        await waitForTabLoad(tabId, 3200);
        return {
          mechanism: "cdp-mouse (navigated)",
          message: afterTab?.url || session.url || null,
          resolvedElementId,
          effect: "changed"
        };
      }
      const netFired = (session.networkRequestSeq || 0) > beforeNetSeq;
      let effect = "unverified";
      let warning = null;
      if (probe?.mutated || probe?.stateChanged || probe?.urlChanged || probe?.scrollChanged || probe?.focusChanged || netFired) {
        effect = "changed";
      } else if (probe && !probe.sawEvent) {
        effect = "none";
        warning = "The page did not receive the click event (the page may still be loading or reflowed). Observe again before retrying.";
      } else if (probe && isLink) {
        effect = "none";
        warning = "Clicked the link, but no navigation, download, network request, or DOM change was observed. Observe again before retrying.";
      }
      return { mechanism: "cdp-mouse", message: null, resolvedElementId, effect, warning };
    } finally {
      if (!batchClicks) state.activeDownloadClicks.delete(click);
    }
  }

  if (action === "hover") {
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error("hover requires elementId, selector, match, or (x, y).");
    }
    const label = target.label ? `Hovering ${target.label}` : "Hovering";
    const pt = await moveCursorSmoothly(tabId, target.x, target.y, label);
    emitCursor(tabId, pt.x, pt.y, "hover", label);
    await waitForAnimationFrames(tabId, 40);
    return {
      mechanism: "cdp-hover",
      message: target.label || `(${Math.round(pt.x)}, ${Math.round(pt.y)})`,
      resolvedElementId: target.elementId || null
    };
  }

  if (action === "focus") {
    const target = await resolveStepTarget(tabId, step);
    const resolvedId = target?.elementId || step.elementId || null;
    if (resolvedId || step.selector) {
      const lookupExpr = findElementExprJs({ elementId: resolvedId, selector: resolvedId ? null : step.selector });
      await evalAgentInputInFrame(tabId, target?.frameMeta || null, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = ${lookupExpr};
        if (el) el.focus();
      })()`);
    }
    if (target) {
      await moveCursorSmoothly(tabId, target.x, target.y, "Focusing");
    }
    return { mechanism: "cdp-focus", message: null, resolvedElementId: resolvedId };
  }

  if (action === "setValue" || action === "type") {
    // setValue replaces a field's text, so it must name the field: without one it used to select-all and type into
    // whatever had focus. Typing into the focused element is what "type" is for.
    if (action === "setValue" && !stepNamesTarget(step)) {
      throw {
        code: "INVALID_REQUEST",
        message: "setValue names no field: pass elementId (an @bN id from browser_observe), match, or selector. Nothing was typed. To type into the focused field, use type."
      };
    }
    const session = getOrCreateTabSession(tabId);
    const text = step.text ?? "";
    const target = await resolveStepTarget(tabId, step);
    const frameMeta = target?.frameMeta || null;
    const resolvedId = target?.elementId || (typeof step.elementId === "string" && step.elementId.trim() ? step.elementId.trim() : null);
    const hasDomRef = Boolean(resolvedId || (typeof step.selector === "string" && step.selector.trim()));
    const lookupExpr = findElementExprJs({ elementId: resolvedId, selector: resolvedId ? null : step.selector });

    // Single collapsed eval for setValue on DOM targets: handles <select>, checkbox/radio, OR focuses & clears text input!
    if (action === "setValue" && hasDomRef) {
      const textLit = JSON.stringify(String(text));
      const prepRes = await evalAgentInputInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = ${lookupExpr};
        if (!el) return { handled: false, cleared: false };
        const tag = (el.tagName || '').toLowerCase();
        if (tag === 'select') {
          const wanted = ${textLit}.trim();
          const wantedLower = wanted.toLowerCase();
          const opts = Array.from(el.options || []);
          let match =
            opts.find((o) => o.value === wanted) ||
            opts.find((o) => (o.value || '').toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase() === wantedLower) ||
            opts.find((o) => (o.text || '').trim().toLowerCase().includes(wantedLower));
          if (!match) {
            const sample = opts.slice(0, 12).map((o) => (o.text || o.value || '').trim()).join(', ');
            return { handled: true, ok: false, error: 'No matching <option> for "' + wanted + '". Available: ' + sample };
          }
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set;
          if (setter) setter.call(el, match.value);
          else el.value = match.value;
          match.selected = true;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { handled: true, ok: true, mechanism: 'cdp-select', message: 'Selected "' + (match.text || match.value).trim() + '"' };
        }
        if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
          const lower = ${textLit}.trim().toLowerCase();
          if (['true', 'false', 'checked', 'unchecked', 'on', 'off', '1', '0'].includes(lower)) {
            const desired = ['true', 'checked', 'on', '1'].includes(lower);
            if (Boolean(el.checked) !== desired) {
              el.click();
            }
            return { handled: true, ok: true, mechanism: 'cdp-toggle', message: 'checked=' + Boolean(el.checked) };
          }
        }
        el.focus();
        if ('value' in el && el.type !== 'file') {
          const proto = el.tagName === 'TEXTAREA'
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) setter.call(el, '');
          else el.value = '';
          el.dispatchEvent(new Event('input', { bubbles: true }));
        } else if (el.isContentEditable) {
          el.textContent = '';
          el.dispatchEvent(new Event('input', { bubbles: true }));
        }
        return { handled: false, cleared: true };
      })()`);
      const sv = prepRes?.result?.value;
      if (sv?.handled) {
        if (!sv.ok) throw new Error(sv.error || "Failed to select option.");
        return {
          mechanism: sv.mechanism || "cdp-select",
          message: sv.message || null,
          resolvedElementId: resolvedId
        };
      }
    }

    if (target) {
      const pt = await moveCursorSmoothly(tabId, target.x, target.y, "Typing");
      emitCursor(tabId, pt.x, pt.y, "type", "Typing");
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
    } else {
      emitCursor(tabId, session.cursor.x, session.cursor.y, "type", "Typing");
    }

    if (action === "setValue" && !hasDomRef) {
      await sendCDP(tabId, "Input.dispatchKeyEvent", {
        type: "keyDown",
        key: "a",
        code: "KeyA",
        windowsVirtualKeyCode: 65,
        modifiers: 4
      });
      await sendCDP(tabId, "Input.dispatchKeyEvent", {
        type: "keyUp",
        key: "a",
        code: "KeyA",
        windowsVirtualKeyCode: 65,
        modifiers: 4
      });
      await sendCDP(tabId, "Input.dispatchKeyEvent", {
        type: "keyDown",
        key: "Backspace",
        code: "Backspace",
        windowsVirtualKeyCode: 8
      });
      await sendCDP(tabId, "Input.dispatchKeyEvent", {
        type: "keyUp",
        key: "Backspace",
        code: "Backspace",
        windowsVirtualKeyCode: 8
      });
    }

    if (text.length > 0) {
      let inserted = false;
      if (frameMeta?.sessionId) {
        try {
          await sendCDP(tabId, "Input.insertText", { text }, frameMeta.sessionId);
          inserted = true;
        } catch (_) {}
      }
      if (!inserted) {
        await sendCDP(tabId, "Input.insertText", { text });
      }
    }

    // Single finalization eval: dispatches 'change', plus OOPIF fallback value sync ONLY when frameMeta?.isOOPIF === true.
    if (hasDomRef) {
      const isOOPIF = frameMeta?.isOOPIF === true;
      const textLit = JSON.stringify(String(text));
      const isSetValue = action === "setValue" ? "true" : "false";
      await evalAgentInputInFrame(tabId, frameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const el = ${lookupExpr};
        if (!el) return;
        if (${isOOPIF ? "true" : "false"} && ${text.length > 0 ? "true" : "false"} && 'value' in el && el.type !== 'file') {
          const wanted = ${textLit};
          const cur = String(el.value || '');
          if (cur === '' || (${isSetValue} && cur !== wanted && !cur.includes(wanted))) {
            const nextVal = ${isSetValue} ? wanted : (cur + wanted);
            const proto = el.tagName === 'TEXTAREA'
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            if (setter) setter.call(el, nextVal);
            else el.value = nextVal;
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
        }
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()`).catch(() => {});
    }

    return {
      mechanism: frameMeta?.isOOPIF === true ? "cdp-input (iframe)" : "cdp-input",
      message: null,
      resolvedElementId: resolvedId
    };
  }

  if (action === "pressKey") {
    const session = getOrCreateTabSession(tabId);
    const desc = buildKeyDescriptor(step.key || "");
    const modifiers = buildModifierMask(step.modifiers);
    emitCursor(tabId, session.cursor.x, session.cursor.y, "type", `Key ${desc.key}`);

    await sendCDP(tabId, "Input.dispatchKeyEvent", {
      type: desc.text && modifiers === 0 ? "keyDown" : "rawKeyDown",
      key: desc.key,
      code: desc.code,
      windowsVirtualKeyCode: desc.keyCode,
      nativeVirtualKeyCode: desc.keyCode,
      modifiers,
      text: modifiers === 0 ? desc.text : undefined,
      unmodifiedText: desc.text
    });
    await sendCDP(tabId, "Input.dispatchKeyEvent", {
      type: "keyUp",
      key: desc.key,
      code: desc.code,
      windowsVirtualKeyCode: desc.keyCode,
      nativeVirtualKeyCode: desc.keyCode,
      modifiers
    });
    return { mechanism: "cdp-key", message: null };
  }

  if (action === "scroll") {
    const session = getOrCreateTabSession(tabId);
    const target = await resolveStepTarget(tabId, step);
    const pt = target
      ? await moveCursorSmoothly(tabId, target.x, target.y, "Scrolling")
      : { ...session.cursor };
    emitCursor(tabId, pt.x, pt.y, "scroll", "Scrolling");

    const requestedDeltaX = Number(step.deltaX || 0);
    const requestedDeltaY = Number(step.deltaY || 0);
    const selectorLit = step.selector ? JSON.stringify(String(step.selector)) : "null";
    const scrollFrameMeta = (target?.frameMeta && target.frameMeta.frameId != null)
      ? target.frameMeta
      : findChildFrameAtPoint(session, pt.x, pt.y);
    const localPtX = scrollFrameMeta ? (pt.x - scrollFrameMeta.offsetX) : pt.x;
    const localPtY = scrollFrameMeta ? (pt.y - scrollFrameMeta.offsetY) : pt.y;

    const beforeEval = await evalInFrame(tabId, scrollFrameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const y = window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0;
        const x = window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0;
        const sh = Math.max(document.documentElement?.scrollHeight || 0, document.body?.scrollHeight || 0);
        const sw = Math.max(document.documentElement?.scrollWidth || 0, document.body?.scrollWidth || 0);
        const vh = window.innerHeight || 800;
        const vw = window.innerWidth || 1280;
        const sel = ${selectorLit};
        const hit = sel ? queryOneDeep(document, sel) : document.elementFromPoint(${localPtX}, ${localPtY});
        let hitScrollTop = 0;
        let hitScrollLeft = 0;
        let hitScrollableY = false;
        let hitScrollableX = false;
        let cur = hit;
        while (cur && cur !== document.body && cur !== document.documentElement) {
          const st = window.getComputedStyle(cur);
          if (!hitScrollableY && (st.overflowY === 'auto' || st.overflowY === 'scroll') && cur.scrollHeight > cur.clientHeight + 4) {
            hitScrollTop = cur.scrollTop;
            hitScrollableY = true;
          }
          if (!hitScrollableX && (st.overflowX === 'auto' || st.overflowX === 'scroll') && cur.scrollWidth > cur.clientWidth + 4) {
            hitScrollLeft = cur.scrollLeft;
            hitScrollableX = true;
          }
          if (hitScrollableY && hitScrollableX) break;
          cur = cur.parentElement;
        }
        const htmlOv = window.getComputedStyle(document.documentElement).overflowY;
        const bodyOv = document.body ? window.getComputedStyle(document.body).overflowY : '';
        return {
          scrollX: x,
          scrollY: y,
          scrollWidth: sw,
          scrollHeight: sh,
          vw,
          vh,
          hitScrollLeft,
          hitScrollTop,
          hitScrollableX,
          hitScrollableY,
          locked: htmlOv === 'hidden' || bodyOv === 'hidden'
        };
      })()`).catch(() => null);

    const before = beforeEval?.result?.value || {
      scrollX: 0, scrollY: 0, scrollWidth: 0, scrollHeight: 0, vw: 1280, vh: 800,
      hitScrollLeft: 0, hitScrollTop: 0, hitScrollableX: false, hitScrollableY: false, locked: false
    };

    await sendCDP(tabId, "Input.dispatchMouseEvent", {
      type: "mouseWheel",
      x: pt.x,
      y: pt.y,
      deltaX: requestedDeltaX,
      deltaY: requestedDeltaY
    });
    await waitForAnimationFrames(tabId, 45);

    // If horizontal scroll was requested on an inner container and CDP wheel didn't move it, apply direct scrollBy fallback
    if (Math.abs(requestedDeltaX) >= 10) {
      await evalInFrame(tabId, scrollFrameMeta, `(() => {
          ${QUERY_DEEP_HELPER_JS}
          const sel = ${selectorLit};
          const hit = sel ? queryOneDeep(document, sel) : document.elementFromPoint(${localPtX}, ${localPtY});
          let cur = hit;
          while (cur && cur !== document.body && cur !== document.documentElement) {
            const st = window.getComputedStyle(cur);
            if ((st.overflowX === 'auto' || st.overflowX === 'scroll') && cur.scrollWidth > cur.clientWidth + 4) {
              if (Math.abs(cur.scrollLeft - ${before.hitScrollLeft}) < 2) {
                cur.scrollLeft += ${requestedDeltaX};
              }
              return;
            }
            cur = cur.parentElement;
          }
        })()`).catch(() => null);
      await waitForAnimationFrames(tabId, 35);
    }

    const afterEval = await evalInFrame(tabId, scrollFrameMeta, `(() => {
        ${QUERY_DEEP_HELPER_JS}
        const y = window.scrollY || document.documentElement?.scrollTop || document.body?.scrollTop || 0;
        const x = window.scrollX || document.documentElement?.scrollLeft || document.body?.scrollLeft || 0;
        const sel = ${selectorLit};
        const hit = sel ? queryOneDeep(document, sel) : document.elementFromPoint(${localPtX}, ${localPtY});
        let hitScrollTop = 0;
        let hitScrollLeft = 0;
        let gotY = false;
        let gotX = false;
        let overlayHit = null;
        let cur = hit;
        while (cur && cur !== document.body && cur !== document.documentElement) {
          const st = window.getComputedStyle(cur);
          if (!gotY && (st.overflowY === 'auto' || st.overflowY === 'scroll') && cur.scrollHeight > cur.clientHeight + 4) {
            hitScrollTop = cur.scrollTop;
            gotY = true;
          }
          if (!gotX && (st.overflowX === 'auto' || st.overflowX === 'scroll') && cur.scrollWidth > cur.clientWidth + 4) {
            hitScrollLeft = cur.scrollLeft;
            gotX = true;
          }
          const z = parseInt(st.zIndex, 10);
          if (!overlayHit && (cur.getAttribute?.('role') === 'dialog' || cur.getAttribute?.('aria-modal') === 'true' || (st.position === 'fixed' && Number.isFinite(z) && z >= 10))) {
            const r = cur.getBoundingClientRect();
            if (r.height >= 90 && r.width >= 200) {
              overlayHit = (cur.innerText || cur.tagName || 'overlay').replace(/\\s+/g, ' ').trim().slice(0, 100);
            }
          }
          cur = cur.parentElement;
        }
        return { scrollX: x, scrollY: y, hitScrollLeft, hitScrollTop, overlayHit };
      })()`).catch(() => null);

    const after = afterEval?.result?.value || {
      scrollX: before.scrollX, scrollY: before.scrollY,
      hitScrollLeft: before.hitScrollLeft, hitScrollTop: before.hitScrollTop, overlayHit: null
    };
    const winDeltaY = Math.round((after.scrollY - before.scrollY) * 10) / 10;
    const containerDeltaY = Math.round((after.hitScrollTop - before.hitScrollTop) * 10) / 10;
    const actualDeltaY = Math.abs(winDeltaY) >= Math.abs(containerDeltaY) ? winDeltaY : containerDeltaY;

    const winDeltaX = Math.round((after.scrollX - before.scrollX) * 10) / 10;
    const containerDeltaX = Math.round((after.hitScrollLeft - before.hitScrollLeft) * 10) / 10;
    const actualDeltaX = Math.abs(winDeltaX) >= Math.abs(containerDeltaX) ? winDeltaX : containerDeltaX;

    const wantedDown = requestedDeltaY > 20 && (before.scrollY + before.vh < before.scrollHeight - 10 || before.locked || before.hitScrollableY);
    const wantedUp = requestedDeltaY < -20 && (before.scrollY > 10 || before.hitScrollTop > 4);
    const wantedHoriz = Math.abs(requestedDeltaX) > 20 && (before.scrollWidth > before.vw + 10 || before.hitScrollableX);
    let blockedWarning = null;
    if ((wantedDown || wantedUp) && Math.abs(actualDeltaY) < 4 && Math.abs(actualDeltaX) < 4) {
      if (after.overlayHit) {
        blockedWarning = `Scroll moved 0px — blocked by overlay: "${after.overlayHit}". Dismiss it (or call vision_query) before scrolling.`;
      } else if (before.locked && !before.hitScrollableY) {
        blockedWarning = "Scroll moved 0px — document scroll is locked (overflow: hidden), likely by a modal or popup banner.";
      } else {
        blockedWarning = `Scroll moved 0px at (${Math.round(pt.x)}, ${Math.round(pt.y)}) despite page height ${Math.round(before.scrollHeight)}px — a banner, iframe, or fixed element may be intercepting wheel events.`;
      }
    } else if (wantedHoriz && Math.abs(actualDeltaX) < 4 && Math.abs(requestedDeltaY) < 20) {
      blockedWarning = `Horizontal scroll moved 0px at (${Math.round(pt.x)}, ${Math.round(pt.y)}) — target the scrollable grid container (see ScrollContainers) or use browser_extract(mode: 'tables', scanHorizontal: true).`;
    }

    const msgParts = [];
    if (requestedDeltaY !== 0 || actualDeltaY !== 0) msgParts.push(`scrollDeltaY=${actualDeltaY}px (y=${Math.round(after.scrollY)})`);
    if (requestedDeltaX !== 0 || actualDeltaX !== 0) msgParts.push(`scrollDeltaX=${actualDeltaX}px (x=${Math.round(after.hitScrollLeft || after.scrollX)})`);

    return {
      mechanism: "cdp-wheel",
      message: blockedWarning ? blockedWarning : (msgParts.join(", ") || "scrolled"),
      scrollDeltaX: actualDeltaX,
      scrollDeltaY: actualDeltaY,
      blockedWarning
    };
  }

  if (action === "wait") {
    if (step.selector || step.text || hasNonEmptyMatch(step.match)) {
      return runWaitForStep(tabId, { ...step, timeoutMs: step.timeoutMs ?? step.durationMs ?? 6000 }, cancelToken);
    }
    const ms = clamp(Number(step.durationMs ?? step.ms ?? 500), 0, 30000);
    await sleepCancellable(ms, tabId, cancelToken);
    return { mechanism: "timer", message: null };
  }

  if (action === "uploadFile") {
    const files = Array.isArray(step.files) ? step.files.filter((f) => typeof f === "string" && f.trim().length > 0) : [];
    if (files.length === 0) {
      throw new Error("uploadFile requires a non-empty 'files' array of local file paths.");
    }

    let resolvedUploadId = typeof step.elementId === "string" && step.elementId.trim() ? step.elementId.trim() : null;
    if (!resolvedUploadId && !step.selector && hasNonEmptyMatch(step.match)) {
      const mTarget = await resolveMatchCenter(tabId, step.match).catch(() => null);
      if (mTarget?.elementId) resolvedUploadId = mTarget.elementId;
    }

    const lookupTargetJs = resolvedUploadId
      ? `findByUsemacId(${JSON.stringify(resolvedUploadId)}, document)`
      : step.selector
        ? `queryOneDeep(document, ${JSON.stringify(String(step.selector))})`
        : "null";
    const hasExplicitTarget = Boolean(resolvedUploadId || step.selector);

    const findInputExpr = `(() => {
      ${QUERY_DEEP_HELPER_JS}
      let target = ${lookupTargetJs};
      let input = null;
      if (target) {
        if (target.tagName === 'INPUT' && target.type === 'file') {
          input = target;
        } else if (target.tagName === 'LABEL' && target.control && target.control.type === 'file') {
          input = target.control;
        } else {
          input = queryOneDeep(target, 'input[type="file"]');
        }
        if (!input && target.parentElement) {
          const siblingInputs = queryAllDeep(target.parentElement, 'input[type="file"]');
          if (siblingInputs.length === 1) input = siblingInputs[0];
        }
      } else if (!${hasExplicitTarget ? "true" : "false"}) {
        const all = queryAllDeep(document, 'input[type="file"]');
        if (all.length >= 1) input = all[0];
      }
      return input || null;
    })()`;

    // Tier 1: Direct <input type="file"> across top frame and child OOPIFs/iframes (zero Finder!)
    const session = getOrCreateTabSession(tabId);
    const candidateFrames = [];
    const mappedFrame = resolvedUploadId ? session.elementFrameMap.get(resolvedUploadId) : null;
    if (mappedFrame) candidateFrames.push(mappedFrame);
    if (!mappedFrame || mappedFrame.frameId != null) candidateFrames.push(null);
    const extraFrames = session.lastChildFrames?.length
      ? session.lastChildFrames
      : await discoverChildFrames(tabId).catch(() => []);
    for (const f of extraFrames) {
      if (f !== mappedFrame) candidateFrames.push(f);
    }

    for (const frameMeta of candidateFrames) {
      const cdpSessionId = frameMeta?.sessionId || null;
      const directEval = await evalInFrame(tabId, frameMeta, findInputExpr, { returnByValue: false }).catch(() => null);
      const directObjectId = directEval?.result?.objectId;
      if (directObjectId) {
        try {
          const desc = await sendCDP(tabId, "DOM.describeNode", { objectId: directObjectId }, cdpSessionId);
          const backendNodeId = desc?.node?.backendNodeId;
          if (backendNodeId != null) {
            await sendCDP(tabId, "DOM.setFileInputFiles", {
              backendNodeId,
              files
            }, cdpSessionId);
            await sendCDP(tabId, "Runtime.callFunctionOn", {
              objectId: directObjectId,
              functionDeclaration: `function() {
                this.dispatchEvent(new Event('input', { bubbles: true }));
                this.dispatchEvent(new Event('change', { bubbles: true }));
              }`,
              returnByValue: true
            }, cdpSessionId).catch(() => {});
            await waitForAnimationFrames(tabId, 40);
            return {
              mechanism: frameMeta?.isOOPIF ? "cdp-file-input (iframe)" : "cdp-file-input",
              message: `Uploaded ${files.length} file(s): ${files.map((f) => f.split("/").pop()).join(", ")}`,
              resolvedElementId: resolvedUploadId
            };
          }
        } finally {
          await sendCDP(tabId, "Runtime.releaseObject", { objectId: directObjectId }, cdpSessionId).catch(() => {});
        }
      }
    }

    // Tier 2: Intercept dynamic file chooser dialog before macOS Finder opens!
    const target = await resolveStepTarget(tabId, step);
    if (!target) {
      throw new Error("uploadFile found no <input type='file'> and no clickable target (provide elementId, selector, match, or x/y).");
    }

    const pt = await moveCursorSmoothly(tabId, target.x, target.y, "Uploading");
    emitCursor(tabId, pt.x, pt.y, "click", "Uploading");
    const targetSessionId = target.frameMeta?.sessionId || null;

    await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: true }).catch(() => {});
    if (targetSessionId) {
      await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: true }, targetSessionId).catch(() => {});
    }
    let chooserEvent = null;
    try {
      const chooserPromise = waitForFileChooser(tabId, 2600);
      await dispatchMouseClick(tabId, pt.x, pt.y, "left", 1);
      chooserEvent = await chooserPromise;
      if (chooserEvent?.backendNodeId != null) {
        await sendCDP(tabId, "DOM.setFileInputFiles", {
          backendNodeId: chooserEvent.backendNodeId,
          files
        }, chooserEvent.sessionId || targetSessionId || null);
        await waitForAnimationFrames(tabId, 40);
        return {
          mechanism: "cdp-file-chooser",
          message: `Uploaded ${files.length} file(s) via intercepted chooser: ${files.map((f) => f.split("/").pop()).join(", ")}`,
          resolvedElementId: target.elementId || resolvedUploadId
        };
      }
    } finally {
      await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: false }).catch(() => {});
      if (targetSessionId) {
        await sendCDP(tabId, "Page.setInterceptFileChooserDialog", { enabled: false }, targetSessionId).catch(() => {});
      }
    }

    // Tier 3: Synthetic drag-and-drop fallback for pure ondrop dropzones without <input>
    const dragData = { items: [], files, dragOperationsMask: 1 };
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "dragEnter",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "dragOver",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await sendCDP(tabId, "Input.dispatchDragEvent", {
      type: "drop",
      x: pt.x,
      y: pt.y,
      data: dragData
    });
    await waitForAnimationFrames(tabId, 40);
    return {
      mechanism: "cdp-drag-drop",
      message: `Dropped ${files.length} file(s) at (${Math.round(pt.x)}, ${Math.round(pt.y)}): ${files.map((f) => f.split("/").pop()).join(", ")}`,
      resolvedElementId: target.elementId || resolvedUploadId
    };
  }

  if (action === "target") {
    const target = await resolveStepTarget(tabId, step);
    if (target) {
      await moveCursorSmoothly(tabId, target.x, target.y, "Targeting");
    }
    return { mechanism: "cdp-target", message: null, resolvedElementId: target?.elementId || null };
  }

  throw new Error(`Unsupported action step: ${action}`);
}
