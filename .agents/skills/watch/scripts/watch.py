#!/usr/bin/env python3
"""/watch entry point: download video, extract frames, parse transcript.

Prints a markdown report to stdout listing frame paths + transcript. Claude
then Reads each frame path to see the video.
"""
from __future__ import annotations

import argparse
import atexit
import datetime
import math
import re
import shutil
import sys
import tempfile
import time
import unicodedata
from pathlib import Path


# Make stdout/stderr UTF-8-safe before any print() runs. Windows consoles
# default to cp1252, which raises UnicodeEncodeError on chars like `≥`,
# `→`, `·`, `...`, `×`. Without this, the report-rendering print() at the
# very end crashes after all the expensive work (frames + Whisper) is
# already done - costing the user the saved-report files. `errors='replace'`
# turns any survivor chars into `?` instead of crashing. Linux already has
# UTF-8 stdout; reconfigure is a no-op there.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def _dedup_threshold_arg(value: str) -> "int | str":
    """Validator for --dedup-threshold: accepts 'auto' or an integer 0-64."""
    if value == "auto":
        return "auto"
    try:
        i = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"--dedup-threshold must be 'auto' or an integer 0-64 (got {value!r})"
        )
    if not 0 <= i <= 64:
        raise argparse.ArgumentTypeError(
            f"--dedup-threshold integer must be 0-64 (got {i})"
        )
    return i


def _reap_old_work_dirs(prefix: str = "watch-", max_age_hours: float = 24.0) -> None:
    """Delete leftover working directories from prior crashed/killed runs.

    On normal completion, Step 6 of SKILL.md instructs Claude to `rm -rf` the
    work dir, and on Ctrl+C `finally` blocks tidy up the small bits. But
    nothing cleans up after SIGKILL / power loss / Claude-Code-tab-closed:
    the `mkdtemp` dir is not wrapped in a context manager because we want it
    to survive past the script for follow-up reads. Net result: long-running
    users accumulate gigabytes of dead work dirs in `/tmp` (or %TEMP%).

    Strategy: at startup, scan the system temp root for `watch-*` directories
    whose mtime is older than `max_age_hours`, and delete them. We use mtime
    (not ctime / atime) because ffmpeg keeps touching files in the active
    work dir, so mtime stays fresh during a real run. Anything older than
    24 h is definitionally dead - even the slowest URL download finishes
    inside that window.
    """
    tmp_root = Path(tempfile.gettempdir())
    cutoff = time.time() - max_age_hours * 3600
    reaped: list[str] = []
    for d in tmp_root.glob(f"{prefix}*"):
        if not d.is_dir():
            continue
        try:
            mtime = d.stat().st_mtime
        except OSError:
            continue
        if mtime >= cutoff:
            continue
        try:
            shutil.rmtree(d, ignore_errors=True)
        except OSError:
            continue
        if not d.exists():
            reaped.append(d.name)
    if reaped:
        preview = ", ".join(reaped[:3])
        suffix = f" (+{len(reaped) - 3} more)" if len(reaped) > 3 else ""
        print(
            f"[watch] reaped {len(reaped)} old work dir(s) older than "
            f"{max_age_hours:.0f}h: {preview}{suffix}",
            file=sys.stderr,
        )


SCRIPT_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(SCRIPT_DIR))


def _slugify(name: str, max_length: int = 60) -> str:
    """Lowercase ASCII slug from an arbitrary title - safe for filesystems.

    Steps: NFKD-strip diacritics, lowercase, non-alphanumeric → `-`, collapse
    runs of hyphens, trim. Falls back to "untitled" if everything strips out.
    """
    normalized = unicodedata.normalize("NFKD", name)
    ascii_only = "".join(c for c in normalized if not unicodedata.combining(c))
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", ascii_only.lower())
    slug = re.sub(r"-+", "-", slug).strip("-")
    if len(slug) > max_length:
        slug = slug[:max_length].rstrip("-")
    return slug or "untitled"


