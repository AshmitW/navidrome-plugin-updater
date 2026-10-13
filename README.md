# navidrome-plugin-updater

Updates Navidrome plugins (`.ndp`) to their newest GitHub release within the same major version, before Navidrome starts. New major versions are only logged, since they usually change settings; install those by hand and the script follows the new major from then on.

It runs while Navidrome is stopped because Navidrome disables any plugin whose file changed; the script re-enables updated plugins with the Navidrome CLI.

Requires `curl`, `jq`, `unzip` and Podman, with Navidrome 0.63+ running as a systemd service.

## Configuration

Copy `nd-plugin-update.env.example` to e.g. `~/.config/nd-plugin-update.env`.

| Variable | Default | |
|---|---|---|
| `NPU_DATA_DIR` | *(required)* | Navidrome's data folder (mounted at `/data`) |
| `NPU_PLUGINS` | `*` | Plugin IDs to auto-update, comma-separated, or `*` for all |
| `NPU_EXCLUDE` | | Plugin IDs to only check, never install (e.g. after a rollback) |
| `NPU_PLUGINS_DIR` | `$NPU_DATA_DIR/plugins` | |
| `NPU_BACKUP_DIR` | `$NPU_DATA_DIR/plugin-backups` | Replaced versions, for rollback |
| `NPU_KEEP_BACKUPS` | `3` | |
| `NPU_IMAGE` | `docker.io/deluan/navidrome:latest` | |

## Install

In `navidrome.container` under `[Service]`, then `systemctl --user daemon-reload`:

```ini
EnvironmentFile=%h/.config/nd-plugin-update.env
ExecStartPre=-/path/to/nd-plugin-update.sh
TimeoutStartSec=300
```

## Use

```bash
journalctl --user -u navidrome | grep nd-plugin-update   # what it did
./nd-plugin-update.sh --dry-run                          # needs the env vars set
```
