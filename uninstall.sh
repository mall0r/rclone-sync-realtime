#!/usr/bin/env bash
#
# Remove the systemd user service and script installed by install.sh.
# Watched data, logs and the rclone configuration are kept.
#
set -uo pipefail

UNIT_NAME="rclone-sync-realtime.service"
UNIT_DIR="$HOME/.config/systemd/user"
SYNC_SCRIPT="$HOME/.local/bin/rclone-sync-realtime.sh"

systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true

rm -f "$UNIT_DIR/$UNIT_NAME" "$SYNC_SCRIPT"

systemctl --user daemon-reload 2>/dev/null || true

echo "Service and script removed."
echo "Kept untouched: watched data, logs and rclone configuration."
