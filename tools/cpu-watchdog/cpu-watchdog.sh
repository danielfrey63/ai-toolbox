#!/usr/bin/env bash
# Three-stage CPU temperature watchdog (invoked once per minute by a systemd
# user timer; state survives between ticks, resets on reboot).
#
# Temperature source: the HOTTEST of all thermal zones (acpitz, pkg, ...) and
# the NVIDIA GPU. Never a single preferred sensor — the Aug 2026 hardware
# shutdown happened because acpitz climbed to 128°C while the throttled CPU
# package read a harmless 78°C.
#
# Stage 1 (temp >= WARN_C): one warning, naming the hottest process.
# Stage 2 only when the warning showed no effect: after GRACE_S the
#   temperature is still rising (or CRIT_C is exceeded outright) -> stop the
#   next still-active entry of the prioritized stop list. One entry per tick,
#   so a higher-priority victim gets time to cool the box before the next
#   one is sacrificed.
# Stage 3 (temp >= EMERG_C, or stop list exhausted): cap the global CPU
#   performance ceiling to THROTTLE_PCT via the root helper cpu-throttle —
#   this hits ANY heat source without having to know its name.
# Recovery (temp <= WARN_C - HYST_C): lift the cap, reset state, all-clear.
#
# While the box is hot the script re-checks every FAST_INTERVAL_S inside one
# run instead of waiting for the next timer tick — a 1-minute grid is too
# coarse for a 50°C-in-6-minutes sprint.
#
# Hardware protection itself is thermald's job - this watchdog makes
# overheating visible, sheds our own batch load, and caps the rest.
set -euo pipefail

WARN_C=${WARN_C:-85}
CRIT_C=${CRIT_C:-92}
EMERG_C=${EMERG_C:-95}
HYST_C=${HYST_C:-5}
GRACE_S=${GRACE_S:-180}
THROTTLE_PCT=${THROTTLE_PCT:-30}
THROTTLE_HELPER=${THROTTLE_HELPER:-/usr/local/sbin/cpu-throttle}
FAST_INTERVAL_S=${FAST_INTERVAL_S:-15}
FAST_TICKS_MAX=${FAST_TICKS_MAX:-16}

CONF=${CONF:-$HOME/.config/cpu-watchdog/stop-list.conf}
STATE_DIR=${STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/cpu-watchdog}
LOG=${LOG:-$HOME/.cache/cpu-watchdog.log}
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
STATE="$STATE_DIR/warn-state"        # "<epoch> <temp-at-warning>"
THROTTLED="$STATE_DIR/throttled"     # exists while the global CPU cap is on

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
  # Hottest of ALL zones — acpitz (EC/board) is the one that trips the
  # kernel's hardware protection, so it must never be masked by a cooler
  # package sensor.
  for z in /sys/class/thermal/thermal_zone*; do
    [ -r "$z/temp" ] || continue
    t=$(( $(cat "$z/temp") / 1000 ))
    [ "$t" -gt "$max" ] && max=$t
  done
  # NVIDIA GPU heats the same heatpipe but has no thermal zone entry.
  if command -v nvidia-smi >/dev/null 2>&1; then
    while read -r t; do
      [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt "$max" ] && max=$t
    done < <(timeout 5 nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)
  fi
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

# Stage 3: cap the global CPU performance ceiling. Idempotent per hot phase.
throttle_now() {  # $1 temp, $2 reason
  [ -e "$THROTTLED" ] && return 0
  if sudo -n "$THROTTLE_HELPER" set "$THROTTLE_PCT" >/dev/null 2>&1; then
    touch "$THROTTLED"
    log "THROTTLE: $1°C — CPU capped to ${THROTTLE_PCT}% ($2)"
    notify critical "CPU-Watchdog: CPU gedrosselt" \
      "$1°C — CPU global auf ${THROTTLE_PCT}% gedeckelt ($2). Aufhebung bei Entwarnung."
  else
    # No marker on failure: retried every tick, but logged (not notified) to
    # keep the channels quiet while still leaving a trace.
    log "THROTTLE FAILED: $1°C — sudo -n $THROTTLE_HELPER refused ($2)"
  fi
  return 0
}

unthrottle() {  # $1 temp
  [ -e "$THROTTLED" ] || return 0
  if sudo -n "$THROTTLE_HELPER" reset >/dev/null 2>&1; then
    rm -f "$THROTTLED"
    log "UNTHROTTLE: $1°C — CPU cap lifted"
    notify low "CPU-Watchdog: Drosselung aufgehoben" "$1°C — CPU wieder auf voller Leistung."
  else
    log "UNTHROTTLE FAILED: $1°C — sudo -n $THROTTLE_HELPER refused"
  fi
  return 0
}

# One full pass of the state machine for a single temperature reading.
evaluate() {
  local temp=$1 now warn_epoch warn_temp stopped

  # --- stage 3 fast path: way past critical — cap first, sort out later ---
  if [ "$temp" -ge "$EMERG_C" ]; then
    throttle_now "$temp" "emergency: >= ${EMERG_C}°C"
  fi

  # --- recovery ---
  if [ "$temp" -le $(( WARN_C - HYST_C )) ]; then
    unthrottle "$temp"
    if [ -e "$STATE" ]; then
      rm -f "$STATE"
      log "recovered: ${temp}°C — state reset"
      notify low "CPU wieder kühl" "${temp}°C — Watchdog zurückgesetzt."
    fi
    return 0
  fi

  [ "$temp" -lt "$WARN_C" ] && return 0   # hysteresis band: keep state, do nothing

  # --- stage 1: first time over the warning threshold ---
  if [ ! -e "$STATE" ]; then
    echo "$(date +%s) $temp" > "$STATE"
    log "WARN: ${temp}°C (>= ${WARN_C}°C) — top: $(top_process)"
    notify critical "CPU heiss: ${temp}°C" \
      "Verursacher: $(top_process). Ohne Abkühlung stoppt der Watchdog in $(( GRACE_S / 60 )) min Dienste gemäss Stop-Liste."
    return 0
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
      log "STOP: ${temp}°C — stop list exhausted, capping CPU instead"
      throttle_now "$temp" "stop list exhausted"
      echo "$warn_epoch $temp" > "$STATE"
    fi
  else
    log "warn active: ${temp}°C (warned ${warn_temp}°C, $(( now - warn_epoch ))s ago) — waiting"
  fi
  return 0
}

temp=$(read_temp)
evaluate "$temp"

# Hot phase: stay resident and re-check every FAST_INTERVAL_S instead of
# waiting for the next timer tick. Bounded by FAST_TICKS_MAX; if still hot
# afterwards the next timer activation takes over seamlessly.
fast=0
while [ "$temp" -ge "$WARN_C" ] && [ "$fast" -lt "$FAST_TICKS_MAX" ]; do
  sleep "$FAST_INTERVAL_S"
  temp=$(read_temp)
  evaluate "$temp"
  fast=$(( fast + 1 ))
done
