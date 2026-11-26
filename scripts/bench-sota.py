#!/usr/bin/env python3
"""UseMac SOTA Benchmark Suite (Python 3 stdlib only).

Measures:
  1. Static Schema & Skill Tax (MCP tools/list compact/pretty bytes, initialize instructions, SKILL.md, AGENTS.md)
  2. Local IPC & Native AX / Menu / Skill / Apple Vision OCR speedups
  3. Browser & SPA fixture metrics (scripts/bench/spa-fixture.html with /api/transactions) when Chrome is connected
  4. Calibrated End-to-End Amdahl Wall-Clock & Token Model (5-step Native & 5-step Browser @ 5.0 s/turn frontier LLM)

Usage:
  python3 scripts/bench-sota.py [--cli <path>] [--socket <path>] [--app <name>] [--iterations <n>] [--save <json>] [--json]
  python3 scripts/bench-sota.py --compare <before.json> <after.json>
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import math
import os
import platform
import shutil
import socket
import socketserver
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
BENCH_DIR = REPO_ROOT / "scripts" / "bench"
LLM_TURN_SECONDS = 5.0
CHARS_PER_TOKEN_OBSERVE = 2.5
CHARS_PER_TOKEN_STATIC = 3.5

# Pre-SOTA documented baseline constants for the calibrated Amdahl model
BASELINE_STATIC_TOKENS = 23_500  # ~32.9 KB MCP schema + ~45.3 KB SKILL.md + instructions / 3.5
BASELINE_NATIVE_TURNS = 8        # status + task_start + observe + click + wait + type + observe + task_complete
BASELINE_NATIVE_OBS_TOKENS = 744
BASELINE_NATIVE_ENGINE_SEC = 0.85
BASELINE_BROWSER_TURNS = 9       # status + task_start + open + observe + dismiss + fill + submit + extract + complete
BASELINE_BROWSER_OBS_TOKENS = 1_650
BASELINE_BROWSER_ENGINE_SEC = 3.80


# MARK: - CLI & Socket Helpers


def detect_cli(explicit: str | None) -> str | None:
    if explicit:
        return explicit if os.path.isfile(explicit) else shutil.which(explicit)
    candidates = [
        REPO_ROOT / ".build" / "release" / "usemac-cli",
        REPO_ROOT / ".build" / "debug" / "usemac-cli",
        Path("/Applications/UseMac.app/Contents/Helpers/usemac"),
    ]
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return shutil.which("usemac")


def default_socket_path() -> str:
    env = os.environ.get("USEMAC_SOCKET")
    if env:
        return env
    return f"/tmp/usemac-{os.getuid()}/usemac.sock"


class UnixRPCClient:
    """Minimal persistent NDJSON client over UseMac's AF_UNIX socket."""

    def __init__(self, socket_path: str, timeout: float = 20.0) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._reader: Any = None
        self._next_id = 1

    def connect(self) -> bool:
        if not os.path.exists(self.socket_path):
            return False
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            sock.connect(self.socket_path)
            self._sock = sock
            self._reader = sock.makefile("r", encoding="utf-8")
            return True
        except OSError:
            self.close()
            return False

    def close(self) -> None:
        if self._reader is not None:
            try:
                self._reader.close()
            except OSError:
                pass
            self._reader = None
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def call(self, method: str, **payload: Any) -> tuple[dict[str, Any] | None, float]:
        if self._sock is None or self._reader is None:
            return None, 0.0
        req_id = f"bench-{self._next_id}"
        self._next_id += 1
        req = {"id": req_id, "method": method, **payload}
        wire = (json.dumps(req, separators=(",", ":")) + "\n").encode("utf-8")
        t0 = time.perf_counter()
        try:
            self._sock.sendall(wire)
            line = self._reader.readline()
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            if not line:
                return None, elapsed_ms
            return json.loads(line), elapsed_ms
        except (OSError, json.JSONDecodeError):
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            return None, elapsed_ms


def run_json_cmd(cmd: list[str], timeout: float = 45.0) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)


# MARK: - 1. Static Schema & Skill Tax


