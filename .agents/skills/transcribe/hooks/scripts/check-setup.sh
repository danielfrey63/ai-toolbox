#!/usr/bin/env bash
# SessionStart delegates readiness and configuration checks to Python.
set -euo pipefail
SKILL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "/transcribe: Python 3.10+ required. See $SKILL_ROOT/INSTALL.md."
  exit 0
fi
if ! "$PYTHON" -X utf8 "$SKILL_ROOT/transcribe.py" doctor --profile local --json >/dev/null 2>&1; then
  echo "/transcribe: setup incomplete. Run: $PYTHON \"$SKILL_ROOT/transcribe.py\" doctor --profile local"
  echo "Installation: $SKILL_ROOT/INSTALL.md"
fi
