#!/usr/bin/env python3
"""Download a video via yt-dlp, or resolve a local file path.

Also fetches subtitles (manual first, then auto-generated) in VTT format so
transcribe.py can parse them without needing Whisper.
"""
from __future__ import annotations

import collections
import json
import os
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import urlparse

from setup import TRANSCRIBE_BIN_DIR, find_tool


VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}
# Audio-only sources are first-class - voice memos / podcasts / meeting
# recordings run through the same pipeline minus the frame stages. Treat
# their extensions as known so they don't trip the "unknown extension"
# warning, which on an .m4a is pure noise.
AUDIO_EXTS = {".m4a", ".mp3", ".wav", ".flac", ".ogg", ".opus", ".aac", ".wma"}
KNOWN_MEDIA_EXTS = VIDEO_EXTS | AUDIO_EXTS


def is_url(source: str) -> bool:
    parsed = urlparse(source)
    return parsed.scheme in ("http", "https")


def resolve_source_path(path: str) -> Path:
    """Resolve a local source path, tolerating NFC/NFD Unicode mismatches.

    macOS-authored filenames arrive NFD (`Ö` as `O` + combining diaeresis)
    while callers type NFC - or vice versa - so a byte-exact lookup misses a
    file that visibly exists. Try both normal forms of the full path, then
    scan the parent directory for a name that matches under NFC folding
    (catches mixed-form names). If nothing matches, the byte-exact resolution
    is returned unchanged - the caller decides how to fail.
    """
    p = Path(path).expanduser().resolve()
    if p.exists():
        return p
    for form in ("NFC", "NFD"):
        candidate = Path(unicodedata.normalize(form, str(p)))
        if candidate.exists():
            return candidate
    target = unicodedata.normalize("NFC", p.name)
    try:
        for entry in p.parent.iterdir():
            if unicodedata.normalize("NFC", entry.name) == target:
                return entry
    except OSError:
        pass
    return p


def resolve_local(path: str) -> dict:
    p = resolve_source_path(path)
    if not p.exists():
        raise SystemExit(f"File not found: {p}")
    if p.name != Path(path).name:
        print(
            f"[transcribe] resolved Unicode-normalized filename: {p.name}",
            file=sys.stderr,
        )
    if p.suffix.lower() not in KNOWN_MEDIA_EXTS:
        print(
            f"[transcribe] warning: {p.suffix} is not a known media extension, proceeding anyway",
            file=sys.stderr,
        )
    return {
        "video_path": str(p),
        "subtitle_path": None,
        "info": {"title": p.name, "url": str(p)},
        "downloaded": False,
        "captions_only": False,
        "download_error": None,
        "media_kind": "video",
    }


def _base_lang(language: str | None) -> str | None:
    """"de-DE" -> "de". None when the language is unknown."""
    if not language:
        return None
    base = str(language).split("-")[0].strip().lower()
    return base or None


def subtitle_langs(language: str | None) -> str | None:
    """`--sub-langs` for the video's OWN language, or None when unknown.

    YouTube offers auto-translated caption tracks in ~200 languages for any
    video that has one automatic track. Asking for "en" on a German video
    therefore does not fail - it silently returns a machine translation, and
    the pipeline then produces an English transcript of German speech. Only
    the video's own language is ever requested; when it cannot be determined
    we ask for nothing and let the local Whisper path handle it, because a
    transcript in the wrong language is worse than no captions at all.
    """
    base = _base_lang(language)
    if not base:
        return None
    # `<lang>-orig` is YouTube's marker for the untranslated track; the bare
    # code and the full tag cover platforms that use neither convention.
    langs = [base, f"{base}-orig"]
    if language and str(language).lower() != base:
        langs.append(str(language))
    return ",".join(langs)


def _pick_subtitle(out_dir: Path, language: str | None = None) -> Path | None:
    """Newest matching VTT, preferring the video's own language."""
    candidates = sorted(out_dir.glob("video*.vtt"))
    if not candidates:
        return None
    base = _base_lang(language)
    if base:
        preferred = [c for c in candidates if f".{base}" in c.name.lower()]
        if preferred:
            return preferred[0]
    return candidates[0]


