#!/usr/bin/env python3
"""Parse a WebVTT subtitle file into a clean, timestamped transcript.

YouTube auto-subs emit rolling-duplicate cues (each line appears 2-3 times as it
scrolls). We dedupe consecutive identical cues and merge their time ranges.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


TS_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})[.,](\d{3})"
)
TAG_RE = re.compile(r"<[^>]+>")


def _to_seconds(h: str, m: str, s: str, ms: str) -> float:
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def parse_vtt(path: str) -> list[dict]:
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()

    segments: list[dict] = []
    i = 0
    while i < len(lines):
        match = TS_RE.match(lines[i])
        if not match:
            i += 1
            continue

        start = _to_seconds(*match.groups()[:4])
        end = _to_seconds(*match.groups()[4:])
        i += 1

        cue_lines: list[str] = []
        while i < len(lines) and lines[i].strip():
            cleaned = TAG_RE.sub("", lines[i]).strip()
            if cleaned:
                cue_lines.append(cleaned)
            i += 1

        cue_text = " ".join(cue_lines).strip()
        if cue_text:
            segments.append({"start": round(start, 2), "end": round(end, 2), "text": cue_text})
        i += 1

    return _dedupe(segments)


def _dedupe(segments: list[dict]) -> list[dict]:
    """Collapse rolling duplicates common in YouTube auto-subs."""
    out: list[dict] = []
    for seg in segments:
        if out and seg["text"] == out[-1]["text"]:
            out[-1]["end"] = seg["end"]
            continue
        if out and seg["text"].startswith(out[-1]["text"] + " "):
            out[-1]["text"] = seg["text"]
            out[-1]["end"] = seg["end"]
            continue
        out.append(seg)
    return out


def filter_range(
    segments: list[dict],
    start_seconds: float | None,
    end_seconds: float | None,
) -> list[dict]:
    """Return segments whose time range overlaps [start, end]."""
    if start_seconds is None and end_seconds is None:
        return segments
    lo = start_seconds if start_seconds is not None else float("-inf")
    hi = end_seconds if end_seconds is not None else float("inf")
    return [seg for seg in segments if seg["end"] >= lo and seg["start"] <= hi]


def merge_speaker_turns(segments: list[dict]) -> list[dict]:
    """Collapse consecutive segments by the same speaker into one turn.

    Diarizing backends (gpt-4o-transcribe-diarize, AssemblyAI, pyannote)
    emit many fine-grained segments - often one short phrase each. A
    readable transcript wants one block per speaker turn:
    `[MM:SS] [Speaker] <everything they said until the next speaker change>`.

    Each turn keeps the first segment's `start` and the last segment's
    `end`. Only merges when a `speaker` field is present *and* equal on
    adjacent segments. If no segment carries a speaker at all (plain
    captions / non-diarized Whisper), the input is returned unchanged -
    those transcripts keep their per-segment granularity, which the
    frame-to-transcript alignment relies on.

    The single source of truth for turn-merging - imported by both the
    production transcript formatter and the azure_transcribe_test harness.
    """
    if not segments:
        return []
    if not any(s.get("speaker") for s in segments):
        return list(segments)

    turns: list[dict] = []
    for seg in segments:
        spk = seg.get("speaker")
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        if turns and turns[-1].get("speaker") == spk:
            turns[-1]["text"] = (turns[-1]["text"] + " " + text).strip()
            turns[-1]["end"] = seg.get("end", turns[-1]["end"])
        else:
            turns.append({
                "start": seg.get("start", 0.0),
                "end": seg.get("end", 0.0),
                "text": text,
                "speaker": spk,
            })
    return turns


def format_transcript(segments: list[dict]) -> str:
    """Render `[MM:SS] text` per segment, with `[MM:SS] [<speaker>] text`
    when a speaker label is present (set by diarize.align_speakers /
    diarize.diarize_assemblyai / the azure transcribe-diarize backend).

    When speakers are present, consecutive same-speaker segments are first
    collapsed into turns via `merge_speaker_turns` - one readable block per
    turn instead of one line per fine-grained segment."""
    lines = []
    for seg in merge_speaker_turns(segments):
        start = int(seg["start"])
        stamp = f"[{start // 60:02d}:{start % 60:02d}]"
        speaker = seg.get("speaker")
        if speaker:
            lines.append(f"{stamp} [{speaker}] {seg['text']}")
        else:
            lines.append(f"{stamp} {seg['text']}")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: transcribe.py <vtt-path>", file=sys.stderr)
        raise SystemExit(2)
    print(format_transcript(parse_vtt(sys.argv[1])))
