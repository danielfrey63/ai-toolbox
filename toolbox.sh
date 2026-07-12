#!/usr/bin/env bash
# toolbox.sh — install AI-Toolbox tools from the catalog.
#
# Reads tools/catalog.json and dispatches per tool TYPE to a handler:
#   skill  — symlink the tool into <scope>/.{claude,codex,agents}/skills/
#   hook   — insert a managed version-bump block into a repo's pre/post-commit
#   plugin — claude plugin marketplace add + install (--target claude);
#            for --target codex|agents the plugin falls back to a skill-link
#   config — symlink a global config file (CLAUDE.md) into ~/.claude/
#   bin    — make a CLI available system-wide (PATH symlink, or sourced shell
#            function via catalog "source: true" — needed for env-setting tools)
#   repo   — clone/update an external tool repo as a SIBLING of this toolbox
#            (catalog path "../<name>"), run its dependency install when the
#            lockfile changed, then link its declared artifacts (skill/bin)
#            via the standard link mechanics. remove unlinks the artifacts but
#            never deletes the checkout.
#
# Usage:
#   toolbox.sh <install|status|remove> --target <claude|codex|agents|kilo>
#              [--scope global|project] [--project PATH] [--what all|<name>|<type>]
#              [--tagstyle plain|namespaced]
#
# Parameter families:
#   scope   global (default; base = $HOME) | project (base = --project PATH,
#           which itself defaults to the current directory)
#   target  claude | codex | agents | kilo  — required unless the selection is hook/config/bin-only
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

APP_VERSION='0.40.254'
set -u

# Resolve $0 through symlinks — when invoked via the ~/.local/bin/toolbox
# symlink (the "bin" install) $0 is the link, not the real script.
REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
CATALOG="$REPO_ROOT/tools/catalog.json"

# git-bash/MSYS: without this, `ln -s` silently DEEP-COPIES instead of linking
# (installs then look fine but never receive upstream updates). nativestrict
# makes ln fail loudly when a real symlink cannot be created (needs Windows
# Developer Mode or admin) — a hard error beats a silent copy.
case "$(uname -s)" in
    MINGW*|MSYS*) export MSYS="winsymlinks:nativestrict${MSYS:+ $MSYS}" ;;
esac

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
  toolbox <install|status|remove|list|reconcile|validate> [options]
  toolbox --help [<switch>]

Commands:
  install   Install selected tools (idempotent — safe to re-run).
  status    Report install state; with no args, sweeps the registry.
  remove    Remove selected tools (only ever our own links/config).
  list      Print the catalog (name, type, description).
  reconcile Discover existing links into this repo (e.g. hand-made symlinks)
            and register any that are missing, so status/remove see them.
  validate  Check the catalog against disk — every entry's path exists and,
            for skills/plugins, its SKILL.md carries valid frontmatter.

For switch detail:  toolbox --help <switch>      e.g.  toolbox --help --target

Examples:
  toolbox list
  toolbox validate
  toolbox install --what cli
  toolbox install --what versioning-hooks --scope project
  toolbox status --all
EOF
    _help_switches
}

_help_target() {
    cat <<'EOF'
--target <claude|codex|agents|kilo>
  Where to install. Required, unless the selection is hook/config/bin-only.

  claude   Claude Code      skills link into <scope>/.claude/skills/
  codex    Codex CLI        skills link into <scope>/.codex/skills/
  agents   agentskills.io   skills link into <scope>/.agents/skills/
  kilo     Kilo Code        skills register in ~/.config/kilo/kilo.jsonc ->
                            skills.paths (global scope; skill type only)

  Config/bin entries ignore --target. Hooks honour --target claude (also
  patches the project's .claude/settings.json with an edit-bump PostToolUse
  hook); --target codex|agents is not yet supported for the edit-bump path.
  Plugins do a real `claude plugin` install for --target claude; for other
  targets they fall back to a skill-link. --target kilo handles the skill
  type only (it edits kilo.jsonc, not a skills/ dir); other types are skipped.

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
    hook    Git hooks installed as a managed line in a repo's pre/post-commit.
            Installing a hook WITHOUT --scope project re-installs every
            registered repo (recorded target kept) — one command to refresh
            or migrate all repos after a toolbox update.
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
    printf 'Usage: toolbox <install|status|remove|list|reconcile|validate> [--target claude|codex|agents|kilo] [--scope global|project] [--project PATH] [--what all|<name>|<type>] [--tagstyle plain|namespaced] [--all] [-h|--help]\n\n'
    printf '  %-20s %-7s %s\n' NAME TYPE DESCRIPTION
    jq -r '.tools[] | [.name, .type, .description] | @tsv' "$CATALOG" \
        | while IFS=$(printf '\t') read -r n t d; do
            printf '  %-20s %-7s %s\n' "$n" "$t" "$d"
        done
    printf '\nSelect one with --what <name> or a group with --what <type>; default is all.\n'
}

# --- validate command ----------------------------------------------------------
# Checks the catalog for drift against disk: a renamed/removed source path, a
# SKILL.md whose frontmatter is missing or no longer matches the catalog name,
# a bin entry missing its PowerShell sibling. Read-only, needs no --target or
# --scope — safe to run any time (e.g. before pushing a catalog change).

# The YAML frontmatter block of a SKILL.md (the lines between the first pair
# of "---" markers), without the markers themselves.
_frontmatter() {  # file -> block
    awk '
        NR==1 && $0!="---" {exit}
        NR==1 {next}
        /^---[[:space:]]*$/ {exit}
        {print}
    ' "$1"
}

