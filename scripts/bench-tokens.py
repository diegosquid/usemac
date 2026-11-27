#!/usr/bin/env python3
"""Summarize a scripts/bench.sh run: IPC latency and text-observation vs screenshot tokens.

    python3 scripts/bench-tokens.py <bench-output-dir> [--count-tokens] [--model <id>]

Screenshot tokens follow Anthropic's documented estimate for images, tokens ~= width * height / 750, after the
API's own downscale: an image is shrunk to fit 1568 px on the long edge and about 1,600 tokens (newer high-resolution
models allow up to 2576 px, so a large capture can cost them up to ~3x more; this script uses the smaller limit, which
makes the screenshot side cheaper and the comparison conservative).

Text tokens are estimated at one token per CHARS_PER_TOKEN characters unless --count-tokens is given, which sends
each capture (text and image) to Anthropic's count_tokens endpoint and uses the exact counts (needs
ANTHROPIC_API_KEY; count_tokens is free but rate-limited).
"""

import base64
import json
import math
import os
import re
import sys
import urllib.request
from pathlib import Path

# Compact observation text is dense with ids, roles, labels and punctuation, which tokenize into short pieces:
# a line like `@b11 [input] "Who did you pay?"` or `@b11 [AXTextField] "Who did you pay?" (275,165 468x37)`
# tokenizes densely; 2.5 characters per token errs on the high side (English prose is closer to 4), so the text
# side is never undercounted.
CHARS_PER_TOKEN = 2.5
IMAGE_MAX_EDGE = 1568
IMAGE_MAX_TOKENS = 1600


def image_tokens(width: int, height: int) -> tuple[int, int, int]:
    scale = min(1.0, IMAGE_MAX_EDGE / max(width, height), math.sqrt(IMAGE_MAX_TOKENS * 750 / (width * height)))
    w, h = int(width * scale), int(height * scale)
    return math.ceil(w * h / 750), w, h


