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

- **`pct set` mount point syntax:** The correct format is `pct set <vmid> -mp<N> <host_path>,mp=<container_path>` — note the `mp=` prefix before the container path. Without it, `pct set` fails silently or produces malformed config. The `apply_mounts` helper builds this format internally from separate `host_path` and `container_path` arguments.

- **Container readiness helpers (`apply_mounts`, `get_container_ip`):** `apply_mounts` stops the container, applies all bind mounts, restarts it, and waits until it's ready — when it returns, the container is fully operational. `get_container_ip` internally calls `wait_container_ready` before fetching the IP, so callers never need to wait separately. If a script needs to run `pct exec` after a restart, use `apply_mounts` first (it guarantees readiness on return).

- **`pct set` requires the container to be stopped:** Mount point changes via `pct set -mpX` only take effect after a container restart. Scripts that call `pct set` on a running container (without stop/restart) will have the mounts silently ignored until the next reboot. Always use `apply_mounts` which handles stop → set → start → wait.

- **Hardlinks require a single mount point in LXC containers:** When `media` and `downloads` need hardlink/instant moves (e.g., `*arr` + `qBittorrent`), they must be on the same ZFS dataset. Using separate datasets (`tank/data/downloads` and `tank/data/media`) makes `link()` fail even via a parent mount if the parent exposes private data. Solution is a dedicated dataset `tank/data/mediaserver` with subfolders `media/{Movies,Series,Music,Shows}` and `downloads/{series,movies,music,shows}` mounted as `-mp0 /tank/data/mediaserver,mp=/data`. Mounting each dataset separately makes the kernel treat them as distinct filesystems, causing `link()` to fail. The container apps must see both source and destination paths under one unified `/data` tree.

- **Mock `pct exec -- true` must stay silent:** `get_container_ip` wraps `wait_container_ready` inside command substitution, so any stdout the mock emits for readiness probes (e.g. echoing a generic fixture var) pollutes the captured IP. Mock branches for `true`/`is-active` probes must print nothing, and per-command fixtures (e.g. `ss` output) need dedicated vars.

- **`while read … done <<< "$var"` steals stdin from inner `read` prompts:** redirecting a loop's stdin to a herestring makes every `read -p` inside the body consume herestring lines instead of user answers. For interactive loops over a list, use `for x in $list` (intended word-splitting) so prompts still read from the user's stdin.

- **Generators that own a file must preserve unmanaged blocks:** when a script rewrites a config file from scanned state (e.g. one block per guest), any block it didn't generate (manual extras, multi-service subdomains) is silently deleted on the next run. Persist the extra identity signals the file already has (saved IP/port per block) to re-attach them, and carry forward unknown blocks with a warning instead of dropping them.

- **macOS `/bin/bash` is 3.2 — repo scripts using `declare -A`/`${var,,}` need bash 5 to test locally:** install via `brew install bash` and put `/opt/homebrew/bin` first in PATH when running bats. Production (Proxmox/Debian) and CI (ubuntu-latest) already have bash 5.
- **Template selection must filter by host arch (`dpkg --print-architecture` / `uname -m`):** Picking the newest template with `sort -V | tail -1` over a mixed `pveam available` list silently prefers `arm64` over `amd64` (`r` > `m`), causing `pct create` to fail with "can't find file" on x86 hosts. Always `grep -F` the detected arch first, with an unfiltered fallback only when the arch has no match.
- **Keep command-substituted helpers stdout-clean (`pveam download ... >&2`):** Helpers like `ensure_debian_template` return a value via `echo` captured with `$(...)`, so any child command writing to stdout (e.g. `pveam download ... 2>&1`) pollutes the return value. Redirect progress/download output to stderr instead.
- **Guard recursive `setfacl -R` with a `getfacl` pre-check:** `setfacl -R` walks every file, so re-applying ACLs on large datasets (media libraries) takes minutes on every idempotent re-run even with nothing to change. Check `getfacl` for the exact access + default entries first and skip when present; fall through to the recursive apply when the check fails or entries are missing (also covers drift from files that bypassed default-ACL inheritance).

- **Negative mock-log assertions must use `/usr/bin/grep`, never the mocked `grep`:** The mock `grep` appends each invocation (`mock_log`) to the same `MOCK_LOG` being asserted on, so `! grep -q "<pattern>" "$MOCK_LOG"` matches the assertion's own log line and fails spuriously. Positive assertions are unaffected (they pass trivially). Always write negative assertions as `! /usr/bin/grep -q ...`.

- **Tarball installs create no service users — verify before assuming UIDs:** Apps deployed by unpacking upstream tarballs/zips with hand-written systemd units (no `User=`, no `useradd`, no `.deb` postinst) run as root, so `id -u <service>` fails. Only `.deb`/`apt` installs (e.g. Jellyfin) can be expected to own a service user. Confirm with `pct exec <id> -- id <user>`, `/etc/passwd`, and `ps -o user,uid,comm` before writing ACL logic around service users; otherwise resolve the UID actually running the process (often root → host UID 100000).

- **Nextcloud storage migration — avoid data loss and duplicate mounts:**
  - Never `rm -rf` the data directory before mounting — it deletes Nextcloud's initial files (and user data on re-runs). The NextcloudPi community script already sets up `mp1` for the ZFS dataset, so re-creating it as `mp2` creates a duplicate.
  - Always check if a mount for the target `data_dir` already exists (`pct config | grep "mp=$data_dir"`) before adding one.
  - After migration, create `/opt/ncdata/data/tmp` and run `occ files:scan --all` to keep the file cache consistent with disk.
  - Add the container root UID (host UID 100000) to ZFS ACLs so `pct exec` commands work without "Permission denied" on the mounted dataset.

