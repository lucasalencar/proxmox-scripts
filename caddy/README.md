# Caddy

Reverse proxy (LXC container) serving all `*.marx.home` subdomains.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the LXC container and installs Caddy. |
| `update.sh` | Updates packages and upgrades the Caddy binary. |
| `generate-caddyfile.sh` | Scans guests, prompts for ports (one subdomain per port for multi-service guests), writes `Caddyfile.local`, and reloads Caddy. |
| `trust-haos.sh` | Injects Home Assistant `configuration.yaml` to trust Caddy as a reverse proxy. |
| `trust-haos-restore.sh` | Restores a previous HA `configuration.yaml` from backup. |
| `trust-nextcloud.sh` | Configures Nextcloud trusted_domains, trusted_proxies, and overwriteprotocol for Caddy. |
| `trust-nextcloud-restore.sh` | Restores a previous Nextcloud config.php from backup. |

## Execution order

```
install.sh
generate-caddyfile.sh   (after install or when guests change)
trust-haos.sh           (only for Home Assistant OS)
trust-nextcloud.sh      (only for Nextcloud)
trust-nextcloud-restore.sh (undo trust-nextcloud.sh changes)
update.sh               (run any time to upgrade)
```
