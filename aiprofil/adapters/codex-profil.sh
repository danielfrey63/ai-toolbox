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
# Deployment catalog (optional, combinable with the above):
#   CODEX_MODEL_DEPLOYMENTS=a,b   one [profiles."<provider>-<a>"] per deployment
#                                 (codex --profile <provider>-<a>); stale ones of
#                                 the provider are dropped. Without
#                                 CODEX_MODEL_DEPLOYMENT the default model stays.
#   CODEX_PROVIDER_ID=<id>        own [model_providers.<id>] (default azure) with
#                                 env_key AZURE_<ID>_API_KEY
#   CODEX_BASE_URL=<url>          overrides the base_url derived from the resource
#   CODEX_API_VERSION=<ver>       [model_providers.<id>.query_params] api-version
#   CODEX_API_KEY=<key>           key for this provider (else FOUNDRY_API_KEY)
#
# Subscription mode (CODEX_AUTH=chatgpt) instead targets the built-in openai
# provider with the ChatGPT sign-in (codex login): sets forced_login_method,
# drops the Azure repoint, and uses CODEX_MODEL (or the Codex default) as
# model. No API key involved.
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

APP_VERSION='0.4.18'

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

    # toml_del <section> <key> — stdin filter. Drops the key line inside the
    # given section ('' = top-level); everything else passes through.
    _cx_toml_del() {
        awk -v section="$1" -v key="$2" '
        BEGIN { cur = "" }
        /^\[/ { cur = $0; sub(/^\[/, "", cur); sub(/\].*$/, "", cur); print; next }
        { if (cur == section && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) next; print }'
    }

    # toml_drop <prefix> <provider> <keep_csv> — stdin filter. Drops every
    # section whose name starts with <prefix>, is not listed in <keep_csv> and
    # (if <provider> is non-empty) carries model_provider = "<provider>".
    # Blank lines travel with the section that follows them, so a dropped
    # section takes its separating blank line along.
    _cx_toml_drop() {
        awk -v prefix="$1" -v provider="$2" -v keepcsv="$3" '
        function flush() {
            if (nsec > 0 && !(droppable && (provider == "" || hasprov) && !(name in keep)))
                for (i = 1; i <= nsec; i++) print sec[i]
            nsec = 0
        }
        BEGIN {
            n = split(keepcsv, arr, ","); for (i = 1; i <= n; i++) keep[arr[i]] = 1
            nsec = 0; nb = 0; name = ""; droppable = 0; hasprov = 0
        }
        /^[[:space:]]*$/ { nb++; next }
        /^\[/ {
            flush()
            name = $0; sub(/^\[/, "", name); sub(/\].*$/, "", name)
            droppable = (index(name, prefix) == 1); hasprov = 0
            while (nb > 0) { sec[++nsec] = ""; nb-- }
            sec[++nsec] = $0; next
        }
        {
            while (nb > 0) { sec[++nsec] = ""; nb-- }
            if ($0 ~ /^[[:space:]]*model_provider[[:space:]]*=/) {
                v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/"|[[:space:]]+$/, "", v)
                if (v == provider) hasprov = 1
            }
            sec[++nsec] = $0
        }
        END {
            keeplast = !(droppable && (provider == "" || hasprov) && !(name in keep))
            flush()
            if (keeplast) while (nb > 0) { print ""; nb-- }
        }'
    }

    _cx_list() {
        local f name
        echo "Profiles (${profiles_dir}):" >&2
        for f in "${profiles_dir}"/*.env; do
            [[ -f "$f" ]] || continue
            name="$(basename "$f" .env)"
            if grep -Eq '^(CODEX_MODEL_DEPLOYMENTS?|CODEX_AUTH)=' "$f"; then
                printf '  %-16s [codex-capable]\n' "$name" >&2
            else
                printf '  %-16s (no codex block)\n' "$name" >&2
            fi
        done
    }

    _cx_status() {
        local file; file="$(_cx_config_file)"
        _cx_info "target: ${file}"
        local p=""
        if [[ -f "$file" ]]; then
            local m b l
            m="$(grep -E '^[[:space:]]*model[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            p="$(grep -E '^[[:space:]]*model_provider[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            b="$(grep -E '^[[:space:]]*base_url[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            l="$(grep -E '^[[:space:]]*forced_login_method[[:space:]]*=' "$file" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
            _cx_ok "model: ${m:-<unset>}  provider: ${p:-<unset>}  login: ${l:-<default>}"
            _cx_info "base_url: ${b:-<unset>}"
        else
            _cx_warn "config does not exist yet"
        fi
        # The env key only matters when the azure provider is active.
        if [[ "$p" == "azure" ]]; then
            if [[ -n "${AZURE_OPENAI_API_KEY:-}" ]]; then
                _cx_ok "AZURE_OPENAI_API_KEY set (session)"
            else
                _cx_warn "AZURE_OPENAI_API_KEY not set in this shell"
            fi
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

        # A profile is Codex-capable iff it names an Azure deployment
        # (CODEX_MODEL_DEPLOYMENT), a deployment catalog (CODEX_MODEL_DEPLOYMENTS)
        # or a subscription login (CODEX_AUTH=chatgpt).
        local auth deployment deployments model resource api_key mode
        local provider base_url api_version env_key
        auth="$(_cx_profile_val "$f" CODEX_AUTH)"
        deployment="$(_cx_profile_val "$f" CODEX_MODEL_DEPLOYMENT)"
        deployments="$(_cx_profile_val "$f" CODEX_MODEL_DEPLOYMENTS)"
        model="$(_cx_profile_val "$f" CODEX_MODEL)"
        if [[ -z "$auth" && -z "$deployment" && -z "$deployments" ]]; then
            _cx_info "profile '${name}' has no CODEX_* keys — nothing for the codex target."
            return 0
        fi
        if [[ "$auth" == "chatgpt" ]]; then
            mode="chatgpt"
        elif [[ -n "$auth" ]]; then
            _cx_fail "profile '${name}': unknown CODEX_AUTH '${auth}' (use chatgpt, or omit for Azure mode)."
            return 1
        else
            mode="azure"
            # Provider id: 'azure' (default) keeps AZURE_OPENAI_API_KEY; any
            # other id gets its own env var so several backends coexist.
            provider="$(_cx_profile_val "$f" CODEX_PROVIDER_ID)"
            provider="${provider:-azure}"
            if [[ "$provider" == "azure" ]]; then env_key="AZURE_OPENAI_API_KEY"
            else env_key="AZURE_$(printf '%s' "$provider" | tr '[:lower:]-' '[:upper:]_')_API_KEY"; fi
            base_url="$(_cx_profile_val "$f" CODEX_BASE_URL)"
            api_version="$(_cx_profile_val "$f" CODEX_API_VERSION)"
            resource="$(_cx_profile_val "$f" FOUNDRY_RESOURCE)"
            [[ -z "$resource" ]] && resource="$(_cx_profile_val "$f" ANTHROPIC_FOUNDRY_RESOURCE)"
            api_key="$(_cx_profile_val "$f" CODEX_API_KEY)"
            [[ -z "$api_key" ]] && api_key="$(_cx_profile_val "$f" FOUNDRY_API_KEY)"
            [[ -z "$api_key" ]] && api_key="$(_cx_profile_val "$f" ANTHROPIC_FOUNDRY_API_KEY)"
            if [[ -z "$base_url" && -z "$resource" ]]; then
                _cx_fail "profile '${name}' has Codex deployments but neither CODEX_BASE_URL nor FOUNDRY_RESOURCE."
                return 1
            fi
            [[ -z "$base_url" ]] && base_url="https://${resource}.openai.azure.com/openai/v1"
        fi

        # desired-state: patch config.toml only where it deviates.
        local file dir old new
        file="$(_cx_config_file)"; dir="$(dirname "$file")"
        mkdir -p "$dir"
        old=""; [[ -f "$file" ]] && old="$(cat "$file")"
        new="$old"
        _cx_apply() {  # <set|del|drop> <section|prefix> <key|provider> [value|keep]
            local op="$1"; shift
            if [[ -z "$new" ]]; then new="$("_cx_toml_${op}" "$@" </dev/null)"
            else new="$(printf '%s\n' "$new" | "_cx_toml_${op}" "$@")"; fi
        }
        if [[ "$mode" == "chatgpt" ]]; then
            # Subscription mode: built-in openai provider + ChatGPT sign-in.
            # Without CODEX_MODEL the model key is dropped -> Codex default.
            _cx_apply set "" model_provider openai
            _cx_apply set "" forced_login_method chatgpt
            if [[ -n "$model" ]]; then _cx_apply set "" model "$model"
            else _cx_apply del "" model; fi
        else
            # Only a single CODEX_MODEL_DEPLOYMENT repoints the default model;
            # a catalog-only profile leaves the top level (e.g. ChatGPT) alone.
            if [[ -n "$deployment" ]]; then
                _cx_apply set "" model "$deployment"
                _cx_apply set "" model_provider "$provider"
                _cx_apply del "" forced_login_method
            fi
            local psec="model_providers.${provider}"
            if [[ "$provider" == "azure" ]]; then _cx_apply set "$psec" name "Azure OpenAI"
            else _cx_apply set "$psec" name "Azure OpenAI (${provider})"; fi
            _cx_apply set "$psec" base_url "$base_url"
            _cx_apply set "$psec" env_key "$env_key"
            _cx_apply set "$psec" wire_api responses
            # api-version lives in its own sub-table; an inline query_params
            # key would clash with it, so it is always removed.
            _cx_apply del "$psec" query_params
            if [[ -n "$api_version" ]]; then _cx_apply set "${psec}.query_params" api-version "$api_version"
            else _cx_apply drop "${psec}.query_params" "" ""; fi
            # One Codex profile per catalog deployment, named <provider>-<deployment>;
            # stale ones of this provider are dropped.
            local d keep="" sec
            IFS=',' read -ra _cx_deps <<< "$deployments"
            for d in "${_cx_deps[@]}"; do
                d="$(printf '%s' "$d" | tr -d '[:space:]')"
                [[ -n "$d" ]] || continue
                sec="profiles.\"${provider}-${d}\""
                keep="${keep:+${keep},}${sec}"
                _cx_apply set "$sec" model "$d"
                _cx_apply set "$sec" model_provider "$provider"
            done
            _cx_apply drop "profiles.\"${provider}-" "$provider" "$keep"
        fi
        unset -f _cx_apply

        if [[ "$new" == "$old" ]]; then
            _cx_ok "config already up to date (${file})"
        elif [[ "$mode" == "chatgpt" ]]; then
            printf '%s\n' "$new" > "$file"
            _cx_ok "model -> ${model:-<codex default>}, provider openai, login chatgpt (${file})"
        else
            printf '%s\n' "$new" > "$file"
            [[ -n "$deployment" ]] && _cx_ok "model -> ${deployment}, provider ${provider} (${file})"
            [[ -n "$keep" ]] && _cx_ok "profiles for provider ${provider}: $(printf '%s' "$keep" | sed -E 's/profiles\."([^"]*)"/\1/g; s/,/, /g') (${file})"
        fi

        if [[ "$mode" == "chatgpt" ]]; then
            if [[ ! -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]]; then
                _cx_info "no Codex login found — run 'codex login' once to sign in with the ChatGPT account."
            fi
        elif [[ -z "$api_key" ]]; then
            _cx_warn "no CODEX_API_KEY/FOUNDRY_API_KEY in profile — set ${env_key} yourself."
        elif [[ "${CODEX_PROFIL_SOURCED:-false}" == "true" ]]; then
            export "${env_key}=${api_key}"
            _cx_ok "${env_key} exported (session)"
        else
            _cx_warn "not sourced — ${env_key} cannot reach your shell. Wire the sourcing function: toolbox install --what codex-profil"
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
  use <profile> [--scope ...]   write config.toml + export the provider's API key
                                (--scope session|user; idempotent)

Profiles dir: ${profiles_dir}
Profile keys consumed:
  Azure mode:        FOUNDRY_RESOURCE, FOUNDRY_API_KEY, CODEX_MODEL_DEPLOYMENT
  Azure catalog:     CODEX_MODEL_DEPLOYMENTS=a,b,..  -> profiles "<provider>-<a>", ...
                     [CODEX_PROVIDER_ID] [CODEX_BASE_URL] [CODEX_API_VERSION] [CODEX_API_KEY]
  Subscription mode: CODEX_AUTH=chatgpt [CODEX_MODEL]  (sign-in via codex login)
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
             _cx_toml_set _cx_toml_del _cx_list _cx_status _cx_use
    return $rc
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    CODEX_PROFIL_SOURCED=false _codex_profil_main "$@"
else
    CODEX_PROFIL_SOURCED=true _codex_profil_main "$@"
    unset -f _codex_profil_main
fi
