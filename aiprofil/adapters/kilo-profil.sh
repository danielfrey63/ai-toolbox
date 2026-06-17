#!/usr/bin/env bash
# =============================================================================
# kilo-profil — point the Kilo Code config (kilo.jsonc) at a backend profile.
#               Bash variant. Counterpart to cc-profil (which does the same for
#               the Claude Code CLI via env vars). Both read the SAME profile
#               files in cc-profil/profiles/<name>.env — one profile, two tools.
# =============================================================================
# What it does for a profile that carries KILO_* keys:
#   - ensures provider.<KILO_PROVIDER_ID> exists in kilo.jsonc (else: guarded
#     emit — see "provider block" below; we do NOT blind-write a nested block)
#   - repoints the top-level "model" (and "small_model") to
#     <KILO_PROVIDER_ID>/<KILO_ACTIVE_MODEL>
#
# The repoint touches ONLY depth-1 scalar keys, via a brace-depth-aware editor
# that preserves // comments, $schema and formatting. No jq reserialize.
#
# Scope (--scope, mirrors aiprofil):
#   user     ~/.config/kilo/kilo.jsonc            (default)
#   project  ./kilo.jsonc or ./.kilo/kilo.jsonc   (repo-local)
#
# Sub-commands: help | list | status | use <profile> [--scope user|project]
# =============================================================================

APP_VERSION='0.2.3'
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared profile home. Resolution: explicit override > new aiprofil/profiles >
# legacy cc-profil/profiles (keeps installs that still carry profiles at the
# old path working without a re-install).
if [[ -z "${PROFILES_DIR:-}" ]]; then
    if compgen -G "${SCRIPT_DIR}/../profiles/*.env" >/dev/null 2>&1; then
        PROFILES_DIR="$(cd "${SCRIPT_DIR}/../profiles" && pwd)"
    elif compgen -G "${SCRIPT_DIR}/../../cc-profil/profiles/*.env" >/dev/null 2>&1; then
        PROFILES_DIR="$(cd "${SCRIPT_DIR}/../../cc-profil/profiles" && pwd)"
    else
        PROFILES_DIR="${SCRIPT_DIR}/../profiles"
    fi
fi

info() { printf '\033[36m[INFO]\033[0m %s\n'  "$*" >&2; }
ok()   { printf '\033[32m[OK]\033[0m %s\n'    "$*" >&2; }
warn() { printf '\033[33m[WARN]\033[0m %s\n'  "$*" >&2; }
fail() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

# --- target file resolution --------------------------------------------------
resolve_target() {
    local scope="${1:-user}"
    case "$scope" in
        user)
            local base="${XDG_CONFIG_HOME:-$HOME/.config}"
            printf '%s/kilo/kilo.jsonc' "$base"
            ;;
        project)
            if [[ -f "./kilo.jsonc" ]]; then printf './kilo.jsonc'
            elif [[ -f "./.kilo/kilo.jsonc" ]]; then printf './.kilo/kilo.jsonc'
            else printf './kilo.jsonc'; fi   # default create location
            ;;
        *) fail "unknown scope: ${scope} (use user|project)"; return 1 ;;
    esac
}

# --- profile loading ---------------------------------------------------------
load_profile() {
    local name="$1"
    local f="${PROFILES_DIR}/${name}.env"
    [[ -f "$f" ]] || { fail "profile not found: ${f}"; return 1; }
    # Export KEY=VALUE lines (don't clobber values already in the environment).
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        export "${key}=${val}"
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$f")
}

# A profile is Kilo-capable iff it declares a provider id + active model.
profile_has_kilo() {
    [[ -n "${KILO_PROVIDER_ID:-}" && -n "${KILO_ACTIVE_MODEL:-}" ]]
}

# --- depth-1 scalar setter (comment/format preserving) -----------------------
# set_toplevel <file> <key> <json-string-value>  -> writes to stdout.
# Replaces the value of the root-object key only; ignores nested keys of the
# same name (e.g. agent.*.model). Brace counting skips "strings" and // comments.
set_toplevel() {
    awk -v key="$2" -v newval="$3" '
    BEGIN { depth = 0; done = 0 }
    {
        raw = $0
        # Build a brace-relevant view of the line: drop // comments and the
        # contents of "double quoted" strings so braces inside them dont count.
        s = raw; clean = ""; i = 1; n = length(s); instr = 0
        while (i <= n) {
            c = substr(s, i, 1)
            if (!instr && substr(s, i, 2) == "//") break
            if (c == "\"") { instr = !instr; i++; continue }
            if (!instr) clean = clean c
            i++
        }
        if (!done && depth == 1 && match(raw, "^[[:space:]]*\"" key "\"[[:space:]]*:")) {
            indent = raw; sub(/[^[:space:]].*/, "", indent)
            comma = (raw ~ /,[[:space:]]*(\/\/.*)?$/) ? "," : ""
            print indent "\"" key "\": \"" newval "\"" comma
            done = 1
        } else {
            print raw
        }
        gsub(/[^{}]/, "", clean)
        m = length(clean)
        for (j = 1; j <= m; j++) {
            ch = substr(clean, j, 1)
            if (ch == "{") depth++; else if (ch == "}") depth--
        }
    }
    END { if (!done) exit 9 }   # key not found at depth 1
    ' "$1"
}

