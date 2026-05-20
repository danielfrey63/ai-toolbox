#!/usr/bin/env python3
"""Diagnostic + prototype: transcribe an audio file via an Azure transcription
endpoint, dump the raw response, and - for long audio - run the full
chunk -> transcribe -> stitch -> speaker-reconcile -> per-speaker-concat
pipeline that the production watch.py azure backend will use.

Two purposes:
  1. Probe a backend (quality, response schema, duration limit, timing).
  2. Validate the multi-chunk stitching + cross-chunk speaker reconciliation
     on real audio before that logic is ported into stt.py.

Backends (`--backend`):
  diarize  Azure OpenAI gpt-4o-transcribe-diarize. Env vars:
             AZURE_TRANSCRIBE_DIARIZE_URL   full URL incl. ?api-version=...
             AZURE_TRANSCRIBE_DIARIZE_KEY   api-key
           Known: 1500 s audio limit; needs chunking_strategy + response_format.
  mai      Microsoft MAI-Transcribe-1. Env vars:
             MAI_TRANSCRIBE_URL / MAI_TRANSCRIBE_KEY
           Limits/required-fields unknown - use --no-trim to probe them.

Config is read from environment variables OR ~/.config/watch/.env (./.env too).

Usage (Windows: use `python`, not `python3`):
  python azure_transcribe_test.py <audio-file> [options]

  --backend {diarize,mai}   Which endpoint. Default: diarize.
  --no-trim                 Send the whole file in ONE call - no duration
                            trim, no chunking. Use this to discover a
                            backend's real duration limit (the server's
                            error names it). Oversized files are still
                            downsampled to fit the 24 MB upload cap.
  --max-seconds N           Cap total input audio to the first N seconds
                            before anything else (a deliberately quick test).
  --chunk-seconds N         Chunk length when long audio is chunked
                            (default 600 = 10 min). NOT the model's 1500s
                            max: diarization time scales ~quadratically with
                            chunk length, so many small chunks finish far
                            faster overall - and never hit the timeout -
                            than few large ones.
  --overlap-seconds N       Overlap between chunks (default 120). The overlap
                            is what makes cross-chunk speaker reconciliation
                            possible - speakers present in it get a
                            consistent global label.
  --timeout N               Per-request read timeout in seconds (default 900).
  --field K=V               Add/override a multipart form field (repeatable).
  --out PATH                Where to write the full report. Default:
                            <audio-stem>.azuretest.md next to the audio file.

Output goes two places:
  - console: abbreviated live view (progress, timing, previews).
  - report file: EVERYTHING untruncated - every chunk's raw JSON, the full
    stitched [MM:SS] [Speaker] timeline, and the full per-speaker
    concatenation. This is the file to paste back for analysis.
"""
from __future__ import annotations

import io
import json
import mimetypes
import os
import re
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import uuid
from pathlib import Path
from urllib.request import Request, urlopen


SCRIPT_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(SCRIPT_DIR))

from setup import find_tool  # noqa: E402
from stt import _probe_duration  # noqa: E402
from transcribe import merge_speaker_turns  # noqa: E402  (shared, no copy)


UPLOAD_LIMIT_BYTES = 24 * 1024 * 1024  # stay under Azure's 25 MB hard cap

# Per-backend config. default_fields are the multipart form fields known to
# be required; --field entries override/extend them.
BACKENDS = {
    "diarize": {
        "url_var": "AZURE_TRANSCRIBE_DIARIZE_URL",
        "key_var": "AZURE_TRANSCRIBE_DIARIZE_KEY",
        "default_fields": {
            "chunking_strategy": "auto",
            "response_format": "diarized_json",
        },
        # gpt-4o-transcribe-diarize rejects audio longer than 1500 s.
        "duration_limit": 1500,
    },
    "mai": {
        "url_var": "MAI_TRANSCRIBE_URL",
        "key_var": "MAI_TRANSCRIBE_KEY",
        # Unknown required fields - start minimal, iterate via --field on 400s.
        "default_fields": {},
        # Unknown limit - that's exactly what --no-trim is for.
        "duration_limit": None,
    },
}


