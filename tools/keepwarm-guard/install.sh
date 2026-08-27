#!/usr/bin/env bash
# Registers (or removes) the keepwarm-guard PreToolUse hook in ~/.claude/settings.json and drops
# any leftover session-keepwarm Stop hook while at it. Idempotent: re-running replaces the entry.
# Modes: install (default) | --uninstall | --status (exit 0 = installed, 1 = not)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
MARKER='keepwarm-guard/guard.sh'
LEGACY='session-keepwarm'
COMMAND="bash \"$HERE/guard.sh\""

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

has_hook() {
    [ -f "$SETTINGS" ] && jq -e --arg m "$MARKER" \
        '[.hooks.PreToolUse // [] | .[] | .hooks[]? | select(.command | contains($m))] | length > 0' \
        "$SETTINGS" >/dev/null 2>&1
}

# Rewrite settings.json through jq: drop our entries and any legacy keepwarm Stop hook first,
# then apply $1 (extra jq filter), then prune empty containers.
rewrite() {
    local extra=$1 tmp
    tmp=$(mktemp)
    jq --arg m "$MARKER" --arg legacy "$LEGACY" --arg cmd "$COMMAND" "
        (.hooks.PreToolUse = ([.hooks.PreToolUse // [] | .[] | select(([.hooks[]? | select(.command | contains(\$m))] | length) == 0)]))
        | (.hooks.Stop = ([.hooks.Stop // [] | .[] | select(([.hooks[]? | select(.command | contains(\$legacy))] | length) == 0)]))
        | $extra
        | if (.hooks.PreToolUse | length) == 0 then (.hooks |= del(.PreToolUse)) else . end
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
            echo "Removed keepwarm-guard PreToolUse hook from $SETTINGS."
        else
            echo "keepwarm-guard hook is not registered - nothing to do."
        fi
        ;;
    install)
        [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
        rewrite '.hooks.PreToolUse += [{matcher: "ScheduleWakeup", hooks: [{type: "command", command: $cmd, timeout: 10}]}]'
        echo "Registered keepwarm-guard PreToolUse hook in $SETTINGS (takes effect for newly started sessions)."
        ;;
    *)
        echo "usage: install.sh [--uninstall|--status]" >&2; exit 2
        ;;
esac
