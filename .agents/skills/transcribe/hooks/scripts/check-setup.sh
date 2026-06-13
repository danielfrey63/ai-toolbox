#!/usr/bin/env bash
# SessionStart hook for /transcribe — one-line status so users know what's wired up.
# Silent on ready state to avoid spam. Points at the installer when something
# is missing.
set -euo pipefail

CONFIG_FILE="$HOME/.config/transcribe/.env"

# Warn if the secrets file has loose permissions. POSIX only — on Windows
# (Git Bash / MSYS / Cygwin) NTFS ACLs don't map to Unix mode bits, so stat
# always reports 644/666 and `chmod 600` is a no-op; the check would be a
# false-positive the user can't act on.
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) : ;;  # Windows: skip perm check
  *)
    if [[ -f "$CONFIG_FILE" ]]; then
      perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || echo "")
      if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
        echo "/transcribe: WARNING — $CONFIG_FILE has permissions $perms (should be 600)."
        echo "  Fix: chmod 600 $CONFIG_FILE"
      fi
    fi
    ;;
esac

# Load API keys from the config file without exporting them.
read_key() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    echo "${!name}"
    return
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    awk -F= -v k="$name" '
      /^[[:space:]]*#/ { next }
      $1 == k {
        sub(/^[[:space:]]*/, "", $2); sub(/[[:space:]]*$/, "", $2);
        gsub(/^["'\'']|["'\'']$/, "", $2);
        print $2; exit
      }
    ' "$CONFIG_FILE"
  fi
}

HAS_FFMPEG=""
HAS_YTDLP=""
command -v ffmpeg >/dev/null 2>&1 && HAS_FFMPEG="yes"
command -v yt-dlp >/dev/null 2>&1 && HAS_YTDLP="yes"

HAS_GROQ="$(read_key GROQ_API_KEY)"
HAS_OPENAI="$(read_key OPENAI_API_KEY)"
HAS_HF="$(read_key HF_TOKEN)"
SETUP_COMPLETE="$(read_key SETUP_COMPLETE)"

# Missing binaries are the only hard blocker — transcription itself works
# on-device via whisper-local with no key once ffmpeg + yt-dlp are present.
if [[ -z "$HAS_FFMPEG" || -z "$HAS_YTDLP" ]]; then
  echo "/transcribe: needs ffmpeg + yt-dlp. Run \`python3 \$CLAUDE_PLUGIN_ROOT/scripts/setup.py\` once to install and scaffold config."
  exit 0
fi

# Binaries present → /transcribe is functional. Stay silent once setup is marked
# done or any path beyond captions is wired (HF token for local diarization,
# or a cloud key). Otherwise one gentle nudge toward local diarization.
if [[ "$SETUP_COMPLETE" == "true" || -n "$HAS_HF" || -n "$HAS_GROQ" || -n "$HAS_OPENAI" ]]; then
  exit 0
fi
echo "/transcribe: ready — on-device transcription works with no key. Add HF_TOKEN to ~/.config/transcribe/.env for local speaker diarization (free, fully on-device)."
