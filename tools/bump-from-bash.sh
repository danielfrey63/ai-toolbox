#!/usr/bin/env bash
# bump-from-bash.sh — PostToolUse:Bash adapter for bump-version.sh.
#
# The Edit/Write hook covers Claude's Edit and Write tools, but file
# mutations that happen via the Bash tool (sed -i, > redirects, tee …)
# bypass it. This adapter reads the Bash tool payload from stdin, finds
# the files that the command mutates, and runs bump-version.sh per file.
#
# Recognized mutation patterns:
#   sed -i [...] FILES         in-place sed (-i, -i.bak, -i '')
#   tee [-a|--append] FILES    capturing tee
#   > FILE  / >> FILE          shell redirects (incl. >FILE / >>FILE glued)
#
# Over-detection is harmless — bump-version.sh exits 0 for any path that
# is not a recognized artifact. Under-detection is the only real failure.

APP_VERSION='0.2.3'
set -u

INPUT=$(cat 2>/dev/null || true)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0

REPO_ROOT=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)
BUMP="$REPO_ROOT/tools/bump-version.sh"
[ -f "$BUMP" ] || exit 0

declare -A SEEN=()
emit() {  # path
    local p=$1
    [ -n "$p" ] || return
    p=${p#\"}; p=${p%\"}
    p=${p#\'}; p=${p%\'}
    case "$p" in /dev/*|-|"") return ;; esac
    [ -n "${SEEN[$p]:-}" ] && return
    SEEN[$p]=1
    bash "$BUMP" "$p" 2>/dev/null || true
}

# Split the command on shell separators (; && || |) so each sub-command is
# parsed in isolation. Word-splitting via "set --" loses quotes — good
# enough for paths, and the emit() helper strips trivial wrapping quotes.
while IFS= read -r SUB; do
    SUB=${SUB# }; SUB=${SUB% }
    [ -n "$SUB" ] || continue
    # shellcheck disable=SC2086
    set -- $SUB

    while [ $# -gt 0 ]; do
        tok=$1; shift
        case "$tok" in
            sed)
                inplace=0
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -i|-i.*|-i'') inplace=1; shift ;;
                        -e|-f)        shift 2 2>/dev/null || shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *) break ;;
                    esac
                done
                if [ "$inplace" = 1 ] && [ $# -gt 0 ]; then
                    shift           # the sed script itself
                    while [ $# -gt 0 ]; do
                        case "$1" in -*) shift ;; *) emit "$1"; shift ;; esac
                    done
                fi
                break ;;
            tee)
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -a|--append|-i|--ignore-interrupts) shift ;;
                        --) shift; break ;;
                        -*) shift ;;
                        *) emit "$1"; shift ;;
                    esac
                done
                break ;;
            *)
                # Redirect targets: >>FILE / >FILE glued, or > FILE / >> FILE separated.
                case "$tok" in
                    \>\>*) [ "$tok" != '>>' ] && emit "${tok#>>}" ;;
                    \>*)   [ "$tok" != '>'  ] && emit "${tok#>}"  ;;
                esac
                if [ "$tok" = '>' ] || [ "$tok" = '>>' ]; then
                    [ $# -gt 0 ] && { emit "$1"; shift; }
                fi
                ;;
        esac
    done
done < <(printf '%s' "$CMD" | awk 'BEGIN{RS="[;&|]+"} {print}')
exit 0
