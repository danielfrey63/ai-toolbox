#!/usr/bin/env python3
"""Speaker mapping as a durable, human-editable intermediate step.

Diarization yields SPEAKER_NN labels; who is behind them is decided from
evidence - address patterns, self-introductions, name plates on screen,
platform captions with voice tags. Until now that decision was made twice
(compact transcript, Inventar) and evaporated with the session; the user's
corrections had nowhere to go. `<base>.speakers.md` is that place:

  1. run.py pre-fills it once from what is computable: talk time and active
     window per label, the participants seen on screen (ocr.json name
     plates), in the captions (`<v Name>` tags of <base>.original.vtt) and
     in transcribe-participants.txt next to the recording, every address
     hit with the labels around it, self-introductions, and the caption
     voice each label overlaps most.
  2. The model fills Name / Confidence / Evidence for what the evidence
     supports; the human corrects in place.
  3. Every renderer reads the file: a run.py re-run and `speakers.py --apply`
     substitute the names into transcript.md and .vtt, the report's Personen
     & Stimmen summarises it, and the labels still without a name are the
     open speaker questions of the report.

The file is never overwritten once it exists - it carries human input.
`--fresh` does not touch it either; delete it to have it pre-filled again.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

PARTICIPANTS_FILE = "transcribe-participants.txt"
LABEL_RE = re.compile(r"^(SPEAKER_\d+|[A-Z])$")
# Teams tile / dialog name plates as RapidOCR reads them:
#   «Berger Thomas (IT-I-CEN4)», «Simab Asmatullah (IT-I-CE...», «Berger,Thomas[00223016]»
NAME_PLATE_RE = re.compile(
    r"^([A-ZÀ-Þ][\wÀ-ÿ'’-]+),?\s+([A-ZÀ-Þ][\wÀ-ÿ'’-]+)\s*(?:\(|\[\d{4,})"
)
MIN_PLATE_SIGHTINGS = 2
VOICE_TAG_RE = re.compile(r"<v\s+([^>]+)>")
VTT_TS_RE = re.compile(r"(\d{1,2}):(\d{2}):(\d{2})[.,](\d{3})|(\d{1,2}):(\d{2})[.,](\d{3})")
SELF_INTRO = r"(?:ich bin|hier ist|mein name ist|i am|i'm|this is|c'est|je suis)\s+"
VOICE_MIN_SHARE = 0.6


def fmt_ts(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


# --- Evidence collection ----------------------------------------------------

def label_stats(segments: list[dict]) -> list[dict]:
    """Per label: spoken seconds, number of turns, first and last activity."""
    stats: dict[str, dict] = {}
    prev = None
    for seg in segments:
        lab = seg.get("speaker")
        if not lab:
            continue
        s, e = float(seg["start"]), float(seg["end"])
        st = stats.setdefault(lab, {"label": lab, "seconds": 0.0, "turns": 0, "first": s, "last": e})
        st["seconds"] += max(0.0, e - s)
        st["last"] = max(st["last"], e)
        if lab != prev:
            st["turns"] += 1
        prev = lab
    total = sum(x["seconds"] for x in stats.values()) or 1.0
    out = sorted(stats.values(), key=lambda x: -x["seconds"])
    for x in out:
        x["share"] = x["seconds"] / total
    return out


def participants_from_ocr(ocr: dict | None) -> list[dict]:
    """Name plates that RapidOCR read at least twice (once is noise)."""
    seen: dict[str, dict] = {}
    for frame in (ocr or {}).get("frames", []):
        for line in frame.get("lines", []):
            m = NAME_PLATE_RE.match(line["text"].strip())
            if not m:
                continue
            name = f"{m.group(1)} {m.group(2)}"
            item = seen.setdefault(name, {"name": name, "first": frame["t"], "count": 0})
            item["count"] += 1
            item["first"] = min(item["first"], frame["t"])
    return sorted(
        (x for x in seen.values() if x["count"] >= MIN_PLATE_SIGHTINGS),
        key=lambda x: (x["first"], -x["count"]),
    )


def _vtt_seconds(m: re.Match) -> float:
    g = m.groups()
    if g[0] is not None:
        return int(g[0]) * 3600 + int(g[1]) * 60 + int(g[2]) + int(g[3]) / 1000
    return int(g[4]) * 60 + int(g[5]) + int(g[6]) / 1000


def voices_from_vtt(path: Path | None) -> list[dict]:
    """[{name, start, end}] from `<v Name>` cues of a platform VTT."""
    if not path or not path.is_file():
        return []
    out: list[dict] = []
    cur: tuple[float, float] | None = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip().lstrip("﻿")
        if "-->" in line:
            stamps = list(VTT_TS_RE.finditer(line))
            cur = (_vtt_seconds(stamps[0]), _vtt_seconds(stamps[1])) if len(stamps) >= 2 else None
            continue
        if cur is None:
            continue
        for m in VOICE_TAG_RE.finditer(line):
            out.append({"name": m.group(1).strip(), "start": cur[0], "end": cur[1]})
    return out


def participants_from_file(folder: Path | None) -> list[str]:
    if not folder:
        return []
    p = folder / PARTICIPANTS_FILE
    if not p.is_file():
        return []
    names = []
    for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            names.append(line)
    return names


def _name_tokens(name: str) -> list[str]:
    """Words of a name worth searching for in speech: capitalised, >= 3 chars,
    role suffixes after « - » / « — » dropped."""
    head = re.split(r"\s+[-–—]\s+|,", name, maxsplit=1)[0]
    return [t for t in re.findall(r"[A-ZÀ-Þ][\wÀ-ÿ'’-]{2,}", head)]


def address_hits(segments: list[dict], names: list[str]) -> list[dict]:
    """Every spoken occurrence of a participant's name token, with the label
    that said it and the different labels before and after - an address
    («Simon, …») usually hands the floor to the person named."""
    labelled = [s for s in segments if s.get("speaker") and (s.get("text") or "").strip()]
    hits: list[dict] = []
    tokens = sorted({t for n in names for t in _name_tokens(n)}, key=len, reverse=True)
    if not tokens:
        return hits
    tok_re = re.compile(r"\b(" + "|".join(re.escape(t) for t in tokens) + r")\b")
    intro_re = re.compile(SELF_INTRO + r"(" + "|".join(re.escape(t) for t in tokens) + r")\b", re.I)
    for i, seg in enumerate(labelled):
        text = seg["text"].strip()
        for m in tok_re.finditer(text):
            lab = seg["speaker"]
            prev = next((x["speaker"] for x in reversed(labelled[:i]) if x["speaker"] != lab), None)
            nxt = next((x["speaker"] for x in labelled[i + 1:] if x["speaker"] != lab), None)
            a, b = max(0, m.start() - 40), min(len(text), m.end() + 40)
            quote = ("…" if a else "") + text[a:b] + ("…" if b < len(text) else "")
            hits.append({
                "t": float(seg["start"]), "token": m.group(1), "label": lab, "prev": prev, "next": nxt,
                "quote": quote, "self": bool(intro_re.search(text)),
            })
    return hits


def voice_alignment(segments: list[dict], voices: list[dict]) -> dict[str, dict]:
    """label -> {name, share}: the caption voice each label overlaps most,
    with that voice's share of the label's spoken time."""
    if not voices:
        return {}
    per: dict[str, dict[str, float]] = {}
    total: dict[str, float] = {}
    for seg in segments:
        lab = seg.get("speaker")
        if not lab:
            continue
        s, e = float(seg["start"]), float(seg["end"])
        total[lab] = total.get(lab, 0.0) + max(0.0, e - s)
        for v in voices:
            ov = max(0.0, min(e, v["end"]) - max(s, v["start"]))
            if ov > 0:
                per.setdefault(lab, {})[v["name"]] = per.setdefault(lab, {}).get(v["name"], 0.0) + ov
    out = {}
    for lab, by in per.items():
        name, ov = max(by.items(), key=lambda kv: kv[1])
        out[lab] = {"name": name, "share": ov / (total.get(lab) or 1.0)}
    return out


# --- Rendering --------------------------------------------------------------

def prefill(title: str, segments: list[dict], ocr: dict | None, vtt_path: Path | None,
            folder: Path | None, version: str = "unknown") -> str:
    stats = label_stats(segments)
    plates = participants_from_ocr(ocr)
    voices = voices_from_vtt(vtt_path)
    listed = participants_from_file(folder)
    voice_names = sorted({v["name"] for v in voices})
    names = list(dict.fromkeys([p["name"] for p in plates] + voice_names + listed))
    hits = address_hits(segments, names)
    align = voice_alignment(segments, voices)

    lines = [
        f"# Speakers: {title}",
        "",
        f"_Pre-filled by transcribe {version} on {_dt.date.today().isoformat()} from diarization "
        f"({len(stats)} labels), the transcript, on-screen name plates and captions. Fill **Name** "
        f"(canonical first name; `Andrea B` / `Andrea T` on collision), **Confidence** (high / medium / "
        f"low) and **Evidence** per label. Leave Name empty when the evidence does not carry it - those "
        f"labels are the open speaker questions of the report. A run.py re-run and `speakers.py --apply` "
        f"substitute the names into transcript.md and .vtt; a name marked `(?)` is shown in the report "
        f"but not substituted. This file is never overwritten - delete it to pre-fill again. A room "
        f"microphone often splits one person into several labels: giving two labels the same name "
        f"merges them on the next render._",
        "",
        "## Labels",
        "",
        "| Label | Talk time | Turns | Active | Name | Confidence | Evidence |",
        "|---|---|---|---|---|---|---|",
    ]
    for st in stats:
        name = conf = ev = ""
        va = align.get(st["label"])
        if va and va["share"] >= VOICE_MIN_SHARE:
            name, conf = va["name"], "high"
            ev = f"captions: {va['share']:.0%} of the label's speech under `<v {va['name']}>`"
        else:
            intro = next((h for h in hits if h["self"] and h["label"] == st["label"]), None)
            if intro:
                name, conf = intro["token"], "medium"
                ev = f"self-introduction [{fmt_ts(intro['t'])}] «{intro['quote']}»"
        lines.append(
            f"| {st['label']} | {fmt_ts(st['seconds'])} ({st['share']:.0%}) | {st['turns']} | "
            f"[{fmt_ts(st['first'])}]–[{fmt_ts(st['last'])}] | {name} | {conf} | {ev} |"
        )
    lines += [
        "", "## Overrides", "",
        "_One row per transcript block that someone who was in the room attributes by hand - for the "
        "contributions a shared microphone filed under the presenter's label. The timestamp is the block's "
        "`[MM:SS]` in transcript.md; the name replaces the label for that block (and its VTT cues) only._",
        "",
        "| Zeit | Name | Wortmeldung |",
        "|---|---|---|",
        "", "## Participants", "",
    ]
    if names:
        lines += ["| Name | Source |", "|---|---|"]
        for p in plates:
            lines.append(f"| {p['name']} | on screen [{fmt_ts(p['first'])}] ({p['count']} frames) |")
        for v in voice_names:
            lines.append(f"| {v} | caption voice tag |")
        for n in listed:
            lines.append(f"| {n} | {PARTICIPANTS_FILE} |")
    else:
        lines.append(
            f"_None found on screen or in captions. List them in `{PARTICIPANTS_FILE}` next to the "
            f"recording (one per line, `Name - role` allowed) and delete this file to pre-fill again._"
        )
    lines += ["", "## Evidence", "", "### Self-introductions", ""]
    intros = [h for h in hits if h["self"]]
    lines += [f"- [{fmt_ts(h['t'])}] {h['label']}: «{h['quote']}»" for h in intros] or ["- none found"]
    lines += ["", "### Address hits", ""]
    addr = [h for h in hits if not h["self"]]
    if addr:
        lines.append("_Who says a name, and which labels speak right before and after - the next "
                     "different label after «Name, …» is usually the person addressed._")
        lines.append("")
        lines += [
            f"- [{fmt_ts(h['t'])}] {h['label']} says «{h['quote']}» - before: {h['prev'] or '-'}, "
            f"after: {h['next'] or '-'}"
            for h in addr
        ]
    else:
        lines.append("- none found" + ("" if names else " (no participant names to look for)"))
    lines += ["", "### Caption voices", ""]
    if align:
        lines += [f"- {lab}: {a['name']} ({a['share']:.0%} overlap)" for lab, a in sorted(align.items())]
    else:
        lines.append("- none (no `<base>.original.vtt` with `<v Name>` tags)")
    return "\n".join(lines)


# --- Consuming the file -----------------------------------------------------

def parse_mapping(path: Path) -> dict[str, str]:
    """label -> name from the Labels table. Empty names and names marked
    `(?)` are left out - they are not substituted."""
    mapping: dict[str, str] = {}
    cols: list[str] | None = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            cols = None if cols and not line else cols
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if cols is None:
            if "Label" in cells and "Name" in cells:
                cols = cells
            continue
        if all(set(c) <= set("-: ") for c in cells):
            continue
        row = dict(zip(cols, cells))
        label, name = row.get("Label", ""), row.get("Name", "")
        name = name.strip("` ")
        if LABEL_RE.match(label) and name and name not in ("?", "-") and not name.endswith("(?)"):
            mapping[label] = name
    return mapping


def apply_mapping(segments: list[dict], mapping: dict[str, str]) -> list[dict]:
    if not mapping:
        return segments
    return [dict(s, speaker=mapping.get(s.get("speaker"), s.get("speaker"))) for s in segments]


def parse_overrides(path: Path) -> dict[str, str]:
    """`[MM:SS]` -> name from the Overrides table: one transcript block that a
    person who was in the room attributed by hand. A room microphone puts
    several people under one label, so a label-wide name cannot express
    «this question came from Márton»; the override can."""
    out: dict[str, str] = {}
    in_section = False
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("## "):
            in_section = line[3:].strip().lower().startswith("overrides")
            continue
        if not in_section or not line.startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in line.strip("|").split("|")]
        if len(cells) < 2 or not TS_RE.fullmatch(cells[0]) or not cells[1] or cells[1].lower() == "name":
            continue
        out[cells[0].strip("[]")] = cells[1].strip("` ")
    return out


TS_RE = re.compile(r"\[?\d{1,2}:\d{2}(?::\d{2})?\]?")
BLOCK_RE = re.compile(r"^\[(\d{1,2}:\d{2}(?::\d{2})?)\] \[([^\]]+)\]")


def _block_starts(segments: list[dict]) -> list[tuple[str, float, float]]:
    """(MM:SS, start, end) of every rendered transcript block, so an override
    keyed by the block's timestamp can cover all of its segments."""
    from transcribe import merge_speaker_turns  # noqa: PLC0415

    return [(fmt_ts(float(b["start"])), float(b["start"]), float(b["end"]))
            for b in merge_speaker_turns(segments)]


