# shellcheck shell=bash
# =============================================================================
# idempotent.sh -- core primitives for idempotent, verify-then-mutate DevOps
#                  scripts. Single-file, no dependencies beyond bash + coreutils
#                  (optional jq for config parsing).
#
# Source it from a setup script:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/idempotent.sh"
#
# The library encodes ONE rule: every state change goes through
# `desired_state` (or `desired_absent`), which checks first, mutates only on
# divergence, and re-verifies. That's the whole methodology -- everything else
# is logging, argument parsing and remote execution.
#
# Provided:
#   parse_action            normalize sub-command (help|verify|install|cleanup|purge|...)
#   info / ok / warn / fail consistent log output (stderr-safe)
#   desired_state           check -> mutate-if-needed -> re-verify
#   desired_absent          inverted variant for cleanup paths
#   confirm_destructive     interactive yes/no gate (bypassed by FORCE=1)
#   run_cmd / run_scp       SSH_TARGET-aware execution (local vs. remote)
#   show_header             banner with local/remote target
#
# Versioning: bump APP_VERSION on every change. Downstream projects can pin by
# checking the marker at install time.
# =============================================================================

APP_VERSION='0.2.0'

# --- color codes (no-op when stdout is not a TTY) -----------------------------
if [[ -t 1 ]]; then
    _IDM_RED='\033[0;31m'
    _IDM_GREEN='\033[0;32m'
    _IDM_YELLOW='\033[1;33m'
    _IDM_CYAN='\033[0;36m'
    _IDM_NC='\033[0m'
else
    _IDM_RED='' _IDM_GREEN='' _IDM_YELLOW='' _IDM_CYAN='' _IDM_NC=''
fi

# --- log sink ----------------------------------------------------------------
# Mutation stdout/stderr is appended to LOG_FILE (default: per-script tmp file).
# Callers may override before sourcing; an empty value disables capture.
LOG_FILE="${LOG_FILE:-/tmp/idempotent-$(basename -- "${0:-shell}" .sh)-$(id -u).log}"
if [[ -n "$LOG_FILE" ]]; then
    : > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
else
    LOG_FILE=/dev/null
fi

# --- log primitives ----------------------------------------------------------
# All log lines go to stderr so that command substitution (ACTION=$(parse_action ...))
# captures only the intended stdout. Each helper takes one message arg.
info()     { printf '%b[INFO]%b     %s\n'  "$_IDM_GREEN"  "$_IDM_NC" "$*" >&2; }
ok()       { printf '%b[OK]%b       %s\n'  "$_IDM_GREEN"  "$_IDM_NC" "$*" >&2; }
warn()     { printf '%b[WARNING]%b  %s\n'  "$_IDM_YELLOW" "$_IDM_NC" "$*" >&2; }
fail()     { printf '%b[ERROR]%b    %s\n'  "$_IDM_RED"    "$_IDM_NC" "$*" >&2; }
checking() { printf '%b[CHECKING]%b %s ... ' "$_IDM_CYAN" "$_IDM_NC" "$*" >&2; }
changing() { printf '%b[CHANGING]%b %s ... ' "$_IDM_YELLOW" "$_IDM_NC" "$*" >&2; }
sep()      { printf -- '----------------------------------------------------\n' >&2; }

# --- header ------------------------------------------------------------------
# Banner with target info (local vs. SSH_TARGET) -- call once at script start.
show_header() {
    local title="$1"
    sep
    printf '%b%s%b\n' "$_IDM_CYAN" "$title" "$_IDM_NC" >&2
    sep
    if [[ -n "${SSH_TARGET:-}" ]]; then
        info "Target: ${SSH_TARGET} (remote)"
    else
        info "Target: local ($(hostname))"
    fi
}

# --- argument parsing --------------------------------------------------------
# parse_action <arg> -> normalized action on stdout. Unknown actions become
# 'help' with a warning on stderr. Default action is 'help'.
#
# Recognized aliases:
#   install                       -> install
#   cleanup | remove | delete     -> cleanup
#   purge                         -> purge
#   verify | check | status       -> verify
#   help | (empty)                -> help
#
# Add your own actions in the caller by handling them BEFORE invoking
# parse_action, or extend this function in a fork.
parse_action() {
    local action="${1:-help}"
    case "$action" in
        install)                        echo install ;;
        cleanup|remove|delete)          echo cleanup ;;
        purge)                          echo purge ;;
        verify|check|status)            echo verify ;;
        help|"")                        echo help ;;
        *)
            warn "Unknown action: ${action}"
            echo help
            ;;
    esac
}

# --- SSH-aware execution -----------------------------------------------------
# run_cmd "<shell-command>"  -- runs locally when SSH_TARGET is empty, via ssh
# when set. SSH_PORT and SSH_IDENTITY are honored if set. The command string is
# passed verbatim to the remote shell -- caller is responsible for quoting.
#
# Examples:
#   SSH_TARGET=admin@host SSH_PORT=2222 run_cmd 'systemctl is-active nginx'
#   run_cmd 'test -d /opt/app'            # local
SSH_TARGET="${SSH_TARGET:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_IDENTITY="${SSH_IDENTITY:-}"

