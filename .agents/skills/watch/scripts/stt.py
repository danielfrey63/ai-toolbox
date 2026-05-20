#!/usr/bin/env python3
"""Speech-to-text for /watch (the STT module).

Currently: Groq / OpenAI Whisper. Extracts audio (mono 16kHz mp3, tiny
payload), auto-splits oversized audio, uploads to whichever API has a key,
and returns segments in the same shape as transcribe.parse_vtt so the rest
of the pipeline (filter_range, format_transcript) doesn't care where the
transcript came from.

This module will grow a pluggable STT-backend registry (Azure
gpt-4o-transcribe-diarize, AssemblyAI, MAI-Transcribe-1) - hence the rename
from whisper.py: the module is no longer Whisper-specific.

Pure stdlib - no `pip install groq` or `pip install openai` needed.
"""
from __future__ import annotations

import io
import json
import math
import mimetypes
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import Request, urlopen

from setup import find_tool


# Parallel uploads for chunked audio.
#
# Default is "adaptive":
#   - 2 chunks -> parallel (well under typical hourly quotas, real speedup).
#   - 3+ chunks -> sequential (3 simultaneous uploads of ~30-min audio each
#     burst Groq's audio-second buckets; observed Retry-After of 533 s in
#     the wild, making the sad path slower than just running them serially).
#
# The 2-chunk parallel case adds a small startup stagger (WHISPER_STAGGER_S)
# between the two `pool.submit` calls so they don't both hit the upload
# endpoint at the exact same instant - cheap insurance against burst
# detection at no real cost (total wall time is dominated by the longer
# upload, not by when each one starts).
#
# Override via watch.py's --whisper-workers N (then this fallback is bypassed).
WHISPER_PARALLEL_UPLOADS = 1
WHISPER_STAGGER_S = 3.0


GROQ_ENDPOINT = "https://api.groq.com/openai/v1/audio/transcriptions"
GROQ_MODEL = "whisper-large-v3"

OPENAI_ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"
OPENAI_MODEL = "whisper-1"

# Whisper APIs cap multipart uploads at 25 MB. Target 20 MB per chunk so the
# multipart envelope (boundary, headers) stays comfortably under the limit.
WHISPER_UPLOAD_LIMIT_BYTES = 25 * 1024 * 1024
CHUNK_TARGET_BYTES = 20 * 1024 * 1024
# Overlap is wide enough that a sentence cut by the chunk boundary is fully
# captured in at least one of the two adjacent chunks. The stitcher drops the
# second chunk's copy at the midpoint of the overlap.
CHUNK_OVERLAP_SECONDS = 20.0


def load_api_key(preferred: str | None = None) -> tuple[str, str] | tuple[None, None]:
    """Return (backend, api_key). Prefers Groq, falls back to OpenAI.

    If `preferred` is "groq" or "openai", only that backend's key is considered.
    """
    def _from_env(name: str) -> str | None:
        value = os.environ.get(name)
        return value.strip() if value else None

    def _from_dotenv(path: Path, name: str) -> str | None:
        if not path.exists():
            return None
        try:
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if key.strip() != name:
                    continue
                value = value.strip()
                if len(value) >= 2 and value[0] in ('"', "'") and value[-1] == value[0]:
                    value = value[1:-1]
                return value or None
        except OSError:
            return None
        return None

    dotenv_paths = [
        Path.home() / ".config" / "watch" / ".env",
        Path.cwd() / ".env",
    ]

    candidates = (("GROQ_API_KEY", "groq"), ("OPENAI_API_KEY", "openai"))
    if preferred is not None:
        candidates = tuple(c for c in candidates if c[1] == preferred)

    for key_name, backend in candidates:
        value = _from_env(key_name)
        if not value:
            for candidate in dotenv_paths:
                value = _from_dotenv(candidate, key_name)
                if value:
                    break
        if value:
            return backend, value

    return None, None


