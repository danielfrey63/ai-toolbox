#!/usr/bin/env python3
"""Speaker diarization with three interchangeable backends.

Three modes, picked by `--diarize` in watch.py:

  * `assemblyai`     - cloud, all-in-one. Replaces Whisper entirely:
                       transcription + speaker labels come from one API call.
  * `pyannote-api`   - cloud, diarization only (pyannote.ai). Runs alongside
                       Whisper and the script aligns speaker turns to Whisper
                       segments by overlap.
  * `pyannote-local` - local CPU/GPU via the open-source `pyannote.audio`
                       package. Same alignment as `pyannote-api`. Free but
                       heavyweight (PyTorch model download, HuggingFace token,
                       slow on CPU).

Segment shape produced by all three:
    {"start": float, "end": float, "text": str, "speaker": str | None}

The `speaker` field is a short label (`"A"`, `"B"`, `"SPEAKER_00"`, ...).
Mapping speaker labels to real names is done later by Claude using
transcript context (address patterns like "Andrea, ..." -> next speaker = A).

Pure stdlib except for the optional `pyannote.audio` import in the local
backend (lazy-loaded so the script runs fine without it installed).
"""
from __future__ import annotations

import io
import json
import os
import ssl
import sys
import time
import urllib.error
import uuid
from pathlib import Path
from urllib.request import Request, urlopen


ASSEMBLYAI_HOSTS = {
    "us": "https://api.assemblyai.com/v2",
    "eu": "https://api.eu.assemblyai.com/v2",
}
# Required by AssemblyAI; ordered fallback list - first available wins,
# only one model produces the transcript (not parallel execution).
ASSEMBLYAI_SPEECH_MODELS = ["universal-3-pro", "universal-2"]

PYANNOTE_API_BASE = "https://api.pyannote.ai/v1"
PYANNOTE_MODEL = "pyannote/speaker-diarization-3.1"

POLL_INTERVAL_SECONDS = 4.0
MAX_POLL_SECONDS = 60 * 60


def _assemblyai_base() -> str:
    """Resolve the AssemblyAI REST base URL from $ASSEMBLYAI_REGION (us|eu).

    Default: US. Set ASSEMBLYAI_REGION=eu in env or .env to route through
    api.eu.assemblyai.com - required if your account/data needs EU residency.
    """
    region = (_load_env_value("ASSEMBLYAI_REGION") or "us").lower()
    if region not in ASSEMBLYAI_HOSTS:
        raise SystemExit(
            f"Unknown ASSEMBLYAI_REGION: {region!r} (expected 'us' or 'eu')"
        )
    return ASSEMBLYAI_HOSTS[region]


def _load_env_value(name: str) -> str | None:
    """Look up an env value from $name or `~/.config/watch/.env` / `./.env`."""
    value = os.environ.get(name)
    if value:
        return value.strip()
    for path in (Path.home() / ".config" / "watch" / ".env", Path.cwd() / ".env"):
        if not path.exists():
            continue
        try:
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() != name:
                    continue
                v = v.strip()
                if len(v) >= 2 and v[0] in ('"', "'") and v[-1] == v[0]:
                    v = v[1:-1]
                if v:
                    return v
        except OSError:
            continue
    return None


def pick_backend(preferred: str | None) -> str | None:
    """Resolve `--diarize` to a concrete backend.

    `preferred` is one of: None, "auto", "assemblyai", "pyannote-api",
    "pyannote-local". In "auto" mode we try, LOCAL FIRST - nothing leaves
    the machine unless local processing is unavailable:
        1. pyannote local (if HF_TOKEN available; managed venv self-provisions)
        2. pyannote.ai   (if PYANNOTE_API_KEY)
        3. AssemblyAI    (if ASSEMBLYAI_API_KEY)
    Returns the chosen backend name, or None if nothing is configured.

    **Explicit choices** (anything other than None/"auto") are now validated
    eagerly: if the required key for the chosen backend is missing, raise
    SystemExit with a clear message. This stops the previous silent-fallback
    behaviour where `--diarize assemblyai` would fail and quietly fall back
    to Whisper without the user noticing. Auto-mode keeps its forgiving
    behaviour because the whole point of auto is "use whatever is there".
    """
    if preferred is None:
        return None
    if preferred == "auto":
        if _has_pyannote_local() and (_load_env_value("HF_TOKEN") or _load_env_value("HUGGINGFACE_TOKEN")):
            return "pyannote-local"
        if _load_env_value("PYANNOTE_API_KEY"):
            return "pyannote-api"
        if _load_env_value("ASSEMBLYAI_API_KEY"):
            return "assemblyai"
        return None

    # Explicit backend choice - validate the matching credential now so the
    # user sees a clear setup error rather than a downstream API failure.
    if preferred == "assemblyai":
        if not _load_env_value("ASSEMBLYAI_API_KEY"):
            raise SystemExit(
                "--diarize assemblyai requires ASSEMBLYAI_API_KEY. "
                "Add it to ~/.config/watch/.env or the environment. "
                "Get a key at https://www.assemblyai.com/dashboard/api-keys"
            )
    elif preferred == "pyannote-api":
        if not _load_env_value("PYANNOTE_API_KEY"):
            raise SystemExit(
                "--diarize pyannote-api requires PYANNOTE_API_KEY. "
                "Add it to ~/.config/watch/.env or the environment. "
                "Sign up at https://www.pyannote.ai/"
            )
    elif preferred == "pyannote-local":
        if not (_load_env_value("HF_TOKEN") or _load_env_value("HUGGINGFACE_TOKEN")):
            raise SystemExit(
                "--diarize pyannote-local requires HF_TOKEN (Hugging Face token). "
                "Add it to ~/.config/watch/.env or the environment, and accept the "
                "licenses at https://huggingface.co/pyannote/speaker-diarization-3.1 "
                "and https://huggingface.co/pyannote/segmentation-3.0"
            )
    return preferred