def _load_config(name: str) -> str | None:
    """Look up a config value from $name, then ~/.config/watch/.env, then ./.env."""
    value = os.environ.get(name)
    if value and value.strip():
        return value.strip()
    for path in (Path.home() / ".config" / "watch" / ".env", Path.cwd() / ".env"):
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


def _extract_clip(src: Path, start: float, length: float | None) -> Path:
    """ffmpeg-extract a span as a 16 kHz mono 64 kbps mp3 (~0.5 MB/min).

    `start` = offset in seconds, `length` = duration in seconds (None = to end).
    Re-encoding (not -c copy) guarantees the result fits the 24 MB upload cap
    even for a 24-min chunk, and 16 kHz mono is plenty for speech models.
    """
    ffmpeg = find_tool("ffmpeg")
    if ffmpeg is None:
        raise SystemExit(
            "ffmpeg not found. Run `python scripts/setup.py --install-binaries`."
        )
    out = Path(tempfile.gettempdir()) / f"azure-test-{uuid.uuid4().hex[:8]}.mp3"
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    if start > 0:
        cmd += ["-ss", f"{start:.3f}"]
    cmd += ["-i", str(src)]
    if length is not None:
        cmd += ["-t", f"{length:.3f}"]
    cmd += ["-vn", "-acodec", "libmp3lame", "-ar", "16000", "-ac", "1",
            "-b:a", "64k", str(out)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not out.exists():
        raise SystemExit(f"ffmpeg extract failed: {result.stderr.strip()}")
    return out


def _build_multipart(fields: dict[str, str], file_path: Path) -> tuple[bytes, str]:
    """Assemble a multipart/form-data body (pure stdlib, no requests dependency)."""
    boundary = f"----AzureTestBoundary{uuid.uuid4().hex}"
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


def _post(url: str, key: str, fields: dict[str, str],
          audio_path: Path, timeout: float) -> tuple[int, str, float]:
    """POST one transcription request. Returns (http_status, body, elapsed_s).

    status 0 is a synthetic code for a network-level failure (timeout, DNS,
    connection reset, TLS) - those are NOT urllib.error.HTTPError and would
    otherwise propagate as an uncaught traceback. The caller treats any
    non-200 (including 0) as a chunk failure and stops gracefully, keeping
    whatever earlier chunks already succeeded.
    """
    body, boundary = _build_multipart(fields, audio_path)
    headers = {
        "api-key": key,
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": "watch-skill-azure-test/2.0",
    }
    request = Request(url, data=body, headers=headers, method="POST")
    context = ssl.create_default_context()
    t0 = time.perf_counter()
    try:
        with urlopen(request, timeout=timeout, context=context) as response:
            return response.status, response.read().decode("utf-8", errors="replace"), \
                time.perf_counter() - t0
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return exc.code, body_text, time.perf_counter() - t0
    except (TimeoutError, urllib.error.URLError, ssl.SSLError, OSError) as exc:
        elapsed = time.perf_counter() - t0
        return 0, (
            f"network failure after {elapsed:.0f}s: {type(exc).__name__}: {exc}. "
            f"If this is a read timeout, the chunk is too long for the model's "
            f"processing speed - lower --chunk-seconds or raise --timeout."
        ), elapsed


def _parse_segments(data: dict) -> list[dict]:
    """Extract {start, end, text, speaker} list from a diarized_json response.

    Schema (gpt-4o-transcribe-diarize): data["segments"][i] has start, end,
    text (leading space), speaker (single letter). Defensive about field
    name variants in case MAI differs.
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
        out.append({"start": start, "end": end, "text": text, "speaker": str(speaker)})
    return out


def _plan_chunks(duration: float, chunk_s: float,
                 overlap_s: float) -> list[tuple[float, float]]:
    """Partition [0, duration] into overlapping (start, end) windows.

    Adjacent chunks share `overlap_s` of audio - that shared region is what
    makes cross-chunk speaker reconciliation possible.
    """
    if duration <= chunk_s:
        return [(0.0, duration)]
    stride = max(chunk_s - overlap_s, chunk_s * 0.5)
    chunks: list[tuple[float, float]] = []
    t = 0.0
    while t < duration:
        end = min(t + chunk_s, duration)
        chunks.append((t, end))
        if end >= duration:
            break
        t += stride
    return chunks


def _stitch(per_chunk: list[tuple[float, list[dict]]],
            overlap_s: float) -> tuple[list[dict], list[str]]:
    """Merge per-chunk segments onto the global timeline.

    `per_chunk` = [(chunk_start_offset, local_segments), ...]. Each chunk's
    local timestamps are shifted by its start offset; overlap duplicates
    are dropped at the overlap midpoint.

    Speaker labels are chunk-TAGGED (`C1-A`, `C2-B`, ...) - deliberately
    NOT reconciled here. The earlier overlap-based auto-reconciliation was
    abandoned: on a one-dominant-speaker meeting it fragmented 3 real
    speakers into 33 (only the dominant speaker is present in every
    overlap window; everyone else gets a fresh id per chunk). Cross-chunk
    speaker identity is now deferred to the claude-opus-4-7 step, which
    sees every chunk's per-speaker text and resolves identity globally.

    The small overlap (~20 s) exists purely so a sentence sitting on a
    chunk boundary survives intact in one of the two chunks - not for
    speaker matching.
    """
    if not per_chunk:
        return [], []
    merged: list[dict] = []
    for idx, (offset, local) in enumerate(per_chunk):
        tag = f"C{idx + 1}-"
        shifted = [
            {
                "start": s["start"] + offset,
                "end": s["end"] + offset,
                "text": s["text"],
                "speaker": tag + str(s.get("speaker", "?")),
            }
            for s in local
        ]
        if idx == 0:
            merged = shifted
            continue
        # Inclusive cut on BOTH sides: a segment whose two overlap copies
        # straddle the midpoint is never lost (worst case it's kept twice).
        # The text-dedup pass below then collapses any such duplicate -
        # losing transcript text would be unrecoverable, a stray duplicate
        # is not.
        cut = offset + overlap_s / 2.0
        merged = [s for s in merged if s["start"] <= cut]
        merged += [s for s in shifted if s["start"] >= cut]
    merged.sort(key=lambda s: s["start"])

    # Collapse consecutive identical-text segments from the inclusive-cut
    # overlap (same audio transcribed by both adjacent chunks).
    deduped: list[dict] = []
    for s in merged:
        if (deduped and deduped[-1]["text"] == s["text"]
                and abs(deduped[-1]["start"] - s["start"]) < overlap_s):
            continue
        deduped.append(s)

    note = (
        "speaker labels are chunk-tagged (C1-.., C2-.., ...) - cross-chunk "
        "identity is deferred to the claude-opus-4-7 reconciliation step"
    )
    return deduped, [note]


def _concat_by_speaker(segments: list[dict]) -> dict[str, str]:
    """Concatenate every speaker's text across all chunks, in time order."""
    by_spk: dict[str, list[str]] = {}
    for s in sorted(segments, key=lambda x: x["start"]):
        by_spk.setdefault(s["speaker"], []).append(s["text"])
    return {spk: " ".join(parts) for spk, parts in by_spk.items()}


# ===========================================================================
# claude-opus-4-7 speaker reconciliation
#
# Each chunk is diarized independently, so labels are chunk-local (C1-A,
# C2-B, ...) and the same real person gets many labels - and the model even
# over-splits within one chunk. claude-opus-4-7 reads every label's text and
# collapses them to a handful of real speakers. This is the prototype of
# what will move into stt.py's azure backend.
# ===========================================================================

def _post_claude(url: str, key: str, prompt: str,
                 max_tokens: int = 2048) -> tuple[int, str, float]:
    """POST to the Anthropic Messages API (Azure AI Foundry passthrough).

    Returns (status, body, elapsed). status 0 = network failure. Both
    `x-api-key` (Anthropic-native) and `api-key` (Azure-style) are sent -
    the server honors whichever it expects, the other is ignored; saves a
    round-trip while the exact auth scheme is still unconfirmed.
    """
    payload = json.dumps({
        "model": "claude-opus-4-7",
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
    t0 = time.perf_counter()
    try:
        with urlopen(request, timeout=300, context=context) as response:
            return (response.status,
                    response.read().decode("utf-8", errors="replace"),
                    time.perf_counter() - t0)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return exc.code, body, time.perf_counter() - t0
    except (TimeoutError, urllib.error.URLError, ssl.SSLError, OSError) as exc:
        return 0, f"network failure: {type(exc).__name__}: {exc}", \
            time.perf_counter() - t0


def _build_reconcile_prompt(turns: list[dict]) -> str:
    """Build the reconciliation prompt from chunk-tagged speaker turns."""
    by_spk: dict[str, list[str]] = {}
    for t in turns:
        by_spk.setdefault(t["speaker"], []).append(t["text"])
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


def _stamp(seconds: float) -> str:
    s = int(seconds)
    return f"[{s // 60:02d}:{s % 60:02d}]"


def _readable_preview(segments: list[dict], limit: int = 30) -> str:
    if not segments:
        return "(no segments parsed - inspect the raw JSON above)"
    lines = [
        f"{_stamp(s['start'])} [{s['speaker']}] {s['text']}"
        for s in segments[:limit]
    ]
    if len(segments) > limit:
        lines.append(f"... (+{len(segments) - limit} more segments)")
    return "\n".join(lines)


def _arg_value(args: list[str], flag: str) -> str | None:
    if flag not in args:
        return None
    i = args.index(flag)
    return args[i + 1] if i + 1 < len(args) else None


def main() -> int:
    t_start = time.perf_counter()
    args = list(sys.argv[1:])
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2

    audio_arg = args[0]
    backend = _arg_value(args, "--backend") or "diarize"
    if backend not in BACKENDS:
        print(f"--backend must be one of {sorted(BACKENDS)}", file=sys.stderr)
        return 2
    cfg = BACKENDS[backend]

    no_trim = "--no-trim" in args
    # Default 600s, NOT the model's 1500s max: gpt-4o-transcribe-diarize
    # processing time scales super-linearly (~quadratically) with chunk
    # duration - a 600s chunk measured ~148s, a 1440s chunk blew past 900s.
    # So many small chunks finish far faster overall (and never time out)
    # than few large ones. 600s is the proven-fast size.
    chunk_seconds = float(_arg_value(args, "--chunk-seconds") or 600)
    # 20s, not the old 120s: the overlap is now only for transcript
    # continuity (a boundary-straddling sentence survives in one chunk).
    # Speaker reconciliation no longer relies on it - that moved to the
    # claude-opus-4-7 step - so the big window is unnecessary.
    overlap_seconds = float(_arg_value(args, "--overlap-seconds") or 20)
    timeout_seconds = float(_arg_value(args, "--timeout") or 900)
    max_seconds_raw = _arg_value(args, "--max-seconds")
    max_seconds = float(max_seconds_raw) if max_seconds_raw else None

    # Multipart fields: backend defaults, then --field overrides.
    fields = dict(cfg["default_fields"])
    for i, a in enumerate(args):
        if a == "--field" and i + 1 < len(args):
            k, _, v = args[i + 1].partition("=")
            fields[k.strip()] = v

    src = Path(audio_arg).expanduser()
    if not src.exists():
        print(f"audio file not found: {src}", file=sys.stderr)
        return 2

    # Full report file: default <audio-stem>.azuretest-c<chunk>.md next to
    # the audio, overridable with --out. The chunk size is baked into the
    # default name so comparison runs (--chunk-seconds 600 vs 1400) land in
    # separate files instead of clobbering each other.
    out_raw = _arg_value(args, "--out")
    out_path = (
        Path(out_raw).expanduser() if out_raw
        else src.with_suffix(f".azuretest-c{int(chunk_seconds)}.md")
    )

    url = _load_config(cfg["url_var"])
    key = _load_config(cfg["key_var"])
    if not url or not key:
        print(
            f"backend '{backend}' needs {cfg['url_var']} and {cfg['key_var']} "
            f"in ~/.config/watch/.env or the environment.",
            file=sys.stderr,
        )
        return 3

    duration = 0.0
    try:
        duration = _probe_duration(src)
    except SystemExit:
        pass
    print(
        f"[test] backend={backend}  source={src.name}  "
        f"duration={duration:.0f}s  fields={fields}",
        file=sys.stderr,
    )

    # ---- decide single-call vs chunked --------------------------------------
    limit = cfg["duration_limit"]
    chunk_plan: list[tuple[float, float]]
    if no_trim:
        # Probe mode: one call, whole file. Downsample only if over the
        # 24 MB upload cap (we still want to discover the DURATION limit).
        chunk_plan = [(0.0, duration or 0.0)]
        print("[test] --no-trim: single call, whole file (probe mode)", file=sys.stderr)
    elif max_seconds is not None:
        chunk_plan = [(0.0, min(max_seconds, duration or max_seconds))]
        print(f"[test] --max-seconds: capping to first {max_seconds:.0f}s", file=sys.stderr)
    elif duration and limit and duration > limit:
        chunk_plan = _plan_chunks(duration, min(chunk_seconds, limit - 60), overlap_seconds)
        print(
            f"[test] {duration:.0f}s over the {limit}s limit - chunking into "
            f"{len(chunk_plan)} x ~{chunk_plan[0][1]-chunk_plan[0][0]:.0f}s "
            f"({overlap_seconds:.0f}s overlap)",
            file=sys.stderr,
        )
    else:
        chunk_plan = [(0.0, duration or 0.0)]
        print("[test] single call (within limits)", file=sys.stderr)

    # ---- run each chunk -----------------------------------------------------
    # A chunk failure stops the loop but does NOT abort the run: whatever
    # chunks already succeeded are still stitched and written to the report.
    # No more losing 15 minutes of completed work to one bad call.
    per_chunk: list[tuple[float, list[dict]]] = []
    raw_dumps: list[tuple[int, str]] = []
    api_total = 0.0
    tmp_files: list[Path] = []
    stopped_reason: str | None = None
    try:
        for ci, (cs, ce) in enumerate(chunk_plan):
            length = (ce - cs) if (ce - cs) > 0 else None
            # Send verbatim only when it's the whole file AND already small;
            # otherwise (re)encode the span to a compact 16 kHz mono mp3.
            if length is None and src.stat().st_size <= UPLOAD_LIMIT_BYTES and cs == 0:
                clip = src
            else:
                clip = _extract_clip(src, cs, length)
                tmp_files.append(clip)
            label = (
                f"chunk {ci+1}/{len(chunk_plan)} (t={cs:.0f}-{ce:.0f}s, "
                f"{clip.stat().st_size // 1024} kB)"
            )
            print(f"[test] {label} -> POST", file=sys.stderr)
            status, payload, elapsed = _post(url, key, fields, clip, timeout_seconds)
            api_total += elapsed
            raw_dumps.append((status, payload))
            print(f"[test]   HTTP {status} after {elapsed:.1f}s", file=sys.stderr)
            if status != 200:
                stopped_reason = (
                    f"chunk {ci+1}/{len(chunk_plan)} failed (HTTP {status}): "
                    f"{payload[:300]}"
                )
                print(f"[test] {stopped_reason}", file=sys.stderr)
                print(f"[test] stopping; {len(per_chunk)} earlier chunk(s) "
                      f"kept and written to the report.", file=sys.stderr)
                break
            try:
                parsed = json.loads(payload)
            except json.JSONDecodeError:
                stopped_reason = f"chunk {ci+1}: non-JSON response"
                print(f"[test] {stopped_reason}", file=sys.stderr)
                break
            per_chunk.append((cs, _parse_segments(parsed)))
    finally:
        for f in tmp_files:
            f.unlink(missing_ok=True)

    if not per_chunk:
        # Not even the first chunk succeeded - nothing to stitch.
        print(f"[test] no chunk succeeded. {stopped_reason or 'unknown error'}",
              file=sys.stderr)
        return 1

    # ---- stitch + reconcile -------------------------------------------------
    if len(per_chunk) == 1:
        merged = [
            {**s, "start": s["start"] + per_chunk[0][0],
             "end": s["end"] + per_chunk[0][0]}
            for s in per_chunk[0][1]
        ]
        notes: list[str] = []
    else:
        merged, notes = _stitch(per_chunk, overlap_seconds)
    if stopped_reason:
        notes.insert(0, f"RUN INCOMPLETE: {stopped_reason}")

    total_elapsed = time.perf_counter() - t_start
    # processed_s = audio actually transcribed (only the chunks that succeeded),
    # so the realtime factor stays honest even on an incomplete run.
    processed_s = per_chunk[-1][0] + (
        max((s["end"] for s in per_chunk[-1][1]), default=0.0)
    ) if per_chunk else 0.0

    rt = processed_s / api_total if (processed_s > 0 and api_total > 0) else 0.0

    # ---- claude-opus-4-7 speaker reconciliation (when configured) ----------
    # Collapses the chunk-tagged labels (C1-A, C2-B, ...) into a handful of
    # real speakers. Runs only when AZURE_CLAUDE_URL + _KEY are set and we
    # actually have multi-chunk fragmentation to resolve.
    claude_url = _load_config("AZURE_CLAUDE_URL")
    claude_key = _load_config("AZURE_CLAUDE_KEY")
    reconcile_lines: list[str] = []
    pre_turns = merge_speaker_turns(merged)
    if claude_url and claude_key and len(per_chunk) > 1:
        print(f"[test] reconciling speakers via claude-opus-4-7...", file=sys.stderr)
        prompt = _build_reconcile_prompt(pre_turns)
        c_status, c_body, c_elapsed = _post_claude(claude_url, claude_key, prompt)
        print(f"[test]   claude HTTP {c_status} after {c_elapsed:.1f}s", file=sys.stderr)
        if c_status == 200:
            try:
                mapping, names = _parse_claude_mapping(c_body)
                for s in merged:
                    glob = mapping.get(s["speaker"], s["speaker"])
                    s["speaker"] = names.get(glob) or glob
                n_global = len({(names.get(g) or g) for g in mapping.values()})
                reconcile_lines.append(
                    f"claude-opus-4-7 collapsed {len(mapping)} chunk-tagged "
                    f"labels into {n_global} global speaker(s) in {c_elapsed:.1f}s"
                )
                for k, v in sorted(mapping.items()):
                    reconcile_lines.append(f"  {k} -> {names.get(v) or v}")
            except (json.JSONDecodeError, ValueError) as exc:
                reconcile_lines.append(
                    f"claude reply could not be parsed ({exc}); raw body:")
                reconcile_lines.append(c_body[:1000])
        else:
            reconcile_lines.append(
                f"claude HTTP {c_status} - reconciliation skipped, labels stay "
                f"chunk-tagged. Raw body (probe the endpoint/auth from this):")
            reconcile_lines.append(c_body[:1000])
    elif claude_url and claude_key:
        reconcile_lines.append(
            "single chunk - no cross-chunk reconciliation needed")
    else:
        reconcile_lines.append(
            "AZURE_CLAUDE_URL / AZURE_CLAUDE_KEY not set - speakers stay "
            "chunk-tagged (set them to enable claude-opus-4-7 reconciliation)")

    by_speaker = _concat_by_speaker(merged)

    # ---- full report file (everything, untruncated) ------------------------
    report: list[str] = []
    report.append(f"# Azure transcription test - {src.name}")
    report.append("")
    report.append(f"- backend: {backend}")
    report.append(f"- source: {src}")
    report.append(f"- duration: {duration:.0f}s")
    report.append(f"- multipart fields: {fields}")
    report.append(f"- chunks: {len(chunk_plan)}  "
                   f"(plan: {[(round(a), round(b)) for a, b in chunk_plan]})")
    report.append("")
    report.append("## Timing")
    report.append(f"- API calls: {api_total:.1f}s ({len(chunk_plan)} call(s))")
    report.append(f"- total: {total_elapsed:.1f}s")
    if rt > 0:
        report.append(f"- speed: {rt:.1f}x realtime "
                       f"({processed_s:.0f}s audio / {api_total:.1f}s API)")
        report.append(f"- 100-min video extrapolation: "
                       f"~{(100*60)/rt/60:.1f} min API time, sequential")
    report.append("")
    if notes:
        report.append("## Stitch notes")
        for n in notes:
            report.append(f"- {n}")
        report.append("")
    report.append("## Speaker reconciliation (claude-opus-4-7)")
    for line in reconcile_lines:
        report.append(line if line.startswith(" ") else f"- {line}")
    report.append("")
    report.append("## Raw responses")
    for i, (status, payload) in enumerate(raw_dumps):
        report.append(f"### Chunk {i+1}/{len(raw_dumps)} - HTTP {status}")
        report.append("```json")
        try:
            report.append(json.dumps(json.loads(payload), indent=2, ensure_ascii=False))
        except json.JSONDecodeError:
            report.append(payload)
        report.append("```")
        report.append("")
    # Turn-merged view: consecutive same-speaker segments collapsed into
    # one block (the production transcribe.merge_speaker_turns - shared, not
    # a copy). This is the readable [MM:SS] [Speaker] paragraph form.
    merged_turns = merge_speaker_turns(merged)
    report.append("## Timeline - raw segments (stitched)")
    report.append("```")
    report.append(_readable_preview(merged, limit=len(merged) or 1))
    report.append("```")
    report.append("")
    report.append(f"## Timeline - speaker turns ({len(merged_turns)} turns, "
                   f"merge_speaker_turns)")
    report.append("```")
    report.append(_readable_preview(merged_turns, limit=len(merged_turns) or 1))
    report.append("```")
    report.append("")
    report.append("## Per-speaker concatenation (all chunks)")
    for spk, text in sorted(by_speaker.items()):
        report.append(f"### Speaker {spk}")
        report.append(text)
        report.append("")
    try:
        out_path.write_text("\n".join(report) + "\n", encoding="utf-8")
        wrote_file = True
    except OSError as exc:
        print(f"[test] WARNING: could not write report to {out_path}: {exc}",
              file=sys.stderr)
        wrote_file = False

    # ---- console (abbreviated live view) -----------------------------------
    if len(raw_dumps) == 1:
        print()
        print("=" * 70)
        print("RAW JSON RESPONSE")
        print("=" * 70)
        try:
            print(json.dumps(json.loads(raw_dumps[0][1]), indent=2, ensure_ascii=False))
        except json.JSONDecodeError:
            print(raw_dumps[0][1])
    else:
        print()
        print(f"[test] {len(raw_dumps)} chunk responses, {len(merged)} merged "
              f"segments (full raw JSON is in the report file)")

    print()
    print("[test] --- timing ---", file=sys.stderr)
    print(f"[test]   API calls:  {api_total:7.1f}s  ({len(chunk_plan)} call(s))",
          file=sys.stderr)
    print(f"[test]   total:      {total_elapsed:7.1f}s", file=sys.stderr)
    if rt > 0:
        print(f"[test]   speed:      {rt:7.1f}x realtime "
              f"({processed_s:.0f}s audio / {api_total:.1f}s API)", file=sys.stderr)
        print(f"[test]   -> 100-min video: ~{(100*60)/rt/60:.1f} min API "
              f"(sequential)", file=sys.stderr)

    if reconcile_lines:
        print()
        print("[test] --- speaker reconciliation (claude-opus-4-7) ---",
              file=sys.stderr)
        for line in reconcile_lines:
            print(f"[test]  {line}", file=sys.stderr)

    print()
    print("=" * 70)
    print(f"TIMELINE - speaker turns ({len(merged_turns)} turns; "
          f"raw segments: {len(merged)})")
    print("=" * 70)
    print(_readable_preview(merged_turns))

    print()
    print("=" * 70)
    print("PER-SPEAKER CONCATENATION (everything each speaker said, all chunks)")
    print("=" * 70)
    for spk, text in sorted(by_speaker.items()):
        preview = text if len(text) <= 600 else text[:600] + " ..."
        print(f"\n### Speaker {spk}\n{preview}")

    if wrote_file:
        print()
        print(f"[test] full report (all raw JSON, full timeline + per-speaker) "
              f"-> {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