# A skill/plugin directory must carry a SKILL.md with non-empty name+description
# frontmatter fields. Echoes 0 (ok), 1 (fail — printed to stderr) or 2 (ok, but
# the frontmatter name differs from the catalog name — printed to stdout).
validate_skill_dir() {  # name src -> 0/1/2
    local name=$1 src=$2 fm fmname fmdesc
    if [ ! -f "$src/SKILL.md" ]; then
        printf '  [!] %-18s missing SKILL.md: %s/SKILL.md\n' "$name" "$src" >&2
        return 1
    fi
    fm=$(_frontmatter "$src/SKILL.md")
    fmname=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)
    fmdesc=$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1)
    if [ -z "$fmname" ] || [ -z "$fmdesc" ]; then
        printf '  [!] %-18s SKILL.md frontmatter missing name/description: %s/SKILL.md\n' "$name" "$src" >&2
        return 1
    fi
    if [ "$fmname" != "$name" ]; then
        printf '  [i] %-18s SKILL.md name "%s" != catalog name "%s"\n' "$name" "$fmname" "$name"
        return 2
    fi
    return 0
}

# Walks every catalog entry (index-based, not piped — a piped `while read`
# forks a subshell and the fail/warn counters below would not survive it) and
# checks it resolves to something real on disk. Prints one line per entry plus
# a summary; exit status is non-zero iff any entry failed.
run_validate() {
    local n i tool name type path desc src fail=0 warn=0 total=0
    local cmdname ps1 mkt plg rc
    n=$(jq '.tools | length' "$CATALOG")
    i=0
    while [ "$i" -lt "$n" ]; do
        tool=$(jq -c ".tools[$i]" "$CATALOG")
        i=$((i + 1)); total=$((total + 1))
        name=$(printf '%s' "$tool" | jq -r '.name // empty')
        type=$(printf '%s' "$tool" | jq -r '.type // empty')
        path=$(printf '%s' "$tool" | jq -r '.path // empty')
        desc=$(printf '%s' "$tool" | jq -r '.description // empty')
        if [ -z "$name" ] || [ -z "$type" ] || [ -z "$path" ] || [ -z "$desc" ]; then
            printf '  [!] %-18s missing required field(s) (name/type/path/description)\n' "${name:-?}" >&2
            fail=$((fail + 1)); continue
        fi
        case "$type" in
            skill|hook|plugin|config|bin|repo) ;;
            *) printf '  [!] %-18s unknown type: %s\n' "$name" "$type" >&2
               fail=$((fail + 1)); continue ;;
        esac
        src="$REPO_ROOT/$path"
        case "$type" in
            skill)
                [ -d "$src" ] || { printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2; fail=$((fail + 1)); continue; }
                validate_skill_dir "$name" "$src"; rc=$?
                [ "$rc" = 1 ] && { fail=$((fail + 1)); continue; }
                [ "$rc" = 2 ] && warn=$((warn + 1))
                ;;
            plugin)
                [ -d "$src" ] || { printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2; fail=$((fail + 1)); continue; }
                validate_skill_dir "$name" "$src"; rc=$?
                [ "$rc" = 1 ] && { fail=$((fail + 1)); continue; }
                [ "$rc" = 2 ] && warn=$((warn + 1))
                mkt=$(printf '%s' "$tool" | jq -r '.marketplace // empty')
                plg=$(printf '%s' "$tool" | jq -r '.plugin // empty')
                if [ -z "$mkt" ] || [ -z "$plg" ]; then
                    printf '  [!] %-18s plugin missing marketplace/plugin field\n' "$name" >&2
                    fail=$((fail + 1)); continue
                fi
                ;;
            hook)
                [ -d "$src" ] || { printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2; fail=$((fail + 1)); continue; }
                if [ ! -f "$src/pre-commit" ] || [ ! -f "$src/post-commit" ]; then
                    printf '  [!] %-18s hook dir missing pre-commit/post-commit: %s\n' "$name" "$src" >&2
                    fail=$((fail + 1)); continue
                fi
                ;;
            config)
                [ -f "$src" ] || { printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2; fail=$((fail + 1)); continue; }
                ;;
            bin)
                [ -f "$src" ] || { printf '  [!] %-18s source missing: %s\n' "$name" "$src" >&2; fail=$((fail + 1)); continue; }
                cmdname=$(printf '%s' "$tool" | jq -r '.command // empty')
                if [ -z "$cmdname" ]; then
                    printf '  [!] %-18s bin missing "command" field\n' "$name" >&2
                    fail=$((fail + 1)); continue
                fi
                case "$path" in
                    *.sh)
                        ps1="${path%.sh}.ps1"
                        if [ ! -f "$REPO_ROOT/$ps1" ]; then
                            printf '  [i] %-18s no PowerShell sibling: %s\n' "$name" "$ps1"
                            warn=$((warn + 1))
                        fi
                        ;;
                esac
                ;;
            repo)
                # path is the checkout DESTINATION — its absence is fine (not
                # cloned yet), but the entry needs a url and well-formed links.
                if [ -z "$(printf '%s' "$tool" | jq -r '.url // empty')" ]; then
                    printf '  [!] %-18s repo missing "url" field\n' "$name" >&2
                    fail=$((fail + 1)); continue
                fi
                if [ "$(printf '%s' "$tool" | jq -r '(.links // []) | map(select(.type == null or .path == null or (.type == "skill" and .name == null) or (.type == "bin" and .command == null))) | length')" != 0 ]; then
                    printf '  [!] %-18s repo links need type+path (+name for skill, +command for bin)\n' "$name" >&2
                    fail=$((fail + 1)); continue
                fi
                if [ -d "$src" ]; then
                    # checkout present: declared link sources must exist
                    missing=$(printf '%s' "$tool" | jq -r '(.links // [])[].path' | while IFS= read -r lp; do
                        [ -e "$src/$lp" ] || printf '%s ' "$lp"
                    done)
                    if [ -n "$missing" ]; then
                        printf '  [!] %-18s link source(s) missing in checkout: %s\n' "$name" "$missing" >&2
                        fail=$((fail + 1)); continue
                    fi
                else
                    printf '  [i] %-18s not cloned yet (%s)\n' "$name" "$src"
                    warn=$((warn + 1))
                fi
                ;;
        esac
        printf '  [ok] %-18s %s\n' "$name" "$path"
    done
    printf '\n%d tool(s) checked' "$total"
    [ "$warn" -gt 0 ] && printf ', %d warning(s)' "$warn"
    if [ "$fail" -gt 0 ]; then
        printf ', %d failure(s)\n' "$fail"
        return 1
    fi
    printf ' — all OK\n'
    return 0
}

