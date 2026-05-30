# Nextcloud

Self-hosted file sync and share platform (LXC container via NextcloudPi).

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the LXC container and installs NextcloudPi. |
| `update.sh` | Updates packages and runs NextcloudPi/Nextcloud upgrade. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```
