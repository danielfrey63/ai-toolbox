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

APP_VERSION='0.30.186'
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
  toolbox <install|status|remove|list|reconcile> [options]
  toolbox --help [<switch>]

Commands:
  install   Install selected tools (idempotent — safe to re-run).
  status    Report install state; with no args, sweeps the registry.
  remove    Remove selected tools (only ever our own links/config).
  list      Print the catalog (name, type, description).
  reconcile Discover existing links into this repo (e.g. hand-made symlinks)
            and register any that are missing, so status/remove see them.

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

  Config/bin entries ignore --target. Hooks honour --target claude (also
  patches the project's .claude/settings.json with an edit-bump PostToolUse
  hook); --target codex|agents is not yet supported for the edit-bump path.
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
    printf 'Usage: toolbox <install|status|remove|list|reconcile> [--target claude|codex|agents] [--scope global|project] [--project PATH] [--what all|<name>|<type>] [--tagstyle plain|namespaced] [--all] [-h|--help]\n\n'
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
    install|status|remove|list|reconcile) shift ;;
    -h|--help) show_help "${2:-}"; exit $? ;;
    '') printf 'toolbox: missing command (install|status|remove|list|reconcile)\n' >&2; exit 2 ;;
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
# at the toolbox hook directory. Per-repo: needs --scope project.
# Honours --target claude: in that case also installs the edit-bump
# PostToolUse hook into <prepo>/.claude/settings.json (idempotent, via the
# two-stage heuristic implemented in _claude_hook_install above).
# --target codex|agents prints a "not yet supported" note for that aspect.
# Whether the claude hook is expected on later status runs is tracked in
# git config (bumpversion.claudehook).

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

# ── Claude-Code PostToolUse helpers (used by handle_hook when --target claude) ──
# The git hooks above cover commit-time bumps; the Claude-Code edit-driven bump
# is a separate concern that lives in <prepo>/.claude/settings.json. These
# helpers keep that file in sync — idempotent, with a two-stage heuristic so
# foreign PostToolUse hooks survive a remove.
#
# Heuristic:
#   1. command-string contains 'bump-version.sh'
#   2. the script behind that path carries an `APP_VERSION=` declaration at
#      line start (the AI-Toolbox self-marker). Skipped if the file isn't
#      reachable, so re-installs after a repo move still match on stage 1.

# Canonical command we install — sibling-of-project layout (<prepo>/../ai-toolbox).
_claude_hook_command() {  # void → string
    printf 'bash "$(git rev-parse --show-toplevel)/../ai-toolbox/tools/bump-version.sh"'
}

# Stage-2 marker check on the referenced bumper script.
_claude_hook_verify_marker() {  # prepo
    local guess="$1/../ai-toolbox/tools/bump-version.sh"
    [ -f "$guess" ] || return 0   # unreachable → accept stage-1 alone
    grep -qE '^\$?APP_VERSION[[:space:]]*=' "$guess"
}

