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
# (forced_login_method removed), chatgpt without model (key dropped),
# deployment catalog (Azure listing via CODEX_CATALOG_FIXTURE, offline
# fallback, shrink, model_catalog_json set/removed).
#
# Usage: tests/codex-profil-parity.sh
# Requirements: bash; pwsh or powershell for the ps1 side — without it the
# ps1 half is skipped with a warning and only bash idempotence is asserted.
#
# Idempotent: sandboxes live in mktemp dirs and are removed on exit; the
# repo and the real ~/.codex are never touched.
# =============================================================================

APP_VERSION='0.4.18'

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
CODEX_MODEL_DEPLOYMENTS=gpt-5-luna, gpt-6-sol
EOF
cat > "$PROFILES/catalogshrunk.env" <<'EOF'
CODEX_PROVIDER_ID=cat-res
CODEX_BASE_URL=https://cat-res.cognitiveservices.azure.com/openai
CODEX_MODEL_DEPLOYMENTS=gpt-6.1-sol
EOF
cat > "$PROFILES/catalogdefault.env" <<'EOF'
CODEX_PROVIDER_ID=cat-res
CODEX_BASE_URL=https://cat-res.cognitiveservices.azure.com/openai
CODEX_MODEL_DEPLOYMENT=gpt-6.1-sol
CODEX_MODEL_DEPLOYMENTS=gpt-6.1-sol
EOF