def _has_pyannote_local() -> bool:
    """The local backend self-provisions its managed venv on first use, so
    availability hinges only on the HF token (checked by the caller)."""
    return True


def diarize_assemblyai(
    audio_path: Path,
    api_key: str | None = None,
    language: str | None = None,
) -> list[dict]:
    """Run AssemblyAI's full transcription+diarization on an extracted audio file.

    Returns segments with `speaker` set. Async flow: upload -> submit -> poll.
    """
    api_key = api_key or _load_env_value("ASSEMBLYAI_API_KEY")
    if not api_key:
        raise SystemExit(
            "ASSEMBLYAI_API_KEY missing. Add it to ~/.config/watch/.env "
            "or the environment. Get a key at https://www.assemblyai.com/."
        )

    print("[watch] uploading audio to AssemblyAI...", file=sys.stderr)
    upload_url = _assemblyai_upload(audio_path, api_key)

    print("[watch] submitting AssemblyAI transcription job (speaker_labels=true)...", file=sys.stderr)
    job_id = _assemblyai_submit(upload_url, api_key, language)

    print(f"[watch] polling AssemblyAI job {job_id[:12]}...", file=sys.stderr)
    result = _assemblyai_poll(job_id, api_key)
    return _assemblyai_parse(result)


def _assemblyai_upload(audio_path: Path, api_key: str) -> str:
    """Stream the audio bytes to /v2/upload (raw binary, NOT multipart)."""
    base = _assemblyai_base()
    request = Request(
        f"{base}/upload",
        data=audio_path.read_bytes(),
        headers={"authorization": api_key, "Content-Type": "application/octet-stream"},
        method="POST",
    )
    ctx = ssl.create_default_context()
    try:
        with urlopen(request, timeout=600, context=ctx) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(_assemblyai_http_error("upload", exc))
    upload_url = data.get("upload_url")
    if not upload_url:
        raise SystemExit(f"AssemblyAI upload returned no upload_url: {data}")
    return upload_url


def _assemblyai_submit(upload_url: str, api_key: str, language: str | None) -> str:
    body: dict = {
        "audio_url": upload_url,
        "speaker_labels": True,
        "speech_models": ASSEMBLYAI_SPEECH_MODELS,
    }
    if language:
        body["language_code"] = language
    else:
        # Auto-detect - handles multilingual content (DE-CH + EN + FR/IT terms).
        body["language_detection"] = True

    base = _assemblyai_base()
    request = Request(
        f"{base}/transcript",
        data=json.dumps(body).encode(),
        headers={"authorization": api_key, "Content-Type": "application/json"},
        method="POST",
    )
    ctx = ssl.create_default_context()
    try:
        with urlopen(request, timeout=60, context=ctx) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(_assemblyai_http_error("submit", exc))
    job_id = data.get("id")
    if not job_id:
        raise SystemExit(f"AssemblyAI submit returned no job id: {data}")
    return job_id


def _assemblyai_poll(job_id: str, api_key: str) -> dict:
    """Poll /v2/transcript/{id} until status=completed or error.

    Other statuses (`queued`, `processing`) just continue the poll loop.
    """
    started = time.time()
    base = _assemblyai_base()
    url = f"{base}/transcript/{job_id}"
    ctx = ssl.create_default_context()
    while True:
        request = Request(url, headers={"authorization": api_key})
        try:
            with urlopen(request, timeout=60, context=ctx) as response:
                data = json.load(response)
        except urllib.error.HTTPError as exc:
            raise SystemExit(_assemblyai_http_error(f"poll {job_id[:12]}", exc))
        status = data.get("status")
        if status == "completed":
            return data
        if status == "error":
            raise SystemExit(f"AssemblyAI failed: {data.get('error') or data}")
        if time.time() - started > MAX_POLL_SECONDS:
            raise SystemExit(f"AssemblyAI polling exceeded {MAX_POLL_SECONDS}s - job {job_id}")
        time.sleep(POLL_INTERVAL_SECONDS)


