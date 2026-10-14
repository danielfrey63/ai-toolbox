#!/usr/bin/env bash
# Compatibility wrapper; the portable builder is Python-only.
set -euo pipefail
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
    exec "$candidate" -X utf8 "$(dirname "$0")/build_skill.py" "$@"
  fi
done
echo 'Python 3.10+ required' >&2
exit 1
