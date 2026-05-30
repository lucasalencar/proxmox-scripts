# Nextcloud

Self-hosted file sync and share platform (LXC container via NextcloudPi).

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the LXC container and installs NextcloudPi. |
| `update.sh` | Updates packages and runs NextcloudPi/Nextcloud upgrade. |

## Caddy compatibility

| Port | Protocol | Service     |
|------|----------|-------------|
| 80   | HTTP     | Apache/NCP  |
| 443  | HTTPS    | Apache/NCP  |

Nextcloud is auto-detected by `caddy/generate-caddyfile.sh`. Run it after install to add a reverse proxy entry.

## Execution order

```
install.sh
caddy/generate-caddyfile.sh   (optional, for reverse proxy)
caddy/trust-nextcloud.sh      (optional, configures Nextcloud to trust Caddy)
caddy/trust-nextcloud-restore.sh (undo trust-nextcloud.sh changes)
update.sh                      (run any time to upgrade)
```
