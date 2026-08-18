#!/usr/bin/env python3
"""Cross-check the Whisper transcript against platform captions (VTT).

A decoder transcript and platform captions (Teams, YouTube, ...) both
mishear - but rarely in the same way. Where the two independent sources
agree, confidence is high; where they diverge, someone should listen to
the audio. This module slices the timeline into fixed windows, normalizes
both texts, scores each window with a token-level SequenceMatcher ratio,
and reports the windows below threshold as a review list.

The tool never decides which source is right - it only flags divergence.
The review list (<base>.crosscheck.md) is meant for Claude's validation
pass: resolve each flagged window from context/frames/glossary, and put
the rest in front of the user as the "unsichere Stellen" to re-listen to.

CLI (standalone re-run):
    python3 crosscheck.py --segments <base>.segments.json \
        --vtt <base>.original.vtt [-o <base>.crosscheck.md]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from difflib import SequenceMatcher
from pathlib import Path

# Absolute ceiling for "divergent". The effective threshold is adaptive:
# min(this, mean - stdev) over the recording's own window ratios. A pair
# that agrees well (mean ~0.8) is judged against the absolute ceiling; a
# pair that diverges broadly (poor room-mic captions, mean ~0.5) would
# flag half the meeting at a fixed cutoff, so there only the outliers
# below its own baseline count - those are the really broken passages.
DEFAULT_THRESHOLD = 0.55
# The review list is for targeted re-listening; keep the worst N windows.
MAX_FLAGGED = 25
# Window size in seconds: small enough to point at a passage, large
# enough to keep the ratio statistically meaningful.
DEFAULT_WINDOW = 45.0
# Windows where BOTH sources have fewer tokens are skipped (silence,
# music, caption gaps at the margins).
MIN_TOKENS = 8
# One-sided windows: this many tokens on one side with (near) nothing on
# the other is itself a divergence worth flagging.
ONE_SIDED_TOKENS = 25

_TS = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{3})")
_TAG = re.compile(r"<[^>]*>")


def parse_vtt(path: Path) -> list[dict]:
    """Parse a WebVTT file into [{start, end, text}] cues.

    Tolerant of the Teams flavor: cue identifiers, NOTE blocks, voice
    tags (<v Name>...</v>) and hard line-wraps inside a cue.
    """
    cues: list[dict] = []
    cur: dict | None = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip().lstrip("﻿")
        if "-->" in line:
            stamps = _TS.findall(line)
            if len(stamps) >= 2:
                cur = {"start": _seconds(stamps[0]), "end": _seconds(stamps[1]), "text": ""}
                cues.append(cur)
            continue
        if not line or line == "WEBVTT" or line.startswith("NOTE"):
            cur = None if not line else cur
            continue
        if cur is not None:
            text = _TAG.sub("", line).strip()
            if text:
                cur["text"] = f"{cur['text']} {text}".strip()
    return [c for c in cues if c["text"]]


def _seconds(groups: tuple[str, str, str, str]) -> float:
    h, m, s, ms = groups
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000


def _tokens(text: str) -> list[str]:
    """Normalize for comparison: casefold, ss for eszett, drop punctuation,
    join hyphenated compounds (Master-Systeme == Mastersysteme)."""
    text = text.casefold().replace("ß", "ss").replace("-", "")
    return re.findall(r"[a-zà-ÿĀ-ſ0-9]+", text)


def _mmss(t: float) -> str:
    t = int(t)
    return f"{t // 3600}:{t % 3600 // 60:02d}:{t % 60:02d}" if t >= 3600 else f"{t // 60:02d}:{t % 60:02d}"


def crosscheck(segments: list[dict], ref_cues: list[dict],
               window: float = DEFAULT_WINDOW,
               threshold: float = DEFAULT_THRESHOLD) -> dict:
    """Compare two timed transcripts window-wise. Returns
    {"windows": n_compared, "flagged": [...], "mean_ratio": float}."""
    end = max([s["end"] for s in segments] + [c["end"] for c in ref_cues])
    n_win = max(1, int(end // window) + 1)
    ours: list[list[str]] = [[] for _ in range(n_win)]
    theirs: list[list[str]] = [[] for _ in range(n_win)]
    for src, buckets in ((segments, ours), (ref_cues, theirs)):
        for item in src:
            mid = (float(item["start"]) + float(item["end"])) / 2
            buckets[min(int(mid // window), n_win - 1)].append(item["text"])

    scored: list[dict] = []
    one_sided: list[dict] = []
    for i in range(n_win):
        a, b = _tokens(" ".join(ours[i])), _tokens(" ".join(theirs[i]))
        lo, hi = i * window, min((i + 1) * window, end)
        if len(a) < MIN_TOKENS and len(b) < MIN_TOKENS:
            continue
        entry = {"start": lo, "end": hi,
                 "ours": " ".join(ours[i]), "theirs": " ".join(theirs[i])}
        if min(len(a), len(b)) < MIN_TOKENS:
            if max(len(a), len(b)) >= ONE_SIDED_TOKENS:
                missing = "captions" if len(b) < len(a) else "transcript"
                one_sided.append({**entry, "ratio": 0.0,
                                  "reason": f"missing in {missing}"})
            continue
        ratio = SequenceMatcher(None, a, b).ratio()
        scored.append({**entry, "ratio": ratio,
                       "reason": f"similarity {ratio:.0%}"})

    ratios = [w["ratio"] for w in scored]
    mean = sum(ratios) / len(ratios) if ratios else 0.0
    std = (sum((r - mean) ** 2 for r in ratios) / len(ratios)) ** 0.5 if ratios else 0.0
    eff_threshold = min(threshold, mean - std) if ratios else threshold

    flagged = one_sided + [w for w in scored if w["ratio"] < eff_threshold]
    truncated = max(0, len(flagged) - MAX_FLAGGED)
    if truncated:
        flagged = sorted(flagged, key=lambda w: w["ratio"])[:MAX_FLAGGED]
    flagged.sort(key=lambda w: w["start"])
    return {
        "windows": len(ratios),
        "flagged": flagged,
        "truncated": truncated,
        "mean_ratio": mean,
        "threshold": eff_threshold,
    }


def format_report(result: dict, transcript_name: str, ref_name: str) -> str:
    """Render the divergence list as the <base>.crosscheck.md review file."""
    truncated = result.get("truncated", 0)
    lines = [
        "# Crosscheck: Transkript vs. Plattform-Captions",
        "",
        f"Fensterweiser Abgleich von `{transcript_name}` (Whisper) gegen "
        f"`{ref_name}` (Plattform). Beide Quellen verhören - selten gleich: "
        "Wo sie übereinstimmen, ist der Text verlässlich; die Fenster unten "
        "weichen voneinander ab und gehören nachgehört. Das Tool entscheidet "
        "nicht, welche Seite recht hat.",
        "",
        f"- Verglichene Fenster: {result['windows']}"
        f" | mittlere Übereinstimmung: {result['mean_ratio']:.0%}"
        f" | effektive Schwelle: {result['threshold']:.0%} (adaptiv)",
        f"- Auffällige Fenster: **{len(result['flagged'])}**"
        + (f" (die {truncated} mildesten weggelassen)" if truncated else ""),
        "",
    ]
    if not result["flagged"]:
        lines.append("Keine Auffälligkeiten - die Quellen stimmen überall ausreichend überein.")
    for w in result["flagged"]:
        lines += [
            f"## [{_mmss(w['start'])}–{_mmss(w['end'])}] {w['reason']}",
            "",
            f"- **Whisper:** {w['ours'] or '(leer)'}",
            f"- **Captions:** {w['theirs'] or '(leer)'}",
            "",
        ]
    return "\n".join(lines).rstrip() + "\n"


def crosscheck_report(segments: list[dict], vtt_path: Path,
                      transcript_name: str = "transcript",
                      threshold: float = DEFAULT_THRESHOLD,
                      ) -> tuple[str, int, int]:
    """One-call wrapper for run.py: returns (markdown, n_flagged, n_windows)."""
    result = crosscheck(segments, parse_vtt(vtt_path), threshold=threshold)
    report = format_report(result, transcript_name, vtt_path.name)
    return report, len(result["flagged"]), result["windows"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--segments", required=True, help="<base>.segments.json")
    ap.add_argument("--vtt", required=True, help="platform captions (e.g. <base>.original.vtt)")
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--window", type=float, default=DEFAULT_WINDOW)
    ap.add_argument("-o", "--out", help="write the review file here (default: stdout)")
    args = ap.parse_args()

    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    payload = json.loads(Path(args.segments).read_text(encoding="utf-8"))
    segments = payload["segments"] if isinstance(payload, dict) else payload
    result = crosscheck(segments, parse_vtt(Path(args.vtt)),
                        window=args.window, threshold=args.threshold)
    report = format_report(result, Path(args.segments).name, Path(args.vtt).name)
    if args.out:
        Path(args.out).write_text(report, encoding="utf-8")
        print(f"[crosscheck] {len(result['flagged'])} auffällige Fenster -> {args.out}",
              file=sys.stderr)
    else:
        print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
