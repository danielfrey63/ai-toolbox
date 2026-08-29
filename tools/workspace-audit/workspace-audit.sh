#!/usr/bin/env bash
# workspace-audit — inventory and health check of every git repository below a
# workspace root. Read-only: it never writes or mutates anything; --fetch only
# updates remote-tracking refs so ahead/behind counts are current.
#
# Usage: workspace-audit.sh [--depth N] [--fetch] [--quiet] [ROOT ...]
#
#   --depth N   how deep to look for repositories and structure issues (default 3)
#   --fetch     git fetch every remote before computing ahead/behind
#   --quiet     print findings only, no informational lines
#   ROOT        one or more directories to audit (default: current directory)
#
# Findings (one line each, prefixed with the code):
#   SPLIT_GIT        .git has config/HEAD but no objects/refs (or vice versa)
#   NO_REMOTE        repository without any remote
#   DETACHED         HEAD is not on a branch
#   NO_UPSTREAM      branch has no upstream configured
#   AHEAD / BEHIND   local branch diverges from its upstream
#   DIRTY            staged, unstaged or untracked changes
#   SUBMODULE_UNINIT registered submodule not checked out
#   SUBMODULE_DRIFT  submodule checkout differs from the recorded commit
#   NESTED_GIT       a .git inside a repository that is not a registered submodule
#   STRAY_GITMODULES .gitmodules in a directory that is not a repository
#   NAME_MISMATCH    folder name differs from the repository name in origin
#   CONTAINER        directory whose only entry is a single sub-directory
#   SAME_NAME_NESTED directory containing a sub-directory with the same name
#
# Exit code: 0 when no finding was reported, 1 otherwise (usable in automation).
set -u

DEPTH=3
FETCH=0
QUIET=0
ROOTS=()
# Directory names never descended into (dependency and build output trees).
PRUNE_RE='node_modules|\.venv|venv|__pycache__|\.gradle|\.cache|dist|build|target'

while [ $# -gt 0 ]; do
    case "$1" in
        --depth) DEPTH=$2; shift 2 ;;
        --fetch) FETCH=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ROOTS+=("$1"); shift ;;
    esac
done
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(".")

