(() => {
  document.documentElement.classList.add("js");

  // Sticky frosted navbar
  const navbar = document.getElementById("navbar");
  const onScroll = () => {
    if (!navbar) return;
    navbar.classList.toggle("scrolled", window.scrollY > 24);
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Live macOS menu bar clock
  const clockEl = document.getElementById("macClock");
  if (clockEl) {
    const updateClock = () => {
      const now = new Date();
      clockEl.textContent = now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    };
    updateClock();
    setInterval(updateClock, 30000);
  }

  // Scroll reveal observer
  const reveals = document.querySelectorAll(".reveal");
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.12 }
  );
  reveals.forEach((el) => io.observe(el));

  // ---------- Interactive Live macOS Desktop + Floating UseMac HUD Demo ----------
  const hud = document.getElementById("demoHud");
  const webPage = document.getElementById("demoWebPage");
  const formView = document.getElementById("demoFormView");
  const submittedView = document.getElementById("demoSubmittedView");
  const cursor = document.getElementById("hudCursor");
  const cursorPill = document.getElementById("cursorPill");
  const cursorRipple = document.getElementById("cursorRipple");
  const statusText = document.getElementById("hudStatusText");
  const spinner = document.getElementById("hudSpinner");
  const stopBtn = document.getElementById("hudStopBtn");
  const stopLabel = document.getElementById("hudStopLabel");
  const stopIcon = document.getElementById("hudStopIcon");
  const demoToggle = document.getElementById("demoToggle");
  const completeOverlay = document.getElementById("hudCompleteOverlay");
  const completeLabel = document.getElementById("hudCompleteLabel");
  const menubarBadge = document.getElementById("menubarBadge");
  const menubarPulse = document.getElementById("menubarPulse");

  const fieldVendor = document.getElementById("fieldVendor");
  const textVendor = document.getElementById("textVendor");
  const fieldAmount = document.getElementById("fieldAmount");
  const textAmount = document.getElementById("textAmount");
  const fieldDropzone = document.getElementById("fieldDropzone");
  const catChip = document.getElementById("catChip");
  const btnSubmit = document.getElementById("btnSubmit");
  const agentReply = document.getElementById("agentReply");
  const agentInputHint = document.getElementById("agentInputHint");
  const agentSteps = Array.from(document.querySelectorAll("#agentStream .term-step"));
  const stageStepBtns = Array.from(document.querySelectorAll(".stage-step[data-step]"));

  let isPaused = false;
  let timerIds = [];

  function clearTimers() {
    timerIds.forEach((id) => clearTimeout(id));
    timerIds = [];
  }

  function later(ms, fn) {
    const id = setTimeout(fn, ms);
    timerIds.push(id);
  }

  function pingCursor() {
    if (!cursorRipple) return;
    cursorRipple.classList.remove("ping");
    void cursorRipple.offsetWidth;
    cursorRipple.classList.add("ping");
  }

  function showCursor(xPct, yPct, label, click = false) {
    if (!cursor || !cursorPill) return;
    cursor.classList.remove("hidden");
    cursor.classList.toggle("flip-left", xPct > 56);
    cursor.style.left = `${xPct}%`;
    cursor.style.top = `${yPct}%`;
    cursorPill.textContent = label;
    if (click) {
      later(260, pingCursor);
    }
  }

  function hideCursor() {
    cursor?.classList.add("hidden");
  }

  function typeInto(el, text, charDelay = 42) {
    if (!el) return;
    el.textContent = "";
    for (let i = 0; i < text.length; i++) {
      later(i * charDelay, () => {
        if (!isPaused) el.textContent = text.slice(0, i + 1);
      });
    }
  }

  function syncPlayState(paused) {
    if (demoToggle) demoToggle.textContent = paused ? "Play demo" : "Pause demo";
    if (stopLabel) stopLabel.textContent = paused ? "Replay" : "Stop";
    if (stopIcon) stopIcon.style.borderRadius = paused ? "50%" : "1.5px";
  }

  function setActiveStep(stepIdx, allDone = false) {
    agentSteps.forEach((el, idx) => {
      el.classList.remove("running", "done");
      if (allDone || idx < stepIdx) el.classList.add("done");
      else if (idx === stepIdx) el.classList.add("running");
    });
    stageStepBtns.forEach((btn, idx) => {
      const isActive = !allDone && idx === stepIdx;
      btn.classList.toggle("active", isActive);
      btn.classList.toggle("done", allDone || idx < stepIdx);
      if (isActive) btn.setAttribute("aria-current", "step");
      else btn.removeAttribute("aria-current");
    });
    if (agentInputHint) {
      agentInputHint.textContent = allDone ? "Ready for next command" : "Running in background…";
    }
  }

  function resetDemo() {
    hud?.classList.remove("is-hidden", "is-paused");
    webPage?.classList.remove("loading");
    formView?.classList.remove("hidden");
    submittedView?.classList.remove("visible");
    completeOverlay?.classList.remove("visible");
    agentReply?.classList.remove("visible");
    if (agentInputHint) agentInputHint.textContent = "Running in background…";
    menubarBadge?.classList.add("working");
    menubarPulse?.classList.remove("idle");

    if (spinner) spinner.style.display = "inline-block";
    syncPlayState(false);

    fieldVendor?.classList.remove("focused", "filled");
    fieldAmount?.classList.remove("focused", "filled");
    fieldDropzone?.classList.remove("uploaded");
    catChip?.classList.remove("active");
    btnSubmit?.classList.remove("clicked");
    if (textVendor) textVendor.textContent = "";
    if (textAmount) textAmount.textContent = "";
    hideCursor();
  }

  function applyPrefixState(startAt) {
    if (startAt >= 1) {
      webPage?.classList.remove("loading");
    }
    if (startAt >= 2) {
      fieldVendor?.classList.add("filled");
      fieldAmount?.classList.add("filled");
      catChip?.classList.add("active");
      if (textVendor) textVendor.textContent = "Oracle Cloud";
      if (textAmount) textAmount.textContent = "$480.00";
    }
    if (startAt >= 3) {
      fieldDropzone?.classList.add("uploaded");
    }
  }

  function runDemo(startAt = 0) {
    clearTimers();
    isPaused = false;
    resetDemo();
    applyPrefixState(startAt);

    let t = 0;

    // Step 0: Open site silently in corner HUD
    if (startAt <= 0) {
      setActiveStep(0);
      hud?.classList.add("is-hidden");
      webPage?.classList.add("loading");
      if (statusText) statusText.textContent = "Opening acme.app…";
      later(120, () => {
        if (!isPaused) hud?.classList.remove("is-hidden");
      });
      later(780, () => {
        if (!isPaused) webPage?.classList.remove("loading");
      });
      t += 1350;
    }

    // Step 1: Fill form fields (Vendor + Amount)
    if (startAt <= 1) {
      later(t, () => {
        if (isPaused) return;
        setActiveStep(1);
        if (statusText) statusText.textContent = "Filling expense form…";
        fieldVendor?.classList.add("focused");
        showCursor(41, 41, "Typing", true);
        later(220, () => typeInto(textVendor, "Oracle Cloud", 42));
      });
      later(t + 1150, () => {
        if (isPaused) return;
        fieldVendor?.classList.remove("focused");
        fieldVendor?.classList.add("filled");
        fieldAmount?.classList.add("focused");
        showCursor(77, 41, "Typing", true);
        later(200, () => typeInto(textAmount, "$480.00", 48));
        later(620, () => {
          if (isPaused) return;
          fieldAmount?.classList.remove("focused");
          fieldAmount?.classList.add("filled");
          catChip?.classList.add("active");
        });
      });
      t += 2200;
    }

    // Step 2: Zero-Finder PDF upload
    if (startAt <= 2) {
      later(t, () => {
        if (isPaused) return;
        setActiveStep(2);
        if (statusText) statusText.textContent = "Uploading receipt-q4.pdf…";
        showCursor(54, 56, "Uploading", true);
      });
      later(t + 560, () => {
        if (isPaused) return;
        fieldDropzone?.classList.add("uploaded");
      });
      later(t + 1300, () => {
        if (!isPaused) hideCursor();
      });
      t += 1650;
    }

    // Step 3: Click Submit + Frosted Mint Check + Auto-Close HUD
    if (startAt <= 3) {
      later(t, () => {
        if (isPaused) return;
        setActiveStep(3);
        if (statusText) statusText.textContent = "Clicking Submit expense…";
        showCursor(82, 68, "Clicking", true);
      });
      later(t + 460, () => {
        if (isPaused) return;
        btnSubmit?.classList.add("clicked");
      });
      later(t + 880, () => {
        if (isPaused) return;
        hideCursor();
        formView?.classList.add("hidden");
        submittedView?.classList.add("visible");
        if (statusText) statusText.textContent = "Verifying locally…";
      });
      later(t + 1750, () => {
        if (isPaused) return;
        setActiveStep(4, true);
        if (spinner) spinner.style.display = "none";
        if (statusText) statusText.textContent = "All done";
        if (completeLabel) completeLabel.textContent = "All done";
        completeOverlay?.classList.add("visible");
        agentReply?.classList.add("visible");
        menubarBadge?.classList.remove("working");
        menubarPulse?.classList.add("idle");
      });
      later(t + 3150, () => {
        if (isPaused) return;
        hud?.classList.add("is-hidden");
      });
      later(t + 5100, () => {
        if (!isPaused) runDemo(0);
      });
    }
  }

  function pauseDemo() {
    isPaused = true;
    clearTimers();
    hud?.classList.remove("is-hidden");
    hud?.classList.add("is-paused");
    completeOverlay?.classList.remove("visible");
    menubarBadge?.classList.remove("working");
    menubarPulse?.classList.add("idle");
    if (spinner) spinner.style.display = "none";
    if (statusText) statusText.textContent = "Stopped (⇧⌘⎋)";
    hideCursor();
    syncPlayState(true);
  }

  function toggleDemo() {
    if (!isPaused) {
      pauseDemo();
    } else {
      runDemo(0);
    }
  }

  function applyReducedMotionState() {
    clearTimers();
    isPaused = true;
    resetDemo();
    applyPrefixState(3);
    agentSteps.forEach((el, idx) => {
      el.classList.remove("running", "done");
      if (idx < 3) el.classList.add("done");
    });
    stageStepBtns.forEach((btn, idx) => {
      const isCurrent = idx === 2;
      btn.classList.toggle("active", isCurrent);
      btn.classList.toggle("done", idx < 3);
      if (isCurrent) btn.setAttribute("aria-current", "step");
      else btn.removeAttribute("aria-current");
    });
    menubarBadge?.classList.remove("working");
    menubarPulse?.classList.add("idle");
    if (spinner) spinner.style.display = "none";
    if (statusText) statusText.textContent = "Uploaded receipt-q4.pdf";
    if (agentInputHint) agentInputHint.textContent = "Demo paused";
    hideCursor();
    syncPlayState(true);
  }

  stageStepBtns.forEach((btn) => {
    btn.addEventListener("click", () => {
      const idx = Number(btn.dataset.step || 0);
      runDemo(idx);
    });
  });

  stopBtn?.addEventListener("click", toggleDemo);
  demoToggle?.addEventListener("click", toggleDemo);

  const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (prefersReducedMotion) {
    applyReducedMotionState();
  } else {
    runDemo(0);
  }

  // ---------- Interactive Governance Mode Switcher (Bento Card 4) ----------
  const modeOpts = Array.from(document.querySelectorAll(".mode-opt"));
  const modeDot = document.getElementById("modeDot");
  const modeDesc = document.getElementById("modeDesc");
  const modeDescriptions = {
    autonomous: "Agents running quietly in background",
    readonly: "Read-only — clicks, typing & uploads blocked",
    paused: "All agents frozen instantly (⇧⌘⎋)",
  };

  function selectMode(btn, moveFocus = false) {
    const mode = btn.dataset.mode || "autonomous";
    modeOpts.forEach((b) => {
      const isActive = b === btn;
      b.classList.toggle("active", isActive);
      b.setAttribute("aria-checked", isActive ? "true" : "false");
      b.setAttribute("tabindex", isActive ? "0" : "-1");
    });
    if (modeDot) {
      modeDot.className = `mode-dot ${mode === "autonomous" ? "active" : mode}`;
    }
    if (modeDesc) {
      modeDesc.textContent = modeDescriptions[mode] || modeDescriptions.autonomous;
    }
    if (moveFocus) btn.focus();
  }

  modeOpts.forEach((btn, idx) => {
    btn.addEventListener("click", () => selectMode(btn, false));
    btn.addEventListener("keydown", (e) => {
      let nextIdx = null;
      if (e.key === "ArrowRight" || e.key === "ArrowDown") {
        nextIdx = (idx + 1) % modeOpts.length;
      } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
        nextIdx = (idx - 1 + modeOpts.length) % modeOpts.length;
      }
      if (nextIdx !== null) {
        e.preventDefault();
        selectMode(modeOpts[nextIdx], true);
      }
    });
  });

  // ---------- Interactive "Paste into Your Agent" Setup Composer ----------
  const BIN = "/Applications/UseMac.app/Contents/Helpers/usemac";
  const agentConfigs = {
    claude: {
      name: "Claude Code",
      buttonLabel: "Copy prompt for Claude Code",
      copiedLabel: "Copied — paste into Claude Code ✓",
      plain: `Set up UseMac on my Mac so you can control my Mac apps and Chrome tabs in the background:\n\n1. Run \`${BIN} install-skill\`\n2. Add the MCP server (\`${BIN} mcp\`) to my Claude Code config\n3. Run \`${BIN} status\` and confirm Accessibility, Screen Recording, and Chrome Bridge are connected`,
      html: `<p>Set up <strong>UseMac</strong> on my Mac so you can control my Mac apps and Chrome tabs in the background:</p>
<ol>
  <li>Run <code>${BIN} install-skill</code></li>
  <li>Add the MCP server <code>${BIN} mcp</code> to my Claude Code config</li>
  <li>Run <code>${BIN} status</code> and confirm Accessibility, Screen Recording, and Chrome Bridge are ready</li>
</ol>`,
    },
    cursor: {
      name: "Cursor",
      buttonLabel: "Copy prompt for Cursor",
      copiedLabel: "Copied — paste into Cursor ✓",
      plain: `Set up UseMac on my Mac for background browser and desktop control:\n\n1. Run \`${BIN} install-skill\`\n2. Add \`usemac\` to \`~/.cursor/mcp.json\` with command \`${BIN}\` and args \`["mcp"]\`\n3. Run \`${BIN} status\` and verify permissions and Chrome Bridge are connected`,
      html: `<p>Set up <strong>UseMac</strong> on my Mac for background browser and desktop control:</p>
<ol>
  <li>Run <code>${BIN} install-skill</code></li>
  <li>Add <code>usemac</code> to <code>~/.cursor/mcp.json</code> using <code>${BIN} mcp</code></li>
  <li>Run <code>${BIN} status</code> and verify permissions &amp; Chrome Bridge</li>
</ol>`,
    },
    codex: {
      name: "Codex",
      buttonLabel: "Copy prompt for Codex",
      copiedLabel: "Copied — paste into Codex ✓",
      plain: `Install and verify UseMac on my Mac:\n\n1. Run \`${BIN} install-skill\` to install the skill in ~/.codex/skills\n2. Register the MCP server \`${BIN} mcp\`\n3. Run \`${BIN} status\` and report if Accessibility, Screen Recording, and Chrome Bridge are ready`,
      html: `<p>Install and verify <strong>UseMac</strong> on my Mac:</p>
<ol>
  <li>Run <code>${BIN} install-skill</code> to add the skill in <code>~/.codex/skills</code></li>
  <li>Register the MCP server <code>${BIN} mcp</code></li>
  <li>Run <code>${BIN} status</code> and report permissions &amp; Chrome Bridge status</li>
</ol>`,
    },
    antigravity: {
      name: "Antigravity",
      buttonLabel: "Copy prompt for Antigravity",
      copiedLabel: "Copied — paste into Antigravity ✓",
      plain: `Connect UseMac on my Mac so you can use my real Chrome tabs and Mac apps in the background:\n\n1. Run \`${BIN} install-skill\`\n2. Run \`${BIN} status\` and confirm the daemon socket and Chrome Bridge are online`,
      html: `<p>Connect <strong>UseMac</strong> on my Mac so you can use my real Chrome tabs and Mac apps in the background:</p>
<ol>
  <li>Run <code>${BIN} install-skill</code></li>
  <li>Run <code>${BIN} status</code> and confirm the local Unix socket &amp; Chrome Bridge are online</li>
</ol>`,
    },
    mcp: {
      name: "MCP JSON",
      buttonLabel: "Copy MCP JSON",
      copiedLabel: "MCP JSON copied ✓",
      plain: `{\n  "mcpServers": {\n    "usemac": {\n      "command": "${BIN}",\n      "args": ["mcp"]\n    }\n  }\n}`,
      html: `<pre>{
  "mcpServers": {
    "usemac": {
      "command": "${BIN}",
      "args": ["mcp"]
    }
  }
}</pre>`,
    },
  };

  const composerBody = document.getElementById("composerBody");
  const copyAgentBtn = document.getElementById("copyAgentPrompt");
  const copyAgentLabel = document.getElementById("copyAgentLabel");
  const copyCliAlt = document.getElementById("copyCliAlt");
  let activeAgent = "claude";

  function renderAgent(key) {
    activeAgent = key;
    const cfg = agentConfigs[key] || agentConfigs.claude;
    if (composerBody) composerBody.innerHTML = cfg.html;
    if (copyAgentLabel) copyAgentLabel.textContent = cfg.buttonLabel;
    copyAgentBtn?.classList.remove("copied");
  }

  const agentPills = Array.from(document.querySelectorAll(".agent-pill"));

  function selectAgentTab(pill, moveFocus = false) {
    agentPills.forEach((p) => {
      const isActive = p === pill;
      p.classList.toggle("active", isActive);
      p.setAttribute("aria-selected", isActive ? "true" : "false");
      p.setAttribute("tabindex", isActive ? "0" : "-1");
    });
    if (composerBody && pill.id) {
      composerBody.setAttribute("aria-labelledby", pill.id);
    }
    renderAgent(pill.dataset.agent || "claude");
    if (moveFocus) pill.focus();
  }

  agentPills.forEach((pill, idx) => {
    pill.addEventListener("click", () => selectAgentTab(pill, false));
    pill.addEventListener("keydown", (e) => {
      let nextIdx = null;
      if (e.key === "ArrowRight") {
        nextIdx = (idx + 1) % agentPills.length;
      } else if (e.key === "ArrowLeft") {
        nextIdx = (idx - 1 + agentPills.length) % agentPills.length;
      } else if (e.key === "Home") {
        nextIdx = 0;
      } else if (e.key === "End") {
        nextIdx = agentPills.length - 1;
      }
      if (nextIdx !== null) {
        e.preventDefault();
        selectAgentTab(agentPills[nextIdx], true);
      }
    });
  });

  copyAgentBtn?.addEventListener("click", async () => {
    const cfg = agentConfigs[activeAgent] || agentConfigs.claude;
    try {
      await navigator.clipboard.writeText(cfg.plain);
      copyAgentBtn.classList.add("copied");
      if (copyAgentLabel) copyAgentLabel.textContent = cfg.copiedLabel;
      setTimeout(() => {
        copyAgentBtn.classList.remove("copied");
        if (copyAgentLabel) copyAgentLabel.textContent = cfg.buttonLabel;
      }, 2200);
    } catch {
      if (copyAgentLabel) copyAgentLabel.textContent = "Select & Copy";
    }
  });

  copyCliAlt?.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(`${BIN} install-skill`);
      const prev = copyCliAlt.textContent;
      copyCliAlt.textContent = "Terminal command copied ✓";
      setTimeout(() => {
        copyCliAlt.textContent = prev;
      }, 1800);
    } catch {}
  });

  renderAgent("claude");
})();
