#!/usr/bin/env bash
# install.sh — install AI-Toolbox tools from the catalog.
#
# Reads tools/catalog.json and dispatches per tool TYPE to a handler:
#   skill  — symlink the tool into <scope>/.{claude,codex,agents}/skills/
#   hook   — point a repo's core.hooksPath at the toolbox hook directory
#   plugin — claude plugin marketplace add + install (--target claude);
#            for --target codex|agents the plugin falls back to a skill-link
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

APP_VERSION='0.3.10'
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

Tool types: skill, hook, plugin.
  hook   — per-repo: needs --scope project --project PATH, ignores --target.
  plugin — --target claude does a real plugin install; codex/agents skill-link it.
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

# --- hook handler -------------------------------------------------------------
# Installs the versioning git-hooks into a repo by pointing its core.hooksPath
# at the toolbox hook directory. Per-repo: needs --scope project, ignores --target.
handle_hook() {
    local name=$1 path=$2
    local hooksdir="$REPO_ROOT/$path"
    if [ "$SCOPE" != project ]; then
        printf '  [.] %-18s hooks are per-repo — pass --scope project --project PATH\n' "$name"
        return
    fi
    local prepo cur
    prepo=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || {
        printf '  [!] %-18s --project is not a git repo: %s\n' "$name" "$PROJECT" >&2
        return
    }
    cur=$(git -C "$prepo" config --local core.hooksPath 2>/dev/null || true)
    case "$CMD" in
        build)
            if [ "$cur" = "$hooksdir" ]; then
                printf '  [=] %-18s core.hooksPath already set\n' "$name"; return
            fi
            if [ -n "$cur" ]; then
                printf '  [!] %-18s core.hooksPath already set to %s — skipped\n' "$name" "$cur" >&2
                return
            fi
            git -C "$prepo" config --local core.hooksPath "$hooksdir"
            printf '  [+] %-18s core.hooksPath -> %s\n' "$name" "$hooksdir"
            ;;
        status)
            if [ "$cur" = "$hooksdir" ]; then
                printf '  [ok] %-18s %s\n' "$name" "$prepo"
            elif [ -n "$cur" ]; then
                printf '  [? ] %-18s core.hooksPath = %s (not ours)\n' "$name" "$cur"
            else
                printf '  [  ] %-18s not installed in %s\n' "$name" "$prepo"
            fi
            ;;
        clean)
            if [ "$cur" = "$hooksdir" ]; then
                git -C "$prepo" config --local --unset core.hooksPath
                printf '  [-] %-18s core.hooksPath unset (%s)\n' "$name" "$prepo"
            else
                printf '  [.] %-18s nothing to remove\n' "$name"
            fi
            ;;
    esac
}

# --- plugin handler -----------------------------------------------------------
# --target claude: real plugin install via the claude CLI (marketplace add +
# install). Other targets have no plugin system — the tool falls back to a
# skill-link, since a plugin directory also carries a SKILL.md.
handle_plugin() {
    local name=$1 path=$2 marketplace=$3 plugin=$4
    if [ "$TARGET" != claude ]; then
        handle_skill "$name" "$path"
        return
    fi
    command -v claude >/dev/null 2>&1 || {
        printf '  [!] %-18s claude CLI not found — cannot install plugin\n' "$name" >&2
        return
    }
    local srcdir="$REPO_ROOT/$path" ref="$plugin@$marketplace"
    local pscope=user pdir=$PWD
    [ "$SCOPE" = project ] && { pscope=project; pdir=$PROJECT; }
    case "$CMD" in
        build)
            # marketplace add is idempotent enough — tolerate "already added".
            ( cd "$pdir" && claude plugin marketplace add "$srcdir" --scope "$pscope" ) \
                >/dev/null 2>&1 || true
            if claude plugin list 2>/dev/null | grep -qF "$ref"; then
                printf '  [=] %-18s %s already installed\n' "$name" "$ref"
            elif ( cd "$pdir" && claude plugin install "$ref" --scope "$pscope" ) >/dev/null 2>&1; then
                printf '  [+] %-18s %s installed (scope %s)\n' "$name" "$ref" "$pscope"
            else
                printf '  [!] %-18s install failed: %s\n' "$name" "$ref" >&2
            fi
            ;;
        status)
            if claude plugin list 2>/dev/null | grep -qF "$ref"; then
                printf '  [ok] %-18s %s installed\n' "$name" "$ref"
            else
                printf '  [  ] %-18s %s not installed\n' "$name" "$ref"
            fi
            ;;
        clean)
            if claude plugin list 2>/dev/null | grep -qF "$ref"; then
                ( cd "$pdir" && claude plugin uninstall "$ref" -y ) >/dev/null 2>&1 \
                    && printf '  [-] %-18s %s uninstalled\n' "$name" "$ref"
            else
                printf '  [.] %-18s %s not installed\n' "$name" "$ref"
            fi
            ( cd "$pdir" && claude plugin marketplace remove "$marketplace" ) >/dev/null 2>&1 || true
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
        hook)   handle_hook "$name" "$path" ;;
        plugin)
            mkt=$(printf '%s' "$tool" | jq -r '.marketplace // empty')
            plg=$(printf '%s' "$tool" | jq -r '.plugin // empty')
            handle_plugin "$name" "$path" "$mkt" "$plg"
            ;;
        *)
            printf '  [!] %-18s unknown type "%s"\n' "$name" "$type" >&2
            ;;
    esac
done
exit 0
