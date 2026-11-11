#!/usr/bin/env bash
#
# Watch a local folder and sync it to an rclone remote, keeping versioned
# backups of changed/deleted files and retaining only the newest N versions.
#
# Environment variables:
#   SYNC_DIR       local directory to watch              (default: $HOME/SyncDrive)
#   RCLONE_REMOTE  rclone destination remote:path       (required)
#   BACKUP_ROOT    remote directory for backup versions (default: $RCLONE_REMOTE/.backup)
#   KEEP_BACKUPS   number of backup directories to keep (default: 4)
#   LOG_FILE       log file                             (default: $HOME/.local/share/rclone-sync-realtime.log)
#   DEBOUNCE       seconds to wait after a change       (default: 10)
#
set -uo pipefail

SYNC_DIR="${SYNC_DIR:-$HOME/SyncDrive}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
BACKUP_ROOT="${BACKUP_ROOT:-${RCLONE_REMOTE:+$RCLONE_REMOTE/.backup}}"
KEEP_BACKUPS="${KEEP_BACKUPS:-4}"
LOG_FILE="${LOG_FILE:-$HOME/.local/share/rclone-sync-realtime.log}"
DEBOUNCE="${DEBOUNCE:-10}"

[[ -n "$RCLONE_REMOTE" ]] || { echo "RCLONE_REMOTE is required (remote:path)" >&2; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo "rclone not found" >&2; exit 1; }
command -v inotifywait >/dev/null 2>&1 || { echo "inotifywait not found (install inotify-tools)" >&2; exit 1; }
[[ -d "$SYNC_DIR" ]] || { echo "sync directory not found: $SYNC_DIR" >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || { echo "KEEP_BACKUPS must be a positive integer" >&2; exit 1; }
[[ "$DEBOUNCE" =~ ^[0-9]+$ ]] || { echo "DEBOUNCE must be a non-negative integer" >&2; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

log "=== watcher started (dir=$SYNC_DIR remote=$RCLONE_REMOTE keep=$KEEP_BACKUPS) ==="

prune_backups() {
    local dirs=()
    # Only timestamp directories created by this script are candidates.
    mapfile -t dirs < <(
        rclone lsf "$BACKUP_ROOT" --dirs-only --max-depth 1 2>/dev/null \
            | sed 's:/$::' \
            | grep -E '^[0-9]{8}-[0-9]{6}$' \
            | sort -r
    )

    (( ${#dirs[@]} > KEEP_BACKUPS )) || return 0

    local old
    for old in "${dirs[@]:KEEP_BACKUPS}"; do
        log "pruning old backup: $old"
        rclone purge "$BACKUP_ROOT/$old" >>"$LOG_FILE" 2>&1 \
            || log "failed to prune backup: $old"
    done
}

sync_now() {
    local stamp rc
    stamp="$(date +%Y%m%d-%H%M%S)"
    log "sync started (backup=$stamp)"

    rclone sync "$SYNC_DIR" "$RCLONE_REMOTE" \
        --exclude ".backup/**" \
        --backup-dir "$BACKUP_ROOT/$stamp" \
        --create-empty-src-dirs \
        --transfers 4 -v >>"$LOG_FILE" 2>&1
    rc=$?

    if (( rc == 0 )); then
        log "sync finished"
    else
        log "sync failed (exit $rc)"
    fi

    prune_backups
}

sync_now

while true; do
    if ! inotifywait -r -q -e close_write,moved_to,moved_from,delete,create "$SYNC_DIR"; then
        sleep 5
        continue
    fi
    sleep "$DEBOUNCE"
    sync_now
done
