#!/usr/bin/env bash
# toolbox.sh — install AI-Toolbox tools from the catalog.
#
# Reads tools/catalog.json and dispatches per tool TYPE to a handler:
#   skill  — symlink the tool into <scope>/.{claude,codex,agents}/skills/
#   hook   — point a repo's core.hooksPath at the toolbox hook directory
#   plugin — claude plugin marketplace add + install (--target claude);
#            for --target codex|agents the plugin falls back to a skill-link
#   config — symlink a global config file (CLAUDE.md) into ~/.claude/
#   bin    — make a CLI available system-wide (PATH symlink, or sourced shell
#            function via catalog "source: true" — needed for env-setting tools)
#
# Usage:
#   toolbox.sh <install|status|remove> --target <claude|codex|agents>
#              [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#              [--tagstyle plain|namespaced]
#
# Parameter families:
#   scope   global (default; base = $HOME) | project (base = --project PATH,
#           which itself defaults to the current directory)
#   target  claude | codex | agents  — required unless the selection is hook/config/bin-only
#   what    all (default) | a tool name | a tool type
#
# --tagstyle applies only to hook installs — it sets the repo's
# bumpversion.tagstyle (plain = v<version> tags for a single-artifact repo).
#
# Idempotent: install re-links cleanly, remove deletes only our own symlinks,
# a foreign file/dir at the target is never clobbered.
#
# Every install is recorded in a per-machine registry (see "Registry" in
# --help) so `status --all` / `remove --all` can sweep every install.

APP_VERSION='0.20.143'
set -u

# Resolve $0 through symlinks — when invoked via the ~/.local/bin/toolbox
# symlink (the "bin" install) $0 is the link, not the real script.
REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
CATALOG="$REPO_ROOT/tools/catalog.json"

# --- help ---------------------------------------------------------------------
# General overview + per-switch detail. Every screen ends with the same
# switches one-liner so a user can pivot. Dispatched via `show_help <topic>`.

_help_switches() {
    cat <<'EOF'

Switches: --target  --scope  --project  --what  --tagstyle  --all  -h|--help
EOF
}

_help_general() {
    cat <<'EOF'
toolbox — install AI-Toolbox tools (Claude Code / Codex / agentskills).

Usage:
  toolbox <install|status|remove|list> [options]
  toolbox --help [<switch>]

Commands:
  install   Install selected tools (idempotent — safe to re-run).
  status    Report install state; with no args, sweeps the registry.
  remove    Remove selected tools (only ever our own links/config).
  list      Print the catalog (name, type, description).

For switch detail:  toolbox --help <switch>      e.g.  toolbox --help --target

Examples:
  toolbox list
  toolbox install --what cli
  toolbox install --what versioning-hooks --scope project
  toolbox status --all
EOF
    _help_switches
}

_help_target() {
    cat <<'EOF'
--target <claude|codex|agents>
  Where to install. Required, unless the selection is hook/config/bin-only.

  claude   Claude Code      skills link into <scope>/.claude/skills/
  codex    Codex CLI        skills link into <scope>/.codex/skills/
  agents   agentskills.io   skills link into <scope>/.agents/skills/

  Hooks (per-repo git config) and config/bin entries ignore --target.
  Plugins do a real `claude plugin` install for --target claude; for other
  targets they fall back to a skill-link.

  Example:
    toolbox install --what component-audit --target claude
EOF
    _help_switches
}

_help_scope() {
    cat <<'EOF'
--scope <global|project>          Default: global.
  Where the install lives.

  global   Under $HOME  (~/.claude, ~/.codex, ~/.agents, ~/.local/bin, …).
  project  Under --project PATH  — for per-repo installs like the
           versioning git-hooks or project-scoped skills.

  Example:
    toolbox install --what versioning-hooks --scope project
EOF
    _help_switches
}

_help_project() {
    cat <<'EOF'
--project PATH                    Default: current directory.
  Project root for --scope project. Pass an absolute path to point the
  installer at a specific repo from anywhere.

  Examples:
    cd ~/Develop/myrepo && toolbox install --what versioning-hooks --scope project
    toolbox install --what versioning-hooks --scope project --project ~/Develop/myrepo
EOF
    _help_switches
}