def _read_info_language(out_dir: Path) -> str | None:
    """The `language` field yt-dlp writes into video.info.json."""
    path = out_dir / "video.info.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("language")
    except (OSError, ValueError):
        return None


def _probe_language(yt_dlp: str, url: str, env: dict) -> str | None:
    """One cheap metadata call, used only when the info JSON has no language.

    Costs a single request and no download. Worth it: without a language we
    fetch no captions at all, so guessing wrong here means silently losing the
    free caption path on every video whose info JSON is incomplete.
    """
    try:
        proc = subprocess.run(
            [yt_dlp, "--skip-download", "--no-playlist", "--no-warnings",
             "--print", "%(language)s", url],
            capture_output=True, text=True, errors="replace", timeout=120, env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
    if not lines:
        return None
    value = lines[-1]
    return None if value.upper() in ("NA", "NONE") else value


def _pick_video(out_dir: Path) -> Path | None:
    for ext in (".mp4", ".mkv", ".webm", ".mov"):
        for candidate in out_dir.glob(f"video*{ext}"):
            return candidate
    for candidate in out_dir.glob("video.*"):
        if candidate.suffix.lower() in VIDEO_EXTS:
            return candidate
    return None


def _pick_audio(out_dir: Path) -> Path | None:
    """Audio-only download result, for sources whose video streams are gated.

    Audio still carries the whole transcript (Whisper runs normally); only
    the frame stages fall away - the same shape as an .m4a voice memo.
    """
    for ext in (".m4a", ".mp3", ".opus", ".webm", ".ogg", ".wav", ".aac"):
        for candidate in out_dir.glob(f"video*{ext}"):
            return candidate
    return None


# Fingerprints for the ways a media download dies while the caption tracks
# still land. Captions are separate small files fetched over a different
# path, so a gated/DRM'd media stream doesn't take them down with it - which
# is exactly when the frames-less degradation below is worth having.
DOWNLOAD_FAILURE_HINTS: list[tuple[str, str]] = [
    ("po_token", "YouTube demanded a PO token for the media streams"),
    ("po token", "YouTube demanded a PO token for the media streams"),
    ("drm", "the media streams are DRM-protected"),
    ("sign in to confirm", "YouTube asked for a signed-in session (bot check)"),
    ("confirm your age", "the source requires an age-confirmed session"),
    ("private video", "the video is private"),
    ("members-only", "the video is members-only"),
    ("http error 403", "the media URLs returned HTTP 403 (often an outdated yt-dlp)"),
    ("http error 429", "the source rate-limited the download (HTTP 429)"),
    ("requested format is not available", "no downloadable format matched the request"),
    ("unable to download", "yt-dlp could not fetch the media streams"),
]


YOUTUBE_HOSTS = {
    "youtube.com", "www.youtube.com", "m.youtube.com",
    "music.youtube.com", "youtu.be", "www.youtu.be",
}

# Player clients that, per yt-dlp's PO Token Guide, still return plain HTTPS
# format URLs without a Proof-of-Origin token - the retry when the default
# clients hand back SABR-only formats (no URL) or demand a PO token. `tv`
# falls back to itag 18 (360p H.264+AAC), which is plenty: this skill samples
# 512px frames and transcribes audio, it isn't archiving the video.
NO_POT_PLAYER_CLIENTS = "tv,web_embedded,android_vr"


def _is_youtube(url: str) -> bool:
    return (urlparse(url).hostname or "").lower() in YOUTUBE_HOSTS


def _classify_failure(log_tail: list[str]) -> str:
    """Turn yt-dlp's last output lines into one short human-readable reason.

    Falls back to the last ERROR line, then to a generic message - the
    caller puts this into the report header, so it must never be empty.
    """
    haystack = "\n".join(log_tail).lower()
    for needle, reason in DOWNLOAD_FAILURE_HINTS:
        if needle in haystack:
            return reason
    for line in reversed(log_tail):
        if "error" in line.lower():
            return line.strip()[:200]
    return "yt-dlp produced no media file"


def _run_yt_dlp(cmd: list[str], env: dict) -> tuple[int, list[str]]:
    """Run yt-dlp, streaming its output to stderr and keeping the tail.

    Output has to stay live (downloads run for minutes), so it's echoed
    line by line rather than captured wholesale; only the last lines are
    retained for failure classification.
    """
    tail: collections.deque[str] = collections.deque(maxlen=60)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
        errors="replace",
        bufsize=1,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stderr.write(line)
        tail.append(line.rstrip())
    proc.stdout.close()
    return proc.wait(), list(tail)


def download_url(url: str, out_dir: Path) -> dict:
    yt_dlp = find_tool("yt-dlp")
    if yt_dlp is None:
        raise SystemExit(
            "yt-dlp is not installed. Run `python3 scripts/setup.py --install-binaries` "
            "to drop a standalone build into ~/.transcribe/bin/."
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    output_template = str(out_dir / "video.%(ext)s")

    def build_cmd(fmt: str, extractor_args: str | None, sub_langs: str | None) -> list[str]:
        cmd = [
            yt_dlp,
            "-N", "8",
            "-f", fmt,
            "--merge-output-format", "mp4",
            "--write-info-json",
        ]
        if sub_langs:
            cmd += [
                "--write-subs",
                "--write-auto-subs",
                "--sub-langs", sub_langs,
                "--sub-format", "vtt",
                "--convert-subs", "vtt",
            ]
        if extractor_args:
            cmd += ["--extractor-args", extractor_args]
        cmd += [
            "--no-playlist",
            "--ignore-errors",
            "-o", output_template,
            url,
        ]
        return cmd

    # yt-dlp discovers its JS runtime (deno, needed for YouTube's EJS
    # challenges) via PATH. The standalone deno from setup.py lives in
    # ~/.transcribe/bin/, which usually isn't on PATH - prepend it so a
    # system-installed yt-dlp finds it too.
    env = dict(os.environ)
    env["PATH"] = str(TRANSCRIBE_BIN_DIR) + os.pathsep + env.get("PATH", "")

    # Escalation ladder, each rung only paid for when the previous one came
    # back without a media file:
    #   1. the normal 720p video+audio pull
    #   2. (YouTube) the same, through player clients that need no PO token
    #   3. audio only - no frames, but Whisper and diarization run in full
    # A first-rung success costs exactly one yt-dlp call, as before.
    video_fmt = "bv*[height<=720]+ba/b[height<=720]/bv+ba/b"
    yt_args = (
        f"youtube:player_client={NO_POT_PLAYER_CLIENTS}"
        if _is_youtube(url) else None
    )
    strategies: list[tuple[str, str, str | None]] = [
        ("default clients", video_fmt, None),
    ]
    if yt_args:
        strategies.append(
            (f"player_client={NO_POT_PLAYER_CLIENTS}", video_fmt, yt_args)
        )
    strategies.append(("audio-only fallback", "bestaudio/best", yt_args))

    video: Path | None = None
    audio: Path | None = None
    log_tail: list[str] = []
    # The reason worth reporting comes from the *first* attempt - later rungs
    # either succeed (and log nothing useful) or fail for downstream reasons.
    failure_tail: list[str] = []
    returncode = 0
    for i, (label, fmt, extractor_args) in enumerate(strategies):
        if i:
            print(
                f"[transcribe] no media file yet - retrying with {label}...",
                file=sys.stderr,
            )
        # Captions are NOT requested here - they need the video's language,
        # which only the info JSON reveals, so they get their own pass below.
        # yt-dlp may exit non-zero if a subtitle variant fails (e.g. 429) even
        # when the video itself downloaded fine. Treat "media file present" as
        # success regardless of the exit code.
        returncode, log_tail = _run_yt_dlp(build_cmd(fmt, extractor_args, None), env)
        video = _pick_video(out_dir)
        if video is not None:
            break
        if not failure_tail:
            failure_tail = log_tail
        audio = _pick_audio(out_dir)
        if audio is not None:
            break

    # Second, download-free pass for captions, now that the info JSON can say
    # which language the video is actually in (see subtitle_langs()). Skipped
    # entirely when the language stays unknown - no captions beats captions in
    # the wrong language, and the local Whisper path covers that case.
    language = _read_info_language(out_dir) or _probe_language(yt_dlp, url, env)
    subtitle = _pick_subtitle(out_dir, language)
    if subtitle is None:
        sub_langs = subtitle_langs(language)
        if sub_langs:
            print(
                f"[transcribe] fetching {language} captions...",
                file=sys.stderr,
            )
            cmd = build_cmd(video_fmt, yt_args, sub_langs)
            cmd.insert(1, "--skip-download")
            _run_yt_dlp(cmd, env)
            subtitle = _pick_subtitle(out_dir, language)
        else:
            print(
                "[transcribe] video language undetermined - skipping captions "
                "(local transcription handles it)",
                file=sys.stderr,
            )
    captions_only = False
    download_error: str | None = None
    if video is None and audio is not None:
        # Video streams gated, audio through: full transcript, no frames.
        download_error = _classify_failure(failure_tail or log_tail)
        print(
            f"[transcribe] video streams unavailable ({download_error}) - "
            "downloaded audio only; transcript runs in full, frames are skipped",
            file=sys.stderr,
        )
    if video is None and audio is None:
        # Media stream lost, captions present: a full transcript is still
        # reachable, only the frames are gone. Degrade instead of failing -
        # the caller drops the frame stages and notes the reason in the
        # report header.
        download_error = _classify_failure(failure_tail or log_tail)
        if subtitle is None:
            raise SystemExit(
                f"yt-dlp produced neither a video file nor subtitles in {out_dir} "
                f"(exit {returncode}): {download_error}. If this is YouTube, an "
                "outdated yt-dlp is the usual cause - refresh it with "
                "`python3 scripts/setup.py --install-binaries --force`."
            )
        captions_only = True
        print(
            f"[transcribe] video download failed ({download_error}) but subtitles "
            "landed - continuing captions-only, without frames",
            file=sys.stderr,
        )

    info_path = out_dir / "video.info.json"
    info: dict = {}
    if info_path.exists():
        try:
            # yt-dlp always writes UTF-8; the platform default (cp1252 on
            # Windows) chokes on multi-byte titles/descriptions
            raw = json.loads(info_path.read_text(encoding="utf-8"))
            info = {
                "title": raw.get("title"),
                "uploader": raw.get("uploader") or raw.get("channel"),
                "duration": raw.get("duration"),
                "url": raw.get("webpage_url") or url,
                "description": raw.get("description") or "",
            }
        except Exception as exc:
            print(
                f"[transcribe] WARNING: could not parse {info_path.name} "
                f"({type(exc).__name__}: {exc}) - title/description metadata lost",
                file=sys.stderr,
            )
            info = {"url": url}

    media = video or audio
    return {
        "video_path": str(media) if media else None,
        "subtitle_path": str(subtitle) if subtitle else None,
        "info": info or {"url": url},
        "downloaded": True,
        "captions_only": captions_only,
        "download_error": download_error,
        # "video" | "audio" | None - run.py turns an "audio" result plus a
        # download_error into the audio-only degradation note.
        "media_kind": "video" if video else ("audio" if audio else None),
    }


def download(source: str, out_dir: Path) -> dict:
    if is_url(source):
        return download_url(source, out_dir)
    return resolve_local(source)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: download.py <url-or-path> <out-dir>", file=sys.stderr)
        raise SystemExit(2)
    result = download(sys.argv[1], Path(sys.argv[2]))
    print(json.dumps(result, indent=2))
