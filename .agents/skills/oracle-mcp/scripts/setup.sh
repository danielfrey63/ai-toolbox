#!/usr/bin/env bash
# =============================================================================
# oracle-mcp setup — provision an Oracle MCP server (Oracle SQLcl `sql -mcp`)
#                    for natural-language SQL data queries. Bash variant.
# =============================================================================
# Idempotent (desired-state): every change is check -> mutate-if-needed ->
# re-verify, via the bundled idempotent.sh library. Safe to re-run.
#
# Sub-commands: help | verify | install | cleanup
#
# What the MCP server is: Oracle SQLcl 25.x ships a built-in MCP server,
# launched as `sql -mcp`. It exposes SQLcl's *named, saved connections* to an
# MCP client (Claude Code, Kilo, ...) so the model can run SQL WITHOUT ever
# seeing the database password — the credential lives in SQLcl's secure store.
#
# Config: ./config/oracle.env (copy from oracle.env.tmpl, gitignored).
# =============================================================================

# Script version. Named distinctly so sourcing idempotent.sh (which defines
# its own APP_VERSION) doesn't clobber it. The skill's canonical version is
# metadata.version in SKILL.md.
SETUP_VERSION='0.2.0'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${SKILL_DIR}/config"
CONFIG_FILE="${ORACLE_MCP_CONFIG:-${CONFIG_DIR}/oracle.env}"

# shellcheck source=../lib/idempotent.sh
source "${SKILL_DIR}/lib/idempotent.sh"

# --- config ------------------------------------------------------------------
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ -z "${!key:-}" ]] && export "${key}=${val}"
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$CONFIG_FILE")
}

CONN_NAME="${ORACLE_CONN_NAME:-hackathon}"
MCP_CLIENT="${ORACLE_MCP_CLIENT:-print}"

# Kilo Code config. Path order: explicit override -> ~/.config/kilo/kilo.jsonc
# -> ~/.config/kilo.jsonc (some installs flatten it). The marker token is the
# idempotency anchor; it lives inside the template's // markers.
KILO_MARKER='oracle-mcp:managed'
resolve_kilo_config() {
    if [[ -n "${ORACLE_KILO_CONFIG:-}" ]]; then printf '%s\n' "$ORACLE_KILO_CONFIG"; return; fi
    local c
    for c in "$HOME/.config/kilo/kilo.jsonc" "$HOME/.config/kilo.jsonc"; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return; }
    done
    printf '%s\n' "$HOME/.config/kilo/kilo.jsonc"   # default target if none exists yet
}

# --- checks (read-only) ------------------------------------------------------
have_sqlcl()  { command -v sql >/dev/null 2>&1; }
have_java()   { command -v java >/dev/null 2>&1; }
have_claude() { command -v claude >/dev/null 2>&1; }

# The managed "oracle" block (marker lines inclusive) sliced from the template,
# so the template stays the single source of truth. Markers are anchored to the
# start of the line (^//>>>) so the template's descriptive header — which quotes
# the marker text mid-line — is not mistaken for the block itself.
kilo_managed_block() {
    awk '/^\/\/>>> '"$KILO_MARKER"'/{p=1} p{print} /^\/\/<<< '"$KILO_MARKER"'/{p=0}' \
        "${CONFIG_DIR}/mcp-registration.jsonc.tmpl"
}

# Marker present in the Kilo config?
kilo_registered() {
    local f; f="$(resolve_kilo_config)"
    [[ -f "$f" ]] && grep -qF "$KILO_MARKER" "$f"
}

# Match the target file's final-newline state to the reference's, so a rewrite
# of a no-trailing-newline file (Kilo writes one) stays byte-identical.
kilo_match_eof() {
    local ref="$1" tgt="$2"
    # tail -c1 yields "" when the last byte is a newline (or the file is empty).
    if [[ -s "$ref" && -n "$(tail -c1 "$ref")" && -z "$(tail -c1 "$tgt")" ]]; then
        printf '%s' "$(cat "$tgt")" > "${tgt}.eof" && mv -- "${tgt}.eof" "$tgt"
    fi
}

