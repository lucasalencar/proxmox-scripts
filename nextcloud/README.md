# Nextcloud

Self-hosted file sync and share platform (LXC container via NextcloudPi).

## Scripts

| Script | Description |
|---|---|---|
| `install.sh` | Creates the LXC container and installs NextcloudPi, then moves data to ZFS dataset on HDD. |
| `setup-storage.sh` | Moves the Nextcloud data directory to a ZFS dataset on the HDD (run standalone on existing installs). |
| `sync-users.sh` | Syncs server users from `.server_users` to Nextcloud. |
| `update.sh` | Updates packages and runs NextcloudPi/Nextcloud upgrade. |

## Caddy compatibility

| Port | Protocol | Service     |
|------|----------|-------------|
| 80   | HTTP     | Apache/NCP  |
| 443  | HTTPS    | Apache/NCP  |

Nextcloud is auto-detected by `caddy/generate-caddyfile.sh`. Run it after install to add a reverse proxy entry.

## Execution order

```
install.sh                      (creates container + moves data to HDD)
caddy/generate-caddyfile.sh     (optional, for reverse proxy)
caddy/trust-nextcloud.sh        (optional, configures Nextcloud to trust Caddy)
caddy/trust-nextcloud-restore.sh (undo trust-nextcloud.sh changes)
update.sh                        (run any time to upgrade)
```

`setup-storage.sh` is called automatically by `install.sh`. Run it manually only on existing installs. The data directory is moved to `tank/data/nextcloud` ZFS dataset on the HDD.