FINDINGS=0
HEADER=''          # path line pending for the current repository/directory
# With --quiet the path line is printed lazily, only once a finding needs it.
header()  { HEADER=$1; [ "$QUIET" = 1 ] || { printf '%s\n' "$HEADER"; HEADER=''; }; }
finding() { FINDINGS=$((FINDINGS + 1)); [ -n "$HEADER" ] && { printf '%s\n' "$HEADER"; HEADER=''; }; printf '  [%s] %s\n' "$1" "$2"; }
info()    { [ "$QUIET" = 1 ] || printf '  %s\n' "$1"; }
lower()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Repository name from a remote URL: drop a trailing slash and .git, keep the last path component.
repo_name_from_url() {
    local url=${1%/}
    url=${url%.git}
    url=${url##*/}
    url=${url##*:}
    printf '%s' "$url"
}

# ok | file | meta-only | store-only | empty — a repository is usable only for ok/file.
git_dir_state() {
    local g=$1
    if [ -f "$g" ]; then
        printf 'file'
        return
    fi
    local meta=0 store=0
    [ -e "$g/HEAD" ] && [ -e "$g/config" ] && meta=1
    [ -d "$g/objects" ] && [ -d "$g/refs" ] && store=1
    if [ $meta = 1 ] && [ $store = 1 ]; then printf 'ok'
    elif [ $meta = 1 ]; then printf 'meta-only'
    elif [ $store = 1 ]; then printf 'store-only'
    else printf 'empty'
    fi
}

audit_repo() {
    local repo=$1
    local name; name=$(basename "$repo")
    header "$repo"

    local state; state=$(git_dir_state "$repo/.git")
    if [ "$state" != ok ] && [ "$state" != file ]; then
        finding SPLIT_GIT ".git is $state - repository metadata is incomplete"
        return
    fi
    # A gitdir file means submodule or worktree: detached HEAD and a folder name
    # chosen by the parent are expected there, not findings.
    local submodule=0
    [ "$state" = file ] && submodule=1

    local previous=$PWD
    cd "$repo" || return
    {
        local origin remote_name branch upstream ahead behind dirty stashes
        origin=$(git remote get-url origin 2>/dev/null || true)
        remote_name=origin
        if [ -z "$origin" ]; then
            remote_name=$(git remote 2>/dev/null | head -1)
            if [ -z "$remote_name" ]; then
                finding NO_REMOTE "no remote configured (local-only history)"
            else
                origin=$(git remote get-url "$remote_name")
                info "remote ($remote_name): $origin"
            fi
        else
            info "remote: $origin"
        fi
        if [ -n "$origin" ] && [ $submodule = 0 ]; then
            local rn; rn=$(repo_name_from_url "$origin")
            if [ -n "$rn" ] && [ "$(lower "$rn")" != "$(lower "$name")" ]; then
                finding NAME_MISMATCH "folder '$name' vs repository '$rn'"
            fi
        fi

        [ "$FETCH" = 1 ] && [ -n "$origin" ] && GIT_TERMINAL_PROMPT=0 git fetch -q --all 2>/dev/null

        branch=$(git symbolic-ref --short -q HEAD || true)
        if [ -z "$branch" ]; then
            local tag; tag=$(git describe --tags --exact-match 2>/dev/null || true)
            if [ $submodule = 1 ]; then
                info "submodule at $(git rev-parse --short HEAD 2>/dev/null)${tag:+ (tag $tag)}"
            else
                finding DETACHED "HEAD detached at $(git rev-parse --short HEAD 2>/dev/null)${tag:+ (tag $tag)}"
            fi
        else
            upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
            if [ -z "$upstream" ]; then
                [ -n "$origin" ] && finding NO_UPSTREAM "branch '$branch' has no upstream"
            else
                read -r behind ahead < <(git rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || echo "0 0")
                info "branch: $branch -> $upstream"
                [ "$ahead" != 0 ] && finding AHEAD "$ahead commit(s) not pushed to $upstream"
                [ "$behind" != 0 ] && finding BEHIND "$behind commit(s) behind $upstream"
            fi
        fi

        dirty=$(git status --porcelain --untracked-files=normal 2>/dev/null | wc -l | tr -d ' ')
        [ "$dirty" != 0 ] && finding DIRTY "$dirty changed/untracked path(s)"

        stashes=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
        [ "$stashes" != 0 ] && info "stashes: $stashes"

        if [ -f .gitmodules ]; then
            # git submodule status: "<flag><sha> <path> (<describe>)", flag is space, -, + or U
            while IFS= read -r line; do
                local flag=${line:0:1}
                local path=${line#* }; path=${path%% (*}
                case "$flag" in
                    -) finding SUBMODULE_UNINIT "$path" ;;
                    +) finding SUBMODULE_DRIFT "$path checked out at a different commit than recorded" ;;
                    U) finding SUBMODULE_DRIFT "$path has merge conflicts" ;;
                esac
            done < <(git submodule status 2>/dev/null)
        fi

        # Nested .git entries that git does not track as submodules (clone inside clone).
        while IFS= read -r nested; do
            local rel=${nested#./}; rel=${rel%/.git}
            [ -z "$rel" ] && continue
            if ! git ls-files --stage -- "$rel" 2>/dev/null | grep -q '^160000'; then
                finding NESTED_GIT "$rel is a git repository but not a submodule"
            fi
        done < <(find . -mindepth 2 -maxdepth $((DEPTH + 1)) -name .git -not -path './.git/*' -not -regex ".*/\($PRUNE_RE\)/.*" 2>/dev/null)
    }
    cd "$previous" || return
}

# Structure checks look at the workspace skeleton only: directories that are
# not inside a working repository (a repository owns its internal layout).
audit_structure() {
    local root=$1
    while IFS= read -r d; do
        case "$(basename "$d")" in .*) continue ;; esac
        if git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1; then
            continue
        fi
        local base; base=$(basename "$d")
        local entries subdirs
        entries=$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        subdirs=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        HEADER=$d
        if [ "$entries" = 1 ] && [ "$subdirs" = 1 ]; then
            finding CONTAINER "only contains $(basename "$(find "$d" -mindepth 1 -maxdepth 1 -type d)")/"
        fi
        if [ -d "$d/$base" ] && [ "$(cd "$d" && pwd -P)" != "$(cd "$d/$base" && pwd -P)" ]; then
            finding SAME_NAME_NESTED "contains a sub-directory named '$base' again"
        fi
        if [ -f "$d/.gitmodules" ] && [ ! -e "$d/.git" ]; then
            finding STRAY_GITMODULES ".gitmodules without a .git"
        fi
        HEADER=''
    done < <(find "$root" -mindepth 1 -maxdepth "$DEPTH" -type d -not -name .git -not -path '*/.git/*' -not -regex ".*/\($PRUNE_RE\)\(/.*\)?" 2>/dev/null | sort)
}

for root in "${ROOTS[@]}"; do
    root=${root%/}
    [ -d "$root" ] || { printf 'not a directory: %s\n' "$root" >&2; continue; }
    printf '== %s\n' "$(cd "$root" && pwd)"
    while IFS= read -r g; do
        audit_repo "$(dirname "$g")"
    done < <(find "$root" -mindepth 1 -maxdepth $((DEPTH + 1)) -name .git -not -path '*/.git/*' -not -regex ".*/\($PRUNE_RE\)/.*" 2>/dev/null | sort)
    audit_structure "$root"
done

if [ "$FINDINGS" = 0 ]; then
    printf '\nno findings\n'
    exit 0
fi
printf '\n%d finding(s)\n' "$FINDINGS"
exit 1
