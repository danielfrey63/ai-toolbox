#!/usr/bin/env bash
# bump-version.sh — generic per-artifact version bumper for the AI-Toolbox.
#
# Bumps the PATCH segment of a MAJOR.MINOR.PATCH version. The storage location
# is chosen by artifact type:
#   skill   — file under .agents/skills/<name>/  -> <name>/SKILL.md frontmatter metadata.version
#   claude  — CLAUDE.md                          -> trailing <!-- APP_VERSION: x.y.z --> marker
#   agent   — *.md whose parent directory is "agents" -> frontmatter top-level version
#   script  — *.sh/.ps1/.js/.mjs/.cjs/.py/.html  -> APP_VERSION constant (only if already present)
#
# A missing version is initialised to 0.0.1. The structural step (inserting the
# version field) is idempotent; once a version exists, a run only bumps it.
#
# Dual mode:
#   bump-version.sh <file>          — CLI: bump the artifact owning <file>
#   <hook-json> | bump-version.sh   — hook: reads tool_input.file_path from a
#                                     Claude Code / Codex PostToolUse payload
#
# Always exits 0 — a non-artifact edit is a silent no-op, so it is hook-safe.

APP_VERSION='0.0.3'
set -u

INIT_VERSION='0.0.1'
RESULT=''

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
bump-version — generic per-artifact version bumper for the AI-Toolbox.

Usage:
  bump-version.sh <file>        Bump the version of the artifact owning <file>.
  bump-version.sh -h|--help     Show this help.
  <hook-json> | bump-version.sh Hook mode: read the edited path from a Claude
                                Code / Codex PostToolUse JSON payload on stdin.

Artifact types (MAJOR.MINOR.PATCH version; the PATCH segment is bumped):
  skill   file under .agents/skills/<name>/  -> <name>/SKILL.md metadata.version
  claude  CLAUDE.md                          -> trailing <!-- APP_VERSION --> marker
  agent   *.md whose parent dir is "agents"   -> frontmatter version
  script  *.sh .ps1 .js .mjs .cjs .py .html   -> APP_VERSION constant (if present)

A missing version is initialised to 0.0.1. A non-artifact file is a no-op.
EOF
        exit 0 ;;
esac

# --- resolve target file ------------------------------------------------------
FILE=${1:-}
if [ -z "$FILE" ] && [ ! -t 0 ]; then
    INPUT=$(cat)
    FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -z "$FILE" ]; then
        FILE=$(printf '%s' "$INPUT" \
            | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 | sed 's/.*"\(.*\)"$/\1/')
    fi
fi
[ -n "$FILE" ] || exit 0
[ -f "$FILE" ] || exit 0
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

# --- helpers ------------------------------------------------------------------
bump_patch() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    case "${major}-${minor}-${patch}" in
        *[!0-9-]*|*--*|-*|*-) printf '%s' "$INIT_VERSION"; return ;;
    esac
    printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

re_escape() {
    # Escape regex metacharacters in a version string for safe use as a sed/awk
    # pattern. Versions are digits + dots, so escaping dots is sufficient.
    printf '%s' "${1//./\\.}"
}

fm_version() {
    # Echo the first MAJOR.MINOR.PATCH on a "version:" key inside the YAML
    # frontmatter, or nothing.
    awk '
        NR==1 && $0=="---" { fm=1; next }
        fm && $0=="---"     { exit }
        fm && /^[[:space:]]*version:/ {
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+/)) {
                print substr($0, RSTART, RLENGTH); exit
            }
        }
    ' "$1"
}

