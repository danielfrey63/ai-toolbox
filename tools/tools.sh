#!/usr/bin/env bash
# tools.sh — install AI-Toolbox tools from the catalog.
#
# Reads tools/catalog.json and dispatches per tool TYPE to a handler:
#   skill  — symlink the tool into <scope>/.{claude,codex,agents}/skills/
#   hook   — point a repo's core.hooksPath at the toolbox hook directory
#   plugin — claude plugin marketplace add + install (--target claude);
#            for --target codex|agents the plugin falls back to a skill-link
#   config — symlink a global config file (CLAUDE.md) into ~/.claude/
#
# Usage:
#   tools.sh <install|status|clean> --target <claude|codex|agents>
#              [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#              [--tagstyle plain|namespaced]
#
# Parameter families:
#   scope   global (default; base = $HOME) | project (base = --project PATH,
#           which itself defaults to the current directory)
#   target  claude | codex | agents  — required unless the selection is hook/config-only
#   what    all (default) | a tool name | a tool type
#
# --tagstyle applies only to hook installs — it sets the repo's
# bumpversion.tagstyle (plain = v<version> tags for a single-artifact repo).
#
# Idempotent: install re-links cleanly, clean removes only our own symlinks,
# a foreign file/dir at the target is never clobbered.
#
# Every install is recorded in a per-machine registry (see "Registry" in
# --help) so `status --all` / `clean --all` can sweep every install.

APP_VERSION='0.13.82'
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)
CATALOG="$SELF_DIR/catalog.json"

usage() {
    cat <<'EOF'
tools — install AI-Toolbox tools into a Claude Code / Codex / agents setup.

Tools are described in the catalog (tools/catalog.json) and installed by
type-specific handlers. Run `tools.sh list` to see what is available.

Usage:
  tools.sh <install|status|clean> --target <claude|codex|agents> [options]
  tools.sh list
  tools.sh -h|--help

Commands:
  install  Install the selected tools (idempotent — safe to re-run).
  status   Report whether each selected tool is installed.
  clean    Remove the selected tools (only ever removes our own links/config).
  list     Print the catalog — every installable tool with its type.

Options:
  --target   claude | codex | agents
             Where to install. Required, unless the selection is hook/config-only.
  --scope    global | project   Default: global.
             global  — install under $HOME (~/.claude, ~/.codex, ~/.agents).
             project — install under --project PATH.
  --project  PATH    Project root for --scope project. Default: current directory.
  --what     all | <tool-name> | <type>   Default: all.
             Select catalog entries by exact name, by type, or all of them.
  --tagstyle plain | namespaced   Hook installs only.
             plain      — tag v<version>         (single-artifact repo)
             namespaced — tag <name>/v<version>  (default; multi-artifact repo)
  --all      status / clean only: act on every recorded install (the registry),
             ignoring --what. status --all also prunes stale entries.
  -h|--help  Show this help.

Targets:
  claude   Claude Code     — skills link into <scope>/.claude/skills/
  codex    Codex CLI       — skills link into <scope>/.codex/skills/
  agents   agentskills.io  — skills link into <scope>/.agents/skills/
  Hooks (per-repo git config) and config files ignore --target. Plugins do a
  real `claude plugin` install for --target claude, else fall back to a skill-link.

Catalog (tools/catalog.json):
  The single source of truth for installable tools — each entry has a name,
  a type and a path. Types and their install handlers:
    skill   symlink/junction into a .{claude,codex,agents}/skills/ directory
    hook    point a repo's core.hooksPath at the toolbox git hooks
            (per-repo — needs --scope project; --project defaults to cwd)
    plugin  `claude plugin` marketplace add + install (--target claude),
            else a skill-link
    config  symlink a global config file into ~/.claude/ (global scope only)
  Run `tools.sh list` to print the current catalog.

Registry:
  Every install is recorded in
  ${XDG_CONFIG_HOME:-~/.config}/ai-toolbox/installs.json (per machine). It is
  only a discovery index — `status --all` and every `install` re-verify each
  entry against reality and prune stale ones.

Examples:
  tools.sh list
  tools.sh install --target claude   # all tools, global
  tools.sh install --target codex --what component-audit
  tools.sh install --what versioning-hooks --scope project   # --project = cwd
  tools.sh status --target claude
  tools.sh status --all              # every recorded install; prune stale
  tools.sh clean --all               # uninstall everything recorded
  tools.sh clean --target claude --what watch

Idempotent: install re-links cleanly, clean removes only our own links/config,
a foreign file or directory at a target is never clobbered.
EOF
}

