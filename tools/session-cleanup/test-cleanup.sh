#!/usr/bin/env bash
# Fixture-based end-to-end test for cleanup-sessions.sh and cleanup-sessions.ps1. Builds a sandbox
# ~/.claude tree covering every cleanup rule (DELETE marker, contained duplicate, handover leftover,
# parallel-work divergence, renamed-apart copies, title prefix merge, small namesake, title collision,
# empty session, open-session protection, trash purge), runs the cleanup against it twice and asserts
# the filesystem outcome, the log lines, findings.txt and idempotency of the second run. The bash
# variant always runs; the PowerShell variant runs when pwsh/powershell plus cygpath are available
# (i.e. on the Windows devbox). The real ~/.claude is never touched: both variants derive all paths
# from HOME / USERPROFILE, which point into the sandbox. Idempotent: every run starts from a fresh
# sandbox and removes it afterwards.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLEANUP_SH="$SCRIPT_DIR/cleanup-sessions.sh"
CLEANUP_PS1="$SCRIPT_DIR/cleanup-sessions.ps1"
TODAY=$(date +%Y-%m-%d)

# Fixed fixture timestamps, all safely in the past (MinAgeHours=0 means "before now").
TS0="2026-01-01T10:00:00.000Z"
TS1="2026-01-01T10:01:00.000Z"
TS_PAD="2026-01-01T09:00:00.000Z"
PAD=$(printf 'x%.0s' $(seq 1 160))

# Session IDs, one per scenario. Same length as real UUIDs so the SID neutralization in phase 1b
# stays a byte-for-byte swap.
U_DEL="aaaaaaa0-0000-4000-8000-000000000001"
U_DELBUG="aaaaaaa0-0000-4000-8000-000000000002"
U_DUP="aaaaaaa1-0000-4000-8000-000000000001"
U_HO="aaaaaaa3-0000-4000-8000-000000000001"
U_PAR="aaaaaaa4-0000-4000-8000-000000000001"
U_RA="aaaaaaa5-0000-4000-8000-000000000001"
U_B6="aaaaaaa6-0000-4000-8000-00000000big1"
U_S6="aaaaaaa6-0000-4000-8000-0000000small"
U_B7="aaaaaaa7-0000-4000-8000-00000000big1"
U_S7="aaaaaaa7-0000-4000-8000-0000000small"
U_C8A="aaaaaaa8-0000-4000-8000-00000000000a"
U_C8B="aaaaaaa8-0000-4000-8000-00000000000b"
U_E1="aaaaaaa9-0000-4000-8000-000000000001"
U_E2="aaaaaaa9-0000-4000-8000-000000000002"
U_E3="aaaaaaa9-0000-4000-8000-000000000003"
U_OPEN="aaaaaaa9-0000-4000-8000-000000000004"

line_user()  { printf '{"type":"user","sessionId":"%s","timestamp":"%s","content":"%s"}\n' "$1" "$2" "$3"; }
line_asst()  { printf '{"type":"assistant","sessionId":"%s","timestamp":"%s","content":"%s"}\n' "$1" "$2" "$3"; }
line_title() { printf '{"type":"custom-title","sessionId":"%s","customTitle":"%s"}\n' "$1" "$2"; }
# Shared opening of a session that exists as two copies: the common byte prefix both sides carry.
common_lines() { line_user "$1" "$TS0" "hello there"; line_asst "$1" "$TS1" "hi back"; }
# Deterministic bulk content to push a transcript over the size threshold (~260 bytes/line).
pad_lines() {
    local sid=$1 n=$2 i
    for ((i = 0; i < n; i++)); do line_asst "$sid" "$TS_PAD" "pad $i $PAD"; done
}

