#!/usr/bin/env python3
"""Fill the speaker mapping (<base>.speakers.md) with the configured LLM.

Scripted version of the Personen & Stimmen pass the Claude session does by
hand: read the pre-filled speakers.md (talk time, name plates, caption
voices, address hits), the transcript and the participant list, then decide
per diarization label who it is and how sure we are. Contributions that
sit inside a block of another label (a question answered in the same
block) are listed as open attributions - the worklist the person who was
in the room closes.

  python speakers_fill.py "<base or any companion>" [--language de]
                          [--force] [--apply] [--dry-run]

Rules (same as report-writing.md):
  frame/caption evidence AND address-pattern evidence -> high, name set
  one of the two                                      -> medium, name + (?)
  neither                                             -> name left empty

Idempotent: a speakers.md whose labels are all named is left alone unless
--force, and so is one that nobody touched since the last fill (same file,
transcript and participants list - the stamp carries their hash). The human
edits the same file; a re-run never overwrites a non-empty Name cell
without --force.

After every fill (and on a skip) grounding.py ties each uncertainty to the
transcript: verbatim quote and sentence start time in «Open attributions»,
and a «Hörproben» section with quotes to listen to per uncertain label.
With --apply the names then go into transcript and vtt - on a skip too, so a
hand correction in speakers.md lands without a model call.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
from pathlib import Path

import cli
import llm
from companions import (Paths, language_rules, read_input_lines, read_speakers, read_transcript, resolve_base,
                        unique_people)
from version import APP_VERSION

OPEN_HEADING = "## Open attributions"
STAMP_RE = re.compile(r"_Names proposed by speakers_fill\.py[^\n]*_")
HASH_RE = re.compile(r"input ([0-9a-f]{12})")

SYSTEM = """You map diarization labels of a meeting transcript to real people.

Evidence classes:
- FRAME evidence: an on-screen name plate, participant tile, caption voice tag or the fact that a person owns an artefact shown on screen (page created by X).
- ADDRESS evidence: someone is addressed by name («Andrea, …») and the next or previous label change goes to / comes from that label; or a self-introduction; or a label speaks about a person in third person (then it is NOT that person).
- ROLE evidence (audio-only or screen share without plates): a label consistently owns a known person's responsibilities (presents the topic, answers as the maintainer).

- HUMAN evidence: the prefilled Evidence cell or the notes say that a person who was present attributed the label or a contribution («Zugeordnet von <Name> (anwesend)», «Zuordnung <Name>»). This outranks every other class: keep that name with confidence high and keep the attribution in the evidence text. Never downgrade or contradict a HUMAN attribution; per-contribution human attributions also decide the candidate of an open contribution.

Confidence:
- high: HUMAN evidence, or FRAME (or ROLE) evidence AND ADDRESS evidence.
- medium: exactly one of them. Write the name with a trailing " (?)".
- low or none: leave the name empty.

A shared room microphone splits one person into several labels and files questions from the room under the presenter's label. Two labels that are clearly the same voice get the same name. A question that is answered inside the same block by the presenter was asked by someone else: list it under "open" with the candidates (participants minus the presenter, minus people the evidence excludes).

Names: canonical first name only («Thomas»); on a first-name collision add the shortest unique surname prefix («Andrea B»). Never invent names that are not in the participant list or the transcript.

Return ONLY a JSON object:
{"labels": {"<LABEL>": {"name": "Thomas" | "Thomas (?)" | "", "confidence": "high" | "medium" | "low" | "", "evidence": "<one or two sentences, cite [MM:SS] and the evidence class>"}},
 "open": [{"time": "MM:SS", "quote": "<short verbatim quote>", "label": "<LABEL>", "candidates": "<Name, Name>", "weight": "decision" | "objection" | "commitment" | "question"}],
 "notes": "<anything the reader must know, e.g. two labels merged, or a remote participant without own cluster>"}
