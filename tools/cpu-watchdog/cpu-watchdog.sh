#!/usr/bin/env bash
# Two-stage CPU temperature watchdog (invoked once per minute by a systemd
# user timer; state survives between ticks, resets on reboot).
#
# Stage 1 (temp >= WARN_C): one desktop warning, naming the hottest process.
# Stage 2 only when the warning showed no effect: after GRACE_S the
#   temperature is still rising (or CRIT_C is exceeded outright) -> stop the
#   next still-active entry of the prioritized stop list. One entry per tick,
#   so a higher-priority victim gets a minute to cool the box before the next
#   one is sacrificed.
# Recovery (temp <= WARN_C - HYST_C): reset state, log the all-clear.
#
# Hardware protection itself is thermald's job - this watchdog only makes
# overheating visible and sheds our own batch load.
set -euo pipefail

WARN_C=${WARN_C:-85}
CRIT_C=${CRIT_C:-92}
HYST_C=${HYST_C:-5}
GRACE_S=${GRACE_S:-180}

CONF=${CONF:-$HOME/.config/cpu-watchdog/stop-list.conf}
STATE_DIR=${STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/cpu-watchdog}
LOG=${LOG:-$HOME/.cache/cpu-watchdog.log}
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
STATE="$STATE_DIR/warn-state"   # "<epoch> <temp-at-warning>"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

send_mail() {  # $1 subject, $2 body — needs smtp.env, silently skipped otherwise
  local env="$HOME/.config/cpu-watchdog/smtp.env"
  [ -r "$env" ] || return 0
  # shellcheck source=/dev/null
  . "$env"
  [ -n "${SMTP_URL:-}" ] && [ -n "${SMTP_USER:-}" ] && [ -n "${SMTP_PASS:-}" ] || return 0
  printf 'From: cpu-watchdog <%s>\nTo: %s\nSubject: %s\nDate: %s\n\n%s\nHost: %s\nLog: ~/.cache/cpu-watchdog.log\n' \
    "${MAIL_FROM:-$SMTP_USER}" "${MAIL_TO:-$SMTP_USER}" "$1" "$(date -R)" "$2" "$(hostname)" |
    curl --silent --ssl-reqd --url "$SMTP_URL" --user "$SMTP_USER:$SMTP_PASS" \
      --mail-from "${MAIL_FROM:-$SMTP_USER}" --mail-rcpt "${MAIL_TO:-$SMTP_USER}" \
      --upload-file - --max-time 20 2>/dev/null || log "mail delivery failed: $1"
}

notify() {  # $1 urgency, $2 title, $3 body — best effort, never fatal
  # Primary channel: wall reaches every open terminal (console, SSH, tmux) —
  # the box runs headless, so a desktop notification alone would go nowhere.
  printf '[cpu-watchdog] %s — %s\n' "$2" "$3" | wall 2>/dev/null || true
  # E-mail covers the unattended case (nightly batch runs, laptop left alone).
  send_mail "[cpu-watchdog] $2" "$3"
  DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus} \
    notify-send --urgency="$1" --app-name=cpu-watchdog "$2" "$3" 2>/dev/null || true
}

# `cpu-watchdog.sh test-notify` exercises every channel once and exits.
if [ "${1:-}" = test-notify ]; then
  notify low "Testmeldung" "Kanaltest: wall, E-Mail (falls smtp.env befüllt) und notify-send."
  echo "test notification sent — check terminals and mailbox"
  exit 0
fi

read_temp() {
  if [ -n "${TEMP_OVERRIDE:-}" ]; then echo "$TEMP_OVERRIDE"; return; fi
  local max=0 t
  # Prefer the CPU package sensor; fall back to the hottest zone.
  for z in /sys/class/thermal/thermal_zone*; do
    [ -r "$z/temp" ] || continue
    t=$(( $(cat "$z/temp") / 1000 ))
    if [ "$(cat "$z/type")" = x86_pkg_temp ]; then echo "$t"; return; fi
    [ "$t" -gt "$max" ] && max=$t
  done
  echo "$max"
}

top_process() {
  # Second top frame = real 1 s delta (instantaneous load). ps/frame 1 only
  # show lifetime averages and misattribute fork-heavy load to old processes.
  LC_ALL=C top -bn2 -d1 -o %CPU -w 512 |
    awk '/^[ ]*PID/{f++} f==2 && $1 ~ /^[0-9]+$/ {printf "%s (pid %s, %s%% CPU)", $NF, $1, $9; exit}'
}

# Stop the highest-priority entry of the stop list that is still running.
# Prints what was stopped; returns 1 if nothing was left to stop.
shed_one() {
  [ -r "$CONF" ] || return 1
  local kind arg
  while read -r kind arg; do
    case "$kind" in
      ''|'#'*) continue ;;
      user-unit)
        if systemctl --user is-active --quiet "$arg" 2>/dev/null; then
          systemctl --user stop "$arg" && { echo "user-unit $arg"; return 0; }
        fi ;;
      pkill)
        if pgrep -f "$arg" > /dev/null 2>&1; then
          pkill -f "$arg" && { echo "processes matching '$arg'"; return 0; }
        fi ;;
      *) log "config: unknown action '$kind $arg'" ;;
    esac
  done < "$CONF"
  return 1
}

temp=$(read_temp)

# --- recovery ---
if [ "$temp" -le $(( WARN_C - HYST_C )) ]; then
  if [ -e "$STATE" ]; then
    rm -f "$STATE"
    log "recovered: ${temp}°C — state reset"
    notify low "CPU wieder kühl" "${temp}°C — Watchdog zurückgesetzt."
  fi
  exit 0
fi

[ "$temp" -lt "$WARN_C" ] && exit 0   # hysteresis band: keep state, do nothing

# --- stage 1: first time over the warning threshold ---
if [ ! -e "$STATE" ]; then
  echo "$(date +%s) $temp" > "$STATE"
  log "WARN: ${temp}°C (>= ${WARN_C}°C) — top: $(top_process)"
  notify critical "CPU heiss: ${temp}°C" \
    "Verursacher: $(top_process). Ohne Abkühlung stoppt der Watchdog in $(( GRACE_S / 60 )) min Dienste gemäss Stop-Liste."
  exit 0
fi

# --- stage 2: escalate only if the warning showed no effect ---
read -r warn_epoch warn_temp < "$STATE"
now=$(date +%s)
if [ "$temp" -ge "$CRIT_C" ] || { [ $(( now - warn_epoch )) -ge "$GRACE_S" ] && [ "$temp" -gt "$warn_temp" ]; }; then
  if stopped=$(shed_one); then
    log "STOP: ${temp}°C (warned at ${warn_temp}°C) — stopped $stopped"
    notify critical "CPU-Watchdog: Dienst gestoppt" "${temp}°C — gestoppt: $stopped"
    echo "$warn_epoch $temp" > "$STATE"   # raise the bar: escalate again only if it rises further
  else
    log "STOP: ${temp}°C — stop list exhausted, nothing left to shed (thermald takes over)"
    notify critical "CPU-Watchdog: Liste erschöpft" \
      "${temp}°C und nichts mehr zu stoppen — Drosselung übernimmt thermald. Top: $(top_process)"
    echo "$warn_epoch $temp" > "$STATE"
  fi
else
  log "warn active: ${temp}°C (warned ${warn_temp}°C, $(( now - warn_epoch ))s ago) — waiting"
fi
