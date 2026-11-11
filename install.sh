#!/usr/bin/env bash
#
# Install the periodic rclone sync as a systemd user service, plus (optionally)
# system shutdown/sleep hooks that run a final sync and block until it ends.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SYNC_DIR="${SYNC_DIR:-$HOME/SyncDrive}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
KEEP_BACKUPS="${KEEP_BACKUPS:-4}"
LOG_FILE="${LOG_FILE:-$HOME/.local/share/rclone-sync-realtime.log}"
INTERVAL="${INTERVAL:-300}"
CHECKSUM="${CHECKSUM:-1}"
BEFORE_UNIT="${BEFORE_UNIT:-}"
START_SERVICE=1
WITH_SYSTEM_HOOKS=1

UNIT_NAME="rclone-sync-realtime.service"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
SYNC_SCRIPT="$BIN_DIR/rclone-sync-realtime.sh"
BACKUP_ROOT=""

SYSTEM_UNIT_NAME="rclone-sync-shutdown.service"
SYSTEM_UNIT_PATH="/etc/systemd/system/$SYSTEM_UNIT_NAME"
SLEEP_HOOK_PATH="/etc/systemd/system-sleep/rclone-sync-realtime"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage: ./install.sh --remote REMOTE:PATH [options]

Options:
  --remote REMOTE:PATH  rclone destination (required), e.g. "Gdrive:SyncDrive"
  --sync-dir DIR        Local folder to sync (default: ~/SyncDrive)
  --keep N              Number of backup versions to keep (default: 4)
  --interval N          Seconds between syncs (default: 300)
  --log-file FILE       Log file
                        (default: ~/.local/share/rclone-sync-realtime.log)
  --checksum            Compare content hashes (default)
  --no-checksum         Compare size + mtime instead (rclone default)
  --before-unit UNIT    Stop this sync service after UNIT on shutdown, so
                        UNIT's final save is included (e.g. enshrouded-server.service)
  --no-system-hooks     Do not install the shutdown/sleep hooks (they need sudo)
  --no-start            Install and enable, but do not start the service now
  -h, --help            Show this help

The same settings can be provided as environment variables:
RCLONE_REMOTE, SYNC_DIR, KEEP_BACKUPS, LOG_FILE, INTERVAL, CHECKSUM, BEFORE_UNIT.

The sync runs immediately on start, then every --interval seconds. On stop it
runs a final sync. The system hooks (installed with sudo) also run a final sync
before shutdown/reboot/suspend and block until it finishes.
EOF
}

expand_path() {
    case "$1" in
        "~")   printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${1#~/}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

sed_escape() {
    printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)          RCLONE_REMOTE="$2"; shift 2 ;;
        --sync-dir)        SYNC_DIR="$2"; shift 2 ;;
        --keep)            KEEP_BACKUPS="$2"; shift 2 ;;
        --interval)        INTERVAL="$2"; shift 2 ;;
        --log-file)        LOG_FILE="$2"; shift 2 ;;
        --checksum)        CHECKSUM=1; shift ;;
        --no-checksum)     CHECKSUM=0; shift ;;
        --before-unit)     BEFORE_UNIT="$2"; shift 2 ;;
        --no-system-hooks) WITH_SYSTEM_HOOKS=0; shift ;;
        --no-start)        START_SERVICE=0; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "unknown option: $1 (use --help)" ;;
    esac
done

SYNC_DIR="$(expand_path "$SYNC_DIR")"
LOG_FILE="$(expand_path "$LOG_FILE")"

if [[ $(id -u) -eq 0 ]]; then
    die "run as your normal user, not as root (this installs systemd --user units)"
fi

command -v systemctl >/dev/null || die "systemd (systemctl) is required"
command -v rclone    >/dev/null || die "rclone not found; install rclone first"
command -v flock     >/dev/null || die "flock not found; install util-linux"

[[ -n "$RCLONE_REMOTE" ]] || \
    die "--remote is required, e.g. --remote 'Gdrive:SyncDrive'"
[[ "$RCLONE_REMOTE" == *:* ]] || \
    die "invalid remote '$RCLONE_REMOTE'; expected REMOTE:PATH"
