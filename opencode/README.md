# opencode

AI coding assistant CLI for the primary user.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Installs opencode for the current user and creates a system-wide symlink. |
| `update.sh` | Re-runs the installer (idempotent — same as `install.sh`). |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```