def _detect_dates(
    source: str,
    info: dict,
    video_meta: dict,
    is_remote: bool,
    video_path_str: str,
) -> list[tuple[str, list[str]]]:
    """Return `[(YYYY-MM-DD, [source-labels]), ...]` ordered by first-discovery.

    Same date from multiple sources stays one entry with merged source list -
    two independent sources confirming the same date is strong evidence.
    Surfaced in the protocol so Claude can pick the most credible one and
    cross-check the title slide on frame 1. UI timestamps inside the video
    (footers, version stamps) are NOT a source - those can be defaults /
    dummies (the Gebäude-DB-footer pitfall).
    """
    by_date: dict[str, list[str]] = {}
    order: list[str] = []

    def _add(iso: str, src: str) -> None:
        if not iso:
            return
        if iso not in by_date:
            by_date[iso] = []
            order.append(iso)
        if src not in by_date[iso]:
            by_date[iso].append(src)

    # Filename / title - ISO `2024-03-04` / `20240304` / `2024_03_04`
    name_haystack = (
        info.get("title") or Path(source).name if is_remote else Path(source).name
    )
    m = re.search(r"(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})", name_haystack)
    if m:
        try:
            iso = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3))).isoformat()
            _add(iso, "filename" if not is_remote else "title")
        except ValueError:
            pass

    # Filename / title - DMY `04.03.2024` / `04-03-2024` / `04/03/2024`
    m = re.search(r"(\d{1,2})[.\-/](\d{1,2})[.\-/](20\d{2})", name_haystack)
    if m:
        try:
            iso = datetime.date(int(m.group(3)), int(m.group(2)), int(m.group(1))).isoformat()
            _add(iso, "filename" if not is_remote else "title")
        except ValueError:
            pass

    # yt-dlp upload_date - YYYYMMDD
    upload = (info.get("upload_date") or "").strip()
    if len(upload) == 8 and upload.isdigit():
        try:
            iso = datetime.date(int(upload[:4]), int(upload[4:6]), int(upload[6:8])).isoformat()
            _add(iso, "yt-dlp upload_date")
        except ValueError:
            pass

    # ffprobe creation_time - ISO 8601 like 2024-03-04T13:55:01.000000Z
    creation = video_meta.get("creation_time") or ""
    if creation and re.match(r"^20\d{2}-\d{2}-\d{2}", creation):
        _add(creation[:10], "ffprobe creation_time")

    # File mtime - last resort, local files only
    if not is_remote:
        try:
            mtime = Path(video_path_str).stat().st_mtime
            _add(datetime.date.fromtimestamp(mtime).isoformat(), "file mtime")
        except OSError:
            pass

    return [(iso, by_date[iso]) for iso in order]