_help_what() {
    cat <<'EOF'
--what <all|<tool-name>|<type>>   Default: all.
  Select catalog entries by exact name, by type, or `all`.

  Names are listed by `toolbox list`. Types are:
    skill   Skill directory, linked into a CLI's skills/.
    hook    Git hooks installed via core.hooksPath into a repo.
    plugin  Real `claude plugin` install (target=claude) or skill-link.
    config  Global config file (e.g. CLAUDE.md) into ~/.claude/.
    bin     Make a CLI available system-wide (exec or sourced shell function).

  Examples:
    toolbox install --what cli                     # by name (a bin entry)
    toolbox install --what skill --target claude   # by type
    toolbox install --target claude                # default --what all
EOF
    _help_switches
}

_help_tagstyle() {
    cat <<'EOF'
--tagstyle <plain|namespaced>     Hook installs only.
  Sets the repo's `bumpversion.tagstyle` git config — determines how the
  versioning post-commit hook tags releases.

  plain        Tags `v<version>`           single-artifact repo (one app).
  namespaced   Tags `<name>/v<version>`    default if unset; for repos with
                                           multiple versioned artifacts.

  Example:
    toolbox install --what versioning-hooks --scope project --tagstyle plain
EOF
    _help_switches
}

_help_all() {
    cat <<'EOF'
--all                             status / remove only.
  Act on every recorded install (the registry), ignoring --what.
  Bare `toolbox status` is equivalent to `status --all`.

  Registry: ${XDG_CONFIG_HOME:-~/.config}/ai-toolbox/installs.json (per
  machine) — the discovery index for project-scoped installs (hooks in
  arbitrary repos) that cannot otherwise be enumerated.

  `status --all` re-verifies every entry and prunes stale ones; `install`
  runs the same reconcile after each install.

  Examples:
    toolbox status --all
    toolbox remove --all     # uninstall everything recorded
EOF
    _help_switches
}

show_help() {
    case "${1:-}" in
        ''|--help|-h)        _help_general ;;
        --target|target)     _help_target ;;
        --scope|scope)       _help_scope ;;
        --project|project)   _help_project ;;
        --what|what)         _help_what ;;
        --tagstyle|tagstyle) _help_tagstyle ;;
        --all|all)           _help_all ;;
        *)
            printf 'toolbox: unknown help topic: %s\n' "$1" >&2
            printf 'available: --target, --scope, --project, --what, --tagstyle, --all\n' >&2
            return 2
            ;;
    esac
}

# Print the catalog as a readable table — answers "what can I install?".
print_catalog_list() {
    printf 'toolbox — available tools (%s)\n' "$CATALOG"
    printf 'Usage: toolbox <install|status|remove|list> [--target claude|codex|agents] [--scope global|project] [--project PATH] [--what all|<name>|<type>] [--tagstyle plain|namespaced] [--all] [-h|--help]\n\n'
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
    install|status|remove|list) shift ;;
    -h|--help) show_help "${2:-}"; exit $? ;;
    '') printf 'toolbox: missing command (install|status|remove|list)\n' >&2; exit 2 ;;
    *)  printf 'toolbox: unknown command: %s\n' "$CMD" >&2; exit 2 ;;
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
            [ $# -ge 2 ] || { printf 'toolbox: %s needs a value\n' "$opt" >&2; exit 2; }
            case "$opt" in
                --scope)    SCOPE=$2 ;;
                --target)   TARGET=$2 ;;
                --project)  PROJECT=$2 ;;
                --what)     WHAT=$2 ;;
                --tagstyle) TAGSTYLE=$2 ;;
            esac
            shift 2 ;;
        --all) ALL=1; shift ;;
        -h|--help) show_help "${2:-}"; exit $? ;;  # `<cmd> --help [switch]`
        *) printf 'toolbox: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# --- validate -----------------------------------------------------------------
