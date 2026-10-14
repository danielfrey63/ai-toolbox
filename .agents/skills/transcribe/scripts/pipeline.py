#!/usr/bin/env python3
"""Process or resume media, then analyse via a model or the calling harness.

Use --plan to explain reuse without running stages. --local pins audio;
--analysis independently chooses who receives text and images.
Media options include --start, --end, --save-md, --no-diarize and --fresh.
Use --help-all for every advanced option.

Exit: 0 success/handoff, 1 failure, 2 configuration/usage, 3 model missing,
4 speaker review required. Child-process failures are propagated.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
import json
import contextlib
import io
import os
import config
from pathlib import Path

import cli
import llm
from companions import Paths, resolve_base
from download import is_url
from state import read_json, write_json, media_identity, StageState, stage_key

HERE = Path(__file__).resolve().parent
PROTOCOL_RE = re.compile(r"^- \*\*Protocol file:\*\* `(.+?)`\s*$", re.M)


def call(script: str, *args: str, capture: bool = False) -> subprocess.CompletedProcess:
    print(f"[pipeline] -- {script} {' '.join(args)}", file=sys.stderr, flush=True)
    return subprocess.run([sys.executable, "-X", "utf8", str(HERE / script), *args],
                          stdout=subprocess.PIPE if capture else None,
                          text=capture, encoding="utf-8" if capture else None, errors="replace" if capture else None)


def build_parser():
    ap = cli.parser(__doc__, examples=[
        'python transcribe.py run "20261013-1100 - Thema.mp4" --language de --local',
        'python transcribe.py run "20261013-1100 - Thema.mp4" --language de --local --stop-at-speakers',
        'python transcribe.py run "20261013-1100 - Thema.mp4" --redact   # add redaction to a finished run',
        'python transcribe.py run "https://youtu.be/..." --language en --start 0 --end 5:00'])
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
    ap.add_argument("--analysis", choices=("model", "harness", "none"), default="model",
                    help="Who writes the report (default model; harness produces an explicit handoff)")
    ap.add_argument("--plan", action="store_true", help="Show stages and cache decisions without running them")
    ap.add_argument("--json", action="store_true", help="Machine-readable plan or final result on stdout")
    return ap


def main() -> int:
    ap = build_parser()
    if "--help-all" in sys.argv[1:]:
        ap.print_help()
        import run
        run.build_parser().print_help()
        return 0
    if not sys.argv[1:]:
        # The public `run` command: a missing source is a usage error (exit 2), not a help request.
        ap.print_usage(sys.stderr)
        print(f"{ap.prog}: error: a source file or URL is required (see --help)", file=sys.stderr)
        return 2
    args, run_extra = cli.parse_known(ap)
    import run
    lang = ["--language", args.language] if args.language else []
    local = ["--whisper", "whisper-local", "--diarize", "pyannote-local"] if args.local else []
    run_args = run.build_parser().parse_args([args.source, *lang, *local, *run_extra])
    config.snapshot()
    if args.local and (run_args.whisper != "whisper-local" or
                       (not run_args.no_diarize and run_args.diarize != "pyannote-local")):
        ap.error("--local conflicts with a cloud backend override")
    if run_args.no_save_md:
        ap.error("The pipeline requires persisted companions; use run.py --no-save-md for ephemeral runs")
    run.validate_args(run_args, ap)
    url = is_url(args.source)
    index_path = config.user_dir() / "runs.json"
    index = read_json(index_path, {}) or {}
    base = resolve_base(Path(run_args.save_md).expanduser().resolve()) if run_args.save_md else (
        Path(index[args.source]) if url and args.source in index else
        None if url else resolve_base(Path(args.source).expanduser().resolve()))
    p = Paths(base) if base else None
    previous = read_json(p.base.with_name(p.base.name + ".run.json"), {}) if p else {}
    previous = previous or {}
    # A bare base/companion of a previous run resolves back to its original media.
    source = args.source
    companion = not url and previous.get("source") and (not Path(source).is_file() or
                Path(source).suffix.lower() in (".md", ".json", ".vtt", ".xml"))
    if companion:
        source = previous["source"]
        if not is_url(source):
            source = (previous.get("source_identity") or {}).get("path") or source
        resume_parser = run.build_parser()
        resume_parser.set_defaults(**previous.get("options", {}))
        run_args = resume_parser.parse_args([source, *lang, *local, *run_extra])
        args.language = run_args.language
        lang = ["--language", args.language] if args.language else []
        url = is_url(source)
    if not url:
        source = str(Path(source).expanduser().resolve())
        run_args.source = source
    run.validate_args(run_args, ap)
    settings = {k: v for k, v in vars(run_args).items() if k not in ("result_json", "fresh", "background")}
    same_source = url or (Path(source).is_file() and previous.get("source_identity") == media_identity(Path(source)))
    reusable = bool(p and p.transcript.is_file() and p.protocol.is_file() and same_source and
                    previous.get("options") == settings and previous.get("local_config") == local_config() and
                    previous.get("glossary") == glossary_hash(Path(source) if not url else None))
    if reusable and args.analysis != "none" and not args.no_frames:
        from companions import read_protocol
        reusable = all(Path(f["path"]).is_file() for f in read_protocol(p.protocol).get("frames", []))
    needed = args.rerun or run_args.fresh or not reusable
    if needed and not url and not Path(source).is_file():
        if previous.get("source"):
            ap.error(f"Source is unavailable for recomputation: {source}")
        ap.error(f"Source not found: {source}")
    plan = {"schema": 1, "source": source, "base": str(base) if base else None,
            "stages": [{"stage": "media", "status": "pending" if needed else "current",
                        "reason": "inputs/options changed or refresh requested" if needed else "recorded inputs and outputs match"}],
            "analysis": args.analysis}
    if p:
        from companions import read_protocol, read_transcript
        has_video = bool(read_protocol(p.protocol).get("frames"))
        for stage, output in (("frames", p.frames_json), ("speakers", p.speakers), ("kompakt", p.kompakt), ("illustrate", p.manifest), ("report", p.report)):
            options = {"language": args.language}
            options.update({"no_frames": args.no_frames, "max_frames": 48} if stage == "report" else
                           {"max_frames": 48} if stage == "frames" else {"max": 12, "rounds": 2} if stage == "illustrate" else {})
            current = not needed and not args.force and StageState(p.base).current(stage, stage_key(p, stage, options), [output])
            skip = args.analysis != "model" or (stage in ("frames", "illustrate") and args.no_frames)
            if not needed:
                skip |= stage in ("frames", "illustrate") and not has_video
                skip |= stage == "speakers" and not p.speakers.is_file()
                skip |= stage == "kompakt" and not any(b.label for b in read_transcript(p.transcript))
            if stage == "illustrate" and args.redact is not None:
                import illustrate_agent
                current &= illustrate_agent.spec_redaction(read_json(p.spec, []) or []) == args.redact
            plan["stages"].append({"stage": stage, "status": "skipped" if skip else "current" if current else "pending"})
    if args.plan:
        emit_result(plan, args.json)
        return 0
    from joblock import workflow_lock
    # URL output paths are discovered during acquisition; serialize by URL until then.
    from state import digest
    lock_base = config.user_dir() / ("url-" + digest(source)[:16]) if url else base
    if os.environ.get("TRANSCRIBE_WORKFLOW_LOCK") != str(lock_base.resolve()):
        with workflow_lock(lock_base, background=run_args.background) as acquired:
            if not acquired:
                emit_result({"schema": 1, "status": "busy", "base": str(base) if base else None}, args.json)
                return 0
            # Another process may have completed while we waited. Re-read state.
            return main()
    with workflow_lock(lock_base):
        if needed:
            import setup
            required = ["ffmpeg", "ffprobe"] + (["yt-dlp"] if url else [])
            missing = [name for name in required if setup.find_tool(name) is None]
            if missing:
                print(f"[pipeline] tools missing: {', '.join(missing)}; run transcribe install", file=sys.stderr)
                return 2
            with tempfile.TemporaryDirectory(prefix="transcribe-result-") as tmp:
                result_path = Path(tmp) / "result.json"
                r = call("run.py", source, *media_arguments(run_args), "--result-json", str(result_path), capture=True)
                if r.returncode:
                    return r.returncode
                result = read_json(result_path, {}) or {}
            if not result.get("base") or not result.get("protocol"):
                print("[pipeline] media stage returned no structured output", file=sys.stderr)
                return 1
            p = Paths(Path(result["base"]))
            if url:
                from joblock import JobLock
                with JobLock(config.user_dir() / "runs-index.lock"):
                    index = read_json(index_path, {})
                    index[source] = str(p.base)
                    write_json(index_path, index)
        if args.analysis == "model":
            agent_args = [*lang]
            for flag in ("stop_at_speakers", "no_frames", "force"):
                if getattr(args, flag):
                    agent_args.append("--" + flag.replace("_", "-"))
            if args.redact is not None:
                agent_args.append("--redact" if args.redact else "--no-redact")
            analysed = call("agent.py", str(p.base), *agent_args, capture=True)
            if getattr(analysed, "stdout", None):
                print(analysed.stdout, file=sys.stderr, end="")
            rc = analysed.returncode
        else:
            rc = 0
        # The review list exists only after the model stages; a harness may take every path literally.
        review_path = p.base.with_name(p.base.name + ".review.md")
        result = {"schema": 1, "status": "review_required" if rc in (4, 5) else "failed" if rc else
                  "handoff" if args.analysis == "harness" else "complete", "exit_code": rc,
                  "base": str(p.base), "protocol": str(p.protocol), "transcript": str(p.transcript),
                  "report": str(p.report), "review": str(review_path) if review_path.is_file() else None}
        if args.analysis == "harness":
            from companions import read_protocol
            from report import select_frames
            result["frames"] = select_frames(read_protocol(p.protocol).get("frames", [])) if not args.no_frames else []
        emit_result(result, args.json)
        return rc


def local_config() -> dict:
    return {name: config.get(name) for name in config.PARAMETERS
            if name.startswith(("TRANSCRIBE_CPU_", "TRANSCRIBE_GPU_", "TRANSCRIBE_WHISPER_", "TRANSCRIBE_OCR_", "AZURE_TRANSCRIBE_", "ASSEMBLYAI_")) and not config.PARAMETERS[name].secret}


def media_arguments(args) -> list[str]:
    """Serialize effective media options, including defaults inherited on resume."""
    import run
    result = []
    for action in run.build_parser()._actions:
        if not action.option_strings or action.dest in ("help", "result_json"):
            continue
        value = getattr(args, action.dest, None)
        if value is None or value == action.default:
            continue
        if isinstance(action, argparse._StoreTrueAction):
            if value:
                result.append(action.option_strings[0])
        elif isinstance(action, argparse._StoreFalseAction):
            if not value:
                result.append(action.option_strings[0])
        else:
            result.extend([action.option_strings[0], str(value)])
    return result


def glossary_hash(source: Path | None) -> str:
    from stt import load_hotwords
    from state import digest
    with contextlib.redirect_stderr(io.StringIO()):
        return digest(load_hotwords(source))


def emit_result(result: dict, structured: bool) -> None:
    if structured:
        print(json.dumps(result, ensure_ascii=False))
    else:
        for stage in result.get("stages", []):
            print(f"{stage['stage']}: {stage['status']} {stage.get('reason', '')}")
        if result.get("status"):
            print(f"[pipeline] {result['status']}: {result.get('report')}")


if __name__ == "__main__":
    raise SystemExit(main())
