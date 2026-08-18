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
    }


def _pick_subtitle(out_dir: Path) -> Path | None:
    candidates = sorted(out_dir.glob("video*.vtt"))
    if not candidates:
        return None
    preferred = [c for c in candidates if ".en" in c.name]
    return preferred[0] if preferred else candidates[0]


def _pick_video(out_dir: Path) -> Path | None:
    for ext in (".mp4", ".mkv", ".webm", ".mov"):
        for candidate in out_dir.glob(f"video*{ext}"):
            return candidate
    for candidate in out_dir.glob("video.*"):
        if candidate.suffix.lower() in VIDEO_EXTS:
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

    cmd = [
        yt_dlp,
        "-N", "8",
        "-f", "bv*[height<=720]+ba/b[height<=720]/bv+ba/b",
        "--merge-output-format", "mp4",
        "--write-info-json",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs", "en,en-US,en-GB,en-orig",
        "--sub-format", "vtt",
        "--convert-subs", "vtt",
        "--no-playlist",
        "--ignore-errors",
        "-o", output_template,
        url,
    ]

    # yt-dlp discovers its JS runtime (deno, needed for YouTube's EJS
    # challenges) via PATH. The standalone deno from setup.py lives in
    # ~/.transcribe/bin/, which usually isn't on PATH - prepend it so a
    # system-installed yt-dlp finds it too.
    env = dict(os.environ)
    env["PATH"] = str(TRANSCRIBE_BIN_DIR) + os.pathsep + env.get("PATH", "")

    # yt-dlp may exit non-zero if a subtitle variant fails (e.g. 429) even when
    # the video itself downloaded fine. Treat "video file present" as success.
    returncode, log_tail = _run_yt_dlp(cmd, env)
    video = _pick_video(out_dir)
    subtitle = _pick_subtitle(out_dir)
    captions_only = False
    download_error: str | None = None
    if video is None:
        # Media stream lost, captions present: a full transcript is still
        # reachable, only the frames are gone. Degrade instead of failing -
        # the caller drops the frame stages and notes the reason in the
        # report header.
        download_error = _classify_failure(log_tail)
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
            raw = json.loads(info_path.read_text())
            info = {
                "title": raw.get("title"),
                "uploader": raw.get("uploader") or raw.get("channel"),
                "duration": raw.get("duration"),
                "url": raw.get("webpage_url") or url,
                "description": raw.get("description") or "",
            }
        except Exception:
            info = {"url": url}

    return {
        "video_path": str(video) if video else None,
        "subtitle_path": str(subtitle) if subtitle else None,
        "info": info or {"url": url},
        "downloaded": True,
        "captions_only": captions_only,
        "download_error": download_error,
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
