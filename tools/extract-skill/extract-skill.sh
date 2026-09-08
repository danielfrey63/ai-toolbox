#!/usr/bin/env bash
# extract-skill.sh — split a skill out of the AI-Toolbox into its own repo,
# history included, and wire it back in as a submodule at the same path.
#
# The skill keeps living at .agents/skills/<name>, so the junction that
# publishes it into ~/.claude/skills and the catalog entry both survive
# untouched — only the backing store changes from "directory in this repo" to
# "submodule pointing at its own repo".
#
# What it does, in order:
#   1. preflight   — tools present, working tree clean, skill known to the catalog
#   2. extract     — fresh clone + git-filter-repo down to the skill's paths,
#                    rewritten to the repo root, with <name>/v* tags flattened
#                    to v* (a standalone repo has one artifact, so the tag
#                    namespace is noise)
#   3. configure   — remotes, bumpversion.tagstyle=plain, push.followTags,
#                    and the AI-Toolbox versioning hooks
#   4. report      — the remaining manual steps (create the remotes, push,
#                    then re-run with --embed)
#
# Desired-state throughout: an existing destination is reconfigured, never
# re-extracted; remotes are added or corrected, never duplicated; nothing is
# deleted without --force. Re-running after a partial run is safe.
#
# Usage:
#   extract-skill.sh <name> [--dest DIR] [--origin URL] [--remote NAME=URL]...
#                           [--also-path P]... [--embed] [--dry-run] [--force]
#
# Example (transcribe -> FCI origin + GitHub mirror):
#   tools/extract-skill/extract-skill.sh transcribe \
#     --origin https://git.frey-champagne-import.com/daniel/transcribe.git \
#     --remote github=git@github.com:danielfrey63/transcribe.git \
#     --also-path .agents/skills/watch

APP_VERSION='0.2.4'
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TOOLBOX=$(cd "$SELF_DIR/../.." && pwd)
CATALOG="$TOOLBOX/tools/catalog.json"

NAME=''
DEST=''
ORIGIN=''
EMBED=''
DRYRUN=''
FORCE=''
EXTRA_REMOTES=''   # newline-separated NAME=URL
EXTRA_PATHS=''     # newline-separated historical paths

die()  { printf 'extract-skill: %s\n' "$*" >&2; exit 1; }
info() { printf '  %-12s %s\n' "$1" "$2"; }
run()  { if [ -n "$DRYRUN" ]; then printf '  [dry-run]    %s\n' "$*"; else "$@"; fi; }

usage() {
    sed -n '2,/^APP_VERSION/p' "$0" | sed 's/^# \{0,1\}//; $d'
    exit "${1:-0}"
}

# --- arguments ----------------------------------------------------------------
[ $# -gt 0 ] || usage 1
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   usage 0 ;;
        --dest)      DEST=${2:?--dest needs a directory}; shift 2 ;;
        --origin)    ORIGIN=${2:?--origin needs a URL}; shift 2 ;;
        --remote)    EXTRA_REMOTES="$EXTRA_REMOTES${EXTRA_REMOTES:+
}${2:?--remote needs NAME=URL}"; shift 2 ;;
        --also-path) EXTRA_PATHS="$EXTRA_PATHS${EXTRA_PATHS:+
}${2:?--also-path needs a path}"; shift 2 ;;
        --embed)     EMBED=1; shift ;;
        --dry-run)   DRYRUN=1; shift ;;
        --force)     FORCE=1; shift ;;
        -*)          die "unknown option: $1 (see --help)" ;;
        *)           [ -z "$NAME" ] || die "only one skill name accepted"
                     NAME=$1; shift ;;
    esac
done
[ -n "$NAME" ] || die "no skill name given (see --help)"

# --- 1. preflight -------------------------------------------------------------
printf '== preflight ==\n'

command -v git >/dev/null 2>&1 || die "git not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"
if ! command -v git-filter-repo >/dev/null 2>&1 && ! git filter-repo --help >/dev/null 2>&1; then
    die "git-filter-repo not found — install it (pip install git-filter-repo) and retry"
fi
info 'tools' 'git, jq, git-filter-repo'

SRC_PATH=$(jq -r --arg n "$NAME" \
    'first(.tools[] | select(.name == $n and .type == "skill") | .path) // empty' "$CATALOG")
