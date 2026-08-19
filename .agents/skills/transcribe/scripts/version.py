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

Falls back to "unknown" when the manifest is absent: `build-skill.sh` strips
`.claude-plugin/` from the claude.ai `.skill` bundle, so an uploaded skill
runs without one. An honest "unknown" beats a stale number.
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
        return UNKNOWN_VERSION
    return raw.strip() if isinstance(raw, str) and raw.strip() else UNKNOWN_VERSION


APP_VERSION = _read_version()


if __name__ == "__main__":
    print(APP_VERSION)