Every label from the table must appear in "labels"."""


def _rows_to_text(rows: list[dict]) -> str:
    return "\n".join(
        f"- {r.get('Label')}: talk {r.get('Talk time')}, {r.get('Turns')} turns, active {r.get('Active')}"
        + (f", prefilled name {r.get('Name')} ({r.get('Confidence')}): {r.get('Evidence')}" if r.get("Name") else "")
        for r in rows
    )


def input_hash(p: Paths) -> str:
    """Hash over everything a person can change between two fills: speakers.md
    without the stamp line, the transcript and the participants file."""
    h = hashlib.sha256()
    for path in (p.speakers, p.transcript, p.participants_file):
        text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
        h.update(STAMP_RE.sub("", text).encode("utf-8") + b"\0")
    return h.hexdigest()[:12]


def build_prompt(sp: dict, participants: list[str], blocks, language: str | None) -> str:
    evidence = sp["text"].split("## Evidence", 1)[1] if "## Evidence" in sp["text"] else ""
    transcript = "\n".join(b.line() for b in blocks)
    return (
        f"{language_rules(language)} Evidence and quotes in that language, labels and names verbatim.\n\n"
        f"## Labels (from diarization)\n{_rows_to_text(sp['labels'])}\n\n"
        f"## Participants (name plates, caption voices, participants file)\n"
        + ("\n".join(f"- {n}" for n in participants) or "- none listed") +
        f"\n\n## Evidence the script found\n{evidence.strip()}\n\n"
        f"## Transcript\n{transcript}\n"
    )


def _render_open(open_rows: list[dict], model: str, notes: str) -> list[str]:
    lines = ["", OPEN_HEADING, "",
             f"_Contributions filed under another label - the worklist for the person who was in the "
             f"room. Proposed by {model} on {_dt.date.today().isoformat()}; confirm by writing the name "
             f"into the Overrides table (whole block) or leave it for the compact transcript._", ""]
    if notes:
        lines += [f"_{notes.strip()}_", ""]
    lines += ["| Zeit | Wortmeldung | Label | Kandidaten | Gewicht |", "|---|---|---|---|---|"]
    for r in open_rows:
        lines.append(f"| `[{r.get('time', '')}]` | {r.get('quote', '').replace('|', '/')} | "
                     f"{r.get('label', '')} | {r.get('candidates', '')} | {r.get('weight', '')} |")
    if not open_rows:
        lines.append("| | keine | | | |")
    return lines


def write_back(path: Path, result: dict, model: str, force: bool) -> tuple[int, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    labels = result.get("labels", {}) or {}
    named = 0
    out: list[str] = []
    in_labels = False
    for raw in lines:
        line = raw.strip()
        if line.startswith("| Label |"):
            in_labels = True
            out.append(raw)
            continue
        if in_labels and line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            if len(cells) >= 7 and cells[0] in labels and not all(set(c) <= set("-: ") for c in cells):
                cur_name = cells[4]
                prop = labels[cells[0]]
                if (not cur_name or force) and isinstance(prop, dict):
                    cells[4] = (prop.get("name") or "").strip()
                    cells[5] = (prop.get("confidence") or "").strip()
                    cells[6] = (prop.get("evidence") or "").replace("|", "/").replace("\n", " ").strip()
                    if cells[4]:
                        named += 1
                out.append("| " + " | ".join(cells) + " |")
                continue
        elif in_labels and not line:
            in_labels = False
        out.append(raw)
    new_text = "\n".join(out)
    # replace or append the open-attributions section
    if OPEN_HEADING in new_text:
        head, _, tail = new_text.partition(OPEN_HEADING)
        rest = re.split(r"\n## ", tail, maxsplit=1)
        after = ("\n## " + rest[1]) if len(rest) > 1 else ""
        new_text = head.rstrip("\n") + "\n" + "\n".join(_render_open(result.get("open") or [], model,
                                                                      result.get("notes") or "")) + "\n" + after
    else:
        new_text = new_text.rstrip("\n") + "\n" + "\n".join(_render_open(result.get("open") or [], model,
                                                                         result.get("notes") or "")) + "\n"
    stamp = f"_Names proposed by speakers_fill.py (transcribe {APP_VERSION}, {model}) on {_dt.date.today().isoformat()}; the human corrects this file, the next render follows it._"
    if "_Names proposed by speakers_fill.py" not in new_text:
        new_text = new_text.replace("\n## Labels\n", f"\n{stamp}\n\n## Labels\n", 1)
    else:
        new_text = STAMP_RE.sub(lambda _: stamp, new_text, count=1)
    path.write_text(new_text + ("" if new_text.endswith("\n") else "\n"), encoding="utf-8")
    return named, len(result.get("open") or [])


def stamp_hash(p: Paths) -> None:
    """Record the input hash in the stamp write_back just wrote, computed on
    the files as they are now (after --apply rewrote transcript and vtt)."""
    h = input_hash(p)
    text = p.speakers.read_text(encoding="utf-8")
    text = STAMP_RE.sub(lambda m: re.sub(r", input [0-9a-f]{12}", "", m.group(0))
                        .replace("; the human", f", input {h}; the human", 1), text, count=1)
    p.speakers.write_text(text, encoding="utf-8")


def finish(p: Paths, restamp: bool, apply: bool) -> None:
    """Ground every uncertainty in the transcript (grounding.py, no model call),
    then - with --apply - put the names of speakers.md into transcript and vtt.
    Both run on a skip too, so a hand correction lands without a model call;
    the stamp is renewed afterwards because the transcript is part of its hash."""
    import grounding
    import speakers as speakers_mod
    changed = False
    if apply:
        mapping, overrides = speakers_mod.parse_mapping(p.speakers), speakers_mod.parse_overrides(p.speakers)
        touched = speakers_mod.apply_to_files(p.base, mapping, overrides)
        print(f"[speakers-fill] applied {len(mapping)} name(s), {len(overrides)} override(s) to "
              f"{len(touched)} file(s)", file=sys.stderr)
        changed = bool(touched)
    # after the apply, so a second call finds the same transcript and changes nothing
    if grounding.ground_file(p):
        print(f"[speakers-fill] quotes and times grounded in the transcript, Hörproben updated", file=sys.stderr)
        changed = True
    if changed and restamp and STAMP_RE.search(p.speakers.read_text(encoding="utf-8")):
        stamp_hash(p)


def main() -> int:
    ap = cli.parser(__doc__, exit_codes={0: "done or nothing to do", 2: "no speakers.md or no transcript",
                                             3: "chat deployment not configured"},
                    examples=['python speakers_fill.py "<base or recording>" --language de --apply'])
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--language", default=None, help="Language of evidence and quotes, e.g. de")
    ap.add_argument("--force", action="store_true", help="Overwrite names the file already carries")
    ap.add_argument("--apply", action="store_true", help="Run speakers.py --apply afterwards")
    ap.add_argument("--dry-run", action="store_true", help="Print the model's JSON, write nothing")
    args = cli.parse(ap)

    p = Paths(resolve_base(args.base))
    if not p.speakers.is_file():
        print(f"[speakers-fill] no speakers file: {p.speakers}", file=sys.stderr)
        return 2
    sp = read_speakers(p.speakers)
    if not sp["labels"]:
        print("[speakers-fill] no labels table - nothing to do", file=sys.stderr)
        return 0
    unnamed = [r for r in sp["labels"] if not r.get("Name")]
    if not unnamed and not args.force and OPEN_HEADING in sp["text"]:
        print(f"[speakers-fill] all {len(sp['labels'])} labels named and open list present - skip (use --force)",
              file=sys.stderr)
        finish(p, restamp=True, apply=args.apply)
        return 0
    stamp = STAMP_RE.search(sp["text"])
    last = HASH_RE.search(stamp.group(0)) if stamp else None
    if last and last.group(1) == input_hash(p) and not args.force:
        print(f"[speakers-fill] speakers.md, transcript and participants unchanged since the last fill - skip "
              f"(edit speakers.md or use --force)", file=sys.stderr)
        finish(p, restamp=True, apply=args.apply)
        return 0
    ok, reason = llm.available()
    if not ok:
        print(f"[speakers-fill] skipped: LLM not configured ({reason})", file=sys.stderr)
        finish(p, restamp=False, apply=args.apply)
        return 3
    blocks = read_transcript(p.transcript)
    if not blocks:
        print(f"[speakers-fill] no transcript blocks in {p.transcript}", file=sys.stderr)
        return 2

    model = llm.load_config().model("text")
    print(f"[speakers-fill] asking {model} about {len(sp['labels'])} label(s), {len(blocks)} blocks...",
          file=sys.stderr)
    # A participants file added after run.py pre-filled speakers.md counts too.
    participants = unique_people(sp["participants"] + read_input_lines(p.participants_file))
    result = llm.ask_json(build_prompt(sp, participants, blocks, args.language), system=SYSTEM, role="text",
                          max_tokens=4000, label="speakers-fill")
    if args.dry_run:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    named, n_open = write_back(p.speakers, result, model, args.force)
    print(f"[speakers-fill] {named} label(s) named, {n_open} open contribution(s) -> {p.speakers}",
          file=sys.stderr)
    finish(p, restamp=False, apply=args.apply)
    stamp_hash(p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
