#!/usr/bin/env python3
"""Readers for the companion files a run.py pass leaves next to a recording.

The agent stages (speakers_fill, kompakt, report, illustrate_spec, agent)
all start from `<base>` - the report stem without extension - and need the
same handful of parsers: transcript blocks, protocol metadata, the speakers
table, the links list. They live here once.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

BLOCK_RE = re.compile(r"^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s+(?:\[([^\]]+)\]\s+)?(.*)$")
META_RE = re.compile(r"^- \*\*(.+?):\*\*\s*(.*)$")
FRAME_RE = re.compile(r"^- `(.+?)` \(t=(\d{1,2}:\d{2}(?::\d{2})?)\) \[(REG|CUT)\]")


def resolve_base(arg: str | Path) -> Path:
    """`<base>` from any companion path or the bare stem. Strips the known
    suffixes so `x.transcript.md`, `x.md`, `x.mp4` and `x` all map to `x`."""
    p = Path(arg).expanduser()
    name = p.name
    for suffix in (".transcript-kompakt.md", ".transcript.md", ".protocol.md", ".speakers.md",
                   ".links.md", ".crosscheck.md", ".analysis.json", ".frames.json",
                   ".illustrations.spec.json", ".segments.json", ".turns.json", ".ocr.json",
                   ".original.vtt", ".vtt", ".md", ".mp4", ".mkv", ".mov", ".webm", ".m4a", ".mp3",
                   ".wav"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    return p.with_name(name)


@dataclass
class Paths:
    base: Path

    def _p(self, suffix: str) -> Path:
        return self.base.with_name(self.base.name + suffix)

    @property
    def report(self) -> Path: return self._p(".md")
    @property
    def protocol(self) -> Path: return self._p(".protocol.md")
    @property
    def transcript(self) -> Path: return self._p(".transcript.md")
    @property
    def kompakt(self) -> Path: return self._p(".transcript-kompakt.md")
    @property
    def speakers(self) -> Path: return self._p(".speakers.md")
    @property
    def links(self) -> Path: return self._p(".links.md")
    @property
    def crosscheck(self) -> Path: return self._p(".crosscheck.md")
    @property
    def ocr(self) -> Path: return self._p(".ocr.json")
    @property
    def analysis(self) -> Path: return self._p(".analysis.json")
    @property
    def frames_json(self) -> Path: return self._p(".frames.json")
    @property
    def spec(self) -> Path: return self._p(".illustrations.spec.json")
    @property
    def illustrations(self) -> Path: return self._p(".illustrations")
    @property
    def manifest(self) -> Path: return self.illustrations / "manifest.json"
    @property
    def glossary(self) -> Path: return self.base.parent / "transcribe-glossary.txt"
    @property
    def participants_file(self) -> Path: return self.base.parent / "transcribe-participants.txt"


def ts_seconds(ts: str) -> float:
    parts = [int(x) for x in ts.split(":")]
    return parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 else parts[0] * 60 + parts[1]


def fmt_ts(seconds: float) -> str:
    s = int(round(seconds))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


@dataclass
class Block:
    ts: str
    label: str
    text: str

    @property
    def seconds(self) -> float:
        return ts_seconds(self.ts)

    def line(self) -> str:
        return f"[{self.ts}] [{self.label}] {self.text}" if self.label else f"[{self.ts}] {self.text}"


def read_transcript(path: Path) -> list[Block]:
    """Blocks of a transcript.md (inside or outside the code fence)."""
    blocks: list[Block] = []
    if not path.is_file():
        return blocks
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = BLOCK_RE.match(raw.strip())
        if m:
            blocks.append(Block(m.group(1), m.group(2) or "", m.group(3).strip()))
    return blocks


def transcript_source(path: Path) -> str:
    """The `_Source: ..._` line of a transcript.md, without the underscores."""
    if not path.is_file():
        return ""
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.strip()
        if s.startswith("_Source:"):
            return s.strip("_").removeprefix("Source:").strip().rstrip(".")
    return ""


def read_protocol(path: Path) -> dict:
    """Header metadata of protocol.md as {key: value} plus `frames`:
    [{path, ts, kind}] and `resources`: the raw text after `## Resources`."""
    out: dict = {"frames": [], "resources": ""}
    if not path.is_file():
        return out
    text = path.read_text(encoding="utf-8", errors="replace")
    for raw in text.splitlines():
        m = META_RE.match(raw.strip())
        if m:
            out.setdefault(m.group(1), m.group(2))
        f = FRAME_RE.match(raw.strip())
        if f:
            out["frames"].append({"path": f.group(1), "ts": f.group(2), "kind": f.group(3)})
    if "## Resources" in text:
        out["resources"] = text.split("## Resources", 1)[1].split("\n---", 1)[0].strip()
    return out


def read_table(lines: list[str], header_must_have: tuple[str, ...]) -> tuple[list[str], list[dict], int, int]:
    """First markdown table whose header holds all `header_must_have` cells.
    Returns (columns, rows, first_line_index, last_line_index_exclusive)."""
    cols: list[str] | None = None
    rows: list[dict] = []
    start = end = -1
    for i, raw in enumerate(lines):
        line = raw.strip()
        if cols is None:
            if line.startswith("|"):
                cells = [c.strip() for c in line.strip("|").split("|")]
                if all(h in cells for h in header_must_have):
                    cols, start = cells, i
            continue
        if not line.startswith("|"):
            end = i
            break
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(set(c) <= set("-: ") for c in cells):
            continue
        rows.append(dict(zip(cols, cells)))
    if cols is not None and end == -1:
        end = len(lines)
    return cols or [], rows, start, end


def read_speakers(path: Path) -> dict:
    """{labels: [row dicts], participants: [names], open: [row dicts], text: str}."""
    out: dict = {"labels": [], "participants": [], "open": [], "text": ""}
    if not path.is_file():
        return out
    text = path.read_text(encoding="utf-8", errors="replace")
    out["text"] = text
    lines = text.splitlines()
    _, out["labels"], _, _ = read_table(lines, ("Label", "Name"))
    _, prow, _, _ = read_table(lines, ("Name", "Source"))
    out["participants"] = unique_people([r["Name"] for r in prow if r.get("Name")])
    _, out["open"], _, _ = read_table(lines, ("Zeit", "Wortmeldung", "Kandidaten"))
    return out


def unique_people(names: list[str]) -> list[str]:
    """Collapse «Berger Thomas» / «Thomas Berger - BA DfA-Betrieb» into one
    entry (the longest, i.e. the one carrying the role), keyed by the set of
    name tokens before any « - role» suffix."""
    best: dict[frozenset, str] = {}
    order: list[frozenset] = []
    for n in names:
        core = n.split(" - ", 1)[0]
        key = frozenset(t.lower() for t in re.findall(r"[^\W\d_]+", core))
        if not key:
            continue
        if key not in best:
            order.append(key)
            best[key] = n
        elif len(n) > len(best[key]):
            best[key] = n
    return [best[k] for k in order]


def references_from_links(path: Path) -> list[str]:
    """Ticket keys and wiki page titles from links.md that are not marked
    (?) - canonical spellings the agent stages may use to fix a misheard
    «Story 163» into DFABETRIEB-1763."""
    out: list[str] = []
    if not path.is_file():
        return out
    section = ""
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("## "):
            section = raw[3:].strip().lower()
            continue
        if not raw.startswith("| [") or "(?)" in raw:
            continue
        cells = [c.strip() for c in raw.strip("|").split("|")]
        if len(cells) < 2:
            continue
        ref = cells[1].strip("`<> ")
        if section.startswith("ticket"):
            out.append(ref)
        elif section.startswith("wiki"):
            out.append(ref)
    return list(dict.fromkeys(out))


def screen_context(path: Path) -> list[str]:
    """«[MM:SS] host» lines from links.md: which application was on screen
    when. A logo-only web app (Omada, Jira) is named by its host, so the
    vision stages can tell «omada.sbb.ch» from a generic «SBB-Portal»."""
    out: list[str] = []
    if not path.is_file():
        return out
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.startswith("| [") or "(?)" in raw:
            continue
        cells = [c.strip() for c in raw.strip("|").split("|")]
        if len(cells) < 2:
            continue
        ts = cells[0].split("]")[0] + "]"
        ref = cells[1].strip("`<> ")
        m = re.match(r"https?://([^/]+)", ref)
        host = m.group(1) if m else (ref if re.fullmatch(r"[\w.-]+\.[a-z]{2,}", ref) else "")
        if host and (ts, host) not in seen:
            seen.add((ts, host))
            out.append(f"{ts} {host}")
    return out


def read_glossary(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [l.strip() for l in path.read_text(encoding="utf-8", errors="replace").splitlines()
            if l.strip() and not l.startswith("#")]


def read_links_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def read_json(path: Path) -> dict | list | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_json(path: Path, obj) -> None:
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def language_rules(lang: str | None) -> str:
    """Writing rules for the prompts, keyed by the user's language."""
    if (lang or "").lower().startswith("de"):
        return ("Schreibe auf Deutsch (Schweiz): echte Umlaute, «ss» statt «ß», "
                "Halbgeviertstrich «–» statt «—», Anführungszeichen «…». "
                "Keine Floskeln, keine Superlative, sachlicher Ton.")
    return "Write in the language of the transcript. Plain, factual tone."
