#!/usr/bin/env bash
# mirror-skill.sh - publish one skill of the AI-Toolbox to its own repository,
# one way, as a release step.
#
# The toolbox stays the source. The skill's directory is split out with its
# own history (git subtree split, deterministic: the same commits give the
# same hashes), so the mirror only ever receives new commits on top. Nobody
# commits on the mirror side; a commit there makes the next push fail
# (fast-forward only, never forced).
#
# The target comes from the skill's "mirror" entry in tools/catalog.json:
#   {"remote": "<git remote name>", "url": "<clone url>", "branch": "<branch>"}
#
# Desired state, every step checked first:
#   1. remote   - <remote> exists with that URL; `git push <remote>` pushes
#                 only the split branch to <branch> (remote.<r>.push), and
#                 fetch brings no tags into the toolbox (tagOpt --no-tags),
#                 so a plain v* tag can never travel on to origin
#   2. split    - local branch <remote> = the skill's history up to main
#   3. push     - <branch> and the tag v<version from plugin.json>, only when
#                 the mirror is behind; "up to date" otherwise
#
# Usage:
#   mirror-skill.sh <name> [--dry-run]
#
# --dry-run sets up the remote (step 1) and the split (step 2), then shows
# what step 3 would push without pushing.

APP_VERSION='0.2.3'
set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TOOLBOX=$(cd "$SELF_DIR/../.." && pwd)
CATALOG="$TOOLBOX/tools/catalog.json"

die()  { printf 'mirror-skill: %s\n' "$*" >&2; exit 1; }
info() { printf '  %-8s %s\n' "$1" "$2"; }
usage() {
    sed -n '2,/^APP_VERSION/p' "$0" | sed 's/^# \{0,1\}//; $d'
    exit "${1:-0}"
}

NAME=''
DRYRUN=''
[ $# -gt 0 ] || usage 1
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --dry-run) DRYRUN=1 ;;
        -*) die "unknown option: $1" ;;
        *) [ -z "$NAME" ] || die "one skill per call"; NAME=$1 ;;
    esac
    shift
done

command -v jq >/dev/null 2>&1 || die "jq not found"
cd "$TOOLBOX"

entry=$(jq -c --arg n "$NAME" 'first(.tools[] | select(.name == $n)) // empty' "$CATALOG")
[ -n "$entry" ] || die "no catalog entry «$NAME»"
PREFIX=$(printf '%s' "$entry" | jq -r '.path // empty')
REMOTE=$(printf '%s' "$entry" | jq -r '.mirror.remote // empty')
URL=$(printf '%s' "$entry" | jq -r '.mirror.url // empty')
TARGET=$(printf '%s' "$entry" | jq -r '.mirror.branch // "main"')
[ -n "$REMOTE" ] && [ -n "$URL" ] || die "catalog entry «$NAME» has no mirror.remote / mirror.url"
[ -d "$PREFIX" ] || die "skill directory missing: $PREFIX"
SPLIT=$REMOTE

printf 'mirror-skill %s -> %s (%s)\n' "$NAME" "$URL" "$TARGET"

# 1. remote
if [ "$(git remote get-url "$REMOTE" 2>/dev/null || true)" = "$URL" ]; then
    info remote "$REMOTE ok"
elif git remote get-url "$REMOTE" >/dev/null 2>&1; then
    git remote set-url "$REMOTE" "$URL"; info remote "$REMOTE url corrected"
else
    git remote add "$REMOTE" "$URL"; info remote "$REMOTE added"
fi
want_push="refs/heads/$SPLIT:refs/heads/$TARGET"
[ "$(git config --get "remote.$REMOTE.push" || true)" = "$want_push" ] || git config "remote.$REMOTE.push" "$want_push"
[ "$(git config --get "remote.$REMOTE.tagOpt" || true)" = "--no-tags" ] || git config "remote.$REMOTE.tagOpt" --no-tags

# 2. split - committed state of main only; uncommitted edits are not part of a release
[ -z "$(git status --porcelain -- "$PREFIX")" ] || info note "uncommitted changes in $PREFIX are not mirrored"
info split "$PREFIX (this takes a minute)"
HEAD_SHA=$(git subtree split --prefix "$PREFIX" main 2>/dev/null | tail -n 1)
[ -n "$HEAD_SHA" ] || die "subtree split produced nothing"
[ "$(git rev-parse -q --verify "refs/heads/$SPLIT" || true)" = "$HEAD_SHA" ] || git branch -f "$SPLIT" "$HEAD_SHA" >/dev/null
VERSION=$(git show "$HEAD_SHA:.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty' || true)
TAG=${VERSION:+v$VERSION}
info split "$SPLIT = ${HEAD_SHA:0:7}${TAG:+ ($TAG)}"

# 3. push
# an unreachable mirror must stop here, not pass for an empty one
refs=$(git ls-remote "$REMOTE") || die "mirror $URL not reachable (VPN / SSH key?)"
remote_head=$(printf '%s\n' "$refs" | awk -v r="refs/heads/$TARGET" '$2 == r {print $1}')
remote_tag=''
[ -z "$TAG" ] || remote_tag=$(printf '%s\n' "$refs" | awk -v r="refs/tags/$TAG" '$2 == r {print $1}')
if [ "$remote_head" = "$HEAD_SHA" ] && { [ -z "$TAG" ] || [ -n "$remote_tag" ]; }; then
    info mirror "up to date (${remote_head:0:7}${TAG:+, $TAG})"
    exit 0
fi
if [ -n "$remote_head" ] && ! git merge-base --is-ancestor "$remote_head" "$HEAD_SHA" 2>/dev/null; then
    die "$TARGET on the mirror (${remote_head:0:7}) is not an ancestor of the split - someone committed there; sort it out by hand, nothing is forced"
fi
if [ -n "$DRYRUN" ]; then
    info dry-run "would push $SPLIT ${HEAD_SHA:0:7} -> $TARGET (now ${remote_head:0:7})"
    [ -z "$TAG" ] || [ -n "$remote_tag" ] || info dry-run "would push tag $TAG"
    exit 0
fi
[ "$remote_head" = "$HEAD_SHA" ] || git push "$REMOTE"
# the tag goes straight from the commit - no local v* tag that a later `git push --tags` could carry to origin
[ -z "$TAG" ] || [ -n "$remote_tag" ] || git push "$REMOTE" "$HEAD_SHA:refs/tags/$TAG"
info mirror "pushed ${HEAD_SHA:0:7}${TAG:+ and $TAG}"
