#!/usr/bin/env python3
"""Probe video metadata and extract frames at an auto-scaled fps.

Auto-fps targets a frame budget, not a fixed rate. Token cost scales with frame
count, so budget-by-duration keeps short videos dense and long videos capped.
When a user-specified range is passed, focused-mode budgets denser (they are
zooming in for detail).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from setup import find_tool


def _default_workers() -> int:
    """ThreadPool size for per-frame ffmpeg calls.

    8 is a good balance for typical 4-8 core dev laptops - beyond that, ffmpeg
    instances start contending for L3 cache and disk seek bandwidth, and the
    wall-clock curve flattens. Clamp to cpu_count() so 2-core machines don't
    over-subscribe.
    """
    return min(8, os.cpu_count() or 4)


MAX_FPS = 2.0


def _clamp_fps(fps: float, duration_seconds: float, max_frames: int) -> tuple[float, int]:
    fps = min(fps, MAX_FPS)
    target = min(max_frames, max(1, int(round(fps * duration_seconds))))
    return fps, target


def parse_time(value: str | float | int | None) -> float | None:
    """Parse SS, MM:SS, or HH:MM:SS (with optional .ms) into seconds."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    parts = s.split(":")
    try:
        if len(parts) == 1:
            return float(parts[0])
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    except ValueError:
        pass
    raise SystemExit(f"Cannot parse time value: {value!r} (expected SS, MM:SS, or HH:MM:SS)")