def apply_overrides(segments: list[dict], overrides: dict[str, str]) -> list[dict]:
    """Rename the speaker of every segment inside an overridden block."""
    if not overrides:
        return segments
    spans = [(s, e, overrides[ts]) for ts, s, e in _block_starts(segments) if ts in overrides]
    out = []
    for seg in segments:
        st = float(seg["start"])
        name = next((n for s, e, n in spans if s <= st <= e), None)
        out.append(dict(seg, speaker=name) if name else seg)
    return out


def apply_to_files(base: Path, mapping: dict[str, str], overrides: dict[str, str] | None = None) -> list[Path]:
    """Substitute `[LABEL]` / `<v LABEL>` in transcript.md and .vtt in place;
    then rename the blocks the Overrides table names (transcript lines by
    their timestamp, VTT cues by falling inside that block's time span)."""
    overrides = overrides or {}
    touched: list[Path] = []
    tp = base.with_name(base.name + ".transcript.md")
    spans: list[tuple[float, float, str]] = []
    if tp.is_file():
        lines = tp.read_text(encoding="utf-8").splitlines()
        starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := BLOCK_RE.match(l))]
        new_lines = list(lines)
        for k, (i, ts) in enumerate(starts):
            m = BLOCK_RE.match(lines[i])
            label = m.group(2)
            name = overrides.get(ts) or mapping.get(label)
            if name and name != label:
                new_lines[i] = lines[i].replace(f"[{label}]", f"[{name}]", 1)
            if ts in overrides:
                nxt = starts[k + 1][1] if k + 1 < len(starts) else None
                spans.append((_ts_seconds(ts), _ts_seconds(nxt) if nxt else float("inf"), overrides[ts]))
        if new_lines != lines:
            text = tp.read_text(encoding="utf-8")
            tp.write_text("\n".join(new_lines) + ("\n" if text.endswith("\n") else ""), encoding="utf-8")
            touched.append(tp)
    vp = base.with_name(base.name + ".vtt")
    if vp.is_file():
        text = vp.read_text(encoding="utf-8")
        new = text
        for label, name in mapping.items():
            new = new.replace(f"<v {label}>", f"<v {name}>")
        if spans:
            out, cue_start = [], None
            for raw in new.splitlines():
                if "-->" in raw:
                    m = VTT_TS_RE.search(raw)
                    cue_start = _vtt_seconds(m) if m else None
                elif cue_start is not None and raw.startswith("<v "):
                    name = next((n for s, e, n in spans if s <= cue_start < e), None)
                    if name:
                        raw = VOICE_TAG_RE.sub(f"<v {name}>", raw, count=1)
                out.append(raw)
            new = "\n".join(out) + ("\n" if new.endswith("\n") else "")
        if new != text:
            vp.write_text(new, encoding="utf-8")
            touched.append(vp)
    return touched


