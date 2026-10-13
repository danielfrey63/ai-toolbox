#!/usr/bin/env python3
"""Headless orchestrator: everything after run.py, without a chat assistant.

Runs the agent stages on the configured cloud model (llm.py) in the order
the interactive skill does them, so /transcribe works the same under
GitHub Copilot, Codex, a cron job or a plain terminal:

  1. frames      vision pass over the frames  -> <base>.frames.json
  2. speakers    speakers_fill.py             -> <base>.speakers.md
                 then speakers.py --apply     -> names in transcript + vtt
  3. kompakt     kompakt.py                   -> <base>.transcript-kompakt.md
  4. illustrate  illustrate_agent.py          -> <base>.illustrations/
  5. report      report.py                    -> <base>.md
  6. review      writes <base>.review.md: the human gates

Human-in-the-loop stays a gate, not a chat: speaker attributions the model
could not settle and the report itself are listed in <base>.review.md. With
--stop-at-speakers the run ends after step 2 so a person can correct
speakers.md first; the next agent.py call continues where it stopped
(every stage is idempotent and skips finished work).

  python agent.py "<base or recording>" [--language de] [--force]
         [--only speakers,kompakt,...] [--stop-at-speakers] [--no-frames]

Exit codes: 0 done, 3 LLM not configured, 4 stopped at a human gate.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import subprocess
import sys
from pathlib import Path

import llm
from companions import Paths, input_status, read_protocol, read_speakers, resolve_base
from version import APP_VERSION

HERE = Path(__file__).resolve().parent
STAGES = ("frames", "speakers", "kompakt", "illustrate", "report")


def step(name: str, script: str, base: Path, extra: list[str]) -> int:
    print(f"[agent] -- {name}", file=sys.stderr, flush=True)
    r = subprocess.run([sys.executable, "-X", "utf8", str(HERE / script), str(base), *extra])
    if r.returncode not in (0,):
        print(f"[agent] {name} exited {r.returncode}", file=sys.stderr)
    return r.returncode


def write_review(p: Paths) -> Path:
    sp = read_speakers(p.speakers)
    unnamed = [r for r in sp["labels"] if not r.get("Name") or r.get("Name", "").endswith("(?)")]
    out = p.base.with_name(p.base.name + ".review.md")
    lines = [
        f"# Review: {p.base.name}",
        "",
        f"_Written by agent.py (transcribe {APP_VERSION}) on {_dt.date.today().isoformat()} with "
        f"{llm.load_config().describe()}. Close the points below, then re-run "
        f"`agent.py --only speakers,kompakt,report --force` if names changed._",
        "",
        "## 1. Sprecher",
        "",
    ]
    if not sp["labels"]:
        lines.append("- Nicht diarisiert, nichts zu prüfen.")
    else:
        lines.append(f"- {len(sp['labels']) - len(unnamed)} von {len(sp['labels'])} Labels benannt. "
                     f"Prüfen und korrigieren in `{p.speakers.name}`.")
        for r in unnamed:
            lines.append(f"- Offen: {r.get('Label')} ({r.get('Talk time')}) {r.get('Name') or ''}")
        if sp["open"]:
            lines.append(f"- {len(sp['open'])} Wortmeldungen unter fremdem Label: Tabelle «Open attributions» "
                         f"in `{p.speakers.name}`.")
    lines += ["", "## 2. Illustrationen", "",
              f"- Ausschnitte in `{p.illustrations.name}/` ansehen; Korrekturen in `{p.spec.name}`, dann "
              f"`illustrate.py --spec … --out-dir …` erneut."]
    lines += ["", "## 3. Bericht", "",
              f"- `{p.report.name}`: Kernaussagen, Entscheide, Namen und Zahlen gegen die Aufnahme prüfen.",
              "- Erst nach diesem Review veröffentlichen (Confluence, Ticket, PMO)."]
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", help="<base> stem, the recording, or any companion file")
    ap.add_argument("--language", default=None, help="Output language, e.g. de")
    ap.add_argument("--force", action="store_true", help="Redo stages that already have output")
    ap.add_argument("--only", default=None, help=f"Comma-separated subset of {','.join(STAGES)}")
    ap.add_argument("--stop-at-speakers", action="store_true",
                    help="End after the speaker stage so a person can correct speakers.md")
    ap.add_argument("--no-frames", action="store_true", help="Skip every vision call")
    ap.add_argument("--redact", action="store_true",
                    help="Black out person-name lists in the illustration crops (default off; "
                         "TRANSCRIBE_REDACT=1 in .env makes it the default)")
    args = ap.parse_args()

    p = Paths(resolve_base(args.base))
    if not p.transcript.is_file():
        print(f"[agent] no transcript {p.transcript} - run run.py first", file=sys.stderr)
        return 2
    ok, reason = llm.available()
    if not ok:
        print(f"[agent] LLM not configured ({reason}). Set AZURE_LLM_ENDPOINT/_KEY in "
              f"~/.config/transcribe/.env or let the chat assistant do these steps.", file=sys.stderr)
        return 3
    only = set((args.only or ",".join(STAGES)).split(","))
    unknown = only - set(STAGES)
    if unknown:
        ap.error(f"unknown stage(s): {', '.join(sorted(unknown))}")
    lang = ["--language", args.language] if args.language else []
    force = ["--force"] if args.force else []
    has_video = bool(read_protocol(p.protocol).get("frames"))
    print(f"[agent] {p.base.name} | {llm.load_config().describe()}", file=sys.stderr)
    for line in input_status(p.base):
        print(f"[agent] {line}", file=sys.stderr)

    if "frames" in only and has_video and not args.no_frames:
        import report
        report.frame_pass(p, read_protocol(p.protocol), 48, args.language, args.force)
    if "speakers" in only and p.speakers.is_file():
        step("speakers", "speakers_fill.py", p.base, lang + force + ["--apply"])
        if args.stop_at_speakers:
            print(f"[agent] stopped at the speaker gate: {write_review(p)}", file=sys.stderr)
            return 4
    if "kompakt" in only:
        step("kompakt", "kompakt.py", p.base, lang + force)
    if "illustrate" in only and has_video and not args.no_frames:
        step("illustrate", "illustrate_agent.py", p.base, lang + force + (["--redact"] if args.redact else []))
    if "report" in only:
        step("report", "report.py", p.base, lang + force + (["--no-frames"] if args.no_frames else []))
    review = write_review(p)
    print(f"[agent] done - human review: {review}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
