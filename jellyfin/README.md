# Jellyfin

Media server (LXC container) for streaming movies and TV shows.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the LXC container, binds media datasets, and applies ACLs. |
| `update.sh` | Updates packages and upgrades Jellyfin components. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```