# --- command ------------------------------------------------------------------
CMD=${1:-}
case "$CMD" in
    install|status|remove|list|reconcile|validate) shift ;;
    -h|--help) show_help "${2:-}"; exit $? ;;
    '') printf 'toolbox: missing command (install|status|remove|list|reconcile|validate)\n' >&2; exit 2 ;;
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
    ''|claude|codex|agents|kilo) ;;
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

# "validate" is a read-only catalog/disk consistency check — no scope/target/
# selection needed either.
if [ "$CMD" = validate ]; then
    run_validate
    exit $?
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
            if ! ln -s "$src" "$link" || [ ! -L "$link" ]; then
                # A non-symlink result means ln fell back to copying (MSYS
                # without symlink privilege) — remove the copy and fail loudly.
                [ -e "$link" ] && [ ! -L "$link" ] && rm -rf "$link"
                printf '  [!] %-18s could not create a real symlink at %s (on Windows: enable Developer Mode or run elevated)\n' "$name" "$link" >&2
                return 1
            fi
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
    if [ "$TARGET" = kilo ]; then
        handle_skill_kilo "$name" "$src"
        return
    fi
    link_artifact "$name" "$src" "$(skill_destdir)"
}

# --- kilo skill target --------------------------------------------------------
# Kilo Code (OpenCode-based) discovers skills via the `skills.paths` array in
# kilo.jsonc, not a skills/ directory. So --target kilo edits that array in
# place — comment-preserving (no jq: the file carries // comments and provider
# secrets), idempotent, each entry tagged with a trailing `// toolbox:skill:<name>`
# so the exact line can be removed again. A .bak is written before each change.
kilo_config() {
    [ -n "${TOOLBOX_KILO_CONFIG:-}" ] && { printf '%s\n' "$TOOLBOX_KILO_CONFIG"; return; }
    local c
    for c in "$HOME/.config/kilo/kilo.jsonc" "$HOME/.config/kilo.jsonc"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return; }
    done
    printf '%s\n' "$HOME/.config/kilo/kilo.jsonc"
}
# Absolute path -> kilo.jsonc-friendly form (D:/... not /d/... on Windows).
kilo_pathval() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}
# Match the rewritten file's final-newline state to the original (Kilo writes
# none) so an unrelated rewrite stays byte-identical.
kilo_match_eof() {  # ref tgt
    if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ] && [ -z "$(tail -c1 "$2")" ]; then
        printf '%s' "$(cat "$2")" > "$2.eof" && mv -- "$2.eof" "$2"
    fi
}
# Count remaining per-skill lines inside the toolbox-managed skills block.
kilo_block_skill_count() {  # file
    awk '
        /\/\/>>> toolbox:skills:managed/ {inb=1; next}
        /\/\/<<< toolbox:skills:managed/ {inb=0; next}
        inb && /\/\/ toolbox:skill:/ {c++}
        END { print c+0 }
    ' "$1"
}

