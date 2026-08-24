# Learnings from previous sessions

- **`trust-nextcloud.sh` — always also search for "nextcloudpi" container name:** The script only looked for "nextcloud" via `get_container_id_by_name`, but NextcloudPi Community Script creates a container named "nextcloudpi". Always fallback to "nextcloudpi" if "nextcloud" is not found.

- **Caddy reverse proxy + NextcloudPi (HTTPS redirect loop fix):**
  - The script `generate-caddyfile.sh` previously generated `http://` entries only, causing Nextcloud's Apache-level `RewriteRule` HTTP→HTTPS redirect to create an infinite loop through Caddy.
  - Fix 1: Generate entries with `tls internal` (no `http://` scheme) so Caddy terminates TLS, serving both HTTP (redirects to HTTPS) and HTTPS with self-signed certs.
  - Fix 2: Remove the Apache HTTP→HTTPS `RewriteRule` from NextcloudPi's port 80 vhost (it's unnecessary when Caddy handles TLS termination).
  - Fix 3: Add Caddy's container IP to Nextcloud's `trusted_proxies` config so it respects `X-Forwarded-Proto` headers.
  - Fix 4: Add the public domain (e.g., `nextcloudpi.marx.home`) to Nextcloud's `trusted_domains`.
  - Fix 5: `generate-caddyfile.sh` now auto-calls `trust-nextcloud.sh` for any guest whose name starts with "nextcloud", so the Nextcloud config updates happen automatically.

- **`pct set -mpX` error "invalid format - missing key in comma-separated list property":** This error occurs when the `mp=...` value passed to `pct set` is malformed (e.g., contains newlines, spaces, or is empty). The format must be `host_path,mp=container_path` with both paths being single-line clean strings. Always validate/sanitize variables before using them in `pct set` arguments. A broken variable upstream (like a mis-extracted config value) silently produces this error downstream.

- **Container readiness helpers (`apply_mounts`, `get_container_ip`):** `apply_mounts` stops the container, applies all bind mounts, restarts it, and waits until it's ready — when it returns, the container is fully operational. `get_container_ip` internally calls `wait_container_ready` before fetching the IP, so callers never need to wait separately. If a script needs to run `pct exec` after a restart, use `apply_mounts` first (it guarantees readiness on return).

- **`pct set` requires the container to be stopped:** Mount point changes via `pct set -mpX` only take effect after a container restart. Scripts that call `pct set` on a running container (without stop/restart) will have the mounts silently ignored until the next reboot. Always use `apply_mounts` which handles stop → set → start → wait.

- **Hardlinks require a single mount point in LXC containers:** When multiple ZFS datasets (e.g., `tank/data/downloads` and `tank/data/media`) need hardlink support inside a container, mount the common parent (`/tank/data`) as a single mount point (`-mp1 /tank/data,mp=/data`). Mounting each dataset separately makes the kernel treat them as distinct filesystems, causing `link()` to fail. The container apps must see both source and destination paths under one unified `/data` tree.

- **Nextcloud storage migration — avoid data loss and duplicate mounts:**
  - Never `rm -rf` the data directory before mounting — it deletes Nextcloud's initial files (and user data on re-runs). The NextcloudPi community script already sets up `mp1` for the ZFS dataset, so re-creating it as `mp2` creates a duplicate.
  - Always check if a mount for the target `data_dir` already exists (`pct config | grep "mp=$data_dir"`) before adding one.
  - After migration, create `/opt/ncdata/data/tmp` and run `occ files:scan --all` to keep the file cache consistent with disk.
  - Add the container root UID (host UID 100000) to ZFS ACLs so `pct exec` commands work without "Permission denied" on the mounted dataset.

