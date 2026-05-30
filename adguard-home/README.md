# AdGuard Home

DNS-level ad blocking and network-wide filtering.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the LXC container and installs AdGuard Home. |
| `setup-upstream.sh` | Configures upstream DNS servers via the AdGuard API. |
| `setup-dns.sh` | Sets up DNS rewrites for `*.marx.home` pointing to Caddy. |
| `update.sh` | Updates packages inside the container. |

## Execution order

```
install.sh  ──calls──► setup-upstream.sh
                       └── setup-dns.sh
update.sh   (run any time to upgrade)
```