handle_skill_kilo() {
    local name=$1 src=$2
    local f marker val tmp
    f=$(kilo_config)
    marker="toolbox:skill:${name}"
    val=$(kilo_pathval "$src")

    case "$CMD" in
        status)
            if [ -f "$f" ] && grep -qF "// $marker" "$f"; then
                printf '  [ok] %-18s kilo.jsonc skills.paths\n' "$name"; STATE=ok
            else
                printf '  [ ] %-18s not in kilo.jsonc\n' "$name"
            fi
            ;;
        remove)
            if [ -f "$f" ] && grep -qF "// $marker" "$f"; then
                tmp=$(mktemp); cp -- "$f" "$f.bak"
                grep -vF "// $marker" "$f" > "$tmp"
                # if this emptied the block toolbox itself created, drop the block
                if grep -qF 'toolbox:skills:managed' "$tmp" \
                   && [ "$(kilo_block_skill_count "$tmp")" -eq 0 ]; then
                    awk '
                        /\/\/>>> toolbox:skills:managed/ {skip=1}
                        !skip { print }
                        /\/\/<<< toolbox:skills:managed/ {skip=0}
                    ' "$tmp" > "$tmp.b" && mv -- "$tmp.b" "$tmp"
                fi
                kilo_match_eof "$f" "$tmp"; mv -- "$tmp" "$f"
                printf '  [-] %-18s removed from kilo.jsonc\n' "$name"
            else
                printf '  [.] %-18s nothing to remove\n' "$name"
            fi
            ;;
        install)
            if [ ! -f "$f" ]; then
                printf '  [!] %-18s kilo.jsonc not found: %s\n' "$name" "$f" >&2; return
            fi
            if grep -qF "// $marker" "$f"; then
                printf '  [=] %-18s already in kilo.jsonc\n' "$name"; return
            fi
            tmp=$(mktemp); cp -- "$f" "$f.bak"
            if grep -qE '"paths"[[:space:]]*:[[:space:]]*\[[[:space:]]*$' "$f"; then
                # case 1: insert as the first element of an existing skills.paths array
                awk -v v="$val" -v m="$marker" '
                    { print }
                    !done && /"paths"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/ {
                        match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
                        print ind "  \"" v "\", // " m
                        done=1
                    }
                ' "$f" > "$tmp"
            elif grep -qE '"paths"[[:space:]]*:[[:space:]]*\[.*\]' "$f"; then
                # case 1-inline: a single-line paths array. Normalize it to the
                # multiline form so the new entry can carry its // marker without
                # commenting out siblings that follow it on the same line.
                awk -v v="$val" -v m="$marker" '
                    !done && /"paths"[[:space:]]*:[[:space:]]*\[.*\]/ {
                        match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
                        pre=$0;  sub(/\[.*/, "[", pre)         # prefix incl. first "["
                        rest=$0; sub(/^[^[]*\[/, "", rest)     # everything after first "["
                        pos=0; for (i=length(rest); i>=1; i--) if (substr(rest,i,1)=="]") { pos=i; break }
                        inner=substr(rest, 1, pos-1); trail=substr(rest, pos+1)
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", inner)
                        print pre
                        if (inner == "") {
                            print ind "  \"" v "\" // " m
                        } else {
                            print ind "  \"" v "\", // " m
                            print ind "  " inner
                        }
                        print ind "]" trail
                        done=1; next
                    }
                    { print }
                ' "$f" > "$tmp"
            elif grep -qE '"paths"[[:space:]]*:' "$f"; then
                # a paths key exists but not in a layout we can edit safely —
                # fall back to a manual instruction.
                rm -f "$tmp"
                printf '  [!] %-18s kilo.jsonc paths array is not in an editable layout — add manually:\n' "$name" >&2
                printf '        "%s" // %s\n' "$val" "$marker" >&2
                return
            elif grep -qE '"skills"[[:space:]]*:[[:space:]]*\{[[:space:]]*$' "$f"; then
                # case 2: a multiline skills block exists but has no paths array —
                # add a self-marked paths array as the first child of skills.
                awk -v v="$val" -v m="$marker" '
                    { print }
                    !done && /"skills"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
                        match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
                        print ind "  //>>> toolbox:skills:managed (toolbox --target kilo) >>>"
                        print ind "  \"paths\": ["
                        print ind "    \"" v "\" // " m
                        print ind "  ],"
                        print ind "  //<<< toolbox:skills:managed <<<"
                        done=1
                    }
                ' "$f" > "$tmp"
            elif grep -qE '"skills"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}' "$f"; then
                # case 2b: an empty inline skills block ("skills": {}) — rewrite
                # the line into a block carrying a self-marked paths array.
                awk -v v="$val" -v m="$marker" '
                    !done && /"skills"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}/ {
                        match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
                        tail=""; if ($0 ~ /\}[[:space:]]*,[[:space:]]*$/) tail=","
                        print ind "\"skills\": {"
                        print ind "  //>>> toolbox:skills:managed (toolbox --target kilo) >>>"
                        print ind "  \"paths\": ["
                        print ind "    \"" v "\" // " m
                        print ind "  ]"
                        print ind "  //<<< toolbox:skills:managed <<<"
                        print ind "}" tail
                        done=1; next
                    }
                    { print }
                ' "$f" > "$tmp"
            elif ! grep -qE '"skills"[[:space:]]*:' "$f"; then
                # case 3: no skills key yet — create a self-marked block as first
                # child of root {. The markers let `remove` drop the whole block
                # once its last toolbox-managed path is gone (clean round-trip).
                awk -v v="$val" -v m="$marker" '
                    !done && /^[[:space:]]*\{[[:space:]]*$/ {
                        print
                        print "  //>>> toolbox:skills:managed (toolbox --target kilo) >>>"
                        print "  \"skills\": {"
                        print "    \"paths\": ["
                        print "      \"" v "\" // " m
                        print "    ]"
                        print "  },"
                        print "  //<<< toolbox:skills:managed <<<"
                        done=1; next
                    }
                    { print }
                ' "$f" > "$tmp"
            else
                rm -f "$tmp"
                printf '  [!] %-18s kilo.jsonc has an unexpected skills layout — add manually:\n' "$name" >&2
                printf '        "%s" // %s\n' "$val" "$marker" >&2
                return
            fi
            if ! grep -qF "// $marker" "$tmp"; then
                rm -f "$tmp"
                printf '  [!] %-18s could not edit kilo.jsonc (unexpected layout) — add manually:\n' "$name" >&2
                printf '        "%s" // %s\n' "$val" "$marker" >&2
                return
            fi
            kilo_match_eof "$f" "$tmp"; mv -- "$tmp" "$f"
            printf '  [+] %-18s -> kilo.jsonc skills.paths (backup: %s.bak)\n' "$name" "$f"
            ;;
    esac
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
# Installs the versioning git-hooks into a repo by adding a single self-marked
# shim line to the active hooks dir's pre-commit/post-commit (core.hooksPath if
# the repo sets one, else .git/hooks). The line calls the toolbox impl; we never
# touch core.hooksPath, so existing hooks coexist and only our line is
# added/removed. Per-repo: needs --scope project.
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

# ── managed-line helpers ──────────────────────────────────────────────────────
# We do NOT hijack core.hooksPath. Instead we add a single, self-marked shim line
# to the repo's own hook scripts, so our line and any pre-existing hook coexist
# and only our line is ever added or removed. The trailing marker comment tags
# ownership. Git runs hook scripts but never rewrites them, so the comment is safe
# (unlike .git/config, which `git config` reformats).
#
# The shim line is path-free: it calls `toolbox-bump <hook>` — a tiny launcher on
# PATH (~/.local/bin, generated per machine, see _ensure_launchers). So the
# committed/tracked hook carries no machine-specific path and stays portable; each
# machine's launcher points at its own toolbox. The bump logic itself lives in
# the toolbox impl the launcher calls, so it updates centrally with a `git pull`.
_HOOK_MARK='# ai-toolbox:versioning-hooks (managed - do not edit)'

# Where the on-PATH launchers live. ~/.local/bin is on git's `sh` PATH on both
# Linux and Windows git-bash (verified), so git hooks can call them by name —
# unlike the PowerShell-$PROFILE bins, which `sh` never sees.
_LAUNCHER_DIR="$HOME/.local/bin"

# Generate (idempotently) the two POSIX launchers git hooks call by name:
#   toolbox-bump <pre-commit|post-commit>   -> the staged-artifact bump impl
#   bump-version <args...>                   -> the atomic per-file bumper
# The toolbox path is baked in (machine-local — these live under $HOME). Returns
# 0 always; prints a note when ~/.local/bin is not on PATH.
_ensure_launchers() {  # void
    local tb bump_body hook_body
    tb=$(printf '%s' "$REPO_ROOT" | sed 's#\\#/#g')
    mkdir -p "$_LAUNCHER_DIR"
    bump_body="#!/bin/sh
# bump-version — AI-Toolbox per-file version bumper, on PATH for git hooks.
# Generated by \`toolbox install\`; regenerated on every hook install.
exec sh \"$tb/tools/bump-version.sh\" \"\$@\"
"
    hook_body="#!/bin/sh
# toolbox-bump — AI-Toolbox git-hook entry point, on PATH so repo hooks invoke
# the versioning impl by name (no path baked into the committed hook).
# Generated by \`toolbox install\`; regenerated on every hook install.
[ -n \"\$1\" ] || { echo 'usage: toolbox-bump <pre-commit|post-commit> [args]' >&2; exit 2; }
hook=\$1; shift
exec sh \"$tb/tools/githooks/\$hook\" \"\$@\"
"
    _write_launcher "$_LAUNCHER_DIR/bump-version" "$bump_body"
    _write_launcher "$_LAUNCHER_DIR/toolbox-bump" "$hook_body"
    case ":$PATH:" in
        *":$_LAUNCHER_DIR:"*) ;;
        *) printf '  [i] %-18s note: %s is not on PATH — add it so git hooks find the launcher\n' 'versioning-hooks' "$_LAUNCHER_DIR" ;;
    esac
}