# --- detect artifact type -----------------------------------------------------
base=$(basename "$FILE")
parent=$(basename "$(dirname "$FILE")")
ext=${base##*.}
TYPE=''
TARGET=''

case "$FILE" in
    */.agents/skills/*)
        rest=${FILE#*/.agents/skills/}
        prefix=${FILE%/.agents/skills/*}
        skill_dir="$prefix/.agents/skills/${rest%%/*}"
        [ -f "$skill_dir/SKILL.md" ] && { TYPE=skill; TARGET="$skill_dir/SKILL.md"; }
        ;;
esac

if [ -z "$TYPE" ]; then
    if [ "$base" = 'SKILL.md' ]; then
        TYPE=skill; TARGET="$FILE"
    elif [ "$base" = 'CLAUDE.md' ]; then
        TYPE=claude; TARGET="$FILE"
    elif [ "$parent" = 'agents' ] && [ "$ext" = 'md' ]; then
        TYPE=agent; TARGET="$FILE"
    else
        case "$ext" in
            sh|ps1|js|mjs|cjs|py|html)
                grep -qE '(^|[^A-Za-z_])APP_VERSION' "$FILE" && { TYPE=script; TARGET="$FILE"; }
                ;;
        esac
    fi
fi

[ -n "$TYPE" ] || exit 0

# --- bump implementations -----------------------------------------------------
bump_frontmatter() {
    local f=$1 mode=$2 cur new tmp
    cur=$(fm_version "$f")
    tmp=$(mktemp)
    if [ -n "$cur" ]; then
        new=$(bump_patch "$cur")
        awk -v cur="$cur" -v cur_re="$(re_escape "$cur")" -v new="$new" '
            NR==1 && $0=="---" { fm=1; print; next }
            fm && $0=="---"     { fm=0; print; next }
            fm && !done && $0 ~ /^[[:space:]]*version:/ && index($0, cur) {
                sub(cur_re, new); done=1
            }
            { print }
        ' "$f" > "$tmp"
        RESULT="$cur -> $new"
    else
        new=$INIT_VERSION
        if [ "$mode" = 'skill' ]; then
            awk -v ver="$new" '
                NR==1 && $0=="---" { fm=1; print; next }
                fm && /^metadata:[[:space:]]*$/ {
                    print; print "  version: \"" ver "\""; ins=1; next
                }
                fm && $0=="---" {
                    if (!ins) { print "metadata:"; print "  version: \"" ver "\"" }
                    fm=0; print; next
                }
                { print }
            ' "$f" > "$tmp"
        else
            awk -v ver="$new" '
                NR==1 && $0=="---" { fm=1; print; next }
                fm && $0=="---" {
                    if (!ins) print "version: \"" ver "\"";
                    fm=0; print; next
                }
                { print }
            ' "$f" > "$tmp"
        fi
        RESULT="(init) $new"
    fi
    mv "$tmp" "$f"
}

bump_marker() {
    local f=$1 cur new
    cur=$(grep -oE 'APP_VERSION:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$f" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$cur" ]; then
        [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf '\n' >> "$f"
        printf '\n<!-- APP_VERSION: %s -->\n' "$INIT_VERSION" >> "$f"
        RESULT="(init) $INIT_VERSION"
        return
    fi
    new=$(bump_patch "$cur")
    sed -i "/APP_VERSION:/ s/$(re_escape "$cur")/$new/" "$f"
    RESULT="$cur -> $new"
}

bump_script() {
    local f=$1 cur new
    cur=$(grep -oE "APP_VERSION[^0-9]*['\"][0-9]+\.[0-9]+\.[0-9]+['\"]" "$f" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$cur" ] || exit 0
    new=$(bump_patch "$cur")
    sed -i "/APP_VERSION/ s/$(re_escape "$cur")/$new/" "$f"
    RESULT="$cur -> $new"
}

case "$TYPE" in
    skill)  bump_frontmatter "$TARGET" skill ;;
    agent)  bump_frontmatter "$TARGET" agent ;;
    claude) bump_marker "$TARGET" ;;
    script) bump_script "$TARGET" ;;
esac

# --- report -------------------------------------------------------------------
# When a skill sub-file triggered the bump, FILE (the edited file) differs from
# TARGET (the SKILL.md whose version moved) — log both so the trigger is traceable.
VIA=''
[ "$FILE" != "$TARGET" ] && VIA=" (via $FILE)"
repo=$(git -C "$(dirname "$TARGET")" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$repo" ] && [ -d "$repo/.claude" ]; then
    printf '[%s] %-7s %s%s :: %s\n' "$(date '+%F %T')" "$TYPE" "$TARGET" "$VIA" "$RESULT" \
        >> "$repo/.claude/hook-log.txt" 2>/dev/null || true
fi
printf 'bump-version: %s %s%s :: %s\n' "$TYPE" "$TARGET" "$VIA" "$RESULT"
exit 0
