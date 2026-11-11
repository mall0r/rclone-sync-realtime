#!/usr/bin/env bash
#
# Sync a local folder to an rclone remote on a fixed interval, keeping
# versioned backups. Every top-level entry of the local folder gets its own
# backup namespace and every version is a FULL snapshot of that entry, so any
# file can be recovered from any version - even files that did not change in
# that particular sync. Only the newest N versions of each entry are kept.
#
# Modes:
#   (default)  sync immediately, then every INTERVAL seconds
#   --once     run a single sync and exit (used by shutdown/sleep hooks)
#
# The sync itself only transfers files whose content changed: with CHECKSUM=1
# rclone compares content hashes; with CHECKSUM=0 it compares size + modtime
# (rclone's default). Unchanged files are never uploaded again.
#
# Environment variables:
#   SYNC_DIR       local directory to sync                 (default: $HOME/SyncDrive)
#   RCLONE_REMOTE  rclone destination remote:path          (required)
#   BACKUP_ROOT    remote directory for backup versions    (default: $RCLONE_REMOTE/.backup)
#   KEEP_BACKUPS   versions kept PER top-level entry       (default: 4)
#   LOG_FILE       log file                                (default: $HOME/.local/share/rclone-sync-realtime.log)
#   INTERVAL       seconds between syncs                   (default: 300)
#   CHECKSUM       1 = compare content hashes, 0 = size+mtime (default: 1)
#   LOCK_FILE      lock file                               (default: next to LOG_FILE)
#   LOCK_WAIT      seconds to wait for the lock             (default: 120)
#   PARTIAL_STATE  file with incomplete snapshots to purge  (default: next to LOG_FILE)
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
PARTIAL_STATE="${PARTIAL_STATE:-$(dirname "$LOG_FILE")/rclone-sync-realtime.partials}"
ONCE=0

# Junk that must never be synced or stored in a backup. The patterns have no
# slash, so rclone matches the file name at any depth. "._*" covers all
# AppleDouble files, including "._.DS_Store".
EXCLUDE_ARGS=(--exclude ".DS_Store" --exclude "._*")

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

CHECKSUM_ARGS=()
(( CHECKSUM == 1 )) && CHECKSUM_ARGS=(--checksum)

# Include hidden entries in globs, and expand to nothing when a glob is empty.
shopt -s dotglob nullglob

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

# Top-level entries of SYNC_DIR that must be synced. ".backup" is reserved for
# the remote backup root, and junk files are ignored.
local_entries() {
    local path name
    for path in "$SYNC_DIR"/*; do
        name="${path##*/}"
        case "$name" in
            .backup|.DS_Store|._*) continue ;;
        esac
        printf '%s\n' "$name"
    done
}

# Signature of a remote path (path, size and modification time of every file).
# Comparing the signature before/after a sync tells whether anything changed.
remote_signature() {
    rclone lsf "$1" --recursive --files-only --format "pst" 2>/dev/null | LC_ALL=C sort
}

# Timestamp directories of one backup namespace, newest first.
list_versions() {
    rclone lsf "$BACKUP_ROOT/$1" --dirs-only --max-depth 1 2>/dev/null \
        | sed 's:/$::' \
        | grep -E '^[0-9]{8}-[0-9]{6}$' \
        | sort -r
}

