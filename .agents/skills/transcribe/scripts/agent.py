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
  6. review      review.py -> <base>.review.md: one box per artefact, the
                 gate publish.py checks

Human-in-the-loop stays a gate, not a chat: speaker attributions the model
could not settle and the report itself are listed in <base>.review.md. With
--stop-at-speakers the run ends after step 2 so a person can correct
speakers.md first; the next agent.py call continues where it stopped
(every stage is idempotent and skips finished work).

A hand correction in speakers.md needs nothing but another plain call: the
speaker stage keeps every name you wrote, asks the model only about labels
still empty and applies the names to transcript and vtt, and kompakt and report are rebuilt because they no
longer match the transcript - <base>.agent.json records the transcript hash
each was built from. A second call changes nothing.

--force redoes frames, kompakt, illustrate and report but never touches the
names in speakers.md; --refill-speakers lets the model overwrite them.

  python agent.py "<base or recording>" [--language de] [--force]
         [--refill-speakers] [--only speakers,kompakt,...]
         [--stop-at-speakers] [--no-frames]

Exit codes: 0 done, 3 LLM not configured, 4 stopped at a human gate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

import cli
import llm
from companions import Paths, input_status, read_json, read_protocol, resolve_base

HERE = Path(__file__).resolve().parent
STAGES = ("frames", "speakers", "kompakt", "illustrate", "report")


def step(name: str, script: str, base: Path, extra: list[str]) -> int:
    print(f"[agent] -- {name}", file=sys.stderr, flush=True)
    r = subprocess.run([sys.executable, "-X", "utf8", str(HERE / script), str(base), *extra])
    if r.returncode not in (0,):
        print(f"[agent] {name} exited {r.returncode}", file=sys.stderr)
    return r.returncode


def transcript_hash(p: Paths) -> str:
    return hashlib.sha256(p.transcript.read_bytes()).hexdigest()[:12]


def state_path(p: Paths) -> Path:
    return p.base.with_name(p.base.name + ".agent.json")


def outdated(p: Paths, state: dict, stage: str, artefact: Path) -> bool:
    """True when `artefact` exists but was built from another transcript (new
    names, overrides, corrections). Without a record - runs from before this
    file existed - a transcript newer than the artefact counts as outdated."""
    if not artefact.is_file():
        return False
    if stage in state:
        return state[stage] != transcript_hash(p)
    return p.transcript.stat().st_mtime > artefact.stat().st_mtime + 1


def record(p: Paths, state: dict, stage: str, artefact: Path) -> None:
    if artefact.is_file() and state.get(stage) != transcript_hash(p):
        state[stage] = transcript_hash(p)
        state_path(p).write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def write_review(p: Paths) -> Path:
    """The human gate (review.py): one box per artefact, kept ticked while it is unchanged."""
    import review
    path, reset = review.refresh(p, review._current_target(p))
    for key in reset:
        print(f"[agent] review: {key} changed since it was ticked - box reset", file=sys.stderr)
    return path


def main() -> int:
    ap = cli.parser(__doc__, examples=[
        'python agent.py "<base or recording>" --language de',
        'python agent.py "<base or recording>" --stop-at-speakers',
        'python agent.py "<base or recording>"   # after correcting speakers.md',
        'python agent.py "<base or recording>" --only kompakt,report --force'])
    ap.add_argument("base", help="<base> stem, the recording, or any companion file")
    ap.add_argument("--language", default=None, help="Output language, e.g. de")
    ap.add_argument("--force", action="store_true",
                    help="Redo stages that already have output (speaker names stay as they are)")
    ap.add_argument("--refill-speakers", action="store_true",
                    help="Let the model overwrite the names already in speakers.md")
    ap.add_argument("--only", default=None, help=f"Comma-separated subset of {','.join(STAGES)}")
    ap.add_argument("--stop-at-speakers", action="store_true",
                    help="End after the speaker stage so a person can correct speakers.md")
    ap.add_argument("--no-frames", action="store_true", help="Skip every vision call")
    ap.add_argument("--redact", dest="redact", action="store_true", default=None,
                    help="Black out person-name lists in the illustration crops; on finished crops only "
                         "the redaction is added (default: TRANSCRIBE_REDACT, else unchanged, else off)")
    ap.add_argument("--no-redact", dest="redact", action="store_false", help="Remove or skip redaction")
    args = cli.parse(ap)

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
        step("speakers", "speakers_fill.py", p.base,
             lang + (["--force"] if args.refill_speakers else []) + ["--apply"])
        if args.stop_at_speakers:
            print(f"[agent] stopped at the speaker gate: {write_review(p)}", file=sys.stderr)
            return 4
    state = read_json(state_path(p)) or {}
    if "kompakt" in only:
        redo = outdated(p, state, "kompakt", p.kompakt)
        if redo and not args.force:
            print("[agent] transcript changed since the compact transcript was built - rebuilding", file=sys.stderr)
        if step("kompakt", "kompakt.py", p.base, lang + (["--force"] if args.force or redo else [])) == 0:
            record(p, state, "kompakt", p.kompakt)
    if "illustrate" in only and has_video and not args.no_frames:
        step("illustrate", "illustrate_agent.py", p.base, lang + force + ({True: ["--redact"], False: ["--no-redact"]}.get(args.redact, [])))
    if "report" in only:
        redo = outdated(p, state, "report", p.report)
        if redo and not args.force:
            print("[agent] transcript changed since the report was written - rewriting", file=sys.stderr)
        # the frames stage above already re-described the frames on --force
        if step("report", "report.py", p.base, lang + (["--rewrite"] if args.force or redo else [])
                + (["--no-frames"] if args.no_frames else [])) == 0:
            record(p, state, "report", p.report)
    review = write_review(p)
    print(f"[agent] done - human review: {review}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