# An empty --target is allowed here; whether it is actually required depends on
# the selected tool types and is checked once the catalog selection is known.
case "$TARGET" in
    ''|claude|codex|agents) ;;
    *) printf 'toolbox: invalid --target: %s\n' "$TARGET" >&2; exit 2 ;;
esac
case "$SCOPE" in
    global) ;;
    project)
        # --project defaults to the current directory.
        [ -n "$PROJECT" ] || PROJECT=$PWD
        PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd) \
            || { printf 'toolbox: --project path not found: %s\n' "$PROJECT" >&2; exit 2; }
        ;;
    *) printf 'toolbox: invalid --scope: %s\n' "$SCOPE" >&2; exit 2 ;;
esac
case "$TAGSTYLE" in
    ''|plain|namespaced) ;;
    *) printf 'toolbox: invalid --tagstyle: %s\n' "$TAGSTYLE" >&2; exit 2 ;;
esac
[ -f "$CATALOG" ] || { printf 'toolbox: catalog not found: %s\n' "$CATALOG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
    || { printf 'toolbox: jq is required to read the catalog\n' >&2; exit 1; }

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

# Symlink one artifact (file or directory) into a destination directory, under
# an optional link name (4th arg; defaults to the source basename). Idempotent
# across install/status/remove; never clobbers a non-symlink. Shared by the
# skill, config and bin handlers.
link_artifact() {
    local name=$1 src=$2 destdir=$3
    local link="$destdir/${4:-$(basename "$src")}"

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
                printf '  [ ] %-18s not installed\n' "$name"
            fi
            ;;
        remove)
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

# --- bin handler --------------------------------------------------------------
# Makes a CLI available system-wide. Two modes (catalog flag `source: true`):
#   exec   (default): a symlink in ~/.local/bin (the script is run as a
#                     subprocess); pwsh uses a $PROFILE function with `&`.
#   source           : a sourcing function in ~/.bashrc (the script is sourced
#                     into the current shell — needed for env-setting tools
#                     like cc-profil); pwsh uses `.` (dot-source) in $PROFILE.
# Global scope only, ignores --target.
handle_bin() {
    local name=$1 path=$2 cmdname=$3 sourced=${4:-}
    local src="$REPO_ROOT/$path"
    if [ "$SCOPE" != global ]; then
        printf '  [.] %-18s bin is global-only — use --scope global\n' "$name"
        return
    fi
    if [ ! -f "$src" ]; then
        printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2
        return
    fi
    if [ -n "$sourced" ]; then
        handle_bin_source "$name" "$src" "$cmdname"
    else
        handle_bin_exec "$name" "$src" "$cmdname"
    fi
}

# Exec mode: symlink the script into ~/.local/bin as <cmdname>.
handle_bin_exec() {
    local name=$1 src=$2 cmdname=$3
    local bindir="$HOME/.local/bin"
    link_artifact "$name" "$src" "$bindir" "$cmdname"
    if [ "$CMD" = install ]; then
        case ":${PATH}:" in
            *":$bindir:"*) ;;
            *) printf '  [i] %-18s %s is not on PATH — add it so `%s` is found\n' \
                "$name" "$bindir" "$cmdname" ;;
        esac
    fi
}

