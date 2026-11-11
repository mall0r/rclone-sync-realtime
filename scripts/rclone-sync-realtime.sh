#!/usr/bin/env bash
#
# Sync a local folder to an rclone remote on a fixed interval, keeping
# versioned backups of changed/deleted files and retaining only the newest N.
#
# Modes:
#   (default)  sync immediately, then every INTERVAL seconds
#   --once     run a single sync and exit (used by shutdown/sleep hooks)
#
# Only files whose content changed are transferred: with CHECKSUM=1 rclone
# compares content hashes; with CHECKSUM=0 it compares size + modification
# time (rclone's default). Unchanged files are never uploaded.
#
# Environment variables:
#   SYNC_DIR       local directory to sync                 (default: $HOME/SyncDrive)
#   RCLONE_REMOTE  rclone destination remote:path          (required)
#   BACKUP_ROOT    remote directory for backup versions    (default: $RCLONE_REMOTE/.backup)
#   KEEP_BACKUPS   number of backup directories to keep    (default: 4)
#   LOG_FILE       log file                                (default: $HOME/.local/share/rclone-sync-realtime.log)
#   INTERVAL       seconds between syncs                   (default: 300)
#   CHECKSUM       1 = compare content hashes, 0 = size+mtime (default: 1)
#   LOCK_FILE      lock file                               (default: next to LOG_FILE)
#   LOCK_WAIT      seconds to wait for the lock             (default: 120)
#
set -uo pipefail

SYNC_DIR="${SYNC_DIR:-$HOME/SyncDrive}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
BACKUP_ROOT="${BACKUP_ROOT:-${RCLONE_REMOTE:+$RCLONE_REMOTE/.backup}}"
KEEP_BACKUPS="${KEEP_BACKUPS:-4}"
LOG_FILE="${LOG_FILE:-$HOME/.local/share/rclone-sync-realtime.log}"
INTERVAL="${INTERVAL:-300}"
CHECKSUM="${CHECKSUM:-1}"
LOCK_FILE="${LOCK_FILE:-$(dirname "$LOG_FILE")/rclone-sync-realtime.lock}"
LOCK_WAIT="${LOCK_WAIT:-120}"
ONCE=0

case "${1:-}" in
    --once) ONCE=1 ;;
    "")     ;;
    *)      echo "unknown option: $1 (use --once)" >&2; exit 2 ;;
esac

[[ -n "$RCLONE_REMOTE" ]] || { echo "RCLONE_REMOTE is required (remote:path)" >&2; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo "rclone not found" >&2; exit 1; }
command -v flock  >/dev/null 2>&1 || { echo "flock not found (install util-linux)" >&2; exit 1; }
[[ -d "$SYNC_DIR" ]] || { echo "sync directory not found: $SYNC_DIR" >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || { echo "KEEP_BACKUPS must be a positive integer" >&2; exit 1; }
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "INTERVAL must be a positive integer" >&2; exit 1; }
[[ "$CHECKSUM" =~ ^[01]$ ]] || { echo "CHECKSUM must be 0 or 1" >&2; exit 1; }
[[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || { echo "LOCK_WAIT must be a non-negative integer" >&2; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

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
        # Delete permanently instead of moving to the remote's trash, so the
        # space is freed immediately and the trash does not grow forever.
        rclone purge "$BACKUP_ROOT/$old" --drive-use-trash=false >>"$LOG_FILE" 2>&1 \
            || log "failed to prune backup: $old"
    done
}

sync_now() {
    local stamp rc
    stamp="$(date +%Y%m%d-%H%M%S)"
    log "sync started (backup=$stamp)"

    local -a args=(
        sync "$SYNC_DIR" "$RCLONE_REMOTE"
        --exclude ".backup/**"
        --backup-dir "$BACKUP_ROOT/$stamp"
        --create-empty-src-dirs
        --transfers 4 -v
    )
    (( CHECKSUM == 1 )) && args+=(--checksum)

    # Serialize the periodic sync and on-demand (--once) syncs. The lock is
    # held only for the duration of rclone, never while sleeping.
    (
        exec 9>"$LOCK_FILE"
        flock -w "$LOCK_WAIT" 9 || exit 75
        rclone "${args[@]}"
    ) >>"$LOG_FILE" 2>&1
    rc=$?

    if (( rc == 0 )); then
        log "sync finished"
        prune_backups
    elif (( rc == 75 )); then
        log "sync skipped (another sync is running)"
    else
        log "sync failed (exit $rc)"
    fi

    return "$rc"
}

if (( ONCE )); then
    log "=== single sync requested (--once) ==="
    sync_now
    exit $?
fi

log "=== service started (dir=$SYNC_DIR remote=$RCLONE_REMOTE keep=$KEEP_BACKUPS interval=${INTERVAL}s checksum=$CHECKSUM) ==="

STOP=0
on_stop() { STOP=1; }
trap on_stop TERM INT

# Initial sync. If the network is not up yet, retry a few times before
# settling into the regular interval.
attempt=0
until sync_now; do
    attempt=$((attempt + 1))
    (( attempt >= 10 )) && break
    log "initial sync failed; retrying in 30s (attempt $attempt/10)"
    sleep 30 & wait $! 2>/dev/null
    (( STOP )) && break
done

while (( ! STOP )); do
    # Background sleep + wait so SIGTERM interrupts the sleep immediately.
    sleep "$INTERVAL" & wait $! 2>/dev/null
    (( STOP )) && break
    sync_now
done

log "=== service stopping; running final sync ==="
sync_now
log "=== service stopped ==="