prune_backups() {
    local ns="$1"
    local -a versions=()
    mapfile -t versions < <(list_versions "$ns")

    (( ${#versions[@]} > KEEP_BACKUPS )) || return 0

    local old
    for old in "${versions[@]:KEEP_BACKUPS}"; do
        log "pruning old backup: $ns/$old"
        # Delete permanently instead of moving to the remote's trash, so the
        # space is freed immediately and the trash does not grow forever.
        rclone purge "$BACKUP_ROOT/$ns/$old" --drive-use-trash=false >>"$LOG_FILE" 2>&1 \
            || log "failed to prune backup: $ns/$old"
    done
}

# Purge a version directory that could not be completed. Leaving it behind
# would make list_versions believe the entry already has a version (blocking
# the baseline/retry) and could push a good version out during pruning.
# If the purge itself fails (e.g. the remote is unreachable), the removal is
# recorded and retried at the start of the next run.
discard_partial_snapshot() {
    local ns="$1" stamp="$2"
    log "removing incomplete snapshot: $ns/$stamp"
    if ! rclone purge "$BACKUP_ROOT/$ns/$stamp" --drive-use-trash=false >>"$LOG_FILE" 2>&1; then
        log "failed to remove incomplete snapshot: $ns/$stamp (will retry on the next run)"
        printf '%s/%s\n' "$ns" "$stamp" >>"$PARTIAL_STATE"
    fi
}

# Retry removals of incomplete snapshots that could not be purged before.
retry_pending_purges() {
    [[ -s "$PARTIAL_STATE" ]] || return 0

    local -a pending=() remaining=()
    local entry ns stamp dirs listing
    mapfile -t pending < <(sort -u "$PARTIAL_STATE")

    # If the remote cannot be listed at all, keep every pending entry for the
    # next run. An empty listing here means "unavailable", not "already gone".
    if ! dirs="$(rclone lsf "$BACKUP_ROOT" --dirs-only --max-depth 1 2>/dev/null)"; then
        # The backup root itself may have been removed: if the remote root is
        # reachable and has no .backup entry, there is nothing left to purge.
        local root_entries
        if root_entries="$(rclone lsf "$RCLONE_REMOTE" --max-depth 1 2>/dev/null)" \
                && ! grep -qxF ".backup/" <<<"$root_entries"; then
            log "$BACKUP_ROOT does not exist: discarding pending removals"
            : >"$PARTIAL_STATE"
            return 0
        fi
        log "cannot list $BACKUP_ROOT: keeping incomplete snapshots for the next run"
        return 0
    fi

    for entry in "${pending[@]}"; do
        [[ "$entry" == */* ]] || continue
        ns="${entry%%/*}"
        stamp="${entry##*/}"

        # The whole namespace is gone, so the partial version is gone too.
        grep -qxF "$ns/" <<<"$dirs" || continue

        # Distinguish "version no longer exists" from "listing failed": on a
        # listing error the entry must stay pending.
        if ! listing="$(rclone lsf "$BACKUP_ROOT/$ns" --dirs-only --max-depth 1 2>/dev/null)"; then
            log "failed to list $BACKUP_ROOT/$ns: keeping pending removal for $entry"
            remaining+=("$entry")
            continue
        fi
        grep -qxF "$stamp/" <<<"$listing" || continue

        log "retrying removal of incomplete snapshot: $entry"
        if ! rclone purge "$BACKUP_ROOT/$ns/$stamp" --drive-use-trash=false >>"$LOG_FILE" 2>&1; then
            log "failed to remove incomplete snapshot: $entry"
            remaining+=("$entry")
        fi
    done

    if (( ${#remaining[@]} )); then
        printf '%s\n' "${remaining[@]}" >"$PARTIAL_STATE"
    else
        : >"$PARTIAL_STATE"
    fi
}

# Copy the current state of one entry into a new full version.
snapshot_entry() {
    local ns="$1" stamp="$2"
    local src="$SYNC_DIR/$ns" dst="$RCLONE_REMOTE/$ns"
    local backup="$BACKUP_ROOT/$ns/$stamp"

    log "snapshot: $ns/$stamp"
    if [[ -d "$src" ]]; then
        # Same remote on both sides: rclone copies server-side (no bandwidth).
        rclone copy "$dst" "$backup" \
            --create-empty-src-dirs -v "${EXCLUDE_ARGS[@]}" >>"$LOG_FILE" 2>&1 \
            || { log "snapshot failed for $ns"; discard_partial_snapshot "$ns" "$stamp"; return 1; }
    else
        rclone copyto "$dst" "$backup/$ns" \
            -v >>"$LOG_FILE" 2>&1 \
            || { log "snapshot failed for $ns"; discard_partial_snapshot "$ns" "$stamp"; return 1; }
    fi
}

# Sync one top-level entry and, when its content changed (or when it has no
# version yet), store a full snapshot of the new state in its own namespace.
sync_entry() {
    local ns="$1" stamp="$2"
    local src="$SYNC_DIR/$ns" dst="$RCLONE_REMOTE/$ns"
    local before after rc=0
    local -a versions=()

    before="$(remote_signature "$dst")"

    if [[ -d "$src" ]]; then
        rclone sync "$src" "$dst" \
            --create-empty-src-dirs \
            --delete-excluded \
            --transfers 4 -v \
            "${CHECKSUM_ARGS[@]}" "${EXCLUDE_ARGS[@]}" >>"$LOG_FILE" 2>&1
    else
        rclone copyto "$src" "$dst" \
            --transfers 4 -v \
            "${CHECKSUM_ARGS[@]}" >>"$LOG_FILE" 2>&1
    fi
    rc=$?

    if (( rc != 0 )); then
        log "sync failed for $ns (exit $rc)"
        return 1
    fi

    after="$(remote_signature "$dst")"

    # A version is created when the remote content changed, and always for an
    # entry that has no version yet (baseline snapshot).
    mapfile -t versions < <(list_versions "$ns")
    if [[ "$before" != "$after" ]] || (( ${#versions[@]} == 0 )); then
        snapshot_entry "$ns" "$stamp" || return 1
    fi

    return 0
}

# Remove remote top-level entries that no longer exist locally (files or
# directories deleted locally), keeping the backup namespace intact.
delete_remote_extras() {
    local -A present=()
    local -a remote_entries=()
    local raw name is_dir rc=0

    for name in "$@"; do
        present["$name"]=1
    done

    # Directories are listed with a trailing slash; keep it to tell them
    # apart from loose files (purge only works on directories).
    mapfile -t remote_entries < <(
        rclone lsf "$RCLONE_REMOTE" --max-depth 1 2>/dev/null
    )

    for raw in "${remote_entries[@]}"; do
        name="${raw%/}"
        is_dir=0
        [[ "$raw" == */ ]] && is_dir=1
        [[ "$name" == ".backup" ]] && continue
        [[ -n "${present[$name]:-}" ]] && continue

        log "removing remote entry not present locally: $name"
        if (( is_dir )); then
            rclone purge "$RCLONE_REMOTE/$name" --drive-use-trash=false >>"$LOG_FILE" 2>&1 \
                || { log "failed to remove remote entry: $name"; rc=1; }
        else
            rclone deletefile "$RCLONE_REMOTE/$name" --drive-use-trash=false >>"$LOG_FILE" 2>&1 \
                || { log "failed to remove remote entry: $name"; rc=1; }
        fi
    done

    return "$rc"
}

do_sync() {
    local stamp rc=0 name
    local -a names=()

    stamp="$(date +%Y%m%d-%H%M%S)"
    log "sync started (backup=$stamp)"

    mapfile -t names < <(local_entries)

    # Safety net: an empty SYNC_DIR is much more likely to be an unmounted
    # disk than an intentional wipe, so never delete the remote contents then.
    if (( ${#names[@]} == 0 )); then
        log "sync directory has no entries: skipping (remote left untouched)"
        log "sync finished"
        return 0
    fi

    # Finish any removal of incomplete snapshots left from a failed run before
    # checking which entries already have a version.
    retry_pending_purges

    for name in "${names[@]}"; do
        sync_entry "$name" "$stamp" || rc=1
    done

    delete_remote_extras "${names[@]}" || rc=1

    for name in "${names[@]}"; do
        prune_backups "$name"
    done

    if (( rc == 0 )); then
        log "sync finished"
    else
        log "sync finished with errors"
    fi

    return "$rc"
}

sync_now() {
    local rc
    exec 9>"$LOCK_FILE" || { log "cannot open lock file: $LOCK_FILE"; return 1; }

    # Serialize the periodic sync and on-demand (--once) syncs. The lock is
    # held only while syncing, never while sleeping.
    if ! flock -w "$LOCK_WAIT" 9; then
        log "sync skipped (another sync is running)"
        exec 9>&-
        return 75
    fi

    do_sync
    rc=$?

    flock -u 9 2>/dev/null || true
    exec 9>&-
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