# Print the catalog as a readable table — answers "what can I install?".
print_catalog_list() {
    printf 'tools — available tools (%s):\n\n' "$CATALOG"
    printf '  %-20s %-7s %s\n' NAME TYPE DESCRIPTION
    jq -r '.tools[] | [.name, .type, .description] | @tsv' "$CATALOG" \
        | while IFS=$(printf '\t') read -r n t d; do
            printf '  %-20s %-7s %s\n' "$n" "$t" "$d"
        done
    printf '\nSelect one with --what <name> or a group with --what <type>; default is all.\n'
}

# --- command ------------------------------------------------------------------
CMD=${1:-}
case "$CMD" in
    install|status|clean|list) shift ;;
    -h|--help) usage; exit 0 ;;
    '') printf 'tools: missing command (install|status|clean|list)\n' >&2; exit 2 ;;
    *)  printf 'tools: unknown command: %s\n' "$CMD" >&2; exit 2 ;;
esac

# --- options ------------------------------------------------------------------
SCOPE=global
TARGET=''
PROJECT=''
WHAT=all
TAGSTYLE=''
ALL=''
STATE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --scope|--target|--project|--what|--tagstyle)
            opt=$1
            [ $# -ge 2 ] || { printf 'tools: %s needs a value\n' "$opt" >&2; exit 2; }
            case "$opt" in
                --scope)    SCOPE=$2 ;;
                --target)   TARGET=$2 ;;
                --project)  PROJECT=$2 ;;
                --what)     WHAT=$2 ;;
                --tagstyle) TAGSTYLE=$2 ;;
            esac
            shift 2 ;;
        --all) ALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'tools: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# --- validate -----------------------------------------------------------------
# An empty --target is allowed here; whether it is actually required depends on
# the selected tool types and is checked once the catalog selection is known.
case "$TARGET" in
    ''|claude|codex|agents) ;;
    *) printf 'tools: invalid --target: %s\n' "$TARGET" >&2; exit 2 ;;
esac
case "$SCOPE" in
    global) ;;
    project)
        # --project defaults to the current directory.
        [ -n "$PROJECT" ] || PROJECT=$PWD
        PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd) \
            || { printf 'tools: --project path not found: %s\n' "$PROJECT" >&2; exit 2; }
        ;;
    *) printf 'tools: invalid --scope: %s\n' "$SCOPE" >&2; exit 2 ;;
esac
case "$TAGSTYLE" in
    ''|plain|namespaced) ;;
    *) printf 'tools: invalid --tagstyle: %s\n' "$TAGSTYLE" >&2; exit 2 ;;
