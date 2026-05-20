#!/usr/bin/env bash
# bump-version.sh — generic per-artifact version bumper for the AI-Toolbox.
#
# Bumps one segment of a MAJOR.MINOR.BUILD version. The storage location is
# chosen by artifact type:
#   plugin  — skill dir with .claude-plugin/plugin.json -> plugin.json "version"
#   skill   — file under .agents/skills/<name>/  -> <name>/SKILL.md frontmatter metadata.version
#   claude  — CLAUDE.md                          -> trailing <!-- APP_VERSION: x.y.z --> marker
#   agent   — *.md whose parent directory is "agents" -> frontmatter top-level version
#   script  — *.sh/.ps1/.js/.mjs/.cjs/.py/.html OR any file with a #! shebang,
#             provided it carries an APP_VERSION assignment
#
# A skill directory that also ships a Claude Code plugin manifest is versioned
# via plugin.json — that is the plugin's own authoritative version — instead of
# the SKILL.md frontmatter.
#
# The version marker is matched in its DECLARATION form only — an APP_VERSION
# assignment at the start of a line, the whole <!-- APP_VERSION: --> comment,
# a version: key inside YAML frontmatter, or the "version" key of plugin.json.
# A mere mention of the word in a comment, help text or prose is never matched.
#
# Modes:
#   (default) bump BUILD (3rd) — driven by the per-edit PostToolUse hook
#   --build   bump BUILD (3rd) explicitly
#   --minor   bump MINOR (2nd), BUILD untouched
#   --commit  bump MINOR+BUILD together — driven by the pre-commit hook
#   --target  print the resolved artifact file without bumping
#   --get     print the artifact's current version (type-aware, no mutation)
#
# A missing version is initialised to 0.0.1. The structural step (inserting the
# version field) is idempotent; once a version exists, a run only bumps it.
#
# Dual mode:
#   bump-version.sh [--build|--minor|--commit|--target|--get] <file>  — CLI
#   <hook-json> | bump-version.sh [--build|--commit]           — hook: reads
#                  tool_input.file_path from a Claude Code / Codex payload
#
# Always exits 0 (except on a usage error) — a non-artifact edit is a silent
# no-op, so it is hook-safe.

APP_VERSION='0.4.13'
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
  bump-version.sh [--build|--minor|--commit|--target|--get] <file>
  bump-version.sh -h|--help
  <hook-json> | bump-version.sh [--build|--commit]

Options:
  --build   Bump the BUILD segment (3rd). Default. Used by the per-edit hook.
  --minor   Bump the MINOR segment (2nd), leaving BUILD untouched.
  --commit  Bump MINOR and BUILD together. Used by the pre-commit hook.
  --target  Print the resolved artifact file without bumping anything.
  --get     Print the artifact's current version (type-aware, no mutation).
  -h|--help Show this help.

Hook mode: with no <file>, the edited path is read from a Claude Code / Codex
PostToolUse JSON payload on stdin.

Artifact types (MAJOR.MINOR.BUILD version):
  plugin  skill dir with .claude-plugin/plugin.json -> plugin.json "version"
  skill   file under .agents/skills/<name>/  -> <name>/SKILL.md metadata.version
  claude  CLAUDE.md                          -> trailing <!-- APP_VERSION --> marker
  agent   *.md whose parent dir is "agents"   -> frontmatter version
  script  *.sh .ps1 .js .mjs .cjs .py .html, or any #!-shebang file with an
          APP_VERSION assignment

The version is matched in its declaration form only — an assignment / the
whole marker comment / a frontmatter key / the plugin.json "version" key —
never a bare mention of the word. A missing version is initialised to 0.0.1.
A non-artifact file is a no-op.
EOF
            exit 0 ;;
        --build)  SEGMENT=build; shift ;;
        --minor)  SEGMENT=minor; shift ;;
        --commit) SEGMENT=commit; shift ;;
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

# --- declaration patterns -----------------------------------------------------
# An APP_VERSION assignment at the start of a line — covers APP_VERSION='x',
# $APP_VERSION = 'x', const APP_VERSION = "x", export APP_VERSION='x', etc.
# Anchoring to the assignment form means a mention of APP_VERSION in a comment
# or help text is never matched.
DECL_RE='^[[:space:]]*((export|const|let|var)[[:space:]]+)?\$?APP_VERSION[[:space:]]*=[[:space:]]*['\''"]'
# The whole CLAUDE.md / markdown version-marker comment.
MARKER_RE='<!--[[:space:]]*APP_VERSION:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+'
# The "version" key of a JSON manifest (plugin.json).
JSON_RE='"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"'