run_cmd() {
    if [[ -n "$SSH_TARGET" ]]; then
        ssh ${SSH_PORT:+-p "$SSH_PORT"} ${SSH_IDENTITY:+-i "$SSH_IDENTITY"} \
            -o BatchMode=yes "$SSH_TARGET" "$@"
    else
        bash -c "$@"
    fi
}

# run_scp <scp-args>  -- thin wrapper that injects -P and -i from SSH_PORT /
# SSH_IDENTITY. Only meaningful for remote targets; for local copies use
# install(1) or cp(1) directly.
run_scp() {
    scp ${SSH_PORT:+-P "$SSH_PORT"} ${SSH_IDENTITY:+-i "$SSH_IDENTITY"} "$@"
}

# --- desired_state -----------------------------------------------------------
# desired_state "<description>" "<check_cmd>" "<change_cmd>"
#
# Lifecycle:
#   1. CHECKING  -> run check_cmd. If it exits 0, log "already correct" and return 0.
#   2. CHANGING  -> run change_cmd. If non-zero, log error and return 1.
#   3. CHECKING  -> re-run check_cmd. If 0, log "changed". If not, log
#                   verification-failed and return 1.
#
# The check_cmd MUST be side-effect-free and exit 0 iff the desired state is
# present. The change_cmd is only invoked on divergence.
#
# Both commands are passed to `eval` -- they may be simple commands, pipelines
# or quoted multi-statement strings. Stdout/stderr is redirected to LOG_FILE
# so the human-facing output stays clean; failures point at the log.
desired_state() {
    local description="$1" check_cmd="$2" change_cmd="$3"

    checking "$description"
    if eval "$check_cmd" >>"$LOG_FILE" 2>&1; then
        printf '%balready correct%b\n' "$_IDM_GREEN" "$_IDM_NC" >&2
        return 0
    fi
    printf '%bneeds change%b\n' "$_IDM_YELLOW" "$_IDM_NC" >&2

    changing "$description"
    if ! eval "$change_cmd" >>"$LOG_FILE" 2>&1; then
        printf '%bFAILED%b (see %s)\n' "$_IDM_RED" "$_IDM_NC" "$LOG_FILE" >&2
        return 1
    fi
    printf '%bdone%b\n' "$_IDM_GREEN" "$_IDM_NC" >&2

    checking "$description"
    if eval "$check_cmd" >>"$LOG_FILE" 2>&1; then
        printf '%bverified%b\n' "$_IDM_GREEN" "$_IDM_NC" >&2
        return 0
    fi
    printf '%bVERIFICATION FAILED%b (see %s)\n' "$_IDM_RED" "$_IDM_NC" "$LOG_FILE" >&2
    return 1
}

# --- desired_absent ----------------------------------------------------------
# desired_absent "<description>" "<absent_check_cmd>" "<remove_cmd>"
#
# Inverse of desired_state for cleanup paths: absent_check_cmd MUST exit 0 iff
# the thing is already absent (e.g. `! test -f /etc/foo.conf`). Lifecycle:
#   1. CHECKING  -> if already absent, return 0 with "already absent".
#   2. REMOVING  -> run remove_cmd. Non-zero -> error.
#   3. CHECKING  -> re-verify absence. Still present -> error.
desired_absent() {
    local description="$1" absent_check_cmd="$2" remove_cmd="$3"

    checking "$description (absent?)"
    if eval "$absent_check_cmd" >>"$LOG_FILE" 2>&1; then
        printf '%balready absent%b\n' "$_IDM_GREEN" "$_IDM_NC" >&2
        return 0
    fi
    printf '%bstill present%b\n' "$_IDM_YELLOW" "$_IDM_NC" >&2

    changing "removing: $description"
    if ! eval "$remove_cmd" >>"$LOG_FILE" 2>&1; then
        printf '%bFAILED%b (see %s)\n' "$_IDM_RED" "$_IDM_NC" "$LOG_FILE" >&2
        return 1
    fi
    printf '%bdone%b\n' "$_IDM_GREEN" "$_IDM_NC" >&2

    checking "$description (absent?)"
    if eval "$absent_check_cmd" >>"$LOG_FILE" 2>&1; then
        printf '%bverified absent%b\n' "$_IDM_GREEN" "$_IDM_NC" >&2
        return 0
    fi
    printf '%bSTILL PRESENT%b (see %s)\n' "$_IDM_RED" "$_IDM_NC" "$LOG_FILE" >&2
    return 1
}

# --- destructive confirmation ------------------------------------------------
# confirm_destructive "<message>" -- prompts the user for 'yes' / 'no' on
# stderr. Anything other than 'yes' aborts the script via exit 0 (cancelled,
# not failed). Set FORCE=1 in the environment to bypass.
confirm_destructive() {
    local msg="${1:-This will delete data.}"
    if [[ "${FORCE:-}" == "1" ]]; then
        warn "${msg} [FORCE=1, proceeding without confirmation]"
        return 0
    fi
    printf '%b[CONFIRM]%b %s Continue? (yes/no): ' \
        "$_IDM_YELLOW" "$_IDM_NC" "$msg" >&2
    read -r reply
    if [[ "${reply,,}" != "yes" ]]; then
        info "Aborted."
        exit 0
    fi
}