# Insert the managed block as the FIRST child of the `mcp` object (always with a
# trailing comma -> existing entries are never touched; .jsonc tolerates the
# trailing comma even if `mcp` was empty). No-op write if no `mcp` opener found.
kilo_do_install() {
    local f; f="$(resolve_kilo_config)"
    [[ -f "$f" ]] || { warn "Kilo config not found: $f"; return 1; }
    local blk tmp; blk="$(mktemp)"; tmp="$(mktemp)"
    kilo_managed_block > "$blk"
    cp -- "$f" "${f}.bak"
    awk -v bf="$blk" '
        BEGIN { while ((getline line < bf) > 0) blk[n++]=line }
        { print }
        !done && /"mcp"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
            for (i=0;i<n;i++) print "    " blk[i]; done=1
        }
    ' "$f" > "$tmp"
    if ! grep -qF "$KILO_MARKER" "$tmp"; then rm -f "$tmp" "$blk"; return 1; fi
    kilo_match_eof "$f" "$tmp"
    mv -- "$tmp" "$f"; rm -f "$blk"
}

# Remove the managed block (markers inclusive). Restores the file byte-for-byte.
kilo_do_cleanup() {
    local f; f="$(resolve_kilo_config)"
    [[ -f "$f" ]] || return 0
    local tmp; tmp="$(mktemp)"
    cp -- "$f" "${f}.bak"
    awk '
        /^[[:space:]]*\/\/>>> '"$KILO_MARKER"'/ {skip=1}
        !skip { print }
        /^[[:space:]]*\/\/<<< '"$KILO_MARKER"'/ {skip=0}
    ' "$f" > "$tmp"
    kilo_match_eof "$f" "$tmp"
    mv -- "$tmp" "$f"
}

# A saved SQLcl connection with our name exists?
conn_exists() {
    have_sqlcl || return 1
    # `connmgr list` prints saved connection names; tolerate older syntax.
    { printf 'conn -list\n' | sql -nolog 2>/dev/null; } | grep -qiw "$CONN_NAME"
}

# MCP server registered with Claude Code under the name "oracle"?
claude_mcp_registered() {
    have_claude || return 1
    claude mcp list 2>/dev/null | grep -qiw "oracle"
}

# --- sub-commands ------------------------------------------------------------
cmd_help() {
    cat <<EOF
oracle-mcp setup ${SETUP_VERSION} — Oracle SQLcl MCP for SQL data queries.

Usage: bash $(basename "$0") <action>

Actions:
  help      this message
  verify    check current state, change nothing
  install   scaffold config, save the SQLcl connection, register the MCP server
  cleanup   unregister the MCP server (and optionally drop the saved connection)

Config: ${CONFIG_FILE}
  (copy config/oracle.env.tmpl -> config/oracle.env and fill in; gitignored)

Registration target (ORACLE_MCP_CLIENT in oracle.env):
  print   only emit the snippet, change nothing (default)
  claude  register with Claude Code via 'claude mcp add'
  kilo    insert/remove the 'oracle' entry in Kilo's kilo.jsonc, idempotently,
          preserving comments (no jq). Path: ORACLE_KILO_CONFIG, else
          ~/.config/kilo/kilo.jsonc, else ~/.config/kilo.jsonc.

Prerequisites (not auto-installed — Oracle license/download required):
  - Oracle SQLcl 25.x on PATH ('sql')   https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/
  - A JVM (unless using a SQLcl build with bundled GraalVM)
EOF
}

cmd_verify() {
    show_header "oracle-mcp verify"
    local rc=0

    checking "Oracle SQLcl ('sql') on PATH"
    if have_sqlcl; then ok "found: $(command -v sql)"; else warn "missing — install SQLcl 25.x"; rc=1; fi

    checking "JVM ('java') available"
    if have_java; then ok "found"; else warn "missing — SQLcl needs Java unless GraalVM-bundled"; rc=1; fi

    checking "config file"
    if [[ -f "$CONFIG_FILE" ]]; then ok "present: ${CONFIG_FILE}"; else warn "absent — run 'install' to scaffold"; rc=1; fi

    checking "saved SQLcl connection '${CONN_NAME}'"
    if conn_exists; then ok "present"; else warn "not saved yet"; rc=1; fi

    case "$MCP_CLIENT" in
        kilo)
            checking "Kilo MCP registration 'oracle'"
            if kilo_registered; then ok "registered in $(resolve_kilo_config)"; else warn "not registered — run 'install'"; rc=1; fi
            ;;
        claude)
            checking "Claude Code MCP registration 'oracle'"
            if claude_mcp_registered; then ok "registered"; else warn "not registered — run 'install'"; rc=1; fi
            ;;
        *)
            checking "Claude Code MCP registration 'oracle'"
            if claude_mcp_registered; then ok "registered"; else warn "not registered (ok if target is 'print')"; fi
            ;;
    esac

    [[ $rc -eq 0 ]] && ok "ready" || warn "not fully set up — see 'install'"
    return $rc
}

