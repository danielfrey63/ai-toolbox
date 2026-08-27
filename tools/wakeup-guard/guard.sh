#!/usr/bin/env bash
# PreToolUse hook for ScheduleWakeup: refuses wakeups that stem from hook instructions which are no
# longer in force.
#
# Why: a hook that tells the model "call ScheduleWakeup ..." outlives its own uninstall. The
# instruction sits in old transcripts and compaction summaries, the model keeps obeying it from
# context alone, and the loop runs for as long as the session stays open (session-keepwarm, retired
# 2026-08-18, still ticked on 2026-08-27). Documentation cannot fix that - the summary drops it - so
# validity is enforced here, at the harness level.
#
# Contract for hooks that instruct the model to schedule a wakeup: the prompt carries a tag
#   [hook:<name> valid-until:<YYYY-MM-DD>]
# where <name> is the tool's catalog name (its install marker must be present in settings.json)
# and the date bounds the instruction's life even if the uninstall never happens. A wakeup is
# blocked (exit 2, reason on stderr for the model) when
#   - it carries the legacy keepwarm marker (no tag, hook long gone),
#   - its tag names a hook that is not registered in ~/.claude/settings.json,
#   - its valid-until date lies in the past.
# Untagged wakeups (/loop, user-driven pacing) and {"stop": true} pass unchanged.
#
# Input: hook JSON on stdin. Needs only grep/sed/date - runs under Git Bash and Linux bash alike.
set -u
input=$(cat)
settings="$HOME/.claude/settings.json"

block() {
    cat >&2 <<MSG
wakeup-guard: ScheduleWakeup call blocked - $1
The instruction that led here is a leftover from a hook that is no longer in force, not a user
configuration. Do not reschedule it. If a wakeup is still pending, call ScheduleWakeup with
{"stop": true} once, then continue with the actual task.
MSG
    exit 2
}

# Legacy session-keepwarm loop (predates the tag contract).
if printf '%s' "$input" | grep -qi 'keepwarm'; then
    block "Session-Keepwarm was retired on 2026-08-18."
fi

tag=$(printf '%s' "$input" | grep -oE '\[hook:[A-Za-z0-9_-]+( +valid-until:[0-9]{4}-[0-9]{2}-[0-9]{2})?\]' | head -1) || true
[ -n "$tag" ] || exit 0

name=$(printf '%s' "$tag" | sed -E 's/^\[hook:([A-Za-z0-9_-]+).*/\1/')
until=$(printf '%s' "$tag" | grep -oE 'valid-until:[0-9-]+' | cut -d: -f2) || true

if ! [ -f "$settings" ] || ! grep -q "$name" "$settings"; then
    block "hook '$name' is not installed anymore."
fi
if [ -n "$until" ] && [ "$until" \< "$(date +%F)" ]; then
    block "hook '$name' instruction expired on $until."
fi
exit 0
