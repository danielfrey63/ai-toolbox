#!/usr/bin/env bash
# =============================================================================
# tests/parity.sh — cross-port parity harness for toolbox.sh / toolbox.ps1
#
# The two CLI ports are maintained by hand in parallel; this harness catches
# drift between them without depending on the real catalog. It builds
# throw-away sandboxes (copies of both scripts + a fixture catalog + fixture
# artifacts), runs the same read-only commands through both ports, and
# asserts that exit codes, per-tool status lines and failure counts agree.
#
# Covered commands: validate (clean fixture), validate (broken fixture), list,
# status --all (registry healing of legacy repo-row duplicates + "null" paths).
#
# Usage:
#   tests/parity.sh          # run the parity assertions
#   tests/parity.sh --lint   # additionally run shellcheck / PSScriptAnalyzer
#                            # (informational only — never fails the run)
#
# Requirements: bash + jq (for toolbox.sh); pwsh or powershell for the ps1
# side — if neither is on PATH the ps1 half is skipped with a warning and
# only the bash port is exercised.
#
# Idempotent: sandboxes live in mktemp dirs and are removed on exit; the
# repo itself is never touched.
# =============================================================================

APP_VERSION='0.3.7'

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
CLEANUP=""
trap 'for d in $CLEANUP; do rm -rf "$d"; done' EXIT

ok()  { PASS=$((PASS + 1)); printf '  [ok] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [!!] %s\n' "$1" >&2; }

# --- runners -----------------------------------------------------------------

command -v jq >/dev/null 2>&1 || { echo "parity: jq not found — cannot run toolbox.sh" >&2; exit 1; }

PWSH=""
for c in pwsh powershell; do
    if command -v "$c" >/dev/null 2>&1; then PWSH=$c; break; fi
done
[ -n "$PWSH" ] || echo "parity: no pwsh/powershell on PATH — ps1 side SKIPPED" >&2

run_sh() {  # sandbox cmd... -> stdout+stderr, $? preserved
    local d=$1; shift
    bash "$d/toolbox.sh" "$@" 2>&1
}

run_ps() {  # sandbox cmd... -> stdout+stderr, $? preserved
    local d=$1; shift
    local p="$d/toolbox.ps1"
    command -v cygpath >/dev/null 2>&1 && p=$(cygpath -w "$p")
    "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$p" "$@" 2>&1
}

# Normalize a captured output for comparison: unify em-dash vs hyphen (the
# ps1 console renders — as -), squeeze runs of whitespace, drop trailing
# blanks. Absolute paths still differ (/d/… vs D:\…), so comparisons below
# only ever look at status tags, tool names and counts — never full lines.
norm() { sed -e 's/\xe2\x80\x94/-/g' -e 's/[[:space:]]\{1,\}/ /g' -e 's/ $//'; }

# Extract "<tag> <name>" pairs from validate output ([ok]/[!]/[i] lines).
status_pairs() { norm | grep -oE '^\s*\[(ok|!|i)\] [A-Za-z0-9_-]+' | sed 's/^ *//' | sort; }

# Extract the catalog table's tool names from list output (lines with the
# two-space indent + name + type word).
list_names() { norm | awk '$2 ~ /^(skill|hook|plugin|config|bin)$/ {print $1}' | sort; }

# --- fixtures ----------------------------------------------------------------

