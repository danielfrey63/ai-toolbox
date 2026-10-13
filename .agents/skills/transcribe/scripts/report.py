#!/usr/bin/env python3
"""Write the analysis report (Übersicht, Summary, Analysis) with the LLM.

Scripted version of SKILL.md Step 4. Two stages:

1. Frame pass (vision model): the cut frames plus a thinned set of regular
   frames are described in batches - what is on screen, names and labels
   verbatim, whether the frame carries content worth an illustration.
   Cached in <base>.frames.json.
2. Report pass (text model): the methodology in references/report-writing.md
   is the system prompt; transcript (or the compact transcript), frame
   descriptions, speakers.md, links.md, protocol metadata, crosscheck and
   glossary are the input. The reply is the Markdown of the three sections.

The script then embeds the illustrations listed in the manifest, appends a
deterministic data-flow line (which model saw what - AK E) and writes the
report below the stub in <base>.md.

  python report.py "<base or any companion>" [--language de] [--force]
                   [--no-frames] [--max-frames 48]

Idempotent: a <base>.md that already carries «## Übersicht» is kept unless
--force; with --force the section from «## Übersicht» on is replaced.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from pathlib import Path

import llm
from companions import (Paths, language_rules, read_glossary, read_json, read_protocol, read_speakers,
                        read_transcript, references_from_links, resolve_base, ts_seconds, write_json)
from version import APP_VERSION

SKILL_ROOT = Path(__file__).resolve().parent.parent
METHOD = SKILL_ROOT / "references" / "report-writing.md"
FRAME_BATCH = 8

FRAME_SYSTEM = """You look at frames of a recorded meeting or screen share. For EACH frame return what is on screen, verbatim where text is legible: application or page title, headings, table headers, object names, people's names on tiles or name plates, URLs, ticket keys. Ignore the meeting client chrome (participant strip, toolbar) except for names on tiles.
Return ONLY a JSON object {"frames": [{"ts": "<MM:SS as given>", "screen": "<application / page>", "content": "<what is shown, verbatim names>", "names": ["<person names visible>"], "illustration": true|false, "why": "<only when illustration=true: what this frame explains that words cannot>"}]}.
illustration=true only for diagrams, architecture or data-flow slides, tables with substance, code or configuration that the speakers discuss, dialogs that are the topic. Never for talking heads, title cards, desktop, loading states."""

REPORT_TASK = """Write the report for this recording now, following the methodology above exactly:
the mandatory pre-stage (Inventar, Konsistenz-Check, date identification) happens in your head and lands in the Analysis; then output the three top-level sections in this order and nothing else:

## Übersicht
### Kernaussagen
### Chapter-Struktur
## Summary
### <Thema> groups (5-10), the first one «Setting und Teilnehmer» with the date and its source
## Analysis
### Inventar
### Beurteilungen
### Schlüsselaussagen
### Details
### Abdeckung
### Resources
### Offene Sprecherzuordnung (only when OPEN ATTRIBUTIONS lists rows; use them as the table rows)