# Codex's OpenAI model cache (metadata templates) in both sandbox homes, and
# Azure deployment listings served via CODEX_CATALOG_FIXTURE instead of HTTP.
for h in "$HOME_SH" "$HOME_PS"; do
    cat > "$h/models_cache.json" <<'EOF'
{"models": [
 {"slug": "gpt-6-sol", "display_name": "GPT-6-Sol", "supported_reasoning_levels": [{"effort": "medium"}], "priority": 3},
 {"slug": "gpt-5-sol", "display_name": "GPT-5-Sol", "supported_reasoning_levels": [{"effort": "low"}], "priority": 7},
 {"slug": "gpt-5-luna", "display_name": "GPT-5-Luna", "supported_reasoning_levels": [{"effort": "low"}], "priority": 9}
]}
EOF
done
cat > "$SANDBOX/deployments-full.json" <<'EOF'
{"data": [
 {"id": "gpt-6-sol", "model": "gpt-6-sol", "status": "succeeded"},
 {"id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "status": "succeeded"},
 {"id": "gpt-5-luna", "model": "gpt-5-luna", "status": "succeeded"},
 {"id": "embed", "model": "text-embedding-3-large", "status": "succeeded"},
 {"id": "gpt-7-sol", "model": "gpt-7-sol", "status": "creating"}
]}
EOF
cat > "$SANDBOX/deployments-small.json" <<'EOF'
{"data": [{"id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "status": "succeeded"}]}
EOF
FIXTURE="$SANDBOX/deployments-full.json"

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
    local fix="$FIXTURE"
    command -v cygpath >/dev/null 2>&1 && fix=$(cygpath -w "$fix")
    ( export PROFILES_DIR="$PROFILES" CODEX_HOME="$HOME_SH" CODEX_CATALOG_FIXTURE="$fix"
      # shellcheck disable=SC1091
      source "$ADAPTERS/codex-profil.sh" use "$1" ) >/dev/null 2>&1
}

run_ps() {  # <profile> — ps1 port against HOME_PS
    [ -n "$PWSH" ] || return 0
    local ppath="$ADAPTERS/codex-profil.ps1" phome="$HOME_PS" pprof="$PROFILES" pfix="$FIXTURE"
    if command -v cygpath >/dev/null 2>&1; then
        ppath=$(cygpath -w "$ppath"); phome=$(cygpath -w "$phome"); pprof=$(cygpath -w "$pprof"); pfix=$(cygpath -w "$pfix")
    fi
    "$PWSH" -NoProfile -NonInteractive -Command \
        "\$env:PROFILES_DIR='$pprof'; \$env:CODEX_HOME='$phome'; \$env:CODEX_CATALOG_FIXTURE='$pfix'; . '$ppath' use $1" >/dev/null 2>&1
}

# state <home> — config.toml plus every profile file and model catalog, each
# with its name, CRLF-normalized: the complete footprint of the adapter.
state() {
    local f
    for f in "$1/config.toml" "$1"/*.config.toml "$1"/model-catalogs/*.json; do
        [ -f "$f" ] || continue
        printf '== %s\n' "${f#"$1"/}"
        tr -d '\r' < "$f"
    done
}

# step <label> <profile> — run both ports, assert state parity + idempotence.
step() {
    local label="$1" profile="$2" after_sh again_sh

    run_sh "$profile"
    after_sh=$(state "$HOME_SH")
    run_sh "$profile"
    again_sh=$(state "$HOME_SH")
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
        sh_norm=$(state "$HOME_SH")
        ps_norm=$(state "$HOME_PS")
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
# A legacy [profiles."cat-res-*"] table must be migrated away; a hand-made
# profile file without the managed marker must survive pruning.
for h in "$HOME_SH" "$HOME_PS"; do
    printf '\n[profiles."cat-res-old"]\nmodel = "gpt-old"\nmodel_provider = "cat-res"\n' >> "$h/config.toml"
    printf 'model = "mine"\n' > "$h/cat-res-mine.config.toml"
done
step "catalog/over-chatgpt" catalog
if grep -q '^model = "gpt-parity-sub"' "$HOME_SH/config.toml" \
   && grep -q '^model_provider = "openai"' "$HOME_SH/config.toml"; then
    ok "catalog: top-level model/provider untouched"
else
    bad "catalog: top-level model/provider changed"
fi
if grep -q '^model = "gpt-6.1-sol"' "$HOME_SH/cat-res-gpt-6_1-sol.config.toml" 2>/dev/null \
   && grep -q '^model_catalog_json = "model-catalogs/cat-res.json"' "$HOME_SH/cat-res-gpt-6_1-sol.config.toml" \
   && grep -q '^env_key = "AZURE_CAT_RES_API_KEY"' "$HOME_SH/config.toml" \
   && grep -q '^\[model_providers\.cat-res\.query_params\]' "$HOME_SH/config.toml"; then
    ok "catalog: profile file (dot-free name), env_key and api-version written"
else
    bad "catalog: profile file/env_key/api-version missing"
fi
if ! grep -q '^\[profiles\."cat-res-' "$HOME_SH/config.toml" \
   && [ -f "$HOME_SH/cat-res-mine.config.toml" ]; then
    ok "catalog: legacy profile table migrated, unmanaged profile file kept"
else
    bad "catalog: legacy table left or unmanaged file removed"
fi
# Live list wins over CODEX_MODEL_DEPLOYMENTS: 3 GPT deployments; the
# embedding (no template) and the still-creating one are skipped.
managed_count() { grep -l '^# managed by codex-profil: provider=cat-res$' "$HOME_SH"/cat-res-*.config.toml 2>/dev/null | wc -l; }
if [ "$(managed_count)" -eq 3 ] \
   && [ ! -f "$HOME_SH/cat-res-embed.config.toml" ] && [ ! -f "$HOME_SH/cat-res-gpt-7-sol.config.toml" ]; then
    ok "catalog: three profile files from the Azure listing"
else
    bad "catalog: expected three profile files from the Azure listing"
fi
if ! grep -q '^model_catalog_json' "$HOME_SH/config.toml"; then
    ok "catalog: catalog-only profile leaves model_catalog_json unset"
else
    bad "catalog: catalog-only profile set model_catalog_json"
fi
cat_sh="$HOME_SH/model-catalogs/cat-res.json"
if python -c "import json,sys;m={x['slug']:x for x in json.load(open(sys.argv[1]))['models']};assert sorted(m)==['gpt-5-luna','gpt-6-sol','gpt-6.1-sol'];assert m['gpt-6.1-sol']['priority']==3" "$cat_sh" 2>/dev/null; then
    ok "catalog: catalog file lists the deployments, gpt-6.1-sol templated from gpt-6-sol"
else
    bad "catalog: catalog file wrong or missing"
fi

echo "codex-parity: catalog profile as default sets model_catalog_json, chatgpt removes it"
step "catalog-default" catalogdefault
if grep -q '^model_catalog_json = "model-catalogs/cat-res.json"' "$HOME_SH/config.toml" \
   && grep -q '^model_provider = "cat-res"' "$HOME_SH/config.toml"; then
    ok "catalog-default: model_catalog_json + provider set"
else
    bad "catalog-default: model_catalog_json/provider missing"
fi
step "chatgpt-pinned/after-catalog-default" maxpinned
if grep -q '^model_catalog_json' "$HOME_SH/config.toml"; then
    bad "chatgpt/after-catalog: model_catalog_json still present"
else
    ok "chatgpt/after-catalog: model_catalog_json removed"
fi

echo "codex-parity: Azure unreachable falls back to CODEX_MODEL_DEPLOYMENTS"
FIXTURE="$SANDBOX/does-not-exist.json"
step "catalog/offline" catalog
if [ "$(managed_count)" -eq 2 ]; then
    ok "catalog/offline: two profiles from the fallback list"
else
    bad "catalog/offline: expected two profiles from the fallback list"
fi

echo "codex-parity: shrunk Azure listing drops stale profiles and api-version"
FIXTURE="$SANDBOX/deployments-small.json"
step "catalog/shrunk" catalogshrunk
if [ "$(managed_count)" -eq 1 ] && [ -f "$HOME_SH/cat-res-mine.config.toml" ] \
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
