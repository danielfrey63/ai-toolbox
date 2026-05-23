#!/usr/bin/env bash
# =============================================================================
# cc-profil — local Claude Code profile switcher (bash)
# =============================================================================
# Must be sourced — it modifies the current shell's environment. The sourcing
# `cc-profil()` function is wired into ~/.bashrc by:
#   toolbox install --what cc-profil
# (catalog entry: type=bin, source=true).
#
# A profile is a profiles/<name>.env file of KEY=VALUE pairs. `use` clears the
# previously-set "managed vars" (profiles/.managed-vars) and exports the new
# ones. POST_ACTIVATE_CMD is run after activation.
# =============================================================================

APP_VERSION='0.1.3'

_cc_profil_main() {
    local script_dir profiles_dir managed_vars_file
    # BASH_SOURCE[0] points at this script even when sourced.
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    profiles_dir="${script_dir}/profiles"
    managed_vars_file="${profiles_dir}/.managed-vars"

    _read_managed_vars() {
        [[ -f "$managed_vars_file" ]] && grep -E '^[A-Z_]' "$managed_vars_file" || true
    }

    # =================================================================
    # list
    # =================================================================
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

    # =================================================================
    # use <profile>
    # =================================================================
    _do_use() {
        local profile="${1:-}"
        if [[ -z "$profile" ]]; then
            echo "Usage: cc-profil use <profile>"
            return 1
        fi

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

        # Load the new profile (POST_ACTIVATE_CMD handled separately).
        local post_cmd=""
        local key val
        while IFS='=' read -r key val; do
            if [[ "$key" == "POST_ACTIVATE_CMD" ]]; then
                post_cmd="$val"
                continue
            fi
            export "${key}=${val}"
        done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$env_file")

        echo "[cc-profil] profile '${profile}' activated."

        if [[ -n "$post_cmd" ]]; then
            echo "[cc-profil] running: ${post_cmd}"
            eval "$post_cmd"
        fi
    }

    # =================================================================
    # Dispatch
    # =================================================================
    local action="${1:-help}"
    shift || true

    case "${action}" in
        list)  _do_list ;;
        use)   _do_use "$@" ;;
        *)
            cat <<'EOF'
cc-profil — local Claude Code profile switcher

Usage: cc-profil <action> [args]

Actions:
  list                  List available profiles
  use <profile>         Activate a profile (current session)

Installation (one-time, wires the sourcing shell function):
  toolbox install --what cc-profil
EOF
            ;;
    esac

    unset -f _read_managed_vars _do_list _do_use
}

# Must be sourced (not executed). The toolbox installer wires a sourcing
# function `cc-profil() { source '<this>' "$@"; }` into ~/.bashrc.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "cc-profil must be sourced. Install with:" >&2
    echo "  toolbox install --what cc-profil" >&2
    exit 1
else
    _cc_profil_main "$@"
    unset -f _cc_profil_main
fi
