#!/usr/bin/env python3
"""One command for the whole headless pipeline: check -> run.py -> agent.py.

  python pipeline.py "<recording>" [--language de] [--local]
         [--stop-at-speakers] [--redact] [--no-frames] [--force] [--rerun]
         [any run.py option, e.g. --start 0 --end 5:00]

1. setup.py --check    tools and a transcription path are ready
2. llm.py              the chat deployment for the agent stages is configured
3. run.py              local stages: frames, OCR, Whisper, diarization
                       (skipped when <base>.transcript.md exists, unless --rerun)
4. agent.py            speakers, compact transcript, illustrations, report,
                       review.md - each stage skips finished work

--local pins the local backends (whisper-local, pyannote-local), so no audio
leaves the machine even when cloud keys are configured. Options this script
does not know are passed on to run.py. Re-running is safe: finished stages
are skipped, so after correcting speakers.md the same command continues.

Exit codes: 0 done, 1 run.py failed, 2 setup incomplete, 3 chat deployment
not configured (run.py output is there for the interactive path), 4 stopped
at a human gate (--stop-at-speakers).
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import llm
from companions import Paths, resolve_base

HERE = Path(__file__).resolve().parent


def call(script: str, *args: str) -> int:
    print(f"[pipeline] -- {script} {' '.join(args)}", file=sys.stderr, flush=True)
    return subprocess.run([sys.executable, "-X", "utf8", str(HERE / script), *args]).returncode


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("recording", help="Local video or audio file")
    ap.add_argument("--language", default=None, help="Language of transcript and report, e.g. de")
    ap.add_argument("--local", action="store_true",
                    help="Pin whisper-local and pyannote-local (no cloud transcription or diarization)")
    ap.add_argument("--rerun", action="store_true", help="Run run.py again although a transcript exists")
    ap.add_argument("--stop-at-speakers", action="store_true",
                    help="End after the speaker stage so a person can correct speakers.md")
    ap.add_argument("--redact", action="store_true", help="Black out person-name lists in the crops")
    ap.add_argument("--no-frames", action="store_true", help="Skip every image call in the agent stages")
    ap.add_argument("--force", action="store_true", help="Redo finished agent stages")
    args, run_extra = ap.parse_known_args()

    rec = Path(args.recording).expanduser().resolve()
    if not rec.is_file():
        ap.error(f"not a local file: {rec}")
    p = Paths(resolve_base(rec))
    lang = ["--language", args.language] if args.language else []

    if call("setup.py", "--check") != 0:
        print("[pipeline] setup incomplete - run setup.py (or setup.py --venv) and try again", file=sys.stderr)
        return 2
    ok, reason = llm.available()
    if not ok:
        print(f"[pipeline] chat deployment not configured ({reason}) - agent stages will be skipped",
              file=sys.stderr)

    if p.transcript.is_file() and not args.rerun:
        print(f"[pipeline] transcript exists - skip run.py (use --rerun): {p.transcript.name}", file=sys.stderr)
    else:
        local = ["--whisper", "whisper-local", "--diarize", "pyannote-local"] if args.local else []
        if call("run.py", str(rec), *lang, *local, *run_extra) != 0:
            print("[pipeline] run.py failed", file=sys.stderr)
            return 1
    if not ok:
        print(f"[pipeline] local stages done: {p.protocol}. Configure AZURE_LLM_* in "
              f"~/.config/transcribe/.env or let the chat agent do the rest.", file=sys.stderr)
        return 3

    agent = [*lang]
    for flag in ("stop_at_speakers", "redact", "no_frames", "force"):
        if getattr(args, flag):
            agent.append("--" + flag.replace("_", "-"))
    rc = call("agent.py", str(p.base), *agent)
    if rc == 0:
        print(f"[pipeline] done. Report: {p.report}\n[pipeline] Review list: "
              f"{p.base.with_name(p.base.name + '.review.md')}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
