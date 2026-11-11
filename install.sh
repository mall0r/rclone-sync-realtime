#!/usr/bin/env bash
#
# Install the real-time rclone sync watcher as a systemd user service.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SYNC_DIR="${SYNC_DIR:-$HOME/SyncDrive}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
KEEP_BACKUPS="${KEEP_BACKUPS:-4}"
LOG_FILE="${LOG_FILE:-$HOME/.local/share/rclone-sync-realtime.log}"
DEBOUNCE="${DEBOUNCE:-10}"
START_SERVICE=1

UNIT_NAME="rclone-sync-realtime.service"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
SYNC_SCRIPT="$BIN_DIR/rclone-sync-realtime.sh"
BACKUP_ROOT=""

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage: ./install.sh --remote REMOTE:PATH [options]

Options:
  --remote REMOTE:PATH  rclone destination (required), e.g. "gdrive:SyncDrive"
  --sync-dir DIR        Local folder to watch (default: ~/SyncDrive)
  --keep N              Number of backup versions to keep (default: 4)
  --log-file FILE       Log file
                        (default: ~/.local/share/rclone-sync-realtime.log)
  --debounce N          Seconds to wait after a change (default: 10)
  --no-start            Install and enable, but do not start the service now
  -h, --help            Show this help

The same settings can be provided as environment variables:
RCLONE_REMOTE, SYNC_DIR, KEEP_BACKUPS, LOG_FILE, DEBOUNCE.
EOF
}

expand_path() {
    case "$1" in
        "~")   printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${1#~/}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)     RCLONE_REMOTE="$2"; shift 2 ;;
        --sync-dir)   SYNC_DIR="$2"; shift 2 ;;
        --keep)       KEEP_BACKUPS="$2"; shift 2 ;;
        --log-file)   LOG_FILE="$2"; shift 2 ;;
        --debounce)   DEBOUNCE="$2"; shift 2 ;;
        --no-start)   START_SERVICE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1 (use --help)" ;;
    esac
done

SYNC_DIR="$(expand_path "$SYNC_DIR")"
LOG_FILE="$(expand_path "$LOG_FILE")"

if [[ $(id -u) -eq 0 ]]; then
    die "run as your normal user, not as root (this installs systemd --user units)"
fi

command -v systemctl    >/dev/null || die "systemd (systemctl) is required"
command -v rclone       >/dev/null || die "rclone not found; install rclone first"
command -v inotifywait  >/dev/null || die "inotifywait not found; install inotify-tools"

[[ -n "$RCLONE_REMOTE" ]] || \
    die "--remote is required, e.g. --remote 'gdrive:SyncDrive'"
[[ "$RCLONE_REMOTE" == *:* ]] || \
    die "invalid remote '$RCLONE_REMOTE'; expected REMOTE:PATH"
[[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"
[[ "$DEBOUNCE" =~ ^[0-9]+$ ]] || die "--debounce must be a non-negative integer"

remote="${RCLONE_REMOTE%%:*}"
rclone listremotes 2>/dev/null | grep -qxF "${remote}:" || \
    die "rclone remote '${remote}:' not found; run 'rclone config' first or use --remote"

BACKUP_ROOT="${RCLONE_REMOTE}/.backup"

render() {
    local src="$1" dst="$2"
    if [[ -f "$dst" ]]; then
        cp -a "$dst" "$dst.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    sed \
        -e "s|@SYNC_DIR@|$SYNC_DIR|g" \
        -e "s|@RCLONE_REMOTE@|$RCLONE_REMOTE|g" \
        -e "s|@BACKUP_ROOT@|$BACKUP_ROOT|g" \
        -e "s|@KEEP_BACKUPS@|$KEEP_BACKUPS|g" \
        -e "s|@LOG_FILE@|$LOG_FILE|g" \
        -e "s|@DEBOUNCE@|$DEBOUNCE|g" \
        -e "s|@SCRIPT_PATH@|$SYNC_SCRIPT|g" \
        "$src" > "$dst"
}

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

cat <<EOF

Installation complete.

  Watched folder : $SYNC_DIR
  rclone remote  : $RCLONE_REMOTE
  Backup root    : $BACKUP_ROOT
  Keep versions  : $KEEP_BACKUPS
  Log file       : $LOG_FILE

  Service        : systemctl --user status rclone-sync-realtime
  Service log    : journalctl --user -u rclone-sync-realtime -f
  Sync log       : tail -f $LOG_FILE

EOF