# Source mode: a sourcing function `<cmdname>() { source '<src>' "$@"; }` in
# ~/.bashrc, inside a marker-bracketed block. Idempotent install/status/remove.
handle_bin_source() {
    local name=$1 src=$2 cmdname=$3
    local rc="$HOME/.bashrc"
    local beg="# >>> ai-toolbox $cmdname >>>"
    local end="# <<< ai-toolbox $cmdname <<<"
    local has=0
    [ -f "$rc" ] && grep -qF "$beg" "$rc" && has=1
    case "$CMD" in
        install)
            local tmp
            tmp=$(mktemp)
            [ -f "$rc" ] && awk -v b="$beg" -v e="$end" '
                index($0,b){s=1;next}
                s&&index($0,e){s=0;next}
                !s{print}
            ' "$rc" > "$tmp"
            [ -s "$tmp" ] && printf '\n' >> "$tmp"
            printf '%s\n%s() { source %s "$@"; }\n%s\n' \
                "$beg" "$cmdname" "'$src'" "$end" >> "$tmp"
            mv "$tmp" "$rc"
            if [ "$has" = 1 ]; then
                printf '  [=] %-18s %s already in ~/.bashrc\n' "$name" "$cmdname"
            else
                printf '  [+] %-18s %s -> ~/.bashrc (open a new shell or `source ~/.bashrc`)\n' "$name" "$cmdname"
            fi
            ;;
        status)
            if [ "$has" = 1 ]; then
                printf '  [ok] %-18s %s in ~/.bashrc\n' "$name" "$cmdname"
                STATE=ok
            else
                printf '  [ ] %-18s not installed\n' "$name"
            fi
            ;;
        remove)
            if [ "$has" = 1 ]; then
                local tmp
                tmp=$(mktemp)
                awk -v b="$beg" -v e="$end" '
                    index($0,b){s=1;next}
                    s&&index($0,e){s=0;next}
                    !s{print}
                ' "$rc" > "$tmp"
                mv "$tmp" "$rc"
                printf '  [-] %-18s %s removed from ~/.bashrc\n' "$name" "$cmdname"
            else
                printf '  [.] %-18s nothing to remove\n' "$name"
            fi
            ;;
    esac
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
           <ai-toolbox>/toolbox.sh install --what versioning-hooks \
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
                printf '  [ ] %-18s not installed in %s\n' "$name" "$prepo"
            fi
            ;;
        remove)
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
                printf '  [ ] %-18s %s not installed\n' "$name" "$ref"
            fi
            ;;
        remove)
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
# Records every install so `status --all` / `remove --all` can find them across
# all scopes, targets and projects. The registry is only a discovery index —
# each entry is re-verified against reality before any action, stale ones are
# pruned. Per machine, in the user config dir; never committed.
REGISTRY="${XDG_CONFIG_HOME:-$HOME/.config}/ai-toolbox/installs.json"

registry_read() {
    [ -f "$REGISTRY" ] && cat "$REGISTRY" 2>/dev/null || printf '[]'
}

# Normalize scope/target/project for the registry key, per tool type — handlers
# that ignore --target/--scope must not leak those into the key, or one install
# can be recorded as multiple entries that differ only by an ignored field.
# Inlined into add/remove because returning three strings via stdout + read
# would collapse empty fields under whitespace IFS.

# Upsert an entry, keyed by tool + scope + target + project.
registry_add() {  # name type path scope target project
    local scope=$4 target=$5 project=$6
    case "$2" in
        hook)        target='' ;;
        config|bin)  scope=global; target=''; project='' ;;
    esac
    local data
    data=$(registry_read | jq \
        --arg tool "$1" --arg type "$2" --arg path "$3" \
        --arg scope "$scope" --arg target "$target" --arg project "$project" '
        map(select((.tool==$tool and .scope==$scope
                    and .target==$target and .project==$project) | not))
        + [{tool:$tool, type:$type, path:$path,
            scope:$scope, target:$target, project:$project}]
        | sort_by(.tool, .scope, .target, .project)
    ' 2>/dev/null) || return 0
    mkdir -p "$(dirname "$REGISTRY")" && printf '%s\n' "$data" > "$REGISTRY"
}

# Drop the entry with this key — used by a non---all remove.
registry_remove() {  # name type scope target project
    [ -f "$REGISTRY" ] || return 0
    local scope=$3 target=$4 project=$5
    case "$2" in
        hook)        target='' ;;
        config|bin)  scope=global; target=''; project='' ;;
    esac
    local data
    data=$(registry_read | jq \
        --arg tool "$1" --arg scope "$scope" --arg target "$target" --arg project "$project" '
        map(select((.tool==$tool and .scope==$scope
                    and .target==$target and .project==$project) | not))
    ' 2>/dev/null) || return 0
    printf '%s\n' "$data" > "$REGISTRY"
}

