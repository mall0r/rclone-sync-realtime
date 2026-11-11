# rclone-sync-realtime

Periodic, versioned cloud backup of any local folder using
[rclone](https://rclone.org/).

The service syncs a folder to any rclone remote on a fixed interval (5 minutes
by default), immediately when it starts, and again right before the system
shuts down, reboots or suspends. Shutdown and suspend wait for that final sync
to finish. Every sync keeps a timestamped copy of the files that were
overwritten or deleted, and only the newest N versions are retained.

Typical use cases: game savegames, documents, project folders — anything you
want mirrored to Google Drive, Backblaze B2, S3, Dropbox, OneDrive, etc.

## Features

- **Periodic sync**: immediately on start, then every `--interval` seconds
  (default: 300 s)
- **Sync on stop**: `systemctl stop` runs a final sync before exiting
- **Sync before shutdown/reboot/suspend**: system hooks run a final sync and
  block the action until it finishes
- **Only changed files are transferred**: unchanged files are never uploaded
  (content hashes with `--checksum` by default)
- **Provider-agnostic**: works with any rclone remote (`remote:path`)
- **Versioned backups**: `--backup-dir` keeps overwritten/deleted files
- **Retention**: keeps only the newest N versions (default: 4)
- **Safe pruning**: only directories named `YYYYMMDD-HHMMSS` are removed
- **systemd user service**: starts at boot, restarts on failure, no root needed
  for the sync itself
- **Portable installer**: `install.sh` / `uninstall.sh`

## Requirements

- Linux with systemd
- [rclone](https://rclone.org/)
- util-linux (`flock`, and `setpriv` for the suspend hook)
- `sudo` only to install the shutdown/suspend hooks (optional)

### Install dependencies

```bash
# Arch / CachyOS / Manjaro
sudo pacman -S rclone util-linux

# Debian / Ubuntu
sudo apt install rclone util-linux

# Fedora
sudo dnf install rclone util-linux
```

## Quick start

### 1. Configure the rclone remote

```bash
rclone config
rclone listremotes        # e.g. Gdrive:
```

On a headless machine (no browser), follow
<https://rclone.org/remote_setup/>.

### 2. Clone and install

```bash
git clone https://github.com/<your-user>/rclone-sync-realtime.git
cd rclone-sync-realtime
./install.sh --remote "Gdrive:SyncDrive"
```

This syncs `~/SyncDrive` to `Gdrive:SyncDrive` every 5 minutes.

To use another folder, remote or interval:

```bash
./install.sh \
  --sync-dir "$HOME/GameSaves" \
  --remote "Gdrive:Backups/GameSaves" \
  --keep 4 \
  --interval 300
```

### 3. Check the service

```bash
systemctl --user status rclone-sync-realtime
tail -f ~/.local/share/rclone-sync-realtime.log
sudo systemctl status rclone-sync-shutdown
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--remote REMOTE:PATH` | *(required)* | rclone destination |
| `--sync-dir DIR` | `~/SyncDrive` | Local folder to sync |
| `--keep N` | `4` | Number of backup versions to keep |
| `--interval N` | `300` | Seconds between syncs |
| `--log-file FILE` | `~/.local/share/rclone-sync-realtime.log` | Log file |
| `--checksum` | enabled | Compare content hashes (only real changes are uploaded) |
| `--no-checksum` | — | Compare size + mtime instead (rclone default) |
| `--before-unit UNIT` | — | Stop the sync service after `UNIT` on shutdown, so `UNIT`'s final save is included |
| `--no-system-hooks` | — | Do not install the shutdown/suspend hooks |
| `--no-start` | — | Install and enable, but do not start now |
| `-h, --help` | — | Show help |

The same settings can be provided as environment variables: `RCLONE_REMOTE`,
`SYNC_DIR`, `KEEP_BACKUPS`, `LOG_FILE`, `INTERVAL`, `CHECKSUM`, `BEFORE_UNIT`.

If a unit with the same name already exists, it is backed up as
`rclone-sync-realtime.service.bak.<timestamp>` before being replaced.

## Lifecycle

```
service start ──► sync immediately
                  │
                  ├── every INTERVAL ──► sync
                  │
systemctl stop ──► finish current sync ──► final sync ──► exit
shutdown/reboot ─► final sync (system unit) ──► power off
suspend/hibernate ─► final sync (sleep hook) ──► sleep
```

- The **user service** (`rclone-sync-realtime.service`) runs as you, with your
  rclone configuration. On `SIGTERM` it finishes the current sync and runs a
  final one before exiting.
- The **system unit** (`rclone-sync-shutdown.service`) runs on shutdown/reboot
  as your user. `ExecStop` runs the script in `--once` mode. It is ordered
  before the network goes down and `TimeoutStopSec=300` makes systemd wait for
  the sync (or for 5 minutes, whichever comes first).
- The **sleep hook** (`/etc/systemd/system-sleep/rclone-sync-realtime`) runs the
  same `--once` sync on `pre`. systemd does not continue entering suspend
  until every hook has finished.

`--before-unit` adds `Before=UNIT` to the user service. Units stop in reverse
start order, so the sync service stops *after* `UNIT`. Use it when `UNIT` writes
a final save on shutdown that must be included in the sync, e.g.:

```bash
./install.sh --remote "Gdrive:SyncDrive" --before-unit enshrouded-server.service
```

Forced shutdowns (`poweroff -f`, `reboot -f`, holding the power button) bypass
systemd hooks and cannot be blocked.

## Only changed files are transferred

`rclone sync` never uploads a file that is already identical on the remote:

- with `--checksum` (default here), it compares the **content hash** and
  uploads only when the content really changed;
- with `--no-checksum`, it compares **size + modification time** (rclone's
  default), so a file that was only "touched" may be re-uploaded.

Files removed locally are removed from the remote; the previous version is
kept in `.backup`. The cost of `--checksum` is that rclone reads and hashes the
local files on every sync, which is negligible for savegames and small folders.

## How the versioned backups work

For every sync, rclone moves files that would be overwritten or deleted into a
timestamped folder under `.backup`:

```
remote:Backups/GameSaves/                         current files
remote:Backups/GameSaves/.backup/20261111-120000/ files changed by that sync
remote:Backups/GameSaves/.backup/20261111-120500/
...
```

After each sync the script lists the backup folders, sorts them by name
(newest first) and purges everything past the newest `--keep`. Only directories
matching `YYYYMMDD-HHMMSS` are candidates, so unrelated folders are never
touched.

Pruned versions are deleted **permanently** on Google Drive
(`--drive-use-trash=false`), so the space is freed immediately instead of
staying in the Drive trash for 30 days.

A backup folder is created only when a sync actually overwrites or deletes a
file. If nothing changes, no new version appears. With the default 5-minute
interval and `--keep 4`, the history covers roughly 20 minutes of changes.

## Managing the service

```bash
systemctl --user status rclone-sync-realtime     # state
systemctl --user restart rclone-sync-realtime    # restart (final sync + start sync)
systemctl --user stop rclone-sync-realtime       # stop (final sync)
journalctl --user -u rclone-sync-realtime -f     # live service log
tail -f ~/.local/share/rclone-sync-realtime.log  # sync log

sudo systemctl status rclone-sync-shutdown       # shutdown hook
sudo journalctl -u rclone-sync-shutdown          # shutdown hook log
```

To run a sync manually:

```bash
SYNC_DIR="$HOME/SyncDrive" RCLONE_REMOTE="Gdrive:SyncDrive" \
  ~/.local/bin/rclone-sync-realtime.sh --once
```

`install.sh` enables lingering (`loginctl enable-linger`) so the user service
starts at boot without a login session.

## Troubleshooting

- **Authentication expired:** reconnect the remote, e.g.
  `rclone config reconnect Gdrive:`. Google Drive OAuth clients in
  "Testing" mode on Google Cloud expire refresh tokens after 7 days; publish
  the OAuth app to production or use a remote with static credentials
  (Backblaze B2, S3, etc.).
- **Remote not found:** `rclone listremotes` must show the remote used in
  `--remote`. Run `rclone config`.
- **The service keeps restarting:** check
  `journalctl --user -u rclone-sync-realtime -n 50`.
- **Shutdown does not wait:** make sure the system hooks were installed (no
  `--no-system-hooks`) and check `sudo systemctl status rclone-sync-shutdown`.
- **Suspend hook does not run:** verify the hook is executable:
  `ls -l /etc/systemd/system-sleep/rclone-sync-realtime`.
- **Final sync takes too long:** `TimeoutStopSec=300` caps the wait. Raise it
  in `/etc/systemd/system/rclone-sync-shutdown.service` if needed.

## Uninstall

```bash
./uninstall.sh
```

This removes the user service, the installed script and the system
shutdown/suspend hooks. Watched data, logs and the rclone configuration are
kept.

## Privacy

This is self-hosted software. No data is sent to the project maintainers. Data
goes only to the rclone remote you configure. See [PRIVACY.md](PRIVACY.md).

## License

MIT — see [LICENSE](LICENSE).
