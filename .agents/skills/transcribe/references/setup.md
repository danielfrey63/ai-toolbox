# Setup and preflight details

Read this when `setup.py --check` exits non-zero, when the user asks about installation, cloud keys or the managed venv, or when a download fails and a stale yt-dlp is suspected. SKILL.md Step 0 covers the normal path.

All commands below use `python3`; on Windows use `python` (the `python3` command there is the Microsoft Store stub).

## Contents

- Exit codes of `--check`
- Advisory warnings
- Installer
- Managed venv (on-device backends)
- Standalone binaries and deno
- Cloud keys
- Structured mode (`--json`)

## Exit codes of `--check`

| Exit | Meaning | Action |
|------|---------|--------|
| `0` | Ready | Proceed silently, no status message to the user |
| `2` | Missing binaries (`ffmpeg` / `ffprobe` / `yt-dlp`) | Run the installer |
| `3` | No transcription path | Provision the local venv (`setup.py --venv`), do not ask for a key |
| `4` | Both missing | Run the installer (it provisions the local venv on a keyless box) |

## Advisory warnings

`--check` also reports problems that do not block a run but predict failures: a missing deno and a **yt-dlp older than 60 days**. yt-dlp version strings are release dates (`2026.07.04`), so the age is computed offline. A stale build is the most common cause of YouTube downloads dying with HTTP 403, missing formats or a PO-token demand. Remediation:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --install-binaries --force
```

`--force` matters: a plain `--install-binaries` skips anything `find_tool()` already resolves, and the stale copy on PATH is exactly that. Pass the warning on to the user only if a download then actually fails.

## Installer

The installer is idempotent and safe to re-run:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py"
```

- **macOS** – runs `brew install ffmpeg yt-dlp`.
- **Linux / Windows** – downloads standalone binaries into `~/.transcribe/bin/` (yt-dlp and deno from GitHub Releases, ffmpeg from johnvansickle on Linux / Gyan.dev on Windows). No `apt`, no `pip`, no admin rights. `find_tool()` in `setup.py` prefers `~/.transcribe/bin/` and falls back to PATH.

It also scaffolds `~/.config/transcribe/.env` with commented placeholders at `0600`, provisions the on-device whisper-local venv on a keyless box (so the first run leaves the machine transcription-ready) and writes `SETUP_COMPLETE=true`.

Arguments are order-free (`--force --install-binaries` equals `--install-binaries --force`), exactly one command is accepted per call, and an unrecognized argument is an error, never a silent fall-through to the interactive installer. `setup.py --help` lists the commands.

## Managed venv (on-device backends)

whisper-local and pyannote-local run as worker subprocesses inside a managed venv at `~/.config/transcribe/venv/`. The host Python is never modified. Provision it explicitly with:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --venv
```

- The venv is built by `uv` (bootstrapped as a standalone binary into `~/.transcribe/bin/`), which fetches its own managed CPython. The host Python version does not matter, also on a box with only a Python version the torch wheels do not support.
- `--check` / `--json` verify that the base interpreter recorded in the venv's `pyvenv.cfg` still exists. A venv whose base Python was upgraded or removed (scoop, pyenv, Homebrew bump) is reported **not ready** (exit `3`), and `--venv` rebuilds it from scratch instead of installing into a dead venv. A re-run after a Python update repairs itself.
- The only platform where the venv cannot be built is one `uv` ships no binary for (`venv_buildable: false` in `--json`). Only there is a cloud key the fallback.

## Standalone binaries and deno

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --install-binaries [--force]
```

This is what the default installer runs on Linux and Windows. Desired state: anything `find_tool()` already resolves (standalone dir first, then PATH) is skipped. `--force` downloads standalone copies regardless; since `find_tool()` prefers `~/.transcribe/bin/`, that is the escape hatch for a broken or outdated PATH version.

**deno** (recommended, installed automatically): yt-dlp needs a JS runtime for YouTube's EJS challenges; without one it runs in a deprecated no-JS mode and may lose formats. Both the default installer and `--install-binaries` place a standalone deno into `~/.transcribe/bin/` on every platform, and `download.py` prepends that directory to the yt-dlp subprocess PATH. A missing deno prints a `--check` hint but keeps exit 0 (local files do not need it).

## Cloud keys

**No cloud key is the normal, fully supported case – do not ask for one.** Cloud keys (`GROQ_API_KEY`, `OPENAI_API_KEY`, Azure, pyannote.ai, AssemblyAI) are an opt-in speed upgrade. Only set one up when the user explicitly asks for cloud transcription: write the matching line into `~/.config/transcribe/.env`. If the venv cannot be built (`venv_buildable: false`), offer a cloud key; only then is `--no-whisper` (frames-only for caption-less videos) the degraded path.

## Structured mode (`--json`)

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/setup.py" --json
```

Emits `{status, first_run, missing_binaries, ytdlp, recommended_missing, whisper_backend, has_api_key, diarize_configured, local_venv, venv_buildable, config_file, platform}`.

- `status`: `ready | needs_install | needs_local_venv | needs_install_and_local_venv`.
- `recommended_missing`: optional binaries such as deno, never affects `status`.
- `ytdlp`: `{path, version, release_date, age_days, stale}`, advisory.
- Branch on `venv_buildable` (can the venv be built at all?) and `local_venv.ready` / `first_run`. Provisioning is always `setup.py --venv`.