cmd_install() {
    show_header "oracle-mcp install"

    if ! have_sqlcl; then
        fail "Oracle SQLcl not on PATH. Install SQLcl 25.x first (see 'help'), then re-run."
        return 1
    fi

    # desired-state: config file scaffolded from template
    desired_state "config file ${CONFIG_FILE}" \
        "test -f '${CONFIG_FILE}'" \
        "cp '${CONFIG_DIR}/oracle.env.tmpl' '${CONFIG_FILE}'"
    if [[ ! -s "$CONFIG_FILE" ]]; then
        fail "config scaffold failed"; return 1
    fi
    load_config
    CONN_NAME="${ORACLE_CONN_NAME:-$CONN_NAME}"
    MCP_CLIENT="${ORACLE_MCP_CLIENT:-$MCP_CLIENT}"

    # desired-state: SQLcl named connection saved.
    # NOTE: saving needs a live password and writes to SQLcl's secure store.
    # This is credential-bearing, so we do not run it blindly — guarded until
    # the exact save syntax is verified against the target SQLcl build.
    if conn_exists; then
        ok "SQLcl connection '${CONN_NAME}' already saved — nothing to do"
    else
        warn "connection '${CONN_NAME}' not saved. To save it (creds go to SQLcl's"
        warn "secure store, NOT to the model), run interactively, e.g.:"
        warn "    sql /nolog"
        warn "    SQL> connect -save ${CONN_NAME} -savepwd ${ORACLE_USER:-<user>}@<easyconnect-or-tns>"
        warn "(MUTATION DEFERRED — see README 'Offene Verifikation' for the exact"
        warn " connect-save syntax per SQLcl version before automating this.)"
    fi

    # desired-state: MCP server registered with the chosen client.
    case "$MCP_CLIENT" in
        claude)
            if ! have_claude; then
                warn "ORACLE_MCP_CLIENT=claude but 'claude' not on PATH — skipping registration"
            else
                desired_state "Claude Code MCP 'oracle'" \
                    "claude mcp list 2>/dev/null | grep -qiw oracle" \
                    "claude mcp add oracle -- sql -mcp"
            fi
            ;;
        kilo)
            local kf; kf="$(resolve_kilo_config)"
            if [[ ! -f "$kf" ]]; then
                warn "Kilo config not found: ${kf}"
                warn "Create it or set ORACLE_KILO_CONFIG, then re-run. Manual snippet for the 'mcp' block:"
                kilo_managed_block >&2
            elif desired_state "Kilo MCP 'oracle' in ${kf}" "kilo_registered" "kilo_do_install"; then
                ok "inserted into ${kf} (backup: ${kf}.bak)"
            else
                warn "could not auto-insert (no 'mcp' opener line found). Paste this into the 'mcp' block by hand:"
                kilo_managed_block >&2
            fi
            ;;
        *)
            info "ORACLE_MCP_CLIENT=print — registration snippet (change nothing):"
            sed "s/{{ORACLE_CONN_NAME}}/${CONN_NAME}/g" "${CONFIG_DIR}/mcp-registration.jsonc.tmpl" >&2
            ;;
    esac

    cmd_verify
}

cmd_cleanup() {
    show_header "oracle-mcp cleanup"

    if have_claude; then
        desired_absent "Claude Code MCP 'oracle'" \
            "! (claude mcp list 2>/dev/null | grep -qiw oracle)" \
            "claude mcp remove oracle"
    fi

    if kilo_registered; then
        desired_absent "Kilo MCP 'oracle' in $(resolve_kilo_config)" \
            "! kilo_registered" "kilo_do_cleanup"
    else
        ok "Kilo MCP 'oracle' not present — nothing to remove"
    fi

    if conn_exists; then
        if confirm_destructive "drop saved SQLcl connection '${CONN_NAME}'?"; then
            warn "connection drop deferred — verify 'conn -delete ${CONN_NAME}' syntax for your"
            warn "SQLcl version, then run it manually (see README)."
        fi
    else
        ok "no saved connection '${CONN_NAME}' — nothing to drop"
    fi
    ok "cleanup done (config file left in place; delete ${CONFIG_FILE} by hand if desired)"
}

# --- dispatch ----------------------------------------------------------------
ACTION="$(parse_action "${1:-help}")"
case "$ACTION" in
    help)    cmd_help ;;
    verify)  load_config; cmd_verify ;;
    install) load_config; cmd_install ;;
    cleanup) load_config; cmd_cleanup ;;
    *)       fail "unknown action: ${1:-}"; cmd_help; exit 1 ;;
esac
