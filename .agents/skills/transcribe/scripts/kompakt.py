#!/usr/bin/env python3
"""Write the compact transcript (<base>.transcript-kompakt.md) with the LLM.

Scripted version of the editorial pass the Claude session does by hand:
topic chapters first (reused from <base>.analysis.json when report.py ran
before), then one call per chapter that condenses the verbatim blocks of
that window into speaker-attributed statements. Canonical spellings come
from the glossary and, when present, the inventory in analysis.json.

  python kompakt.py "<base or any companion>" [--language de] [--force]

Idempotent: an existing compact transcript is kept unless --force.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from state import StageState, stage_key, digest, write
import config

import cli
import llm
from companions import (Block, Paths, fmt_ts, language_rules, read_glossary, read_json, read_protocol,
                        read_speakers, read_transcript, references_from_links, resolve_base,
                        transcript_source, ts_seconds, write_json)
from version import APP_VERSION

CHAPTER_SYSTEM = """You structure a meeting transcript into chapters.
Return ONLY a JSON object {"chapters": [{"start": "MM:SS", "end": "MM:SS", "title": "<short topic label>"}]}.
Rules: 5 to 12 chapters in chronological order, contiguous (each start = previous end), first start = first block, last end = last block. Use the boundaries the speakers establish (topic shifts, "jetzt kommen wir zu", a question that opens a new subject), not equal time slices. Titles are topic labels, not sentences."""

CONDENSE_SYSTEM = """You condense a window of a verbatim meeting transcript into an editorially clean, speaker-attributed rendition.
Return ONLY a JSON object {"statements": [{"time": "MM:SS", "speaker": "<name or label>", "text": "<polished statement>"}]}.
Rules:
- One statement per substantive contribution; timestamp = start of the block it comes from.
- Fold fillers, repetitions, decoder loops ("das heisst, das heisst, das heisst") and bare acknowledgements ("Ja.", "Genau.") into the flow. Keep every fact, number, name, decision and question.
- Normalize dialect garbles into standard language; replace misrecognitions by the canonical spellings listed under GLOSSARY when the context makes the match obvious (a spoken «Story 163» next to an on-screen ticket DFABETRIEB-1763 is that ticket). Never invent content.
- Speaker: keep the block's speaker as given. If a block contains a question that is clearly asked by someone else and then answered by the block's speaker, split it: the question gets the candidate from OPEN ATTRIBUTIONS when exactly one candidate is listed for that time, otherwise the bare label. Do not guess names beyond that.
- Statements inside a block by two people are split into two statements with the same timestamp."""


def chapters_from_llm(blocks: list[Block], language: str | None) -> list[dict]:
    text = "\n".join(b.line() for b in blocks)
    obj = llm.ask_json(f"{language_rules(language)}\n\n## Transcript\n{text}\n", system=CHAPTER_SYSTEM,
                       role="text", max_tokens=2000, label="kompakt-chapters")
    chapters = [c for c in obj.get("chapters", []) if c.get("start") and c.get("end") and c.get("title")]
    return chapters


def condense(chapter: dict, blocks: list[Block], glossary: list[str], canonical: list[str],
             open_rows: list[dict], language: str | None) -> list[dict]:
    start, end = ts_seconds(chapter["start"]), ts_seconds(chapter["end"])
    window = [b for b in blocks if start <= b.seconds < end or (b is blocks[-1] and b.seconds == end)]
    if not window:
        return []
    open_in = [r for r in open_rows if start <= ts_seconds(r.get("Zeit", "[0:00]").strip("`[]")) < end]
    prompt = (
        f"{language_rules(language)}\n\n"
        f"## Chapter\n{chapter['title']} [{chapter['start']} – {chapter['end']}]\n\n"
        "## GLOSSARY (canonical spellings)\n" + ("\n".join(f"- {g}" for g in glossary + canonical) or "- none") +
        "\n\n## OPEN ATTRIBUTIONS (time, quote, label, candidates)\n"
        + ("\n".join(f"- {r.get('Zeit')} {r.get('Wortmeldung')} | {r.get('Label')} | {r.get('Kandidaten')}"
                     for r in open_in) or "- none") +
        "\n\n## Transcript window\n" + "\n".join(b.line() for b in window) + "\n"
    )
    obj = llm.ask_json(prompt, system=CONDENSE_SYSTEM, role="text", max_tokens=6000,
                       label=f"kompakt:{chapter['start']}")
    return [s for s in obj.get("statements", []) if s.get("text")]


def normalize_chapters(chapters: list[dict], blocks: list[Block]) -> list[dict]:
    """Own the interval boundaries deterministically; every block belongs once."""
    starts = {ts_seconds(c["start"]): str(c["title"]) for c in chapters
              if c.get("start") and c.get("title") and blocks[0].seconds <= ts_seconds(c["start"]) <= blocks[-1].seconds}
    starts.setdefault(blocks[0].seconds, "Gespräch")
    times = sorted(starts)
    return [{"start": fmt_ts(t), "end": fmt_ts(times[i + 1] if i + 1 < len(times) else blocks[-1].seconds + 1),
             "title": starts[t]} for i, t in enumerate(times)]


def render(p: Paths, title: str, chapters: list[dict], statements: dict[int, list[dict]],
           participants: list[str], model: str) -> str:
    proto = read_protocol(p.protocol)
    duration = proto.get("Duration", "")
    lines = [
        f"# Transkript kompakt: {title}",
        "",
        f"_Sprecherzugeordnete Kurzfassung des Volltexts ([`{p.transcript.name}`](<./{p.transcript.name}>)). "
        f"Erzeugt von kompakt.py (transcribe {APP_VERSION}, {model}) am {_dt.date.today().isoformat()}: "
        f"Füllwörter und Wiederholungen entfernt, Verhörer auf die Glossar-Schreibweisen korrigiert, "
        f"Inhalt unverändert. Der Volltext bleibt die wörtliche Referenz._",
        "",
        f"**Quelle:** {transcript_source(p.transcript) or p.base.name}" + (f", Dauer {duration}" if duration else ""),
        "",
        "**Teilnehmende:** " + (", ".join(participants) if participants else "siehe speakers.md"),
        "",
    ]
    for i, ch in enumerate(chapters):
        lines += [f"## {ch['title']}", ""]
        for s in statements.get(i, []):
            lines.append(f"**[{s.get('time', ch['start'])}] {s.get('speaker', '')}:** {s['text'].strip()}")
            lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def main() -> int:
    ap = cli.parser(__doc__, exit_codes={0: "done, skipped or nothing to condense",
                                             3: "chat deployment not configured"},
                    examples=['python kompakt.py "<base or recording>" --language de'])
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--language", default=None, help="Language of the output, e.g. de")
    ap.add_argument("--force", action="store_true", help="Rewrite an existing compact transcript")
    args = cli.parse(ap)

    p = Paths(resolve_base(args.base))
    state = StageState(p.base)
    key = stage_key(p, "kompakt", {"language": args.language})
    if state.current("kompakt", key, [p.kompakt]) and not args.force:
        print(f"[kompakt] exists - skip (use --force): {p.kompakt}", file=sys.stderr)
        return 0
    ok, reason = llm.available()
    if not ok:
        print(f"[kompakt] skipped: LLM not configured ({reason})", file=sys.stderr)
        return 3
    blocks = read_transcript(p.transcript)
    if not blocks:
        print("[kompakt] transcript is empty (silent or frames-only run) - nothing to condense", file=sys.stderr)
        return 0
    if not any(b.label for b in blocks):
        print("[kompakt] transcript carries no speaker labels - compact transcript is for diarized runs",
              file=sys.stderr)
        return 0

    sp = read_speakers(p.speakers)
    glossary = list(dict.fromkeys(read_glossary(p.glossary) + references_from_links(p.links)))
    analysis = read_json(p.analysis) or {}
    canonical = [e.get("name") for e in (analysis.get("inventory") or {}).get("entities", []) if e.get("name")] \
        if isinstance(analysis, dict) else []
    chapters = analysis.get("chapters") if isinstance(analysis, dict) and analysis.get("input") == key and not args.force else None
    model = llm.load_config().model("text")
    if not chapters:
        print(f"[kompakt] asking {model} for chapters ({len(blocks)} blocks)...", file=sys.stderr)
        chapters = chapters_from_llm(blocks, args.language)
        if not chapters:
            chapters = [{"start": blocks[0].ts, "end": fmt_ts(blocks[-1].seconds + 1), "title": "Gespräch"}]
        if isinstance(analysis, dict):
            analysis["chapters"] = chapters
            analysis["input"] = key
            write_json(p.analysis, analysis)
    chapters = normalize_chapters(chapters, blocks)
    print(f"[kompakt] condensing {len(chapters)} chapter(s) via {model}...", file=sys.stderr)
    statements: dict[int, list[dict]] = {}
    cache_path = p.base.with_name(p.base.name + ".kompakt.json")
    cache = read_json(cache_path) or {}
    cached = cache.get("chapters", {}) if not args.force else {}
    jobs = {}
    failures = []
    with ThreadPoolExecutor(max_workers=int(config.get("TRANSCRIBE_LLM_WORKERS"))) as pool:
        for i, ch in enumerate(chapters):
            from state import signature
            cfg = llm.load_config()
            chapter_key = signature([Path(__file__)], {"chapter": ch,
                "blocks": [b.line() for b in blocks if ts_seconds(ch["start"]) <= b.seconds < ts_seconds(ch["end"])],
                "glossary": glossary, "canonical": canonical, "open": sp.get("open", []),
                "language": args.language, "model": model, "endpoint": cfg.endpoint, "provider": cfg.provider})
            if chapter_key in cached:
                statements[i] = cached[chapter_key]
            else:
                jobs[pool.submit(condense, ch, blocks, glossary, canonical, sp.get("open", []), args.language)] = (i, chapter_key)
        for future in as_completed(jobs):
            i, chapter_key = jobs[future]
            try:
                statements[i] = future.result()
                if not statements[i]:
                    raise RuntimeError(f"Empty compact chapter: {chapters[i]['title']}")
            except (RuntimeError, ValueError) as exc:
                failures.append(str(exc))
                continue
            cached[chapter_key] = statements[i]
            write_json(cache_path, {"input": key, "chapters": cached})
    if failures:
        raise RuntimeError(f"{len(failures)} compact chapter(s) failed; successful chapters saved: " + config.redact(failures[0]))
    title = p.base.name.split(" - ", 1)[1] if " - " in p.base.name else p.base.name
    write(p.kompakt, render(p, title, chapters, statements, sp.get("participants", []), model))
    state.record("kompakt", key, [p.kompakt])
    n = sum(len(v) for v in statements.values())
    print(f"[kompakt] {n} statement(s) in {len(chapters)} chapter(s) -> {p.kompakt}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
