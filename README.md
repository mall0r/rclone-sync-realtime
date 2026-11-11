# rclone-sync-realtime

Real-time, versioned cloud backup of any local folder using
[rclone](https://rclone.org/) and inotify.

Whenever a file in the watched folder changes, the service syncs the folder to
any rclone remote and keeps a timestamped copy of every file that was
overwritten or deleted. Only the newest N backup versions are kept.

Typical use cases: game savegames, documents, project folders — anything you
want mirrored to Google Drive, Backblaze B2, S3, Dropbox, OneDrive, etc.

## Features

- **Real-time**: reacts to file changes via inotify (with a debounce)
- **Provider-agnostic**: works with any rclone remote (`remote:path`)
- **Versioned backups**: `--backup-dir` keeps overwritten/deleted files
- **Retention**: keeps only the newest N versions (default: 4)
- **Safe pruning**: only directories named `YYYYMMDD-HHMMSS` are removed
- **systemd user service**: starts at boot, restarts on failure, no root needed
- **Portable installer**: `install.sh` / `uninstall.sh`

## Requirements

- Linux with systemd
- [rclone](https://rclone.org/)
- [inotify-tools](https://github.com/inotify-tools/inotify-tools) (`inotifywait`)

### Install dependencies

```bash
# Arch / CachyOS / Manjaro
sudo pacman -S rclone inotify-tools

# Debian / Ubuntu
sudo apt install rclone inotify-tools

# Fedora
sudo dnf install rclone inotify-tools
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

This watches `~/SyncDrive` and syncs it to `Gdrive:SyncDrive`.

To watch a different folder or use another remote:

```bash
./install.sh \
  --sync-dir "$HOME/GameSaves" \
  --remote "Gdrive:Backups/GameSaves" \
  --keep 4
```

### 3. Check the service

```bash
systemctl --user status rclone-sync-realtime
tail -f ~/.local/share/rclone-sync-realtime.log
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--remote REMOTE:PATH` | *(required)* | rclone destination |
| `--sync-dir DIR` | `~/SyncDrive` | Local folder to watch |
| `--keep N` | `4` | Number of backup versions to keep |
| `--log-file FILE` | `~/.local/share/rclone-sync-realtime.log` | Log file |
| `--debounce N` | `10` | Seconds to wait after a change before syncing |
| `--no-start` | — | Install and enable, but do not start now |
| `-h, --help` | — | Show help |

The same settings can be provided as environment variables: `RCLONE_REMOTE`,
`SYNC_DIR`, `KEEP_BACKUPS`, `LOG_FILE`, `DEBOUNCE`.

If a unit with the same name already exists, it is backed up as
`rclone-sync-realtime.service.bak.<timestamp>` before being replaced.

## How the versioned backups work

For every sync, rclone moves files that would be overwritten or deleted into a
timestamped folder under `.backup`:

```
remote:Backups/GameSaves/                         current files
remote:Backups/GameSaves/.backup/20261111-120000/ files changed by that sync
remote:Backups/GameSaves/.backup/20261111-121500/
...
```

After each sync the script lists the backup folders, sorts them by name
(newest first) and purges everything past the newest `--keep`. Only directories
matching `YYYYMMDD-HHMMSS` are candidates, so unrelated folders are never
touched.

A backup folder is created only when a sync actually overwrites or deletes a
file. If nothing changes, no new version appears.

## Managing the service

```bash
systemctl --user status rclone-sync-realtime     # state
systemctl --user restart rclone-sync-realtime    # restart
systemctl --user stop rclone-sync-realtime       # stop
journalctl --user -u rclone-sync-realtime -f     # live service log
tail -f ~/.local/share/rclone-sync-realtime.log  # sync log
```

`install.sh` enables lingering (`loginctl enable-linger`) so the user service
starts at boot without a login session.

## Troubleshooting

- **Authentication expired:** reconnect the remote, e.g.
  `rclone config reconnect Gdrive:`. Google Drive OAuth clients in
  "Testing" mode on Google Cloud expire refresh tokens after 7 days; publish
  the OAuth app to production or use a remote with static credentials
  (Backblaze B2, S3, etc.).
- **`inotifywait: command not found`:** install `inotify-tools`.
- **Remote not found:** `rclone listremotes` must show the remote used in
  `--remote`. Run `rclone config`.
- **The service keeps restarting:** check
  `journalctl --user -u rclone-sync-realtime -n 50`.
- **Nothing is syncing:** the watcher only triggers on filesystem events; make
  sure the folder path exists and is the one being written to.

## Uninstall

```bash
./uninstall.sh
```

This removes the systemd unit and the installed script. Watched data, logs and
the rclone configuration are kept.

## Privacy

This is self-hosted software. No data is sent to the project maintainers. Data
goes only to the rclone remote you configure. See [PRIVACY.md](PRIVACY.md).

## License

MIT — see [LICENSE](LICENSE).