def format_time(seconds: float) -> str:
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, sec = divmod(rem, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{sec:02d}"
    return f"{minutes:02d}:{sec:02d}"


def get_metadata(video_path: str) -> dict:
    ffprobe = find_tool("ffprobe")
    if ffprobe is None:
        raise SystemExit(
            "ffprobe is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )

    result = subprocess.run(
        [
            ffprobe,
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            video_path,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"ffprobe failed: {result.stderr.strip()}")

    data = json.loads(result.stdout or "{}")
    streams = data.get("streams", [])
    fmt = data.get("format", {})
    video_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
    audio_stream = next((s for s in streams if s.get("codec_type") == "audio"), None)

    duration = float(fmt.get("duration") or video_stream.get("duration") or 0)
    fmt_tags = fmt.get("tags") or {}
    stream_tags = video_stream.get("tags") or {}
    creation_time = (
        fmt_tags.get("creation_time")
        or stream_tags.get("creation_time")
        or fmt_tags.get("date")
    )
    return {
        "duration_seconds": duration,
        "width": video_stream.get("width"),
        "height": video_stream.get("height"),
        "codec": video_stream.get("codec_name"),
        "size_bytes": int(fmt.get("size") or 0),
        "has_audio": audio_stream is not None,
        "has_video": bool(video_stream),
        "creation_time": creation_time,
    }


def auto_fps(duration_seconds: float, max_frames: int = 100) -> tuple[float, int]:
    """Pick fps that targets a sensible frame budget for full-video scans."""
    if duration_seconds <= 0:
        return 1.0, 1

    if duration_seconds <= 30:
        target = min(max_frames, max(12, int(round(duration_seconds))))
    elif duration_seconds <= 60:
        target = min(max_frames, 40)
    elif duration_seconds <= 180:  # 3 min
        target = min(max_frames, 60)
    elif duration_seconds <= 600:  # 10 min
        target = min(max_frames, 80)
    else:
        target = max_frames

    return _clamp_fps(target / duration_seconds, duration_seconds, max_frames)


def auto_fps_focus(duration_seconds: float, max_frames: int = 100) -> tuple[float, int]:
    """Denser budget for user-specified ranges - they are zooming in for detail."""
    if duration_seconds <= 0:
        return min(MAX_FPS, 2.0), 2

    if duration_seconds <= 5:
        target = min(max_frames, max(10, int(round(duration_seconds * 6))))
    elif duration_seconds <= 15:
        target = min(max_frames, max(30, int(round(duration_seconds * 4))))
    elif duration_seconds <= 30:
        target = min(max_frames, 60)
    elif duration_seconds <= 60:
        target = min(max_frames, 80)
    elif duration_seconds <= 180:
        target = max_frames
    else:
        target = max_frames

    return _clamp_fps(target / duration_seconds, duration_seconds, max_frames)


def extract(
    video_path: str,
    out_dir: Path,
    fps: float,
    resolution: int = 512,
    max_frames: int = 100,
    start_seconds: float | None = None,
    end_seconds: float | None = None,
) -> list[dict]:
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    for existing in out_dir.glob("frame_*.jpg"):
        existing.unlink()

    output_pattern = str(out_dir / "frame_%04d.jpg")
    cmd: list[str] = [
        ffmpeg,
        "-hide_banner",
        "-loglevel", "error",
        "-y",
    ]

    # -ss before -i = fast seek (keyframe-snap, good enough for preview frames).
    if start_seconds is not None:
        cmd += ["-ss", f"{start_seconds:.3f}"]
    if end_seconds is not None:
        cmd += ["-to", f"{end_seconds:.3f}"]

    cmd += [
        "-i", video_path,
        "-vf", f"fps={fps},scale={resolution}:-2",
        "-frames:v", str(max_frames),
        "-q:v", "4",
        output_pattern,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"ffmpeg frame extraction failed: {result.stderr.strip()}")

    offset = start_seconds or 0.0
    frames = sorted(out_dir.glob("frame_*.jpg"))
    return [
        {
            "timestamp_seconds": round(offset + (i / fps if fps > 0 else 0.0), 2),
            "path": str(p),
            "kind": "regular",
        }
        for i, p in enumerate(frames)
    ]


def _kneedle_threshold(scores: list[float], floor: float = 5.0) -> float:
    """Pick a content-aware scdet threshold via knee-point detection.

    scdet score distributions are extremely heavy-tailed: 99 %+ of frames sit at
    near-zero (residual motion) and a few hundred sit on a long tail (real cuts).
    Naive kneedle on the full sorted-descending curve gets dragged into the noise
    floor, so we truncate to the top `max(50, N//200)` scores (capped at 1000)
    and find the knee there. Returns at least `floor` so static videos with no
    real cuts don't have noise misclassified.
    """
    if not scores:
        return floor
    s_sorted = sorted(scores, reverse=True)
    n = len(s_sorted)
    head_size = min(max(50, n // 200), 1000, n)
    head = s_sorted[:head_size]
    h_n = len(head)
    if h_n < 3:
        return max(head[-1], floor)
    h_max, h_min = head[0], head[-1]
    if h_max - h_min < 1e-6:
        return max(h_max, floor)
    span_y, span_x = h_max - h_min, h_n - 1
    best_idx, best = 0, -1.0
    for i, y in enumerate(head):
        d = (h_max - y) * span_x - span_y * i
        if d > best:
            best, best_idx = d, i
    return max(head[best_idx], floor)


def detect_cuts(
    video_path: str,
    threshold: float | None = None,
    min_gap: float = 2.0,
    start_seconds: float | None = None,
    end_seconds: float | None = None,
    floor: float = 5.0,
) -> tuple[list[float], float]:
    """Run an scdet pass; return (cut timestamps, threshold used).

    If `threshold` is None, the threshold is auto-detected from the score
    distribution itself via knee-point detection (content-aware). Otherwise the
    explicit value is applied as-is. `floor` is the minimum auto-threshold -
    on static videos with no real cuts the knee can drop into noise; the floor
    prevents that.
    """
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )

    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as tf:
        meta_path = tf.name
    try:
        # ffmpeg uses *two* levels of escaping in filter graphs (per
        # ffmpeg-utils(1) "Quoting and escaping"):
        #   - level 1 (filter chain): `\`, `,`, `;` are special
        #   - level 2 (filter arg):   `\`, `:`, `'` are special
        # A literal `:` in a filter argument value must survive both passes,
        # so it has to be written as `\\:` (3 bytes) - level 1 eats one `\`,
        # leaving `\:`; level 2 eats the other `\`, leaving `:` as literal.
        # Single-quote wrapping does NOT work - ffmpeg's filter-arg parser
        # doesn't honor `'...'` as a literal-string delimiter despite older
        # docs implying it does.
        # Strategy: convert backslashes to forward slashes first (ffmpeg
        # accepts both on Windows), then double-backslash-escape any colon
        # left over from the Windows drive letter.
        meta_path_for_filter = meta_path.replace("\\", "/").replace(":", r"\\:")
        cmd: list[str] = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
        if start_seconds is not None:
            cmd += ["-ss", f"{start_seconds:.3f}"]
        if end_seconds is not None:
            cmd += ["-to", f"{end_seconds:.3f}"]
        cmd += [
            "-i", video_path,
            "-vf", f"scdet=threshold=0,metadata=mode=print:file={meta_path_for_filter}",
            "-an", "-f", "null", "-",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(f"ffmpeg scdet failed: {result.stderr.strip()}")

        offset = start_seconds or 0.0
        text = Path(meta_path).read_text()
    finally:
        Path(meta_path).unlink(missing_ok=True)

    pattern = re.compile(
        r"pts_time:(\d+(?:\.\d+)?).*?lavfi\.scd\.score=(\d+(?:\.\d+)?)",
        re.S,
    )
    pairs = [(round(offset + float(t), 3), float(s)) for t, s in pattern.findall(text)]

    used_threshold = (
        threshold
        if threshold is not None
        else _kneedle_threshold([s for _, s in pairs], floor=floor)
    )

    raw = sorted({t for t, s in pairs if s >= used_threshold})

    filtered: list[float] = []
    last = float("-inf")
    for t in raw:
        if t - last >= min_gap:
            filtered.append(t)
            last = t
    return filtered, used_threshold


def _hash_sidecar_path(jpeg_path: Path) -> Path:
    """Return the path of the 9x8 grayscale raw file that lives next to a JPEG."""
    return jpeg_path.with_suffix(".gray9x8")


def _renumber_kept_frames(kept: list[dict], out_dir: Path) -> list[dict]:
    """Rename surviving regular-frame JPEGs so their indices are gap-free.

    Dedup leaves filenames like `frame_0001`, `frame_0017`, `frame_0019` -
    chronologically correct but visually broken in a directory listing
    and in the report. Renumber them to `frame_0001`, `frame_0002`,
    `frame_0003` while keeping the `_tNNNNNs` timestamp suffix so
    "which moment did this come from?" stays answerable from the name.

    Two-phase rename via a temporary suffix avoids collisions when the
    new name happens to equal an existing not-yet-renamed file's name.
    """
    if not kept:
        return kept
    # Phase 1: move every kept JPEG to a `.tmp-<i>` name, capturing the
    # original timestamp tag from the old filename.
    pattern = re.compile(r"frame_\d+_(t\d+s)\.jpg$")
    temp_paths: list[tuple[dict, Path, str]] = []
    for new_i, f in enumerate(kept, start=1):
        old_path = Path(f["path"])
        m = pattern.search(old_path.name)
        ts_tag = m.group(1) if m else f"t{int(f['timestamp_seconds']):05d}s"
        tmp_name = f"frame_{new_i:04d}_{ts_tag}.jpg.tmprename"
        tmp_path = out_dir / tmp_name
        try:
            old_path.rename(tmp_path)
        except OSError:
            # Rename failed - leave the old file in place and skip this entry.
            # Keeps the original path in the dict so downstream Read still works.
            temp_paths.append((f, old_path, ""))
            continue
        temp_paths.append((f, tmp_path, ts_tag))
    # Phase 2: strip the `.tmprename` suffix to land at the final names.
    for f, tmp_path, ts_tag in temp_paths:
        if not ts_tag:
            continue  # rename failed earlier
        final_name = tmp_path.name[: -len(".tmprename")]
        final_path = tmp_path.parent / final_name
        try:
            tmp_path.rename(final_path)
        except OSError:
            f["path"] = str(tmp_path)
            continue
        f["path"] = str(final_path)
    return kept


def _extract_one_frame(
    ffmpeg: str,
    video_path: str,
    seek_t: float,
    out_path: Path,
    resolution: int,
    produce_hash: bool = False,
) -> bool:
    """Run a single ffmpeg fast-seek-and-extract. Returns True on success.

    When `produce_hash=True`, also writes a 72-byte 9x8 grayscale raw file
    alongside the JPEG (same basename, `.gray9x8` extension). Same ffmpeg
    call, no extra decode cost - `split` duplicates the decoded frame to
    two scale chains. Used by `_dedup_regular_frames` afterwards.
    """
    if produce_hash:
        cmd = [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-ss", f"{seek_t:.3f}",
            "-i", video_path,
            "-filter_complex",
            f"[0:v]split=2[a][b];"
            f"[a]scale={resolution}:-2[jpg];"
            f"[b]scale=9:8,format=gray[hash]",
            "-map", "[jpg]", "-frames:v", "1", "-q:v", "4", str(out_path),
            "-map", "[hash]", "-frames:v", "1", "-f", "rawvideo",
            "-pix_fmt", "gray", str(_hash_sidecar_path(out_path)),
        ]
    else:
        cmd = [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-ss", f"{seek_t:.3f}",
            "-i", video_path,
            "-frames:v", "1",
            "-vf", f"scale={resolution}:-2",
            "-q:v", "4",
            str(out_path),
        ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0 and out_path.exists()


def _dhash_from_file(path: Path) -> int | None:
    """Compute 64-bit dHash from a 9x8 grayscale raw file (72 bytes).

    The hash is a bitmap of 64 "is left pixel brighter than right pixel?"
    comparisons across the 8 rows of 8 pixel-pairs. Returns None when the
    sidecar is missing or the wrong size - caller treats that as "unknown,
    keep the frame to be safe".
    """
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 72:
        return None
    h = 0
    for row in range(8):
        base = row * 9
        for col in range(8):
            if data[base + col] > data[base + col + 1]:
                h |= 1 << (row * 8 + col)
    return h


def _auto_dedup_threshold(
    distances: list[int],
    floor: int = 3,
    ceiling: int = 12,
) -> int:
    """Pick a dedup threshold via knee-point detection on sorted distances.

    Hamming-distance distributions between consecutive frames are typically
    bimodal: a dense low cluster (near-duplicates, JPEG noise, mouse jitter)
    and a sparser high cluster (real content changes). The cliff between
    them is the natural threshold.

    Method: sort distances ascending, then find the point with maximum
    perpendicular distance to the chord connecting (0, min) and (n-1, max).
    That's the elbow - the value right at the transition. Add 1 so the
    threshold falls strictly inside the gap rather than on the last
    duplicate.

    Clamped to [floor, ceiling] so degenerate distributions (all-similar
    static videos, or extremely cut-heavy montages) don't produce absurd
    thresholds.
    """
    if len(distances) < 5:
        return 6  # not enough data, fall back to the previous fixed default
    s = sorted(distances)
    n = len(s)
    if s[-1] - s[0] < 3:
        # No meaningful spread -> likely a near-static video, drop only the
        # most extreme duplicates.
        return floor
    x_hi = n - 1
    y_lo, y_hi = s[0], s[-1]
    max_dev = -1.0
    elbow_i = 0
    for i in range(n):
        line_y = y_lo + (y_hi - y_lo) * i / x_hi
        dev = abs(s[i] - line_y)
        if dev > max_dev:
            max_dev = dev
            elbow_i = i
    # +1 so we land strictly inside the gap, not on the last duplicate value.
    return max(floor, min(ceiling, s[elbow_i] + 1))


def _dedup_regular_frames(
    extracted: list[dict],
    threshold: "int | str" = "auto",
) -> tuple[list[dict], int, int, dict]:
    """Drop frames whose dHash is within `threshold` bits of the last kept one.

    `threshold` is either an int (fixed) or "auto" (knee-point detection
    on the distance distribution). The actual threshold used is returned
    as part of the result tuple so the caller can log it.

    Walks chronologically. Comparison anchor is the **last kept** hash, not
    the immediate predecessor - that way a slow drift over many frames
    still ends up with one frame from the cluster rather than every Nth.

    Returns `(kept_frames, dropped_count, threshold_used, stats)` where
    `stats` is a small dict with distribution summary statistics
    (`n_pairs`, `median`, `p90`, `max`) - useful for diagnostic output
    so the user can see where the cliff actually lives.

    Removes both the JPEG and its `.gray9x8` sidecar from disk for dropped
    frames; cleans up the sidecars of kept frames at the end too.
    """
    if not extracted:
        return [], 0, 0, {"n_pairs": 0, "median": 0, "p90": 0, "max": 0}

    # Read all hashes upfront so we can both auto-threshold and walk in one go.
    hashes: list["int | None"] = []
    for f in extracted:
        hashes.append(_dhash_from_file(_hash_sidecar_path(Path(f["path"]))))

    # Distances between *consecutive* frames (not last-kept) - that's the
    # right shape for distribution analysis and knee-point detection.
    pair_distances: list[int] = []
    for i in range(1, len(hashes)):
        a, b = hashes[i - 1], hashes[i]
        if a is not None and b is not None:
            pair_distances.append(bin(a ^ b).count("1"))

    if isinstance(threshold, str) and threshold == "auto":
        used_threshold = _auto_dedup_threshold(pair_distances)
    else:
        used_threshold = int(threshold)

    # Distribution stats for diagnostic logging.
    if pair_distances:
        sd = sorted(pair_distances)
        stats = {
            "n_pairs": len(sd),
            "median": sd[len(sd) // 2],
            "p90": sd[min(len(sd) - 1, int(len(sd) * 0.9))],
            "max": sd[-1],
        }
    else:
        stats = {"n_pairs": 0, "median": 0, "p90": 0, "max": 0}

    kept: list[dict] = []
    last_hash: "int | None" = None
    dropped = 0

    for f, this_hash in zip(extracted, hashes):
        jpeg_path = Path(f["path"])
        hash_path = _hash_sidecar_path(jpeg_path)

        # Keep when:
        #   - first frame (nothing to compare against)
        #   - this_hash unreadable (be safe, don't drop)
        #   - hash distance >= threshold (genuinely different)
        if last_hash is None or this_hash is None:
            kept.append(f)
            if this_hash is not None:
                last_hash = this_hash
            continue

        distance = bin(last_hash ^ this_hash).count("1")
        if distance >= used_threshold:
            kept.append(f)
            last_hash = this_hash
        else:
            jpeg_path.unlink(missing_ok=True)
            hash_path.unlink(missing_ok=True)
            dropped += 1

    # Sweep the .gray9x8 sidecars of survivors - their job is done.
    for f in kept:
        _hash_sidecar_path(Path(f["path"])).unlink(missing_ok=True)

    return kept, dropped, used_threshold, stats


def extract_at_timestamps(
    video_path: str,
    out_dir: Path,
    timestamps: list[float],
    kind: str = "regular",
    resolution: int = 512,
    settle_seconds: float = 1.0,
    workers: int | None = None,
    dedup_threshold: "int | str | None" = None,
) -> list[dict]:
    """Extract one JPEG per timestamp via fast-seek (`-ss` before `-i`).

    `kind` controls filename convention and the returned dicts' "kind" field:
      - "regular" -> `frame_NNNN_tNNNNNs.jpg` (timestamp baked in for sortability)
      - "cut"     -> `cut_NNN_tNNNNNs.jpg`   (timestamp baked in for sortability)
    Both kinds carry the source timestamp in their filename so a directory
    listing alone tells you when each frame was sampled from.

    `settle_seconds` only applies to `kind="cut"`. scdet flags the moment a
    pixel-diff spike crosses threshold - but UI transitions (a launcher
    opening, a dialog rendering) often need 0.5–2 s before the new content
    is actually visible, so a t-0.05 seek lands on a loading/black state.
    Seeking at `t + settle_seconds` lets the new shot settle. The seek is
    capped at `next_cut - 0.3 s` so we never bleed into the following shot.
    Set settle_seconds=0 to revert to the old just-before-cut behavior.
    The filename always carries the ORIGINAL cut timestamp t so chronology
    in the report matches the detected event, not the post-settle extraction.

    `workers` controls thread-pool parallelism for the per-frame ffmpeg
    subprocesses. None -> auto (`_default_workers()`); pass 1 to force
    sequential extraction (useful on HDDs or for benchmark comparison).
    Each worker spawns one ffmpeg process; subprocess.run releases the GIL
    while waiting, so threads - not multiprocessing - are the right tool.

    `dedup_threshold`, if not None, enables dHash-based deduplication of
    near-identical frames (only applies to `kind="regular"` - cut frames
    are a separate signal and never deduped). The threshold is the
    minimum Hamming distance between a frame's 64-bit dHash and the last
    kept frame's hash; smaller distances mean "near-identical" and the
    frame is dropped. Sensible default is 6 (drops mouse jitter / JPEG
    noise but keeps real content changes). Producing the hash is free -
    same ffmpeg call, an extra `split` output. After dedup, the .gray9x8
    sidecars are cleaned up.
    """
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    glob_pattern = "cut_*.jpg" if kind == "cut" else "frame_*.jpg"
    for existing in out_dir.glob(glob_pattern):
        existing.unlink()

    # Build the job table up front. seek_t computation depends on neighboring
    # timestamps (for cut-mode settle clamping), so it's sequential - but the
    # actual ffmpeg subprocess calls are independent and run in parallel.
    jobs: list[tuple[int, float, float, Path]] = []
    for idx, t in enumerate(timestamps):
        i = idx + 1  # 1-indexed for filename consistency
        if kind == "cut" and settle_seconds > 0:
            next_t = timestamps[idx + 1] if idx + 1 < len(timestamps) else float("inf")
            seek_t = min(t + settle_seconds, next_t - 0.3)
            seek_t = max(seek_t, t)  # never seek before t itself
        else:
            seek_t = max(0.0, t - 0.05)

        name = (
            f"cut_{i:03d}_t{int(t):05d}s.jpg" if kind == "cut"
            else f"frame_{i:04d}_t{int(t):05d}s.jpg"
        )
        jobs.append((i, t, seek_t, out_dir / name))

    if not jobs:
        return []

    n_workers = workers if workers is not None else _default_workers()
    n_workers = max(1, min(n_workers, len(jobs)))

    # Dedup only applies to regular frames; cut frames are an explicit
    # scene-change signal and shouldn't be deduplicated against each other.
    use_dedup = (kind == "regular") and (dedup_threshold is not None)

    def run_job(job: tuple[int, float, float, Path]) -> tuple[int, float, Path, bool]:
        i, t, seek_t, path = job
        ok = _extract_one_frame(
            ffmpeg, video_path, seek_t, path, resolution,
            produce_hash=use_dedup,
        )
        return i, t, path, ok

    if n_workers == 1:
        results = [run_job(j) for j in jobs]
    else:
        with ThreadPoolExecutor(max_workers=n_workers) as pool:
            results = list(pool.map(run_job, jobs))

    extracted: list[dict] = []
    for i, t, path, ok in results:
        if not ok:
            continue
        extracted.append({
            "timestamp_seconds": round(t, 2),
            "path": str(path),
            "kind": kind,
        })

    if use_dedup and extracted:
        kept, dropped, used_thr, stats = _dedup_regular_frames(
            extracted, threshold=dedup_threshold,
        )
        # Diagnostic: surface the distribution so the user can sanity-check
        # the chosen threshold (whether auto or fixed).
        if stats["n_pairs"] > 0:
            print(
                f"[transcribe] dedup distances: median={stats['median']}, "
                f"p90={stats['p90']}, max={stats['max']} "
                f"(n={stats['n_pairs']} consecutive pairs)",
                file=sys.stderr,
            )
        threshold_label = (
            f"{used_thr} auto"
            if isinstance(dedup_threshold, str) and dedup_threshold == "auto"
            else str(used_thr)
        )
        print(
            f"[transcribe] dedup: kept {len(kept)} of {len(extracted)} regular "
            f"frames (threshold {threshold_label}, dropped {dropped} "
            f"near-duplicates)",
            file=sys.stderr,
        )
        return _renumber_kept_frames(kept, out_dir)

    return extracted


def extract_cuts(
    video_path: str,
    out_dir: Path,
    cut_times: list[float],
    resolution: int = 512,
    max_cuts: int = 80,
    settle_seconds: float = 1.0,
    workers: int | None = None,
) -> list[dict]:
    """Extract one JPEG per cut timestamp. Thin wrapper over `extract_at_timestamps`.

    `settle_seconds` shifts extraction to `t + settle_seconds` so UI transitions
    have time to render before we grab the frame (capped by the next cut).
    `workers` controls thread-pool parallelism (see `extract_at_timestamps`).
    """
    return extract_at_timestamps(
        video_path, out_dir, cut_times[:max_cuts],
        kind="cut", resolution=resolution,
        settle_seconds=settle_seconds, workers=workers,
    )


def gap_fill_timestamps(
    cut_times: list[float],
    start_seconds: float,
    end_seconds: float,
    target: int,
    min_gap_for_fill: float | None = None,
) -> list[float]:
    """Distribute `target` regular sampling points into the gaps between cuts.

    Each gap receives a number of frames proportional to its length. Gaps shorter
    than `min_gap_for_fill` are skipped (they're already covered by adjacent cut
    frames; sampling there would be redundant). If `min_gap_for_fill` is None,
    it defaults to `(duration / target) / 2` - i.e. don't fill gaps that are
    smaller than half the average sampling interval.

    When `cut_times` is empty, this collapses to uniform sampling over [start, end]
    - same effective behaviour as the old fixed-fps path.
    """
    if target <= 0 or end_seconds <= start_seconds:
        return []

    inner = sorted(t for t in cut_times if start_seconds < t < end_seconds)
    boundaries = [start_seconds] + inner + [end_seconds]
    gaps = [(boundaries[i], boundaries[i + 1]) for i in range(len(boundaries) - 1)]

    duration = end_seconds - start_seconds
    if min_gap_for_fill is None:
        min_gap_for_fill = max(2.0, duration / max(target, 1) / 2)

    eligible = [(a, b) for a, b in gaps if (b - a) >= min_gap_for_fill]
    if not eligible:
        return []

    total_eligible = sum(b - a for a, b in eligible)
    raw = [(a, b, target * (b - a) / total_eligible) for a, b in eligible]
    counts = [int(x) for _, _, x in raw]
    used = sum(counts)
    # Largest-remainder allocation to hit exactly `target`
    remainders = sorted(
        ((i, raw[i][2] - counts[i]) for i in range(len(raw))),
        key=lambda r: -r[1],
    )
    for i, _ in remainders[: max(0, target - used)]:
        counts[i] += 1

    timestamps: list[float] = []
    for (a, b, _), n in zip(raw, counts):
        if n <= 0:
            continue
        gap_len = b - a
        for j in range(n):
            timestamps.append(a + (j + 0.5) * gap_len / n)
    return sorted(timestamps)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(
            "usage: frames.py <video-path> <out-dir> [--fps F] [--resolution W] "
            "[--max-frames N] [--start T] [--end T]",
            file=sys.stderr,
        )
        raise SystemExit(2)

    video = sys.argv[1]
    out = Path(sys.argv[2])
    args = sys.argv[3:]

    fps_override = None
    resolution = 512
    max_frames = 100
    start_arg = None
    end_arg = None
    i = 0
    while i < len(args):
        if args[i] == "--fps":
            fps_override = float(args[i + 1]); i += 2
        elif args[i] == "--resolution":
            resolution = int(args[i + 1]); i += 2
        elif args[i] == "--max-frames":
            max_frames = int(args[i + 1]); i += 2
        elif args[i] == "--start":
            start_arg = args[i + 1]; i += 2
        elif args[i] == "--end":
            end_arg = args[i + 1]; i += 2
        else:
            i += 1

    meta = get_metadata(video)
    start_sec = parse_time(start_arg)
    end_sec = parse_time(end_arg)
    full_duration = meta["duration_seconds"]

    effective_start = start_sec if start_sec is not None else 0.0
    effective_end = end_sec if end_sec is not None else full_duration
    effective_duration = max(0.0, effective_end - effective_start)

    focused = start_sec is not None or end_sec is not None
    if focused:
        fps, target = auto_fps_focus(effective_duration, max_frames=max_frames)
    else:
        fps, target = auto_fps(effective_duration, max_frames=max_frames)
    if fps_override is not None:
        fps = fps_override
        target = max(1, int(round(fps * effective_duration)))

    frames = extract(
        video, out,
        fps=fps,
        resolution=resolution,
        max_frames=max_frames,
        start_seconds=start_sec,
        end_seconds=end_sec,
    )
    print(json.dumps(
        {"meta": meta, "fps": fps, "target": target, "focused": focused, "frames": frames},
        indent=2,
    ))
