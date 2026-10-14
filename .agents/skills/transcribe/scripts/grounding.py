#!/usr/bin/env python3
"""Ground the speaker uncertainties of speakers.md in the verbatim transcript.

Every uncertainty gets a quote that really is in the transcript and the time
that quote starts, so a person can jump there and listen:

- «Open attributions»: each row's quote is looked up in the transcript and
  replaced by the verbatim sentence; «Zeit» becomes that sentence's start
  instead of the start of its transcript block (a block can run 30 s and
  more). A quote that cannot be found is marked, not guessed.
- «Hörproben» (new section): for every label whose name is empty, marked
  (?) or not high-confidence, up to three verbatim sentences with their
  time - first the moments its Evidence cites, then samples spread over the
  recording.
- A row whose time falls in a transcript block the Overrides table already
  names is answered: it leaves «Open attributions» (its quote goes into the
  override's empty Wortmeldung cell), so the open list shrinks with every
  answer - in the report too.

Times come from the Whisper segments (<base>.segments.json), interpolated
by character position inside a segment (about ±3 s); without segments the
transcript blocks are used. A sentence's label comes from the diarization
turns it overlaps (<base>.turns.json), else from its transcript block;
where it differs from the label a contribution is filed under, both are
shown - a hint for room-microphone questions.

No model call; idempotent. speakers_fill.py runs it after every fill.

  python grounding.py "<base or any companion>"
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

import cli
from companions import Paths, fmt_ts, read_json, read_speakers, read_transcript, resolve_base, ts_seconds
from speakers import block_of, parse_overrides

SAMPLES_HEADING = "## Hörproben"
OPEN_HEADING = "## Open attributions"
NOT_FOUND = "nicht im Transkript gefunden"
ALL_ANSWERED = "_Alle Stellen sind in den Overrides beantwortet._"
TS_CELL = re.compile(r"\d{1,2}:\d{2}(?::\d{2})?")
MAX_QUOTE = 220
MIN_RATIO = 0.6


def _norm(s: str) -> str:
    return " ".join(re.sub(r"[^\w\s]", " ", s.lower()).split())


def sentences(p: Paths) -> list[dict]:
    """Verbatim sentences with start time, transcript-block label and diarization label."""
    blocks = read_transcript(p.transcript)
    starts = [b.seconds for b in blocks]

    def block_label(t: float) -> str:
        i = max((k for k, s in enumerate(starts) if s <= t + 0.5), default=0)
        return blocks[i].label if blocks else ""

    seg = read_json(p.base.with_name(p.base.name + ".segments.json"))
    segs = seg.get("segments") if isinstance(seg, dict) else seg
    turns = read_json(p.base.with_name(p.base.name + ".turns.json")) or []
    if not segs:
        segs = [{"start": b.seconds, "end": (blocks[i + 1].seconds if i + 1 < len(blocks) else b.seconds + 30),
                 "text": b.text} for i, b in enumerate(blocks)]
    out: list[dict] = []
    for s in segs:
        text = (s.get("text") or "").strip()
        if not text:
            continue
        start, end = float(s["start"]), float(s["end"])
        pos = 0
        for sent in re.split(r"(?<=[.?!…])\s+", text):
            off = text.find(sent, pos)
            pos = off + len(sent)
            t0 = start + (end - start) * off / max(len(text), 1)
            t1 = start + (end - start) * pos / max(len(text), 1)
            spk, best = "", 0.0
            for tr in turns if isinstance(turns, list) else []:
                ov = max(0.0, min(t1, tr["end"]) - max(t0, tr["start"]))
                if ov > best:
                    spk, best = tr["speaker"], ov
            # the diarization label first: after speakers.py --apply the transcript
            # blocks carry names instead of labels
            out.append({"t": t0, "text": sent.strip(), "label": spk or block_label(t0), "turn": spk})
    return out


def find(sents: list[dict], quote: str, near: float | None) -> tuple[dict | None, float]:
    """Best sentence (or sentence pair) for a quote, preferring the neighbourhood of `near`."""
    nq = _norm(quote)
    if not nq:
        return None, 0.0
    pool = range(len(sents))
    if near is not None:
        close = [i for i in pool if abs(sents[i]["t"] - near) <= 120]
        pool = close or list(pool)
    best, score = None, 0.0
    for i in pool:
        first = _norm(sents[i]["text"])
        for span in (1, 2):
            if i + span > len(sents):
                continue
            nc = _norm(" ".join(sents[k]["text"] for k in range(i, i + span)))
            if nq in nc:
                r, at = 1.0, nc.index(nq)
            else:
                m = difflib.SequenceMatcher(None, nc, nq, autojunk=False).find_longest_match(0, len(nc), 0, len(nq))
                r, at = m.size / len(nq), m.a
                if len(nc) <= len(nq) * 1.5:
                    r = max(r, difflib.SequenceMatcher(None, nq, nc, autojunk=False).ratio())
            # a pair only counts for the sentence the match starts in; a match that
            # starts in the second sentence is that sentence's own hit
            if span == 2 and at > len(first):
                continue
            better = r > score + 1e-9
            tie = abs(r - score) <= 1e-9 and best is not None and near is not None \
                and abs(sents[i]["t"] - near) < abs(best["t"] - near)
            if better or tie:
                best, score = sents[i], r
    return best, score


def _clip(text: str) -> str:
    return text if len(text) <= MAX_QUOTE else text[:MAX_QUOTE].rsplit(" ", 1)[0] + " …"


def _label_cell(label: str, sent: dict) -> str:
    return f"{label} · Satz: {sent['turn']}" if sent.get("turn") and sent["turn"] != label else label


def ground_open_rows(rows: list[dict], sents: list[dict]) -> list[dict]:
    out = []
    for r in rows:
        r = dict(r)
        quote = re.sub(rf"\s*\({NOT_FOUND}\)\s*$", "", (r.get("Wortmeldung") or "").strip()).strip("«»\"„“ ")
        label = (r.get("Label") or "").split(" · ")[0].strip()
        zeit = (r.get("Zeit") or "").strip("`[] ")
        near = ts_seconds(zeit) if re.fullmatch(r"\d{1,2}:\d{2}(?::\d{2})?", zeit) else None
        sent, score = find(sents, quote, near)
        if sent and score >= MIN_RATIO:
            r["Zeit"] = f"`[{fmt_ts(sent['t'])}]`"
            r["Wortmeldung"] = _clip(sent["text"]).replace("|", "/")
            r["Label"] = _label_cell(label or sent["label"], sent)
        else:
            r["Wortmeldung"] = f"{quote} ({NOT_FOUND})"
        out.append(r)
    return out


def samples(label_rows: list[dict], sents: list[dict], per_label: int = 3) -> list[str]:
    lines = [SAMPLES_HEADING, "",
             "_Wörtliche Stellen je unsicherem Label zum Nachhören. Zeit = Satzanfang, aus der Segmentzeit "
             "interpoliert (etwa ±3 s). «Beleg» = Stelle, auf die sich die Evidence stützt. Nach dem Anhören "
             "Name und Confidence oben in der Tabelle setzen. Geschrieben von grounding.py, ohne Modell._", ""]
    any_label = False
    for r in label_rows:
        name, conf = (r.get("Name") or "").strip(), (r.get("Confidence") or "").strip().lower()
        if name and not name.endswith("(?)") and conf == "high":
            continue
        label = r.get("Label", "")
        own = [s for s in sents if s["label"] == label and len(s["text"].split()) >= 4]
        if not own:
            continue
        any_label = True
        picked: list[tuple[dict, str]] = []
        for ref in re.findall(r"\[(\d{1,2}:\d{2}(?::\d{2})?)\]", r.get("Evidence") or ""):
            t = ts_seconds(ref)
            hit = next((s for s in own if t - 3 <= s["t"] <= t + 30), None)
            if hit and all(hit is not x for x, _ in picked):
                picked.append((hit, "Beleg"))
            if len(picked) >= per_label:
                break
        if len(picked) < per_label:
            span = (own[0]["t"], own[-1]["t"] + 1)
            width = (span[1] - span[0]) / per_label
            for k in range(per_label):
                bucket = [s for s in own if span[0] + k * width <= s["t"] < span[0] + (k + 1) * width
                          and all(s is not x for x, _ in picked)]
                if bucket and len(picked) < per_label:
                    # most distinct words: long enough to recognise the voice, not a decoder loop
                    picked.append((max(bucket, key=lambda s: len(set(_norm(s["text"]).split()))), ""))
        head = f"### {label}" + (f" · Vorschlag «{name}»" if name else " · unbenannt") + (f", {conf}" if conf else "")
        lines += [head, ""]
        for s, why in sorted(picked, key=lambda x: x[0]["t"]):
            turn = f" (Satz laut Diarisierung: {s['turn']})" if s.get("turn") and s["turn"] != label else ""
            lines.append(f"- `[{fmt_ts(s['t'])}]` «{_clip(s['text'])}»" + (f" – {why}" if why else "") + turn)
        lines.append("")
    return lines if any_label else []


def _replace_section(text: str, heading: str, new_lines: list[str]) -> str:
    """Replace the section `heading` (up to the next `## `) with new_lines; append when missing."""
    m = re.search(rf"^{re.escape(heading)}\s*$", text, re.M)
    block = "\n".join(new_lines).rstrip("\n")
    if not m:
        return text if not new_lines else text.rstrip("\n") + "\n\n" + block + "\n"
    nxt = re.search(r"^## ", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    tail = text[end:]
    head = text[:m.start()].rstrip("\n")
    return head + ("\n\n" + block if new_lines else "") + ("\n\n" + tail if tail else "\n")


def _replace_open_table(text: str, rows: list[dict]) -> str:
    m = re.search(rf"^{re.escape(OPEN_HEADING)}\s*$", text, re.M)
    if not m:
        return text
    nxt = re.search(r"^## ", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    section = text[m.end():end].split("\n")
    idx = [i for i, l in enumerate(section) if l.lstrip().startswith("|")]
    if not idx:
        return text
    cols = ["Zeit", "Wortmeldung", "Label", "Kandidaten", "Gewicht"]
    table = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    table += ["| " + " | ".join(str(r.get(c, "") or "") for c in cols) + " |" for r in rows]
    section[idx[0]:idx[-1] + 1] = table if rows else [ALL_ANSWERED]
    return text[:m.end()] + "\n".join(section) + text[end:]


def _answered(rows: list[dict], overrides: dict[str, str], starts: list[str]) -> tuple[list[dict], dict[str, str]]:
    """(rows still open, override block -> quote of the answered row)."""
    done = {block_of(ts, starts) for ts in overrides}
    still, quotes = [], {}
    for r in rows:
        zeit = (r.get("Zeit") or "").strip("`[] ")
        blk = block_of(zeit, starts) if TS_CELL.fullmatch(zeit) else None
        if blk in done:
            quotes.setdefault(blk, re.sub(rf"\s*\({NOT_FOUND}\)\s*$", "", r.get("Wortmeldung") or ""))
        else:
            still.append(r)
    return still, quotes


def _fill_override_quotes(text: str, quotes: dict[str, str], starts: list[str]) -> str:
    """Put the quote of an answered row into its override's empty Wortmeldung cell."""
    out, in_section = [], False
    for line in text.split("\n"):
        if line.startswith("## "):
            in_section = line[3:].strip().lower().startswith("overrides")
        if in_section and line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            ts = cells[0].strip("`[] ")
            quote = quotes.get(block_of(ts, starts)) if TS_CELL.fullmatch(ts) else None
            if quote and len(cells) >= 2 and cells[1] and (len(cells) < 3 or not cells[2]):
                line = "| " + " | ".join([cells[0], cells[1], quote] + cells[3:]) + " |"
        out.append(line)
    return "\n".join(out)


