#!/usr/bin/env python3
"""Human review gate: <base>.review.md with one checkbox per reviewed artefact.

Each checkbox carries the hash of the artefact it releases, hidden in an
HTML comment:

  - [x] Bericht geprüft: ... <!-- report:3f9a1c2b -->

A box ticked by a person stays ticked as long as its artefact is unchanged.
When the artefact changes (report re-written, crops re-rendered, speakers.md
edited, publish target changed) the box is reset on the next refresh and
the gate is closed again. publish.py refuses to upload while a box is open.

Items (only those that apply to the recording):
  speakers       speakers.md: names and open contributions checked
  illustrations  crops and captions looked at; redaction state stated
  kompakt        compact transcript spot-checked
  report         key statements, decisions, names and numbers checked
  release        publication released for the stated target

  python review.py "<base or any companion>"            refresh the file
  python review.py "<base or any companion>" --check    gate status only
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import re
import sys
from pathlib import Path

import cli
from companions import Paths, read_json, read_speakers, resolve_base
from version import APP_VERSION

BOX_RE = re.compile(r"^- \[( |x|X)\] .*<!-- (\w+):([0-9a-f]{8}) -->\s*$", re.M)


def review_path(p: Paths) -> Path:
    return p.base.with_name(p.base.name + ".review.md")


def _hash(*parts: str | bytes | Path | None) -> str:
    h = hashlib.sha256()
    for part in parts:
        if isinstance(part, Path):
            data = part.read_bytes() if part.is_file() else b""
        elif isinstance(part, str):
            data = part.encode("utf-8")
        else:
            data = part or b""
        h.update(data + b"\0")
    return h.hexdigest()[:8]


def redaction_summary(p: Paths) -> tuple[int, int]:
    """(crops with redaction boxes, crops) from the illustration spec."""
    spec = read_json(p.spec)
    if not isinstance(spec, list):
        return 0, 0
    return sum(1 for e in spec if e.get("redact")), len(spec)


def items(p: Paths, target: str | None) -> list[tuple[str, str, str, list[str]]]:
    """(key, text, hash, detail lines) per checkbox, in display order. Details are
    hints for the reviewer and do not take part in the hash."""
    out: list[tuple[str, str, str, list[str]]] = []
    sp = read_speakers(p.speakers) if p.speakers.is_file() else {"labels": [], "open": []}
    if sp["labels"]:
        named = [r for r in sp["labels"] if r.get("Name") and not r["Name"].endswith("(?)")]
        text = (f"Sprecher geprüft in `{p.speakers.name}`: {len(named)} von {len(sp['labels'])} Labels sicher "
                f"benannt" + (f", {len(sp['open'])} Wortmeldungen unter fremdem Label geklärt oder bewusst offen"
                              if sp["open"] else ""))
        details = [f"{r.get('Label')} ({r.get('Talk time')}): {r.get('Name') or 'unbenannt'}"
                   for r in sp["labels"] if r not in named]
        if details:
            details.append("Nach Korrekturen: `agent.py <base> --only speakers,kompakt,report --force`")
        out.append(("speakers", text, _hash(p.speakers), details))
    if p.spec.is_file():
        k, n = redaction_summary(p)
        red = f"Schwärzung in {k} von {n} Bildern" if k else "keine Schwärzung"
        text = (f"Illustrationen in `{p.illustrations.name}/` angesehen: {n} Ausschnitte, Bildunterschriften "
                f"stimmen, {red} passt zum Empfängerkreis")
        out.append(("illustrations", text, _hash(p.spec, p.manifest),
                    ["Schwärzung ändern: `pipeline.py <base> --redact` bzw. `--no-redact`",
                     f"Ausschnitt oder Bildunterschrift ändern: `{p.spec.name}` bearbeiten, dann "
                     f"`illustrate.py --video <aufnahme> --spec … --out-dir …`"]))
    if p.kompakt.is_file():
        out.append(("kompakt", f"Kompaktfassung `{p.kompakt.name}` stichprobenweise gegen das Transkript geprüft",
                    _hash(p.kompakt), []))
    if p.report.is_file():
        out.append(("report", f"Bericht `{p.report.name}` geprüft: Kernaussagen, Entscheide, Namen und Zahlen "
                              f"gegen die Aufnahme", _hash(p.report), []))
    if target:
        out.append(("release", f"Publikation freigegeben: {target}",
                    _hash(target, *[h for _, _, h, _ in out]), []))
    else:
        out.append(("release", "Publikation freigegeben: Ziel noch nicht festgelegt",
                    _hash("no target"), ["Ziel festlegen: `parent:` in `transcribe-publish.txt` bzw. "
                                         "`<name>.publish.txt` oder `publish.py <base> --parent ID`"]))
    return out


def refresh(p: Paths, target: str | None = None, note: str = "") -> tuple[Path, list[str]]:
    """Write <base>.review.md, keeping every tick whose artefact hash is unchanged.
    Returns the path and the keys whose tick was reset because the artefact changed."""
    path = review_path(p)
    old = path.read_text(encoding="utf-8") if path.is_file() else ""
    ticked = {m.group(2): (m.group(1).lower() == "x", m.group(3)) for m in BOX_RE.finditer(old)}
    reset: list[str] = []
    lines = [f"# Review: {p.base.name}", "",
             f"_Freigabe-Gate, geschrieben von transcribe {APP_VERSION} am {_dt.date.today().isoformat()}. "
             f"Jede Box gibt ein Artefakt frei: ankreuzen (`[x]`), wenn geprüft. Ändert sich das Artefakt danach, "
             f"setzt der nächste Lauf die Box zurück. `publish.py` lädt erst hoch, wenn alle Boxen angekreuzt "
             f"sind.{(' ' + note) if note else ''}_", ""]
    for key, text, h, details in items(p, target):
        was, old_h = ticked.get(key, (False, ""))
        keep = was and old_h == h
        if was and not keep:
            reset.append(key)
        lines.append(f"- [{'x' if keep else ' '}] {text} <!-- {key}:{h} -->")
        lines += [f"  - {d}" for d in details]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path, reset


def gate(p: Paths, target: str | None = None) -> tuple[bool, list[str]]:
    """(open?, list of open item texts) after a refresh."""
    path, _ = refresh(p, target)
    text = path.read_text(encoding="utf-8")
    open_items = [re.sub(r"\s*<!--.*-->\s*$", "", m.group(0))[6:] for m in BOX_RE.finditer(text)
                  if m.group(1) == " "]
    return bool(open_items), open_items


def main() -> int:
    ap = cli.parser(__doc__, exit_codes={0: "file refreshed / gate closed (all boxes ticked)",
                                         5: "--check: boxes still open"},
                    examples=['python review.py "<base>"', 'python review.py "<base>" --check'])
    ap.add_argument("base", help="<base> stem or any companion file of the recording")
    ap.add_argument("--check", action="store_true", help="Only report whether every box is ticked")
    args = cli.parse(ap)
    p = Paths(resolve_base(args.base))
    path, reset = refresh(p, _current_target(p))
    for key in reset:
        print(f"[review] {key}: artefact changed since it was ticked - box reset", file=sys.stderr)
    if args.check:
        is_open, open_items = gate(p, _current_target(p))
        for t in open_items:
            print(f"[review] open: {t}", file=sys.stderr)
        print(f"[review] gate {'OPEN' if is_open else 'closed'}: {path}", file=sys.stderr)
        return 5 if is_open else 0
    print(f"[review] {path}", file=sys.stderr)
    return 0


def _current_target(p: Paths) -> str | None:
    """Publish target as publish.py describes it, when a publish config exists."""
    try:
        import publish
    except ImportError:
        return None
    cfg = publish.load_config(p, None)
    return publish.describe_target(p, cfg) if cfg.get("parent") else None


if __name__ == "__main__":
    raise SystemExit(main())
