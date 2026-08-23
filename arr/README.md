# ARR Stack

Media automation suite (Prowlarr, Sonarr, Radarr, Lidarr, Readarr, Bazarr, Whisparr, Seerr, qBittorrent, SABnzbd) deployed as Proxmox LXC containers.

The `install.sh` drives the community-scripts **ARR-Stack** installer (`community-scripts/ProxmoxVED`, currently beta). That installer creates **one LXC per selected app** (hostname = app slug), wires them together via their HTTP APIs, and writes `/root/arr-stack-summary.txt` on the PVE host with URLs, API keys and credentials.

After the installer finishes, `install.sh` discovers the created containers, maps each service user UID to the host (`+100000`), applies ZFS ACLs and bind-mounts the shared datasets into every container.

## Required datasets

| Dataset | Mounted at | Used by |
|---------|------------|---------|
| `/tank/data/media` | `/DATA/Media` (mp1) | Sonarr, Radarr, Lidarr, Readarr, Bazarr, Whisparr |
| `/tank/data/downloads` | `/DATA/Downloads` (mp2) | qBittorrent, SABnzbd, and the *arr above for imports |

Create these datasets on the host before running `install.sh`.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Runs the interactive ARR-Stack installer, then applies ACLs and bind mounts to each created container. |
| `update.sh` | Updates packages and upgrades each *arr service inside its container. |

## Caddy compatibility

All *arr UIs are plain HTTP web services and can be reverse-proxied behind Caddy.

| Port | Protocol | Service |
|------|----------|---------|
| 9696 | HTTP | Prowlarr |
| 8989 | HTTP | Sonarr |
| 7878 | HTTP | Radarr |
| 8686 | HTTP | Lidarr |
| 5055 | HTTP | Seerr |
| 8090 | HTTP | qBittorrent |
| 7777 | HTTP | SABnzbd |

The Caddy generator auto-discovers every LXC guest, so no manual Caddy edit is needed. After `install.sh`, run:

```
caddy/generate-caddyfile.sh
```

It detects each *arr container by its hostname (`sonarr`, `radarr`, `prowlarr`, ...) and its listening port, then creates `*.marx.home` entries (e.g. `sonarr.marx.home` -> `10.x.x.x:8989`). Each entry defaults to plain HTTP (internal homelab). Optionally set the *arr "Base URL" in its UI to match the subdomain if you enable HTTPS later.

## Execution order

```
install.sh                      (creates one LXC per app, wires them, mounts datasets)
caddy/generate-caddyfile.sh     (optional, auto-detects each *arr container as a subdomain)
update.sh                       (run any time to upgrade)
```

## Disposable CTID range (recommended for first run)

The underlying ARR-Stack script is in active development, so test it on an isolated, disposable CTID range first. The installer reads `var_start_ctid` from the environment to decide where container IDs begin; each selected app gets the next ID (Prowlarr = start, Sonarr = start+1, ...).

Run `install.sh` with a free high range (e.g. `900`):

```bash
var_start_ctid=900 \
var_bridge=vmbr0 \
var_gateway=192.168.x.1 \
var_cidr=24 \
var_container_storage=local-lvm \
var_qbt_password='your_password' \
bash arr/install.sh
```

This creates containers `900` (prowlarr), `901` (sonarr), `902` (radarr), and so on. Apps, download clients and IPs are still prompted interactively.

To tear down a failed test run on the `900` range:

```bash
for i in 900 901 902 903 904 905 906; do
  pct stop $i 2>/dev/null
  pct destroy $i 2>/dev/null
done
```

Note: `install.sh` skips the installer if any `*arr` container already exists, to avoid duplicates — destroy the test range before re-running.

## Post-install manual steps

The installer automates container creation and API wiring, but the following still require manual action (see `/root/arr-stack-summary.txt`):

- **Prowlarr:** add indexers (none ship by default).
- **Sonarr / Radarr / Lidarr:** set root folder to `/DATA/Media` and at least one quality profile.
- **SABnzbd / Seerr:** complete the first-run web wizard.

## Notes

- `install.sh` skips the installer if any *arr container already exists, to avoid creating duplicates.