Constraints that override the methodology where they differ:
- You cannot crop illustrations. Where an illustration from ILLUSTRATIONS fits a Summary group, put the placeholder line {{ILL:<id>}} on its own line at that spot; the script replaces it with the image and caption. Use each id at most once.
- Frames are ground truth for names and labels; the transcript is noisy. Use FRAME DESCRIPTIONS and LINKS for spellings.
- Speaker names: use the names from SPEAKERS; a label without a name stays the bare label.
- Do not write a data-flow statement; the script appends it.
- Markdown: one paragraph = one line, no hard wraps. Timestamps as [MM:SS]."""


def _thin(items: list, n: int) -> list:
    if len(items) <= n:
        return items
    step = len(items) / n
    return [items[int(i * step)] for i in range(n)]


def frame_pass(p: Paths, proto: dict, max_frames: int, language: str | None, force: bool) -> list[dict]:
    cached = read_json(p.frames_json)
    if isinstance(cached, dict) and cached.get("frames") and not force:
        print(f"[report] frame descriptions cached ({len(cached['frames'])}) - reuse", file=sys.stderr)
        return cached["frames"]
    frames = [f for f in proto.get("frames", []) if Path(f["path"]).is_file()]
    if not frames:
        print("[report] no frame files on disk (work dir gone or audio-only) - frame pass skipped",
              file=sys.stderr)
        return []
    cuts = [f for f in frames if f["kind"] == "CUT"]
    regs = [f for f in frames if f["kind"] == "REG"]
    pick = cuts[:max_frames]
    if len(pick) < max_frames:
        pick += _thin(regs, max_frames - len(pick))
    pick.sort(key=lambda f: ts_seconds(f["ts"]))
    out: list[dict] = []
    for i in range(0, len(pick), FRAME_BATCH):
        batch = pick[i:i + FRAME_BATCH]
        listing = "\n".join(f"{k + 1}. ts={f['ts']} ({f['kind']})" for k, f in enumerate(batch))
        prompt = (f"{language_rules(language)}\nThe images are attached in this order:\n{listing}\n"
                  "Describe every frame, keep the ts values as given.")
        try:
            obj = llm.ask_json(prompt, system=FRAME_SYSTEM, images=[f["path"] for f in batch], role="vision",
                               max_tokens=4000, label=f"frames {i + 1}-{i + len(batch)}")
            out += [dict(d, kind=next((f["kind"] for f in batch if f["ts"] == d.get("ts")), ""))
                    for d in obj.get("frames", [])]
        except (RuntimeError, ValueError) as exc:
            print(f"[report] frame batch {i + 1} failed: {exc}", file=sys.stderr)
    write_json(p.frames_json, {"generated": _dt.datetime.now().isoformat(timespec="seconds"),
                               "model": llm.load_config().model("vision"), "frames": out})
    print(f"[report] {len(out)} frame description(s) -> {p.frames_json}", file=sys.stderr)
    return out


def _manifest(p: Paths) -> list[dict]:
    m = read_json(p.manifest)
    return (m or {}).get("illustrations", []) if isinstance(m, dict) else []


def build_input(p: Paths, proto: dict, frames: list[dict], language: str | None) -> str:
    blocks = read_transcript(p.transcript)
    sp = read_speakers(p.speakers)
    glossary = list(dict.fromkeys(read_glossary(p.glossary) + references_from_links(p.links)))
    meta_keys = ("Title", "Source", "Duration", "Date candidates", "Transcript", "Repaired passages",
                 "Speakers", "On-screen references", "Degraded run")
    meta = "\n".join(f"- {k}: {proto[k]}" for k in meta_keys if proto.get(k))
    ills = _manifest(p)
    parts = [
        language_rules(language),
        f"## PROTOCOL METADATA\n{meta or '- none'}",
        "## SPEAKERS (label -> name, confidence, evidence)\n" + ("\n".join(
            f"- {r.get('Label')}: {r.get('Name') or '(unnamed)'} [{r.get('Confidence') or '-'}] {r.get('Evidence') or ''}"
            for r in sp["labels"]) or "- not diarized"),
        "## PARTICIPANTS\n" + ("\n".join(f"- {n}" for n in sp["participants"]) or "- none listed"),
        "## OPEN ATTRIBUTIONS\n" + ("\n".join(
            f"- {r.get('Zeit')} | {r.get('Wortmeldung')} | {r.get('Label')} | {r.get('Kandidaten')} | {r.get('Gewicht', '')}"
            for r in sp["open"]) or "- none"),
        "## GLOSSARY (canonical spellings)\n" + ("\n".join(f"- {g}" for g in glossary) or "- none"),
        "## LINKS (read off the screen by OCR)\n" + (p.links.read_text(encoding="utf-8", errors="replace")
                                                    if p.links.is_file() else "- none"),
        "## FRAME DESCRIPTIONS\n" + ("\n".join(
            f"- [{f.get('ts')}] {f.get('screen', '')}: {f.get('content', '')}"
            + (f" | names: {', '.join(f['names'])}" if f.get("names") else "") for f in frames) or "- none"),
        "## ILLUSTRATIONS (id, timestamp, caption)\n" + ("\n".join(
            f"- {i['id']} [{i.get('timestamp_label') or ''}] {i.get('caption', '')}" for i in ills)
            or "- none"),
    ]
    if p.crosscheck.is_file():
        parts.append("## CROSSCHECK (Whisper vs. platform captions)\n"
                     + p.crosscheck.read_text(encoding="utf-8", errors="replace"))
    parts.append("## TRANSCRIPT\n" + "\n".join(b.line() for b in blocks))
    return "\n\n".join(parts)


def _ill_markdown(p: Paths, ill: dict) -> str:
    rel = f"./{p.illustrations.name}/{ill['path']}"
    ts = ill.get("timestamp_label") or ""
    cap = ill.get("caption", "")
    return f"![{cap[:60]}](<{rel}>)\n*Abb. – {cap}" + (f" [{ts}]" if ts else "") + "*"


def embed_illustrations(p: Paths, md: str) -> tuple[str, int]:
    ills = {str(i["id"]): i for i in _manifest(p) if i.get("path")}
    used = 0

    def sub(m):
        nonlocal used
        ill = ills.pop(m.group(1), None)
        if not ill:
            return ""
        used += 1
        return _ill_markdown(p, ill)

    md = re.sub(r"^\{\{ILL:(\w+)\}\}\s*$", sub, md, flags=re.M)
    if ills:  # not placed by the model: append them to the end of the Summary
        extra = "\n\n".join(_ill_markdown(p, i) for i in ills.values())
        md = md.replace("\n## Analysis", f"\n### Weitere Illustrationen\n\n{extra}\n\n## Analysis", 1)
        used += len(ills)
    return md, used


def data_flow_line(proto: dict) -> str:
    cfg = llm.load_config()
    stt = proto.get("Transcript", "")
    return (f"- **Datenfluss:** STT und Diarisierung: {stt or 'siehe Protokoll'}; OCR: RapidOCR lokal. "
            f"Agent-Stufen über {cfg.describe()}: Transkripttext, OCR-Referenzen, Sprechertabelle und "
            f"{llm.USAGE.images} Frame-/Crop-Bild(er) gingen an das Modell; Audio und Video nicht. "
            f"Verbrauch: {llm.USAGE.summary()}. Erzeugt von report.py (transcribe {APP_VERSION}) am "
            f"{_dt.date.today().isoformat()}.")


def write_report(p: Paths, body: str, flow: str, force: bool) -> None:
    text = p.report.read_text(encoding="utf-8") if p.report.is_file() else f"# transcribe: {p.base.name}\n"
    if "## Übersicht" in text:
        if not force:
            raise SystemExit("[report] report exists - use --force")
        text = text.split("## Übersicht", 1)[0].rstrip("\n") + "\n"
    head = re.sub(r"^- \*\*Datenfluss:\*\*.*\n?", "", text, flags=re.M).rstrip("\n")
    p.report.write_text(f"{head}\n{flow}\n\n{body.strip()}\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--language", default=None, help="Report language, e.g. de")
    ap.add_argument("--force", action="store_true", help="Replace an existing report (and re-describe frames)")
    ap.add_argument("--no-frames", action="store_true", help="Skip the vision frame pass")
    ap.add_argument("--max-frames", type=int, default=48, help="Frames sent to the vision model (default 48)")
    args = ap.parse_args()

    p = Paths(resolve_base(args.base))
    if p.report.is_file() and "## Übersicht" in p.report.read_text(encoding="utf-8") and not args.force:
        print(f"[report] report exists - skip (use --force): {p.report}", file=sys.stderr)
        return 0
    ok, reason = llm.available()
    if not ok:
        print(f"[report] skipped: LLM not configured ({reason})", file=sys.stderr)
        return 3
    if not p.transcript.is_file():
        print(f"[report] no transcript: {p.transcript}", file=sys.stderr)
        return 2
    proto = read_protocol(p.protocol)
    frames = [] if args.no_frames else frame_pass(p, proto, args.max_frames, args.language, args.force)
    method = METHOD.read_text(encoding="utf-8")
    prompt = build_input(p, proto, frames, args.language) + "\n\n" + REPORT_TASK
    model = llm.load_config().model("text")
    print(f"[report] writing report via {model}...", file=sys.stderr)
    reply = llm.ask(prompt, system=method, role="text", max_tokens=16000, label="report")
    body = reply.text.strip()
    if body.startswith("```"):
        body = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", body, flags=re.S)
    if "## Übersicht" not in body:
        raise SystemExit(f"[report] reply has no «## Übersicht» section: {body[:300]!r}")
    body = body[body.index("## Übersicht"):]
    body, n_ill = embed_illustrations(p, body)
    write_report(p, body, data_flow_line(proto), args.force)
    print(f"[report] {len(body)} chars, {n_ill} illustration(s) embedded -> {p.report}", file=sys.stderr)
    print(f"[report] usage: {llm.USAGE.summary()}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