# Idempotent install of our PostToolUse:Edit|Write hook.
_claude_hook_install() {  # name prepo
    local name=$1 prepo=$2
    local settings="$prepo/.claude/settings.json"
    mkdir -p "$prepo/.claude"
    [ -f "$settings" ] || printf '{}\n' > "$settings"
    local present
    present=$(jq -r '
        (.hooks.PostToolUse // [])
        | map(select(((.hooks // [])
                      | map(select(.command | tostring | test("bump-version\\.sh")))
                      | length) > 0))
        | length
    ' "$settings" 2>/dev/null) || present=0
    if [ "${present:-0}" -ge 1 ]; then
        printf '  [=] %-18s claude PostToolUse already present\n' "$name"
        return 0
    fi
    local cmd tmp
    cmd=$(_claude_hook_command)
    tmp=$(jq --arg cmd "$cmd" '
        .hooks = (.hooks // {})
        | .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
            matcher: "Edit|Write",
            hooks: [{ type: "command", command: $cmd, statusMessage: "Version-Bump (AI-Toolbox)..." }]
        }])
    ' "$settings") || return 1
    printf '%s\n' "$tmp" > "$settings"
    printf '  [+] %-18s claude PostToolUse -> %s\n' "$name" "$settings"
}

# Echo 'yes' | 'no' | 'no-settings' for the project's PostToolUse state.
_claude_hook_state() {  # prepo → string
    local settings="$1/.claude/settings.json"
    [ -f "$settings" ] || { printf 'no-settings'; return; }
    local match
    match=$(jq -r '
        (.hooks.PostToolUse // [])
        | map(select(((.hooks // [])
                      | map(select(.command | tostring | test("bump-version\\.sh")))
                      | length) > 0))
        | length
    ' "$settings" 2>/dev/null) || match=0
    [ "${match:-0}" -ge 1 ] && printf 'yes' || printf 'no'
}

# Remove our PostToolUse entries — guarded by the two-stage heuristic.
_claude_hook_remove() {  # name prepo
    local name=$1 prepo=$2
    local settings="$prepo/.claude/settings.json"
    [ -f "$settings" ] || return 0
    if ! _claude_hook_verify_marker "$prepo"; then
        printf '  [!] %-18s claude PostToolUse: target script lacks APP_VERSION marker, refusing to remove\n' "$name"
        return 0
    fi
    local tmp
    tmp=$(jq '
        if .hooks.PostToolUse then
            .hooks.PostToolUse |= map(
                select(((.hooks // [])
                        | map(select(.command | tostring | test("bump-version\\.sh")))
                        | length) == 0)
            )
            | if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end
            | if (.hooks | length) == 0 then del(.hooks) else . end
        else . end
    ' "$settings") || return 1
    printf '%s\n' "$tmp" > "$settings"
    printf '  [-] %-18s claude PostToolUse removed (%s)\n' "$name" "$settings"
}

# True when two paths denote the same hooks directory, regardless of path
# format. core.hooksPath is stored verbatim by whichever port set it: the
# PowerShell port writes a Windows path ("D:\...\tools\githooks"), the bash
# port a forward-slash MSYS path ("/d/.../tools/githooks"). A plain string
# compare therefore reports a cross-port install as "not ours" and `status`
# prunes a perfectly live hook. The `-ef` test resolves both forms to the same
# inode when they exist, so it matches across drive-letter case, separators and
# trailing slashes; the exact-string fast path covers the same-port case (and
# the rare box without a working `-ef`).
_same_hookpath() {  # cur hooksdir
    [ -n "$1" ] || return 1
    [ "$1" = "$2" ] && return 0
    [ "$1" -ef "$2" ] 2>/dev/null
}

# Interactive takeover dialog for a foreign core.hooksPath. Always prints a
# clear hint on stdout (the previous behaviour buried the verdict on stderr
# and short-circuited silently). On a TTY, offers two yes/no prompts:
#   1. Replace with the toolbox hook?  N → bail out, foreign hook preserved.
#   2. Also delete the foreign hooks dir?  N → keep dir on disk, just unset.
# Off-TTY (pipe, cron, hook context), prints the same hint and skips with a
# pointer to the manual fix — never hangs waiting for input.
# Returns 0 when core.hooksPath has been unset and the caller may proceed
# with the install; 1 when the foreign hook was kept and the install should
# bail out.
_foreign_hook_takeover() {  # name prepo cur
    local name=$1 prepo=$2 cur=$3 reply
    local foreign=$cur
    case "$foreign" in
        /*|[A-Za-z]:[/\\]*) ;;       # absolute (POSIX or Windows drive)
        *) foreign="$prepo/$cur" ;;  # git stores relative paths repo-relative
    esac
    printf '  [!] %-18s core.hooksPath already set to %s (not a toolbox install)\n' \
        "$name" "$cur"
    if [ -d "$foreign" ]; then
        printf '       contents of %s:\n' "$foreign"
        for f in "$foreign"/* "$foreign"/.[!.]*; do
            [ -e "$f" ] || continue
            printf '         - %s\n' "$(basename "$f")"
        done
    fi
    if [ ! -t 0 ]; then
        printf '       (run interactively to take it over, or unset core.hooksPath manually); skipped\n'
        return 1
    fi
    printf '       Replace it with the toolbox hook? [y/N] '
    IFS= read -r reply || return 1
    case "$reply" in
        y|Y|yes|j|J|ja) ;;
        *) printf '  [.] %-18s skipped — foreign hook preserved\n' "$name"; return 1 ;;
    esac
    if [ -d "$foreign" ]; then
        printf '       Also delete %s (and its contents)? [y/N] ' "$foreign"
        IFS= read -r reply || reply=n
        case "$reply" in
            y|Y|yes|j|J|ja)
                rm -rf -- "$foreign"
                printf '  [-] %-18s removed foreign hooks dir %s\n' "$name" "$foreign"
                ;;
            *)
                printf '  [i] %-18s foreign hooks dir %s preserved on disk\n' \
                    "$name" "$foreign"
                ;;
        esac
    fi
    git -C "$prepo" config --local --unset core.hooksPath
    printf '  [-] %-18s core.hooksPath unset (was %s)\n' "$name" "$cur"
    return 0
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
            if [ -n "$cur" ] && ! _same_hookpath "$cur" "$hooksdir"; then
                _foreign_hook_takeover "$name" "$prepo" "$cur" || return
                cur=''
            fi
            if _same_hookpath "$cur" "$hooksdir"; then
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
            # The post-commit hook creates tags; push.followTags makes the
            # next `git push` carry them along, so tags never silently lag
            # behind commits on the remote.
            local curft
            curft=$(git -C "$prepo" config --local push.followTags 2>/dev/null || true)
            if [ "$curft" = "true" ]; then
                printf '  [=] %-18s push.followTags already true\n' "$name"
            else
                git -C "$prepo" config --local push.followTags true
                printf '  [+] %-18s push.followTags -> true\n' "$name"
            fi
            # --target claude: also install the Claude-Code PostToolUse hook
            # so per-edit BUILD bumps work. We track the "claude was requested"
            # bit in git config so `status` knows to expect the settings hook
            # even when the registry entry itself is target-agnostic.
            case "$TARGET" in
                claude)
                    _claude_hook_install "$name" "$prepo"
                    git -C "$prepo" config --local bumpversion.claudehook true
                    ;;
                codex|agents)
                    printf '  [.] %-18s edit-bump PostToolUse not yet supported for --target %s\n' "$name" "$TARGET"
                    ;;
            esac
            [ -n "$fresh" ] && print_readme_hint
            ;;
        status)
            # When this install was requested with --target claude (the flag
            # bumpversion.claudehook persists in git config), the claude
            # PostToolUse hook is part of the contract. The verdict is folded
            # into the single status line so each registry entry stays at one
            # row — `claude=present` decorates the `(tagstyle=…)` suffix,
            # `claude=missing-…` flips the row marker to `[! ]` and bumps
            # STATE=partial so `status --all` surfaces it on a punch list.
            local cl_suffix='' cl_state=''
            if [ "$(git -C "$prepo" config --local --bool bumpversion.claudehook 2>/dev/null || true)" = "true" ]; then
                cl_state=$(_claude_hook_state "$prepo")
                case "$cl_state" in
                    yes)         cl_suffix=', claude=present' ;;
                    no)          cl_suffix=', claude=missing-from-settings' ;;
                    no-settings) cl_suffix=', claude=missing-no-settings' ;;
                esac
            fi
            if _same_hookpath "$cur" "$hooksdir"; then
                curts=$(git -C "$prepo" config --local bumpversion.tagstyle 2>/dev/null || true)
                if [ "$cl_state" = "no" ] || [ "$cl_state" = "no-settings" ]; then
                    printf '  [! ] %-18s %s (tagstyle=%s%s)\n' "$name" "$prepo" "${curts:-namespaced}" "$cl_suffix"
                    STATE=partial
                else
                    printf '  [ok] %-18s %s (tagstyle=%s%s)\n' "$name" "$prepo" "${curts:-namespaced}" "$cl_suffix"
                    STATE=ok
                fi
            elif [ -n "$cur" ]; then
                printf '  [? ] %-18s core.hooksPath = %s (not ours)%s\n' "$name" "$cur" "$cl_suffix"
                STATE=
            else
                printf '  [ ] %-18s not installed in %s%s\n' "$name" "$prepo" "$cl_suffix"
                STATE=
            fi
            ;;
        remove)
            if _same_hookpath "$cur" "$hooksdir"; then
                git -C "$prepo" config --local --unset core.hooksPath
                printf '  [-] %-18s core.hooksPath unset (%s)\n' "$name" "$prepo"
            else
                printf '  [.] %-18s nothing to remove\n' "$name"
            fi
            git -C "$prepo" config --local --unset bumpversion.tagstyle 2>/dev/null || true
            git -C "$prepo" config --local --unset push.followTags 2>/dev/null || true
            # Remove the claude PostToolUse hook if the flag says we installed it.
            if [ "$(git -C "$prepo" config --local --bool bumpversion.claudehook 2>/dev/null || true)" = "true" ]; then
                _claude_hook_remove "$name" "$prepo"
                git -C "$prepo" config --local --unset bumpversion.claudehook 2>/dev/null || true
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
    # config/bin are always global, repo-agnostic; their target is meaningless.
    # hook keeps target in the key — the claude PostToolUse patching in
    # .claude/settings.json is target-specific even though core.hooksPath is
    # repo-wide, so the same repo can legitimately have multiple hook entries
    # (target="" = bare git-hook, target="claude" = git-hook + claude patch).
    case "$2" in
        config|bin)  scope=global; target=''; project='' ;;
    esac
    # Path keys: '/' separators + no trailing slash — Windows can pass either
    # form (Resolve-Path gives '\', git rev-parse gives '/') and raw input may
    # have a trailing slash. Symmetric with the PS port (_Registry-Normalize).
    if [ -n "$project" ]; then
        project=${project//\\//}
        while [ "${project%/}" != "$project" ]; do project=${project%/}; done
    fi
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
        config|bin)  scope=global; target=''; project='' ;;
    esac
    if [ -n "$project" ]; then
        project=${project//\\//}
        while [ "${project%/}" != "$project" ]; do project=${project%/}; done
    fi
    local data
    data=$(registry_read | jq \
        --arg tool "$1" --arg scope "$scope" --arg target "$target" --arg project "$project" '
        map(select((.tool==$tool and .scope==$scope
                    and .target==$target and .project==$project) | not))
    ' 2>/dev/null) || return 0
    printf '%s\n' "$data" > "$REGISTRY"
}

# Hook-target conflict resolution: for each repo represented by multiple hook
# entries (only differing in target), pick the entry that reflects reality —
# probe the project's .claude/settings.json. If our PostToolUse is patched in,
# the claude-bearing entry wins; otherwise the bare target="" entry wins.
# Single-entry groups pass through unchanged. Non-hook entries pass through.
_heal_hook_targets() {  # entries_json → healed_json
    local entries=$1 out='[]' groups gn gi g project cs expected winner
    # Non-hook entries first, unchanged.
    out=$(printf '%s' "$entries" | jq '[.[] | select(.type != "hook")]')
    # Group hook entries by (tool, scope, project) — same-repo entries that
    # only differ in target. For each group, probe reality (does the project
    # carry our claude PostToolUse?) and produce one winner whose target
    # matches reality. Falls back to first entry if no exact target match
    # exists in the group — and re-stamps its target to the expected value,
    # so a lone legacy entry with the wrong target gets healed in place.
    groups=$(printf '%s' "$entries" | jq -c '
        [.[] | select(.type == "hook")]
        | group_by([.tool, .scope, .project])
    ')
    gn=$(printf '%s' "$groups" | jq 'length')
    gi=0
    while [ "$gi" -lt "$gn" ]; do
        g=$(printf '%s' "$groups" | jq -c ".[$gi]")
        gi=$((gi + 1))
        project=$(printf '%s' "$g" | jq -r '.[0].project')
        cs=$(_claude_hook_state "$project" 2>/dev/null || printf 'no')
        if [ "$cs" = yes ]; then expected='claude'; else expected=''; fi
        winner=$(printf '%s' "$g" | jq -c --arg t "$expected" '
            (map(select(.target == $t)) + [.[0]]) | .[0] | .target = $t
        ')
        out=$(printf '%s' "$out" | jq -c --argjson w "$winner" '. + [$w]')
    done
    printf '%s\n' "$out" | jq 'sort_by(.tool, .scope, .target, .project)'
}

# Run $CMD against every registry entry. status: verify, report, prune stale
# entries. remove: uninstall each, then empty the registry. Entries carry
# only install parameters — the handlers re-verify against reality.
registry_sweep() {
    local entries n i e tool type path mkt plg cmdname bin_src kept='[]'
    # Heal five legacy registry pathologies in one pass:
    #   1. {value:[...], Count:n} hulls from PS 5.1 ConvertTo-Json on single-
    #      element arrays — flatten them into their inner entries.
    #   2. Stray whitespace in tool/type/scope/… (e.g. type="bin ") — trim it.
    #   3. Per-type field leakage on config/bin — they are repo-agnostic and
    #      always global; re-apply the registry_add normalization so any
    #      legacy entry with a non-empty target/project/scope collapses.
    #      (hook entries keep target — it's part of the key.)
    #   4. Mixed project-path forms — backslashes vs forward slashes, with or
    #      without a trailing slash. Symmetric with the per-call normalization
    #      in registry_add (sh) and _Registry-Normalize (ps1).
    #   5. Functionally identical entries that only differ by the above — dedup.
    # The post-pass below this jq filter resolves hook-target conflicts (same
    # repo with both target="" and target="claude") by probing reality.
    entries=$(registry_read | jq '
        def unwrap: if type == "object" and has("value") and has("Count")
                       and (keys | length) <= 2
                    then .value[] else . end;
        def trim: if type == "string"
                  then sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
                  else . end;
        def normtype:
            if .type == "config" or .type == "bin"
                then .scope = "global" | .target = "" | .project = ""
            else . end;
        def normproj: if has("project") and (.project // "") != ""
                      then .project |= (gsub("\\\\"; "/") | sub("/+$"; ""))
                      else . end;
        [.[] | unwrap]
        | map(with_entries(.value |= trim))
        | map(normtype)
        | map(normproj)
        | unique_by([.tool, .type, .scope, .target, .project])
    ' 2>/dev/null)
    # Hook-target conflict resolution: pre-d4be626 (and the brief target=""
    # forced era after) can leave one repo recorded twice — once as the bare
    # git-hook (target="") and once as the claude-integrated entry
    # (target="claude"). Probe the project's .claude/settings.json: if our
    # PostToolUse is actually patched in, keep target="claude" and drop
    # target=""; if not, keep target="" and drop target="claude". A repo
    # with only one entry passes through untouched.
    entries=$(_heal_hook_targets "$entries")
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
            # by the other port". `partial` means the primary install (e.g.
            # git-hook) is intact but a secondary aspect (e.g. claude
            # PostToolUse) is missing — keep the entry so the user has a
            # punch-list to re-run install against, don't prune it.
            if [ "$STATE" = ok ] || [ "$STATE" = partial ] || [ "$type" = bin ]; then
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

# True when an entry with this exact key already lives in the registry.
_registry_has() {  # tool type scope target project
    [ -f "$REGISTRY" ] || return 1
    local n
    n=$(registry_read | jq \
        --arg t "$1" --arg ty "$2" --arg s "$3" --arg tg "$4" --arg p "$5" '
        [.[] | select(.tool==$t and .type==$ty and .scope==$s
                      and .target==$tg and .project==$p)] | length
    ' 2>/dev/null) || return 1
    [ "${n:-0}" -ge 1 ]
}

# Discover AI-Toolbox installs that exist on disk but were never recorded —
# e.g. a skill symlinked by hand, outside `toolbox install`. Walks the global
# link destinations (per-target skills dirs, the ~/.claude config dir,
# ~/.local/bin), finds every symlink pointing into THIS repo, matches it to a
# catalog tool by the linked path, and upserts a registry entry for any that is
# missing — so `status --all` / `remove --all` see them. Always registers the
# on-disk form (a symlink => type "skill"), which is what `registry_sweep`
# re-verifies; when the catalog declares a different type (e.g. a plugin that
# was instead hand-linked as a skill) it says so but still adopts the real
# state. Project-scope installs (per-repo hooks/skills) can't be found by a
# global scan — restore those by re-running `install … --scope project`.
registry_reconcile() {
    local adopted=0 target dir l tgt rel row catname cattype regtype
    printf 'toolbox reconcile — discovering links into %s\n' "$REPO_ROOT"

    _adopt() {  # link regtype scope target
        local link=$1 rt=$2 sc=$3 tg=$4 t r row cn ct
        t=$(readlink "$link")
        case "$t" in "$REPO_ROOT"/*) ;; *) return ;; esac
        r=${t#"$REPO_ROOT"/}
        row=$(jq -r --arg p "$r" \
            '.tools[] | select(.path==$p) | "\(.name)|\(.type)"' "$CATALOG")
        [ -n "$row" ] || return
        cn=${row%%|*}; ct=${row#*|}
        if _registry_has "$cn" "$rt" "$sc" "$tg" ''; then
            printf '  [=] %-18s already registered (%s%s)\n' "$cn" "$rt" \
                "${tg:+, $tg}"
        else
            registry_add "$cn" "$rt" "$r" "$sc" "$tg" ''
            printf '  [+] %-18s adopted (%s%s) -> %s\n' "$cn" "$rt" \
                "${tg:+, $tg}" "$link"
            adopted=$((adopted + 1))
        fi
        [ "$ct" = "$rt" ] || printf '      catalog declares type=%s; recorded as %s to match the on-disk link\n' "$ct" "$rt"
    }

    # Skills, per target (claude/codex/agents) at global scope.
    for target in claude codex agents; do
        dir="$HOME/.$target/skills"
        [ -d "$dir" ] || continue
        for l in "$dir"/*; do
            [ -L "$l" ] && _adopt "$l" skill global "$target"
        done
    done
    # Global config files live directly under ~/.claude.
    dir="$HOME/.claude"
    if [ -d "$dir" ]; then
        for l in "$dir"/*; do
            [ -L "$l" ] && _adopt "$l" config global ''
        done
    fi
    # bin symlinks in ~/.local/bin.
    dir="$HOME/.local/bin"
    if [ -d "$dir" ]; then
        for l in "$dir"/*; do
            [ -L "$l" ] && _adopt "$l" bin global ''
        done
    fi

    printf '  %d new install(s) adopted\n\n-- registry status after reconcile --\n' "$adopted"
    CMD=status
    registry_sweep
}

# `status` with no selection arguments shows the registry — bare `toolbox
# status` answers "what is installed?" without needing a --target.
if [ "$CMD" = status ] && [ -z "$ALL" ] && [ -z "$TARGET" ] \
    && [ "$WHAT" = all ] && [ "$SCOPE" = global ]; then
    ALL=1
fi

# reconcile is a global discovery sweep — no selection/target needed.
if [ "$CMD" = reconcile ]; then
    registry_reconcile
    exit 0
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
    # Prefix-match fallback: if --what is an unambiguous prefix of exactly one
    # name or type (or "all"), resolve to that. Ambiguity is reported back so
    # the user can re-issue the command with a longer prefix. Exact matches
    # always win above and never reach this branch.
    candidates=$(jq -r --arg what "$WHAT" '
        ([.tools[] | .name, .type] + ["all"])
        | unique
        | .[] | select(startswith($what))
    ' "$CATALOG")
    count=$(printf '%s' "$candidates" | grep -c .)
    if [ "$count" = 0 ]; then
        printf 'toolbox: nothing in the catalog matches --what %s\n\n' "$WHAT" >&2
        print_catalog_list >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        printf 'toolbox: --what %s is ambiguous — candidates:\n' "$WHAT" >&2
        printf '  %s\n' $candidates >&2
        exit 2
    fi
    printf '  [i] --what %s -> %s\n' "$WHAT" "$candidates"
    WHAT=$candidates
    selected=$(jq -c --arg what "$WHAT" \
        '.tools[] | select($what == "all" or .name == $what or .type == $what)' "$CATALOG")
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
