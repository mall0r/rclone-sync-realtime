#!/usr/bin/env bash
#
# Remove the systemd user service, the system shutdown/sleep hooks and the
# script installed by install.sh. Watched data, logs and the rclone
# configuration are kept.
#
set -uo pipefail

UNIT_NAME="rclone-sync-realtime.service"
UNIT_DIR="$HOME/.config/systemd/user"
SYNC_SCRIPT="$HOME/.local/bin/rclone-sync-realtime.sh"

SYSTEM_UNIT_NAME="rclone-sync-shutdown.service"
SYSTEM_UNIT_PATH="/etc/systemd/system/$SYSTEM_UNIT_NAME"
SLEEP_HOOK_PATH="/etc/systemd/system-sleep/rclone-sync-realtime"

systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true

rm -f "$UNIT_DIR/$UNIT_NAME" "$SYNC_SCRIPT"

systemctl --user daemon-reload 2>/dev/null || true

if [[ -f "$SYSTEM_UNIT_PATH" || -f "$SLEEP_HOOK_PATH" ]]; then
    if command -v sudo >/dev/null 2>&1; then
        sudo systemctl disable --now "$SYSTEM_UNIT_NAME" 2>/dev/null || true
        sudo rm -f "$SYSTEM_UNIT_PATH" "$SLEEP_HOOK_PATH"
        sudo systemctl daemon-reload 2>/dev/null || true
    else
        echo "warning: sudo not found; remove manually:" >&2
        echo "  $SYSTEM_UNIT_PATH" >&2
        echo "  $SLEEP_HOOK_PATH" >&2
    fi
fi

echo "Service, hooks and script removed."
echo "Kept untouched: watched data, logs and rclone configuration."
