#!/usr/bin/env python3
"""Detect ASR passages that collapsed into garbage and re-transcribe them.

Whisper feeds each 30s window's output into the next one as a prompt
(``condition_on_previous_text``). That keeps sentences and terminology
coherent across window boundaries, but it also means a window that produced
garbage poisons the following ones: the model locks into a repetition loop
("Ja. Ja. Ja. Ja."), or drifts into the wrong language and cannot recover.

Observed in the wild on a 26-minute German meeting recording: a 20-second
stretch came out as ``um eben für Krips-C жить классisch durch diese
Markenелision zu sein``. Re-running the *same model* over *only that audio
window* produced clean, readable German. The audio was never the problem -
the accumulated context was.

This module does exactly that, automatically:

1. ``find_suspects()`` scans the segment list for the known collapse
   signatures (foreign script, repetition loops, cross-segment duplication,
   implausible text density).
2. ``build_windows()`` merges neighbouring suspects into audio windows and
   pads them so the model gets some run-up.
3. ``repair_segments()`` cuts each window out of the audio, re-transcribes it
   with a *fresh* context (and ``--no-carryover`` for good measure), and
   splices the result back in - but only if the result actually scores
   better, so a repair can never make a passage worse.

Usable as a library (run.py calls it) or standalone for inspection:

    python3 repair.py --segments <base>.segments.json --audio audio.mp3 --dry-run
    python3 repair.py --segments <base>.segments.json --video meeting.mp4 --language de
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from setup import find_tool  # noqa: E402

# Languages written in Latin script - for these, a burst of Cyrillic / CJK /
# Arabic characters is a collapse signature rather than legitimate content.
LATIN_LANGS = {
    "de", "en", "fr", "it", "es", "pt", "nl", "sv", "da", "no", "nn", "fi",
    "pl", "cs", "sk", "sl", "hr", "hu", "ro", "tr", "et", "lt", "lv", "id",
    "ms", "vi", "af", "ca", "eu", "gl", "cy", "is", "sq",
}

FOREIGN_BLOCKS = ("CYRILLIC", "CJK", "HANGUL", "HIRAGANA", "KATAKANA",
                  "ARABIC", "HEBREW", "DEVANAGARI", "THAI", "GREEK",
                  "ARMENIAN", "GEORGIAN")

# Tuning. Deliberately conservative: a false negative costs nothing (the
# passage stays as it is today), a false positive costs a re-transcription.
MIN_FOREIGN_CHARS = 2
MAX_TOKEN_RUN = 6          # "Ja. Ja. Ja. Ja. Ja. Ja." -> suspect
MAX_SENTENCE_REPEAT = 4
MAX_SEGMENT_REPEAT = 3     # identical text in N consecutive segments
MIN_CHARS_PER_SEC = 0.7    # long segment, almost no words
MAX_CHARS_PER_SEC = 32.0   # run-on hallucination
MIN_DURATION_FOR_DENSITY = 6.0
MIN_CONTENT_RATIO = 0.6    # reject a rerun that lost this much real speech


def _norm_token(tok: str) -> str:
    return re.sub(r"[^\w]", "", tok, flags=re.UNICODE).casefold()


def _foreign_chars(text: str) -> int:
    n = 0
    for ch in text:
        if not ch.isalpha():
            continue
        try:
            name = unicodedata.name(ch)
        except ValueError:
            continue
        if any(name.startswith(b) for b in FOREIGN_BLOCKS):
            n += 1
    return n


def _max_token_run(text: str) -> int:
    toks = [_norm_token(t) for t in text.split()]
    toks = [t for t in toks if t]
    best = run = 0
    prev = None
    for t in toks:
        run = run + 1 if t == prev else 1
        prev = t
        best = max(best, run)
    return best


def _max_sentence_repeat(text: str) -> int:
    sents = [s.strip().casefold() for s in re.split(r"[.!?]+", text) if s.strip()]
    if not sents:
        return 0
    counts: dict[str, int] = {}
    for s in sents:
        counts[s] = counts.get(s, 0) + 1
    return max(counts.values())


def find_suspects(segments: list[dict], language: str | None = None) -> list[dict]:
    """Return [{index, start, end, reasons: [...]}] for every suspect segment."""
    latin = (language or "").lower() in LATIN_LANGS or not language
    suspects: list[dict] = []

    for i, seg in enumerate(segments):
        text = (seg.get("text") or "").strip()
        start = float(seg.get("start", 0.0))
        end = float(seg.get("end", start))
        dur = max(0.0, end - start)
        reasons: list[str] = []

        if latin:
            nf = _foreign_chars(text)
            if nf >= MIN_FOREIGN_CHARS:
                reasons.append(f"Fremdschrift ({nf} Zeichen)")

        run = _max_token_run(text)
        if run >= MAX_TOKEN_RUN:
            reasons.append(f"Wortwiederholung ({run}x)")

        rep = _max_sentence_repeat(text)
        if rep >= MAX_SENTENCE_REPEAT:
            reasons.append(f"Satzwiederholung ({rep}x)")

        if dur >= MIN_DURATION_FOR_DENSITY and text:
            cps = len(text) / dur
            if cps < MIN_CHARS_PER_SEC:
                reasons.append(f"kaum Text ({cps:.1f} Z/s über {dur:.0f}s)")
            elif cps > MAX_CHARS_PER_SEC:
                reasons.append(f"Textflut ({cps:.0f} Z/s)")

        if reasons:
            suspects.append({"index": i, "start": start, "end": end,
                             "reasons": reasons, "text": text})

    # Cross-segment duplication: the same line echoed by N consecutive segments.
    i = 0
    while i < len(segments):
        t = (segments[i].get("text") or "").strip().casefold()
        if not t:
            i += 1
            continue
        j = i
        while j + 1 < len(segments) and \
                (segments[j + 1].get("text") or "").strip().casefold() == t:
            j += 1
        if j - i + 1 >= MAX_SEGMENT_REPEAT:
            known = {s["index"] for s in suspects}
            for k in range(i, j + 1):
                if k in known:
                    continue
                suspects.append({
                    "index": k,
                    "start": float(segments[k].get("start", 0.0)),
                    "end": float(segments[k].get("end", 0.0)),
                    "reasons": [f"Segmentdopplung ({j - i + 1}x in Folge)"],
                    "text": (segments[k].get("text") or "").strip(),
                })
        i = j + 1

    suspects.sort(key=lambda s: s["index"])
    return suspects


def _dedup_chars(segments: list[dict]) -> int:
    """Character count after collapsing repeated sentences.

    A repair that merely deletes a "Ja. Ja. Ja." loop shrinks the raw text a
    lot while losing nothing; a repair that silently drops real speech shrinks
    it too. Comparing *deduplicated* length tells the two apart.
    """
    seen: set[str] = set()
    total = 0
    for seg in segments:
        for sent in re.split(r"[.!?]+", seg.get("text") or ""):
            s = sent.strip()
            key = s.casefold()
            if s and key not in seen:
                seen.add(key)
                total += len(s)
    return total


def build_windows(suspects: list[dict], duration: float | None = None,
                  pad: float = 12.0, join_gap: float = 12.0) -> list[dict]:
    """Merge suspects into padded audio windows to re-transcribe."""
    if not suspects:
        return []
    windows: list[dict] = []
    cur = {"start": suspects[0]["start"], "end": suspects[0]["end"],
           "reasons": list(suspects[0]["reasons"])}
    for s in suspects[1:]:
        if s["start"] - cur["end"] <= join_gap:
            cur["end"] = max(cur["end"], s["end"])
            cur["reasons"].extend(r for r in s["reasons"] if r not in cur["reasons"])
        else:
            windows.append(cur)
            cur = {"start": s["start"], "end": s["end"],
                   "reasons": list(s["reasons"])}
    windows.append(cur)

    for w in windows:
        w["padded_start"] = max(0.0, w["start"] - pad)
        w["padded_end"] = w["end"] + pad
        if duration:
            w["padded_end"] = min(duration, w["padded_end"])
    return windows


def _cut_audio(source: Path, start: float, end: float, out: Path) -> Path:
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )
    subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
         "-ss", f"{start:.3f}", "-to", f"{end:.3f}", "-i", str(source),
         "-vn", "-ac", "1", "-ar", "16000", str(out)],
        check=True,
    )
    return out


def _score(segments: list[dict], language: str | None) -> int:
    """How broken is this stretch? Lower is better."""
    return sum(len(s["reasons"]) for s in find_suspects(segments, language))


def repair_segments(segments: list[dict], audio: Path,
                    language: str | None = None,
                    duration: float | None = None,
                    dry_run: bool = False,
                    skip_spans: list[tuple[float, float]] | None = None,
                    max_passes: int = 2,
                    ) -> tuple[list[dict], list[dict]]:
    """Re-transcribe collapsed windows. Returns (segments, report).

    ``skip_spans`` are time ranges already repaired by an earlier run. Without
    them the pass is not idempotent: a repair usually leaves a *milder*
    signature behind (a shorter repetition, a slightly odd density), which the
    next run happily "repairs" again, and the transcript keeps drifting on
    every re-run. Once a span has been rewritten, it is left alone.

    ``max_passes`` closes the same gap *within* one run: rewriting a window can
    expose a mild signature just past its edge, so a second internal pass picks
    that up and the caller converges in a single invocation. Capped at 2 - a
    third pass has never found anything but would keep churning the text.
    """
    done: list[tuple[float, float]] = list(skip_spans or [])
    out = list(segments)
    report: list[dict] = []
    tmp: Path | None = None

    for pass_no in range(max_passes):
        suspects = find_suspects(out, language)
        if done:
            before = len(suspects)
            suspects = [
                s for s in suspects
                if not any(lo <= (s["start"] + s["end"]) / 2 <= hi for lo, hi in done)
            ]
            if before != len(suspects) and pass_no == 0:
                print(f"[transcribe] repair: {before - len(suspects)} Segment(e) in "
                      f"bereits reparierten Bereichen übersprungen", file=sys.stderr)
        if not suspects:
            break

        windows = build_windows(suspects, duration=duration)
        print(f"[transcribe] repair: {len(suspects)} auffällige Segmente in "
              f"{len(windows)} Fenster(n)"
              f"{'' if pass_no == 0 else f' (Durchgang {pass_no + 1})'}",
              file=sys.stderr)

        if dry_run:
            for w in windows:
                old = [s for s in out
                       if w["padded_start"] <= (s["start"] + s["end"]) / 2 <= w["padded_end"]]
                report.append({**w, "applied": False, "old_text": " ".join(
                    (s.get("text") or "").strip() for s in old)})
            return out, report

        if tmp is None:
            tmp = Path(tempfile.mkdtemp(prefix="transcribe-repair-"))
        out, new_report = _repair_windows(out, windows, audio, language, tmp)
        report.extend(new_report)
        done.extend((w["padded_start"], w["padded_end"]) for w in windows)

    out.sort(key=lambda s: s["start"])
    return out, report


def _repair_windows(segments: list[dict], windows: list[dict], audio: Path,
                    language: str | None,
                    tmp: Path) -> tuple[list[dict], list[dict]]:
    """Re-transcribe each window and splice in whatever passes both gates."""
    from setup import run_venv_worker

    report: list[dict] = []
    out = list(segments)
    # Rebuild back-to-front so earlier indices stay valid while splicing.
    for w in sorted(windows, key=lambda x: x["padded_start"], reverse=True):
        lo, hi = w["padded_start"], w["padded_end"]
        old = [s for s in out if lo <= (s["start"] + s["end"]) / 2 <= hi]
        if not old:
            continue
        clip = _cut_audio(audio, lo, hi, tmp / f"repair_{int(lo)}.wav")
        args = [str(clip)]
        if language:
            args.append(language)
        args.append("--no-carryover")
        try:
            fresh = json.loads(run_venv_worker("whisper_local_worker.py", args))
        except (SystemExit, ValueError) as exc:
            print(f"[transcribe] repair: Fenster {lo:.0f}-{hi:.0f}s "
                  f"fehlgeschlagen ({exc}) - Original bleibt", file=sys.stderr)
            continue

        new = [{"start": round(lo + float(s["start"]), 2),
                "end": round(lo + float(s["end"]), 2),
                "text": (s.get("text") or "").strip()}
               for s in fresh if (s.get("text") or "").strip()]

        old_score, new_score = _score(old, language), _score(new, language)
        old_chars, new_chars = _dedup_chars(old), _dedup_chars(new)
        entry = {**w, "old_text": " ".join(s.get("text", "") for s in old),
                 "new_text": " ".join(s["text"] for s in new),
                 "old_score": old_score, "new_score": new_score,
                 "old_chars": old_chars, "new_chars": new_chars}

        # Two independent gates. The score gate catches "still broken"; the
        # content gate catches "fixed by deleting the evidence" - a rerun that
        # drops real speech scores perfectly but is strictly worse.
        lost_content = old_chars > 0 and new_chars < MIN_CONTENT_RATIO * old_chars
        if not new or new_score > old_score or lost_content:
            entry["applied"] = False
            why = (f"Textverlust ({new_chars}/{old_chars} Zeichen)" if lost_content
                   else f"nicht besser ({old_score} -> {new_score})")
            print(f"[transcribe] repair: {lo:.0f}-{hi:.0f}s {why} - Original bleibt",
                  file=sys.stderr)
        else:
            head = [s for s in out if (s["start"] + s["end"]) / 2 < lo]
            tail = [s for s in out if (s["start"] + s["end"]) / 2 > hi]
            out = head + new + tail
            entry["applied"] = True
            print(f"[transcribe] repair: {lo:.0f}-{hi:.0f}s ersetzt "
                  f"({old_score} -> {new_score}, {len(old)} -> {len(new)} Segmente)",
                  file=sys.stderr)
        report.append(entry)

    out.sort(key=lambda s: s["start"])
    return out, list(reversed(report))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--segments", required=True, help="<base>.segments.json")
    ap.add_argument("--audio", help="audio file (mp3/wav)")
    ap.add_argument("--video", help="source video - audio is cut from it directly")
    ap.add_argument("--language", default=None, help='e.g. "de"')
    ap.add_argument("--dry-run", action="store_true",
                    help="only list the suspect passages, change nothing")
    ap.add_argument("-o", "--out", help="write result here (default: in place)")
    args = ap.parse_args()

    # The whole point of this tool is printing text the console choked on;
    # a cp1252 stdout would raise UnicodeEncodeError on exactly those lines.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    store = Path(args.segments)
    payload = json.loads(store.read_text(encoding="utf-8"))
    segments = payload["segments"] if isinstance(payload, dict) else payload

    source = Path(args.audio or args.video) if (args.audio or args.video) else None
    if not args.dry_run and source is None:
        ap.error("--audio or --video is required unless --dry-run is set")

    fixed, report = repair_segments(segments, source, language=args.language,
                                    dry_run=args.dry_run)

    for r in report:
        mark = "REPARIERT" if r.get("applied") else "unveraendert"
        print(f"\n[{r['padded_start']:.0f}-{r['padded_end']:.0f}s] {mark} "
              f"- {', '.join(r['reasons'])}")
        print(f"  alt: {r.get('old_text', '')[:300]}")
        if r.get("new_text"):
            print(f"  neu: {r['new_text'][:300]}")
    if not report:
        print("Keine auffaelligen Passagen gefunden.")

    if not args.dry_run:
        target = Path(args.out) if args.out else store
        if isinstance(payload, dict):
            payload["segments"] = fixed
            payload["repaired"] = [
                {k: r[k] for k in ("padded_start", "padded_end", "reasons", "applied")}
                for r in report
            ]
        else:
            payload = fixed
        target.write_text(json.dumps(payload), encoding="utf-8")
        print(f"\n-> {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
