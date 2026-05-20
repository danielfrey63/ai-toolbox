#!/usr/bin/env bash
# bump-version.sh — generic per-artifact version bumper for the AI-Toolbox.
#
# Bumps one segment of a MAJOR.MINOR.BUILD version. The storage location is
# chosen by artifact type:
#   skill   — file under .agents/skills/<name>/  -> <name>/SKILL.md frontmatter metadata.version
#   claude  — CLAUDE.md                          -> trailing <!-- APP_VERSION: x.y.z --> marker
#   agent   — *.md whose parent directory is "agents" -> frontmatter top-level version
#   script  — *.sh/.ps1/.js/.mjs/.cjs/.py/.html OR any file with a #! shebang,
#             provided it carries an APP_VERSION constant
#
# Modes:
#   (default) bump BUILD (3rd) — driven by the per-edit PostToolUse hook
#   --minor   bump MINOR (2nd), BUILD untouched — driven by the pre-commit hook
#   --build   bump BUILD (3rd) explicitly
#   --target  print the resolved artifact file without bumping
#   --get     print the artifact's current version (type-aware, no mutation)
#
# A missing version is initialised to 0.0.1. The structural step (inserting the
# version field) is idempotent; once a version exists, a run only bumps it.
#
# Dual mode:
#   bump-version.sh [--minor|--build|--target|--get] <file>   — CLI
#   <hook-json> | bump-version.sh [--minor|--build]            — hook: reads
#                  tool_input.file_path from a Claude Code / Codex payload
#
# Always exits 0 (except on a usage error) — a non-artifact edit is a silent
# no-op, so it is hook-safe.

APP_VERSION='0.1.5'
set -u

INIT_VERSION='0.0.1'
RESULT=''
SEGMENT=build
MODE=bump

# --- parse arguments ----------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<'EOF'
bump-version — generic per-artifact version bumper for the AI-Toolbox.

Usage:
  bump-version.sh [--minor|--build|--target|--get] <file>
  bump-version.sh -h|--help
  <hook-json> | bump-version.sh [--minor|--build]

Options:
  --build   Bump the BUILD segment (3rd). Default. Used by the per-edit hook.
  --minor   Bump the MINOR segment (2nd), leaving BUILD. Used by the pre-commit hook.
  --target  Print the resolved artifact file without bumping anything.
  --get     Print the artifact's current version (type-aware, no mutation).
  -h|--help Show this help.

Hook mode: with no <file>, the edited path is read from a Claude Code / Codex
PostToolUse JSON payload on stdin.

Artifact types (MAJOR.MINOR.BUILD version):
  skill   file under .agents/skills/<name>/  -> <name>/SKILL.md metadata.version
  claude  CLAUDE.md                          -> trailing <!-- APP_VERSION --> marker
  agent   *.md whose parent dir is "agents"   -> frontmatter version
  script  *.sh .ps1 .js .mjs .cjs .py .html, or any #!-shebang file with an
          APP_VERSION constant

A missing version is initialised to 0.0.1. A non-artifact file is a no-op.
EOF
            exit 0 ;;
        --build)  SEGMENT=build; shift ;;
        --minor)  SEGMENT=minor; shift ;;
        --target) MODE=target; shift ;;
        --get)    MODE=get; shift ;;
        --)       shift; break ;;
        -*)       printf 'bump-version: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)        break ;;
    esac
done

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
bump_version() {
    # $1 = current version; bumps the segment named by the global $SEGMENT.
    local major minor build
    IFS='.' read -r major minor build <<< "$1"
    case "${major}-${minor}-${build}" in
        *[!0-9-]*|*--*|-*|*-) printf '%s' "$INIT_VERSION"; return ;;
    esac
    if [ "$SEGMENT" = minor ]; then
        printf '%s.%s.%s' "$major" "$((minor + 1))" "$build"
    else
        printf '%s.%s.%s' "$major" "$minor" "$((build + 1))"
    fi
}

re_escape() {
    # Escape regex metacharacters in a version string for safe use as a sed/awk
    # pattern. Versions are digits + dots, so escaping dots is sufficient.
    printf '%s' "${1//./\\.}"
}

fm_version() {
    # Echo the first MAJOR.MINOR.BUILD on a "version:" key inside the YAML
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

marker_version() {
    # Echo the version from an APP_VERSION: marker / constant, or nothing.
    grep -oE "APP_VERSION[^0-9]*[0-9]+\.[0-9]+\.[0-9]+" "$1" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
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
        # A "script" is a file with a known code extension OR a #! shebang —
        # the latter catches extensionless tools like the git hooks.
        is_script=''
        case "$ext" in sh|ps1|js|mjs|cjs|py|html) is_script=1 ;; esac
        if [ -z "$is_script" ] && [ "$(head -c2 -- "$FILE" 2>/dev/null)" = '#!' ]; then
            is_script=1
        fi
        if [ -n "$is_script" ] && grep -qE '(^|[^A-Za-z_])APP_VERSION' "$FILE"; then
            TYPE=script; TARGET="$FILE"
        fi
    fi
fi

[ -n "$TYPE" ] || exit 0

# --- read-only modes ----------------------------------------------------------
if [ "$MODE" = target ]; then
    printf '%s\n' "$TARGET"
    exit 0
fi
if [ "$MODE" = get ]; then
    # Type-aware read — no generic version-string guessing.
    case "$TYPE" in
        skill|agent) fm_version "$TARGET" ;;
        claude|script) marker_version "$TARGET" ;;
    esac
    exit 0
fi

# --- bump implementations -----------------------------------------------------
bump_frontmatter() {
    local f=$1 mode=$2 cur new tmp
    cur=$(fm_version "$f")
    tmp=$(mktemp)
    if [ -n "$cur" ]; then
        new=$(bump_version "$cur")
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
    new=$(bump_version "$cur")
    sed -i "/APP_VERSION:/ s/$(re_escape "$cur")/$new/" "$f"
    RESULT="$cur -> $new"
}

bump_script() {
    local f=$1 cur new
    cur=$(grep -oE "APP_VERSION[^0-9]*['\"][0-9]+\.[0-9]+\.[0-9]+['\"]" "$f" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$cur" ] || exit 0
    new=$(bump_version "$cur")
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
    printf '[%s] %-7s %-6s %s%s :: %s\n' "$(date '+%F %T')" "$TYPE" "$SEGMENT" "$TARGET" "$VIA" "$RESULT" \
        >> "$repo/.claude/hook-log.txt" 2>/dev/null || true
fi
printf 'bump-version: %s %s %s%s :: %s\n' "$TYPE" "$SEGMENT" "$TARGET" "$VIA" "$RESULT"
exit 0