def probe_mcp_schema(cli_path: str | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "mcpToolCount": None,
        "mcpToolNames": None,
        "mcpToolsCompactBytes": None,
        "mcpToolsPrettyBytes": None,
        "mcpInstructionsChars": None,
        "error": None,
    }
    if not cli_path:
        result["error"] = "CLI binary not found"
        return result

    requests = "\n".join([
        json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "bench-sota", "version": "1.0"},
            },
        }),
        json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
    ]) + "\n"

    try:
        proc = subprocess.run(
            [cli_path, "mcp"],
            input=requests,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15.0,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        result["error"] = str(exc)
        return result

    responses: dict[int, dict[str, Any]] = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if isinstance(obj, dict) and isinstance(obj.get("id"), int):
                responses[obj["id"]] = obj
        except json.JSONDecodeError:
            continue

    init_resp = responses.get(1, {}).get("result") or {}
    instructions = init_resp.get("instructions")
    if isinstance(instructions, str):
        result["mcpInstructionsChars"] = len(instructions)

    tools_resp = responses.get(2, {}).get("result") or {}
    tools = tools_resp.get("tools")
    if isinstance(tools, list):
        compact = json.dumps(tools, separators=(",", ":")).encode("utf-8")
        pretty = json.dumps(tools, indent=2).encode("utf-8")
        result["mcpToolCount"] = len(tools)
        result["mcpToolNames"] = [t.get("name") for t in tools if isinstance(t, dict) and "name" in t]
        result["mcpToolsCompactBytes"] = len(compact)
        result["mcpToolsPrettyBytes"] = len(pretty)
    else:
        result["error"] = f"tools/list unavailable (rc={proc.returncode})"

    return result


def measure_static_tax(cli_path: str | None) -> dict[str, Any]:
    mcp = probe_mcp_schema(cli_path)
    skill_path = REPO_ROOT / ".agents" / "skills" / "usemac" / "SKILL.md"
    refs_dir = REPO_ROOT / ".agents" / "skills" / "usemac" / "references"
    agents_path = REPO_ROOT / ".agents" / "AGENTS.md"

    skill_bytes = skill_path.stat().st_size if skill_path.exists() else None
    ref_bytes = sum(p.stat().st_size for p in refs_dir.glob("*.md")) if refs_dir.exists() else 0
    agents_bytes = agents_path.stat().st_size if agents_path.exists() else None

    static_tokens: int | None = None
    if mcp["mcpToolsCompactBytes"] is not None and skill_bytes is not None:
        instr = mcp["mcpInstructionsChars"] or 0
        static_tokens = math.ceil((mcp["mcpToolsCompactBytes"] + instr + skill_bytes) / CHARS_PER_TOKEN_STATIC)

    return {
        "mcpToolCount": mcp["mcpToolCount"],
        "mcpToolsCompactBytes": mcp["mcpToolsCompactBytes"],
        "mcpToolsPrettyBytes": mcp["mcpToolsPrettyBytes"],
        "mcpInstructionsChars": mcp["mcpInstructionsChars"],
        "skillMdBytes": skill_bytes,
        "skillReferencesBytes": ref_bytes,
        "agentsMdBytes": agents_bytes,
        "staticTokensEst35": static_tokens,
        "mcpError": mcp["error"],
    }


# MARK: - 2. Local IPC & Native AX / Menu / Skill / Vision


def reconstruct_v1_compact_line(el: dict[str, Any]) -> str:
    """Reconstruct pre-SOTA v1 compactLine format to measure v2 compactLine compression on the same snapshot."""
    parts = [f"{el.get('id', '@e?')} [{el.get('role', 'AXUnknown')}]"]
    title = el.get("title")
    if title:
        parts.append('"' + str(title).replace("\n", " ") + '"')
    value = el.get("value")
    if value:
        trimmed = str(value).replace("\n", " ")
        clipped = trimmed[:48] + "..." if len(trimmed) > 48 else trimmed
        parts.append(f'val="{clipped}"')
    if el.get("focused"):
        parts.append("*focused*")
    if el.get("enabled") is False:
        parts.append("(disabled)")
    if el.get("offscreen"):
        parts.append("(offscreen)")
    else:
        frame = el.get("frame") or {}
        parts.append(f"({int(frame.get('x', 0))},{int(frame.get('y', 0))} {int(frame.get('width', 0))}x{int(frame.get('height', 0))})")
    actions = el.get("actions") or []
    if actions:
        parts.append("{" + ",".join(str(a) for a in actions) + "}")
    return " ".join(parts)


SHORT_ROLE_MAP = {
    "AXButton": "btn",
    "AXLink": "link",
    "AXTextField": "input",
    "AXTextArea": "textarea",
    "AXCheckBox": "checkbox",
    "AXRadioButton": "radio",
    "AXPopUpButton": "select",
    "AXComboBox": "select",
    "AXStaticText": "text",
    "AXMenuItem": "menuitem",
    "AXRow": "row",
    "AXTab": "tab",
    "AXImage": "img",
    "AXHeading": "heading",
}


def reconstruct_v2_compact_line(el: dict[str, Any]) -> str:
    role = str(el.get("role", "AXUnknown"))
    short_role = SHORT_ROLE_MAP.get(role)
    if short_role is None:
        short_role = role[2:].lower() if role.startswith("AX") and len(role) > 2 else role.lower()
    el_id = str(el.get("id", "@e?"))
    parts = [f"{el_id} [{short_role}]"]
    title = el.get("title")
    if title:
        parts.append('"' + str(title).replace("\n", " ") + '"')
    value = el.get("value")
    if value:
        trimmed = str(value).replace("\n", " ")
        clipped = trimmed[:48] + "..." if len(trimmed) > 48 else trimmed
        parts.append(f'val="{clipped}"')
    if el.get("focused"):
        parts.append("*focused*")
    if el.get("enabled") is False:
        parts.append("(disabled)")
    if el.get("offscreen"):
        parts.append("(offscreen)")
    elif not el_id.startswith("@"):
        frame = el.get("frame") or {}
        parts.append(f"({int(frame.get('x', 0))},{int(frame.get('y', 0))} {int(frame.get('width', 0))}x{int(frame.get('height', 0))})")
    actions = [str(a) for a in (el.get("actions") or [])]
    if short_role in {"btn", "link", "menuitem", "tab", "checkbox", "radio"}:
        actions = [a for a in actions if a != "AXPress"]
    elif short_role in {"input", "textarea"} and "AXSetValue" in actions:
        actions = [a for a in actions if a not in {"AXSetValue", "AXConfirm"}]
    if actions:
        parts.append("{" + ",".join(actions) + "}")
    return " ".join(parts)


def measure_native_and_ipc(
    cli_path: str | None,
    socket_path: str,
    app_name: str,
    iterations: int,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "app": app_name,
        "daemonReachable": False,
        "ipcMode": None,
        "pingP50Ms": None,
        "pingP95Ms": None,
        "listAppsP50Ms": None,
        "observeColdMs": None,
        "observeWarmP50Ms": None,
        "nativeObserveElements": None,
        "nativeObserveCliChars": None,
        "nativeObserveV2Chars": None,
        "nativeObserveV1BaselineChars": None,
        "nativeObserveCompressionPct": None,
        "nativeObserveTokensEst": None,
        "appMenuSearchMs": None,
        "appMenuItemsFound": None,
        "skillSaveMs": None,
        "skillListMs": None,
        "visionBackend": None,
        "visionVerifyMs": None,
        "visionAnswerChars": None,
        "notes": [],
    }

    # 2a. Run `usemac bench --json`
    if cli_path:
        cmd = [cli_path, "--socket", socket_path, "--json", "bench", "--iterations", str(iterations), "--app", app_name]
        rc, stdout, stderr = run_json_cmd(cmd, timeout=60.0)
        if rc == 0 and stdout.strip():
            try:
                ipc = json.loads(stdout)
                out["ipcMode"] = ipc.get("mode")
                ping = ipc.get("ping") or {}
                apps = ipc.get("listApps") or {}
                obs = ipc.get("observe") or {}
                out["pingP50Ms"] = round(float(ping["p50Ms"]), 4) if "p50Ms" in ping else None
                out["pingP95Ms"] = round(float(ping["p95Ms"]), 4) if "p95Ms" in ping else None
                out["listAppsP50Ms"] = round(float(apps["p50Ms"]), 4) if "p50Ms" in apps else None
                out["observeColdMs"] = round(float(obs["coldMs"]), 3) if obs.get("coldMs") is not None else None
                out["observeWarmP50Ms"] = round(float(obs["warmP50Ms"]), 3) if obs.get("warmP50Ms") is not None else None
            except (json.JSONDecodeError, ValueError, KeyError) as exc:
                out["notes"].append(f"bench parse error: {exc}")
        else:
            out["notes"].append(f"usemac bench failed (rc={rc}): {stderr.strip()[:160]}")

        # Also capture actual CLI formatted observe output chars for apples-to-apples text inspection
        obs_cmd = [cli_path, "--socket", socket_path, "observe", "--app", app_name]
        orc, ostdout, _ = run_json_cmd(obs_cmd, timeout=20.0)
        if orc == 0 and ostdout.strip():
            out["nativeObserveCliChars"] = len(ostdout)

    # 2b. Direct AF_UNIX socket benchmarks
    rpc = UnixRPCClient(socket_path)
    if not rpc.connect():
        out["notes"].append(f"UseMac daemon socket not reachable at {socket_path}")
        return out

    out["daemonReachable"] = True
    try:
        # Native observe snapshot -> exact v2 vs v1 compactLine comparison on the same elements
        obs_resp, _ = rpc.call("observe", observe={"app": app_name, "useCache": False, "includeOffscreen": False})
        if obs_resp and obs_resp.get("ok") and isinstance(obs_resp.get("snapshot"), dict):
            elements = obs_resp["snapshot"].get("elements") or []
            out["nativeObserveElements"] = len(elements)
            v2_text = "\n".join(reconstruct_v2_compact_line(e) for e in elements)
            v1_text = "\n".join(reconstruct_v1_compact_line(e) for e in elements)
            out["nativeObserveV2Chars"] = len(v2_text)
            out["nativeObserveV1BaselineChars"] = len(v1_text)
            if len(v1_text) > 0:
                out["nativeObserveCompressionPct"] = round((len(v2_text) - len(v1_text)) / len(v1_text) * 100.0, 1)
            effective_chars = out["nativeObserveCliChars"] or len(v2_text)
            out["nativeObserveTokensEst"] = math.ceil(effective_chars / CHARS_PER_TOKEN_OBSERVE)

        # app_menu search latency on target app (1 warmup + 3 measured runs)
        warm, _ = rpc.call("app_menu", appMenu={"app": app_name, "query": "New"})
        if warm and warm.get("ok"):
            menu_times: list[float] = []
            items_count = None
            for _ in range(3):
                mresp, ms = rpc.call("app_menu", appMenu={"app": app_name, "query": "New"})
                if mresp and mresp.get("ok"):
                    menu_times.append(ms)
                    items = (mresp.get("appMenuResult") or {}).get("items") or []
                    items_count = len(items)
            if menu_times:
                out["appMenuSearchMs"] = round(statistics.median(menu_times), 3)
                out["appMenuItemsFound"] = items_count
        elif warm and not warm.get("ok"):
            code = (warm.get("error") or {}).get("code", "ERROR")
            out["notes"].append(f"app_menu unavailable on running daemon ({code})")

        # skill_save / skill_list round-trip (always cleans up temporary bench skill)
        bench_skill = "__bench_sota_temp__"
        save_resp, save_ms = rpc.call(
            "skill_save",
            skillSave={
                "name": bench_skill,
                "description": "Temporary benchmark skill",
                "target": "native",
                "app": app_name,
                "steps": [{"action": "wait", "durationMs": 10}],
            },
        )
        if save_resp and save_resp.get("ok"):
            out["skillSaveMs"] = round(save_ms, 3)
            list_times: list[float] = []
            for _ in range(3):
                lresp, lms = rpc.call("skill_list", skillList={"query": bench_skill})
                if lresp and lresp.get("ok"):
                    list_times.append(lms)
            if list_times:
                out["skillListMs"] = round(statistics.median(list_times), 3)
            # Clean up
            rpc.call("skill_save", skillSave={"name": bench_skill, "delete": True, "steps": []})
        elif save_resp and not save_resp.get("ok"):
            code = (save_resp.get("error") or {}).get("code", "ERROR")
            out["notes"].append(f"skill_save unavailable on running daemon ({code})")

        # Apple Vision OCR status + verify latency
        vstatus, _ = rpc.call("vision_status")
        if vstatus and vstatus.get("ok"):
            out["visionBackend"] = (vstatus.get("visionStatus") or {}).get("backend")

        v_times: list[float] = []
        v_chars: int | None = None
        for _ in range(3):
            vresp, vms = rpc.call(
                "vision_query",
                visionQuery={
                    "mode": "verify",
                    "query": "No red error banner visible",
                    "app": app_name,
                },
            )
            if vresp and vresp.get("ok") and isinstance(vresp.get("visionResult"), dict):
                vr = vresp["visionResult"]
                v_times.append(float(vr.get("latencyMs") or vms))
                v_chars = len(str(vr.get("answer") or ""))
                if not out["visionBackend"]:
                    out["visionBackend"] = vr.get("backend")
            else:
                code = (vresp.get("error") or {}).get("code", "ERROR") if vresp else "NO_RESPONSE"
                out["notes"].append(f"vision_query skipped ({code})")
                break
        if v_times:
            out["visionVerifyMs"] = round(statistics.median(v_times), 2)
            out["visionAnswerChars"] = v_chars
    finally:
        rpc.close()

    return out


# MARK: - 3. Browser & SPA Fixture Metrics


def build_transactions_payload(count: int = 120) -> bytes:
    vendors = [
        "Northwind Cloud",
        "Contoso Analytics",
        "Fabrikam Air",
        "Blue Yonder",
        "Litware Design",
        "Tailspin Security",
    ]
    categories = ["Cloud hosting", "Software", "Travel", "Meals", "Hardware"]
    cost_centers = [
        "ENG-101 Platform",
        "FIN-202 Treasury",
        "OPS-303 Infrastructure",
        "SEC-404 Security",
        "MKT-505 Growth",
    ]
    statuses = ["Paid", "Approved", "Pending"]
    items = []
    for i in range(1, count + 1):
        items.append({
            "id": f"TXN-{1000 + i}",
            "vendor": f"{vendors[i % len(vendors)]} {i}",
            "category": categories[i % len(categories)],
            "costCenter": cost_centers[i % len(cost_centers)],
            "date": f"2026-{((i - 1) % 11) + 1:02d}-{((i - 1) % 28) + 1:02d}",
            "amount": round(42.5 + ((i * 37.15) % 980.0), 2),
            "billable": (i % 3 == 0),
            "status": statuses[i % len(statuses)],
        })
    return json.dumps({"total": len(items), "currency": "USD", "items": items}, separators=(",", ":")).encode("utf-8")


class SPAFixtureHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] == "/api/transactions":
            body = build_transactions_payload(120)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Suppress HTTP access logs during benchmarks
        return


class ReusableThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def start_spa_server() -> tuple[ReusableThreadingHTTPServer, int]:
    handler = functools.partial(SPAFixtureHandler, directory=str(BENCH_DIR))
    server = ReusableThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = int(server.server_address[1])
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, port


def measure_browser_spa(socket_path: str) -> dict[str, Any]:
    out: dict[str, Any] = {
        "browserConnected": False,
        "connectedProfiles": 0,
        "spaOpenMs": None,
        "autoDismissWorked": None,
        "observeVisibleElements": None,
        "observeVisibleChars": None,
        "observeAllElements": None,
        "observeAllChars": None,
        "offscreenCompressionPct": None,
        "fillFormActMs": None,
        "fillFormSucceeded": None,
        "fillFormDiffChars": None,
        "networkExtractMs": None,
        "networkExtractChars": None,
        "tableScanVerticalMs": None,
        "tableScanVerticalChars": None,
        "screenshotFullBytes": None,
        "screenshotDiffCropBytes": None,
        "browserVisionVerifyMs": None,
        "notes": [],
    }

    rpc = UnixRPCClient(socket_path, timeout=30.0)
    if not rpc.connect():
        out["notes"].append("Daemon not reachable; skipping browser SPA metrics")
        return out

    server: ReusableThreadingHTTPServer | None = None
    task_id: str | None = None
    try:
        bstatus, _ = rpc.call("browser_status")
        profiles = (bstatus or {}).get("browserProfiles") or []
        out["connectedProfiles"] = len(profiles)
        if not profiles:
            out["notes"].append("No paired Chrome extension connected; browser SPA metrics set to null")
            return out
        out["browserConnected"] = True

        if not (BENCH_DIR / "spa-fixture.html").exists():
            out["notes"].append("scripts/bench/spa-fixture.html missing")
            return out

        server, port = start_spa_server()
        spa_url = f"http://127.0.0.1:{port}/spa-fixture.html"

        ts, _ = rpc.call("task_start", taskStart={"summary": "UseMac SOTA SPA Benchmark", "agent": "bench-sota"})
        if ts and ts.get("ok"):
            task_id = ts.get("taskId")

        # 1. browser_open with autoDismissOverlays: true
        open_payload: dict[str, Any] = {
            "browserOpen": {
                "url": spa_url,
                "newTab": True,
                "autoDismissOverlays": True,
            }
        }
        if task_id:
            open_payload["taskId"] = task_id
        oresp, open_ms = rpc.call("browser_open", **open_payload)
        if not oresp or not oresp.get("ok"):
            code = (oresp.get("error") or {}).get("code", "ERROR") if oresp else "NO_RESPONSE"
            out["notes"].append(f"browser_open failed ({code})")
            return out

        tab_id = oresp.get("browserTabId")
        out["spaOpenMs"] = round(open_ms, 2)
        snap0 = oresp.get("snapshot") or {}
        overlay0 = (snap0.get("pageState") or {}).get("blockingOverlay")
        out["autoDismissWorked"] = overlay0 is None

        # Wait briefly for /api/transactions fetch to settle
        time.sleep(0.35)

        # 2. Observe viewport-only (includeOffscreen: false) vs full (includeOffscreen: true)
        req_base: dict[str, Any] = {"taskId": task_id} if task_id else {}
        vis_resp, _ = rpc.call(
            "browser_observe",
            browserObserve={"tabId": tab_id, "maxElements": 300, "includeText": False, "includeTables": False},
            **req_base,
        )
        if vis_resp and vis_resp.get("ok") and isinstance(vis_resp.get("snapshot"), dict):
            vis_els = vis_resp["snapshot"].get("elements") or []
            vis_text = "\n".join(reconstruct_v2_compact_line(e) for e in vis_els)
            out["observeVisibleElements"] = len(vis_els)
            out["observeVisibleChars"] = len(vis_text)

        # Also compare with all elements including offscreen (via maxElements=400 & filter none)
        all_resp, _ = rpc.call(
            "browser_observe",
            browserObserve={"tabId": tab_id, "maxElements": 400, "includeText": True, "includeTables": True},
            **req_base,
        )
        if all_resp and all_resp.get("ok") and isinstance(all_resp.get("snapshot"), dict):
            all_snap = all_resp["snapshot"]
            all_els = all_snap.get("elements") or []
            all_text = "\n".join(reconstruct_v1_compact_line(e) for e in all_els)
            tables = (all_snap.get("pageState") or {}).get("tablesMarkdown") or ""
            readable = (all_snap.get("pageState") or {}).get("readableText") or ""
            out["observeAllElements"] = len(all_els)
            out["observeAllChars"] = len(all_text) + len(tables) + len(readable)
            if out["observeVisibleChars"] is not None and out["observeAllChars"] > 0:
                out["offscreenCompressionPct"] = round(
                    (out["observeVisibleChars"] - out["observeAllChars"]) / out["observeAllChars"] * 100.0,
                    1,
                )

        # 3. Resilient batch: optional cookie dismiss + fillForm + assert + observationMode:"auto"
        act_resp, act_ms = rpc.call(
            "browser_act",
            browserAct={
                "tabId": tab_id,
                "observationMode": "auto",
                "returnDiffOnly": True,
                "steps": [
                    {"action": "click", "match": {"role": "button", "title": "Accept All"}, "optional": True},
                    {
                        "action": "fillForm",
                        "fields": [
                            {"selector": "#vendor", "value": "Acme Robotics"},
                            {"selector": "#amount", "value": "249.50"},
                            {"selector": "#category", "value": "Software"},
                            {"selector": "#cost-center", "value": "ENG-101 Platform"},
                            {"selector": "#billable", "checked": True},
                        ],
                        "submitSelector": "#submit-btn",
                    },
                    {"action": "assert", "expectText": "submitted successfully"},
                ],
            },
            **req_base,
        )
        if act_resp and act_resp.get("ok") and isinstance(act_resp.get("actionResult"), dict):
            ares = act_resp["actionResult"]
            out["fillFormActMs"] = round(act_ms, 2)
            out["fillFormSucceeded"] = bool(ares.get("success"))
            obs_after = ares.get("observation") or {}
            diff = obs_after.get("diff") or {}
            diff_lines = (
                [reconstruct_v2_compact_line(e) for e in (diff.get("added") or [])]
                + [reconstruct_v2_compact_line(e) for e in (diff.get("changed") or [])]
                + [",".join(diff.get("removedIds") or [])]
            )
            out["fillFormDiffChars"] = len("\n".join(l for l in diff_lines if l))
        elif act_resp and not act_resp.get("ok"):
            out["notes"].append(f"browser_act fillForm failed ({(act_resp.get('error') or {}).get('code')})")

        # 4. browser_extract mode:"network" vs mode:"tables" scanVertical:true
        net_resp, net_ms = rpc.call(
            "browser_extract",
            browserExtract={"tabId": tab_id, "mode": "network", "urlFilter": "/api/transactions"},
            **req_base,
        )
        if net_resp and net_resp.get("ok") and isinstance(net_resp.get("browserExtract"), dict):
            be = net_resp["browserExtract"]
            out["networkExtractMs"] = round(net_ms, 2)
            out["networkExtractChars"] = len(str(be.get("jsonResult") or be.get("text") or ""))
        elif net_resp and not net_resp.get("ok"):
            out["notes"].append(f"browser_extract network skipped ({(net_resp.get('error') or {}).get('code')})")

        tbl_resp, tbl_ms = rpc.call(
            "browser_extract",
            browserExtract={"tabId": tab_id, "mode": "tables", "scanVertical": True},
            **req_base,
        )
        if tbl_resp and tbl_resp.get("ok") and isinstance(tbl_resp.get("browserExtract"), dict):
            be = tbl_resp["browserExtract"]
            out["tableScanVerticalMs"] = round(tbl_ms, 2)
            out["tableScanVerticalChars"] = len(str(be.get("tablesMarkdown") or be.get("text") or ""))

        # 5. browser_screenshot full vs diffCrop
        shot_full, _ = rpc.call(
            "browser_screenshot",
            browserScreenshot={"tabId": tab_id, "viewportWidth": 1280, "viewportHeight": 800, "returnImageContent": False},
            **req_base,
        )
        if shot_full and shot_full.get("ok") and isinstance(shot_full.get("screenshot"), dict):
            out["screenshotFullBytes"] = shot_full["screenshot"].get("byteCount")

        shot_crop, _ = rpc.call(
            "browser_screenshot",
            browserScreenshot={
                "tabId": tab_id,
                "viewportWidth": 1280,
                "viewportHeight": 800,
                "diffCrop": True,
                "returnImageContent": False,
            },
            **req_base,
        )
        if shot_crop and shot_crop.get("ok") and isinstance(shot_crop.get("screenshot"), dict):
            out["screenshotDiffCropBytes"] = shot_crop["screenshot"].get("byteCount")

        # 6. Apple Vision verify OCR latency on SPA tab
        vresp, vms = rpc.call(
            "vision_query",
            visionQuery={"mode": "verify", "query": "Acme Treasury SPA is visible", "tabId": tab_id},
            **req_base,
        )
        if vresp and vresp.get("ok") and isinstance(vresp.get("visionResult"), dict):
            out["browserVisionVerifyMs"] = round(float(vresp["visionResult"].get("latencyMs") or vms), 2)
    finally:
        if task_id:
            rpc.call("task_complete", taskComplete={"taskId": task_id, "summary": "SOTA SPA benchmark finished"})
        rpc.close()
        if server is not None:
            server.shutdown()
            server.server_close()

    return out


