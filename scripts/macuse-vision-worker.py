#!/usr/bin/env python3
"""
MacUse Local Vision Worker (Apple Silicon MLX-VLM NDJSON sidecar)
Reads one JSON request per line on stdin and emits one JSON response per line on stdout.
"""

import gc
import json
import os
import re
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple

from PIL import Image

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TQDM_DISABLE", "1")

_loaded_model_id: Optional[str] = None
_model: Any = None
_processor: Any = None
_config: Any = None


def _emit(payload: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _unload_model() -> None:
    global _loaded_model_id, _model, _processor, _config
    _loaded_model_id = None
    _model = None
    _processor = None
    _config = None
    gc.collect()
    try:
        import mlx.core as mx
        mx.clear_cache()
    except Exception:
        pass


def _ensure_model(model_id: str) -> None:
    global _loaded_model_id, _model, _processor, _config
    if _loaded_model_id == model_id and _model is not None and _processor is not None:
        return
    if _model is not None:
        _unload_model()
    from mlx_vlm import load
    from mlx_vlm.utils import load_config

    _model, _processor = load(model_id)
    _config = load_config(model_id)
    _loaded_model_id = model_id


def _prepare_image(image_path: str, max_side: int = 1024) -> Tuple[str, int, int, bool]:
    with Image.open(image_path) as im:
        im = im.convert("RGB")
        orig_w, orig_h = im.size
        scale = min(1.0, float(max_side) / float(max(orig_w, orig_h)))
        if scale < 0.999:
            new_w = max(64, int(round(orig_w * scale)))
            new_h = max(64, int(round(orig_h * scale)))
            # Keep dimensions divisible by 28 for Qwen2.5-VL patch alignment
            new_w = max(28, (new_w // 28) * 28)
            new_h = max(28, (new_h // 28) * 28)
            resized = im.resize((new_w, new_h), Image.Resampling.LANCZOS)
            fd, tmp_path = tempfile.mkstemp(prefix="macuse-vlm-", suffix=".jpg")
            os.close(fd)
            resized.save(tmp_path, format="JPEG", quality=88)
            return tmp_path, new_w, new_h, True
        return image_path, orig_w, orig_h, False


def _uses_normalized_1000_coords() -> bool:
    mt = ""
    if isinstance(_config, dict):
        mt = str(_config.get("model_type") or "").lower()
    elif _config is not None:
        mt = str(getattr(_config, "model_type", "") or "").lower()
    return ("qwen3" in mt) or ("qwen2_vl" in mt)


def _map_coord(val: float, img_dim: int, vp_dim: float) -> float:
    if 0.0 <= val <= 1.0:
        return round(val * vp_dim, 1)
    if _uses_normalized_1000_coords() and val <= 1000.0:
        return round((val / 1000.0) * vp_dim, 1)
    if val <= img_dim * 1.04:
        return round((val / float(img_dim)) * vp_dim, 1)
    if val <= 1000.0:
        return round((val / 1000.0) * vp_dim, 1)
    return round(min(max(val, 0.0), vp_dim), 1)


def _extract_json_block(text: str) -> Optional[Dict[str, Any]]:
    cleaned = text.strip()
    decoder = json.JSONDecoder()
    # Try fenced block first
    fence = re.search(r"```(?:json)?\s*([\{\[].*?[\}\]])\s*```", cleaned, re.S)
    candidates = [fence.group(1).strip()] if fence else []
    candidates.append(cleaned)
    for blob in candidates:
        for idx, ch in enumerate(blob):
            if ch in "{[":
                try:
                    parsed, _ = decoder.raw_decode(blob[idx:])
                    if isinstance(parsed, dict):
                        return parsed
                    if isinstance(parsed, list) and parsed and isinstance(parsed[0], dict):
                        return parsed[0]
                except Exception:
                    continue
    return None


def _parse_spatial_output(
    raw_text: str, img_w: int, img_h: int, vp_w: float, vp_h: float, default_label: str
) -> Dict[str, Any]:
    data = _extract_json_block(raw_text) or {}
    x_out: Optional[float] = None
    y_out: Optional[float] = None
    frame_out: Optional[Dict[str, float]] = None
    label = str(data.get("label") or data.get("closeLabel") or default_label).strip()
    answer = str(data.get("answer") or "").strip() or raw_text.strip()
    raw_blocking = data.get("blocking")
    if isinstance(raw_blocking, bool):
        blocking = raw_blocking
    else:
        ans_lower = answer.lower()
        blocking = not (ans_lower in ("no", "none", "false", "no.") or ans_lower.startswith("no blocking") or ans_lower.startswith("no popup"))

    # Never hallucinate click points when diagnose explicitly says no blocking overlay
    if raw_blocking is False or answer.lower() in ("no", "no.", "none", "false"):
        return {
            "answer": answer if answer.lower() not in ("no", "no.") else "No blocking overlay detected.",
            "x": None,
            "y": None,
            "frame": None,
            "blockingDetected": False,
            "detections": [],
        }

    bbox = data.get("bbox") or data.get("bbox_2d") or data.get("box")
    if isinstance(bbox, list) and len(bbox) == 4:
        try:
            bx1, by1, bx2, by2 = [float(v) for v in bbox]
            x1 = _map_coord(bx1, img_w, vp_w)
            y1 = _map_coord(by1, img_h, vp_h)
            x2 = _map_coord(bx2, img_w, vp_w)
            y2 = _map_coord(by2, img_h, vp_h)
            if x2 > x1 and y2 > y1:
                frame_out = {
                    "x": round(x1, 1),
                    "y": round(y1, 1),
                    "width": round(x2 - x1, 1),
                    "height": round(y2 - y1, 1),
                }
                x_out = round((x1 + x2) / 2.0, 1)
                y_out = round((y1 + y2) / 2.0, 1)
        except Exception:
            pass

    if x_out is None and data.get("x") is not None and data.get("y") is not None:
        try:
            x_out = _map_coord(float(data["x"]), img_w, vp_w)
            y_out = _map_coord(float(data["y"]), img_h, vp_h)
        except Exception:
            pass

    # Regex fallback for [x1, y1, x2, y2] or (x, y)
    if x_out is None:
        m_box = re.search(r"\[\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\]", raw_text)
        if m_box:
            bx1, by1, bx2, by2 = [float(g) for g in m_box.groups()]
            x1 = _map_coord(bx1, img_w, vp_w)
            y1 = _map_coord(by1, img_h, vp_h)
            x2 = _map_coord(bx2, img_w, vp_w)
            y2 = _map_coord(by2, img_h, vp_h)
            if x2 > x1 and y2 > y1:
                frame_out = {
                    "x": round(x1, 1),
                    "y": round(y1, 1),
                    "width": round(x2 - x1, 1),
                    "height": round(y2 - y1, 1),
                }
                x_out = round((x1 + x2) / 2.0, 1)
                y_out = round((y1 + y2) / 2.0, 1)

    if x_out is None:
        m_pt = re.search(r"\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)", raw_text)
        if m_pt:
            x_out = _map_coord(float(m_pt.group(1)), img_w, vp_w)
            y_out = _map_coord(float(m_pt.group(2)), img_h, vp_h)

    detections: List[Dict[str, Any]] = []
    if x_out is not None and y_out is not None:
        detections.append({
            "label": label or default_label,
            "x": x_out,
            "y": y_out,
            "frame": frame_out,
            "confidence": 0.9,
            "source": "mlx-vlm",
        })

    return {
        "answer": answer,
        "x": x_out,
        "y": y_out,
        "frame": frame_out,
        "blockingDetected": blocking,
        "detections": detections,
    }


def _strip_thinking(text: str) -> str:
    cleaned = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    return cleaned or text.strip()


def _parse_verify_output(raw_text: str, query: str = "") -> Dict[str, Any]:
    cleaned = _strip_thinking(raw_text)
    data = _extract_json_block(cleaned) or {}
    raw_ver = data.get("condition_met") if "condition_met" in data else data.get("verified")
    raw_err = data.get("error_visible")
    answer = str(data.get("answer") or data.get("reason") or "").strip() or cleaned

    if isinstance(raw_ver, bool):
        verified: Optional[bool] = raw_ver
    else:
        low = answer.lower().lstrip()
        if low.startswith(("yes", "true", "sim", "confirmed", "verified")):
            verified = True
        elif low.startswith(("no", "false", "não", "nao", "not ", "failed")):
            verified = False
        else:
            verified = None

    # Guardrail for small VLMs: if an error banner is visible and the assertion expected success / no errors, verified must be False
    q_low = query.lower()
    ans_low = answer.lower()
    expects_no_error = any(k in q_low for k in ("no error", "no red error", "without error", "sem erro", "succeeded", "successfully"))
    ans_negates_error = bool(re.search(r"\b(no|without|zero|sem)\b(?:\s+\w+){0,2}\s+(?:error|errors)\b", ans_low))
    ans_reports_error = (not ans_negates_error) and any(
        k in ans_low for k in ("error message", "error banner", "is invalid", "already exists", "contradicts", "failed to")
    )
    if expects_no_error and (raw_err is True or ans_reports_error):
        verified = False

    return {
        "answer": answer,
        "verified": verified,
        "x": None,
        "y": None,
        "frame": None,
        "blockingDetected": False,
        "detections": [],
    }


def _handle_query(req: Dict[str, Any]) -> Dict[str, Any]:
    t0 = time.perf_counter()
    model_id = req.get("model") or "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
    mode = (req.get("mode") or "ask").lower().strip()
    query = (req.get("query") or "").strip()
    ocr_context = (req.get("ocrContext") or "").strip()
    image_path = req.get("imagePath")
    vp_w = float(req.get("viewportWidth") or 1280.0)
    vp_h = float(req.get("viewportHeight") or 800.0)

    if not image_path or not os.path.exists(image_path):
        raise ValueError(f"Image not found: {image_path}")

    _ensure_model(model_id)

    # Higher resolution for text/UI comprehension (ask/verify/describe); compact for fast grounding (locate/diagnose)
    if mode in ("ask", "verify", "describe"):
        max_side = 896
    else:
        max_side = 544 if _uses_normalized_1000_coords() else 672

    prep_path, img_w, img_h, is_tmp = _prepare_image(image_path, max_side=max_side)
    try:
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        ocr_block = ""
        if ocr_context:
            trimmed_ocr = ocr_context[:1800]
            ocr_block = (
                f"\nExact OCR text detected on screen (trust exact spelling for hostnames, codes, numbers, and error messages):\n"
                f"{trimmed_ocr}\n"
            )

        if mode == "ask":
            q_text = query or "Describe what is currently shown on this screen, including any errors, status messages, or key values."
            user_prompt = (
                f"You are a strict, factual local UI visual assistant inspecting a {img_w}x{img_h} macOS/browser screenshot."
                f"{ocr_block}"
                f"Answer concisely in 1-3 short plain-text sentences (no markdown fluff). "
                f"Copy exact strings from the OCR text above for hostnames, codes, emails, or numbers. "
                f"NEVER guess or invent unreadable/covered text — if a value is blurry or obscured, explicitly say it is not legible.\n"
                f"Question: {q_text}"
            )
            max_toks = 128
        elif mode == "verify":
            q_text = query or "The expected visual update succeeded with no visible error."
            user_prompt = (
                f"You are strictly verifying whether a UI screenshot satisfies a target assertion."
                f"{ocr_block}"
                f"Target assertion: \"{q_text}\"\n"
                f"Rules: Set error_visible=true if any red error/failure banner is shown. "
                f"Set condition_met=true ONLY if every part of the assertion is actually satisfied on screen (if an error contradicts it, condition_met MUST be false).\n"
                f'Reply ONLY compact JSON: {{"condition_met": true/false, "error_visible": true/false, "answer": "short factual visual evidence (1-2 sentences)"}}'
            )
            max_toks = 104
        elif mode == "describe":
            focus_hint = f" Focus especially on: {query}." if query else ""
            user_prompt = (
                f"Summarize the current UI state in this {img_w}x{img_h} screenshot in 2-4 crisp bullet points: "
                f"active page/modal, any red errors/warnings/disabled states, key generated/displayed values, and primary buttons.{focus_hint}"
                f"{ocr_block}"
                f"Use plain concise text with exact OCR values where relevant."
            )
            max_toks = 160
        elif mode == "diagnose":
            user_prompt = (
                f"In this {img_w}x{img_h} UI screenshot, check if a popup, ad banner, modal, validation error, disabled button, or overlay is blocking the user."
                f"{ocr_block}"
                f"Context: {query or 'Find any blocking overlay and its small X close or dismiss button (NOT Allow/Eu quero), or any red error/disabled control.'}\n"
                f"Reply ONLY compact JSON: "
                f'{{"blocking": true/false, "answer": "short reason", "label": "X", "bbox_2d": [x1,y1,x2,y2]}}'
            )
            max_toks = 88
        else:
            user_prompt = (
                f"In this {img_w}x{img_h} UI screenshot, locate \"{query}\". "
                f'Reply ONLY compact JSON: {{"found": true, "label": "short", "bbox_2d": [x1,y1,x2,y2]}}'
            )
            max_toks = 44

        try:
            formatted = apply_chat_template(
                _processor,
                _config,
                user_prompt,
                num_images=1,
                enable_thinking=False,
            )
        except TypeError:
            formatted = apply_chat_template(
                _processor,
                _config,
                user_prompt,
                num_images=1,
            )
        result = generate(
            _model,
            _processor,
            formatted,
            image=[prep_path],
            max_tokens=max_toks,
            temp=0.0,
            verbose=False,
        )
        raw_text = _strip_thinking(result.text if hasattr(result, "text") else str(result))

        if mode in ("ask", "describe"):
            parsed = {
                "answer": raw_text,
                "verified": None,
                "x": None,
                "y": None,
                "frame": None,
                "blockingDetected": False,
                "detections": [],
            }
        elif mode == "verify":
            parsed = _parse_verify_output(raw_text, query=query)
        else:
            parsed = _parse_spatial_output(raw_text, img_w, img_h, vp_w, vp_h, query or "target")
            parsed["verified"] = None

        latency_ms = round((time.perf_counter() - t0) * 1000.0, 2)
        return {
            "ok": True,
            "mode": mode,
            "backend": "mlx-vlm",
            "modelId": model_id,
            "latencyMs": latency_ms,
            "answer": parsed["answer"],
            "verified": parsed.get("verified"),
            "x": parsed["x"],
            "y": parsed["y"],
            "frame": parsed["frame"],
            "blockingDetected": parsed["blockingDetected"],
            "detections": parsed["detections"],
        }
    finally:
        if is_tmp and os.path.exists(prep_path):
            try:
                os.unlink(prep_path)
            except Exception:
                pass


def main() -> None:
    _emit({"type": "ready", "pid": os.getpid()})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = ""
        try:
            req = json.loads(line)
            req_id = str(req.get("id", ""))
            cmd = req.get("cmd", "")
            if cmd == "ping":
                _emit({"id": req_id, "ok": True, "loadedModel": _loaded_model_id})
            elif cmd == "load":
                model_id = req.get("model") or "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
                _ensure_model(model_id)
                _emit({"id": req_id, "ok": True, "loadedModel": _loaded_model_id})
            elif cmd == "unload":
                _unload_model()
                _emit({"id": req_id, "ok": True})
            elif cmd == "query":
                out = _handle_query(req)
                out["id"] = req_id
                _emit(out)
            elif cmd == "shutdown":
                _unload_model()
                _emit({"id": req_id, "ok": True})
                break
            else:
                _emit({"id": req_id, "ok": False, "error": f"Unknown command: {cmd}"})
        except Exception as exc:
            _emit({"id": req_id, "ok": False, "error": str(exc)})


if __name__ == "__main__":
    main()
