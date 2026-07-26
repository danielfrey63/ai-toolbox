#!/usr/bin/env bash
# Idempotent installer for the two-stage CPU temperature watchdog.
# Desired state: script in ~/.local/bin, machine-local config present (seeded
# once, never overwritten — it holds priorities and credentials), systemd user
# units installed, timer enabled. Re-runs and partial re-runs are always safe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/cpu-watchdog.sh"
CONF_DIR="$HOME/.config/cpu-watchdog"
UNIT_DIR="$HOME/.config/systemd/user"

install -D -m 755 "$HERE/cpu-watchdog.sh" "$BIN"

mkdir -p "$CONF_DIR"
[ -e "$CONF_DIR/stop-list.conf" ] || install -m 644 "$HERE/stop-list.conf" "$CONF_DIR/stop-list.conf"
[ -e "$CONF_DIR/smtp.env" ] || install -m 600 "$HERE/smtp.env.template" "$CONF_DIR/smtp.env"

install -D -m 644 "$HERE/cpu-watchdog.service" "$UNIT_DIR/cpu-watchdog.service"
install -D -m 644 "$HERE/cpu-watchdog.timer" "$UNIT_DIR/cpu-watchdog.timer"
systemctl --user daemon-reload
systemctl --user enable --now cpu-watchdog.timer

echo "cpu-watchdog installiert — Timer aktiv. Kanaltest: $BIN test-notify"
