#!/usr/bin/env python3
"""Skill version, resolved from the plugin manifest at runtime.

The AI-Toolbox versioning hooks bump `.claude-plugin/plugin.json` on every
edit and commit touching this skill, which makes that manifest the single
source of truth for "which version produced this?".

Reading it here instead of carrying a hand-maintained literal is not just
DRY - a literal in these scripts would never be bumped at all:
`bump-version.sh` resolves *any* file under `.agents/skills/<name>/` to the
plugin manifest, so the script-level `APP_VERSION` branch is unreachable for
a skill that ships a plugin.json. A literal would silently rot from its first
commit, which is worse than no stamp.

Upload bundles carry a generated .build-version from the same manifest.
Falls back to unknown only when neither version source is available.
"""
from __future__ import annotations

import json
from pathlib import Path

UNKNOWN_VERSION = "unknown"

# scripts/ -> skill root -> .claude-plugin/plugin.json
MANIFEST_PATH = Path(__file__).resolve().parent.parent / ".claude-plugin" / "plugin.json"


def _read_version() -> str:
    try:
        raw = json.loads(MANIFEST_PATH.read_text(encoding="utf-8")).get("version")
    except (OSError, ValueError):
        try:
            return (MANIFEST_PATH.parent.parent / ".build-version").read_text(encoding="utf-8").strip() or UNKNOWN_VERSION
        except OSError:
            return UNKNOWN_VERSION
    return raw.strip() if isinstance(raw, str) and raw.strip() else UNKNOWN_VERSION


APP_VERSION = _read_version()


if __name__ == "__main__":
    import sys

    if sys.argv[1:] and sys.argv[1] in ("-h", "--help"):
        print("usage: version.py\n\nPrints the skill version from .claude-plugin/plugin.json "
              "(bundle version or \"unknown\" without a manifest).\n\nA bare call prints the version.")
        raise SystemExit(0)
    print(APP_VERSION)