def _probe_duration(audio_path: Path) -> float:
    """Read audio duration in seconds via ffprobe."""
    ffprobe = find_tool("ffprobe")
    if ffprobe is None:
        raise SystemExit(
            "ffprobe is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )
    result = subprocess.run(
        [
            ffprobe, "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(audio_path),
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise SystemExit(
            f"ffprobe failed on {audio_path}: {result.stderr.strip()}"
        )
    return float(result.stdout.strip())


def _chunk_audio(
    audio_path: Path,
    chunks_dir: Path,
    max_bytes: int = CHUNK_TARGET_BYTES,
    overlap_seconds: float = CHUNK_OVERLAP_SECONDS,
) -> list[tuple[float, Path]]:
    """Split audio for Whisper's 25 MB upload limit, with overlap.

    Returns `[(start_offset_seconds, chunk_path), ...]`. If the file already
    fits under `max_bytes`, returns `[(0.0, audio_path)]` unchanged.

    Strategy: evenly split into `ceil(size / max_bytes)` chunks, then extend
    each chunk by `overlap_seconds` so adjacent chunks share that much audio.
    The stitcher uses the overlap midpoint as the cut, so a sentence broken
    by the chunk boundary is fully captured in at least one chunk.

    Uses `-c copy` for fast cuts - sample-accuracy within the overlap is
    irrelevant because the overlap is much wider than any seek imprecision.
    """
    size = audio_path.stat().st_size
    if size <= max_bytes:
        return [(0.0, audio_path)]

    duration = _probe_duration(audio_path)
    num_chunks = max(2, math.ceil(size / max_bytes))
    base_chunk_seconds = duration / num_chunks
    overlap = min(overlap_seconds, base_chunk_seconds * 0.5)
    chunk_seconds = base_chunk_seconds + overlap

    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )

    chunks_dir.mkdir(parents=True, exist_ok=True)
    chunks: list[tuple[float, Path]] = []

    for i in range(num_chunks):
        start = i * base_chunk_seconds
        end = min(start + chunk_seconds, duration)
        chunk_path = chunks_dir / f"chunk_{i:03d}.mp3"
        cmd = [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-ss", f"{start:.3f}",
            "-i", str(audio_path),
            "-t", f"{end - start:.3f}",
            "-c", "copy",
            str(chunk_path),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(
                f"ffmpeg chunk extraction failed (chunk {i}): "
                f"{result.stderr.strip()}"
            )
        if not chunk_path.exists() or chunk_path.stat().st_size == 0:
            raise SystemExit(f"audio chunk {i} produced an empty file")
        chunks.append((start, chunk_path))

    return chunks


def _stitch_chunked_segments(
    chunk_results: list[tuple[float, list[dict]]],
    overlap_seconds: float = CHUNK_OVERLAP_SECONDS,
) -> list[dict]:
    """Merge per-chunk Whisper segments onto one timeline.

    Each chunk's segments are shifted by its start offset. At a boundary,
    segments from the second chunk whose `start` falls before the overlap
    midpoint are dropped - the first chunk already covered that audio. A
    final pass collapses any consecutive duplicate texts that survive at
    the seam (Whisper sometimes re-emits boundary phrases).
    """
    if not chunk_results:
        return []

    out: list[dict] = []
    for i, (offset, segments) in enumerate(chunk_results):
        shifted = [
            {
                "start": round(seg["start"] + offset, 2),
                "end": round(seg["end"] + offset, 2),
                "text": seg["text"],
            }
            for seg in segments
        ]
        if i == 0:
            out.extend(shifted)
            continue
        cut_at = offset + overlap_seconds / 2.0
        out.extend(seg for seg in shifted if seg["start"] >= cut_at)

    deduped: list[dict] = []
    for seg in out:
        if deduped and seg["text"] == deduped[-1]["text"]:
            deduped[-1]["end"] = seg["end"]
            continue
        deduped.append(seg)
    return deduped


def _post(backend: str, api_key: str, audio_path: Path) -> dict:
    """Dispatch a single Whisper upload to the matching backend."""
    if backend == "groq":
        return _post_whisper(GROQ_ENDPOINT, api_key, GROQ_MODEL, audio_path)
    if backend == "openai":
        return _post_whisper(OPENAI_ENDPOINT, api_key, OPENAI_MODEL, audio_path)
    raise SystemExit(f"Unknown whisper backend: {backend}")


def extract_audio(video_path: str, out_path: Path) -> Path:
    """Extract mono 16kHz 64kbps mp3 - ~480 kB/min, fits any Whisper limit."""
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", video_path,
        "-vn",
        "-acodec", "libmp3lame",
        "-ar", "16000",
        "-ac", "1",
        "-b:a", "64k",
        str(out_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"ffmpeg audio extraction failed: {result.stderr.strip()}")
    if not out_path.exists() or out_path.stat().st_size == 0:
        raise SystemExit("ffmpeg produced no audio - video may have no audio track")
    return out_path


def _build_multipart(fields: dict[str, str], file_path: Path) -> tuple[bytes, str]:
    """Assemble a multipart/form-data body the Whisper APIs accept.

    Whisper's multipart upload is small and predictable - doing it by hand
    keeps us on pure stdlib instead of pulling requests/groq/openai SDKs.
    """
    boundary = f"----WatchBoundary{uuid.uuid4().hex}"
    eol = b"\r\n"
    buf = io.BytesIO()

    for name, value in fields.items():
        buf.write(f"--{boundary}".encode()); buf.write(eol)
        buf.write(f'Content-Disposition: form-data; name="{name}"'.encode()); buf.write(eol)
        buf.write(eol)
        buf.write(str(value).encode()); buf.write(eol)

    mimetype = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    buf.write(f"--{boundary}".encode()); buf.write(eol)
    buf.write(
        f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"'.encode()
    )
    buf.write(eol)
    buf.write(f"Content-Type: {mimetype}".encode()); buf.write(eol)
    buf.write(eol)
    buf.write(file_path.read_bytes())
    buf.write(eol)
    buf.write(f"--{boundary}--".encode()); buf.write(eol)

    return buf.getvalue(), boundary


MAX_ATTEMPTS = 4       # initial + 3 retries
MAX_429_RETRIES = 2
RETRY_BASE_DELAY = 2.0


def _post_whisper(endpoint: str, api_key: str, model: str, audio_path: Path) -> dict:
    fields = {
        "model": model,
        "response_format": "verbose_json",
        "temperature": "0",
    }
    body, boundary = _build_multipart(fields, audio_path)
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        # Groq sits behind Cloudflare - the default `Python-urllib/3.x` UA
        # trips WAF rule 1010 (403) before auth even runs. Any non-default
        # UA clears it; we identify honestly.
        "User-Agent": "watch-skill/1.0 (+claude-code; python-urllib)",
    }

    context = ssl.create_default_context()
    rate_limit_hits = 0
    last_exc: Exception | None = None
    last_detail = ""

    for attempt in range(MAX_ATTEMPTS):
        request = Request(endpoint, data=body, headers=headers, method="POST")
        try:
            with urlopen(request, timeout=300, context=context) as response:
                payload = response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            detail = _read_error_body(exc)
            last_exc, last_detail = exc, detail

            # 4xx other than 429 are client errors - no retry will fix them.
            if 400 <= exc.code < 500 and exc.code != 429:
                raise SystemExit(f"Whisper request failed: {exc}{detail}")

            if exc.code == 429:
                rate_limit_hits += 1
                if rate_limit_hits >= MAX_429_RETRIES:
                    raise SystemExit(f"Whisper request failed: {exc}{detail}")
                delay = _retry_after(exc) or RETRY_BASE_DELAY * (2 ** attempt) + 1
            else:
                delay = RETRY_BASE_DELAY * (2 ** attempt)

            if attempt < MAX_ATTEMPTS - 1:
                print(
                    f"[watch] whisper HTTP {exc.code} - retrying in {delay:.1f}s "
                    f"(attempt {attempt + 2}/{MAX_ATTEMPTS})",
                    file=sys.stderr,
                )
                time.sleep(delay)
            continue
        except (urllib.error.URLError, TimeoutError, ConnectionResetError, OSError) as exc:
            last_exc, last_detail = exc, ""
            if attempt < MAX_ATTEMPTS - 1:
                delay = RETRY_BASE_DELAY * (attempt + 1)
                print(
                    f"[watch] whisper network error ({type(exc).__name__}: {exc}) - "
                    f"retrying in {delay:.1f}s (attempt {attempt + 2}/{MAX_ATTEMPTS})",
                    file=sys.stderr,
                )
                time.sleep(delay)
            continue

        try:
            return json.loads(payload)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Whisper returned non-JSON response: {exc}: {payload[:200]}")

    raise SystemExit(
        f"Whisper request failed after {MAX_ATTEMPTS} attempts: {last_exc}{last_detail}"
    )


def _read_error_body(exc: urllib.error.HTTPError) -> str:
    try:
        body = exc.read()
    except Exception:
        return ""
    if not body:
        return ""
    try:
        return f" - {body.decode('utf-8', errors='replace')[:400]}"
    except Exception:
        return ""


def _retry_after(exc: urllib.error.HTTPError) -> float | None:
    header = exc.headers.get("Retry-After") if getattr(exc, "headers", None) else None
    if not header:
        return None
    try:
        return float(header)
    except ValueError:
        return None


def _segments_from_response(data: dict) -> list[dict]:
    """Convert Whisper verbose_json into our {start, end, text} segment format."""
    out: list[dict] = []
    for seg in data.get("segments") or []:
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        out.append({
            "start": round(float(seg.get("start") or 0.0), 2),
            "end": round(float(seg.get("end") or 0.0), 2),
            "text": text,
        })

    if not out:
        full = (data.get("text") or "").strip()
        if full:
            out.append({"start": 0.0, "end": 0.0, "text": full})

    return out


def transcribe_video(
    video_path: str,
    audio_out: Path,
    backend: str | None = None,
    api_key: str | None = None,
    parallel_uploads: int | None = None,
) -> tuple[list[dict], str]:
    """Run the full flow: extract audio -> upload -> parse segments.

    Returns (segments, backend_used). Raises SystemExit on any failure.

    `parallel_uploads` controls how many chunk uploads run concurrently
    in the multi-chunk path. None -> `WHISPER_PARALLEL_UPLOADS` (default 1).
    Beyond 1-2 you risk Groq/OpenAI rate limits; see the constant's
    docstring for the tradeoff.
    """
    if backend is None or api_key is None:
        detected_backend, detected_key = load_api_key()
        backend = backend or detected_backend
        api_key = api_key or detected_key

    if not backend or not api_key:
        setup_py = Path(__file__).resolve().parent / "setup.py"
        raise SystemExit(
            "No Whisper API key available. Set GROQ_API_KEY (preferred) or OPENAI_API_KEY "
            "in the environment or in ~/.config/watch/.env. "
            f"Run `python3 {setup_py}` to configure."
        )

    print(f"[watch] extracting audio for Whisper ({backend})...", file=sys.stderr)
    audio_path = extract_audio(video_path, audio_out)
    size_kb = audio_path.stat().st_size / 1024

    chunks = _chunk_audio(audio_path, audio_out.parent / "audio_chunks")

    if len(chunks) == 1:
        print(
            f"[watch] audio: {size_kb:.0f} kB - uploading to {backend} Whisper...",
            file=sys.stderr,
        )
        response = _post(backend, api_key, chunks[0][1])
        segments = _segments_from_response(response)
    else:
        if parallel_uploads is not None:
            configured = parallel_uploads
        elif len(chunks) == 2:
            # Adaptive: 2 chunks is safely under any tier's per-hour audio
            # quota even when uploaded in parallel, and the speedup roughly
            # halves transcription time.
            configured = 2
        else:
            configured = WHISPER_PARALLEL_UPLOADS  # 1, sequential
        n_workers = max(1, min(configured, len(chunks)))
        mode = "sequential" if n_workers == 1 else f"{n_workers} parallel"
        print(
            f"[watch] audio: {size_kb:.0f} kB exceeds Whisper upload limit - "
            f"splitting into {len(chunks)} chunks "
            f"({CHUNK_OVERLAP_SECONDS:.0f}s overlap, {mode} uploads)...",
            file=sys.stderr,
        )

        def run_chunk(indexed: tuple[int, tuple[float, Path]]) -> tuple[float, list[dict]]:
            i, (offset, chunk_path) = indexed
            chunk_size_kb = chunk_path.stat().st_size / 1024
            print(
                f"[watch] chunk {i + 1}/{len(chunks)} "
                f"(t={offset:.0f}s, {chunk_size_kb:.0f} kB) -> {backend}...",
                file=sys.stderr,
            )
            response = _post(backend, api_key, chunk_path)
            return offset, _segments_from_response(response)

        if n_workers == 1:
            chunk_results = [run_chunk(item) for item in enumerate(chunks)]
        else:
            # Stagger submits by WHISPER_STAGGER_S so we don't slam the
            # upload endpoint with N simultaneous bursts. Cheap insurance
            # - wall-clock is dominated by the longest upload, not by when
            # each one starts. Order preserved via pool.submit + sorted index.
            with ThreadPoolExecutor(max_workers=n_workers) as pool:
                futures = []
                for i, chunk in enumerate(chunks):
                    if i > 0:
                        time.sleep(WHISPER_STAGGER_S)
                    futures.append(pool.submit(run_chunk, (i, chunk)))
                # Collect by future-completion order, then re-sort by offset
                # for the stitcher which expects ascending start times.
                chunk_results = [fut.result() for fut in futures]
                chunk_results.sort(key=lambda pair: pair[0])
        segments = _stitch_chunked_segments(chunk_results)

    if not segments:
        raise SystemExit("Whisper returned no transcript segments")

    print(f"[watch] transcribed {len(segments)} segments via {backend}", file=sys.stderr)
    return segments, backend


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: stt.py <video-path> [<audio-out.mp3>] [--backend groq|openai]", file=sys.stderr)
        raise SystemExit(2)

    video = sys.argv[1]
    audio_out = Path(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else Path("audio.mp3")
    backend_override = None
    if "--backend" in sys.argv:
        backend_override = sys.argv[sys.argv.index("--backend") + 1]

    segments, backend = transcribe_video(video, audio_out, backend=backend_override)
    print(json.dumps({"backend": backend, "segments": segments}, indent=2))
