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

APP_VERSION='0.3.5'

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
cat > "$PROFILES/catalog.env" <<'EOF'
CODEX_PROVIDER_ID=cat-res
CODEX_BASE_URL=https://cat-res.cognitiveservices.azure.com/openai
CODEX_API_VERSION=2025-04-01-preview
CODEX_API_KEY=sk-catalog
CODEX_MODEL_DEPLOYMENTS=gpt-a, gpt-b.1,gpt-c
EOF
cat > "$PROFILES/catalogshrunk.env" <<'EOF'
CODEX_PROVIDER_ID=cat-res
CODEX_BASE_URL=https://cat-res.cognitiveservices.azure.com/openai
CODEX_MODEL_DEPLOYMENTS=gpt-b.1
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

echo "codex-parity: deployment catalog over chatgpt (top level untouched)"
step "chatgpt-pinned/before-catalog" maxpinned
step "catalog/over-chatgpt" catalog
if grep -q '^model = "gpt-parity-sub"' "$HOME_SH/config.toml" \
   && grep -q '^model_provider = "openai"' "$HOME_SH/config.toml"; then
    ok "catalog: top-level model/provider untouched"
else
    bad "catalog: top-level model/provider changed"
fi
if grep -q '^\[profiles\."cat-res-gpt-b\.1"\]' "$HOME_SH/config.toml" \
   && grep -q '^env_key = "AZURE_CAT_RES_API_KEY"' "$HOME_SH/config.toml" \
   && grep -q '^\[model_providers\.cat-res\.query_params\]' "$HOME_SH/config.toml"; then
    ok "catalog: profiles, env_key and api-version written"
else
    bad "catalog: profiles/env_key/api-version missing"
fi
if [ "$(grep -c '^\[profiles\."cat-res-' "$HOME_SH/config.toml")" -eq 3 ]; then
    ok "catalog: three profiles"
else
    bad "catalog: expected three profiles"
fi

echo "codex-parity: shrunk catalog drops stale profiles and api-version"
step "catalog/shrunk" catalogshrunk
if [ "$(grep -c '^\[profiles\."cat-res-' "$HOME_SH/config.toml")" -eq 1 ] \
   && ! grep -q 'query_params' "$HOME_SH/config.toml" \
   && grep -q 'mcp_servers.docs' "$HOME_SH/config.toml" \
   && grep -q 'profiles.fast' "$HOME_SH/config.toml"; then
    ok "catalog/shrunk: stale profiles + api-version gone, foreign kept"
else
    bad "catalog/shrunk: stale state left or foreign content lost"
fi
if python -c "import sys,tomllib;tomllib.load(open(sys.argv[1],'rb'))" "$HOME_SH/config.toml" 2>/dev/null; then
    ok "catalog/shrunk: config is valid TOML"
elif command -v python >/dev/null 2>&1; then
    bad "catalog/shrunk: config is NOT valid TOML"
fi

# --- summary ------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "codex-parity: $PASS check(s) passed — ports in sync"
else
    echo "codex-parity: $FAIL failure(s), $PASS pass(es)" >&2
    exit 1
fi