def ground_file(p: Paths) -> bool:
    """Rewrite speakers.md with grounded open rows and the Hörproben section. True when it changed."""
    if not p.speakers.is_file() or not p.transcript.is_file():
        return False
    text = p.speakers.read_text(encoding="utf-8")
    sp = read_speakers(p.speakers)
    sents = sentences(p)
    if not sents:
        return False
    new = text
    if sp["open"]:
        starts = [b.ts for b in read_transcript(p.transcript)]
        rows, quotes = _answered(ground_open_rows(sp["open"], sents), parse_overrides(p.speakers), starts)
        new = _fill_override_quotes(_replace_open_table(text, rows), quotes, starts)
    new = _replace_section(new, SAMPLES_HEADING, samples(sp["labels"], sents))
    if new != text:
        p.speakers.write_text(new, encoding="utf-8")
        return True
    return False


def main() -> int:
    ap = cli.parser(__doc__, exit_codes={0: "done (or nothing to ground)", 2: "no speakers.md or transcript"},
                    examples=['python grounding.py "<base>"'])
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    args = cli.parse(ap)
    p = Paths(resolve_base(args.base))
    if not p.speakers.is_file() or not p.transcript.is_file():
        print(f"[grounding] needs {p.speakers.name} and {p.transcript.name}", file=sys.stderr)
        return 2
    changed = ground_file(p)
    print(f"[grounding] {'updated' if changed else 'unchanged'}: {p.speakers}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
