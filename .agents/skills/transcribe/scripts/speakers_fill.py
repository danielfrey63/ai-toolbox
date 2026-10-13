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
--force. The human edits the same file; a re-run never overwrites a
non-empty Name cell without --force.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from pathlib import Path

import llm
from companions import Paths, language_rules, read_speakers, read_transcript, resolve_base
from version import APP_VERSION

OPEN_HEADING = "## Open attributions"

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


def build_prompt(sp: dict, blocks, language: str | None) -> str:
    evidence = sp["text"].split("## Evidence", 1)[1] if "## Evidence" in sp["text"] else ""
    transcript = "\n".join(b.line() for b in blocks)
    return (
        f"{language_rules(language)} Evidence and quotes in that language, labels and names verbatim.\n\n"
        f"## Labels (from diarization)\n{_rows_to_text(sp['labels'])}\n\n"
        f"## Participants (name plates, caption voices, transcribe-participants.txt)\n"
        + ("\n".join(f"- {p}" for p in sp["participants"]) or "- none listed") +
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
        new_text = re.sub(r"_Names proposed by speakers_fill\.py[^\n]*_", stamp, new_text, count=1)
    path.write_text(new_text + ("" if new_text.endswith("\n") else "\n"), encoding="utf-8")
    return named, len(result.get("open") or [])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--language", default=None, help="Language of evidence and quotes, e.g. de")
    ap.add_argument("--force", action="store_true", help="Overwrite names the file already carries")
    ap.add_argument("--apply", action="store_true", help="Run speakers.py --apply afterwards")
    ap.add_argument("--dry-run", action="store_true", help="Print the model's JSON, write nothing")
    args = ap.parse_args()

    p = Paths(resolve_base(args.base))
    if not p.speakers.is_file():
        print(f"[speakers-fill] no speakers file: {p.speakers}", file=sys.stderr)
        return 2
    ok, reason = llm.available()
    if not ok:
        print(f"[speakers-fill] skipped: LLM not configured ({reason})", file=sys.stderr)
        return 3
    sp = read_speakers(p.speakers)
    if not sp["labels"]:
        print("[speakers-fill] no labels table - nothing to do", file=sys.stderr)
        return 0
    unnamed = [r for r in sp["labels"] if not r.get("Name")]
    if not unnamed and not args.force and OPEN_HEADING in sp["text"]:
        print(f"[speakers-fill] all {len(sp['labels'])} labels named and open list present - skip (use --force)",
              file=sys.stderr)
        return 0
    blocks = read_transcript(p.transcript)
    if not blocks:
        print(f"[speakers-fill] no transcript blocks in {p.transcript}", file=sys.stderr)
        return 2

    model = llm.load_config().model("text")
    print(f"[speakers-fill] asking {model} about {len(sp['labels'])} label(s), {len(blocks)} blocks...",
          file=sys.stderr)
    result = llm.ask_json(build_prompt(sp, blocks, args.language), system=SYSTEM, role="text",
                          max_tokens=4000, label="speakers-fill")
    if args.dry_run:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    named, n_open = write_back(p.speakers, result, model, args.force)
    print(f"[speakers-fill] {named} label(s) named, {n_open} open contribution(s) -> {p.speakers}",
          file=sys.stderr)
    if args.apply:
        import speakers as speakers_mod
        mapping = speakers_mod.parse_mapping(p.speakers)
        overrides = speakers_mod.parse_overrides(p.speakers)
        touched = speakers_mod.apply_to_files(p.base, mapping, overrides)
        print(f"[speakers-fill] applied {len(mapping)} name(s) to {len(touched)} file(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