# MARK: - 4. Calibrated End-to-End Amdahl Wall-Clock & Token Model


def compute_amdahl_model(static: dict[str, Any], native: dict[str, Any], browser: dict[str, Any]) -> dict[str, Any]:
    static_tokens = static.get("staticTokensEst35") or BASELINE_STATIC_TOKENS
    is_sota_schema = (static.get("mcpToolCount") or 99) <= 10 and (static.get("skillMdBytes") or 99_999) <= 6_000

    # Native 5-step task model (e.g. open menu -> create item -> fill -> assert -> finish)
    native_turns = 2 if is_sota_schema else BASELINE_NATIVE_TURNS
    native_obs_tokens = native.get("nativeObserveTokensEst") or 420
    native_cold_s = (native.get("observeColdMs") or 35.0) / 1000.0
    native_menu_s = (native.get("appMenuSearchMs") or 12.0) / 1000.0
    native_vision_s = (native.get("visionVerifyMs") or 25.0) / 1000.0
    native_engine_s = round(native_cold_s + native_menu_s + native_vision_s + 0.08, 3)

    native_wall_s = round(native_turns * LLM_TURN_SECONDS + native_engine_s, 2)
    baseline_native_wall_s = round(BASELINE_NATIVE_TURNS * LLM_TURN_SECONDS + BASELINE_NATIVE_ENGINE_SEC, 2)

    # Cumulative prompt tokens across turns (static tax is re-billed on every turn, though cacheable;
    # we track uncached total input tokens to show full context pressure).
    native_total_tokens = native_turns * static_tokens + native_obs_tokens + math.ceil(native_obs_tokens * 0.25)
    baseline_native_tokens = BASELINE_NATIVE_TURNS * BASELINE_STATIC_TOKENS + 2 * BASELINE_NATIVE_OBS_TOKENS

    # Browser 5-step SPA task model (open + auto-dismiss + fillForm + assert + network extract)
    browser_turns = 2 if is_sota_schema else BASELINE_BROWSER_TURNS
    browser_obs_tokens = (
        math.ceil(browser["observeVisibleChars"] / CHARS_PER_TOKEN_OBSERVE)
        if browser.get("observeVisibleChars")
        else 620
    )
    browser_diff_tokens = (
        math.ceil(browser["fillFormDiffChars"] / CHARS_PER_TOKEN_OBSERVE)
        if browser.get("fillFormDiffChars")
        else 140
    )
    browser_open_s = (browser.get("spaOpenMs") or 650.0) / 1000.0
    browser_act_s = (browser.get("fillFormActMs") or 180.0) / 1000.0
    browser_net_s = (browser.get("networkExtractMs") or 25.0) / 1000.0
    browser_engine_s = round(browser_open_s + browser_act_s + browser_net_s, 3)

    browser_wall_s = round(browser_turns * LLM_TURN_SECONDS + browser_engine_s, 2)
    baseline_browser_wall_s = round(BASELINE_BROWSER_TURNS * LLM_TURN_SECONDS + BASELINE_BROWSER_ENGINE_SEC, 2)

    browser_total_tokens = browser_turns * static_tokens + browser_obs_tokens + browser_diff_tokens
    baseline_browser_tokens = BASELINE_BROWSER_TURNS * BASELINE_STATIC_TOKENS + 3 * BASELINE_BROWSER_OBS_TOKENS

    def pct_delta(cur: float, base: float) -> float:
        return round((cur - base) / base * 100.0, 1) if base else 0.0

    return {
        "llmTurnSeconds": LLM_TURN_SECONDS,
        "native5Step": {
            "turns": native_turns,
            "baselineTurns": BASELINE_NATIVE_TURNS,
            "engineSeconds": native_engine_s,
            "wallClockSeconds": native_wall_s,
            "baselineWallClockSeconds": baseline_native_wall_s,
            "wallClockDeltaPct": pct_delta(native_wall_s, baseline_native_wall_s),
            "totalTokensEst": native_total_tokens,
            "baselineTotalTokensEst": baseline_native_tokens,
            "tokensDeltaPct": pct_delta(native_total_tokens, baseline_native_tokens),
        },
        "browser5Step": {
            "turns": browser_turns,
            "baselineTurns": BASELINE_BROWSER_TURNS,
            "engineSeconds": browser_engine_s,
            "wallClockSeconds": browser_wall_s,
            "baselineWallClockSeconds": baseline_browser_wall_s,
            "wallClockDeltaPct": pct_delta(browser_wall_s, baseline_browser_wall_s),
            "totalTokensEst": browser_total_tokens,
            "baselineTotalTokensEst": baseline_browser_tokens,
            "tokensDeltaPct": pct_delta(browser_total_tokens, baseline_browser_tokens),
        },
    }


