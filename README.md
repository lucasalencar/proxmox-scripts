# Proxmox Scripts

Repository of scripts to automate Proxmox server setup, storage configuration, and service installation (LXC/VM).

## Scripts Overview

### Host Setup (`post-install/`)
*   **001-root-setup.sh**: Run on Proxmox as root. Runs tteck's post-install, creates a primary user (UID 1000), and sets up mapping permissions.
*   **002-enable-intel-iommu.sh**: Enables IOMMU for PCIe passthrough (Intel).
*   **003-ssh-generate-key.sh**: Run locally. Configures passwordless SSH to the server.
*   **004-useful-commands.sh**: Installs monitoring tools (`htop`, `btop`, `iotop`, `sysstat`).
*   **005-add-secondary-user.sh**: Adds an additional unprivileged user to the system.

### Storage Configuration (`storage-setup/`)
*   **001-create-datasets.sh**: Creates ZFS structure on `tank` pool (`media`, `memorias`, etc.) with correct permissions.
*   **002-exfat-external-drive.sh**: Installs `exfatprogs` for external drive support.

### Service Installation
Each service folder contains an `install.sh` that automates:
1.  Downloading/Running the community install script.
2.  Discovering the Container ID.
3.  Configuring ZFS ACLs for the service user.
4.  Performing **Bind Mounts** from the host datasets to the container.

### Service Updates
Some services include an `update.sh` to keep them up to date via the host CLI:
*   **casa-os/update.sh**: Runs `apt update && apt upgrade` and the official CasaOS update script inside the container.
*   **jellyfin/update.sh**: Updates the Jellyfin container and its specific packages.

*   **casa-os/**: Installs CasaOS LXC and mounts Media, Gallery, and Documents.
*   **jellyfin/**: Installs Jellyfin LXC, configures ACLs, and mounts Media.
*   **home-assistant-os/**: Installs Home Assistant OS as a VM.

## Setup Order

### Step 1: Base Host Setup (as root)

```bash
# Upload and run the root setup script
scp post-install/001-root-setup.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/001-root-setup.sh <your-username>
# Reboot when prompted
```

### Step 2: Local SSH Config (from your computer)

```bash
# Option A: Create config file
cp proxmox_config.example ~/.proxmox_config
# Edit ~/.proxmox_config with your IP and username

# Run the key generator
./post-install/003-ssh-generate-key.sh
```

### Step 3: Storage and Utilities

```bash
# Run on Proxmox as root
./storage-setup/001-create-datasets.sh
./post-install/004-useful-commands.sh
```

### Step 4: Installing Services

You can now install services which will automatically mount the previously created datasets:

```bash
# On Proxmox as root
./casa-os/install.sh
./jellyfin/install.sh
./home-assistant-os/install.sh
```

## Configuration

Edit `~/.proxmox_config` (on your local machine) or `proxmox_config.example` to customize:

```bash
PROXMOX_SERVER_IP="192.168.1.100"     # Your Proxmox server IP
PROXMOX_SSH_USER="lucas"               # SSH username
PROXMOX_SSH_KEY_PATH="$HOME/.ssh/proxmox"  # SSH key location
```
