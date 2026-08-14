#!/usr/bin/env bash
# Idempotent installer for the three-stage CPU temperature watchdog.
# Desired state: script in ~/.local/bin, machine-local config present (seeded
# once, never overwritten — it holds priorities and credentials), systemd user
# units installed, timer enabled, root throttle helper + sudoers rule in
# place. Re-runs and partial re-runs are always safe.
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

# Root part: global throttle helper + sudoers whitelist for stage 3. Without
# it the watchdog degrades gracefully to warn + shed (stage 1/2 only).
if sudo -n true 2>/dev/null || [ -t 0 ]; then
  sudo install -D -m 755 "$HERE/cpu-throttle" /usr/local/sbin/cpu-throttle
  tmp=$(mktemp)
  sed "s/__USER__/$USER/" "$HERE/cpu-watchdog.sudoers" > "$tmp"
  visudo -c -q -f "$tmp"
  sudo install -m 440 -o root -g root "$tmp" /etc/sudoers.d/cpu-watchdog
  rm -f "$tmp"
  echo "cpu-throttle helper + sudoers rule installed (stage 3 active)"
else
  echo "WARN: sudo unavailable — stage 3 (cpu-throttle) not installed, watchdog runs warn+shed only" >&2
fi

echo "cpu-watchdog installiert — Timer aktiv. Kanaltest: $BIN test-notify"