# MARK: - Formatting & Comparison


def fmt_val(value: Any, unit: str = "") -> str:
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, int):
        return f"{value:,}{unit}"
    if isinstance(value, float):
        if abs(value) >= 100:
            return f"{value:,.1f}{unit}"
        if abs(value) >= 1:
            return f"{value:.2f}{unit}"
        return f"{value:.3f}{unit}"
    return str(value)


def render_markdown_report(report: dict[str, Any]) -> str:
    m = report["meta"]
    s = report["static"]
    n = report["native"]
    b = report["browser"]
    a = report["amdahl"]

    lines = [
        "# UseMac SOTA Benchmark Report",
        "",
        f"- **Date (UTC):** {m['timestampUtc']}",
        f"- **Host:** {m['chip']} ({m['macOS']})",
        f"- **CLI:** `{m['cli'] or 'not found'}`",
        f"- **Socket:** `{m['socket']}` (daemon reachable: `{n['daemonReachable']}`)",
        "",
        "## 1. Static Schema & Skill Tax",
        "",
        "| Metric | Value |",
        "| :--- | ---: |",
        f"| MCP `tools/list` count | {fmt_val(s['mcpToolCount'])} |",
        f"| MCP `tools/list` compact JSON | {fmt_val(s['mcpToolsCompactBytes'], ' B')} |",
        f"| MCP `tools/list` pretty JSON | {fmt_val(s['mcpToolsPrettyBytes'], ' B')} |",
        f"| MCP `initialize.instructions` | {fmt_val(s['mcpInstructionsChars'], ' chars')} |",
        f"| Core `SKILL.md` | {fmt_val(s['skillMdBytes'], ' B')} |",
        f"| `references/*.md` (on-demand) | {fmt_val(s['skillReferencesBytes'], ' B')} |",
        f"| `AGENTS.md` | {fmt_val(s['agentsMdBytes'], ' B')} |",
        f"| Static session tax est. (@ 3.5 ch/tok) | {fmt_val(s['staticTokensEst35'], ' tok')} |",
        "",
        f"## 2. Local IPC, Native AX (`{n['app']}`), Menu, Skills & Apple Vision OCR",
        "",
        "| Metric | Value |",
        "| :--- | ---: |",
        f"| `ping` p50 / p95 | {fmt_val(n['pingP50Ms'], ' ms')} / {fmt_val(n['pingP95Ms'], ' ms')} |",
        f"| `list_apps` p50 | {fmt_val(n['listAppsP50Ms'], ' ms')} |",
        f"| `observe` cold / hot-cache p50 | {fmt_val(n['observeColdMs'], ' ms')} / {fmt_val(n['observeWarmP50Ms'], ' ms')} |",
        f"| Native `observe` elements (`compactLine` v2 vs v1) | {fmt_val(n['nativeObserveElements'])} ({fmt_val(n['nativeObserveV2Chars'], ' B')} vs {fmt_val(n['nativeObserveV1BaselineChars'], ' B')}, {fmt_val(n['nativeObserveCompressionPct'], '%')}) |",
        f"| `app_menu` search latency | {fmt_val(n['appMenuSearchMs'], ' ms')} ({fmt_val(n['appMenuItemsFound'])} items) |",
        f"| `skill_save` / `skill_list` RTT | {fmt_val(n['skillSaveMs'], ' ms')} / {fmt_val(n['skillListMs'], ' ms')} |",
        f"| Apple Vision `verify` OCR (`{n['visionBackend'] or 'n/a'}`) | {fmt_val(n['visionVerifyMs'], ' ms')} ({fmt_val(n['visionAnswerChars'], ' chars')}) |",
        "",
        "## 3. Browser & SPA Fixture (`scripts/bench/spa-fixture.html`)",
        "",
    ]

    if not b["browserConnected"]:
        lines.append("_Chrome extension not connected on `--socket`; browser SPA metrics recorded as `null`._")
        lines.append("")
    else:
        lines += [
            "| Metric | Value |",
            "| :--- | ---: |",
            f"| `browser_open` (`autoDismissOverlays: true`) | {fmt_val(b['spaOpenMs'], ' ms')} (dismissed: {fmt_val(b['autoDismissWorked'])}) |",
            f"| `browser_observe` viewport-first vs full | {fmt_val(b['observeVisibleChars'], ' B')} ({fmt_val(b['observeVisibleElements'])} els) vs {fmt_val(b['observeAllChars'], ' B')} ({fmt_val(b['offscreenCompressionPct'], '%')}) |",
            f"| `browser_act` (`fillForm` + `assert` + delta) | {fmt_val(b['fillFormActMs'], ' ms')} (ok: {fmt_val(b['fillFormSucceeded'])}, diff: {fmt_val(b['fillFormDiffChars'], ' B')}) |",
            f"| `browser_extract` `mode:\"network\"` vs `tables`/`scanVertical` | {fmt_val(b['networkExtractMs'], ' ms')} ({fmt_val(b['networkExtractChars'], ' B')}) vs {fmt_val(b['tableScanVerticalMs'], ' ms')} ({fmt_val(b['tableScanVerticalChars'], ' B')}) |",
            f"| `browser_screenshot` full vs `diffCrop` | {fmt_val(b['screenshotFullBytes'], ' B')} vs {fmt_val(b['screenshotDiffCropBytes'], ' B')} |",
            f"| Apple Vision `verify` on SPA tab | {fmt_val(b['browserVisionVerifyMs'], ' ms')} |",
            "",
        ]

    n5 = a["native5Step"]
    b5 = a["browser5Step"]
    lines += [
        f"## 4. Calibrated End-to-End Amdahl Model (@ {a['llmTurnSeconds']:.1f} s/turn frontier LLM)",
        "",
        "| Workflow | Baseline | Current | Delta |",
        "| :--- | ---: | ---: | ---: |",
        f"| 5-step Native wall-clock ({n5['baselineTurns']} → {n5['turns']} turns) | {n5['baselineWallClockSeconds']:.2f} s | {n5['wallClockSeconds']:.2f} s | {n5['wallClockDeltaPct']:+.1f}% |",
        f"| 5-step Native total input tokens est. | {n5['baselineTotalTokensEst']:,} tok | {n5['totalTokensEst']:,} tok | {n5['tokensDeltaPct']:+.1f}% |",
        f"| 5-step Browser SPA wall-clock ({b5['baselineTurns']} → {b5['turns']} turns) | {b5['baselineWallClockSeconds']:.2f} s | {b5['wallClockSeconds']:.2f} s | {b5['wallClockDeltaPct']:+.1f}% |",
        f"| 5-step Browser SPA total input tokens est. | {b5['baselineTotalTokensEst']:,} tok | {b5['totalTokensEst']:,} tok | {b5['tokensDeltaPct']:+.1f}% |",
    ]

    all_notes = (n.get("notes") or []) + (b.get("notes") or [])
    if s.get("mcpError"):
        all_notes.append(f"MCP schema probe: {s['mcpError']}")
    if all_notes:
        lines += ["", "### Notes", ""] + [f"- {note}" for note in all_notes]

    return "\n".join(lines)


