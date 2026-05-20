#!/usr/bin/env python3
"""Test harness for the /watch STT pipeline.

Runs the REAL production code (stt.transcribe_audio) on an audio file and
writes a detailed report. This is a THIN harness: every transcription,
chunking, stitching and speaker-reconciliation step comes from stt.py - the
harness owns only argument parsing, optional trimming for a quick test, and
report formatting. There is no duplicated pipeline logic to drift out of
sync with production.

Config (endpoint URLs, keys, Azure tuning knobs) is read from
~/.config/watch/.env exactly as in production - see .env.example. Pre-flight
checks run inside transcribe_audio, so a misconfigured backend fails fast
here too (e.g. a multi-chunk Azure run with no AZURE_CLAUDE_KEY).

Usage (Windows: use `python`, not `python3`):
  python azure_transcribe_test.py <audio-file> [options]

  --backend NAME       STT backend to test. Default: azure-diarize.
  --max-seconds N      Trim the input to its first N seconds before
                       transcribing - a quick test without waiting for a
                       full-length run.
  --chunk-seconds N    Override the Azure per-chunk length (default 600).
  --overlap-seconds N  Override the Azure chunk overlap (default 20).
  --out PATH           Report destination. Default: <audio-stem>.stt-test.md
                       next to the audio file.

The report holds the full [MM:SS] [Speaker] timeline, the turn-merged view
and a per-speaker concatenation - the file to paste back for analysis.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(SCRIPT_DIR))

from setup import find_tool  # noqa: E402
from stt import (  # noqa: E402
    AzureDiarizeBackend,
    BACKEND_FACTORIES,
    _probe_duration,
    extract_audio,
    get_backend,
    transcribe_audio,
)
from transcribe import format_transcript, merge_speaker_turns  # noqa: E402


def _arg(args: list[str], flag: str, default: str | None = None) -> str | None:
    """Value following `flag`, or `default` if the flag is absent."""
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def _trim(src: Path, max_seconds: float) -> Path:
    """ffmpeg-trim the input to its first `max_seconds` (16 kHz mono mp3)."""
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg not found. Run `python scripts/setup.py --install-binaries`."
        )
    out = Path(tempfile.gettempdir()) / f"stt-test-trim-{uuid.uuid4().hex[:8]}.mp3"
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src), "-t", f"{max_seconds:.3f}",
        "-vn", "-acodec", "libmp3lame", "-ar", "16000", "-ac", "1", "-b:a", "64k",
        str(out),
    ]
    if subprocess.run(cmd, capture_output=True, text=True).returncode != 0 \
            or not out.exists():
        raise SystemExit("ffmpeg trim failed")
    return out


def _concat_by_speaker(turns: list[dict]) -> dict[str, str]:
    """Concatenate every speaker's text across the whole transcript."""
    by_spk: dict[str, list[str]] = {}
    for turn in turns:
        by_spk.setdefault(turn.get("speaker") or "(no speaker)", []).append(turn["text"])
    return {spk: " ".join(parts) for spk, parts in by_spk.items()}


def main() -> int:
    args = list(sys.argv[1:])
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2

    src = Path(args[0]).expanduser()
    if not src.exists():
        print(f"audio file not found: {src}", file=sys.stderr)
        return 2

    backend_name = _arg(args, "--backend", "azure-diarize")
    if backend_name not in BACKEND_FACTORIES:
        print(f"--backend must be one of {sorted(BACKEND_FACTORIES)}", file=sys.stderr)
        return 2
    max_seconds = _arg(args, "--max-seconds")
    chunk_seconds = _arg(args, "--chunk-seconds")
    overlap_seconds = _arg(args, "--overlap-seconds")
    out_raw = _arg(args, "--out")
    out_path = Path(out_raw).expanduser() if out_raw else src.with_suffix(".stt-test.md")

    backend = get_backend(backend_name)
    if isinstance(backend, AzureDiarizeBackend):
        if chunk_seconds:
            backend.chunk_limit = float(chunk_seconds)
        if overlap_seconds:
            backend.chunk_overlap = float(overlap_seconds)

    work = Path(tempfile.mkdtemp(prefix="stt-test-"))
    trim_file: Path | None = None
    print(f"[test] backend={backend_name}  source={src.name}", file=sys.stderr)

    try:
        # Normalise to a compact 16 kHz mono mp3 - exactly what production does.
        if max_seconds:
            trim_file = _trim(src, float(max_seconds))
            audio = extract_audio(str(trim_file), work / "audio.mp3")
        else:
            audio = extract_audio(str(src), work / "audio.mp3")
        duration = _probe_duration(audio)
        print(f"[test] transcribing {duration:.0f}s via {backend_name}...", file=sys.stderr)

        t0 = time.perf_counter()
        try:
            segments = transcribe_audio(audio, backend, work / "chunks")
        except SystemExit as exc:
            print(f"[test] pipeline failed: {exc}", file=sys.stderr)
            return 1
        elapsed = time.perf_counter() - t0
    finally:
        if trim_file is not None:
            trim_file.unlink(missing_ok=True)
        shutil.rmtree(work, ignore_errors=True)

    turns = merge_speaker_turns(segments)
    by_speaker = _concat_by_speaker(turns)
    rt = duration / elapsed if elapsed > 0 else 0.0

    report: list[str] = [
        f"# STT pipeline test - {src.name}",
        "",
        f"- backend: {backend_name}",
        f"- source: {src}",
        f"- duration transcribed: {duration:.0f}s",
    ]
    if isinstance(backend, AzureDiarizeBackend):
        report.append(
            f"- chunk policy: duration, {backend.chunk_limit:.0f}s chunks, "
            f"{backend.chunk_overlap:.0f}s overlap"
        )
    report += [
        "",
        "## Timing",
        f"- wall time: {elapsed:.1f}s",
        f"- speed: {rt:.1f}x realtime" if rt else "- speed: n/a",
        "",
        f"## Timeline - speaker turns ({len(turns)} turns, "
        f"{len(segments)} raw segments)",
        "```",
        format_transcript(segments),
        "```",
        "",
        "## Per-speaker concatenation",
    ]
    for spk, text in sorted(by_speaker.items()):
        report += [f"### {spk}", text, ""]

    wrote = True
    try:
        out_path.write_text("\n".join(report) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"[test] WARNING: could not write report to {out_path}: {exc}",
              file=sys.stderr)
        wrote = False

    print(
        f"\n[test] {len(segments)} segments, {len(turns)} turns, "
        f"{len(by_speaker)} speaker(s), {elapsed:.1f}s ({rt:.1f}x realtime)",
        file=sys.stderr,
    )
    print()
    print(format_transcript(segments))
    if wrote:
        print(f"\n[test] full report -> {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