esac
[ -f "$CATALOG" ] || { printf 'tools: catalog not found: %s\n' "$CATALOG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
    || { printf 'tools: jq is required to read the catalog\n' >&2; exit 1; }

# "list" just prints the catalog — no scope/target/selection needed.
if [ "$CMD" = list ]; then
    print_catalog_list
    exit 0
fi

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

# Symlink one artifact (file or directory) into a destination directory.
# Idempotent across install/status/clean; never clobbers a non-symlink.
# Shared by the skill and config handlers.
link_artifact() {
    local name=$1 src=$2 destdir=$3
    local link="$destdir/$(basename "$src")"

    if [ "$link" = "$src" ]; then
        printf '  [=] %-18s source == target, skipped\n' "$name"
        return
    fi

    case "$CMD" in
        install)
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
                STATE=ok
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

handle_skill() {
    local name=$1 path=$2
    local src="$REPO_ROOT/$path"
    if [ ! -d "$src" ]; then
        printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2
        return
    fi
    link_artifact "$name" "$src" "$(skill_destdir)"
}

# --- config handler -----------------------------------------------------------
# Symlinks a global config file (e.g. CLAUDE.md) into ~/.claude/. Config is
# user-global — global scope only, and --target is ignored.
handle_config() {
    local name=$1 path=$2
    local src="$REPO_ROOT/$path"
    if [ "$SCOPE" != global ]; then
        printf '  [.] %-18s config is global-only — use --scope global\n' "$name"
        return
    fi
    if [ ! -f "$src" ]; then
        printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2
        return
    fi
    link_artifact "$name" "$src" "$HOME/.claude"
}

# --- hook handler -------------------------------------------------------------
# Installs the versioning git-hooks into a repo by pointing its core.hooksPath
# at the toolbox hook directory. Per-repo: needs --scope project, ignores --target.

# Printed after a fresh hook install — a README snippet for the target repo so
# contributors know to activate the hooks too (git hooks are never cloned).
print_readme_hint() {
    cat <<'EOF'
      -> Add a setup note to this repo's README — git hooks are never cloned,
         so every clone must activate them once:

         ## Versioning
         Artifacts here are version-bumped by the AI-Toolbox git hooks.
         Once per clone, from this repo's root:
           git clone https://github.com/danielfrey63/ai-toolbox.git   # if needed
           <ai-toolbox>/tools/tools.sh install --what versioning-hooks \
             --scope project
EOF
}

handle_hook() {
    local name=$1 path=$2
    local hooksdir="$REPO_ROOT/$path"
    if [ "$SCOPE" != project ]; then
        printf '  [.] %-18s hooks are per-repo — pass --scope project\n' "$name"
        return
    fi
    local prepo cur curts fresh=''
    prepo=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || {
        printf '  [!] %-18s --project is not a git repo: %s\n' "$name" "$PROJECT" >&2
        return
    }
    cur=$(git -C "$prepo" config --local core.hooksPath 2>/dev/null || true)
    case "$CMD" in
        install)
            if [ -n "$cur" ] && [ "$cur" != "$hooksdir" ]; then
                printf '  [!] %-18s core.hooksPath already set to %s — skipped\n' "$name" "$cur" >&2
                return
            fi
            if [ "$cur" = "$hooksdir" ]; then
                printf '  [=] %-18s core.hooksPath already set\n' "$name"
            else
                git -C "$prepo" config --local core.hooksPath "$hooksdir"
                printf '  [+] %-18s core.hooksPath -> %s\n' "$name" "$hooksdir"
                fresh=1
            fi
            curts=$(git -C "$prepo" config --local bumpversion.tagstyle 2>/dev/null || true)
            if [ -n "$TAGSTYLE" ]; then
                if [ "$curts" = "$TAGSTYLE" ]; then
                    printf '  [=] %-18s bumpversion.tagstyle already %s\n' "$name" "$TAGSTYLE"
                else
                    git -C "$prepo" config --local bumpversion.tagstyle "$TAGSTYLE"
                    printf '  [+] %-18s bumpversion.tagstyle -> %s\n' "$name" "$TAGSTYLE"
                fi
            elif [ -n "$curts" ]; then
                printf '  [i] %-18s bumpversion.tagstyle = %s\n' "$name" "$curts"
            else
                printf '  [i] %-18s bumpversion.tagstyle = namespaced (default) — pass --tagstyle plain for a single-artifact repo\n' "$name"
            fi
            [ -n "$fresh" ] && print_readme_hint
            ;;
        status)
            if [ "$cur" = "$hooksdir" ]; then
                curts=$(git -C "$prepo" config --local bumpversion.tagstyle 2>/dev/null || true)
                printf '  [ok] %-18s %s (tagstyle=%s)\n' "$name" "$prepo" "${curts:-namespaced}"
                STATE=ok
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
            git -C "$prepo" config --local --unset bumpversion.tagstyle 2>/dev/null || true
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
        install)
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
                STATE=ok
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

# --- registry -----------------------------------------------------------------
# Records every install so `status --all` / `clean --all` can find them across
# all scopes, targets and projects. The registry is only a discovery index —
# each entry is re-verified against reality before any action, stale ones are
# pruned. Per machine, in the user config dir; never committed.
REGISTRY="${XDG_CONFIG_HOME:-$HOME/.config}/ai-toolbox/installs.json"

registry_read() {
    [ -f "$REGISTRY" ] && cat "$REGISTRY" 2>/dev/null || printf '[]'
}