def _assemblyai_http_error(stage: str, exc: urllib.error.HTTPError) -> str:
    """Format an AssemblyAI HTTPError with the common-pitfall hints inline."""
    body = ""
    try:
        body = exc.read().decode("utf-8", errors="replace")[:400]
    except Exception:
        pass
    hint = ""
    if exc.code == 401:
        hint = (
            " - Auth failed. Check that ASSEMBLYAI_API_KEY is set and is the "
            "raw key (NO 'Bearer ' prefix; this differs from many APIs). "
            "Get one at https://www.assemblyai.com/dashboard/api-keys."
        )
    elif exc.code == 429:
        hint = " - Rate limited. Retry after a few seconds or check your plan limits."
    return f"AssemblyAI {stage} HTTP {exc.code}: {body}{hint}"


def _assemblyai_parse(result: dict) -> list[dict]:
    """Convert /transcript utterances into our segment shape."""
    segments: list[dict] = []
    for u in (result.get("utterances") or []):
        text = (u.get("text") or "").strip()
        if not text:
            continue
        segments.append({
            "start": round(float(u.get("start") or 0) / 1000.0, 2),
            "end": round(float(u.get("end") or 0) / 1000.0, 2),
            "text": text,
            "speaker": u.get("speaker"),
        })
    if not segments:
        full = (result.get("text") or "").strip()
        if full:
            segments.append({"start": 0.0, "end": 0.0, "text": full, "speaker": None})
    return segments


def diarize_pyannote_api(
    audio_path: Path,
    api_key: str | None = None,
) -> list[dict]:
    """Run pyannote.ai diarization on an extracted audio file.

    Returns a list of speaker turns: [{start, end, speaker}, ...]. Caller
    aligns these to Whisper segments via `align_speakers()`.
    """
    api_key = api_key or _load_env_value("PYANNOTE_API_KEY")
    if not api_key:
        raise SystemExit(
            "PYANNOTE_API_KEY missing. Add it to ~/.config/watch/.env or "
            "the environment. Get a key at https://www.pyannote.ai/."
        )

    media_url = _pyannote_upload(audio_path, api_key)
    print("[watch] submitting pyannote.ai diarization job...", file=sys.stderr)
    job_id = _pyannote_submit(media_url, api_key)
    print(f"[watch] polling pyannote.ai job {job_id[:12]}...", file=sys.stderr)
    result = _pyannote_poll(job_id, api_key)
    return _pyannote_parse(result)


def _pyannote_headers(api_key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}


def _pyannote_upload(audio_path: Path, api_key: str) -> str:
    """Get a presigned upload URL, PUT the file, return the media:// URL.

    pyannote.ai's API expects a `media://` reference. The flow is:
      1. POST /media/{name} with auth -> returns a presigned upload URL.
      2. PUT the audio bytes to that URL.
      3. Reference the upload as `media://<name>` in /diarize.
    """
    name = f"watch-{uuid.uuid4().hex}.mp3"
    ctx = ssl.create_default_context()

    print(f"[watch] requesting pyannote.ai upload URL for {name}...", file=sys.stderr)
    request = Request(
        f"{PYANNOTE_API_BASE}/media/{name}",
        data=b"{}",
        headers=_pyannote_headers(api_key),
        method="POST",
    )
    with urlopen(request, timeout=60, context=ctx) as response:
        data = json.load(response)
    presigned_url = data.get("url") or data.get("uploadUrl") or data.get("presignedUrl")
    if not presigned_url:
        raise SystemExit(f"pyannote.ai upload-URL response missing url field: {data}")

    print(f"[watch] uploading audio to pyannote.ai presigned URL...", file=sys.stderr)
    put_request = Request(
        presigned_url,
        data=audio_path.read_bytes(),
        headers={"Content-Type": "audio/mpeg"},
        method="PUT",
    )
    with urlopen(put_request, timeout=600, context=ctx) as _:
        pass

    return f"media://{name}"


def _pyannote_submit(media_url: str, api_key: str) -> str:
    body = {"url": media_url}
    request = Request(
        f"{PYANNOTE_API_BASE}/diarize",
        data=json.dumps(body).encode(),
        headers=_pyannote_headers(api_key),
        method="POST",
    )
    ctx = ssl.create_default_context()
    with urlopen(request, timeout=60, context=ctx) as response:
        data = json.load(response)
    job_id = data.get("jobId") or data.get("id")
    if not job_id:
        raise SystemExit(f"pyannote.ai submit returned no job id: {data}")
    return job_id


