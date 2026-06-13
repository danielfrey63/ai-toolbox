#!/usr/bin/env python3
"""Speech-to-text for /transcribe (the STT module).

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
import re
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
from transcribe import merge_speaker_turns


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
# Override via run.py's --whisper-workers N (then this fallback is bypassed).
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


# ---------------------------------------------------------------------------
# Azure gpt-4o-transcribe-diarize + claude-opus-4-7 reconciliation defaults.
# All overridable via ~/.config/transcribe/.env - see .env.example.
# ---------------------------------------------------------------------------
# Per-chunk audio length for the duration-chunked Azure backend. NOT the
# model's ~1500 s hard cap: gpt-4o-transcribe-diarize processing time scales
# ~quadratically with chunk length (a 600 s chunk measured ~150 s of API
# time, a 1400 s chunk blew past a 900 s timeout). Many small chunks finish
# faster overall and never time out - 600 s is the proven-fast size.
AZURE_CHUNK_SECONDS_DEFAULT = 600.0
AZURE_OVERLAP_SECONDS_DEFAULT = 20.0
AZURE_TIMEOUT_DEFAULT = 900.0
# Anthropic model (on the Azure AI Foundry passthrough) used to reconcile
# chunk-local speaker labels into a handful of real speakers.
AZURE_CLAUDE_MODEL = "claude-opus-4-7"


def _get_config(name: str) -> str | None:
    """Look up a config value: `$NAME` first, then ~/.config/transcribe/.env, then
    ./.env. Surrounding quotes on .env values are stripped. None if unset.

    The single config reader for the whole STT module - Whisper keys, the
    Azure endpoint/key pairs and the tuning knobs all come through here.
    """
    value = os.environ.get(name)
    if value and value.strip():
        return value.strip()
    for path in (Path.home() / ".config" / "transcribe" / ".env", Path.cwd() / ".env"):
        if not path.exists():
            continue
        try:
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, raw = line.partition("=")
                if key.strip() != name:
                    continue
                raw = raw.strip()
                if len(raw) >= 2 and raw[0] in ('"', "'") and raw[-1] == raw[0]:
                    raw = raw[1:-1]
                return raw or None
        except OSError:
            return None
    return None


def _get_config_float(name: str, default: float) -> float:
    """`_get_config` coerced to float, falling back to `default` on an unset
    or unparseable value."""
    raw = _get_config(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        print(
            f"[transcribe] WARNING: {name}={raw!r} is not a number - using {default}",
            file=sys.stderr,
        )
        return default


def load_api_key(preferred: str | None = None) -> tuple[str, str] | tuple[None, None]:
    """Return (provider, api_key) for Whisper. Prefers Groq, falls back to
    OpenAI. With `preferred` ("groq"/"openai"), only that provider is tried."""
    candidates = (("GROQ_API_KEY", "groq"), ("OPENAI_API_KEY", "openai"))
    if preferred is not None:
        candidates = tuple(c for c in candidates if c[1] == preferred)
    for key_name, provider in candidates:
        value = _get_config(key_name)
        if value:
            return provider, value
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


def _plan_duration_windows(
    duration: float, chunk_seconds: float, overlap_seconds: float
) -> list[tuple[float, float]]:
    """Partition [0, duration] into overlapping (start, end) windows of at
    most `chunk_seconds`. Adjacent windows share `overlap_seconds` so a
    sentence on a chunk boundary survives intact in one of them."""
    if duration <= chunk_seconds:
        return [(0.0, duration)]
    stride = max(chunk_seconds - overlap_seconds, chunk_seconds * 0.5)
    windows: list[tuple[float, float]] = []
    t = 0.0
    while t < duration:
        end = min(t + chunk_seconds, duration)
        windows.append((t, end))
        if end >= duration:
            break
        t += stride
    return windows


def _chunk_audio_by_duration(
    audio_path: Path,
    chunks_dir: Path,
    chunk_seconds: float,
    overlap_seconds: float,
) -> list[tuple[float, Path]]:
    """Split audio into overlapping duration-bounded chunks for backends with
    a hard audio-length limit (Azure gpt-4o-transcribe-diarize).

    Returns `[(start_offset_seconds, chunk_path), ...]`. If the audio already
    fits within `chunk_seconds`, returns `[(0.0, audio_path)]` unchanged.

    Uses `-c copy`: the input is an already-compact 16 kHz mono mp3, so a
    stream copy is fast and the ~20 s overlap dwarfs any seek imprecision.
    """
    duration = _probe_duration(audio_path)
    windows = _plan_duration_windows(duration, chunk_seconds, overlap_seconds)
    if len(windows) == 1:
        return [(0.0, audio_path)]

    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg is not installed. Run `python3 scripts/setup.py --install-binaries`."
        )
    chunks_dir.mkdir(parents=True, exist_ok=True)
    chunks: list[tuple[float, Path]] = []
    for i, (start, end) in enumerate(windows):
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
                f"ffmpeg chunk extraction failed (chunk {i}): {result.stderr.strip()}"
            )
        if not chunk_path.exists() or chunk_path.stat().st_size == 0:
            raise SystemExit(f"audio chunk {i} produced an empty file")
        chunks.append((start, chunk_path))
    return chunks


def _stitch_chunked_segments(
    chunk_results: list[tuple[float, list[dict]]],
    overlap_seconds: float = CHUNK_OVERLAP_SECONDS,
    tag_speakers: bool = False,
) -> list[dict]:
    """Merge per-chunk segments onto one global timeline.

    Each chunk's local timestamps are shifted by its start offset. At a
    boundary the overlap is cut at its midpoint - inclusively on BOTH sides,
    so a segment whose two overlap copies straddle the midpoint is never
    lost (worst case it survives twice; the text-dedup pass below collapses
    the duplicate - losing transcript text is unrecoverable, a stray
    duplicate is not).

    `tag_speakers`: when the backend diarizes per-chunk, speaker labels are
    chunk-local (the same person may be "A" in chunk 1 and "B" in chunk 2).
    Tagging them `C1-A`, `C2-B`, ... keeps them distinct so the downstream
    reconciliation step can resolve identity globally. A `speaker` field is
    always preserved through the stitch when present.
    """
    if not chunk_results:
        return []

    merged: list[dict] = []
    for idx, (offset, segments) in enumerate(chunk_results):
        shifted: list[dict] = []
        for seg in segments:
            out = {
                "start": round(seg["start"] + offset, 2),
                "end": round(seg["end"] + offset, 2),
                "text": seg["text"],
            }
            speaker = seg.get("speaker")
            if speaker is not None:
                out["speaker"] = f"C{idx + 1}-{speaker}" if tag_speakers else speaker
            shifted.append(out)
        if idx == 0:
            merged = shifted
            continue
        cut = offset + overlap_seconds / 2.0
        merged = [s for s in merged if s["start"] <= cut]
        merged += [s for s in shifted if s["start"] >= cut]

    merged.sort(key=lambda s: s["start"])

    deduped: list[dict] = []
    for seg in merged:
        if (deduped and deduped[-1]["text"] == seg["text"]
                and abs(deduped[-1]["start"] - seg["start"]) < overlap_seconds):
            continue
        deduped.append(seg)
    return deduped


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
    boundary = f"----TranscribeBoundary{uuid.uuid4().hex}"
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
        "User-Agent": "transcribe-skill/1.0 (+claude-code; python-urllib)",
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
                    f"[transcribe] whisper HTTP {exc.code} - retrying in {delay:.1f}s "
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
                    f"[transcribe] whisper network error ({type(exc).__name__}: {exc}) - "
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


# ===========================================================================
# Azure gpt-4o-transcribe-diarize: one call does transcription AND speaker
# diarization. Audio over ~1500 s is rejected, so long audio is duration-
# chunked and each chunk diarized independently - producing chunk-local
# speaker labels that reconcile_speakers() (below) resolves globally.
# ===========================================================================

def _post_azure_diarize(url: str, key: str, audio_path: Path, timeout: float) -> dict:
    """POST one audio file to gpt-4o-transcribe-diarize, return parsed JSON.

    `chunking_strategy=auto` and `response_format=diarized_json` are both
    required by the endpoint (it 400s without them). Raises SystemExit on
    any HTTP or network failure - a read timeout means the chunk is too
    long for the model's processing speed.
    """
    fields = {"chunking_strategy": "auto", "response_format": "diarized_json"}
    body, boundary = _build_multipart(fields, audio_path)
    headers = {
        "api-key": key,
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": "transcribe-skill/1.0 (+claude-code; python-urllib)",
    }
    request = Request(url, data=body, headers=headers, method="POST")
    context = ssl.create_default_context()
    try:
        with urlopen(request, timeout=timeout, context=context) as response:
            payload = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"Azure transcribe-diarize HTTP {exc.code}{_read_error_body(exc)}"
        )
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
        raise SystemExit(
            f"Azure transcribe-diarize network failure: {type(exc).__name__}: {exc}. "
            "If this is a read timeout the chunk exceeds the model's processing "
            "speed - lower AZURE_TRANSCRIBE_CHUNK_SECONDS or raise "
            "AZURE_TRANSCRIBE_TIMEOUT."
        )
    try:
        return json.loads(payload)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"Azure transcribe-diarize returned non-JSON: {exc}: {payload[:200]}"
        )


def _parse_diarized_json(data: dict) -> list[dict]:
    """Convert a diarized_json response into {start,end,text,speaker} segments.

    gpt-4o-transcribe-diarize emits data["segments"][i] with start/end/text
    and a single-letter `speaker`. Field-name variants are tolerated in case
    a future backend (MAI-Transcribe-1) differs slightly.
    """
    out: list[dict] = []
    for seg in data.get("segments") or []:
        if not isinstance(seg, dict):
            continue
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        try:
            start = float(seg.get("start", seg.get("start_time", 0.0)) or 0.0)
            end = float(seg.get("end", seg.get("end_time", 0.0)) or 0.0)
        except (TypeError, ValueError):
            start, end = 0.0, 0.0
        speaker = (
            seg.get("speaker") or seg.get("speaker_id")
            or seg.get("speaker_label") or "?"
        )
        out.append({
            "start": round(start, 2), "end": round(end, 2),
            "text": text, "speaker": str(speaker),
        })
    if not out:
        full = (data.get("text") or "").strip()
        if full:
            out.append({"start": 0.0, "end": 0.0, "text": full, "speaker": "?"})
    return out


# ===========================================================================
# Cross-chunk speaker reconciliation via claude-opus-4-7
#
# Each chunk is diarized independently, so labels are chunk-local (C1-A,
# C2-B, ...): the same real person appears under many labels, and the
# diarizer even over-splits one person within a single chunk. claude reads
# every label's text and collapses them to a handful of real speakers.
# ===========================================================================

def reconcile_available() -> tuple[bool, str]:
    """(configured, reason). Speaker reconciliation needs AZURE_CLAUDE_URL +
    AZURE_CLAUDE_KEY. `reason` names what is missing when not configured."""
    url = _get_config("AZURE_CLAUDE_URL")
    key = _get_config("AZURE_CLAUDE_KEY")
    if url and key:
        return True, ""
    missing = [n for n, v in (("AZURE_CLAUDE_URL", url), ("AZURE_CLAUDE_KEY", key)) if not v]
    return False, f"{' + '.join(missing)} not set"


def _post_claude(url: str, key: str, prompt: str, max_tokens: int = 2048) -> tuple[int, str]:
    """POST to the Anthropic Messages API (Azure AI Foundry passthrough).

    Returns (status, body); status 0 = network failure. Both `x-api-key`
    (Anthropic-native) and `api-key` (Azure-style) are sent - the server
    honours whichever it expects and ignores the other.
    """
    payload = json.dumps({
        "model": AZURE_CLAUDE_MODEL,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")
    headers = {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
        "x-api-key": key,
        "api-key": key,
    }
    request = Request(url, data=payload, headers=headers, method="POST")
    context = ssl.create_default_context()
    try:
        with urlopen(request, timeout=300, context=context) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace") if exc.fp else ""
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
        return 0, f"network failure: {type(exc).__name__}: {exc}"


def _build_reconcile_prompt(turns: list[dict]) -> str:
    """Build the reconciliation prompt from chunk-tagged speaker turns."""
    by_spk: dict[str, list[str]] = {}
    for turn in turns:
        by_spk.setdefault(turn["speaker"], []).append(turn["text"])
    blocks = []
    for spk in sorted(by_spk):
        full = " ".join(by_spk[spk]).strip()
        sample = full if len(full) <= 800 else full[:800] + " [...]"
        blocks.append(f'- "{spk}" ({len(full)} chars total): {sample}')
    speaker_block = "\n".join(blocks)
    return (
        "A meeting recording was transcribed in chunks; each chunk was "
        "diarized independently, so speaker labels are chunk-local "
        "(\"C1-A\" = chunk 1, speaker A). The same real person therefore "
        "appears under many labels - and the diarizer also over-splits one "
        "person within a single chunk. Below is a text sample per label.\n\n"
        "Decide which labels are the SAME real person. Return ONLY a JSON "
        "object, no prose, no markdown fence:\n"
        '{"mapping": {"C1-A": "S1", "C1-C": "S1", "C1-B": "S2", ...}, '
        '"names": {"S1": "<name or null>", "S2": null, ...}}\n\n'
        "Rules:\n"
        "- Map EVERY label to a global speaker S1, S2, S3, ...\n"
        "- A long technical monologue split across labels is almost always "
        "one person - merge aggressively when the content/voice-role fits.\n"
        "- In `names`, give a real first name ONLY when the text clearly "
        "reveals it (someone is addressed directly - \"Andrea, ...\" - or "
        "signs off by name). Otherwise null.\n\n"
        f"Labels:\n{speaker_block}"
    )


def _parse_claude_mapping(body: str) -> tuple[dict[str, str], dict[str, str]]:
    """Extract (mapping, names) from a Claude Messages response body."""
    data = json.loads(body)
    text = "".join(
        b.get("text", "") for b in data.get("content", [])
        if isinstance(b, dict) and b.get("type") == "text"
    )
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        raise ValueError(f"no JSON object in Claude reply: {text[:200]}")
    obj = json.loads(match.group(0))
    return obj.get("mapping", {}) or {}, obj.get("names", {}) or {}


def reconcile_speakers(segments: list[dict]) -> list[dict]:
    """Collapse chunk-local speaker labels (C1-A, C2-B, ...) into a handful
    of real speakers via claude-opus-4-7, rewriting each segment's `speaker`.

    On ANY failure (no config, HTTP error, unparseable reply) the chunk-
    tagged labels are kept and a warning printed: a usable transcript with
    ugly labels beats losing the whole run to a reconciliation hiccup.
    Mutates and returns `segments`.
    """
    ok, reason = reconcile_available()
    if not ok:
        print(f"[transcribe] speaker reconciliation skipped: {reason}", file=sys.stderr)
        return segments
    url = _get_config("AZURE_CLAUDE_URL")
    key = _get_config("AZURE_CLAUDE_KEY")

    print(f"[transcribe] reconciling speaker labels via {AZURE_CLAUDE_MODEL}...", file=sys.stderr)
    status, body = _post_claude(url, key, _build_reconcile_prompt(merge_speaker_turns(segments)))
    if status != 200:
        print(
            f"[transcribe] speaker reconciliation failed (claude HTTP {status}) - "
            f"keeping chunk-tagged labels: {body[:200]}",
            file=sys.stderr,
        )
        return segments
    try:
        mapping, names = _parse_claude_mapping(body)
    except (json.JSONDecodeError, ValueError) as exc:
        print(
            f"[transcribe] could not parse reconciliation reply ({exc}) - "
            "keeping chunk-tagged labels",
            file=sys.stderr,
        )
        return segments

    for seg in segments:
        glob = mapping.get(seg.get("speaker"), seg.get("speaker"))
        seg["speaker"] = names.get(glob) or glob
    n_global = len({(names.get(g) or g) for g in mapping.values()}) if mapping else 0
    print(
        f"[transcribe] reconciled {len(mapping)} chunk-tagged labels into "
        f"{n_global} speaker(s) via {AZURE_CLAUDE_MODEL}",
        file=sys.stderr,
    )
    return segments


# ===========================================================================
# Pluggable STT backends
#
# Each backend declares a chunking + diarization policy and implements two
# operations: call the API for one within-limit audio file, and parse that
# response into {start,end,text,speaker?} segments. The generic orchestrator
# (transcribe_audio) does everything else - chunk planning, parallel uploads,
# stitching, speaker reconciliation - so adding a backend (Azure
# transcribe-diarize, MAI-Transcribe-1, ...) never re-implements the pipeline.
# ===========================================================================


class STTBackend:
    """Base class for a speech-to-text backend.

    A concrete backend sets the policy attributes below and implements
    available() + transcribe_one(). It never touches chunking or stitching:
    that is the orchestrator's job, keyed off these policy attributes.
    """

    name = "base"

    # Chunking policy. `chunk_by`:
    #   "size"     - split when the audio file exceeds `chunk_limit` megabytes
    #   "duration" - split when the audio exceeds `chunk_limit` seconds
    #   None       - never split; the backend accepts the whole file
    chunk_by: str | None = None
    chunk_limit: float | None = None
    # Audio shared between adjacent chunks so a boundary-straddling sentence
    # survives intact in one of them.
    chunk_overlap: float = CHUNK_OVERLAP_SECONDS

    # Diarization policy - drives post-processing in transcribe_audio:
    #   "none"      - no speaker labels in the output
    #   "per-chunk" - labels are chunk-local; cross-chunk reconciliation needed
    #   "global"    - labels are already consistent across the whole file
    diarization = "none"

    def available(self) -> tuple[bool, str]:
        """Return (configured, reason). `reason` is a human hint when the
        backend cannot run (e.g. a missing key) and "" when it can."""
        raise NotImplementedError

    def transcribe_one(self, audio_path: Path) -> list[dict]:
        """Transcribe ONE audio file already within the chunk limit. Return
        segments [{start,end,text, speaker?}] with chunk-local timestamps."""
        raise NotImplementedError


class WhisperBackend(STTBackend):
    """Groq / OpenAI Whisper - transcription only, no speaker labels.

    Both providers expose the identical multipart `audio/transcriptions`
    API; they differ only in endpoint, model name and which key they read,
    so one class serves both - selected by the `provider` argument.
    """

    chunk_by = "size"
    chunk_limit = CHUNK_TARGET_BYTES / (1024 * 1024)  # MB
    diarization = "none"

    _PROVIDERS = {
        "groq": (GROQ_ENDPOINT, GROQ_MODEL, "GROQ_API_KEY"),
        "openai": (OPENAI_ENDPOINT, OPENAI_MODEL, "OPENAI_API_KEY"),
    }

    def __init__(self, provider: str, api_key: str | None = None):
        if provider not in self._PROVIDERS:
            raise SystemExit(
                f"Unknown Whisper provider: {provider!r} "
                f"(expected one of {', '.join(self._PROVIDERS)})"
            )
        self.provider = provider
        self.name = provider
        self.endpoint, self.model, self.key_name = self._PROVIDERS[provider]
        self._api_key = api_key

    def _key(self) -> str | None:
        if self._api_key is None:
            _, self._api_key = load_api_key(self.provider)
        return self._api_key

    def available(self) -> tuple[bool, str]:
        return (True, "") if self._key() else (False, f"{self.key_name} not set")

    def transcribe_one(self, audio_path: Path) -> list[dict]:
        key = self._key()
        if not key:
            raise SystemExit(f"{self.key_name} not set")
        return _segments_from_response(
            _post_whisper(self.endpoint, key, self.model, audio_path)
        )


class AzureDiarizeBackend(STTBackend):
    """Azure OpenAI gpt-4o-transcribe-diarize - transcription + speaker
    diarization in one call, on a private Azure tenant.

    The endpoint rejects audio over ~1500 s and processing time scales
    super-linearly with chunk length, so audio is duration-chunked into
    AZURE_TRANSCRIBE_CHUNK_SECONDS-long pieces (default 600 s). Each chunk
    is diarized independently -> chunk-local speaker labels; the orchestrator
    chunk-tags them and reconcile_speakers() resolves identity globally.
    All knobs are read from ~/.config/transcribe/.env at construction.
    """

    name = "azure-diarize"
    chunk_by = "duration"
    diarization = "per-chunk"

    def __init__(self):
        self.url = _get_config("AZURE_TRANSCRIBE_DIARIZE_URL")
        self.key = _get_config("AZURE_TRANSCRIBE_DIARIZE_KEY")
        self.chunk_limit = _get_config_float(
            "AZURE_TRANSCRIBE_CHUNK_SECONDS", AZURE_CHUNK_SECONDS_DEFAULT
        )
        self.chunk_overlap = _get_config_float(
            "AZURE_TRANSCRIBE_OVERLAP_SECONDS", AZURE_OVERLAP_SECONDS_DEFAULT
        )
        self.timeout = _get_config_float(
            "AZURE_TRANSCRIBE_TIMEOUT", AZURE_TIMEOUT_DEFAULT
        )

    def available(self) -> tuple[bool, str]:
        if self.url and self.key:
            return True, ""
        missing = [
            n for n, v in (
                ("AZURE_TRANSCRIBE_DIARIZE_URL", self.url),
                ("AZURE_TRANSCRIBE_DIARIZE_KEY", self.key),
            ) if not v
        ]
        return False, f"{' + '.join(missing)} not set"

    def transcribe_one(self, audio_path: Path) -> list[dict]:
        if not self.url or not self.key:
            raise SystemExit("AZURE_TRANSCRIBE_DIARIZE_URL / _KEY not set")
        return _parse_diarized_json(
            _post_azure_diarize(self.url, self.key, audio_path, self.timeout)
        )


class WhisperLocalBackend(STTBackend):
    """faster-whisper in the managed ML venv - fully on-device transcription.

    No API key, nothing leaves the machine: the right default for
    confidential recordings. Heavy lifting happens in
    `whisper_local_worker.py` inside the venv that setup.ensure_venv()
    provisions on first use (large-v3 on CUDA, medium/int8 CPU fallback).
    ctranslate2 streams arbitrary-length audio, so no chunking is needed.
    """

    name = "whisper-local"
    chunk_by = None  # faster-whisper handles arbitrary length itself
    diarization = "none"

    def available(self) -> tuple[bool, str]:
        # Always available: the venv self-provisions on first use (with
        # clear progress on stderr). Sits last in BACKEND_FACTORIES so
        # auto-selection prefers configured cloud backends.
        return True, ""

    def transcribe_one(self, audio_path: Path) -> list[dict]:
        import json as _json

        from setup import run_venv_worker

        stdout = run_venv_worker("whisper_local_worker.py", [str(audio_path)])
        try:
            return _json.loads(stdout)
        except ValueError as exc:
            raise SystemExit(
                f"whisper_local_worker returned invalid JSON ({exc}): "
                f"{stdout[-300:]}"
            )


# Backend factories in auto-selection priority order - LOCAL FIRST: nothing
# leaves the machine unless the local path actually fails, then the cascade
# moves on to the configured cloud backends (private Azure tenant before the
# public Whisper APIs). Factories (not instances) so construction - and
# config lookup - is deferred until a backend is actually chosen.
BACKEND_FACTORIES = {
    "whisper-local": lambda: WhisperLocalBackend(),
    "azure-diarize": lambda: AzureDiarizeBackend(),
    "groq": lambda: WhisperBackend("groq"),
    "openai": lambda: WhisperBackend("openai"),
}


def get_backend(name: str) -> STTBackend:
    """Construct the named backend, or SystemExit if the name is unknown."""
    factory = BACKEND_FACTORIES.get(name)
    if factory is None:
        raise SystemExit(
            f"Unknown STT backend: {name!r} (have: {', '.join(BACKEND_FACTORIES)})"
        )
    return factory()


def select_backend(preferred: str | None = None) -> STTBackend | None:
    """Pick a configured STT backend.

    With `preferred`, return exactly that backend (SystemExit if it is
    unknown or not configured). Otherwise return the first backend in
    BACKEND_FACTORIES order that has a key, or None if none are configured.
    """
    if preferred:
        backend = get_backend(preferred)
        ok, reason = backend.available()
        if not ok:
            raise SystemExit(f"STT backend {preferred!r} is not configured: {reason}")
        return backend
    for name in BACKEND_FACTORIES:
        backend = get_backend(name)
        ok, _ = backend.available()
        if ok:
            return backend
    return None


def select_backends(preferred: str | None = None) -> list[STTBackend]:
    """Resolve the STT cascade: every backend to try, in order.

    With `preferred`, the user pinned one backend - no cascade (explicit
    choices fail loudly, they don't silently degrade). Otherwise return ALL
    configured backends in BACKEND_FACTORIES order; the caller tries them
    one after another until a transcription succeeds.
    """
    if preferred:
        return [select_backend(preferred)]
    out: list[STTBackend] = []
    for name in BACKEND_FACTORIES:
        backend = get_backend(name)
        ok, _ = backend.available()
        if ok:
            out.append(backend)
    return out


def _plan_chunks(
    audio_path: Path, backend: STTBackend, chunks_dir: Path
) -> list[tuple[float, Path]]:
    """Split `audio_path` per the backend's chunking policy. Returns
    `[(start_offset_seconds, chunk_path), ...]` - a single entry when the
    audio is within the backend's limit and no split is needed."""
    if backend.chunk_by is None:
        return [(0.0, audio_path)]
    if backend.chunk_by == "size":
        max_bytes = int((backend.chunk_limit or 20) * 1024 * 1024)
        return _chunk_audio(
            audio_path, chunks_dir, max_bytes=max_bytes,
            overlap_seconds=backend.chunk_overlap,
        )
    if backend.chunk_by == "duration":
        return _chunk_audio_by_duration(
            audio_path, chunks_dir,
            backend.chunk_limit or AZURE_CHUNK_SECONDS_DEFAULT,
            backend.chunk_overlap,
        )
    raise SystemExit(f"unknown chunk_by policy: {backend.chunk_by!r}")


def _transcribe_chunks(
    chunks: list[tuple[float, Path]],
    backend: STTBackend,
    parallel_uploads: int | None,
    tag_speakers: bool = False,
) -> list[dict]:
    """Transcribe each chunk (parallel-aware) and stitch onto one timeline.

    `tag_speakers` is forwarded to the stitcher: per-chunk-diarizing backends
    need chunk-local speaker labels kept distinct for later reconciliation.
    """
    if parallel_uploads is not None:
        configured = parallel_uploads
    elif len(chunks) == 2:
        # Adaptive: 2 chunks is safely under any tier's per-hour audio quota
        # even uploaded in parallel, and the speedup roughly halves time.
        configured = 2
    else:
        configured = WHISPER_PARALLEL_UPLOADS  # 1, sequential
    n_workers = max(1, min(configured, len(chunks)))
    mode = "sequential" if n_workers == 1 else f"{n_workers} parallel"
    print(
        f"[transcribe] splitting into {len(chunks)} chunks "
        f"({backend.chunk_overlap:.0f}s overlap, {mode} uploads)...",
        file=sys.stderr,
    )

    def run_chunk(indexed: tuple[int, tuple[float, Path]]) -> tuple[float, list[dict]]:
        i, (offset, chunk_path) = indexed
        chunk_size_kb = chunk_path.stat().st_size / 1024
        print(
            f"[transcribe] chunk {i + 1}/{len(chunks)} "
            f"(t={offset:.0f}s, {chunk_size_kb:.0f} kB) -> {backend.name}...",
            file=sys.stderr,
        )
        return offset, backend.transcribe_one(chunk_path)

    if n_workers == 1:
        chunk_results = [run_chunk(item) for item in enumerate(chunks)]
    else:
        # Stagger submits by WHISPER_STAGGER_S so we don't slam the upload
        # endpoint with N simultaneous bursts. Cheap insurance - wall-clock
        # is dominated by the longest upload, not by when each one starts.
        with ThreadPoolExecutor(max_workers=n_workers) as pool:
            futures = []
            for i, chunk in enumerate(chunks):
                if i > 0:
                    time.sleep(WHISPER_STAGGER_S)
                futures.append(pool.submit(run_chunk, (i, chunk)))
            # Collect by future-completion order, then re-sort by offset for
            # the stitcher which expects ascending start times.
            chunk_results = [fut.result() for fut in futures]
            chunk_results.sort(key=lambda pair: pair[0])
    return _stitch_chunked_segments(
        chunk_results, overlap_seconds=backend.chunk_overlap, tag_speakers=tag_speakers
    )


def preflight(backend: STTBackend, audio_seconds: float) -> list[str]:
    """Validate everything a transcription run will need, BEFORE any audio
    extraction or API call. Returns human-readable problems (empty = good).

    The point: a misconfigured run fails here in well under a second
    instead of after a 25-minute chunk upload. Checks the chosen STT
    backend is usable, and - when the run will be multi-chunk on a
    per-chunk-diarizing backend - that the claude-opus-4-7 reconciliation
    backend is configured too (otherwise the speaker labels can never be
    resolved and the long transcription would be wasted).
    """
    problems: list[str] = []
    ok, reason = backend.available()
    if not ok:
        problems.append(f"STT backend '{backend.name}' not usable: {reason}")

    will_chunk = (
        backend.chunk_by == "duration"
        and backend.chunk_limit
        and audio_seconds > backend.chunk_limit
    )
    if will_chunk and backend.diarization == "per-chunk":
        rok, rreason = reconcile_available()
        if not rok:
            problems.append(
                f"audio is {audio_seconds:.0f}s - backend '{backend.name}' will "
                f"split it into multiple chunks and diarize each independently, "
                f"so cross-chunk speaker reconciliation is required, but {rreason}"
            )
    return problems


def transcribe_audio(
    audio_path: Path,
    backend: STTBackend,
    chunks_dir: Path | None = None,
    parallel_uploads: int | None = None,
) -> list[dict]:
    """Generic STT orchestration for one audio file.

    Runs pre-flight checks, then chunks per the backend's policy,
    transcribes each chunk, stitches onto one timeline, and - when the
    backend diarizes per-chunk - reconciles speaker labels across chunks.
    Returns {start,end,text,speaker?} segments. Every backend goes through
    this path.
    """
    chunks_dir = chunks_dir or (audio_path.parent / "audio_chunks")

    # Pre-flight: probe duration only when it can change the plan (a
    # duration-chunked backend), then validate config BEFORE any API call.
    audio_seconds = (
        _probe_duration(audio_path) if backend.chunk_by == "duration" else 0.0
    )
    problems = preflight(backend, audio_seconds)
    if problems:
        raise SystemExit(
            "pre-flight checks failed - fix these before re-running:\n  - "
            + "\n  - ".join(problems)
        )

    chunks = _plan_chunks(audio_path, backend, chunks_dir)
    size_kb = audio_path.stat().st_size / 1024

    if len(chunks) == 1:
        print(
            f"[transcribe] audio: {size_kb:.0f} kB - transcribing via {backend.name}...",
            file=sys.stderr,
        )
        return backend.transcribe_one(chunks[0][1])

    tag = backend.diarization == "per-chunk"
    segments = _transcribe_chunks(chunks, backend, parallel_uploads, tag_speakers=tag)
    if tag:
        segments = reconcile_speakers(segments)
    return segments


def transcribe_video(
    video_path: str,
    audio_out: Path,
    backend: str | None = None,
    api_key: str | None = None,
    parallel_uploads: int | None = None,
) -> tuple[list[dict], str]:
    """Extract audio from a video, then transcribe it.

    Thin convenience wrapper over `transcribe_audio` for callers that start
    from a video file (run.py). `backend` is a backend name; when given
    with `api_key`, that key is injected so .env is not re-read. Returns
    (segments, backend_name). Raises SystemExit on any failure.
    """
    if backend in ("groq", "openai"):
        stt: STTBackend | None = WhisperBackend(backend, api_key=api_key)
    elif backend:
        stt = get_backend(backend)
    else:
        stt = select_backend()

    if stt is None:
        setup_py = Path(__file__).resolve().parent / "setup.py"
        raise SystemExit(
            "No Whisper API key available. Set GROQ_API_KEY (preferred) or "
            "OPENAI_API_KEY in the environment or in ~/.config/transcribe/.env. "
            f"Run `python3 {setup_py}` to configure."
        )

    print(f"[transcribe] extracting audio for transcription ({stt.name})...", file=sys.stderr)
    audio_path = extract_audio(video_path, audio_out)
    segments = transcribe_audio(
        audio_path, stt, audio_out.parent / "audio_chunks", parallel_uploads
    )
    if not segments:
        raise SystemExit("transcription returned no transcript segments")
    print(f"[transcribe] transcribed {len(segments)} segments via {stt.name}", file=sys.stderr)
    return segments, stt.name


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(
            "usage: stt.py <video-or-audio> [<audio-out.mp3>] "
            f"[--backend {'|'.join(BACKEND_FACTORIES)}]",
            file=sys.stderr,
        )
        raise SystemExit(2)

    source = sys.argv[1]
    audio_out = (
        Path(sys.argv[2])
        if len(sys.argv) > 2 and not sys.argv[2].startswith("--")
        else Path("audio.mp3")
    )
    backend_override = None
    if "--backend" in sys.argv:
        backend_override = sys.argv[sys.argv.index("--backend") + 1]

    from transcribe import format_transcript

    segments, used = transcribe_video(source, audio_out, backend=backend_override)
    print(f"\n[stt] transcript via {used} ({len(segments)} segments)\n", file=sys.stderr)
    print(format_transcript(segments))