# Run $CMD against every registry entry. status: verify, report, prune stale
# entries. remove: uninstall each, then empty the registry. Entries carry
# only install parameters — the handlers re-verify against reality.
registry_sweep() {
    local entries n i e tool type path mkt plg cmdname bin_src kept='[]'
    # Heal pre-fix entries that snuck in with stray whitespace in tool/type/etc.
    # by trimming all string fields, then drop exact-duplicate keys.
    entries=$(registry_read | jq '
        def trim: if type == "string" then sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") else . end;
        map(with_entries(.value |= trim))
        | unique_by([.tool, .type, .scope, .target, .project])
    ' 2>/dev/null)
    n=$(printf '%s' "$entries" | jq 'length' 2>/dev/null || printf 0)
    if [ "$n" = 0 ]; then
        printf '  (registry empty — nothing recorded)\n'
        [ "$CMD" = remove ] && printf '[]\n' > "$REGISTRY"
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
            bin)
                cmdname=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .command // empty' "$CATALOG")
                bin_src=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | if .source then "1" else "" end' "$CATALOG")
                handle_bin "$tool" "$path" "$cmdname" "$bin_src" ;;
            plugin)
                mkt=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .marketplace // empty' "$CATALOG")
                plg=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .plugin // empty' "$CATALOG")
                handle_plugin "$tool" "$path" "$mkt" "$plg" ;;
            *)  printf '  [!] %-18s unknown type "%s"\n' "$tool" "$type" >&2 ;;
        esac

        if [ "$CMD" = status ]; then
            # bin entries are kept regardless of the verdict — their install
            # mechanism is port-specific (bash symlink vs pwsh $PROFILE), so a
            # cross-port status check cannot tell "gone" apart from "installed
            # by the other port".
            if [ "$STATE" = ok ] || [ "$type" = bin ]; then
                kept=$(printf '%s' "$kept" | jq -c --argjson e "$e" '. + [$e]')
            else
                printf '      -> pruned from registry (no longer installed)\n'
            fi
        fi
    done
    if [ "$CMD" = remove ]; then
        printf '[]\n' > "$REGISTRY"
    else
        printf '%s\n' "$kept" | jq . > "$REGISTRY"
    fi
}

# `status` with no selection arguments shows the registry — bare `toolbox
# status` answers "what is installed?" without needing a --target.
if [ "$CMD" = status ] && [ -z "$ALL" ] && [ -z "$TARGET" ] \
    && [ "$WHAT" = all ] && [ "$SCOPE" = global ]; then
    ALL=1
fi

# --- registry sweep (--all) ---------------------------------------------------
if [ -n "$ALL" ]; then
    case "$CMD" in
        status|remove) ;;
        *) printf 'toolbox: --all is only valid for status and remove\n' >&2; exit 2 ;;
    esac
    printf 'toolbox %s --all — sweeping the registry (%s)\n' "$CMD" "$REGISTRY"
    registry_sweep
    exit 0
fi

# --- dispatch -----------------------------------------------------------------
printf 'toolbox %s — scope=%s target=%s what=%s\n' "$CMD" "$SCOPE" "$TARGET" "$WHAT"

selected=$(jq -c --arg what "$WHAT" \
    '.tools[] | select($what == "all" or .name == $what or .type == $what)' "$CATALOG")
if [ -z "$selected" ]; then
    printf 'toolbox: nothing in the catalog matches --what %s\n\n' "$WHAT" >&2
    print_catalog_list >&2
    exit 1
fi

# --target is required unless every selected tool ignores it (hook, config, bin).
if [ -z "$TARGET" ]; then
    needs_target=$(printf '%s\n' "$selected" \
        | jq -r 'select(.type != "hook" and .type != "config" and .type != "bin") | .name' | head -1)
    if [ -n "$needs_target" ]; then
        printf 'toolbox: --target is required (claude|codex|agents) — "%s" needs it\n' \
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
        bin)
            cmdname=$(printf '%s' "$tool" | jq -r '.command // empty')
            bin_src=$(printf '%s' "$tool" | jq -r 'if .source then "1" else "" end')
            handle_bin "$name" "$path" "$cmdname" "$bin_src"
            ;;
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
        remove)  registry_remove "$name" "$type" "$SCOPE" "$TARGET" "$PROJECT" ;;
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
