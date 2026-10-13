#!/usr/bin/env python3
"""One command for the whole headless pipeline: check -> run.py -> agent.py.

  python pipeline.py "<recording or URL>" [--language de] [--local]
         [--stop-at-speakers] [--redact] [--no-frames] [--force] [--rerun]
         [any run.py option, e.g. --start 0 --end 5:00]

1. setup.py --check    tools and a transcription path are ready
2. llm.py              the chat deployment for the agent stages is configured
3. run.py              local stages: frames, OCR, Whisper, diarization
                       and which participants / glossary files it found
                       (for a local file skipped when <base>.transcript.md
                       exists, unless --rerun)
4. agent.py            speakers, compact transcript, illustrations, report,
                       review.md - each stage skips finished work

--local pins the local backends (whisper-local, pyannote-local), so no audio
leaves the machine even when cloud keys are configured. Options this script
does not know are passed on to run.py. Re-running is safe: finished stages
are skipped, so after correcting speakers.md the same command continues.
A URL is downloaded by run.py on every call; for re-runs pass the
downloaded file or the <base> path printed at the end.

Exit codes: 0 done, 1 run.py failed, 2 setup incomplete, 3 chat deployment
not configured (run.py output is there for the interactive path), 4 stopped
at a human gate (--stop-at-speakers).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

import cli
import llm
from companions import Paths, resolve_base
from download import is_url

HERE = Path(__file__).resolve().parent
PROTOCOL_RE = re.compile(r"^- \*\*Protocol file:\*\* `(.+?)`\s*$", re.M)


def call(script: str, *args: str, capture: bool = False) -> subprocess.CompletedProcess:
    print(f"[pipeline] -- {script} {' '.join(args)}", file=sys.stderr, flush=True)
    return subprocess.run([sys.executable, "-X", "utf8", str(HERE / script), *args],
                          stdout=subprocess.PIPE if capture else None,
                          text=capture, encoding="utf-8" if capture else None, errors="replace" if capture else None)


def main() -> int:
    ap = cli.parser(__doc__, examples=[
        'python pipeline.py "20261013-1100 - Thema.mp4" --language de --local',
        'python pipeline.py "20261013-1100 - Thema.mp4" --language de --local --stop-at-speakers',
        'python pipeline.py "20261013-1100 - Thema.mp4" --redact   # add redaction to a finished run',
        'python pipeline.py "https://youtu.be/..." --language en --start 0 --end 5:00'])
    ap.add_argument("source", help="Local video or audio file, or a URL")
    ap.add_argument("--language", default=None, help="Language of transcript and report, e.g. de")
    ap.add_argument("--local", action="store_true",
                    help="Pin whisper-local and pyannote-local (no cloud transcription or diarization)")
    ap.add_argument("--rerun", action="store_true", help="Run run.py again although a transcript exists")
    ap.add_argument("--stop-at-speakers", action="store_true",
                    help="End after the speaker stage so a person can correct speakers.md")
    ap.add_argument("--redact", dest="redact", action="store_true", default=None,
                    help="Black out person-name lists in the crops; on a finished run only the redaction "
                         "is added (default: TRANSCRIBE_REDACT, else the state of the existing crops, else off)")
    ap.add_argument("--no-redact", dest="redact", action="store_false", help="Remove or skip redaction")
    ap.add_argument("--no-frames", action="store_true", help="Skip every image call in the agent stages")
    ap.add_argument("--force", action="store_true", help="Redo finished agent stages")
    args, run_extra = cli.parse_known(ap)

    url = is_url(args.source)
    p = None
    if not url:
        rec = Path(args.source).expanduser().resolve()
        p = Paths(resolve_base(rec))
        if not rec.is_file() and not p.transcript.is_file():  # a <base> of an earlier run is fine too
            ap.error(f"not a local file, an earlier run's <base> or a URL: {rec}")
    lang = ["--language", args.language] if args.language else []

    if call("setup.py", "--check").returncode != 0:
        print("[pipeline] setup incomplete - run setup.py (or setup.py --venv) and try again", file=sys.stderr)
        return 2
    ok, reason = llm.available()
    if not ok:
        print(f"[pipeline] chat deployment not configured ({reason}) - agent stages will be skipped",
              file=sys.stderr)
    if p and p.transcript.is_file() and not args.rerun:
        print(f"[pipeline] transcript exists - skip run.py (use --rerun): {p.transcript.name}", file=sys.stderr)
    else:
        local = ["--whisper", "whisper-local", "--diarize", "pyannote-local"] if args.local else []
        src = args.source if url else str(rec)
        # run.py prints the protocol to stdout; it is saved next to the recording,
        # so it is captured here only to learn where a URL source landed.
        r = call("run.py", src, *lang, *local, *run_extra, capture=True)
        if r.returncode != 0:
            print("[pipeline] run.py failed", file=sys.stderr)
            return 1
        m = PROTOCOL_RE.search(r.stdout or "")
        if p is None:
            if not m:
                print("[pipeline] run.py did not report a protocol file - cannot continue", file=sys.stderr)
                return 1
            p = Paths(resolve_base(Path(m.group(1))))
        print(f"[pipeline] local stages done: {p.protocol}", file=sys.stderr)
    if not ok:
        print(f"[pipeline] configure AZURE_LLM_* in ~/.config/transcribe/.env or let the chat agent do the rest "
              f"from {p.protocol}", file=sys.stderr)
        return 3

    agent = [*lang]
    for flag in ("stop_at_speakers", "no_frames", "force"):
        if getattr(args, flag):
            agent.append("--" + flag.replace("_", "-"))
    if args.redact is not None:
        agent.append("--redact" if args.redact else "--no-redact")
    rc = call("agent.py", str(p.base), *agent).returncode
    if rc == 0:
        print(f"[pipeline] done. Report: {p.report}\n[pipeline] Review list: "
              f"{p.base.with_name(p.base.name + '.review.md')}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