# --- helpers ------------------------------------------------------------------
bump_version() {
    # $1 = current version; bumps the segment named by the global $SEGMENT.
    local major minor build
    IFS='.' read -r major minor build <<< "$1"
    case "${major}-${minor}-${build}" in
        *[!0-9-]*|*--*|-*|*-) printf '%s' "$INIT_VERSION"; return ;;
    esac
    case "$SEGMENT" in
        minor)  printf '%s.%s.%s' "$major" "$((minor + 1))" "$build" ;;
        commit) printf '%s.%s.%s' "$major" "$((minor + 1))" "$((build + 1))" ;;
        *)      printf '%s.%s.%s' "$major" "$minor" "$((build + 1))" ;;
    esac
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

script_version() {
    # Echo the version from the first APP_VERSION assignment line, or nothing.
    grep -m1 -oE "${DECL_RE}[0-9]+\.[0-9]+\.[0-9]+" "$1" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

marker_version() {
    # Echo the version from the <!-- APP_VERSION: x.y.z --> marker, or nothing.
    grep -m1 -oE "$MARKER_RE" "$1" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

plugin_version() {
    # Echo the version from the "version" key of a plugin.json, or nothing.
    grep -m1 -oE "$JSON_RE" "$1" \
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
        # A skill that ships a Claude Code plugin manifest is versioned via
        # plugin.json (the plugin's own authoritative version), not SKILL.md.
        if [ -f "$skill_dir/.claude-plugin/plugin.json" ]; then
            TYPE=plugin; TARGET="$skill_dir/.claude-plugin/plugin.json"
        elif [ -f "$skill_dir/SKILL.md" ]; then
            TYPE=skill; TARGET="$skill_dir/SKILL.md"
        fi
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
        # the latter catches extensionless tools like the git hooks. It only
        # counts as a versioned artifact if it carries an APP_VERSION assignment.
        is_script=''
        case "$ext" in sh|ps1|js|mjs|cjs|py|html) is_script=1 ;; esac
        if [ -z "$is_script" ] && [ "$(head -c2 -- "$FILE" 2>/dev/null)" = '#!' ]; then
            is_script=1
        fi
        if [ -n "$is_script" ] && grep -qE "$DECL_RE" "$FILE"; then
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
    # Type-aware read — each type from its own declaration form.
    case "$TYPE" in
        skill|agent) fm_version "$TARGET" ;;
        claude)      marker_version "$TARGET" ;;
        script)      script_version "$TARGET" ;;
        plugin)      plugin_version "$TARGET" ;;
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
    cur=$(marker_version "$f")
    if [ -z "$cur" ]; then
        [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf '\n' >> "$f"
        printf '\n<!-- APP_VERSION: %s -->\n' "$INIT_VERSION" >> "$f"
        RESULT="(init) $INIT_VERSION"
        return
    fi
    new=$(bump_version "$cur")
    # Replace the version only inside the marker comment, nowhere else.
    sed -i -E "s|(<!--[[:space:]]*APP_VERSION:[[:space:]]*)$(re_escape "$cur")|\\1$new|" "$f"
    RESULT="$cur -> $new"
}

bump_script() {
    local f=$1 cur new ln
    # Operate on the first APP_VERSION assignment line only — never on a
    # comment or help text that merely mentions the token.
    ln=$(grep -m1 -nE "$DECL_RE" "$f" | cut -d: -f1)
    [ -n "$ln" ] || exit 0
    cur=$(sed -n "${ln}p" "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$cur" ] || exit 0
    new=$(bump_version "$cur")
    sed -i "${ln}s/$(re_escape "$cur")/$new/" "$f"
    RESULT="$cur -> $new"
}

bump_plugin() {
    local f=$1 cur new
    # Operate only on the "version" key of the plugin manifest.
    cur=$(plugin_version "$f")
    [ -n "$cur" ] || exit 0
    new=$(bump_version "$cur")
    sed -i -E "s|(\"version\"[[:space:]]*:[[:space:]]*\")$(re_escape "$cur")|\\1$new|" "$f"
    RESULT="$cur -> $new"
}

case "$TYPE" in
    skill)  bump_frontmatter "$TARGET" skill ;;
    agent)  bump_frontmatter "$TARGET" agent ;;
    claude) bump_marker "$TARGET" ;;
    script) bump_script "$TARGET" ;;
    plugin) bump_plugin "$TARGET" ;;
esac

# --- report -------------------------------------------------------------------
# When a skill sub-file triggered the bump, FILE (the edited file) differs from
# TARGET (the manifest whose version moved) — log both so the trigger is traceable.
VIA=''
[ "$FILE" != "$TARGET" ] && VIA=" (via $FILE)"
repo=$(git -C "$(dirname "$TARGET")" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$repo" ] && [ -d "$repo/.claude" ]; then
    printf '[%s] %-7s %-6s %s%s :: %s\n' "$(date '+%F %T')" "$TYPE" "$SEGMENT" "$TARGET" "$VIA" "$RESULT" \
        >> "$repo/.claude/hook-log.txt" 2>/dev/null || true
fi
printf 'bump-version: %s %s %s%s :: %s\n' "$TYPE" "$SEGMENT" "$TARGET" "$VIA" "$RESULT"
exit 0
