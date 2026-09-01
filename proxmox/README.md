# Proxmox VE

Host-level setup and maintenance scripts for the Proxmox server.

## Scripts

### Post-install (run in order)

| Script | Description |
|---|---|
| `post-install/001-root-setup.sh <username>` | Community post-PVE script, creates user, sets up sudo, configures UID/GID 1000 and subuid mapping. |
| `post-install/002-enable-intel-iommu.sh` | Enables IOMMU for PCIe passthrough (Intel). Reboot required. |
| `post-install/003-ssh-generate-key.sh [ip]` | **Run on your client machine.** Generates an SSH key and copies it to the server. |
| `post-install/004-useful-commands.sh` | Installs monitoring tools (`htop`, `btop`, `iotop`, `sysstat`). |
| `post-install/005-add-secondary-user.sh <username>` | Creates a secondary user and grants ACL access to shared datasets. |

### Storage setup (run after post-install)

| Script | Description |
|---|---|
| `storage-setup/001-create-datasets.sh` | Creates ZFS datasets (`tank/data/mediaserver` with `media/{Movies,Series,Music,Shows}` + `downloads/{series,movies,music,shows}`, `memorias`, `primary_user`) with optimized settings. |
| `storage-setup/002-exfat-external-drive.sh` | Installs exFAT support for external drives. |
| `storage-setup/create-user-dataset.sh <username>` | Creates a private ZFS dataset for a specific user. |

### Maintenance

| Script | Description |
|---|---|
| `update.sh` | Runs `apt dist-upgrade` and cleans up old packages. |

## Execution order

```
post-install/001-root-setup.sh <username>
post-install/002-enable-intel-iommu.sh        (then reboot)
post-install/003-ssh-generate-key.sh <ip>     (on your local machine)
post-install/004-useful-commands.sh
post-install/005-add-secondary-user.sh <user> (optional)

storage-setup/001-create-datasets.sh
storage-setup/002-exfat-external-drive.sh     (optional)
storage-setup/create-user-dataset.sh <user>   (optional)

update.sh   (run any time to upgrade the host)
```