# Write a launcher only if missing or changed (idempotent), then mark executable.
_write_launcher() {  # path body
    local path=$1 body=$2
    if [ ! -f "$path" ] || [ "$(cat "$path" 2>/dev/null)" != "$body" ]; then
        printf '%s' "$body" > "$path"
        chmod +x "$path" 2>/dev/null || true
    fi
}

# True when two paths denote the same dir regardless of format (Windows vs MSYS
# slashes, drive-letter case, trailing slash). The exact-string fast path covers
# the same-format case; `-ef` resolves both to one inode when they exist.
_same_hookpath() {  # a b → 0/1
    [ -n "$1" ] || return 1
    [ "$1" = "$2" ] && return 0
    [ "$1" -ef "$2" ] 2>/dev/null
}

# A repo "legacy" install pointed core.hooksPath at our SHARED toolbox hook dir
# (pre-block era). We must never write a per-repo block into that shared dir, and
# such installs need migrating to the block model. True when the repo's
# core.hooksPath resolves to <toolbox>/tools/githooks.
_is_legacy_hookpath() {  # prepo → 0/1
    local cur; cur=$(git -C "$1" config --local core.hooksPath 2>/dev/null || true)
    [ -n "$cur" ] && _same_hookpath "$cur" "$REPO_ROOT/tools/githooks"
}