def _ts_seconds(ts: str) -> float:
    parts = [int(x) for x in ts.split(":")]
    return parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 else parts[0] * 60 + parts[1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--prefill", metavar="BASE",
                    help="print the pre-filled speakers.md for <BASE> (needs <BASE>.segments.json + .turns.json)")
    ap.add_argument("--apply", metavar="BASE",
                    help="substitute the names of <BASE>.speakers.md into <BASE>.transcript.md and .vtt")
    args = ap.parse_args()
    if args.prefill:
        from diarize import align_speakers  # noqa: PLC0415

        base = Path(args.prefill)
        segs = json.loads(base.with_name(base.name + ".segments.json").read_text(encoding="utf-8"))["segments"]
        turns = json.loads(base.with_name(base.name + ".turns.json").read_text(encoding="utf-8"))
        ocr_p = base.with_name(base.name + ".ocr.json")
        ocr = json.loads(ocr_p.read_text(encoding="utf-8")) if ocr_p.is_file() else None
        print(prefill(base.name, align_speakers(segs, turns), ocr,
                      base.with_name(base.name + ".original.vtt"), base.parent))
        return 0
    if args.apply:
        base = Path(args.apply)
        sp = base.with_name(base.name + ".speakers.md")
        mapping, overrides = parse_mapping(sp), parse_overrides(sp)
        touched = apply_to_files(base, mapping, overrides)
        print(f"[speakers] {len(mapping)} name(s) and {len(overrides)} override(s) applied to "
              f"{len(touched)} file(s)" + (": " + ", ".join(p.name for p in touched) if touched else ""))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
