# CasaOS

Home server OS (LXC container) providing a web dashboard.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the LXC container, binds datasets (`/tank/data/*`), and applies ACLs. |
| `update.sh` | Updates packages and runs the CasaOS update script. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```