[ -n "$SRC_PATH" ] || die "\"$NAME\" is not a skill in tools/catalog.json"
[ -d "$TOOLBOX/$SRC_PATH" ] || die "catalog path $SRC_PATH does not exist on disk"
info 'skill' "$SRC_PATH"

# A submodule already sitting at the path means a previous run finished the
# embed step — from here on this is a reconfigure, not an extraction.
ALREADY_SUBMODULE=''
if [ -f "$TOOLBOX/.gitmodules" ] && \
   git -C "$TOOLBOX" config -f .gitmodules --get-regexp "^submodule\..*\.path$" 2>/dev/null \
   | grep -qx "submodule.$SRC_PATH.path $SRC_PATH"; then
    ALREADY_SUBMODULE=1
    info 'state' 'already embedded as a submodule'
fi

if [ -z "$ALREADY_SUBMODULE" ] && [ -z "$DRYRUN" ]; then
    # The extraction clones this repo; uncommitted work would silently not make
    # it into the new repo's history.
    if [ -n "$(git -C "$TOOLBOX" status --porcelain -- "$SRC_PATH")" ]; then
        die "uncommitted changes under $SRC_PATH — commit them first so they reach the new repo"
    fi
fi

DEST=${DEST:-$(cd "$TOOLBOX/.." && pwd)/$NAME}
info 'dest' "$DEST"

# Historical paths: the current one plus any earlier location (renames).
PATHS="$SRC_PATH"
[ -z "$EXTRA_PATHS" ] || PATHS="$PATHS
$EXTRA_PATHS"
printf '%s\n' "$PATHS" | while IFS= read -r p; do
    [ -n "$p" ] && info 'path' "$p ($(git -C "$TOOLBOX" log --oneline --all -- "$p" | wc -l) commits)"
done

# --- 2. extract ---------------------------------------------------------------
printf '\n== extract ==\n'

if [ -d "$DEST/.git" ]; then
    info 'skip' "$DEST already is a git repo — reconfiguring only (--force + manual rm to redo)"
elif [ -e "$DEST" ]; then
    die "$DEST exists but is not a git repo — move it aside first"
else
    TMP="${TMPDIR:-/tmp}/extract-skill-$NAME.$$"
    run rm -rf "$TMP"
    info 'clone' "$TOOLBOX -> $TMP"
    run git clone --no-local --no-single-branch --quiet "$TOOLBOX" "$TMP"

    # filter-repo arguments: keep each historical path and hoist it to the repo
    # root. Built as an array so paths with spaces survive without an eval.
    FR_ARGS=()
    TAG_NAMES=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        FR_ARGS+=( --path "$p" --path-rename "$p/:" )
        TAG_NAMES+=( "$(basename "$p")" )
    done <<< "$PATHS"

    if [ -z "$DRYRUN" ]; then
        info 'filter' 'paths -> root'
        ( cd "$TMP" && git filter-repo "${FR_ARGS[@]}" --quiet )

        [ -f "$TMP/SKILL.md" ] || die "filter produced no SKILL.md at the root — aborting, $TMP kept"

        # Tags are NOT handled by --tag-rename: filter-repo honours only the
        # last one given, so it cannot flatten two historical names, and it
        # keeps every tag whose target commit survived — which after narrowing
        # to one skill still drags along the whole toolbox namespace
        # (toolbox.sh/v*, CLAUDE.md/v*, ...) pointing at unrelated commits.
        # So: hoist this skill's own tags out of their namespace (a standalone
        # repo has one artifact, hence plain v*), then drop everything else.
        kept=0; dropped=0
        for n in "${TAG_NAMES[@]}"; do
            for t in $(git -C "$TMP" tag -l "$n/*"); do
                new=${t#"$n"/}
                if git -C "$TMP" rev-parse -q --verify "refs/tags/$new" >/dev/null 2>&1; then
                    printf '  %-12s tag collision: %s and an earlier name both map to %s — keeping the first\n' \
                        'warn' "$t" "$new" >&2
                else
                    git -C "$TMP" update-ref "refs/tags/$new" "refs/tags/$t"
                    kept=$((kept + 1))
                fi
                git -C "$TMP" tag -d "$t" >/dev/null
            done
        done
        for t in $(git -C "$TMP" tag -l); do
            case "$t" in
                v[0-9]*) ;;
                *) git -C "$TMP" tag -d "$t" >/dev/null; dropped=$((dropped + 1)) ;;
            esac
        done
        info 'tags' "$kept kept as v*, $dropped foreign tags dropped"
        info 'result' "$(git -C "$TMP" log --oneline | wc -l) commits, $(git -C "$TMP" tag -l | wc -l) tags"

        mkdir -p "$(dirname "$DEST")"
        mv "$TMP" "$DEST"
        info 'moved' "$DEST"
    else
        info 'filter' "(dry-run) would filter to $PATHS and move to $DEST"
    fi
