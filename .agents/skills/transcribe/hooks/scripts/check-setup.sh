#!/usr/bin/env bash
# SessionStart delegates readiness and configuration checks to Python.
set -euo pipefail
SKILL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR="${TRANSCRIBE_BIN_DIR:-$HOME/.transcribe/bin}"
supported() {
  "$1" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1
}
# python3 can be an old system interpreter (macOS ships 3.9) while a newer one
# is installed alongside, so look for versioned names and the usual Homebrew
# prefixes before giving up, and finally for a uv-managed Python.
PYTHON=""
for candidate in python3 python python3.14 python3.13 python3.12 python3.11 python3.10 \
                 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if path="$(command -v "$candidate" 2>/dev/null)" && supported "$path"; then
    PYTHON="$path"
    break
  fi
done
if [[ -z "$PYTHON" && -x "$BIN_DIR/uv" ]]; then
  path="$("$BIN_DIR/uv" python find '>=3.10' 2>/dev/null || true)"
  if [[ -n "$path" ]] && supported "$path"; then
    PYTHON="$path"
  fi
fi
if [[ -z "$PYTHON" ]]; then
  echo "/transcribe: Python 3.10+ required. See $SKILL_ROOT/INSTALL.md."
  exit 0
fi
# Name the interpreter whenever plain python3 would not work, so the harness
# does not retry with the old one.
if ! { command -v python3 >/dev/null 2>&1 && supported python3; }; then
  echo "/transcribe: python3 is missing or older than 3.10; use $PYTHON for transcribe.py."
fi
if ! "$PYTHON" -X utf8 "$SKILL_ROOT/transcribe.py" doctor --profile local --json >/dev/null 2>&1; then
  echo "/transcribe: setup incomplete. Run: $PYTHON \"$SKILL_ROOT/transcribe.py\" doctor --profile local"
  echo "Installation: $SKILL_ROOT/INSTALL.md"
fi