provider_present() {
    local file="$1" pid="$2"
    grep -Eq "\"${pid}\"[[:space:]]*:" "$file"
}

current_model() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    set_toplevel "$file" model "__probe__" >/dev/null 2>&1 \
        && grep -E '^[[:space:]]{0,4}"model"[[:space:]]*:' "$file" | head -1 \
            | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

# --- sub-commands ------------------------------------------------------------
cmd_help() {
    cat <<EOF
kilo-profil ${APP_VERSION} — point kilo.jsonc at a backend profile.

Usage: bash $(basename "$0") <action> [args]

Actions:
  help                          this message
  list                          profiles (Kilo-capable marked) + active model
  status [--scope user|project] show target file + current model, change nothing
  use <profile> [--scope ...]   repoint model/small_model (idempotent)

Profiles dir: ${PROFILES_DIR:-<not found>}
Profile keys consumed: KILO_PROVIDER_ID, KILO_ACTIVE_MODEL, KILO_SMALL_MODEL
EOF
}

cmd_list() {
    [[ -n "$PROFILES_DIR" && -d "$PROFILES_DIR" ]] || { fail "profiles dir not found"; return 1; }
    local active; active="$(current_model "$(resolve_target user)")"
    info "active (user kilo.jsonc) model: ${active:-<none>}"
    echo "Profiles (${PROFILES_DIR}):" >&2
    local f name
    for f in "${PROFILES_DIR}"/*.env; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f" .env)"
        if grep -Eq '^KILO_PROVIDER_ID=' "$f"; then
            printf '  %-16s [kilo-capable]\n' "$name" >&2
        else
            printf '  %-16s (cc-only)\n' "$name" >&2
        fi
    done
}

cmd_status() {
    local scope="${1:-user}" file
    file="$(resolve_target "$scope")" || return 1
    info "scope: ${scope}"
    info "target: ${file}"
    if [[ -f "$file" ]]; then
        ok "current model: $(current_model "$file" || echo '<unset>')"
    else
        warn "target file does not exist yet"
    fi
}

cmd_use() {
    local name="" scope="user"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scope) scope="${2:-user}"; shift 2 ;;
            -*) fail "unknown flag: $1"; return 1 ;;
            *) name="$1"; shift ;;
        esac
    done
    [[ -n "$name" ]] || { fail "usage: use <profile> [--scope user|project]"; return 1; }

    load_profile "$name" || return 1
    if ! profile_has_kilo; then
        info "profile '${name}' has no KILO_* keys — nothing for the kilo target (cc-only profile)."
        return 0
    fi

    local file; file="$(resolve_target "$scope")" || return 1
    if [[ ! -f "$file" ]]; then
        fail "kilo config not found: ${file}"
        warn "launch Kilo once (or create the file) so there is something to repoint."
        return 1
    fi

    # desired-state: provider block present. We do NOT blind-write a nested
    # JSONC block — emit it for review/paste if missing (guarded).
    if ! provider_present "$file" "${KILO_PROVIDER_ID}"; then
        warn "provider '${KILO_PROVIDER_ID}' not in ${file} — repoint skipped."
        warn "Add this provider block first (see kilo-profil README / aiprofil), then re-run:"
        local res="${ANTHROPIC_FOUNDRY_RESOURCE:-<resource>}"
        printf '  "%s": { "name": "%s", "npm": "@ai-sdk/anthropic",\n' "${KILO_PROVIDER_ID}" "${name}" >&2
        printf '    "options": { "baseURL": "https://%s.services.ai.azure.com/anthropic/v1",\n' "$res" >&2
        printf '                 "apiKey": "<key>", "headers": { "api-key": "<key>" } } }\n' >&2
        return 1
    fi

    local target_model="${KILO_PROVIDER_ID}/${KILO_ACTIVE_MODEL}"
    local tmp; tmp="$(mktemp)"
    if set_toplevel "$file" model "$target_model" > "$tmp"; then
        mv "$tmp" "$file"
        ok "model -> ${target_model}  (${file})"
    else
        rm -f "$tmp"
        fail "no top-level \"model\" key in ${file} — not changed"
        return 1
    fi

    if [[ -n "${KILO_SMALL_MODEL:-}" ]]; then
        local target_small="${KILO_PROVIDER_ID}/${KILO_SMALL_MODEL}"
        tmp="$(mktemp)"
        if set_toplevel "$file" small_model "$target_small" > "$tmp"; then
            mv "$tmp" "$file"
            ok "small_model -> ${target_small}"
        else
            rm -f "$tmp"
            warn "no top-level \"small_model\" key — left as is"
        fi
    fi
}

# --- dispatch ----------------------------------------------------------------
action="${1:-help}"; shift || true
case "$action" in
    help|-h|--help) cmd_help ;;
    list)           cmd_list ;;
    status)         [[ "${1:-}" == "--scope" ]] && cmd_status "${2:-user}" || cmd_status "user" ;;
    use)            cmd_use "$@" ;;
    *) fail "unknown action: ${action}"; cmd_help; exit 1 ;;
esac