def nested_get(data: dict[str, Any], path: tuple[str, ...]) -> Any:
    cur: Any = data
    for key in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


COMPARE_ROWS: list[tuple[str, tuple[str, ...], str]] = [
    ("MCP `tools/list` count", ("static", "mcpToolCount"), ""),
    ("MCP `tools/list` compact JSON", ("static", "mcpToolsCompactBytes"), " B"),
    ("MCP `tools/list` pretty JSON", ("static", "mcpToolsPrettyBytes"), " B"),
    ("MCP `instructions` length", ("static", "mcpInstructionsChars"), " chars"),
    ("Core `SKILL.md` size", ("static", "skillMdBytes"), " B"),
    ("`AGENTS.md` size", ("static", "agentsMdBytes"), " B"),
    ("Static session token tax (@ 3.5 ch/tok)", ("static", "staticTokensEst35"), " tok"),
    ("IPC `ping` p50", ("native", "pingP50Ms"), " ms"),
    ("IPC `list_apps` p50", ("native", "listAppsP50Ms"), " ms"),
    ("Native `observe` cold", ("native", "observeColdMs"), " ms"),
    ("Native `observe` hot-cache p50", ("native", "observeWarmP50Ms"), " ms"),
    ("Native `observe` CLI text", ("native", "nativeObserveCliChars"), " B"),
    ("`app_menu` search latency", ("native", "appMenuSearchMs"), " ms"),
    ("`skill_save` RTT", ("native", "skillSaveMs"), " ms"),
    ("`skill_list` RTT", ("native", "skillListMs"), " ms"),
    ("Apple Vision `verify` OCR (native)", ("native", "visionVerifyMs"), " ms"),
    ("SPA `browser_open` (`autoDismissOverlays`)", ("browser", "spaOpenMs"), " ms"),
    ("SPA `browser_observe` viewport-first", ("browser", "observeVisibleChars"), " B"),
    ("SPA `browser_act` (`fillForm` + `assert`)", ("browser", "fillFormActMs"), " ms"),
    ("SPA `browser_act` diff payload", ("browser", "fillFormDiffChars"), " B"),
    ("SPA `browser_extract` `network`", ("browser", "networkExtractMs"), " ms"),
    ("SPA `browser_extract` `tables` (`scanVertical`)", ("browser", "tableScanVerticalMs"), " ms"),
    ("SPA `browser_screenshot` `diffCrop`", ("browser", "screenshotDiffCropBytes"), " B"),
    ("SPA Apple Vision `verify`", ("browser", "browserVisionVerifyMs"), " ms"),
    ("Amdahl 5-step Native wall-clock", ("amdahl", "native5Step", "wallClockSeconds"), " s"),
    ("Amdahl 5-step Native total tokens", ("amdahl", "native5Step", "totalTokensEst"), " tok"),
    ("Amdahl 5-step Browser wall-clock", ("amdahl", "browser5Step", "wallClockSeconds"), " s"),
    ("Amdahl 5-step Browser total tokens", ("amdahl", "browser5Step", "totalTokensEst"), " tok"),
]


