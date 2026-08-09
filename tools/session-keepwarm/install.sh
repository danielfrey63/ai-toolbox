#!/usr/bin/env bash
# Registers (or removes) the session-keepwarm Stop hook in ~/.claude/settings.json.
# Idempotent: re-running replaces the existing hook entry.
# Modes: install (default) | --uninstall | --status (exit 0 = installed, 1 = not)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
MARKER='session-keepwarm/stop-hook.sh'
COMMAND="bash \"$HERE/stop-hook.sh\""

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

has_hook() {
    [ -f "$SETTINGS" ] && jq -e --arg m "$MARKER" \
        '[.hooks.Stop // [] | .[] | .hooks[]? | select(.command | contains($m))] | length > 0' \
        "$SETTINGS" >/dev/null 2>&1
}

# Rewrite settings.json through jq, dropping our entries first; $1 = extra jq filter to apply after.
rewrite() {
    local extra=$1 tmp
    tmp=$(mktemp)
    jq --arg m "$MARKER" --arg cmd "$COMMAND" "
        (.hooks.Stop = ([.hooks.Stop // [] | .[] | select(([.hooks[]? | select(.command | contains(\$m))] | length) == 0)]))
        | $extra
        | if (.hooks.Stop | length) == 0 then (.hooks |= del(.Stop)) else . end
        | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
    " "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

case "${1:-install}" in
    --status)
        has_hook && exit 0 || exit 1
        ;;
    --uninstall)
        if has_hook; then
            rewrite '.'
            echo "Removed session-keepwarm Stop hook from $SETTINGS."
        else
            echo "session-keepwarm Stop hook is not registered - nothing to do."
        fi
        ;;
    install)
        [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
        rewrite '.hooks.Stop += [{hooks: [{type: "command", command: $cmd, timeout: 30}]}]'
        echo "Registered session-keepwarm Stop hook in $SETTINGS (takes effect for newly started sessions)."
        ;;
    *)
        echo "usage: install.sh [--uninstall|--status]" >&2; exit 2
        ;;
esac