make_sandbox() {  # variant(good|bad) -> sandbox dir on stdout
    local variant=$1 d
    d=$(mktemp -d) || exit 1
    cp "$ROOT/toolbox.sh" "$ROOT/toolbox.ps1" "$d/"
    mkdir -p "$d/tools" "$d/skills/alpha" "$d/hookdir"
    printf -- '---\nname: alpha\ndescription: fixture skill\n---\n# alpha\n' > "$d/skills/alpha/SKILL.md"
    printf '# fixture config\n' > "$d/CONF.md"
    printf '#!/bin/sh\necho hi\n' > "$d/tool.sh"
    printf 'Write-Output hi\n' > "$d/tool.ps1"
    chmod +x "$d/toolbox.sh" "$d/tool.sh" 2>/dev/null
    for h in pre-commit post-commit; do
        printf '#!/bin/sh\nexit 0\n' > "$d/hookdir/$h"
    done
    if [ "$variant" = good ]; then
        cat > "$d/tools/catalog.json" <<'EOF'
{ "tools": [
  { "name": "alpha", "type": "skill",  "path": "skills/alpha", "description": "fixture skill" },
  { "name": "conf",  "type": "config", "path": "CONF.md",      "description": "fixture config" },
  { "name": "tool",  "type": "bin",    "path": "tool.sh", "command": "tool", "description": "fixture bin" },
  { "name": "hooks", "type": "hook",   "path": "hookdir",      "description": "fixture hooks" }
] }
EOF
    else
        # beta: SKILL.md without frontmatter -> fail; gamma: name mismatch -> warn
        mkdir -p "$d/skills/beta" "$d/skills/gamma"
        printf '# no frontmatter here\n' > "$d/skills/beta/SKILL.md"
        printf -- '---\nname: delta\ndescription: mismatched\n---\n' > "$d/skills/gamma/SKILL.md"
        cat > "$d/tools/catalog.json" <<'EOF'
{ "tools": [
  { "name": "alpha",         "type": "skill", "path": "skills/alpha",   "description": "fixture skill" },
  { "name": "missing-skill", "type": "skill", "path": "skills/missing", "description": "path gone" },
  { "name": "beta",          "type": "skill", "path": "skills/beta",    "description": "bad frontmatter" },
  { "name": "gamma",         "type": "skill", "path": "skills/gamma",   "description": "name mismatch" },
  { "name": "tool-nocmd",    "type": "bin",   "path": "tool.sh",        "description": "command missing" }
] }
EOF
    fi
    printf '%s' "$d"
}

# --- assertions ----------------------------------------------------------------

check_case() {  # label sandbox expected_exit cmd...
    local label=$1 d=$2 want=$3; shift 3

    local out_sh rc_sh
    out_sh=$(run_sh "$d" "$@"); rc_sh=$?
    [ "$rc_sh" -eq "$want" ] \
        && ok "$label: sh exit $rc_sh" \
        || bad "$label: sh exit $rc_sh (want $want)"

    [ -n "$PWSH" ] || return 0
    local out_ps rc_ps
    out_ps=$(run_ps "$d" "$@"); rc_ps=$?
    [ "$rc_ps" -eq "$want" ] \
        && ok "$label: ps1 exit $rc_ps" \
        || bad "$label: ps1 exit $rc_ps (want $want)"

    local pairs_sh pairs_ps
    if [ "$1" = validate ]; then
        pairs_sh=$(printf '%s\n' "$out_sh" | status_pairs)
        pairs_ps=$(printf '%s\n' "$out_ps" | status_pairs)
    else
        pairs_sh=$(printf '%s\n' "$out_sh" | list_names)
        pairs_ps=$(printf '%s\n' "$out_ps" | list_names)
    fi
    if [ "$pairs_sh" = "$pairs_ps" ] && [ -n "$pairs_sh" ]; then
        ok "$label: per-tool output identical across ports"
    else
        bad "$label: per-tool output differs across ports"
        diff <(printf '%s\n' "$pairs_sh") <(printf '%s\n' "$pairs_ps") | sed 's/^/       /' >&2
    fi

    if [ "$1" = validate ]; then
        local fails_sh fails_ps
        fails_sh=$(printf '%s\n' "$out_sh" | grep -cE '^\s*\[!\]')
        fails_ps=$(printf '%s\n' "$out_ps" | grep -cE '^\s*\[!\]')
        [ "$fails_sh" = "$fails_ps" ] \
            && ok "$label: failure count identical ($fails_sh)" \
            || bad "$label: failure count differs (sh=$fails_sh ps1=$fails_ps)"
    fi
}

# --- registry healing ------------------------------------------------------------
# The sweep must collapse legacy registry pathologies the same way in both
# ports: a bare (target="") repo row is subsumed by the targeted row of the
# same tool, and literal "null" paths (recorded by pre-fix installs for
# path-less repo/mcp catalog entries) collapse to "". Each port gets its own
# XDG base dir holding a seeded registry and a fake checkout under the XDG
# data dir (where _repo_dest resolves when no sibling checkout exists), so the
# swept rows verify as installed instead of being pruned.

make_reg_sandbox() {  # -> sandbox dir on stdout
    local d
    d=$(mktemp -d) || exit 1
    cp "$ROOT/toolbox.sh" "$ROOT/toolbox.ps1" "$d/"
    chmod +x "$d/toolbox.sh" 2>/dev/null
    mkdir -p "$d/tools"
    cat > "$d/tools/catalog.json" <<'EOF'
{ "tools": [
  { "name": "fixrepo", "type": "repo", "url": "https://example.invalid/fixrepo.git", "description": "fixture repo" }
] }
EOF
    printf '%s' "$d"
}

