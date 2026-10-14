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
                   [--rewrite] [--no-frames] [--max-frames 48]

Idempotent: a <base>.md that already carries «## Übersicht» is kept unless
--force or --rewrite; both replace the section from «## Übersicht» on,
--force also re-describes the frames, --rewrite reuses the cached ones.

The table of «Offene Sprecherzuordnung» always comes verbatim from the
«Open attributions» of speakers.md, so the report and the worklist show the
same rows. On an existing report (also one the chat agent wrote) a plain
call only re-syncs that table - no model call, no --force needed.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from pathlib import Path

import cli
import llm
from companions import (REPORT_STUB_NOTE, Paths, fmt_ts, language_rules, read_glossary, read_json, read_protocol, read_speakers,
                        read_transcript, references_from_links, resolve_base, ts_seconds, write_json)
from version import APP_VERSION
from state import StageState, stage_key, signature

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
### Offene Sprecherzuordnung (only when OPEN ATTRIBUTIONS lists rows: one sentence on the candidate pool, one on which rows to clarify first; NO table and no own candidate guesses - the script inserts the rows verbatim from speakers.md)

Constraints that override the methodology where they differ:
- You cannot crop illustrations. Where an illustration from ILLUSTRATIONS fits a Summary group, put the placeholder line {{ILL:<id>}} on its own line at that spot; the script replaces it with the image and caption. Use each id at most once.
- Frames are ground truth for names and labels; the transcript is noisy. Use FRAME DESCRIPTIONS and LINKS for spellings.
- Speaker names: use the names from SPEAKERS; a label without a name stays the bare label.
- Do not write a data-flow statement; the script appends it.
- Markdown: one paragraph = one line, no hard wraps. Timestamps as [MM:SS]."""


def _thin(items: list, n: int) -> list:
    if len(items) <= n:
        return items
    if n <= 0:
        return []
    if n == 1:
        return [items[len(items) // 2]]
    return [items[round(i * (len(items) - 1) / (n - 1))] for i in range(n)]


def select_frames(frames: list[dict], limit: int = 48) -> list[dict]:
    if limit < 1:
        raise ValueError("Frame limit must be positive")
    cuts = [f for f in frames if f["kind"] == "CUT"]
    regs = [f for f in frames if f["kind"] == "REG"]
    pick = _thin(cuts, limit if not regs else max(1, limit * 2 // 3))
    pick += _thin(regs, limit - len(pick))
    return sorted(pick, key=lambda f: ts_seconds(f["ts"]))


def frame_pass(p: Paths, proto: dict, max_frames: int, language: str | None, force: bool) -> list[dict]:
    cached = read_json(p.frames_json)
    frames = [f for f in proto.get("frames", []) if Path(f["path"]).is_file()]
    native = native_frames(p)
    if native and (not read_transcript(p.transcript) or len(frames) == 0):
        # Without speech the screen is the only source, and code or forms are
        # unreadable at 512 px: describe the native-resolution OCR frames.
        print(f"[report] no transcript - describing {len(native)} native-resolution OCR frame(s)",
              file=sys.stderr)
        frames = native
    if not frames:
        if isinstance(cached, dict) and cached.get("complete") and not force:
            return cached.get("frames", [])
        print("[report] no frame files on disk (work dir gone or audio-only) - frame pass skipped",
              file=sys.stderr)
        return []
    pick = select_frames(frames, max_frames)
    out: list[dict] = []
    cached_batches = cached.get("batches", {}) if isinstance(cached, dict) and not force else {}
    batches = {}
    failed = []
    # Native frames carry far more legible text; fewer per call keeps the reply
    # inside the completion budget (a truncated JSON reply loses the whole batch).
    is_native = bool(pick) and "ocr_t" in Path(pick[0]["path"]).name
    batch_size = 4 if is_native else FRAME_BATCH
    for i in range(0, len(pick), batch_size):
        batch = pick[i:i + batch_size]
        listing = "\n".join(f"{k + 1}. ts={f['ts']} ({f['kind']})" for k, f in enumerate(batch))
        prompt = (f"{language_rules(language)}\nThe images are attached in this order:\n{listing}\n"
                  "Describe every frame, keep the ts values as given. Keep «content» under 120 words per "
                  "frame: names, titles, identifiers and key values verbatim, no full code listings.")
        cfg = llm.load_config()
        key = signature([Path(f["path"]) for f in batch],
                        {"prompt": prompt, "system": FRAME_SYSTEM, "model": cfg.model("vision"),
                         "provider": cfg.provider, "endpoint": cfg.endpoint, "api_version": cfg.api_version})
        if key in cached_batches:
            batches[key] = cached_batches[key]
            out += batches[key]
            continue
        try:
            reply = llm.ask(prompt, system=FRAME_SYSTEM, images=[f["path"] for f in batch], role="vision",
                            max_tokens=8000, json_mode=True, label=f"frames {i + 1}-{i + len(batch)}")
            finish = ((reply.raw or {}).get("choices") or [{}])[0].get("finish_reason")
            if finish == "length":
                raise ValueError("reply truncated at the completion limit")
            got = reply.json().get("frames", [])
            if len(got) != len(batch) or {d.get("ts") for d in got} != {f["ts"] for f in batch}:
                raise ValueError("frame reply does not cover every requested timestamp")
            batches[key] = [dict(d, kind=next(f["kind"] for f in batch if f["ts"] == d["ts"])) for d in got]
            out += batches[key]
            write_json(p.frames_json, {"complete": False, "frames": out, "batches": {**cached_batches, **batches}})
        except (RuntimeError, ValueError, AttributeError) as exc:
            print(f"[report] WARNING: frame batch {i + 1}-{i + len(batch)} lost: {exc}", file=sys.stderr)
            failed.append(str(i))
    if pick and not out:
        print("[report] WARNING: frame pass returned no descriptions - the report relies on transcript and OCR",
              file=sys.stderr)
    unchanged = isinstance(cached, dict) and cached.get("complete") and cached.get("batches") == batches and not failed
    write_json(p.frames_json, {"generated": cached.get("generated") if unchanged else _dt.datetime.now().isoformat(timespec="seconds"),
                               "model": llm.load_config().model("vision"), "images_sent": len(pick),
                               "frames": out, "batches": batches, "complete": not failed,
                               "failed_batches": failed})
    if failed:
        raise RuntimeError(f"{len(failed)} frame batch(es) failed; successful batches saved for resume")
    print(f"[report] {len(out)} frame description(s) -> {p.frames_json}", file=sys.stderr)
    return out


def native_frames(p: Paths) -> list[dict]:
    """The OCR pass keeps native-resolution PNGs of the cut and changed
    frames in the work dir; listed in <base>.ocr.json."""
    data = read_json(p.ocr)
    if not isinstance(data, dict):
        return []
    out = []
    for f in data.get("frames", []):
        png = f.get("png")
        if png and Path(png).is_file():
            out.append({"path": png, "ts": fmt_ts(float(f.get("t", 0))),
                        "kind": "CUT" if f.get("kind") == "cut" else "REG"})
    return out


def ocr_excerpt(p: Paths, cap: int = 40000, min_score: float = 0.85) -> str:
    """Screen text per OCR frame, each line only the first time it appears,
    capped - a second, verbatim source next to the frame descriptions."""
    data = read_json(p.ocr)
    if not isinstance(data, dict):
        return ""
    seen: set[str] = set()
    parts: list[str] = []
    size = 0
    for f in data.get("frames", []):
        lines = []
        for ln in f.get("lines") or []:
            text = (ln.get("text") if isinstance(ln, dict) else str(ln)).strip()
            score = ln.get("score", 1.0) if isinstance(ln, dict) else 1.0
            if len(text) < 3 or score < min_score or text in seen:
                continue
            seen.add(text)
            lines.append(text)
        if not lines:
            continue
        chunk = f"[{fmt_ts(float(f.get('t', 0)))}] " + " · ".join(lines)
        if size + len(chunk) > cap:
            parts.append("[…] (gekürzt)")
            break
        parts.append(chunk)
        size += len(chunk)
    return "\n".join(parts)


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
        "## SCREEN TEXT (OCR, verbatim, each line at its first appearance)\n" + (ocr_excerpt(p) or "- none"),
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
    alt = cap if len(cap) <= 60 else cap[:60].rsplit(" ", 1)[0] + " …"
    alt = alt.replace("[", "(").replace("]", ")")
    # Blank lines around the block: consecutive images must not merge into one
    # paragraph, and the next heading must not be glued to the caption.
    return f"\n![{alt}](<{rel}>)\n*Abb. – {cap}" + (f" [{ts}]" if ts else "") + "*\n"


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
    return re.sub(r"\n{3,}", "\n\n", md), used


def data_flow_line(p: Paths, proto: dict) -> str:
    """What left the machine, counted across all agent stages - the frame
    pass and the illustration stage may have run in earlier processes, so
    their image counts come from their output files, not from this USAGE."""
    cfg = llm.load_config()
    stt = proto.get("Transcript", "")
    fj = read_json(p.frames_json)
    frame_imgs = fj.get("images_sent", len(fj.get("frames", []))) if isinstance(fj, dict) else 0
    n_ill = len(_manifest(p))
    ill_note = f", dazu {n_ill} Bildausschnitte samt Quellframes in Auswahl und Sichtprüfung" if n_ill else ""
    return (f"- **Datenfluss:** STT und Diarisierung: {stt or 'siehe Protokoll'}; OCR: RapidOCR lokal. "
            f"Agent-Stufen über {cfg.describe()}: Transkripttext, OCR-Text und -Referenzen, Sprechertabelle, "
            f"{frame_imgs} Frame-Bild(er) für die Bildbeschreibung{ill_note}. Audio und Video gingen nicht an "
            f"das Modell. Verbrauch des Report-Laufs: {llm.USAGE.summary()}. Erzeugt von report.py "
            f"(transcribe {APP_VERSION}) am {_dt.date.today().isoformat()}.")


SECTION_RE = re.compile(r"^## Übersicht\s*$", re.M)  # a heading line, not the stub's prose mention
OPEN_HEADING = "### Offene Sprecherzuordnung"
OPEN_SOURCE = "_Zeilen aus «Open attributions» in `{name}`. Klären dort: Name in die Overrides-Tabelle eintragen._"


def open_attributions_table(p: Paths) -> list[str]:
    """The open speaker attributions exactly as speakers.md lists them - the report
    and the worklist the person in the room uses must show the same rows."""
    sp = read_speakers(p.speakers) if p.speakers.is_file() else {"open": []}
    rows = sp.get("open") or []
    if not rows:
        return []
    cell = lambda v: str(v or "").replace("|", "/").strip()
    lines = ["| Zeit | Wortmeldung | Label | Kandidaten | Gewicht |", "|---|---|---|---|---|"]
    lines += [f"| {cell(r.get('Zeit')).strip('`')} | {cell(r.get('Wortmeldung'))} | {cell(r.get('Label'))} | "
              f"{cell(r.get('Kandidaten'))} | {cell(r.get('Gewicht'))} |" for r in rows]
    return lines + ["", OPEN_SOURCE.format(name=p.speakers.name)]


def sync_open_attributions(p: Paths, md: str) -> str:
    """Replace the table of «Offene Sprecherzuordnung» with the rows of speakers.md.
    The prose the report writer put there stays; the section is added when
    speakers.md has open rows and dropped when it has none."""
    table = open_attributions_table(p)
    m = re.search(rf"^{re.escape(OPEN_HEADING)}\s*$", md, re.M)
    if not m:
        return md if not table else md.rstrip("\n") + f"\n\n{OPEN_HEADING}\n\n" + "\n".join(table) + "\n"
    nxt = re.search(r"^#{1,3} ", md[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(md)
    if not table:
        return md[:m.start()].rstrip("\n") + ("\n\n" + md[end:] if nxt else "\n")
    source_re = re.escape(OPEN_SOURCE.split("`")[0])
    prose = [l for l in md[m.end():end].strip("\n").splitlines()
             if not l.lstrip().startswith("|") and not re.match(source_re, l)]
    paras = [x.strip() for x in "\n".join(prose).split("\n\n") if x.strip()]
    section = [OPEN_HEADING, ""] + ([paras[0], ""] if paras else []) + table + \
              [""] + ["\n\n".join(paras[1:])] * bool(paras[1:])
    tail = md[end:]
    return md[:m.start()] + "\n".join(section).rstrip("\n") + ("\n\n" + tail if tail else "\n")


def has_report(text: str) -> bool:
    return all(re.search(rf"^{re.escape(heading)}\s*\n\s*\S", text, re.M)
               for heading in ("## Übersicht", "## Summary", "## Analysis"))


def write_report(p: Paths, body: str, flow: str, force: bool) -> None:
    text = p.report.read_text(encoding="utf-8") if p.report.is_file() else f"# transcribe: {p.base.name}\n"
    m = SECTION_RE.search(text)
    if m:
        if not force:
            raise SystemExit("[report] report exists - use --force")
        text = text[: m.start()].rstrip("\n") + "\n"
    # The written report replaces the stub's placeholder; the data-flow line joins the header bullets.
    head = re.sub(r"^- \*\*Datenfluss:\*\*.*\n?", "", text, flags=re.M)
    head = head.replace(REPORT_STUB_NOTE, "").strip("\n")
    from state import write
    write(p.report, f"{head}\n{flow}\n\n{body.strip()}\n")


def main() -> int:
    ap = cli.parser(__doc__, exit_codes={0: "done or report exists", 1: "model reply unusable",
                                             2: "no transcript", 3: "chat deployment not configured"},
                    examples=['python report.py "<base or recording>" --language de',
                              'python report.py "<base or recording>" --force --no-frames'])
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--language", default=None, help="Report language, e.g. de")
    ap.add_argument("--force", action="store_true", help="Replace an existing report (and re-describe frames)")
    ap.add_argument("--rewrite", action="store_true",
                    help="Replace an existing report but keep the cached frame descriptions")
    ap.add_argument("--no-frames", action="store_true", help="Skip the vision frame pass")
    ap.add_argument("--max-frames", type=int, default=48, help="Frames sent to the vision model (default 48)")
    args = cli.parse(ap)

    p = Paths(resolve_base(args.base))
    state = StageState(p.base)
    if args.max_frames < 1:
        ap.error("--max-frames must be positive")
    options = {"language": args.language, "no_frames": args.no_frames, "max_frames": args.max_frames}
    key = stage_key(p, "report", options)
    replace = args.force or args.rewrite
    if p.report.is_file() and has_report(p.report.read_text(encoding="utf-8")) and not replace and state.current("report", key, [p.report]):
        text = p.report.read_text(encoding="utf-8")
        synced = sync_open_attributions(p, text)
        if synced != text:
            p.report.write_text(synced, encoding="utf-8")
            print(f"[report] report exists - open speaker attributions synced from {p.speakers.name}",
                  file=sys.stderr)
        else:
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
    if not reply.complete:
        raise RuntimeError("Report reply was truncated or filtered; previous report preserved")
    body = reply.text.strip()
    if body.startswith("```"):
        body = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", body, flags=re.S)
    if not has_report(body):
        raise RuntimeError("Report reply is missing required sections; previous report preserved")
    body = body[body.index("## Übersicht"):]
    body, n_ill = embed_illustrations(p, body)
    body = sync_open_attributions(p, body)
    write_report(p, body, data_flow_line(p, proto), True)
    state.record("report", stage_key(p, "report", options), [p.report])
    print(f"[report] {len(body)} chars, {n_ill} illustration(s) embedded -> {p.report}", file=sys.stderr)
    print(f"[report] usage: {llm.USAGE.summary()}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
