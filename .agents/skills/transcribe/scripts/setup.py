#!/usr/bin/env python3
"""Setup / preflight for /transcribe.

Modes:
  setup.py --check      Silent preflight. Exit 0 if ready, 2/3/4 on failure.
  setup.py --json       Machine-readable status for Claude to parse.
  setup.py --venv       Provision/repair the managed ML venv (pyannote/whisper local).
  setup.py              Installer. Auto-installs deps, scaffolds .env, marks SETUP_COMPLETE.

Design:
- Silent on success: --check exits 0 with no output when everything's ready so
  that /transcribe doesn't spam "setup is complete" on every turn.
- Idempotent: re-running the installer is safe - it never clobbers existing
  keys and only appends missing ones.
- SETUP_COMPLETE=true in ~/.config/transcribe/.env tells us the user has been
  through a successful installer run at least once.
- Never sudo. On macOS, auto-install via brew. Elsewhere, print exact commands.
- Never write an API key to disk automatically - only scaffold placeholders.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path


REQUIRED_BINARIES = ["ffmpeg", "ffprobe", "yt-dlp"]
CONFIG_DIR = Path.home() / ".config" / "transcribe"
CONFIG_FILE = CONFIG_DIR / ".env"

# Single source of truth for Windows-platform branches. Anywhere else in the
# codebase that needs "are we on Windows?" should import this constant rather
# than re-stringly-typed-compare platform.system().
IS_WINDOWS = platform.system() == "Windows"

# Standalone-binary install location. Lives outside .config because these are
# binaries (chmod +x on Unix, .exe on Windows), not config. Same directory on
# both platforms so the path scripts hand to subprocess is trivially portable.
TRANSCRIBE_BIN_DIR = Path.home() / ".transcribe" / "bin"

# ===========================================================================
# Managed venv for the local ML backends (pyannote-local, whisper-local).
#
# The pyannote/faster-whisper dependency stack is too fragile to import into
# whatever Python happens to run run.py (battle-tested on Windows: pyannote
# 4.x torchcodec DLLs, torch>=2.6 weights_only, hub 1.x API breaks, conflicts
# with any env carrying recent transformers/torchvision). So the heavy code
# runs in *worker subprocesses* inside a skill-owned venv, provisioned
# idempotently next to the rest of the skill state in ~/.config/transcribe/.
# The host process stays stdlib-only.
# ===========================================================================
VENV_DIR = CONFIG_DIR / "venv"
VENV_MARKER = VENV_DIR / ".provisioned.json"

# Battle-tested pin set - change it and provisioning self-heals on the next
# ensure_venv() because the marker signature no longer matches.
VENV_PINS = [
    "pyannote.audio==3.3.2",   # 4.x is broken on Windows + extra gated repo
    "huggingface_hub==0.25.2", # 1.x drops use_auth_token paths pyannote needs
    "matplotlib",              # imported unconditionally by pyannote 3.x
    "soundfile",               # in-memory decode, bypasses torchaudio backends
    "faster-whisper==1.2.1",   # local Whisper via ctranslate2 (torch-free)
]
TORCH_PINS_CPU = ["torch==2.6.0", "torchaudio==2.6.0"]
# pip refuses to swap an installed CPU wheel for CUDA without the explicit
# build tag, hence the +cu124 pins plus the dedicated index.
TORCH_PINS_GPU = ["torch==2.6.0+cu124", "torchaudio==2.6.0+cu124"]
TORCH_GPU_INDEX = "https://download.pytorch.org/whl/cu124"
# torch 2.6.0 ships CPython wheels for 3.9-3.13 only. The managed venv is
# created from THIS interpreter (sys.executable), so a host Python outside
# that window makes the torch pin unsatisfiable - and pip's bare "Could not
# find a version that satisfies torch==2.6.0+cu124" gives no hint why. Guard
# up front with an actionable message instead.
TORCH_PY_MIN = (3, 9)
TORCH_PY_MAX = (3, 13)

# Auto-download sources (Linux+Windows). macOS still routes through Homebrew.
# All three are stable URLs that always point at the current release; no
# version pinning needed unless an upstream changes the URL shape.
YTDLP_URLS = {
    "linux-amd64": "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux",
    "linux-arm64": "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux_aarch64",
    "windows-x64": "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe",
    "macos":       "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos",
}

FFMPEG_URLS = {
    # johnvansickle = long-standing free static builds for Linux, ships ffmpeg + ffprobe in one tarball
    "linux-amd64": "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz",
    "linux-arm64": "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz",
    # gyan.dev = the standard Windows ffmpeg distribution
    "windows-x64": "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip",
    # macOS intentionally omitted - brew is the right path there
}
# The .env template is a real file at the repo / skill root, not an embedded
# string - one canonical source, browsable in the repo, shipped in the skill
# bundle via `git archive`. scripts/ is one level below the root.
ENV_EXAMPLE_PATH = Path(__file__).resolve().parent.parent / ".env.example"


def _env_template() -> str:
    """Return the .env scaffold text, read from .env.example.

    Raises SystemExit with an actionable message if the file is missing -
    that only happens on a broken/partial install, and a stale embedded
    fallback would just mask it.
    """
    try:
        return ENV_EXAMPLE_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(
            f"[setup] template not found: {ENV_EXAMPLE_PATH} ({exc}). "
            "The skill install looks incomplete - reinstall it."
        )


def _exe_suffix() -> str:
    return ".exe" if IS_WINDOWS else ""


def find_tool(name: str) -> str | None:
    """Locate ffmpeg / ffprobe / yt-dlp. Prefer the standalone install
    in `~/.transcribe/bin/`, then fall back to anything on PATH.

    Returned path is absolute so subprocess.run can use it verbatim.
    Returns None if the binary cannot be found in either location.
    """
    candidate = TRANSCRIBE_BIN_DIR / f"{name}{_exe_suffix()}"
    if candidate.exists() and candidate.is_file():
        return str(candidate)
    return shutil.which(name)


def _which(name: str) -> str | None:
    """Back-compat alias - the rest of this module uses find_tool now."""
    return find_tool(name)


def _check_binaries() -> list[str]:
    return [b for b in REQUIRED_BINARIES if not find_tool(b)]


def _detect_target() -> str | None:
    """Map (system, machine) to a download-target key, or None if we don't ship one."""
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Linux":
        if machine in ("x86_64", "amd64"):
            return "linux-amd64"
        if machine in ("aarch64", "arm64"):
            return "linux-arm64"
        return None
    if system == "Windows":
        if machine in ("amd64", "x86_64"):
            return "windows-x64"
        return None
    if system == "Darwin":
        return "macos"
    return None