seed_reg_xdg() {  # sandbox port -> XDG base dir on stdout
    local base="$1/xdg-$2"
    mkdir -p "$base/config/ai-toolbox" "$base/data/ai-toolbox/repos/fixrepo/.git"
    cat > "$base/config/ai-toolbox/installs.json" <<'EOF'
[
  {"tool":"fixrepo","type":"repo","path":"../fixrepo","scope":"global","target":"","project":""},
  {"tool":"fixrepo","type":"repo","path":"null","scope":"global","target":"claude","project":""}
]
EOF
    printf '%s' "$base"
}

# Canonicalize a swept registry for comparison: tolerate a bare object (PS
# single-element output), fix key order, keep only the fixture's rows.
reg_canon() {
    jq -Sc 'if type == "array" then . else [.] end
            | map(select(.tool == "fixrepo"))
            | map({tool, type, path, scope, target, project})' \
        "$1/config/ai-toolbox/installs.json" 2>/dev/null
}

check_registry_heal() {
    local d base rc got_sh got_ps want
    d=$(make_reg_sandbox); CLEANUP="$CLEANUP $d"
    want='[{"path":"","project":"","scope":"global","target":"claude","tool":"fixrepo","type":"repo"}]'

    base=$(seed_reg_xdg "$d" sh)
    (export XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data"
     run_sh "$d" status --all >/dev/null); rc=$?
    got_sh=$(reg_canon "$base")
    if [ "$rc" -eq 0 ] && [ "$got_sh" = "$want" ]; then
        ok "registry-heal: sh collapses bare repo row + null path"
    else
        bad "registry-heal: sh exit $rc, registry after sweep: ${got_sh:-<unreadable>} (want $want)"
    fi

    [ -n "$PWSH" ] || return 0
    base=$(seed_reg_xdg "$d" ps)
    (export XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data"
     run_ps "$d" status --all >/dev/null); rc=$?
    got_ps=$(reg_canon "$base")
    if [ "$rc" -eq 0 ] && [ "$got_ps" = "$want" ]; then
        ok "registry-heal: ps1 collapses bare repo row + null path"
    else
        bad "registry-heal: ps1 exit $rc, registry after sweep: ${got_ps:-<unreadable>} (want $want)"
    fi
    [ "$got_sh" = "$got_ps" ] \
        && ok "registry-heal: healed registry identical across ports" \
        || bad "registry-heal: healed registry differs across ports"
}

echo "parity: building fixtures..."
GOOD=$(make_sandbox good); CLEANUP="$CLEANUP $GOOD"
BAD=$(make_sandbox bad);   CLEANUP="$CLEANUP $BAD"

echo "parity: validate on clean fixture (expect exit 0)"
check_case "validate/clean" "$GOOD" 0 validate

echo "parity: validate on broken fixture (expect exit 1)"
check_case "validate/broken" "$BAD" 1 validate

echo "parity: list on clean fixture (expect exit 0)"
check_case "list" "$GOOD" 0 list

echo "parity: registry healing via status --all"
check_registry_heal

# --- optional lint layer (informational, never fails the run) -----------------

if [ "${1:-}" = "--lint" ]; then
    if command -v shellcheck >/dev/null 2>&1; then
        echo "lint: shellcheck toolbox.sh (informational)"
        shellcheck -S warning "$ROOT/toolbox.sh" | head -60 || true
    else
        echo "lint: shellcheck not installed — skipped"
    fi
    if [ -n "$PWSH" ]; then
        echo "lint: PSScriptAnalyzer toolbox.ps1 (informational)"
        "$PWSH" -NoProfile -Command "if (Get-Module -ListAvailable PSScriptAnalyzer) { Invoke-ScriptAnalyzer -Path '$ROOT/toolbox.ps1' -Severity Warning | Select-Object -First 40 | Format-Table -AutoSize } else { 'PSScriptAnalyzer not installed - skipped' }" || true
    fi
fi

# --- summary -------------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
    echo "parity: $PASS check(s) passed — ports in sync"
    exit 0
else
    echo "parity: $FAIL of $((PASS + FAIL)) check(s) FAILED" >&2
    exit 1
fi
