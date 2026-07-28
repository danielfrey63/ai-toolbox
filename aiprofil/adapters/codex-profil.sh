#!/usr/bin/env bash
# =============================================================================
# codex-profil — point the Codex CLI config (~/.codex/config.toml) at a backend
#                profile. Codex adapter of aiprofil. Reads the SAME profile
#                files as cc-profil/kilo-profil — one profile, three tools.
# =============================================================================
# What it does for a profile that carries CODEX_MODEL_DEPLOYMENT:
#   - desired-state edit of ${CODEX_HOME:-~/.codex}/config.toml:
#       model          = <CODEX_MODEL_DEPLOYMENT>   (top-level; Azure deployment
#                                                    name, not the model name)
#       model_provider = "azure"                    (top-level)
#       [model_providers.azure] with name / base_url / env_key / wire_api,
#       base_url derived from FOUNDRY_RESOURCE
#   - exports AZURE_OPENAI_API_KEY from FOUNDRY_API_KEY — Codex refuses inline
#     keys; env_key must reference an environment variable
#
# Generic profile keys consumed (legacy ANTHROPIC_FOUNDRY_* as fallback):
#   FOUNDRY_RESOURCE, FOUNDRY_API_KEY, CODEX_MODEL_DEPLOYMENT
#
# Should be sourced for `use` so AZURE_OPENAI_API_KEY lands in the caller's
# shell — the sourcing function is wired by `toolbox install --what codex-profil`.
# Executed directly, `use` still writes config.toml but only warns about the
# env var (it cannot reach the parent shell).
#
# Scope (--scope, mirrors aiprofil):
#   session  env var in this shell; config.toml is per-user by nature (default)
#   user     bash: like session + note (PowerShell twin persists User scope)
#   project  no Codex analog -> skipped with a note
# =============================================================================

APP_VERSION='0.2.3'