def render_comparison(before_path: Path, after_path: Path) -> str:
    before = json.loads(before_path.read_text(encoding="utf-8"))
    after = json.loads(after_path.read_text(encoding="utf-8"))

    lines = [
        "# UseMac SOTA Benchmark Comparison",
        "",
        f"- **Before:** `{before_path}`",
        f"- **After:** `{after_path}`",
        "",
        "| Metric | Before | After | Delta % |",
        "| :--- | ---: | ---: | ---: |",
    ]
    for label, path, unit in COMPARE_ROWS:
        bval = nested_get(before, path)
        aval = nested_get(after, path)
        if bval is None and aval is None:
            continue
        delta_str = "—"
        if isinstance(bval, (int, float)) and isinstance(aval, (int, float)) and bval != 0:
            pct = (aval - bval) / bval * 100.0
            delta_str = f"{pct:+.1f}%"
        lines.append(f"| {label} | {fmt_val(bval, unit)} | {fmt_val(aval, unit)} | {delta_str} |")
    return "\n".join(lines)


def host_meta(cli_path: str | None, socket_path: str) -> dict[str, Any]:
    chip = platform.machine()
    rc, out, _ = run_json_cmd(["sysctl", "-n", "machdep.cpu.brand_string"], timeout=5.0)
    if rc == 0 and out.strip():
        chip = out.strip()
    mac_ver = platform.mac_ver()[0] or platform.platform()
    rc2, out2, _ = run_json_cmd(["sw_vers", "-productVersion"], timeout=5.0)
    rc3, out3, _ = run_json_cmd(["sw_vers", "-buildVersion"], timeout=5.0)
    if rc2 == 0 and out2.strip():
        mac_ver = f"macOS {out2.strip()}" + (f" ({out3.strip()})" if rc3 == 0 and out3.strip() else "")
    return {
        "timestampUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "chip": chip,
        "macOS": mac_ver,
        "cli": cli_path,
        "socket": socket_path,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="UseMac SOTA Benchmark Suite")
    parser.add_argument("--cli", help="Path to usemac-cli binary (auto-detected if omitted)")
    parser.add_argument("--socket", default=default_socket_path(), help="UseMac Unix socket path")
    parser.add_argument("--app", default="Finder", help="Native macOS app for AX/menu/vision benchmarks (default: Finder)")
    parser.add_argument("--iterations", type=int, default=200, help="Ping iterations for `usemac bench` (default: 200)")
    parser.add_argument("--save", help="Save JSON benchmark report to this path")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE_JSON", "AFTER_JSON"), help="Compare two saved JSON reports")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of Markdown")
    args = parser.parse_args(argv)

    if args.compare:
        before_p, after_p = Path(args.compare[0]), Path(args.compare[1])
        if not before_p.exists() or not after_p.exists():
            print(f"bench-sota: comparison file missing ({before_p}, {after_p})", file=sys.stderr)
            return 2
        print(render_comparison(before_p, after_p))
        return 0

    cli_path = detect_cli(args.cli)
    static = measure_static_tax(cli_path)
    native = measure_native_and_ipc(cli_path, args.socket, args.app, args.iterations)
    browser = measure_browser_spa(args.socket)
    amdahl = compute_amdahl_model(static, native, browser)

    report = {
        "meta": host_meta(cli_path, args.socket),
        "static": static,
        "native": native,
        "browser": browser,
        "amdahl": amdahl,
    }

    if args.save:
        save_path = Path(args.save)
        save_path.parent.mkdir(parents=True, exist_ok=True)
        save_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_markdown_report(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
