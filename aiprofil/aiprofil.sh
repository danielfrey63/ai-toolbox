#!/usr/bin/env bash
# =============================================================================
# aiprofil — unified backend-profile switcher across two tools (bash):
#   - CC  : Claude Code CLI env vars        (adapter: adapters/cc-profil.sh)
#   - Kilo: Kilo Code config kilo.jsonc     (adapter: adapters/kilo-profil.sh)
#
# One profile (profiles/<name>.env), two targets. MUST be sourced — the CC
# target mutates the current shell's environment. The sourcing `aiprofil()`
# function is wired into ~/.bashrc by `toolbox install --what aiprofil`.
#
# Two orthogonal enums:
#   --target  cc | kilo | both   (also a list: cc,kilo)   default: both
#   --scope   session | user | project                    default: user
#
# Scope maps per target (no analog -> skipped with a note):
#                 session     user                  project
#   cc            shell       User scope            (skip)
#   kilo          (skip)      ~/.config/kilo         ./kilo.jsonc
# =============================================================================

APP_VERSION='0.3.4'

_aiprofil_main() {
    local script_dir adapters profiles_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    adapters="${script_dir}/adapters"

    # Resolve profiles once (new location, legacy fallback) and hand it to the
    # adapters via PROFILES_DIR so all three agree on the source.
    if compgen -G "${script_dir}/profiles/*.env" >/dev/null 2>&1; then
        profiles_dir="$(cd "${script_dir}/profiles" && pwd)"
    elif compgen -G "${script_dir}/../cc-profil/profiles/*.env" >/dev/null 2>&1; then
        profiles_dir="$(cd "${script_dir}/../cc-profil/profiles" && pwd)"
    else
        profiles_dir="${script_dir}/profiles"
    fi
    export PROFILES_DIR="$profiles_dir"

    _ai_info() { printf '\033[36m[aiprofil]\033[0m %s\n' "$*"; }

    _ai_use() {
        local profile="" target="both" scope="user"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --target) target="${2:-both}"; shift 2 ;;
                --scope)  scope="${2:-user}";  shift 2 ;;
                -*)       echo "[WARN] unknown flag: $1"; shift ;;
                *)        profile="$1"; shift ;;
            esac
        done
        if [[ -z "$profile" ]]; then
            echo "Usage: aiprofil use <profile> [--target cc|kilo|both] [--scope session|user|project]"
            return 1
        fi

        # Normalize target to a comma-free membership test.
        local want_cc=false want_kilo=false
        case ",${target}," in
            *,both,*) want_cc=true; want_kilo=true ;;
            *) [[ ",${target}," == *,cc,*   ]] && want_cc=true
               [[ ",${target}," == *,kilo,* ]] && want_kilo=true ;;
        esac
        if ! $want_cc && ! $want_kilo; then
            echo "[WARN] --target '${target}' selected nothing (use cc|kilo|both)"; return 1
        fi

        # CC target.
        if $want_cc; then
            if [[ "$scope" == "project" ]]; then
                _ai_info "cc:   scope 'project' has no CC analog — skipped"
            else
                # Sourced so the env lands in the caller's shell.
                source "${adapters}/cc-profil.sh" use "$profile" --scope "$scope"
            fi
        fi

        # Kilo target.
        if $want_kilo; then
            if [[ "$scope" == "session" ]]; then
                _ai_info "kilo: scope 'session' has no Kilo analog — skipped"
            else
                bash "${adapters}/kilo-profil.sh" use "$profile" --scope "$scope"
            fi
        fi
    }

    _ai_list() {
        bash "${adapters}/kilo-profil.sh" list
        echo "CC active (session): ${CC_PROFILE:-<none>}"
        echo "Switch defaults: --target both | --scope user"
    }

    _ai_status() {
        echo "CC active (session): ${CC_PROFILE:-<none>}"
        bash "${adapters}/kilo-profil.sh" status "$@"
    }

    local action="${1:-help}"; shift || true
    case "$action" in
        use)    _ai_use "$@" ;;
        list)   _ai_list ;;
        status) _ai_status "$@" ;;
        *)
            cat <<EOF
aiprofil ${APP_VERSION} — unified profile switcher (Claude Code + Kilo).

Usage: aiprofil <action> [args]

Actions:
  list                          profiles + active CC/Kilo state
  status [--scope user|project] what each target points at
  use <profile> [--target ...] [--scope ...]
        --target  cc | kilo | both   (default both; list ok: cc,kilo)
        --scope   session | user | project   (default user)

Profiles: ${profiles_dir}
Installation: toolbox install --what aiprofil
EOF
            ;;
    esac

    unset -f _ai_info _ai_use _ai_list _ai_status
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "aiprofil must be sourced. Install with: toolbox install --what aiprofil" >&2
    exit 1
else
    _aiprofil_main "$@"
    unset -f _aiprofil_main
fi
