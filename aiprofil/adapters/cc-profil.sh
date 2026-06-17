#!/usr/bin/env bash
# =============================================================================
# cc-profil — local Claude Code profile switcher (bash). CC-env adapter.
# =============================================================================
# Must be sourced — it modifies the current shell's environment. The sourcing
# `cc-profil()` function is wired into ~/.bashrc by:
#   toolbox install --what cc-profil
# (catalog entry: type=bin, source=true).
#
# A profile is a profiles/<name>.env file of KEY=VALUE pairs. `use` clears the
# previously-set "managed vars" (profiles/.managed-vars) and exports the new
# ones. POST_ACTIVATE_CMD is run after activation.
#
# Relocated under aiprofil/adapters/. Profiles resolve with a legacy fallback
# so installs that still carry profiles under the old cc-profil/profiles/ path
# keep working without a re-install (PROFILES_DIR env overrides everything).
#
# Scope: --scope session|user  (--global == --scope user, back-compat).
#   session  current shell only (default; the only scope bash persists natively)
#   user     same as session on bash + note (no User registry like Windows);
#            on PowerShell this maps to the persistent User scope.
#   project  no CC analog -> skipped with a note.
# =============================================================================

APP_VERSION='0.2.6'

_cc_profil_main() {
    local script_dir profiles_dir managed_vars_file
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
    managed_vars_file="${profiles_dir}/.managed-vars"

    _read_managed_vars() {
        [[ -f "$managed_vars_file" ]] && grep -E '^[A-Z_]' "$managed_vars_file" || true
    }

    _do_list() {
        local active="${CC_PROFILE:-}"
        echo "Profiles (${profiles_dir}):"
        local found=false
        for f in "${profiles_dir}"/*.env; do
            [[ -f "$f" ]] || continue
            found=true
            local name
            name="$(basename "$f" .env)"
            if [[ "$name" == "$active" ]]; then
                echo -e "  * ${name}  \033[32m(active)\033[0m"
            else
                echo "    ${name}"
            fi
        done
        $found || echo "  (no .env profiles found)"
    }

    _do_use() {
        local profile="" scope="session"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --global)         scope="user"; shift ;;
                --scope)          scope="${2:-session}"; shift 2 ;;
                -*)               echo "[WARN] unknown flag: $1"; shift ;;
                *)                profile="$1"; shift ;;
            esac
        done

        if [[ -z "$profile" ]]; then
            echo "Usage: cc-profil use <profile> [--scope session|user]"
            return 1
        fi

        case "$scope" in
            session) ;;
            user)    echo "[cc-profil] note: bash applies session scope; persist via your shell rc (PowerShell maps 'user' to the persistent User scope)." ;;
            project) echo "[cc-profil] scope 'project' has no CC analog — skipped."; return 0 ;;
            *)       echo "[WARN] unknown scope '${scope}' — using session." ;;
        esac

        local env_file="${profiles_dir}/${profile}.env"
        if [[ ! -f "$env_file" ]]; then
            echo "[WARN] profile '${profile}' not found: ${env_file}"
            _do_list
            return 1
        fi

        # Unset the previous profile's managed vars.
        local var
        while IFS= read -r var; do
            [[ -n "$var" ]] && unset "$var"
        done < <(_read_managed_vars)

        # Load the new profile. KILO_* keys belong to the kilo-profil adapter
        # (they configure a file edit, not the shell env) — don't export them.
        local post_cmd=""
        local key val
        while IFS='=' read -r key val; do
            if [[ "$key" == "POST_ACTIVATE_CMD" ]]; then
                post_cmd="$val"
                continue
            fi
            [[ "$key" == KILO_* ]] && continue
            export "${key}=${val}"
        done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$env_file")
        export CC_PROFILE="$profile"

        echo "[cc-profil] profile '${profile}' activated (scope: ${scope})."

        if [[ -n "$post_cmd" ]]; then
            echo "[cc-profil] running: ${post_cmd}"
            eval "$post_cmd"
        fi
    }

    local action="${1:-help}"
    shift || true

    case "${action}" in
        list)  _do_list ;;
        use)   _do_use "$@" ;;
        *)
            cat <<'EOF'
cc-profil — local Claude Code profile switcher (CC-env adapter)

Usage: cc-profil <action> [args]

Actions:
  list                          List available profiles
  use <profile> [--scope ...]   Activate a profile. --scope session|user
                                (--global == --scope user)

Installation (one-time, wires the sourcing shell function):
  toolbox install --what cc-profil
EOF
            ;;
    esac

    unset -f _read_managed_vars _do_list _do_use
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "cc-profil must be sourced. Install with:" >&2
    echo "  toolbox install --what cc-profil" >&2
    exit 1
else
    _cc_profil_main "$@"
    unset -f _cc_profil_main
fi