[[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "--interval must be a positive integer"
[[ "$CHECKSUM" =~ ^[01]$ ]] || die "CHECKSUM must be 0 or 1"

remote="${RCLONE_REMOTE%%:*}"
rclone listremotes 2>/dev/null | grep -qxF "${remote}:" || \
    die "rclone remote '${remote}:' not found; run 'rclone config' first or use --remote"

if [[ "$WITH_SYSTEM_HOOKS" -eq 1 ]]; then
    command -v sudo    >/dev/null || die "sudo not found; use --no-system-hooks to skip the system hooks"
    command -v setpriv >/dev/null || die "setpriv not found (util-linux); use --no-system-hooks to skip"
    command -v timeout >/dev/null || die "timeout not found (coreutils); use --no-system-hooks to skip"
fi

BACKUP_ROOT="${RCLONE_REMOTE}/.backup"
UID_NUM="$(id -u)"
GID_NUM="$(id -g)"

render() {
    local src="$1" dst="$2"
    if [[ -f "$dst" ]]; then
        cp -a "$dst" "$dst.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    sed \
        -e "s|@SYNC_DIR@|$(sed_escape "$SYNC_DIR")|g" \
        -e "s|@RCLONE_REMOTE@|$(sed_escape "$RCLONE_REMOTE")|g" \
        -e "s|@BACKUP_ROOT@|$(sed_escape "$BACKUP_ROOT")|g" \
        -e "s|@KEEP_BACKUPS@|$(sed_escape "$KEEP_BACKUPS")|g" \
        -e "s|@LOG_FILE@|$(sed_escape "$LOG_FILE")|g" \
        -e "s|@INTERVAL@|$(sed_escape "$INTERVAL")|g" \
        -e "s|@CHECKSUM@|$(sed_escape "$CHECKSUM")|g" \
        -e "s|@BEFORE_UNIT@|$(sed_escape "$BEFORE_UNIT")|g" \
        -e "s|@USER@|$(sed_escape "$USER")|g" \
        -e "s|@HOME@|$(sed_escape "$HOME")|g" \
        -e "s|@UID@|$(sed_escape "$UID_NUM")|g" \
        -e "s|@GID@|$(sed_escape "$GID_NUM")|g" \
        -e "s|@SCRIPT_PATH@|$(sed_escape "$SYNC_SCRIPT")|g" \
        "$src" > "$dst"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "Creating directories"
mkdir -p "$UNIT_DIR" "$BIN_DIR" "$(dirname "$LOG_FILE")"
if [[ ! -d "$SYNC_DIR" ]]; then
    info "Creating sync directory $SYNC_DIR"
    mkdir -p "$SYNC_DIR"
fi

info "Installing sync script"
install -m 755 "$SCRIPT_DIR/scripts/rclone-sync-realtime.sh" "$SYNC_SCRIPT"

info "Installing $UNIT_NAME"
render "$SCRIPT_DIR/systemd/rclone-sync-realtime.service.in" "$UNIT_DIR/$UNIT_NAME"

if command -v loginctl >/dev/null; then
    if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        info "Enabling linger for $USER (service starts at boot without login)"
        loginctl enable-linger "$USER" 2>/dev/null || \
            warn "could not enable linger; run: sudo loginctl enable-linger $USER"
    fi
fi

systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME"

if [[ "$START_SERVICE" -eq 1 ]]; then
    info "Starting $UNIT_NAME"
    systemctl --user restart "$UNIT_NAME"
fi

if [[ "$WITH_SYSTEM_HOOKS" -eq 1 ]]; then
    info "Installing shutdown and suspend hooks (sudo required)"
    sudo -v

    render "$SCRIPT_DIR/systemd/rclone-sync-shutdown.service.in" \
           "$TMP_DIR/$SYSTEM_UNIT_NAME"
    render "$SCRIPT_DIR/systemd/system-sleep/rclone-sync-realtime.in" \
           "$TMP_DIR/rclone-sync-realtime"

    sudo install -m 644 "$TMP_DIR/$SYSTEM_UNIT_NAME" "$SYSTEM_UNIT_PATH"
    sudo mkdir -p "$(dirname "$SLEEP_HOOK_PATH")"
    sudo install -m 755 "$TMP_DIR/rclone-sync-realtime" "$SLEEP_HOOK_PATH"
    sudo systemctl daemon-reload
    sudo systemctl enable "$SYSTEM_UNIT_NAME"
    sudo systemctl start "$SYSTEM_UNIT_NAME"
fi

cat <<EOF

Installation complete.

  Synced folder  : $SYNC_DIR
  rclone remote  : $RCLONE_REMOTE
  Backup root    : $BACKUP_ROOT
  Keep versions  : $KEEP_BACKUPS
  Interval       : ${INTERVAL}s
  Checksum       : $([[ "$CHECKSUM" -eq 1 ]] && echo "yes (--checksum)" || echo "no (size+mtime)")
  Log file       : $LOG_FILE

  Service        : systemctl --user status rclone-sync-realtime
  Service log    : journalctl --user -u rclone-sync-realtime -f
  Sync log       : tail -f $LOG_FILE

EOF

if [[ -n "$BEFORE_UNIT" ]]; then
    cat <<EOF
  Stop order     : before $BEFORE_UNIT on shutdown

EOF
fi

if [[ "$WITH_SYSTEM_HOOKS" -eq 1 ]]; then
    cat <<EOF
  Shutdown hook  : sudo systemctl status rclone-sync-shutdown
  Suspend hook   : $SLEEP_HOOK_PATH

EOF
else
    cat <<EOF
  System hooks   : not installed (--no-system-hooks)
                   shutdown/suspend will NOT wait for the final sync

EOF
fi
