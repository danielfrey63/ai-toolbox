#!/usr/bin/env python3
"""Parse a WebVTT subtitle file into a clean, timestamped transcript.

YouTube auto-subs emit *rolling* cues: every cue repeats the previously
displayed line verbatim as plain text and appends the new line with inline
word-timing tags, followed by a ~10 ms "spacer" cue carrying the settled line
on its own. Naively joining a cue's lines therefore emits every spoken line
twice. We detect rolling mode structurally (inline timing tags are present
only in YouTube-style auto-subs) and strip the carry-over prefix, so each line
lands in the transcript exactly once. Platform exports (Teams) and
skill-generated VTTs have no inline timings and keep the old, conservative
exact-duplicate merge.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from version import APP_VERSION


TS_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})[.,](\d{3})"
)
TAG_RE = re.compile(r"<[^>]+>")
# Inline word timings (`<00:00:02.680>`) appear only in YouTube-style rolling
# auto-subs. Their presence is the structural signal that carry-over stripping
# is safe; without it we must not touch cue text beyond exact duplicates.
INLINE_TIMING_RE = re.compile(r"<\d{2}:\d{2}:\d{2}[.,]\d{3}>")

# A 1-word overlap is far more likely a genuine repeat ("no, no") than a
# carry-over line, so stripping starts at two words.
MIN_CARRYOVER_WORDS = 2


def _to_seconds(h: str, m: str, s: str, ms: str) -> float:
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def parse_vtt(path: str) -> list[dict]:
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    rolling = bool(INLINE_TIMING_RE.search(text))
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

    return _dedupe(segments, rolling=rolling)


def _carryover_words(prev_words: list[str], cur_words: list[str]) -> int:
    """Longest k where prev_words[-k:] == cur_words[:k]; 0 when they don't overlap.

    Rolling captions repeat the previous line verbatim at the head of the next
    cue, so the repeat is always anchored at the end of what we already emitted.
    Anchoring the match at that boundary is what keeps this from eating
    coincidental repeats elsewhere in the sentence.
    """
    for k in range(min(len(prev_words), len(cur_words)), 0, -1):
        if prev_words[-k:] == cur_words[:k]:
            return k
    return 0


def _dedupe(segments: list[dict], rolling: bool = False) -> list[dict]:
    """Collapse rolling duplicates common in YouTube auto-subs.

    `rolling` enables carry-over stripping: a cue that re-states the tail of the
    previous segment contributes only the words past that overlap. Without it
    only exact duplicates are merged, which is the right behaviour for platform
    exports where cue text is authoritative.
    """
    out: list[dict] = []
    for seg in segments:
        if not out:
            out.append(seg)
            continue

        prev = out[-1]
        prev_words = prev["text"].split()
        cur_words = seg["text"].split()
        overlap = _carryover_words(prev_words, cur_words)
        remainder = cur_words[overlap:]

        # Cue adds nothing new: exact duplicate, or a rolling spacer cue that
        # only re-states the settled line. Extend the existing segment.
        if overlap and not remainder:
            prev["end"] = seg["end"]
            continue

        if rolling and overlap >= MIN_CARRYOVER_WORDS:
            out.append({
                "start": seg["start"],
                "end": seg["end"],
                "text": " ".join(remainder),
            })
            continue

        # Pre-existing non-rolling behaviour: a cue that strictly extends the
        # previous one replaces it rather than duplicating the shared prefix.
        if not rolling and seg["text"].startswith(prev["text"] + " "):
            prev["text"] = seg["text"]
            prev["end"] = seg["end"]
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


# Marker embedded in generated VTT files so re-runs can tell a skill-generated
# VTT from a platform export (Teams, YouTube) that must be preserved. Detection
# is a substring test against this constant, so the version is appended when
# writing (below) rather than baked in here - that keeps VTTs from older
# versions, which carry the bare marker, recognisable.
VTT_GENERATOR_NOTE = "NOTE generated by transcribe-skill"


def _vtt_stamp(seconds: float) -> str:
    ms = int(round(max(seconds, 0.0) * 1000))
    h, rest = divmod(ms, 3_600_000)
    m, rest = divmod(rest, 60_000)
    s, ms = divmod(rest, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"


def format_vtt(segments: list[dict]) -> str:
    """Render segments as a WebVTT subtitle file.

    One cue per segment (fine-grained timing beats merged turns for
    subtitles), with a `<v Speaker>` voice span when a speaker label is
    present. The generator NOTE identifies the file as skill-generated so
    a later run can safely overwrite it while leaving platform exports
    untouched."""
    lines = ["WEBVTT", "", f"{VTT_GENERATOR_NOTE} {APP_VERSION}", ""]
    n = 0
    for seg in segments:
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        n += 1
        start = float(seg.get("start", 0.0))
        end = float(seg.get("end") or 0.0)
        if end <= start:
            end = start + 2.0
        lines.append(str(n))
        lines.append(f"{_vtt_stamp(start)} --> {_vtt_stamp(end)}")
        speaker = seg.get("speaker")
        lines.append(f"<v {speaker}>{text}" if speaker else text)
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: transcribe.py <vtt-path>", file=sys.stderr)
        raise SystemExit(2)
    print(format_transcript(parse_vtt(sys.argv[1])))
