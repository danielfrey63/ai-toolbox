#!/usr/bin/env bash
# Installs (or removes) the systemd user timer (3x daily) that trashes empty Claude Code sessions.
# Idempotent: re-running rewrites the units to the current definition.
# Modes: install (default) | --uninstall | --status (exit 0 = installed, 1 = not)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT=session-cleanup

case "${1:-install}" in
    --status)
        systemctl --user is-enabled "$UNIT.timer" >/dev/null 2>&1 && exit 0 || exit 1
        ;;
    --uninstall)
        if systemctl --user is-enabled "$UNIT.timer" >/dev/null 2>&1; then
            systemctl --user disable --now "$UNIT.timer" >/dev/null
        fi
        rm -f "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT.service"
        systemctl --user daemon-reload
        echo "Removed $UNIT timer."
        ;;
    install)
        mkdir -p "$UNIT_DIR"
        cat > "$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=Trash empty Claude Code sessions (ai-toolbox session-cleanup)

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash "$HERE/cleanup-sessions.sh"
EOF
        cat > "$UNIT_DIR/$UNIT.timer" <<EOF
[Unit]
Description=Daily Claude Code session cleanup (ai-toolbox)

[Timer]
OnCalendar=*-*-* 05:30:00
OnCalendar=*-*-* 11:30:00
OnCalendar=*-*-* 17:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now "$UNIT.timer" >/dev/null
        echo "Installed $UNIT timer (daily at 05:30, 11:30, 17:30, catch-up on missed runs)."
        ;;
    *)
        echo "usage: install.sh [--uninstall|--status]" >&2; exit 2
        ;;
esac