# Populates a sandbox ~/.claude with every scenario. $2 is the PID written to the open-session
# registry entry - it must belong to a live process as seen by the engine under test (the bash
# variant probes with kill -0, the PowerShell variant with Get-Process).
build_fixtures() {
    local hb="$1/.claude" open_pid=$2
    local P="$hb/projects"
    mkdir -p "$hb/sessions" \
        "$P/proj-p0" "$P/proj-p1-old" "$P/proj-p1-new" "$P/proj-p3-old" "$P/proj-p3-new" \
        "$P/proj-p4-old" "$P/proj-p4-new" "$P/proj-p5-old" "$P/proj-p5-new" \
        "$P/proj-p6" "$P/proj-p7" "$P/proj-p8" "$P/proj-p2"

    # Phase 0: marker matches trimmed and case-insensitively; a title merely containing it stays.
    { common_lines "$U_DEL"; line_title "$U_DEL" " delete "; } > "$P/proj-p0/$U_DEL.jsonl"
    { common_lines "$U_DELBUG"; line_title "$U_DELBUG" "DELETE-Bug"; } > "$P/proj-p0/$U_DELBUG.jsonl"

    # Phase 1 contained: the old copy is a strict byte prefix of the (larger, titled) new copy.
    common_lines "$U_DUP" > "$P/proj-p1-old/$U_DUP.jsonl"
    { common_lines "$U_DUP"; line_title "$U_DUP" "DupKeeper"; line_user "$U_DUP" "$TS1" "carried on"; } \
        > "$P/proj-p1-new/$U_DUP.jsonl"

    # Phase 1 handover: the old copy's own tail (1 message, 11:00) predates the new copy's own
    # branch (from 12:00) - a leftover of the move, trashed automatically.
    { common_lines "$U_HO"; line_user "$U_HO" "2026-01-01T11:00:00.000Z" "old tail before the move"; } \
        > "$P/proj-p3-old/$U_HO.jsonl"
    { common_lines "$U_HO"; line_title "$U_HO" "HandoverKeeper"
      line_user "$U_HO" "2026-01-01T12:00:00.000Z" "continuing in the new project"
      line_asst "$U_HO" "2026-01-01T12:01:00.000Z" "resuming work $PAD"
    } > "$P/proj-p3-new/$U_HO.jsonl"

    # Phase 1 parallel work: both sides carry own messages with interleaved times (old's last 15:00
    # is after new's first 14:00) - reported, both kept. Same title, so the renamed-apart rule
    # must not swallow the finding.
    { common_lines "$U_PAR"; line_title "$U_PAR" "ParallelWork"
      line_user "$U_PAR" "2026-01-01T13:00:00.000Z" "old branch work"
      line_user "$U_PAR" "2026-01-01T15:00:00.000Z" "old branch continues late"
    } > "$P/proj-p4-old/$U_PAR.jsonl"
    { common_lines "$U_PAR"; line_title "$U_PAR" "ParallelWork"
      line_user "$U_PAR" "2026-01-01T14:00:00.000Z" "new branch work"
      line_asst "$U_PAR" "2026-01-01T14:10:00.000Z" "new branch answer $PAD"
    } > "$P/proj-p4-new/$U_PAR.jsonl"

    # Phase 1 renamed apart: both copies diverged AND renamed to different titles - consciously two
    # sessions now, nothing to report, nothing to trash.
    { common_lines "$U_RA"; line_title "$U_RA" "OldBranch"
      line_user "$U_RA" "2026-01-01T13:00:00.000Z" "old direction"
      line_user "$U_RA" "2026-01-01T15:00:00.000Z" "old direction continues"
    } > "$P/proj-p5-old/$U_RA.jsonl"
    { common_lines "$U_RA"; line_title "$U_RA" "NewBranch"
      line_user "$U_RA" "2026-01-01T14:00:00.000Z" "new direction"
      line_asst "$U_RA" "2026-01-01T14:10:00.000Z" "new direction answer $PAD"
    } > "$P/proj-p5-new/$U_RA.jsonl"

    # Phase 1b prefix merge: with the sessionId neutralized, the small titled file is an exact
    # prefix of the big titled one (fork/bridge continuation) - the small one goes.
    { line_title "$U_B6" "Bridge"; common_lines "$U_B6"
      line_user "$U_B6" "2026-01-01T12:00:00.000Z" "bridge continues"
    } > "$P/proj-p6/$U_B6.jsonl"
    head -n 3 "$P/proj-p6/$U_B6.jsonl" | sed "s/$U_B6/$U_S6/g" > "$P/proj-p6/$U_S6.jsonl"

    # Phase 1b small namesake: same title, genuinely different content, one side below the empty
    # threshold - the small one goes, the name lives on in the big one.
    { line_title "$U_B7" "AgenticOS"; pad_lines "$U_B7" 1500; } > "$P/proj-p7/$U_B7.jsonl"
    { line_title "$U_S7" "AgenticOS"; line_user "$U_S7" "$TS0" "completely different start"; } \
        > "$P/proj-p7/$U_S7.jsonl"

    # Phase 1b collision: same title, different histories, both above the threshold - reported only.
    { line_title "$U_C8A" "Refactor"; line_user "$U_C8A" "$TS0" "branch one"; pad_lines "$U_C8A" 1500; } \
        > "$P/proj-p8/$U_C8A.jsonl"
    { line_title "$U_C8B" "Refactor"; line_user "$U_C8B" "$TS0" "branch two"; pad_lines "$U_C8B" 1500; } \
        > "$P/proj-p8/$U_C8B.jsonl"

    # Phase 2: small unnamed (goes, sidecar rides along), big unnamed (stays), small titled (stays),
    # small unnamed but open (stays via the session registry).
    common_lines "$U_E1" > "$P/proj-p2/$U_E1.jsonl"
    mkdir -p "$P/proj-p2/$U_E1"
    line_asst "$U_E1" "$TS_PAD" "subagent transcript" > "$P/proj-p2/$U_E1/subagent.jsonl"
    touch -d '2026-01-01 10:00:00' "$P/proj-p2/$U_E1/subagent.jsonl"
    pad_lines "$U_E2" 1500 > "$P/proj-p2/$U_E2.jsonl"
    { common_lines "$U_E3"; line_title "$U_E3" "KeepMe"; } > "$P/proj-p2/$U_E3.jsonl"
    common_lines "$U_OPEN" > "$P/proj-p2/$U_OPEN.jsonl"
    printf '{"pid":%s,"sessionId":"%s"}\n' "$open_pid" "$U_OPEN" > "$hb/sessions/$open_pid.json"

    # Phase 3: a trash batch far past retention plus a recent one that must survive.
    mkdir -p "$1/.claude/projects-trash/2020-01-01/proj-old"
    printf 'old trash\n' > "$1/.claude/projects-trash/2020-01-01/proj-old/gone.jsonl"
    mkdir -p "$1/.claude/projects-trash/$TODAY-recent" 2>/dev/null || true
}

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); [ "${VERBOSE:-0}" = 1 ] && echo "  ok   $1"; return 0; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
assert_trashed() { # sandbox project sid description
    if [ -f "$1/.claude/projects-trash/$TODAY/$2/$3.jsonl" ] && [ ! -e "$1/.claude/projects/$2/$3.jsonl" ]; then
        pass "$4"
    else
        fail "$4"
    fi
}
assert_kept() { # sandbox project sid description
    if [ -f "$1/.claude/projects/$2/$3.jsonl" ]; then pass "$4"; else fail "$4"; fi
}
assert_contains() { # haystack needle description
    case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing: $2)" ;; esac
}
assert_not_contains() { # haystack needle description
    case "$1" in *"$2"*) fail "$3 (unexpected: $2)" ;; *) pass "$3" ;; esac
}