def _download(url: str, dest: Path) -> None:
    """Stream a URL to disk. Coarse 10%-step progress, to stderr."""
    sys.stderr.write(f"[setup] downloading {url}\n")
    sys.stderr.flush()
    req = urllib.request.Request(url, headers={"User-Agent": "transcribe-skill/0.3"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        total = int(resp.headers.get("Content-Length") or 0)
        chunk_size = 1024 * 256
        written = 0
        last_decile = -1
        with open(dest, "wb") as f:
            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                f.write(chunk)
                written += len(chunk)
                if total:
                    decile = (written * 10) // total
                    if decile > last_decile:
                        sys.stderr.write(
                            f"[setup]   {decile*10:3d}%  ({written // (1024*1024)} MB"
                            f" / {total // (1024*1024)} MB)\n"
                        )
                        sys.stderr.flush()
                        last_decile = decile
    sys.stderr.write(f"[setup] saved -> {dest.name} ({dest.stat().st_size // (1024*1024)} MB)\n")


def _install_ytdlp(target: str, force: bool = False) -> bool:
    """Drop yt-dlp[.exe] into TRANSCRIBE_BIN_DIR."""
    suffix = ".exe" if target == "windows-x64" else ""
    out = TRANSCRIBE_BIN_DIR / f"yt-dlp{suffix}"
    if out.exists() and not force:
        sys.stderr.write(f"[setup] yt-dlp already in {out} (use --force to refresh)\n")
        return True
    url = YTDLP_URLS.get(target)
    if not url:
        sys.stderr.write(f"[setup] no yt-dlp standalone for target '{target}'\n")
        return False
    TRANSCRIBE_BIN_DIR.mkdir(parents=True, exist_ok=True)
    _download(url, out)
    if target != "windows-x64":
        out.chmod(0o755)
    return True


def _install_ffmpeg(target: str, force: bool = False) -> bool:
    """Unpack ffmpeg+ffprobe into TRANSCRIBE_BIN_DIR. macOS routes through brew."""
    if target == "macos":
        sys.stderr.write(
            "[setup] macOS auto-install for ffmpeg is not bundled - "
            "run `brew install ffmpeg` instead.\n"
        )
        return False

    suffix = ".exe" if target == "windows-x64" else ""
    ffmpeg_out = TRANSCRIBE_BIN_DIR / f"ffmpeg{suffix}"
    ffprobe_out = TRANSCRIBE_BIN_DIR / f"ffprobe{suffix}"
    if ffmpeg_out.exists() and ffprobe_out.exists() and not force:
        sys.stderr.write(
            f"[setup] ffmpeg+ffprobe already in {TRANSCRIBE_BIN_DIR} (use --force to refresh)\n"
        )
        return True

    url = FFMPEG_URLS.get(target)
    if not url:
        sys.stderr.write(f"[setup] no ffmpeg build for target '{target}'\n")
        return False

    TRANSCRIBE_BIN_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="transcribe-ffmpeg-") as tmp:
        tmp_path = Path(tmp)
        archive_path = tmp_path / url.rsplit("/", 1)[-1]
        _download(url, archive_path)

        sys.stderr.write(f"[setup] extracting {archive_path.name}...\n")
        if url.endswith(".zip"):
            with zipfile.ZipFile(archive_path) as zf:
                zf.extractall(tmp_path)
        else:  # tar.xz from johnvansickle
            with tarfile.open(archive_path, "r:xz") as tf:
                # Python 3.12 made `filter='data'` the safe default. Older
                # versions don't take the kwarg - fall back transparently.
                try:
                    tf.extractall(tmp_path, filter="data")
                except TypeError:
                    tf.extractall(tmp_path)

        ffmpeg_name = f"ffmpeg{suffix}"
        ffprobe_name = f"ffprobe{suffix}"
        ffmpeg_src = next(
            (p for p in tmp_path.rglob(ffmpeg_name) if p.is_file()), None
        )
        ffprobe_src = next(
            (p for p in tmp_path.rglob(ffprobe_name) if p.is_file()), None
        )
        if not ffmpeg_src or not ffprobe_src:
            sys.stderr.write(
                f"[setup] could not find {ffmpeg_name}/{ffprobe_name} inside the archive\n"
            )
            return False

        shutil.copy2(ffmpeg_src, ffmpeg_out)
        shutil.copy2(ffprobe_src, ffprobe_out)
        if target != "windows-x64":
            ffmpeg_out.chmod(0o755)
            ffprobe_out.chmod(0o755)

    sys.stderr.write(f"[setup] installed ffmpeg + ffprobe -> {TRANSCRIBE_BIN_DIR}\n")
    return True


def cmd_install_binaries(force: bool = False) -> int:
    """Download standalone ffmpeg + ffprobe + yt-dlp into ~/.transcribe/bin/."""
    target = _detect_target()
    if not target:
        sys.stderr.write(
            f"[setup] unsupported platform ({platform.system()} / {platform.machine()}) - "
            "install ffmpeg, ffprobe, yt-dlp manually.\n"
        )
        return 2

    sys.stderr.write(
        f"[setup] target: {target} | install dir: {TRANSCRIBE_BIN_DIR}\n"
    )
    try:
        _install_ytdlp(target, force=force)
    except Exception as exc:
        sys.stderr.write(f"[setup] yt-dlp install failed: {exc}\n")
    try:
        _install_ffmpeg(target, force=force)
    except Exception as exc:
        sys.stderr.write(f"[setup] ffmpeg install failed: {exc}\n")

    missing = _check_binaries()
    if missing:
        sys.stderr.write(f"[setup] still missing after install: {', '.join(missing)}\n")
        return 2

    sys.stderr.write(
        "[setup] all binaries available. find_tool() will return paths in "
        f"{TRANSCRIBE_BIN_DIR} unless system-PATH versions are present.\n"
    )
    _print_path_snippets()
    return 0


def _print_path_snippets() -> None:
    """Show platform-appropriate PATH-add snippets for ~/.transcribe/bin.

    The skill itself uses `find_tool()` and doesn't need the binaries on
    PATH. But users (and other shell-driven tools) often want to invoke
    `ffmpeg` / `ffprobe` / `yt-dlp` directly — e.g. for ad-hoc inspection.
    Print copy-pasteable snippets for the major shells. We deliberately
    do NOT auto-modify rc files: too invasive, too easy to get wrong.
    """
    sys.stderr.write("\n")
    sys.stderr.write(
        "[setup] To call ffmpeg / ffprobe / yt-dlp directly from a shell\n"
        f"[setup] (the transcribe skill itself works without this), add\n"
        f"[setup]   {TRANSCRIBE_BIN_DIR}\n"
        f"[setup] to PATH. Snippets per shell:\n\n"
    )
    if IS_WINDOWS:
        bin_str = str(TRANSCRIBE_BIN_DIR)
        # Use generic %USERPROFILE% / $HOME so the snippet survives a copy
        # to a different account name — and the literal path for the
        # current session where the user can paste verbatim.
        sys.stderr.write(
            "  PowerShell (current session only):\n"
            f"    $env:PATH = \"{bin_str};$env:PATH\"\n\n"
            "  PowerShell (persistent for current user, no admin):\n"
            f"    [Environment]::SetEnvironmentVariable('PATH',\n"
            f"      \"{bin_str};\" + [Environment]::GetEnvironmentVariable('PATH','User'),\n"
            f"      'User')\n\n"
            "  cmd (persistent for current user, no admin):\n"
            f"    setx PATH \"{bin_str};%PATH%\"\n\n"
            "  Git Bash / WSL (persistent — append to ~/.bashrc):\n"
            "    export PATH=\"$HOME/.transcribe/bin:$PATH\"\n"
        )
    else:
        sys.stderr.write(
            "  bash / zsh (current session):\n"
            "    export PATH=\"$HOME/.transcribe/bin:$PATH\"\n\n"
            "  bash (persistent - append to ~/.bashrc):\n"
            "    echo 'export PATH=\"$HOME/.transcribe/bin:$PATH\"' >> ~/.bashrc\n\n"
            "  zsh (persistent - append to ~/.zshrc):\n"
            "    echo 'export PATH=\"$HOME/.transcribe/bin:$PATH\"' >> ~/.zshrc\n\n"
            "  fish (persistent):\n"
            "    fish_add_path $HOME/.transcribe/bin\n"
        )
    sys.stderr.write("\n")


# Cache of paths whose permissions we've already checked this process.
# Prevents repeat stat() calls when _read_env_key is invoked five times
# in a single preflight (once per Whisper/Diarize key).
_perm_checked: set[Path] = set()


def _check_file_permissions(path: Path) -> None:
    """Warn to stderr if a secrets file is world/group readable.

    POSIX-only. On Windows, `stat().st_mode` surfaces synthetic mode bits
    that don't reflect real NTFS ACL permissions (typically 0o666 or 0o644
    by default even though the file is owner-only via the ACL), and
    `chmod 600` isn't a Windows command anyway. Skipping the check there
    avoids a false-positive warning that the user can't act on.

    Idempotent within a single process - first call does the stat, later
    calls for the same path short-circuit. Important because every
    `_read_env_key` invocation triggers this, and a preflight reads five
    keys (two Whisper variants + three diarize keys).
    """
    if IS_WINDOWS:
        return
    if path in _perm_checked:
        return
    _perm_checked.add(path)
    try:
        mode = path.stat().st_mode
        if mode & 0o044:
            sys.stderr.write(
                f"[transcribe] WARNING: {path} is readable by other users. "
                f"Run: chmod 600 {path}\n"
            )
            sys.stderr.flush()
    except OSError:
        pass


def _read_env_key(name: str) -> str | None:
    value = os.environ.get(name)
    if value and value.strip():
        return value.strip()
    if not CONFIG_FILE.exists():
        return None
    _check_file_permissions(CONFIG_FILE)
    try:
        for line in CONFIG_FILE.read_text().splitlines():
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


def _have_api_key() -> tuple[bool, str | None]:
    if _read_env_key("GROQ_API_KEY"):
        return True, "groq"
    if _read_env_key("OPENAI_API_KEY"):
        return True, "openai"
    return False, None


def _upsert_env_value(name: str, value: str) -> None:
    """Set `name=value` in CONFIG_FILE. Updates existing line in place,
    or appends one. Preserves comments, layout, and 0600 perms."""
    if not CONFIG_FILE.exists():
        _scaffold_env()
    lines = CONFIG_FILE.read_text().splitlines()
    found = False
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        # Don't touch commented placeholders - only real config lines.
        if stripped.startswith("#"):
            continue
        if stripped.startswith(f"{name}="):
            lines[i] = f"{name}={value}"
            found = True
            break
    if not found:
        lines.append(f"{name}={value}")
    CONFIG_FILE.write_text("\n".join(lines) + "\n")
    try:
        CONFIG_FILE.chmod(0o600)
    except OSError:
        pass


def _prompt_for_key(name: str, label: str, signup_url: str) -> str | None:
    """One interactive key prompt. Returns the stripped value, or None on skip."""
    print(f"  {name}")
    print(f"    {label}")
    print(f"    sign up: {signup_url}")
    try:
        value = input("    paste key (or Enter to skip): ").strip()
    except (EOFError, KeyboardInterrupt):
        print("")
        return None
    print("")
    return value if value else None


def _diarize_is_dismissed() -> bool:
    """True if the user has explicitly opted out of diarization features.

    Honored by cmd_check to suppress the optional-keys-missing nag for
    users who actively don't want diarization. Stored as
    `DIARIZE_DISMISSED=true` in `~/.config/transcribe/.env`.
    """
    return _read_env_key("DIARIZE_DISMISSED") == "true"


def _interactive_keys_prompt() -> None:
    """Walk through required + optional API keys, save what the user pastes.

    Runs only when stdin is a TTY - non-interactive callers (CI, automated
    invocations from Claude) fall through to the existing "edit the file"
    instructions in cmd_install. Each prompt accepts an empty line as
    "skip - I'll edit later". Stored values pass through `_upsert_env_value`
    which updates existing lines in place.

    Whisper logic: prefer Groq, only ask about OpenAI if Groq is skipped.
    Diarization is gated behind a single yes/no - most users don't need it,
    no point walking through three prompts they'll all skip. If the user
    says no, DIARIZE_DISMISSED=true is written so the optional-keys nag in
    cmd_check stays quiet thereafter.
    """
    if not sys.stdin.isatty():
        return

    print("")
    print("[setup] interactive key entry (press Enter to skip any prompt):")
    print("")

    # Whisper - at least one is needed for transcription of caption-less videos.
    if not _read_env_key("GROQ_API_KEY") and not _read_env_key("OPENAI_API_KEY"):
        groq = _prompt_for_key(
            "GROQ_API_KEY",
            "Groq Whisper - preferred (cheaper, faster than OpenAI)",
            "https://console.groq.com/keys",
        )
        if groq:
            _upsert_env_value("GROQ_API_KEY", groq)
        else:
            openai = _prompt_for_key(
                "OPENAI_API_KEY",
                "OpenAI Whisper - fallback when Groq is unavailable",
                "https://platform.openai.com/api-keys",
            )
            if openai:
                _upsert_env_value("OPENAI_API_KEY", openai)

    # Diarization gate - single yes/no before the three sub-prompts.
    # Skipping the whole section sets DIARIZE_DISMISSED so the user
    # doesn't keep getting nagged about optional keys they don't want.
    any_diarize_set = (
        _read_env_key("ASSEMBLYAI_API_KEY")
        or _read_env_key("PYANNOTE_API_KEY")
        or _read_env_key("HF_TOKEN")
        or _read_env_key("HUGGINGFACE_TOKEN")
    )
    if not any_diarize_set and not _diarize_is_dismissed():
        print("  Speaker diarization (optional - labels who says what)")
        print("    Add this if you want speaker-attributed transcripts.")
        try:
            answer = input("    Configure diarization keys now? [y/N]: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            answer = ""
        print("")
        if answer not in ("y", "yes", "j", "ja"):
            _upsert_env_value("DIARIZE_DISMISSED", "true")
            return  # Skip the three diarize sub-prompts entirely.

    # Diarization sub-prompts - only reached if the user opted in above
    # (or had a key partially configured already).
    if not _read_env_key("ASSEMBLYAI_API_KEY"):
        v = _prompt_for_key(
            "ASSEMBLYAI_API_KEY",
            "AssemblyAI - cloud transcription + speaker labels in one call (~$0.37/h)",
            "https://www.assemblyai.com/dashboard/api-keys",
        )
        if v:
            _upsert_env_value("ASSEMBLYAI_API_KEY", v)

    if not _read_env_key("PYANNOTE_API_KEY"):
        v = _prompt_for_key(
            "PYANNOTE_API_KEY",
            "pyannote.ai - diarization-only, aligned to Whisper transcript",
            "https://www.pyannote.ai/",
        )
        if v:
            _upsert_env_value("PYANNOTE_API_KEY", v)

    if not _read_env_key("HF_TOKEN") and not _read_env_key("HUGGINGFACE_TOKEN"):
        v = _prompt_for_key(
            "HF_TOKEN",
            "Hugging Face token - required for pyannote local model",
            "https://huggingface.co/pyannote/speaker-diarization-3.1",
        )
        if v:
            _upsert_env_value("HF_TOKEN", v)


def is_first_run() -> bool:
    """True if the installer hasn't completed successfully yet."""
    return _read_env_key("SETUP_COMPLETE") != "true"


def _scaffold_env() -> bool:
    """Create ~/.config/transcribe/.env with placeholders if missing."""
    if CONFIG_FILE.exists():
        return False
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(_env_template(), encoding="utf-8")
    try:
        CONFIG_FILE.chmod(0o600)
    except OSError:
        pass
    return True


def _write_setup_complete() -> None:
    """Idempotently append SETUP_COMPLETE=true to .env.

    Used only after a fully successful install (deps + key). Future sessions
    detect this marker to skip wizard-style UI and stay silent.
    """
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    existing = ""
    if CONFIG_FILE.exists():
        existing = CONFIG_FILE.read_text()
        for line in existing.splitlines():
            if line.strip().startswith("SETUP_COMPLETE="):
                return
        if existing and not existing.endswith("\n"):
            existing += "\n"
        CONFIG_FILE.write_text(existing + "SETUP_COMPLETE=true\n")
    else:
        CONFIG_FILE.write_text(
            _env_template() + "\nSETUP_COMPLETE=true\n", encoding="utf-8"
        )
    try:
        CONFIG_FILE.chmod(0o600)
    except OSError:
        pass


def _brew_pkg(missing: list[str]) -> list[str]:
    pkgs: list[str] = []
    for bin_name in missing:
        if bin_name in ("ffmpeg", "ffprobe"):
            if "ffmpeg" not in pkgs:
                pkgs.append("ffmpeg")
        elif bin_name == "yt-dlp":
            if "yt-dlp" not in pkgs:
                pkgs.append("yt-dlp")
        else:
            pkgs.append(bin_name)
    return pkgs


def _install_macos(missing: list[str]) -> tuple[bool, str]:
    if _which("brew") is None:
        return False, (
            "Homebrew is not installed. Install it from https://brew.sh, then re-run setup. "
            "Or install manually: `brew install " + " ".join(_brew_pkg(missing)) + "`"
        )
    pkgs = _brew_pkg(missing)
    if not pkgs:
        return True, "nothing to install"
    cmd = ["brew", "install", *pkgs]
    print(f"[setup] running: {' '.join(cmd)}", file=sys.stderr)
    result = subprocess.run(cmd)
    if result.returncode != 0:
        return False, f"brew install failed with exit code {result.returncode}"
    return True, f"installed via brew: {', '.join(pkgs)}"


def _install_hint_linux(missing: list[str]) -> str:
    pkgs = _brew_pkg(missing)
    hints = []
    hints.append(
        f"`python3 {Path(__file__).resolve()} --install-binaries` "
        f"(standalone, no global install, lands in {TRANSCRIBE_BIN_DIR})"
    )
    if "ffmpeg" in pkgs:
        hints.append("or via package manager: `sudo apt install ffmpeg` / `sudo dnf install ffmpeg`")
    if "yt-dlp" in pkgs:
        hints.append("or via pipx: `pipx install yt-dlp`")
    return "\n  ".join(hints) if hints else "nothing to install"


def _install_hint_windows(missing: list[str]) -> str:
    pkgs = _brew_pkg(missing)
    hints = []
    hints.append(
        f"`python {Path(__file__).resolve()} --install-binaries` "
        f"(standalone, no global install, lands in {TRANSCRIBE_BIN_DIR})"
    )
    if "ffmpeg" in pkgs:
        hints.append("or via winget: `winget install Gyan.FFmpeg`")
    if "yt-dlp" in pkgs:
        hints.append("or via winget: `winget install yt-dlp.yt-dlp`")
    return "\n  ".join(hints) if hints else "nothing to install"


def venv_python() -> Path:
    """Path of the managed venv's interpreter (existence not guaranteed)."""
    sub = ("Scripts", "python.exe") if IS_WINDOWS else ("bin", "python")
    return VENV_DIR.joinpath(*sub)


def _gpu_available() -> bool:
    """CUDA GPU present? nvidia-smi on PATH and answering is good enough."""
    smi = shutil.which("nvidia-smi")
    if not smi:
        return False
    try:
        return subprocess.run(
            [smi, "-L"], capture_output=True, timeout=10
        ).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _python_torch_incompatible() -> str | None:
    """Return an actionable message if this interpreter can't host the torch
    pins, else None. The managed venv inherits sys.executable's version.
    """
    ver = sys.version_info[:2]
    if TORCH_PY_MIN <= ver <= TORCH_PY_MAX:
        return None
    want = f"{TORCH_PY_MIN[0]}.{TORCH_PY_MIN[1]}-{TORCH_PY_MAX[0]}.{TORCH_PY_MAX[1]}"
    have = f"{ver[0]}.{ver[1]}"
    hint = (
        f"py -{TORCH_PY_MAX[0]}.{TORCH_PY_MAX[1]} \"{Path(__file__).resolve()}\" --venv"
        if IS_WINDOWS
        else f"python{TORCH_PY_MAX[0]}.{TORCH_PY_MAX[1]} {Path(__file__).resolve()} --venv"
    )
    return (
        f"Python {have} is outside torch 2.6.0's supported range ({want}). The "
        f"managed ML venv is built from this interpreter, so the torch wheels "
        f"won't resolve (pip would just say 'no matching distribution'). Re-run "
        f"with a supported interpreter, e.g.:\n  {hint}"
    )


def _venv_signature(gpu: bool) -> str:
    """Fingerprint of the desired venv state - pins + torch flavor + python."""
    import hashlib

    payload = json.dumps({
        "pins": VENV_PINS,
        "torch": TORCH_PINS_GPU if gpu else TORCH_PINS_CPU,
        "python": f"{sys.version_info.major}.{sys.version_info.minor}",
    }, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def venv_status() -> dict:
    """Desired-state check: {'ready': bool, 'reason': str, 'gpu': bool}."""
    gpu = _gpu_available()
    if not venv_python().exists():
        return {"ready": False, "reason": "venv missing", "gpu": gpu}
    try:
        marker = json.loads(VENV_MARKER.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"ready": False, "reason": "marker missing/corrupt", "gpu": gpu}
    if marker.get("signature") != _venv_signature(gpu):
        return {"ready": False, "reason": "pins or GPU availability changed", "gpu": gpu}
    return {"ready": True, "reason": "", "gpu": gpu}


def cmd_provision_venv(force: bool = False) -> int:
    """Create/repair the managed ML venv. Idempotent: no-op when ready.

    Mutations only happen when the actual state differs from the desired
    state (or --force). Safe to re-run after an aborted install - pip's
    wheel cache makes the retry cheap.
    """
    status = venv_status()
    if status["ready"] and not force:
        sys.stderr.write(f"[setup] ML venv ready: {VENV_DIR}\n")
        return 0

    incompatible = _python_torch_incompatible()
    if incompatible:
        sys.stderr.write(f"[setup] ERROR: {incompatible}\n")
        return 1

    gpu = status["gpu"]
    flavor = "GPU (cu124)" if gpu else "CPU"
    sys.stderr.write(
        f"[setup] provisioning ML venv ({flavor}) at {VENV_DIR} "
        f"({status['reason'] or 'forced'}) - one-time download, "
        f"{'~2.5 GB' if gpu else '~300 MB'}...\n"
    )

    # Recreate from scratch when the interpreter is missing or the marker
    # records a different Python - in-place pip surgery across interpreter
    # versions is not worth debugging.
    py_now = f"{sys.version_info.major}.{sys.version_info.minor}"
    marker_py = None
    try:
        marker_py = json.loads(VENV_MARKER.read_text(encoding="utf-8")).get("python")
    except (OSError, ValueError):
        pass
    if not venv_python().exists() or (marker_py and marker_py != py_now) or force:
        if VENV_DIR.exists():
            shutil.rmtree(VENV_DIR)
        result = subprocess.run([sys.executable, "-m", "venv", str(VENV_DIR)])
        if result.returncode != 0:
            sys.stderr.write("[setup] ERROR: venv creation failed\n")
            return 1

    pip = [str(venv_python()), "-m", "pip", "install", "--quiet"]
    # torch first (own index for GPU) so nothing pulls a CPU torch as a dep.
    torch_cmd = pip + (TORCH_PINS_GPU + ["--index-url", TORCH_GPU_INDEX] if gpu
                       else TORCH_PINS_CPU)
    if subprocess.run(torch_cmd).returncode != 0:
        sys.stderr.write("[setup] ERROR: torch install failed\n")
        return 1
    if subprocess.run(pip + VENV_PINS).returncode != 0:
        sys.stderr.write("[setup] ERROR: ML pins install failed\n")
        return 1

    VENV_MARKER.write_text(json.dumps({
        "signature": _venv_signature(gpu),
        "gpu": gpu,
        "python": py_now,
        "pins": VENV_PINS + (TORCH_PINS_GPU if gpu else TORCH_PINS_CPU),
    }, indent=2), encoding="utf-8")
    sys.stderr.write(f"[setup] ML venv ready: {VENV_DIR}\n")
    return 0


def ensure_venv() -> Path:
    """Return the venv's python, provisioning on demand. SystemExit on failure.

    This is the lazy entry point the worker launchers (diarize.py, stt.py)
    call - first use of a local backend triggers the one-time provisioning.
    """
    if not venv_status()["ready"]:
        if cmd_provision_venv() != 0:
            raise SystemExit(
                "managed ML venv provisioning failed - re-run "
                f"`python {Path(__file__).resolve()} --venv` to retry/repair"
            )
    return venv_python()


def run_venv_worker(script_name: str, args: list[str],
                    env_extra: dict[str, str] | None = None) -> str:
    """Run a worker script inside the managed venv, return its stdout.

    Worker contract: JSON result on stdout, progress on stderr (inherited so
    the user sees it live). Non-zero exit raises SystemExit with the tail of
    the captured stdout for context.
    """
    worker = Path(__file__).resolve().parent / script_name
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        [str(ensure_venv()), str(worker), *args],
        stdout=subprocess.PIPE,  # JSON result; stderr stays live on the console
        text=True,
        encoding="utf-8",
        env=env,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"{script_name} failed (exit {result.returncode}): "
            f"{(result.stdout or '')[-500:]}"
        )
    return result.stdout


def _diarize_backends_configured() -> list[str]:
    """Return diarization backends that have their credentials in place.

    Same priority order as diarize.pick_backend("auto") - local first.
    Reports *configurability*, not "is the library actually importable" -
    keep setup.py free of optional-dependency probing.
    """
    out: list[str] = []
    if _read_env_key("HF_TOKEN") or _read_env_key("HUGGINGFACE_TOKEN"):
        out.append("pyannote-local")
    if _read_env_key("PYANNOTE_API_KEY"):
        out.append("pyannote-api")
    if _read_env_key("ASSEMBLYAI_API_KEY"):
        out.append("assemblyai")
    return out


def _status() -> dict:
    """Structured preflight snapshot."""
    missing = _check_binaries()
    has_key, backend = _have_api_key()
    diarize_configured = _diarize_backends_configured()
    venv = venv_status()
    # A ready ML venv is a full transcription path of its own (whisper-local),
    # so "no cloud key" no longer blocks readiness when the venv is in place.
    has_transcription = has_key or venv["ready"]
    if not has_key and venv["ready"]:
        backend = "whisper-local"

    if not missing and has_transcription:
        status = "ready"
    elif missing and not has_transcription:
        status = "needs_install_and_key"
    elif missing:
        status = "needs_install"
    else:
        status = "needs_key"

    return {
        "status": status,
        "first_run": is_first_run(),
        "missing_binaries": missing,
        "whisper_backend": backend,
        "has_api_key": has_key,
        "diarize_configured": diarize_configured,
        "local_venv": {"ready": venv["ready"], "gpu": venv["gpu"],
                       "path": str(VENV_DIR)},
        "config_file": str(CONFIG_FILE),
        "platform": platform.system(),
    }


def cmd_check() -> int:
    """Preflight check that surfaces *every* missing key, required or optional.

    - Required (binaries + a Whisper key) drives the exit code:
        2 -> binaries missing
        3 -> Whisper API key missing
        4 -> both missing
        0 -> required features OK
    - Optional (diarization keys) is reported as info regardless of exit
      code, so users can see what `--diarize` would lack without having
      to re-run setup interactively.

    Stays fully silent only when *everything* - required + optional - is
    configured. That's the only case where Claude has nothing to surface.
    """
    s = _status()

    # Itemise all missing keys, with category. Specific names so the user
    # knows exactly what to set, not just "something is missing". A ready
    # ML venv (whisper-local) satisfies the transcription requirement
    # without any cloud key.
    missing_required: list[str] = []
    if (not _read_env_key("GROQ_API_KEY") and not _read_env_key("OPENAI_API_KEY")
            and not s["local_venv"]["ready"]):
        missing_required.append(
            "GROQ_API_KEY or OPENAI_API_KEY (or `setup.py --venv` for "
            "fully local whisper-local)"
        )

    # Diarization is optional and local-first. Only nag when NO backend is
    # configured at all - if even one is wired (HF_TOKEN -> pyannote-local,
    # or a cloud key), diarization already works and the rest are mere
    # alternatives, not "needed".
    suggest_diarize = not _diarize_is_dismissed() and not s["diarize_configured"]

    # Fully ready -> stay silent (Claude's per-turn preflight shouldn't spam).
    if not s["missing_binaries"] and not missing_required and not suggest_diarize:
        return 0

    installer = Path(__file__).resolve()

    if s["missing_binaries"] or missing_required:
        parts: list[str] = []
        if s["missing_binaries"]:
            parts.append(f"missing binaries: {', '.join(s['missing_binaries'])}")
        if missing_required:
            parts.append(
                "missing required keys: " + ", ".join(missing_required)
            )
        sys.stderr.write(
            f"[transcribe] setup incomplete ({'; '.join(parts)}). "
            f"Run: python3 {installer}\n"
        )

    if suggest_diarize:
        # Local-first nudge: HF_TOKEN unlocks free, on-device diarization;
        # the cloud keys are alternatives. Transcription works regardless.
        sys.stderr.write(
            "[transcribe] speaker diarization is off (no backend configured). "
            "For free, on-device diarization add HF_TOKEN to "
            "~/.config/transcribe/.env and accept the pyannote licenses; "
            "PYANNOTE_API_KEY / ASSEMBLYAI_API_KEY are cloud alternatives. "
            "Transcription works without any of these. Run "
            "`setup.py --skip-diarize` to silence this hint.\n"
        )

    sys.stderr.flush()

    has_transcription = s["has_api_key"] or s["local_venv"]["ready"]
    if s["missing_binaries"] and not has_transcription:
        return 4
    if s["missing_binaries"]:
        return 2
    if not has_transcription:
        return 3
    # Required features OK, only optional missing -> success exit code,
    # but with the info already printed above.
    return 0


def cmd_json() -> int:
    json.dump(_status(), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def cmd_install() -> int:
    missing = _check_binaries()
    installed_deps = False
    if missing:
        system = platform.system()
        if system == "Darwin":
            ok, msg = _install_macos(missing)
            print(f"[setup] {msg}", file=sys.stderr)
            if not ok:
                return 2
            still_missing = _check_binaries()
            if still_missing:
                print(f"[setup] still missing after install: {', '.join(still_missing)}", file=sys.stderr)
                return 2
            installed_deps = True
        elif system in ("Linux", "Windows"):
            # Auto-route to the standalone-binary installer so first run on a
            # fresh Linux/Windows box is one-shot, not a two-command dance.
            print(
                f"[setup] dependencies missing on {system} - auto-installing "
                f"into {TRANSCRIBE_BIN_DIR}...",
                file=sys.stderr,
            )
            rc = cmd_install_binaries()
            if rc != 0:
                hint = (
                    _install_hint_linux(missing)
                    if system == "Linux"
                    else _install_hint_windows(missing)
                )
                print("  Fallback option: " + hint, file=sys.stderr)
                return rc
            still_missing = _check_binaries()
            if still_missing:
                print(
                    f"[setup] still missing after install: {', '.join(still_missing)}",
                    file=sys.stderr,
                )
                return 2
            installed_deps = True
        else:
            print(f"[setup] unsupported platform ({system}) for auto-install. Install manually:", file=sys.stderr)
            print(f"  missing: {', '.join(missing)}", file=sys.stderr)
            return 2

    created = _scaffold_env()
    if created:
        print(f"[setup] created config: {CONFIG_FILE}")
    else:
        print(f"[setup] config exists: {CONFIG_FILE}")

    # Interactive prompt path - TTY users get input() prompts; CI/non-TTY
    # users fall through silently to the existing "edit the file" hint below.
    _interactive_keys_prompt()

    has_key, backend = _have_api_key()
    # Local-first: transcription always works via whisper-local once the
    # binaries are present (the managed venv self-provisions on first use),
    # so setup is "ready" with no cloud key. Cloud keys are optional upgrades.
    _write_setup_complete()
    if has_key:
        print(f"[setup] ready. transcription: {backend} (cloud) + whisper-local on-device fallback.")
    else:
        print("[setup] ready. transcription runs on-device via whisper-local - "
              "no key needed; the managed venv self-provisions on the first /transcribe run.")
        print(f"  Optional cloud upgrades - edit {CONFIG_FILE}:")
        print("    GROQ_API_KEY / OPENAI_API_KEY   (faster Whisper via cloud)")
    if installed_deps:
        print("[setup] installed dependencies; /transcribe is fully set up.")
    _print_diarize_status()
    return 0


def _print_diarize_status() -> None:
    """Surface diarization-backend keys with the same prominence as Whisper.

    Reading the .env file's commented placeholders is too passive - many
    users go through setup and never realise that speaker diarization is
    available. Print an explicit summary that shows which keys are present
    and which would unlock additional features.
    """
    have_assembly = bool(_read_env_key("ASSEMBLYAI_API_KEY"))
    have_pyannote = bool(_read_env_key("PYANNOTE_API_KEY"))
    have_hf = bool(_read_env_key("HF_TOKEN") or _read_env_key("HUGGINGFACE_TOKEN"))

    print("")
    print("[setup] speaker diarization (optional, --diarize in /transcribe):")
    rows = [
        ("ASSEMBLYAI_API_KEY",
         "AssemblyAI - cloud, transcription + speaker labels in one call (~$0.37/h)",
         "https://www.assemblyai.com/dashboard/api-keys",
         have_assembly),
        ("PYANNOTE_API_KEY",
         "pyannote.ai - cloud, diarization-only, aligned to Whisper transcript",
         "https://www.pyannote.ai/",
         have_pyannote),
        ("HF_TOKEN",
         "pyannote local - fully on-device (managed venv, auto-provisioned on first use)",
         "https://huggingface.co/pyannote/speaker-diarization-3.1",
         have_hf),
    ]
    for var, desc, url, present in rows:
        mark = "  [x] set    " if present else "  [ ] not set"
        print(f"{mark}  {var:20s} - {desc}")
        if not present:
            print(f"               get a key: {url}")
    if not (have_assembly or have_pyannote or have_hf):
        print("")
        print("  Without any of these, /transcribe runs without speaker labels. Transcript")
        print("  still works fine, but lines are not attributed to individual speakers.")


def cmd_skip_diarize() -> int:
    """Mark diarization as dismissed so cmd_check stops nagging.

    Idempotent - running twice is harmless. Reversible by editing the
    .env and removing the DIARIZE_DISMISSED line (or setting it to false).
    """
    _scaffold_env()
    _upsert_env_value("DIARIZE_DISMISSED", "true")
    print(
        "[setup] diarization dismissed. cmd_check will no longer suggest "
        f"diarize keys. Edit {CONFIG_FILE} and remove the DIARIZE_DISMISSED "
        "line (or set it to false) to re-enable the hint.",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "--check":
            return cmd_check()
        if arg == "--json":
            return cmd_json()
        if arg == "--install-binaries":
            force = "--force" in sys.argv[2:]
            return cmd_install_binaries(force=force)
        if arg == "--venv":
            force = "--force" in sys.argv[2:]
            return cmd_provision_venv(force=force)
        if arg == "--skip-diarize":
            return cmd_skip_diarize()
    return cmd_install()


if __name__ == "__main__":
    raise SystemExit(main())