# Active hooks dir of a repo: core.hooksPath if set (absolute kept as-is, a
# relative value resolved against the repo), else the default .git/hooks. We
# follow whatever the repo already uses, so we coexist with husky/lefthook/etc.
# A legacy core.hooksPath that points at our shared toolbox dir is treated as
# unset (→ .git/hooks) so we never write our block into the toolbox itself.
_active_hooksdir() {  # prepo → abspath
    local prepo=$1 cur
    cur=$(git -C "$prepo" config --local core.hooksPath 2>/dev/null || true)
    if [ -n "$cur" ] && ! _same_hookpath "$cur" "$REPO_ROOT/tools/githooks"; then
        case "$cur" in
            /*|[A-Za-z]:[/\\]*) printf '%s' "$cur" ;;
            *) printf '%s/%s' "$prepo" "$cur" ;;
        esac
    else
        printf '%s/.git/hooks' "$prepo"
    fi
}

# The self-marked, path-free shim line for which=pre|post. Calls the on-PATH
# `toolbox-bump` launcher (see _ensure_launchers) so the committed hook carries no
# machine-specific path. The trailing marker tags the line as ours.
_hook_shim_line() {  # which → string
    printf 'toolbox-bump %s-commit   %s' "$1" "$_HOOK_MARK"
}

# True when the repo's installed pre-commit shim is the portable (toolbox-bump)
# form. A marked line that still hard-codes a path is a pre-launcher install that
# should be re-installed to migrate.
_hook_shim_is_portable() {  # prepo → 0/1
    local dir line
    dir=$(_active_hooksdir "$1"); line=$(grep -F "$_HOOK_MARK" "$dir/pre-commit" 2>/dev/null)
    printf '%s' "$line" | grep -q 'toolbox-bump'
}

# Install/refresh our line in <active>/<which>-commit. Echoes 'added' on a fresh
# insert, 'refreshed' when our marked line was already there.
_hook_block_install() {  # prepo which → verdict
    local prepo=$1 which=$2 dir file line tmp
    dir=$(_active_hooksdir "$prepo"); file="$dir/$which-commit"
    line=$(_hook_shim_line "$which")
    mkdir -p "$dir"
    if [ ! -f "$file" ]; then
        printf '#!/bin/sh\n' > "$file"
        chmod +x "$file" 2>/dev/null || true
    fi
    if grep -qF "$_HOOK_MARK" "$file"; then
        # Replace our marked line in place (first match wins; others dropped).
        tmp=$(awk -v m="$_HOOK_MARK" -v repl="$line" '
            index($0, m) { if (!d) { print repl; d=1 } next } { print }
        ' "$file")
        printf '%s\n' "$tmp" > "$file"
        printf 'refreshed'
    else
        printf '%s\n' "$line" >> "$file"
        printf 'added'
    fi
}

# Strip our marked line from <active>/<which>-commit; delete the file if only a
# shebang (or blank lines) remains. Echoes 'removed' | 'absent'.
_hook_block_remove() {  # prepo which → verdict
    local prepo=$1 which=$2 dir file tmp
    dir=$(_active_hooksdir "$prepo"); file="$dir/$which-commit"
    if [ ! -f "$file" ] || ! grep -qF "$_HOOK_MARK" "$file"; then
        printf 'absent'; return
    fi
    # Drop our marked line(s), then trim trailing blank lines.
    tmp=$(grep -vF "$_HOOK_MARK" "$file" | awk 'NF{p=NR} {a[NR]=$0} END{for(i=1;i<=p;i++) print a[i]}')
    printf '%s\n' "$tmp" > "$file"
    # Delete when nothing but a shebang / blanks is left.
    if awk 'NR==1 && /^#!/ {next} /^[[:space:]]*$/ {next} {f=1} END{exit f?1:0}' "$file"; then
        rm -f "$file"
    fi
    printf 'removed'
}

# True when our marked line is present in the active pre-commit.
_hook_block_present() {  # prepo → 0/1
    local dir; dir=$(_active_hooksdir "$1")
    [ -f "$dir/pre-commit" ] && grep -qF "$_HOOK_MARK" "$dir/pre-commit"
}

# Default install path for a hook when no repo is selected (--scope global):
# re-install every registered repo of this hook, each with its recorded
# target — one command refreshes/migrates all repos after a toolbox update.
# Tagstyle stays per-repo unless --tagstyle was passed explicitly.
_hook_registry_reinstall() {
    local name=$1 path=$2 entries entry proj tgt n=0
    entries=$(registry_read | jq -c --arg tool "$name" \
        '.[] | select(.tool == $tool and .type == "hook" and .project != "")' 2>/dev/null)
    if [ -z "$entries" ]; then
        printf '  [.] %-18s no registered repos yet — install into one with --scope project\n' "$name"
        return
    fi
    local oscope=$SCOPE oproject=$PROJECT otarget=$TARGET
    SCOPE=project
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        proj=$(printf '%s' "$entry" | jq -r '.project')
        tgt=$(printf '%s' "$entry" | jq -r '.target')
        if [ ! -d "$proj" ]; then
            printf '  [!] %-18s registered repo missing on disk: %s\n' "$name" "$proj" >&2
            continue
        fi
        printf '  --- %s%s\n' "$proj" "${tgt:+ (target=$tgt)}"
        PROJECT=$proj
        TARGET=$tgt
        handle_hook "$name" "$path"
        registry_add "$name" hook "$path" project "$tgt" "$proj"
        n=$((n+1))
    done <<EOF
$entries
EOF
    SCOPE=$oscope PROJECT=$oproject TARGET=$otarget
    printf '  [i] %-18s %d registered repo(s) re-installed\n' "$name" "$n"
}

handle_hook() {
    local name=$1 path=$2
    if [ "$SCOPE" != project ]; then
        if [ "$CMD" = install ]; then
            _hook_registry_reinstall "$name" "$path"
        else
            printf '  [.] %-18s hooks are per-repo — pass --scope project\n' "$name"
        fi
        return
    fi
    local prepo curts fresh='' hd vpre vpost
    prepo=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || {
        printf '  [!] %-18s --project is not a git repo: %s\n' "$name" "$PROJECT" >&2
        return
    }
    hd=$(_active_hooksdir "$prepo")
    case "$CMD" in
        install)
            # Migrate a legacy install: drop the core.hooksPath that pointed at
            # our shared toolbox dir, so git uses .git/hooks where the block goes.
            if _is_legacy_hookpath "$prepo"; then
                git -C "$prepo" config --local --unset core.hooksPath
                printf '  [-] %-18s legacy core.hooksPath unset — migrating to managed line\n' "$name"
            fi
            # Ensure the on-PATH launchers exist (the shim line calls them).
            _ensure_launchers
            vpre=$(_hook_block_install "$prepo" pre)
            vpost=$(_hook_block_install "$prepo" post)
            if [ "$vpre" = added ]; then
                printf '  [+] %-18s pre-commit block added -> %s\n' "$name" "$hd/pre-commit"; fresh=1
            else
                printf '  [=] %-18s pre-commit block refreshed (%s)\n' "$name" "$hd/pre-commit"
            fi
            if [ "$vpost" = added ]; then
                printf '  [+] %-18s post-commit block added -> %s\n' "$name" "$hd/post-commit"; fresh=1
            else
                printf '  [=] %-18s post-commit block refreshed (%s)\n' "$name" "$hd/post-commit"
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
            if _hook_block_present "$prepo"; then
                curts=$(git -C "$prepo" config --local bumpversion.tagstyle 2>/dev/null || true)
                if ! _hook_shim_is_portable "$prepo"; then
                    printf '  [! ] %-18s %s (old shim path — re-install to migrate to toolbox-bump%s)\n' "$name" "$prepo" "$cl_suffix"
                    STATE=partial
                elif [ "$cl_state" = "no" ] || [ "$cl_state" = "no-settings" ]; then
                    printf '  [! ] %-18s %s (tagstyle=%s%s)\n' "$name" "$prepo" "${curts:-namespaced}" "$cl_suffix"
                    STATE=partial
                else
                    printf '  [ok] %-18s %s (tagstyle=%s%s)\n' "$name" "$prepo" "${curts:-namespaced}" "$cl_suffix"
                    STATE=ok
                fi
            elif _is_legacy_hookpath "$prepo"; then
                printf '  [! ] %-18s %s (legacy core.hooksPath — re-install to migrate%s)\n' "$name" "$prepo" "$cl_suffix"
                STATE=partial
            else
                printf '  [ ] %-18s not installed in %s%s\n' "$name" "$prepo" "$cl_suffix"
                STATE=
            fi
            ;;
        remove)
            local migrated=''
            if _is_legacy_hookpath "$prepo"; then
                git -C "$prepo" config --local --unset core.hooksPath
                printf '  [-] %-18s legacy core.hooksPath unset (%s)\n' "$name" "$prepo"
                migrated=1
            fi
            vpre=$(_hook_block_remove "$prepo" pre)
            vpost=$(_hook_block_remove "$prepo" post)
            [ "$vpre" = removed ]  && printf '  [-] %-18s pre-commit block removed (%s)\n'  "$name" "$hd/pre-commit"
            [ "$vpost" = removed ] && printf '  [-] %-18s post-commit block removed (%s)\n' "$name" "$hd/post-commit"
            [ -z "$migrated" ] && [ "$vpre" = absent ] && [ "$vpost" = absent ] && printf '  [.] %-18s nothing to remove\n' "$name"
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

# --- repo handler ---------------------------------------------------------------
# Clones/updates an external tool repo as a sibling of this toolbox (catalog
# path "../<name>"), brings its dependencies to the desired state, then links
# the artifacts the catalog declares under "links" (skill/bin) through the
# standard link mechanics. Desired-state throughout: clone only if missing,
# ff-pull only when it applies cleanly, re-install deps only when the lockfile
# content changed. `remove` unlinks the artifacts but NEVER deletes the
# checkout — it may hold local work.

# Bring a checkout's npm dependencies to the desired state. The stamp file
# records the lockfile hash of the last successful install; matching stamp =
# nothing to do. Uses `git hash-object` (git is guaranteed — we just cloned).
_repo_deps() {  # name dest install_cmd
    local name=$1 dest=$2 install=$3
    [ -n "$install" ] || return 0
    local lock stamp want have
    lock="$dest/package-lock.json"
    [ -f "$lock" ] || lock="$dest/package.json"
    [ -f "$lock" ] || { printf '  [i] %-18s install cmd set but no package(-lock).json — skipped\n' "$name"; return 0; }
    want=$(git hash-object "$lock" 2>/dev/null || cksum < "$lock")
    stamp="$dest/node_modules/.ai-toolbox-deps"
    have=$(cat "$stamp" 2>/dev/null || true)
    if [ "$want" = "$have" ]; then
        printf '  [=] %-18s deps up to date\n' "$name"
        return 0
    fi
    if ( cd "$dest" && sh -c "$install" ) >/dev/null 2>&1; then
        mkdir -p "$dest/node_modules" && printf '%s' "$want" > "$stamp"
        printf '  [+] %-18s deps installed (%s)\n' "$name" "$install"
    else
        printf '  [!] %-18s dependency install failed — run manually: cd %s && %s\n' "$name" "$dest" "$install" >&2
        return 1
    fi
}

# Link one declared artifact of a repo checkout. Skill links honour --target
# (incl. kilo); bin links go to ~/.local/bin like the bin handler's exec mode.
_repo_link() {  # repo_name dest link_json
    local dest=$2 link=$3 ltype lpath lname lcmd src
    ltype=$(printf '%s' "$link" | jq -r '.type')
    lpath=$(printf '%s' "$link" | jq -r '.path')
    src="$dest/$lpath"
    case "$ltype" in
        skill)
            lname=$(printf '%s' "$link" | jq -r '.name')
            if [ -z "$TARGET" ]; then
                printf '  [i] %-18s skill link needs --target — skipped\n' "$lname"
                return
            fi
            if [ ! -d "$src" ]; then
                printf '  [!] %-18s link source missing: %s\n' "$lname" "$src" >&2
                return
            fi
            if [ "$TARGET" = kilo ]; then
                handle_skill_kilo "$lname" "$src"
            else
                link_artifact "$lname" "$src" "$(skill_destdir)" "$lname"
            fi
            ;;
        bin)
            lcmd=$(printf '%s' "$link" | jq -r '.command')
            if [ ! -f "$src" ]; then
                printf '  [!] %-18s link source missing: %s\n' "$lcmd" "$src" >&2
                return
            fi
            [ "$CMD" = install ] && chmod +x "$src" 2>/dev/null
            link_artifact "$lcmd" "$src" "$HOME/.local/bin" "$lcmd"
            ;;
        *)
            printf '  [!] %-18s unknown link type "%s"\n' "$1" "$ltype" >&2
            ;;
    esac
}

handle_repo() {  # name path url install links_json
    local name=$1 path=$2 url=$3 install=$4 links=$5
    local dest remote before after n i
    dest=$(readlink -f -- "$REPO_ROOT/$path" 2>/dev/null || printf '%s' "$REPO_ROOT/$path")

    case "$CMD" in
        install)
            if [ ! -d "$dest/.git" ]; then
                if [ -e "$dest" ]; then
                    printf '  [!] %-18s %s exists but is not a git checkout — skipped\n' "$name" "$dest" >&2
                    return
                fi
                if git clone --quiet "$url" "$dest" 2>/dev/null; then
                    printf '  [+] %-18s cloned -> %s\n' "$name" "$dest"
                else
                    printf '  [!] %-18s clone failed: %s\n' "$name" "$url" >&2
                    return 1
                fi
            else
                remote=$(git -C "$dest" remote get-url origin 2>/dev/null || true)
                if [ "$remote" != "$url" ]; then
                    printf '  [i] %-18s origin is %s (catalog: %s) — using checkout as-is\n' "$name" "$remote" "$url"
                fi
                before=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
                if git -C "$dest" pull --ff-only --quiet 2>/dev/null; then
                    after=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
                    if [ "$before" != "$after" ]; then
                        printf '  [+] %-18s updated (%.7s -> %.7s)\n' "$name" "$before" "$after"
                    else
                        printf '  [=] %-18s checkout up to date\n' "$name"
                    fi
                else
                    printf '  [i] %-18s pull skipped (offline, diverged or dirty) — using existing checkout\n' "$name"
                fi
            fi
            _repo_deps "$name" "$dest" "$install" || return 1
            ;;
        status)
            if [ -d "$dest/.git" ]; then
                printf '  [ok] %-18s checkout %s\n' "$name" "$dest"
                STATE=ok
            else
                printf '  [ ] %-18s not cloned (%s)\n' "$name" "$dest"
            fi
            ;;
        remove)
            printf '  [i] %-18s checkout kept at %s (remove never deletes repos)\n' "$name" "$dest"
            ;;
    esac

    n=$(printf '%s' "$links" | jq 'length' 2>/dev/null || printf 0)
    i=0
    while [ "$i" -lt "$n" ]; do
        _repo_link "$name" "$dest" "$(printf '%s' "$links" | jq -c ".[$i]")"
        i=$((i + 1))
    done
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
        # repo checkouts are machine-global; only the skill-link target varies.
        repo)        scope=global; project='' ;;
        # A hook entry without a project is meaningless (per-repo installs
        # only) — never record one, e.g. from a global-scope dispatch pass.
        hook)        [ -n "$project" ] || return 0 ;;
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
        repo)        scope=global; project='' ;;
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
    local entries n i e tool type path mkt plg cmdname bin_src url inst links kept='[]'
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
            repo)
                url=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .url // empty' "$CATALOG")
                inst=$(jq -r --arg n "$tool" \
                    '.tools[] | select(.name==$n) | .install // empty' "$CATALOG")
                links=$(jq -c --arg n "$tool" \
                    'first(.tools[] | select(.name==$n) | .links) // []' "$CATALOG")
                handle_repo "$tool" "$path" "$url" "$inst" "$links" ;;
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
# global scan — pass `--project PATH` to also adopt project-scoped versioning
# hooks: if PATH is a git repo its hook is adopted, otherwise every immediate
# child repo of PATH is scanned (so `reconcile --project ~/Develop` re-adopts a
# whole tree of repos whose registry entries were lost).
registry_reconcile() {
    local adopted=0 target dir l tgt rel row catname cattype regtype
    printf 'toolbox reconcile — discovering links into %s\n' "$REPO_ROOT"

    # Adopt one repo's versioning hook if our managed line sits in the active
    # hooks dir's pre-commit but the registry has no matching entry. The recorded
    # target mirrors reality: claude when the repo carries our claudehook flag,
    # else bare. Repos without our block are silently skipped.
    _adopt_repo_hook() {  # repo
        local repo=$1 prepo proj tg hookrel name
        hookrel=$(jq -r 'first(.tools[] | select(.type=="hook") | .path)' "$CATALOG")
        name=$(jq -r 'first(.tools[] | select(.type=="hook") | .name)' "$CATALOG")
        prepo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 0
        _hook_block_present "$prepo" || return 0
        proj=${prepo//\\//}
        while [ "${proj%/}" != "$proj" ]; do proj=${proj%/}; done
        if [ "$(git -C "$prepo" config --local --bool bumpversion.claudehook 2>/dev/null || true)" = "true" ]; then
            tg=claude
        else
            tg=''
        fi
        if _registry_has "$name" hook project "$tg" "$proj"; then
            printf '  [=] %-18s already registered (hook%s) %s\n' "$name" "${tg:+, $tg}" "$proj"
        else
            registry_add "$name" hook "$hookrel" project "$tg" "$proj"
            printf '  [+] %-18s adopted (hook%s) -> %s\n' "$name" "${tg:+, $tg}" "$proj"
            adopted=$((adopted + 1))
        fi
    }

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

    # Project-scoped versioning hooks (--project PATH). A global scan cannot
    # find these — git config is per-repo. PATH itself a repo => adopt it;
    # otherwise scan its immediate children for repos carrying our hook.
    if [ -n "$PROJECT" ]; then
        local root
        if root=$(cd "$PROJECT" 2>/dev/null && pwd); then
            printf '  scanning project hooks under %s\n' "$root"
            if [ -d "$root/.git" ]; then
                _adopt_repo_hook "$root"
            else
                for d in "$root"/*/; do
                    [ -d "$d/.git" ] && _adopt_repo_hook "${d%/}"
                done
            fi
        else
            printf '  [!] reconcile --project path not found: %s\n' "$PROJECT" >&2
        fi
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

# --target is required unless every selected tool ignores it (hook, config,
# bin — and repo, unless it declares a skill link, which is target-specific).
if [ -z "$TARGET" ]; then
    needs_target=$(printf '%s\n' "$selected" \
        | jq -r 'select((.type != "hook" and .type != "config" and .type != "bin" and .type != "repo")
                        or (.type == "repo" and (((.links // []) | map(select(.type == "skill")) | length) > 0))) | .name' | head -1)
    if [ -n "$needs_target" ]; then
        printf 'toolbox: --target is required (claude|codex|agents|kilo) — "%s" needs it\n' \
            "$needs_target" >&2
        exit 2
    fi
fi

printf '%s\n' "$selected" | while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    name=$(printf '%s' "$tool" | jq -r '.name')
    type=$(printf '%s' "$tool" | jq -r '.type')
    path=$(printf '%s' "$tool" | jq -r '.path')
    if [ "$TARGET" = kilo ] && [ "$type" != skill ] && [ "$type" != repo ]; then
        printf '  [.] %-18s --target kilo supports the skill type only — skipped (%s)\n' "$name" "$type"
        continue
    fi
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
        repo)
            url=$(printf '%s' "$tool" | jq -r '.url // empty')
            inst=$(printf '%s' "$tool" | jq -r '.install // empty')
            links=$(printf '%s' "$tool" | jq -c '.links // []')
            handle_repo "$name" "$path" "$url" "$inst" "$links"
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