from diarize import (  # noqa: E402
    align_speakers,
    diarize_assemblyai,
    diarize_pyannote_api,
    diarize_pyannote_local,
    pick_backend as pick_diarize_backend,
)
from download import download, is_url  # noqa: E402
from frames import (  # noqa: E402
    MAX_FPS,
    auto_fps,
    auto_fps_focus,
    detect_cuts,
    extract,
    extract_at_timestamps,
    extract_cuts,
    format_time,
    gap_fill_timestamps,
    get_metadata,
    parse_time,
)
from resources import collect as collect_resources, format_section as format_resources  # noqa: E402
from transcribe import filter_range, format_transcript, parse_vtt  # noqa: E402
from stt import extract_audio, load_api_key, transcribe_video  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="watch",
        description="Download a video, extract auto-scaled frames, and surface the transcript.",
    )
    ap.add_argument("source", help="Video URL or local file path")
    ap.add_argument("--max-frames", type=int, default=80, help="Cap on frame count (default 80, hard max 100)")
    ap.add_argument("--resolution", type=int, default=512, help="Frame width in pixels (default 512)")
    ap.add_argument("--fps", type=float, default=None, help="Override auto-fps")
    ap.add_argument("--start", type=str, default=None, help="Range start (SS, MM:SS, or HH:MM:SS)")
    ap.add_argument("--end", type=str, default=None, help="Range end (SS, MM:SS, or HH:MM:SS)")
    ap.add_argument("--out-dir", type=str, default=None, help="Working directory (default: tmp)")
    ap.add_argument(
        "--no-whisper",
        action="store_true",
        help="Disable Whisper fallback. Report frames-only if no captions available.",
    )
    ap.add_argument(
        "--whisper",
        choices=["groq", "openai"],
        default=None,
        help="Force a specific Whisper backend. Default: prefer Groq, fall back to OpenAI.",
    )
    ap.add_argument(
        "--whisper-workers",
        type=int,
        default=None,
        help="Parallel Whisper chunk uploads (default 1 = sequential). "
             "Higher values speed up long videos but risk hitting the "
             "audio-second-per-hour rate limit on Groq Free Tier (Retry-After "
             "can be several hundred seconds). Try 2 if you have a paid tier "
             "or your video is moderate-length.",
    )
    ap.add_argument(
        "--no-scene",
        action="store_true",
        help="Disable scdet-based cut detection. By default, an extra frame is "
             "extracted at every detected cut, in addition to the regular sampling.",
    )
    ap.add_argument(
        "--scene-threshold",
        type=float,
        default=None,
        help="Override the auto-detected scdet threshold (default: auto via "
             "knee-point detection on the score distribution; lower = more sensitive)",
    )
    ap.add_argument(
        "--scene-min-gap",
        type=float,
        default=2.0,
        help="Minimum seconds between consecutive cut frames (default 2.0)",
    )
    ap.add_argument(
        "--scene-max-frames",
        type=int,
        default=80,
        help="Cap on additional cut frames extracted (default 80)",
    )
    ap.add_argument(
        "--scene-settle-seconds",
        type=float,
        default=1.0,
        help="Seconds after a detected scene cut to wait before extracting the "
             "frame (default 1.0). Lets UI transitions / dialogs / launcher "
             "windows render before capture, so cut frames don't land on "
             "loading-state / black mid-transition pixels. Capped at "
             "next_cut - 0.3s so we never bleed into the following shot. "
             "Set to 0 to revert to the old just-before-cut behavior.",
    )
    ap.add_argument(
        "--frame-workers",
        type=int,
        default=None,
        help="Thread-pool size for per-frame ffmpeg calls (default: "
             "min(8, cpu_count())). Each worker spawns one ffmpeg subprocess. "
             "Set to 1 to force sequential extraction (useful on HDDs where "
             "concurrent seeks thrash, or for benchmark comparison). "
             "Going above 8 rarely helps on consumer hardware - ffmpeg "
             "instances start contending for cache and disk bandwidth.",
    )
    ap.add_argument(
        "--no-dedup",
        action="store_true",
        help="Disable dHash-based deduplication of near-identical regular "
             "frames (default: dedup enabled with threshold 6). Cut frames "
             "are never deduplicated regardless of this flag.",
    )
    ap.add_argument(
        "--dedup-threshold",
        type=_dedup_threshold_arg,
        default="auto",
        help="Hamming-distance threshold for the dHash dedup. 'auto' (default) "
             "picks the threshold via knee-point detection on the per-video "
             "distance distribution - adapts to talking-head (cliff around 4) "
             "vs UI-demo (cliff around 10). Pass an integer to override "
             "(sensible range 3-12). Ignored when --no-dedup is set.",
    )
    ap.add_argument(
        "--save-md",
        type=str,
        default=None,
        help="Save the markdown report to this path. Defaults to "
             "<video-stem>.md next to the source for local files; "
             "./watch/<YYYY-MM-DD>-<slug>/<slug>.md for URL sources.",
    )
    ap.add_argument(
        "--no-save-md",
        action="store_true",
        help="Disable the default auto-save for local-file sources.",
    )
    ap.add_argument(
        "--no-chunk",
        action="store_true",
        help="Disable auto-chunking. By default, videos longer than 10 minutes "
             "without --start/--end are split into ~10-minute chunks, each "
             "processed with focused-mode frame budget, then merged. Use this "
             "flag to revert to the sparse single-pass behavior.",
    )
    ap.add_argument(
        "--diarize",
        nargs="?",
        const="auto",
        default=None,
        choices=["auto", "assemblyai", "pyannote-api", "pyannote-local"],
        help="Enable speaker diarization. With no value: auto-pick the best "
             "available backend (AssemblyAI > pyannote.ai > pyannote local). "
             "Explicit choices: 'assemblyai' (cloud, transcription + diarization "
             "in one call - replaces Whisper), 'pyannote-api' (cloud pyannote.ai, "
             "diarization aligned to Whisper transcript), 'pyannote-local' "
             "(pyannote.audio locally; needs pyannote.audio package + HF_TOKEN). "
             "Requires the matching API key in ~/.config/watch/.env when not local.",
    )
    args = ap.parse_args()

    max_frames = min(args.max_frames, 100)

    # Local-file and explicit --save-md paths resolve now; URL sources defer
    # to Phase 2 below (needs the yt-dlp title to slug the folder).
    save_md_path: Path | None = None
    protocol_path: Path | None = None
    transcript_path: Path | None = None
    if args.save_md:
        save_md_path = Path(args.save_md).expanduser().resolve()
    elif not args.no_save_md and not is_url(args.source):
        src = Path(args.source).expanduser().resolve()
        save_md_path = src.with_suffix(".md")

    if args.out_dir:
        work = Path(args.out_dir).expanduser().resolve()
    else:
        # Reap before mkdtemp so the new dir we're about to create is never
        # a candidate for deletion (its mtime is fresh by the time we scan).
        _reap_old_work_dirs()
        work = Path(tempfile.mkdtemp(prefix="watch-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"[watch] working dir: {work}", file=sys.stderr)

    # Announce parallelism budget + transcript/diarization plan up front so
    # the user can see what's actually running and override if needed.
    from frames import _default_workers as _frame_default
    from stt import WHISPER_PARALLEL_UPLOADS as _whisper_default
    from stt import load_api_key as _load_whisper_key
    from diarize import _load_env_value as _load_diarize_env
    frame_workers = args.frame_workers if args.frame_workers is not None else _frame_default()
    whisper_workers = args.whisper_workers if args.whisper_workers is not None else _whisper_default
    dedup_label = "off" if args.no_dedup else f"{args.dedup_threshold}"
    print(
        f"[watch] workers: frame={frame_workers}, "
        f"whisper={whisper_workers} ({'seq' if whisper_workers == 1 else 'parallel'}), "
        f"dedup={dedup_label} "
        f"(override via --frame-workers / --whisper-workers / --dedup-threshold)",
        file=sys.stderr,
    )
    # Transcript + diarization availability summary - flags missing keys
    # before they bite mid-run.
    _wb, _wk = _load_whisper_key(args.whisper)
    whisper_status = f"whisper={_wb}" if _wb and _wk else "whisper=NONE (no GROQ/OPENAI key)"
    diarize_avail = []
    if _load_diarize_env("ASSEMBLYAI_API_KEY"):
        diarize_avail.append("assemblyai")
    if _load_diarize_env("PYANNOTE_API_KEY"):
        diarize_avail.append("pyannote-api")
    if _load_diarize_env("HF_TOKEN") or _load_diarize_env("HUGGINGFACE_TOKEN"):
        diarize_avail.append("pyannote-local")
    diarize_status = (
        f"diarize available: {', '.join(diarize_avail)}"
        if diarize_avail else "diarize: no backend configured"
    )
    diarize_active = (
        f"diarize requested: {args.diarize}"
        if args.diarize else "diarize: off (--diarize to enable)"
    )
    print(f"[watch] transcript: {whisper_status} | {diarize_active}", file=sys.stderr)
    if args.diarize:
        print(f"[watch] {diarize_status}", file=sys.stderr)

    print(
        "[watch] downloading via yt-dlp..." if is_url(args.source) else "[watch] using local file...",
        file=sys.stderr,
    )
    dl = download(args.source, work / "download")
    video_path = dl["video_path"]

    # URL-source default: ./watch/<YYYY-MM-DD>-<slug>/<slug>.md. Per-video
    # subfolder + date prefix keeps multiple runs sortable; folder leaves room
    # for cached video / extra artifacts.
    if save_md_path is None and not args.no_save_md and is_url(args.source):
        info_for_path = dl.get("info") or {}
        title = info_for_path.get("title") or "untitled"
        slug = _slugify(title)
        date_prefix = datetime.date.today().strftime("%Y-%m-%d")
        folder = Path.cwd() / "watch" / f"{date_prefix}-{slug}"
        save_md_path = folder / f"{slug}.md"

    if save_md_path:
        # Accept `<base>.md` (current) and `<base>.watch.md` (legacy) shapes.
        name = save_md_path.name
        if name.endswith(".watch.md"):
            base = name[: -len(".watch.md")]
        elif name.endswith(".md"):
            base = name[: -len(".md")]
        else:
            base = save_md_path.stem
        protocol_path = save_md_path.parent / f"{base}.protocol.md"
        transcript_path = save_md_path.parent / f"{base}.transcript.md"

    meta = get_metadata(video_path)
    full_duration = meta["duration_seconds"]

    start_sec = parse_time(args.start)
    end_sec = parse_time(args.end)

    if start_sec is not None and start_sec < 0:
        raise SystemExit("--start must be non-negative")
    if end_sec is not None and start_sec is not None and end_sec <= start_sec:
        raise SystemExit("--end must be greater than --start")
    if full_duration > 0 and start_sec is not None and start_sec >= full_duration:
        raise SystemExit(f"--start {start_sec:.1f}s is past end of video ({full_duration:.1f}s)")

    effective_start = start_sec if start_sec is not None else 0.0
    effective_end = end_sec if end_sec is not None else full_duration
    effective_duration = max(0.0, effective_end - effective_start)
    focused = start_sec is not None or end_sec is not None

    # Long unfocused videos auto-split into ~10-min chunks for denser coverage
    # than a single sparse pass; --no-chunk reverts to single-pass-sparse.
    CHUNK_TARGET_SECONDS = 600.0
    chunked = (
        not focused
        and full_duration > CHUNK_TARGET_SECONDS
        and not args.no_chunk
    )
    if chunked:
        n_chunks = math.ceil(full_duration / CHUNK_TARGET_SECONDS)
        chunk_size = full_duration / n_chunks
        chunks: list[tuple[float, float]] = []
        for i in range(n_chunks):
            cs = i * chunk_size
            ce = (i + 1) * chunk_size if i < n_chunks - 1 else full_duration
            chunks.append((cs, ce))
    else:
        chunks = [(effective_start, effective_end)]

    # Chunked treats each chunk as focused (dense budget); single-chunk uses
    # the sparse-or-focused budget per the user's --start/--end choice.
    chunk_plans: list[tuple[float, float, float, int]] = []  # (start, end, fps, target)
    for cs, ce in chunks:
        cd = ce - cs
        if chunked or focused:
            cfps, ctarget = auto_fps_focus(cd, max_frames=max_frames)
        else:
            cfps, ctarget = auto_fps(cd, max_frames=max_frames)
        if args.fps is not None:
            cfps = min(args.fps, MAX_FPS)
            ctarget = max(1, int(round(cfps * cd)))
        chunk_plans.append((cs, ce, cfps, ctarget))

    if chunked:
        scope = f"chunked {len(chunks)}x~{chunks[0][1]-chunks[0][0]:.0f}s over {full_duration:.1f}s"
    elif focused:
        scope = f"{format_time(effective_start)}-{format_time(effective_end)} ({effective_duration:.1f}s)"
    else:
        scope = f"full {effective_duration:.1f}s"

    # Detect cuts once globally - per-chunk detection would multiply the
    # scdet pass; cuts get partitioned into chunk buckets at gap-fill time.
    cut_times: list[float] = []
    cut_threshold: float | None = None
    threshold_is_auto = args.scene_threshold is None
    if not args.no_scene:
        thr_label = "auto" if threshold_is_auto else f"{args.scene_threshold:g}"
        print(
            f"[watch] detecting cuts (scdet threshold {thr_label}, "
            f"min gap {args.scene_min_gap}s)...",
            file=sys.stderr,
        )
        cut_times, cut_threshold = detect_cuts(
            video_path,
            threshold=args.scene_threshold,
            min_gap=args.scene_min_gap,
            start_seconds=start_sec,
            end_seconds=end_sec,
        )
        chose = (
            f"auto-picked {cut_threshold:.2f}"
            if threshold_is_auto else f"threshold {cut_threshold:.2f}"
        )
        print(
            f"[watch] {len(cut_times)} cuts detected ({chose})",
            file=sys.stderr,
        )

    # Gap-fill regular timestamps per chunk against the cuts that fall in it.
    regular_timestamps: list[float] = []
    for cs, ce, _cfps, ctarget in chunk_plans:
        chunk_cuts = [c for c in cut_times if cs <= c < ce]
        regular_timestamps.extend(
            gap_fill_timestamps(chunk_cuts, cs, ce, ctarget)
        )
    # Note: this prints the *candidate* count. Dedup (if enabled) runs at
    # the end of extract_at_timestamps and will reduce this number; that
    # final figure appears in a later [watch] dedup line. Wording made
    # explicit because users have read the candidate count as the final
    # frame budget and wondered why "dedup is gone".
    dedup_hint = (
        ", dedup will filter after extraction"
        if not args.no_dedup else ""
    )
    print(
        f"[watch] sampling {len(regular_timestamps)} regular frame candidates "
        f"(gap-filled across {len(cut_times)} cuts) over {scope}{dedup_hint}...",
        file=sys.stderr,
    )
    frames = extract_at_timestamps(
        video_path,
        work / "frames",
        regular_timestamps,
        kind="regular",
        resolution=args.resolution,
        workers=args.frame_workers,
        dedup_threshold=None if args.no_dedup else args.dedup_threshold,
    )

    cut_frames: list[dict] = []
    if cut_times:
        print(
            f"[watch] extracting up to {args.scene_max_frames} cut frames...",
            file=sys.stderr,
        )
        cut_frames = extract_cuts(
            video_path,
            work / "cuts",
            cut_times,
            resolution=args.resolution,
            max_cuts=args.scene_max_frames,
            settle_seconds=args.scene_settle_seconds,
            workers=args.frame_workers,
        )

    total_target = sum(p[3] for p in chunk_plans)
    avg_fps = (
        sum(p[2] for p in chunk_plans) / len(chunk_plans)
        if chunk_plans else 0.0
    )

    all_frames = sorted(
        list(frames) + list(cut_frames),
        key=lambda f: (f["timestamp_seconds"], f.get("kind") == "cut"),
    )

    # `--diarize` without a value auto-picks the first configured backend.
    diarize_backend = pick_diarize_backend(args.diarize)
    if args.diarize and diarize_backend is None:
        print(
            "[watch] --diarize requested but no backend configured - set "
            "ASSEMBLYAI_API_KEY, PYANNOTE_API_KEY, or install pyannote.audio. "
            "Continuing without diarization.",
            file=sys.stderr,
        )

    transcript_segments: list[dict] = []
    transcript_text: str | None = None
    transcript_source: str | None = None
    audio_path: Path | None = None  # populated on first audio extraction

    # Transcript path: VTT captions → AssemblyAI → Whisper.
    if dl.get("subtitle_path"):
        try:
            all_segments = parse_vtt(dl["subtitle_path"])
            transcript_segments = filter_range(all_segments, start_sec, end_sec) if focused else all_segments
            transcript_source = "captions"
        except Exception as exc:
            print(f"[watch] subtitle parse failed: {exc}", file=sys.stderr)

    if not transcript_segments and diarize_backend == "assemblyai":
        # AssemblyAI returns transcript + speaker labels in one call.
        try:
            audio_path = extract_audio(video_path, work / "audio.mp3")
            all_segments = diarize_assemblyai(audio_path)
            transcript_segments = filter_range(all_segments, start_sec, end_sec) if focused else all_segments
            transcript_source = "assemblyai (transcript + diarization)"
            diarize_backend = "done"
        except SystemExit as exc:
            msg = str(exc)
            # Distinguish "key not configured" (expected, friendly) from
            # "real API failure" (error). The "missing" path is what triggers
            # when --diarize=assemblyai is picked but the key isn't set -
            # we want this to read like a routine fallback, not an alarm.
            if "ASSEMBLYAI_API_KEY missing" in msg:
                print(
                    "[watch] AssemblyAI skipped: ASSEMBLYAI_API_KEY not "
                    "configured in ~/.config/watch/.env - falling back to Whisper.",
                    file=sys.stderr,
                )
            else:
                print(
                    f"[watch] AssemblyAI failed ({msg}) - falling back to Whisper",
                    file=sys.stderr,
                )
            diarize_backend = None

    if not transcript_segments and not args.no_whisper:
        backend, api_key = load_api_key(args.whisper)
        if backend and api_key:
            try:
                all_segments, used_backend = transcribe_video(
                    video_path,
                    work / "audio.mp3",
                    backend=backend,
                    api_key=api_key,
                    parallel_uploads=args.whisper_workers,
                )
                transcript_segments = filter_range(all_segments, start_sec, end_sec) if focused else all_segments
                transcript_source = f"whisper ({used_backend})"
                # Whisper extracted the audio as a side effect - reuse for pyannote.
                audio_path = work / "audio.mp3"
            except SystemExit as exc:
                print(f"[watch] whisper fallback failed: {exc}", file=sys.stderr)
        else:
            hint = (
                f"--whisper {args.whisper} was set but the matching API key is missing"
                if args.whisper else
                "no subtitles and no Whisper API key found"
            )
            setup_py = SCRIPT_DIR / "setup.py"
            print(
                f"[watch] {hint} - run `python3 {setup_py}` to enable the Whisper fallback",
                file=sys.stderr,
            )

    # Pyannote runs alongside Whisper and aligns to the transcript;
    # AssemblyAI already delivered speakers above.
    if transcript_segments and diarize_backend in ("pyannote-api", "pyannote-local"):
        try:
            if audio_path is None or not audio_path.exists():
                audio_path = extract_audio(video_path, work / "audio.mp3")
            if diarize_backend == "pyannote-api":
                turns = diarize_pyannote_api(audio_path)
            else:
                turns = diarize_pyannote_local(audio_path)
            transcript_segments = align_speakers(transcript_segments, turns)
            speakers = sorted({t["speaker"] for t in turns}) if turns else []
            tag = f"{diarize_backend} ({len(speakers)} speakers)"
            transcript_source = f"{transcript_source} + {tag}" if transcript_source else tag
        except SystemExit as exc:
            print(
                f"[watch] {diarize_backend} diarization failed ({exc}) - "
                f"transcript kept without speaker labels",
                file=sys.stderr,
            )

    if transcript_segments:
        transcript_text = format_transcript(transcript_segments)

    info = dl.get("info") or {}

    # emit() -> stdout + protocol.md; emit_t() -> transcript.md only (kept off
    # stdout so the chat log stays scannable; Claude reads the file when needed).
    protocol_lines: list[str] = []
    transcript_lines: list[str] = []

    def emit(line: str = "") -> None:
        # Append FIRST, then print. If print raises (which shouldn't happen
        # after the UTF-8 stdout reconfigure, but who knows what future
        # changes will introduce), the buffer is already complete, so the
        # finally-save block can still flush a valid report to disk.
        protocol_lines.append(line)
        try:
            print(line)
        except Exception as exc:
            # Suppress and warn once. Better to lose the console echo than
            # to lose 10+ min of frame extraction + Whisper work.
            sys.stderr.write(
                f"[watch] WARNING: stdout print failed ({type(exc).__name__}: "
                f"{exc}). Report buffer kept; will still be saved.\n"
            )

    def emit_t(line: str = "") -> None:
        transcript_lines.append(line)

    def _persist_report() -> None:
        """Flush whatever's currently in protocol_lines / transcript_lines to disk.

        Idempotent and crash-tolerant: safe to call from a finally block
        even when an exception interrupted the report building. Files are
        written best-effort; individual write failures don't bubble out
        so a transcript can survive a broken protocol-render etc.
        """
        if not save_md_path:
            return
        try:
            save_md_path.parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            sys.stderr.write(f"[watch] WARNING: could not create save dir: {exc}\n")
            return

        def _write_best_effort(path: "Path", content: str, label: str) -> None:
            try:
                path.write_text(content + "\n", encoding="utf-8")
                sys.stderr.write(f"[watch] {label:11s} -> {path}\n")
            except OSError as exc:
                sys.stderr.write(
                    f"[watch] WARNING: could not write {label} ({path}): {exc}\n"
                )

        if protocol_lines:
            _write_best_effort(protocol_path, "\n".join(protocol_lines), "protocol")
        if transcript_lines:
            _write_best_effort(transcript_path, "\n".join(transcript_lines), "transcript")

        # Main analysis-target file is a stub with cross-links; Claude
        # appends Summary + Analysis sections later.
        title = info.get("title") or Path(args.source).name
        stub_lines = [
            "",
            f"# watch: {title}",
            "",
            f"- **Source:** {args.source}",
            f"- **Duration:** {format_time(full_duration)} ({full_duration:.1f}s)",
            f"- **Protocol:** [`{protocol_path.name}`](./{protocol_path.name}) - metadata + frame list",
            f"- **Transcript:** [`{transcript_path.name}`](./{transcript_path.name}) - full transcript",
            "",
            "_Claude appends `## Übersicht` (Kernaussagen + Chapter-Struktur),"
            " `## Summary` (thematic bullet catalog), and `## Analysis`"
            " (Inventar / Beurteilungen / Schlüsselaussagen / Details / Abdeckung /"
            " Resources) below this line._",
            "",
        ]
        _write_best_effort(save_md_path, "\n".join(stub_lines), "analysis")

    # Defense-in-depth: register _persist_report to fire at interpreter
    # shutdown. Frames are already extracted, audio is already transcribed
    # - those minutes-to-hours of work must survive any late-stage
    # rendering crash. atexit guarantees the save runs on normal exit,
    # unhandled exception, AND sys.exit(); the explicit call at the end
    # of main covers the happy path (atexit then sees nothing new to do
    # because the second write_text overwrites with identical content).
    atexit.register(_persist_report)

    emit()
    emit("# watch: video report")
    emit()
    emit(f"- **Source:** {args.source}")
    if info.get("title"):
        emit(f"- **Title:** {info['title']}")
    if info.get("uploader"):
        emit(f"- **Uploader:** {info['uploader']}")
    emit(f"- **Duration:** {format_time(full_duration)} ({full_duration:.1f}s)")
    if focused:
        emit(
            f"- **Focus range:** {format_time(effective_start)} -> {format_time(effective_end)} "
            f"({effective_duration:.1f}s)"
        )
    if meta.get("width") and meta.get("height"):
        emit(f"- **Resolution:** {meta['width']}x{meta['height']} ({meta.get('codec') or 'unknown codec'})")

    date_candidates = _detect_dates(args.source, info, meta, is_url(args.source), video_path)
    if date_candidates:
        if len(date_candidates) == 1:
            d, srcs = date_candidates[0]
            emit(f"- **Date candidates:** {d} ({' + '.join(srcs)})")
        else:
            emit("- **Date candidates** (Claude: confirm against frame 1 title slide):")
            for d, srcs in date_candidates:
                emit(f"  - {d} ({' + '.join(srcs)})")

    mode = "chunked" if chunked else ("focused" if focused else "full")
    sampler = "gap-filled" if cut_times else "uniform"
    chunk_note = (
        f", {len(chunks)} chunks x ~{chunks[0][1]-chunks[0][0]:.0f}s"
        if chunked else ""
    )
    if cut_frames:
        thr_show = (
            f"{cut_threshold:.1f} auto"
            if threshold_is_auto else f"{cut_threshold:.1f}"
        )
        emit(
            f"- **Frames:** {len(frames)} regular ({sampler}, ~{avg_fps:.3f} fps avg) "
            f"+ {len(cut_frames)} cut (scdet >= {thr_show}) "
            f"= {len(all_frames)} total ({mode} mode{chunk_note}, "
            f"budget {total_target}, max {max_frames}/chunk)"
        )
    else:
        scene_note = ""
        if not args.no_scene and cut_threshold is not None:
            scene_note = f" (no cuts >= {cut_threshold:.1f} detected)"
        emit(
            f"- **Frames:** {len(frames)} ({sampler}, ~{avg_fps:.3f} fps avg), "
            f"{mode} mode{chunk_note} "
            f"(budget {total_target}, max {max_frames}/chunk){scene_note}"
        )
    emit(f"- **Frame size:** {args.resolution}px wide")
    if transcript_segments:
        in_range = " in range" if focused else ""
        emit(
            f"- **Transcript:** {len(transcript_segments)} segments{in_range} "
            f"(via {transcript_source or 'captions'})"
        )
    else:
        emit("- **Transcript:** none available")
    if save_md_path:
        emit(f"- **Protocol file:** `{protocol_path}`")
        emit(f"- **Transcript file:** `{transcript_path}`")
        emit(f"- **Analysis target:** `{save_md_path}` (Claude writes Summary + Analysis here)")

    emit()
    emit("## Frames")
    emit()
    if cut_frames:
        emit(f"Regular frames live at: `{work / 'frames'}`")
        emit(f"Cut frames live at: `{work / 'cuts'}`")
    else:
        emit(f"Frames live at: `{work / 'frames'}`")
    emit()
    emit(
        "**Read each frame path below with the Read tool to view the image.** "
        "Frames are in chronological order; `t=MM:SS` is the absolute timestamp "
        "in the source video. Tag `[REG]` = regular interval sampling, "
        "`[CUT]` = scene-cut detected by scdet."
        if cut_frames else
        "**Read each frame path below with the Read tool to view the image.** "
        "Frames are in chronological order; `t=MM:SS` is the absolute timestamp in the source video."
    )
    emit()
    for frame in all_frames:
        kind = frame.get("kind", "regular")
        tag = "[CUT]" if kind == "cut" else "[REG]"
        suffix = f" {tag}" if cut_frames else ""
        emit(f"- `{frame['path']}` (t={format_time(frame['timestamp_seconds'])}){suffix}")

    emit_t()
    emit_t("## Transcript")
    emit_t()
    if transcript_text:
        label = transcript_source or "captions"
        if focused:
            emit_t(f"_Source: {label}. Filtered to {format_time(effective_start)} -> {format_time(effective_end)}:_")
        else:
            emit_t(f"_Source: {label}._")
        emit_t()
        emit_t("```")
        emit_t(transcript_text)
        emit_t("```")
    elif focused and dl.get("subtitle_path"):
        emit_t(f"_No transcript lines fell inside {format_time(effective_start)} -> {format_time(effective_end)}._")
    else:
        setup_py = SCRIPT_DIR / "setup.py"
        emit_t(
            "_No transcript available - proceed with frames only. "
            "Captions were missing and the Whisper fallback was unavailable "
            "(no API key set, or `--no-whisper` was used). "
            f"Run `python3 {setup_py}` to enable Whisper, then re-run._"
        )

    resources_grouped = collect_resources(
        info.get("description") or "",
        transcript_segments or [],
    )
    if resources_grouped:
        emit()
        emit(format_resources(resources_grouped))

    emit()
    emit("---")
    emit(f"_Work dir: `{work}` - delete when done._")

    _persist_report()
    # Happy path saved successfully - deregister the atexit hook so it
    # doesn't fire a second time during interpreter shutdown.
    atexit.unregister(_persist_report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