def _pyannote_poll(job_id: str, api_key: str) -> dict:
    started = time.time()
    url = f"{PYANNOTE_API_BASE}/jobs/{job_id}"
    ctx = ssl.create_default_context()
    while True:
        request = Request(url, headers={"Authorization": f"Bearer {api_key}"})
        with urlopen(request, timeout=60, context=ctx) as response:
            data = json.load(response)
        status = (data.get("status") or "").lower()
        if status in ("succeeded", "completed", "done"):
            return data
        if status in ("failed", "error", "canceled"):
            raise SystemExit(f"pyannote.ai failed: {data}")
        if time.time() - started > MAX_POLL_SECONDS:
            raise SystemExit(f"pyannote.ai polling exceeded {MAX_POLL_SECONDS}s - job {job_id}")
        time.sleep(POLL_INTERVAL_SECONDS)


def _pyannote_parse(result: dict) -> list[dict]:
    """Convert the diarization output into [{start, end, speaker}, ...].

    pyannote.ai returns the diarization as a list of turns either at the top
    level or under output.diarization. We handle both shapes.
    """
    raw_turns = (
        result.get("diarization")
        or (result.get("output") or {}).get("diarization")
        or result.get("turns")
        or []
    )
    turns: list[dict] = []
    for t in raw_turns:
        turns.append({
            "start": round(float(t.get("start") or 0.0), 2),
            "end": round(float(t.get("end") or 0.0), 2),
            "speaker": str(t.get("speaker") or t.get("label") or "UNK"),
        })
    return turns


def diarize_pyannote_local(
    audio_path: Path,
    hf_token: str | None = None,
) -> list[dict]:
    """Run pyannote.audio locally, fully on-device. Heavy on first use.

    The fragile ML stack never loads into this process: the work happens in
    `pyannote_worker.py` inside the managed venv (~/.config/watch/venv),
    which setup.ensure_venv() provisions idempotently on first use. See the
    worker for the Windows hardening; see setup.VENV_PINS for the pin set.

    Requires a HuggingFace token in $HF_TOKEN / $HUGGINGFACE_TOKEN plus
    license acceptance for BOTH gated repos on the Hugging Face website:
    pyannote/speaker-diarization-3.1 and pyannote/segmentation-3.0.
    """
    hf_token = hf_token or _load_env_value("HF_TOKEN") or _load_env_value("HUGGINGFACE_TOKEN")
    if not hf_token:
        raise SystemExit(
            "HF_TOKEN missing - pyannote.audio needs a Hugging Face token "
            "to download the diarization model. Set HF_TOKEN in your env or "
            "in ~/.config/watch/.env. Also accept the model licenses at "
            "https://huggingface.co/pyannote/speaker-diarization-3.1 and "
            "https://huggingface.co/pyannote/segmentation-3.0."
        )

    from setup import run_venv_worker

    stdout = run_venv_worker(
        "pyannote_worker.py", [str(audio_path)], env_extra={"HF_TOKEN": hf_token}
    )
    try:
        return json.loads(stdout)
    except ValueError as exc:
        raise SystemExit(
            f"pyannote_worker returned invalid JSON ({exc}): {stdout[-300:]}"
        )


def align_speakers(segments: list[dict], turns: list[dict]) -> list[dict]:
    """Annotate each transcript segment with the speaker turn it overlaps most.

    For each segment, we find the turn with maximum temporal overlap and
    assign that turn's speaker label. If a segment straddles a speaker
    boundary, the dominant speaker wins (good-enough for typical meeting
    cadence - false attributions are usually filler words at turn changes).
    """
    if not turns:
        return [dict(seg, speaker=seg.get("speaker")) for seg in segments]

    out: list[dict] = []
    for seg in segments:
        s, e = float(seg["start"]), float(seg["end"])
        best_speaker: str | None = None
        best_overlap = 0.0
        for t in turns:
            overlap = max(0.0, min(e, t["end"]) - max(s, t["start"]))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = t["speaker"]
        out.append({**seg, "speaker": best_speaker})
    return out


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(
            "usage: diarize.py <backend> <audio.mp3>\n"
            "  backend: assemblyai | pyannote-api | pyannote-local",
            file=sys.stderr,
        )
        raise SystemExit(2)
    backend = sys.argv[1]
    audio = Path(sys.argv[2]).expanduser().resolve()

    if backend == "assemblyai":
        segs = diarize_assemblyai(audio)
        print(json.dumps(segs, indent=2))
    elif backend == "pyannote-api":
        turns = diarize_pyannote_api(audio)
        print(json.dumps(turns, indent=2))
    elif backend == "pyannote-local":
        turns = diarize_pyannote_local(audio)
        print(json.dumps(turns, indent=2))
    else:
        print(f"unknown backend: {backend}", file=sys.stderr)
        raise SystemExit(2)
