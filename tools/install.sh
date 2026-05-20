#!/usr/bin/env bash
# install.sh — install AI-Toolbox tools from the catalog.
#
# Reads tools/catalog.json and dispatches per tool TYPE to a handler:
#   skill  — symlink the tool into <scope>/.{claude,codex,agents}/skills/
#   hook   — git-hook shims into a repo's .git/hooks/   (handler: pending)
#   plugin — claude plugin marketplace add + install     (handler: pending)
#
# Usage:
#   install.sh <build|status|clean> --target <claude|codex|agents>
#              [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#
# Parameter families:
#   scope   global (default; base = $HOME) | project (base = --project PATH)
#   target  claude | codex | agents  — required, no default
#   what    all (default) | a tool name | a tool type
#
# Idempotent: build re-links cleanly, clean removes only our own symlinks,
# a foreign file/dir at the target is never clobbered.

APP_VERSION='0.1.2'
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)
CATALOG="$SELF_DIR/catalog.json"

usage() {
    cat <<'EOF'
install — install AI-Toolbox tools from the catalog (tools/catalog.json).

Usage:
  install.sh <build|status|clean> --target <claude|codex|agents> [options]

Options:
  --target  claude | codex | agents     Required. Which CLI/agent to install for.
  --scope   global | project            Default: global ($HOME). project needs --project.
  --project PATH                        Project root; required when --scope project.
  --what    all | <tool-name> | <type>  Default: all. Select catalog entries.
  -h|--help                             Show this help.

Tool types: skill (implemented); hook and plugin handlers are pending.
EOF
}

# --- command ------------------------------------------------------------------
CMD=${1:-}
case "$CMD" in
    build|status|clean) shift ;;
    -h|--help) usage; exit 0 ;;
    '') printf 'install: missing command (build|status|clean)\n' >&2; exit 2 ;;
    *)  printf 'install: unknown command: %s\n' "$CMD" >&2; exit 2 ;;
esac

# --- options ------------------------------------------------------------------
SCOPE=global
TARGET=''
PROJECT=''
WHAT=all
while [ $# -gt 0 ]; do
    case "$1" in
        --scope|--target|--project|--what)
            opt=$1
            [ $# -ge 2 ] || { printf 'install: %s needs a value\n' "$opt" >&2; exit 2; }
            case "$opt" in
                --scope)   SCOPE=$2 ;;
                --target)  TARGET=$2 ;;
                --project) PROJECT=$2 ;;
                --what)    WHAT=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'install: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# --- validate -----------------------------------------------------------------
case "$TARGET" in
    claude|codex|agents) ;;
    '') printf 'install: --target is required (claude|codex|agents)\n' >&2; exit 2 ;;
    *)  printf 'install: invalid --target: %s\n' "$TARGET" >&2; exit 2 ;;
esac
case "$SCOPE" in
    global) ;;
    project)
        [ -n "$PROJECT" ] || { printf 'install: --scope project requires --project PATH\n' >&2; exit 2; }
        PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd) \
            || { printf 'install: --project path not found\n' >&2; exit 2; }
        ;;
    *) printf 'install: invalid --scope: %s\n' "$SCOPE" >&2; exit 2 ;;
esac
[ -f "$CATALOG" ] || { printf 'install: catalog not found: %s\n' "$CATALOG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
    || { printf 'install: jq is required to read the catalog\n' >&2; exit 1; }

# --- skill handler ------------------------------------------------------------
skill_destdir() {
    local base
    [ "$SCOPE" = global ] && base=$HOME || base=$PROJECT
    case "$TARGET" in
        claude) printf '%s/.claude/skills' "$base" ;;
        codex)  printf '%s/.codex/skills' "$base" ;;
        agents) printf '%s/.agents/skills' "$base" ;;
    esac
}

handle_skill() {
    local name=$1 path=$2
    local src="$REPO_ROOT/$path"
    local destdir link
    destdir=$(skill_destdir)
    link="$destdir/$name"

    if [ ! -d "$src" ]; then
        printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2
        return
    fi
    if [ "$link" = "$src" ]; then
        printf '  [=] %-18s source == target, skipped\n' "$name"
        return
    fi

    case "$CMD" in
        build)
            mkdir -p "$destdir"
            if [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
                printf '  [=] %-18s already linked\n' "$name"; return
            fi
            if [ -L "$link" ]; then
                rm -f "$link"
            elif [ -e "$link" ]; then
                printf '  [!] %-18s exists and is not a symlink — skipped\n' "$name" >&2
                return
            fi
            ln -s "$src" "$link"
            printf '  [+] %-18s -> %s\n' "$name" "$link"
            ;;
        status)
            if [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
                printf '  [ok] %-18s %s\n' "$name" "$link"
            elif [ -e "$link" ] || [ -L "$link" ]; then
                printf '  [? ] %-18s %s (exists, not our link)\n' "$name" "$link"
            else
                printf '  [  ] %-18s not installed\n' "$name"
            fi
            ;;
        clean)
            if [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
                rm -f "$link"
                printf '  [-] %-18s removed\n' "$name"
            else
                printf '  [.] %-18s nothing to remove\n' "$name"
            fi
            ;;
    esac
}

# --- dispatch -----------------------------------------------------------------
printf 'install %s — scope=%s target=%s what=%s\n' "$CMD" "$SCOPE" "$TARGET" "$WHAT"

selected=$(jq -c --arg what "$WHAT" \
    '.tools[] | select($what == "all" or .name == $what or .type == $what)' "$CATALOG")
if [ -z "$selected" ]; then
    printf 'install: nothing in the catalog matches --what %s\n' "$WHAT" >&2
    exit 1
fi

printf '%s\n' "$selected" | while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    name=$(printf '%s' "$tool" | jq -r '.name')
    type=$(printf '%s' "$tool" | jq -r '.type')
    path=$(printf '%s' "$tool" | jq -r '.path')
    case "$type" in
        skill)  handle_skill "$name" "$path" ;;
        hook|plugin)
            printf '  [.] %-18s type "%s" — handler not yet implemented\n' "$name" "$type"
            ;;
        *)
            printf '  [!] %-18s unknown type "%s"\n' "$name" "$type" >&2
            ;;
    esac
done
exit 0