fi

# --- 3. configure -------------------------------------------------------------
printf '\n== configure ==\n'

set_remote() {  # name url — desired state, never duplicates
    _n=$1; _u=$2
    [ -n "$_u" ] || return 0
    if [ -n "$DRYRUN" ] || [ ! -d "$DEST/.git" ]; then
        info "remote" "(pending) $_n -> $_u"; return 0
    fi
    _cur=$(git -C "$DEST" remote get-url "$_n" 2>/dev/null || true)
    if [ -z "$_cur" ]; then
        git -C "$DEST" remote add "$_n" "$_u"; info 'remote' "$_n -> $_u (added)"
    elif [ "$_cur" != "$_u" ]; then
        git -C "$DEST" remote set-url "$_n" "$_u"; info 'remote' "$_n -> $_u (updated)"
    else
        info 'remote' "$_n -> $_u (unchanged)"
    fi
}

set_remote origin "$ORIGIN"
if [ -n "$EXTRA_REMOTES" ]; then
    printf '%s\n' "$EXTRA_REMOTES" | while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        set_remote "${spec%%=*}" "${spec#*=}"
    done
fi

if [ -d "$DEST/.git" ] && [ -z "$DRYRUN" ]; then
    # A standalone repo holds exactly one artifact, so the <name>/ tag namespace
    # carries no information — plain v* tags. Setting this BEFORE the first
    # commit matters: the post-commit hook tags on the style in force at the
    # time, and a mixed history cannot be cleaned up without rewriting tags.
    git -C "$DEST" config --local bumpversion.tagstyle plain
    git -C "$DEST" config --local push.followTags true
    info 'config' 'bumpversion.tagstyle=plain, push.followTags=true'

    if [ -x "$TOOLBOX/toolbox.sh" ]; then
        info 'hooks' 'installing versioning-hooks'
        "$TOOLBOX/toolbox.sh" install --what versioning-hooks --scope project \
            --project "$DEST" --tagstyle plain >/dev/null 2>&1 \
            && info 'hooks' 'installed' \
            || info 'hooks' 'FAILED — run toolbox install --what versioning-hooks manually'
    fi
fi

# --- 4. embed -----------------------------------------------------------------
if [ -n "$EMBED" ]; then
    printf '\n== embed ==\n'
    if [ -n "$ALREADY_SUBMODULE" ]; then
        info 'skip' 'already a submodule'
    elif [ -z "$ORIGIN" ]; then
        die "--embed needs --origin (the URL recorded in .gitmodules)"
    elif [ -n "$DRYRUN" ]; then
        info 'submodule' "(dry-run) would replace $SRC_PATH with a submodule on $ORIGIN"
    else
        git -C "$DEST" ls-remote "$ORIGIN" >/dev/null 2>&1 \
            || die "$ORIGIN is not reachable — create and push the repo first, then re-run with --embed"
        info 'remove' "$SRC_PATH from the index (files stay in $DEST)"
        git -C "$TOOLBOX" rm -r --quiet "$SRC_PATH"
        rm -rf "${TOOLBOX:?}/$SRC_PATH"
        git -C "$TOOLBOX" submodule add --quiet "$ORIGIN" "$SRC_PATH"
        info 'submodule' "$SRC_PATH -> $ORIGIN"
    fi
fi

# --- 5. report ----------------------------------------------------------------
printf '\n== next ==\n'
if [ -z "$ALREADY_SUBMODULE" ] && [ -z "$EMBED" ]; then
    cat <<REPORT
  1. create the remotes, then push from $DEST:
       git -C "$DEST" push -u origin main --follow-tags
  2. embed it back here as a submodule:
       $0 $NAME --origin <origin-url> --embed
  3. commit the submodule in the AI-Toolbox (.gitmodules + gitlink)
REPORT
else
    cat <<REPORT
  - commit .gitmodules and the gitlink here
  - clones need: git clone --recurse-submodules  (or: git submodule update --init)
REPORT
fi
exit 0