# Upsert an entry, keyed by tool + scope + target + project.
registry_add() {  # name type path scope target project
    local data
    data=$(registry_read | jq \
        --arg tool "$1" --arg type "$2" --arg path "$3" \
        --arg scope "$4" --arg target "$5" --arg project "$6" '
        map(select((.tool==$tool and .scope==$scope
                    and .target==$target and .project==$project) | not))
        + [{tool:$tool, type:$type, path:$path,
            scope:$scope, target:$target, project:$project}]
        | sort_by(.tool, .scope, .target, .project)
    ' 2>/dev/null) || return 0
    mkdir -p "$(dirname "$REGISTRY")" && printf '%s\n' "$data" > "$REGISTRY"
}

# Drop the entry with this key — used by a non---all clean.
registry_remove() {  # name scope target project
    [ -f "$REGISTRY" ] || return 0
    local data
    data=$(registry_read | jq \
        --arg tool "$1" --arg scope "$2" --arg target "$3" --arg project "$4" '
        map(select((.tool==$tool and .scope==$scope
                    and .target==$target and .project==$project) | not))
    ' 2>/dev/null) || return 0
    printf '%s\n' "$data" > "$REGISTRY"
}

# Run $CMD against every registry entry. status: verify, report, prune stale
# entries. clean: remove each install, then empty the registry. Entries carry
# only install parameters — the handlers re-verify against reality.
registry_sweep() {
    local entries n i e tool type path mkt plg kept='[]'
    entries=$(registry_read)
    n=$(printf '%s' "$entries" | jq 'length' 2>/dev/null || printf 0)
    if [ "$n" = 0 ]; then
        printf '  (registry empty — nothing recorded)\n'
        [ "$CMD" = clean ] && printf '[]\n' > "$REGISTRY"
        return
    fi
    i=0
    while [ "$i" -lt "$n" ]; do
        e=$(printf '%s' "$entries" | jq -c ".[$i]")
        i=$((i + 1))
        tool=$(printf '%s' "$e" | jq -r '.tool')
        type=$(printf '%s' "$e" | jq -r '.type')
        path=$(printf '%s' "$e" | jq -r '.path')
        SCOPE=$(printf '%s' "$e" | jq -r '.scope')
        TARGET=$(printf '%s' "$e" | jq -r '.target')
        PROJECT=$(printf '%s' "$e" | jq -r '.project')

        STATE=gone
        case "$type" in
            skill)  handle_skill "$tool" "$path" ;;
            hook)   handle_hook "$tool" "$path" ;;
            config) handle_config "$tool" "$path" ;;
            plugin)
                mkt=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .marketplace // empty' "$CATALOG")
                plg=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .plugin // empty' "$CATALOG")
                handle_plugin "$tool" "$path" "$mkt" "$plg" ;;
            *)  printf '  [!] %-18s unknown type "%s"\n' "$tool" "$type" >&2 ;;
        esac

        if [ "$CMD" = status ]; then
            if [ "$STATE" = ok ]; then
                kept=$(printf '%s' "$kept" | jq -c --argjson e "$e" '. + [$e]')
            else
                printf '      -> pruned from registry (no longer installed)\n'
            fi
        fi
    done
    if [ "$CMD" = clean ]; then
        printf '[]\n' > "$REGISTRY"
    else
        printf '%s\n' "$kept" | jq . > "$REGISTRY"
    fi
}

# --- registry sweep (--all) ---------------------------------------------------
if [ -n "$ALL" ]; then
    case "$CMD" in
        status|clean) ;;
        *) printf 'tools: --all is only valid for status and clean\n' >&2; exit 2 ;;
    esac
    printf 'tools %s --all — sweeping the registry (%s)\n' "$CMD" "$REGISTRY"
    registry_sweep
    exit 0
fi

# --- dispatch -----------------------------------------------------------------
printf 'tools %s — scope=%s target=%s what=%s\n' "$CMD" "$SCOPE" "$TARGET" "$WHAT"

selected=$(jq -c --arg what "$WHAT" \
    '.tools[] | select($what == "all" or .name == $what or .type == $what)' "$CATALOG")
if [ -z "$selected" ]; then
    printf 'tools: nothing in the catalog matches --what %s\n\n' "$WHAT" >&2
    print_catalog_list >&2
    exit 1
fi

# --target is required unless every selected tool ignores it (hook, config).
if [ -z "$TARGET" ]; then
    needs_target=$(printf '%s\n' "$selected" \
        | jq -r 'select(.type != "hook" and .type != "config") | .name' | head -1)
    if [ -n "$needs_target" ]; then
        printf 'tools: --target is required (claude|codex|agents) — "%s" needs it\n' \
            "$needs_target" >&2
        exit 2
    fi
fi

printf '%s\n' "$selected" | while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    name=$(printf '%s' "$tool" | jq -r '.name')
    type=$(printf '%s' "$tool" | jq -r '.type')
    path=$(printf '%s' "$tool" | jq -r '.path')
    case "$type" in
        skill)  handle_skill "$name" "$path" ;;
        hook)   handle_hook "$name" "$path" ;;
        config) handle_config "$name" "$path" ;;
        plugin)
            mkt=$(printf '%s' "$tool" | jq -r '.marketplace // empty')
            plg=$(printf '%s' "$tool" | jq -r '.plugin // empty')
            handle_plugin "$name" "$path" "$mkt" "$plg"
            ;;
        *)
            printf '  [!] %-18s unknown type "%s"\n' "$name" "$type" >&2
            continue
            ;;
    esac
    case "$CMD" in
        install) registry_add "$name" "$type" "$path" "$SCOPE" "$TARGET" "$PROJECT" ;;
        clean)   registry_remove "$name" "$SCOPE" "$TARGET" "$PROJECT" ;;
    esac
done

# install reconciles the whole registry afterwards — the same verification as
# `status --all`, so stale entries are pruned on every install.
if [ "$CMD" = install ]; then
    printf '\n-- registry reconcile --\n'
    CMD=status
    registry_sweep
fi
exit 0
