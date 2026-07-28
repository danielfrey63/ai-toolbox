#!/usr/bin/env bash
# =============================================================================
# tests/codex-profil-parity.sh — cross-port parity harness for
# aiprofil/adapters/codex-profil.{sh,ps1}
#
# The two adapter ports each carry their own TOML editor and mode logic
# (Azure vs. ChatGPT subscription); this harness catches drift between them.
# It drives BOTH ports through the same profile/scenario sequence against
# separate sandbox CODEX_HOMEs and asserts that the resulting config.toml is
# byte-identical after every step, and that re-running a step changes nothing
# (idempotence).
#
# Scenarios: azure fresh, azure idempotent, azure over foreign config,
# chatgpt over azure (pinned model), chatgpt idempotent, back to azure
# (forced_login_method removed), chatgpt without model (key dropped).
#
# Usage: tests/codex-profil-parity.sh
# Requirements: bash; pwsh or powershell for the ps1 side — without it the
# ps1 half is skipped with a warning and only bash idempotence is asserted.
#
# Idempotent: sandboxes live in mktemp dirs and are removed on exit; the
# repo and the real ~/.codex are never touched.
# =============================================================================

APP_VERSION='0.2.2'

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADAPTERS="$ROOT/aiprofil/adapters"
PASS=0
FAIL=0

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  [ok] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [!!] %s\n' "$1" >&2; }

PWSH=""
for c in pwsh powershell; do
    command -v "$c" >/dev/null 2>&1 && { PWSH=$c; break; }
done
[ -n "$PWSH" ] || echo "codex-parity: no pwsh/powershell on PATH — ps1 side SKIPPED" >&2

# --- fixtures -----------------------------------------------------------------
PROFILES="$SANDBOX/profiles"
HOME_SH="$SANDBOX/codexhome-sh"
HOME_PS="$SANDBOX/codexhome-ps"
mkdir -p "$PROFILES" "$HOME_SH" "$HOME_PS"

cat > "$PROFILES/azureprof.env" <<'EOF'
FOUNDRY_RESOURCE=parity-res
FOUNDRY_API_KEY=sk-parity
CODEX_MODEL_DEPLOYMENT=gpt-parity
EOF
cat > "$PROFILES/maxpinned.env" <<'EOF'
CODEX_AUTH=chatgpt
CODEX_MODEL=gpt-parity-sub
EOF
cat > "$PROFILES/maxplain.env" <<'EOF'
CODEX_AUTH=chatgpt
EOF

FOREIGN_CONFIG=$(cat <<'EOF'
# personal codex config
model = "o4-mini"
model_provider = "openai"
approval_policy = "on-request"

[mcp_servers.docs]
command = "npx"

[profiles.fast]
model = "gpt-4.1"
EOF
)

# --- runners ------------------------------------------------------------------
run_sh() {  # <profile> — bash port against HOME_SH
    ( export PROFILES_DIR="$PROFILES" CODEX_HOME="$HOME_SH"
      # shellcheck disable=SC1091
      source "$ADAPTERS/codex-profil.sh" use "$1" ) >/dev/null 2>&1
}

run_ps() {  # <profile> — ps1 port against HOME_PS
    [ -n "$PWSH" ] || return 0
    local ppath="$ADAPTERS/codex-profil.ps1" phome="$HOME_PS" pprof="$PROFILES"
    if command -v cygpath >/dev/null 2>&1; then
        ppath=$(cygpath -w "$ppath"); phome=$(cygpath -w "$phome"); pprof=$(cygpath -w "$pprof")
    fi
    "$PWSH" -NoProfile -NonInteractive -Command \
        "\$env:PROFILES_DIR='$pprof'; \$env:CODEX_HOME='$phome'; . '$ppath' use $1" >/dev/null 2>&1
}

# step <label> <profile> — run both ports, assert config parity + idempotence.
step() {
    local label="$1" profile="$2" before_sh after_sh again_sh
    before_sh=$(cat "$HOME_SH/config.toml" 2>/dev/null || true)

    run_sh "$profile"
    after_sh=$(cat "$HOME_SH/config.toml" 2>/dev/null || true)
    run_sh "$profile"
    again_sh=$(cat "$HOME_SH/config.toml" 2>/dev/null || true)
    if [ "$after_sh" = "$again_sh" ]; then
        ok "$label: sh idempotent"
    else
        bad "$label: sh NOT idempotent"
    fi

    if [ -n "$PWSH" ]; then
        run_ps "$profile"
        run_ps "$profile"
        # Compare normalized to \n so CRLF differences don't mask real drift.
        local sh_norm ps_norm
        sh_norm=$(tr -d '\r' < "$HOME_SH/config.toml" 2>/dev/null || true)
        ps_norm=$(tr -d '\r' < "$HOME_PS/config.toml" 2>/dev/null || true)
        if [ "$sh_norm" = "$ps_norm" ]; then
            ok "$label: config identical across ports"
        else
            bad "$label: config DIFFERS across ports"
            diff <(printf '%s\n' "$sh_norm") <(printf '%s\n' "$ps_norm") | head -12 >&2
        fi
    fi
}

# --- scenarios ----------------------------------------------------------------
echo "codex-parity: azure on fresh config"
step "azure/fresh" azureprof

echo "codex-parity: chatgpt (pinned model) over azure"
step "chatgpt-pinned/over-azure" maxpinned

echo "codex-parity: back to azure (forced_login_method must go)"
step "azure/after-chatgpt" azureprof
if grep -q 'forced_login_method' "$HOME_SH/config.toml"; then
    bad "azure/after-chatgpt: forced_login_method still present"
else
    ok "azure/after-chatgpt: forced_login_method removed"
fi

echo "codex-parity: chatgpt without model (model key dropped)"
step "chatgpt-plain/over-azure" maxplain
if grep -Eq '^[[:space:]]*model[[:space:]]*=' "$HOME_SH/config.toml"; then
    bad "chatgpt-plain: top-level model still present"
else
    ok "chatgpt-plain: top-level model dropped"
fi

echo "codex-parity: azure over foreign config (comments/sections preserved)"
printf '%s\n' "$FOREIGN_CONFIG" > "$HOME_SH/config.toml"
printf '%s\n' "$FOREIGN_CONFIG" > "$HOME_PS/config.toml"
step "azure/foreign" azureprof
if grep -q '# personal codex config' "$HOME_SH/config.toml" \
   && grep -q 'mcp_servers.docs' "$HOME_SH/config.toml" \
   && grep -q 'profiles.fast' "$HOME_SH/config.toml"; then
    ok "azure/foreign: foreign content preserved"
else
    bad "azure/foreign: foreign content lost"
fi

# --- summary ------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "codex-parity: $PASS check(s) passed — ports in sync"
else
    echo "codex-parity: $FAIL failure(s), $PASS pass(es)" >&2
    exit 1
fi