_codex_profil_main() {
    local script_dir profiles_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Profiles dir: explicit override > new location > legacy cc-profil/profiles.
    if [[ -n "${PROFILES_DIR:-}" ]]; then
        profiles_dir="$PROFILES_DIR"
    elif compgen -G "${script_dir}/../profiles/*.env" >/dev/null 2>&1; then
        profiles_dir="$(cd "${script_dir}/../profiles" && pwd)"
    elif compgen -G "${script_dir}/../../cc-profil/profiles/*.env" >/dev/null 2>&1; then
        profiles_dir="$(cd "${script_dir}/../../cc-profil/profiles" && pwd)"
    else
        profiles_dir="${script_dir}/../profiles"
    fi

    _cx_info() { printf '\033[36m[INFO]\033[0m %s\n'  "$*" >&2; }
    _cx_ok()   { printf '\033[32m[OK]\033[0m %s\n'    "$*" >&2; }
    _cx_warn() { printf '\033[33m[WARN]\033[0m %s\n'  "$*" >&2; }
    _cx_fail() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

    _cx_config_file() { printf '%s/config.toml' "${CODEX_HOME:-$HOME/.codex}"; }

    # First value of KEY= in a profile file (empty if absent).
    _cx_profile_val() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

    # toml_set <section> <key> <value> — stdin filter. Replaces the key inside
    # the given section ('' = top-level) or inserts it, creating the section
    # header at EOF if needed. Blank lines are buffered so an inserted key
    # lands at the section's end, before the separating blank line. Values are
    # always written as TOML strings.
    _cx_toml_set() {
        awk -v section="$1" -v key="$2" -v val="$3" '
        function emit() { print key " = \"" val "\""; done = 1 }
        function flushb() { while (nb > 0) { print ""; nb-- } }
        BEGIN { cur = ""; done = 0; nb = 0 }
        /^[[:space:]]*$/ { nb++; next }
        /^\[/ {
            if (!done && cur == section) emit()
            flushb()
            cur = $0; sub(/^\[/, "", cur); sub(/\].*$/, "", cur)
            print; next
        }
        {
            flushb()
            if (!done && cur == section && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) emit()
            else print
        }
        END {
            if (!done) {
                if (section != "" && cur != section) { flushb(); print ""; print "[" section "]" }
                emit()
            }
            flushb()
        }'
    }

    _cx_list() {
        local f name
        echo "Profiles (${profiles_dir}):" >&2
        for f in "${profiles_dir}"/*.env; do
            [[ -f "$f" ]] || continue
            name="$(basename "$f" .env)"
            if grep -Eq '^CODEX_MODEL_DEPLOYMENT=' "$f"; then
                printf '  %-16s [codex-capable]\n' "$name" >&2
            else
                printf '  %-16s (no codex block)\n' "$name" >&2
            fi
        done
    }

    _cx_status() {
        local file; file="$(_cx_config_file)"
        _cx_info "target: ${file}"
        if [[ -f "$file" ]]; then
            local m p b
            m="$(grep -E '^[[:space:]]*model[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            p="$(grep -E '^[[:space:]]*model_provider[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            b="$(grep -E '^[[:space:]]*base_url[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            _cx_ok "model: ${m:-<unset>}  provider: ${p:-<unset>}"
            _cx_info "base_url: ${b:-<unset>}"
        else
            _cx_warn "config does not exist yet"
        fi
        if [[ -n "${AZURE_OPENAI_API_KEY:-}" ]]; then
            _cx_ok "AZURE_OPENAI_API_KEY set (session)"
        else
            _cx_warn "AZURE_OPENAI_API_KEY not set in this shell"
        fi
    }

    _cx_use() {
        local name="" scope="session"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --scope) scope="${2:-session}"; shift 2 ;;
                -*)      _cx_warn "unknown flag: $1"; shift ;;
                *)       name="$1"; shift ;;
            esac
        done
        [[ -n "$name" ]] || { _cx_fail "usage: use <profile> [--scope session|user]"; return 1; }

        case "$scope" in
            session) ;;
            user)    _cx_info "note: bash applies session scope for the env var; persist via your shell rc (PowerShell maps 'user' to the persistent User scope)." ;;
            project) _cx_info "scope 'project' has no Codex analog — skipped."; return 0 ;;
            *)       _cx_warn "unknown scope '${scope}' — using session." ;;
        esac

        local f="${profiles_dir}/${name}.env"
        [[ -f "$f" ]] || { _cx_fail "profile not found: ${f}"; return 1; }

        # A profile is Codex-capable iff it names an Azure deployment.
        local deployment resource api_key
        deployment="$(_cx_profile_val "$f" CODEX_MODEL_DEPLOYMENT)"
        if [[ -z "$deployment" ]]; then
            _cx_info "profile '${name}' has no CODEX_MODEL_DEPLOYMENT — nothing for the codex target."
            return 0
        fi
        resource="$(_cx_profile_val "$f" FOUNDRY_RESOURCE)"
        [[ -z "$resource" ]] && resource="$(_cx_profile_val "$f" ANTHROPIC_FOUNDRY_RESOURCE)"
        api_key="$(_cx_profile_val "$f" FOUNDRY_API_KEY)"
        [[ -z "$api_key" ]] && api_key="$(_cx_profile_val "$f" ANTHROPIC_FOUNDRY_API_KEY)"
        if [[ -z "$resource" ]]; then
            _cx_fail "profile '${name}' sets CODEX_MODEL_DEPLOYMENT but no FOUNDRY_RESOURCE."
            return 1
        fi

        # desired-state: patch config.toml only where it deviates.
        local file dir old new
        file="$(_cx_config_file)"; dir="$(dirname "$file")"
        mkdir -p "$dir"
        old=""; [[ -f "$file" ]] && old="$(cat "$file")"
        new="$old"
        _cx_apply() {
            if [[ -z "$new" ]]; then new="$(_cx_toml_set "$@" </dev/null)"
            else new="$(printf '%s\n' "$new" | _cx_toml_set "$@")"; fi
        }
        _cx_apply "" model "$deployment"
        _cx_apply "" model_provider azure
        _cx_apply model_providers.azure name "Azure OpenAI"
        _cx_apply model_providers.azure base_url "https://${resource}.openai.azure.com/openai/v1"
        _cx_apply model_providers.azure env_key AZURE_OPENAI_API_KEY
        _cx_apply model_providers.azure wire_api responses
        unset -f _cx_apply

        if [[ "$new" == "$old" ]]; then
            _cx_ok "config already up to date (${file})"
        else
            printf '%s\n' "$new" > "$file"
            _cx_ok "model -> ${deployment}, provider azure (${file})"
        fi

        if [[ -z "$api_key" ]]; then
            _cx_warn "no FOUNDRY_API_KEY in profile — set AZURE_OPENAI_API_KEY yourself."
        elif [[ "${CODEX_PROFIL_SOURCED:-false}" == "true" ]]; then
            export AZURE_OPENAI_API_KEY="$api_key"
            _cx_ok "AZURE_OPENAI_API_KEY exported (session)"
        else
            _cx_warn "not sourced — AZURE_OPENAI_API_KEY cannot reach your shell. Wire the sourcing function: toolbox install --what codex-profil"
        fi
    }

    local action="${1:-help}"; shift || true
    case "$action" in
        help|-h|--help)
            cat <<EOF
codex-profil ${APP_VERSION} — point ~/.codex/config.toml at a backend profile.

Usage: codex-profil <action> [args]

Actions:
  help                          this message
  list                          profiles (Codex-capable marked)
  status                        show config target + current model/provider
  use <profile> [--scope ...]   write config.toml + export AZURE_OPENAI_API_KEY
                                (--scope session|user; idempotent)

Profiles dir: ${profiles_dir}
Profile keys consumed: FOUNDRY_RESOURCE, FOUNDRY_API_KEY, CODEX_MODEL_DEPLOYMENT
Installation: toolbox install --what codex-profil
EOF
            ;;
        list)   _cx_list ;;
        status) _cx_status ;;
        use)    _cx_use "$@" ;;
        *)      _cx_fail "unknown action: ${action}"; return 1 ;;
    esac
    local rc=$?

    unset -f _cx_info _cx_ok _cx_warn _cx_fail _cx_config_file _cx_profile_val \
             _cx_toml_set _cx_list _cx_status _cx_use
    return $rc
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    CODEX_PROFIL_SOURCED=false _codex_profil_main "$@"
else
    CODEX_PROFIL_SOURCED=true _codex_profil_main "$@"
    unset -f _codex_profil_main
fi
