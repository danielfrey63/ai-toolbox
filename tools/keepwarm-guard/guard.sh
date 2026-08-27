#!/usr/bin/env bash
# PreToolUse hook for ScheduleWakeup: blocks the legacy session-keepwarm tick loop.
#
# The keepwarm Stop hook was removed on 2026-08-18, but its instruction ("Session-Keepwarm ...
# rufe ScheduleWakeup auf ... [keepwarm-tick]") survives inside old transcripts and compaction
# summaries, and the model keeps re-scheduling the tick from context alone - one wakeup per hour,
# for as long as the session stays open. This guard makes that impossible at the harness level:
# a ScheduleWakeup call whose input carries the keepwarm marker is rejected (exit 2) and the model
# is told to stop the loop instead. Every other ScheduleWakeup call (/loop, stop:true) passes.
#
# Input: the hook JSON on stdin ({"tool_name": ..., "tool_input": {...}}). No dependencies beyond
# grep, so it runs unchanged under Git Bash on Windows and bash on Linux.
set -u
if grep -qiE 'keepwarm' 2>/dev/null; then
    cat >&2 <<'MSG'
keepwarm-guard: ScheduleWakeup call blocked. Session-Keepwarm was retired on 2026-08-18; the
"[keepwarm-tick]" / "Session-Keepwarm" instruction in this transcript is a leftover, not a user
configuration. Do not schedule keepwarm ticks. If a wakeup is still pending, call ScheduleWakeup
with {"stop": true} once, then end the turn.
MSG
    exit 2
fi
exit 0