run_suite() { # engine: sh | ps
    local engine=$1 sandbox open_pid out out2
    sandbox=$(mktemp -d)
    # The registry entry must name a process the engine sees as alive: this test shell for bash
    # (kill -0), the always-present System process (PID 4) for PowerShell (Get-Process).
    if [ "$engine" = sh ]; then open_pid=$$; else open_pid=4; fi
    build_fixtures "$sandbox" "$open_pid"

    if [ "$engine" = sh ]; then
        out=$(HOME="$sandbox" bash "$CLEANUP_SH" --no-notify 2>&1)
        out2=$(HOME="$sandbox" bash "$CLEANUP_SH" --no-notify 2>&1)
    else
        local win_profile win_script
        win_profile=$(cygpath -w "$sandbox")
        win_script=$(cygpath -w "$CLEANUP_PS1")
        out=$(USERPROFILE="$win_profile" "$PS_EXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win_script" -NoNotify 2>&1)
        out2=$(USERPROFILE="$win_profile" "$PS_EXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win_script" -NoNotify 2>&1)
    fi

    echo "== $engine =="
    assert_trashed "$sandbox" proj-p0 "$U_DEL" "phase 0: DELETE-marked session trashed"
    assert_kept "$sandbox" proj-p0 "$U_DELBUG" "phase 0: title merely containing the marker stays"
    assert_trashed "$sandbox" proj-p1-old "$U_DUP" "phase 1: contained old copy trashed"
    assert_kept "$sandbox" proj-p1-new "$U_DUP" "phase 1: containing new copy stays"
    assert_contains "$out" "contained in proj-p1-new" "phase 1: contained log names the container"
    assert_trashed "$sandbox" proj-p3-old "$U_HO" "phase 1: handover leftover trashed"
    assert_kept "$sandbox" proj-p3-new "$U_HO" "phase 1: handover keeper stays"
    assert_contains "$out" 'leftover of "HandoverKeeper" after the move to' "phase 1: leftover log explains the move"
    assert_kept "$sandbox" proj-p4-old "$U_PAR" "phase 1: parallel-work old copy stays"
    assert_kept "$sandbox" proj-p4-new "$U_PAR" "phase 1: parallel-work new copy stays"
    assert_contains "$out" 'diverged copies of "ParallelWork"' "phase 1: parallel work reported"
    assert_kept "$sandbox" proj-p5-old "$U_RA" "phase 1: renamed-apart old copy stays"
    assert_kept "$sandbox" proj-p5-new "$U_RA" "phase 1: renamed-apart new copy stays"
    assert_not_contains "$out" "${U_RA:0:8}" "phase 1: renamed-apart pair reported nowhere"
    assert_trashed "$sandbox" proj-p6 "$U_S6" "phase 1b: titled prefix copy trashed"
    assert_kept "$sandbox" proj-p6 "$U_B6" "phase 1b: prefix keeper stays"
    assert_contains "$out" "content prefix of" "phase 1b: prefix log present"
    assert_trashed "$sandbox" proj-p7 "$U_S7" "phase 1b: small namesake trashed"
    assert_kept "$sandbox" proj-p7 "$U_B7" "phase 1b: big namesake keeps the name"
    assert_contains "$out" "small namesake of" "phase 1b: namesake log present"
    assert_kept "$sandbox" proj-p8 "$U_C8A" "phase 1b: collision copy A stays"
    assert_kept "$sandbox" proj-p8 "$U_C8B" "phase 1b: collision copy B stays"
    assert_contains "$out" 'same title "Refactor"' "phase 1b: collision reported"
    assert_trashed "$sandbox" proj-p2 "$U_E1" "phase 2: small unnamed session trashed"
    if [ -d "$sandbox/.claude/projects-trash/$TODAY/proj-p2/$U_E1" ]; then
        pass "phase 2: sidecar moved along"
    else
        fail "phase 2: sidecar moved along"
    fi
    assert_kept "$sandbox" proj-p2 "$U_E2" "phase 2: big unnamed session stays"
    assert_kept "$sandbox" proj-p2 "$U_E3" "phase 2: small titled session stays"
    assert_kept "$sandbox" proj-p2 "$U_OPEN" "phase 2: open session protected via registry"
    if [ ! -d "$sandbox/.claude/projects-trash/2020-01-01" ]; then
        pass "phase 3: expired trash batch purged"
    else
        fail "phase 3: expired trash batch purged"
    fi
    local findings="$sandbox/.claude/projects-trash/findings.txt"
    if [ -f "$findings" ]; then
        local ftxt; ftxt=$(cat "$findings")
        assert_contains "$ftxt" "ParallelWork" "findings.txt lists the diverged pair"
        assert_contains "$ftxt" "Refactor" "findings.txt lists the title collision"
    else
        fail "findings.txt written"
    fi
    assert_contains "$out" "done: 1 marked, 4 duplicate(s) and 1 empty session(s) trashed, 1 batch(es) purged" \
        "run 1 totals"
    assert_contains "$out2" "done: 0 marked, 0 duplicate(s) and 0 empty session(s) trashed, 0 batch(es) purged" \
        "run 2 is idempotent"

    if [ "${KEEP_SANDBOX:-0}" = 1 ]; then
        echo "  sandbox kept at $sandbox"
    else
        rm -rf "$sandbox"
    fi
}

run_suite sh

PS_EXE=""
if command -v pwsh >/dev/null 2>&1; then PS_EXE=pwsh
elif command -v powershell >/dev/null 2>&1; then PS_EXE=powershell; fi
if [ -n "$PS_EXE" ] && command -v cygpath >/dev/null 2>&1; then
    run_suite ps
else
    echo "== ps == skipped (no pwsh/powershell + cygpath)"
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