def count_tokens(model: str, content: list) -> int:
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": content}]}).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages/count_tokens",
        data=body,
        headers={
            "x-api-key": os.environ["ANTHROPIC_API_KEY"],
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as res:
        return json.load(res)["input_tokens"]


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = Path(args[0])
    exact = "--count-tokens" in args
    model = args[args.index("--model") + 1] if "--model" in args else "claude-opus-5-5"
    if exact and not os.environ.get("ANTHROPIC_API_KEY"):
        print("bench-tokens: --count-tokens needs ANTHROPIC_API_KEY", file=sys.stderr)
        return 2

    lines = []
    machine = (out / "machine.txt").read_text().strip().splitlines() if (out / "machine.txt").exists() else []
    lines += ["## Machine", ""] + [f"- {m}" for m in machine] + [""]

    summary: dict = {"machine": machine}
    ipc_path = out / "ipc.json"
    if ipc_path.exists():
        ipc = json.loads(ipc_path.read_text())
        summary["ipc"] = ipc
        ping, apps, obs = ipc["ping"], ipc["listApps"], ipc["observe"]
        lines += [
            f"## Local IPC (`usemac bench`, {ipc['mode']} mode)",
            "",
            "| Request | p50 | p95 | min | avg |",
            "| :--- | ---: | ---: | ---: | ---: |",
            f"| ping ({ping['iterations']}x) | {ping['p50Ms']:.3f} ms | {ping['p95Ms']:.3f} ms | {ping['minMs']:.3f} ms | {ping['avgMs']:.3f} ms |",
            f"| list_apps ({apps['iterations']}x) | {apps['p50Ms']:.3f} ms | | | {apps['avgMs']:.3f} ms |",
        ]
        if obs.get("coldMs") is not None:
            lines.append(f"| observe, cold (1x) | {obs['coldMs']:.3f} ms | | | |")
            lines.append(f"| observe, hot cache ({obs['warmIterations']}x) | {obs['warmP50Ms']:.3f} ms | | | {obs['warmAvgMs']:.3f} ms |")
        elif obs.get("error"):
            lines.append(f"| observe | unavailable: {obs['error']} | | | |")
        lines.append("")

    views = sorted(p.name[: -len(".observe.txt")] for p in (out / "views").glob("*.observe.txt")) if (out / "views").exists() else []
    if views:
        method = f"exact, count_tokens on {model}" if exact else f"estimated: text = characters / {CHARS_PER_TOKEN:g}, image = width x height / 750"
        lines += [
            f"## What the agent reads per look ({method})",
            "",
            "| View | Text observation | Screenshot | Text vs screenshot |",
            "| :--- | ---: | ---: | ---: |",
        ]
        summary["views"] = []
        for name in views:
            text = (out / "views" / f"{name}.observe.txt").read_text()
            shot = json.loads((out / "views" / f"{name}.shot.json").read_text())
            source = (out / "views" / f"{name}.source.txt").read_text().strip()
            img_tokens, sent_w, sent_h = image_tokens(shot["width"], shot["height"])
            text_tokens = math.ceil(len(text) / CHARS_PER_TOKEN)
            if exact:
                base = count_tokens(model, [{"type": "text", "text": "."}])
                text_tokens = count_tokens(model, [{"type": "text", "text": text}]) - base
                data = base64.b64encode((out / "views" / f"{name}.jpg").read_bytes()).decode()
                image = {"type": "image", "source": {"type": "base64", "media_type": shot.get("mimeType", "image/jpeg"), "data": data}}
                img_tokens = count_tokens(model, [image, {"type": "text", "text": "."}]) - base
            change = (text_tokens - img_tokens) / img_tokens * 100
            summary["views"].append({
                "view": name, "source": source, "textChars": len(text), "textTokens": text_tokens,
                "screenshot": [shot["width"], shot["height"]], "sentAs": [sent_w, sent_h], "imageTokens": img_tokens,
                "changePercent": round(change, 1),
            })
            lines.append(
                f"| {name}: {source} | {len(text):,} chars, {text_tokens:,} tokens"
                f" | {shot['width']}x{shot['height']}, {img_tokens:,} tokens | {change:+.0f}% |"
            )
        lines.append("")

    vision_runs = sorted(out.glob("vision-[0-9]*.txt"))
    if vision_runs and summary.get("views"):
        web1 = next((v for v in summary["views"] if v["view"] == "web1"), summary["views"][0])
        assertion = (out / "vision-assertion.txt").read_text().strip()
        lines += [
            f"## Visual check answered on this Mac (`usemac vision verify \"{assertion}\"` on {web1['view']})",
            "",
            "| Run | Inference | Round trip | What the agent reads | vs. sending the screenshot |",
            "| :--- | ---: | ---: | ---: | ---: |",
        ]
        summary["vision"] = []
        for i, path in enumerate(vision_runs, 1):
            text = path.read_text()
            inference = re.search(r"inference: ([0-9.]+) ms", text)
            rtt = re.search(r"rtt: ([0-9.]+) ms", text)
            tokens = math.ceil(len(text) / CHARS_PER_TOKEN)
            if exact:
                base = count_tokens(model, [{"type": "text", "text": "."}])
                tokens = count_tokens(model, [{"type": "text", "text": text}]) - base
            change = (tokens - web1["imageTokens"]) / web1["imageTokens"] * 100
            summary["vision"].append({
                "run": i, "inferenceMs": float(inference.group(1)) if inference else None,
                "roundTripMs": float(rtt.group(1)) if rtt else None, "textChars": len(text), "textTokens": tokens,
                "changePercent": round(change, 1),
            })
            lines.append(
                f"| {i} | {inference.group(1) if inference else '?'} ms | {rtt.group(1) if rtt else '?'} ms"
                f" | {len(text):,} chars, {tokens:,} tokens | {change:+.0f}% |"
            )
        lines.append("")

    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
