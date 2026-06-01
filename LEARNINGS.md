# Learnings from previous sessions

- **`pct set -mpX` error "invalid format - missing key in comma-separated list property":** This error occurs when the `mp=...` value passed to `pct set` is malformed (e.g., contains newlines, spaces, or is empty). The format must be `host_path,mp=container_path` with both paths being single-line clean strings. Always validate/sanitize variables before using them in `pct set` arguments. A broken variable upstream (like a mis-extracted config value) silently produces this error downstream.

- **Nextcloud storage migration — avoid data loss and duplicate mounts:**
  - Never `rm -rf` the data directory before mounting — it deletes Nextcloud's initial files (and user data on re-runs). The NextcloudPi community script already sets up `mp1` for the ZFS dataset, so re-creating it as `mp2` creates a duplicate.
  - Always check if a mount for the target `data_dir` already exists (`pct config | grep "mp=$data_dir"`) before adding one.
  - After migration, create `/opt/ncdata/data/tmp` and run `occ files:scan --all` to keep the file cache consistent with disk.
  - Add the container root UID (host UID 100000) to ZFS ACLs so `pct exec` commands work without "Permission denied" on the mounted dataset.

