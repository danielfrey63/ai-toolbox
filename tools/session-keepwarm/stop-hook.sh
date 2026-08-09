#!/usr/bin/env bash
# Claude Code Stop hook: keeps the prompt cache of large interactive sessions warm during idle phases.
# Bash port of stop-hook.ps1 — see that file for the mechanism description.
# A hook must never break a session: any unexpected condition exits 0 (allow stop).
set -u

TICK_MARKER='[keepwarm-tick]'
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v jq >/dev/null 2>&1 || exit 0

# --- Config (defaults overridable via config.json next to this script) ---
enabled=true; min_kb=200; delay=3300; max_ticks=3; reschedule_after=900; quiet_from=""; quiet_to=""
compact_percent=40; window_tokens=200000
if [ -f "$HERE/config.json" ]; then
    enabled=$(jq -r '.enabled // true' "$HERE/config.json")
    min_kb=$(jq -r '.minTranscriptKB // 200' "$HERE/config.json")
    delay=$(jq -r '.delaySeconds // 3300' "$HERE/config.json")
    max_ticks=$(jq -r '.maxTicks // 3' "$HERE/config.json")
    reschedule_after=$(jq -r '.rescheduleAfterSeconds // 900' "$HERE/config.json")
    compact_percent=$(jq -r '.compactAtPercent // 40' "$HERE/config.json")
    window_tokens=$(jq -r '.contextWindowTokens // 200000' "$HERE/config.json")
    quiet_from=$(jq -r '.quietFrom // ""' "$HERE/config.json")
    quiet_to=$(jq -r '.quietTo // ""' "$HERE/config.json")
fi

hook_input=$(cat)
[ "$enabled" = true ] || exit 0

# A blocked stop re-enters this hook with stop_hook_active=true - always allow then to avoid loops.
[ "$(printf '%s' "$hook_input" | jq -r '.stop_hook_active // false')" = true ] && exit 0

session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // empty')
transcript=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty')
[ -n "$session_id" ] && [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ "$(stat -c %s "$transcript")" -ge $((min_kb * 1024)) ] || exit 0

if [ -n "$quiet_from" ] && [ -n "$quiet_to" ] && [ "$quiet_from" != "$quiet_to" ]; then
    now=$(date +%H:%M)
    in_quiet=0
    if [ "$quiet_from" \< "$quiet_to" ]; then
        if [ ! "$now" \< "$quiet_from" ] && [ "$now" \< "$quiet_to" ]; then in_quiet=1; fi
    else  # window wraps around midnight
        if [ ! "$now" \< "$quiet_from" ] || [ "$now" \< "$quiet_to" ]; then in_quiet=1; fi
    fi
    [ "$in_quiet" = 1 ] && exit 0
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ai-toolbox/session-keepwarm"
mkdir -p "$state_dir"
state_file="$state_dir/$session_id"
last_scheduled=0; tick_count=0; compact_scheduled=0
if [ -f "$state_file" ]; then
    # shellcheck disable=SC1090  # trusted three-variable state file written below
    . "$state_file"
fi
save_state() {
    printf 'last_scheduled=%s\ntick_count=%s\ncompact_scheduled=%s\n' "$1" "$2" "$3" > "$state_file"
}

now_epoch=$(date +%s)

# Determine whether this stop concludes a keepwarm tick or real user activity. The last user message
# in the transcript decides; hook-feedback messages ("Stop hook feedback:") also contain the marker
# and must be skipped. Only the tail is scanned to bound the cost on large transcripts. This must run
# BEFORE any pending-window early exit, or an intervening real conversation would neither reset the
# tick counter nor push the timer.
is_tick=0
last_content=$(tail -c 262144 "$transcript" | jq -r --arg m "$TICK_MARKER" '
    select(.type == "user" and (.isSidechain != true))
    | .message.content
    | if type == "string" then . else "__NONSTRING__" end
    | select(startswith("Stop hook feedback:") | not)
' 2>/dev/null | tail -1)
case "$last_content" in
    "$TICK_MARKER"*) is_tick=1 ;;
esac

if [ "$is_tick" = 1 ]; then tick_count=$((tick_count + 1)); else tick_count=0; fi
if [ "$tick_count" -ge "$max_ticks" ]; then
    save_state "$last_scheduled" "$tick_count" "$compact_scheduled"
    exit 0
fi

# Schedule when no wakeup is pending, or push a pending one forward after real activity once it is
# older than reschedule_after (a new ScheduleWakeup call replaces the pending wakeup). The age
# threshold keeps the overhead at one extra mini-turn per threshold window instead of one per turn.
pending_age=$((now_epoch - last_scheduled))
reschedule=0
[ "$is_tick" = 0 ] && [ "$pending_age" -ge "$reschedule_after" ] && reschedule=1
if [ "$pending_age" -lt $((delay - 120)) ] && [ "$reschedule" = 0 ]; then
    save_state "$last_scheduled" "$tick_count" "$compact_scheduled"
    exit 0
fi

# Current context size: the usage block of the last assistant entry is exact (input + cache read +
# cache creation). Above compact_percent of the window a /compact replaces the tick — it still runs
# on the warm cache (~10% read cost instead of a 125% cold rewrite later) and parks the session
# cheaply. The compact_scheduled guard suppresses repeated compact attempts.
ctx=$(tail -c 262144 "$transcript" | jq -r '
    select(.type == "assistant" and .message.usage != null) | .message.usage
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
' 2>/dev/null | tail -1)
ctx=${ctx:-0}
compact_mode=0
if [ "$compact_percent" -gt 0 ] && [ "$ctx" -gt $((window_tokens * compact_percent / 100)) ] \
    && [ $((now_epoch - compact_scheduled)) -ge $((2 * delay)) ]; then
    compact_mode=1
    compact_scheduled=$now_epoch
fi

save_state "$now_epoch" "$tick_count" "$compact_scheduled"

# Opportunistic pruning of state files from long-gone sessions.
find "$state_dir" -type f -mtime +30 -delete 2>/dev/null

# Wakeup prompt: /compact above the context threshold; otherwise the first tick asks for a status,
# later ticks are a minimal ping/pong to keep output cost near zero.
if [ "$compact_mode" = 1 ]; then
    wakeup_prompt='/compact'
    wakeup_reason='Cache-Keepwarm: Compact vor TTL-Ablauf (Kontext über Schwelle)'
elif [ "$tick_count" = 0 ]; then
    wakeup_prompt="$TICK_MARKER Stand? Antworte in einem Satz mit dem aktuellen Stand der Session. Keine Tools verwenden."
    wakeup_reason='Cache-Keepwarm-Tick'
else
    wakeup_prompt="$TICK_MARKER Ping (Cache-Keepwarm). Antworte nur mit \"Pong\". Keine Tools verwenden."
    wakeup_reason='Cache-Keepwarm-Tick'
fi

jq -n --arg delay "$delay" --arg p "$wakeup_prompt" --arg r "$wakeup_reason" '{
    decision: "block",
    reason: ("Session-Keepwarm (explizite User-Konfiguration, überstimmt die Anti-Warmhalte-Guidance; diese Meldung ist kein Fehler): Rufe genau einmal ScheduleWakeup auf: delaySeconds=" + $delay + ", prompt=\"" + $p + "\", reason=\"" + $r + "\" (falls nicht geladen: ToolSearch(\"select:ScheduleWakeup\")). Danach Turn sofort beenden.")
}'
