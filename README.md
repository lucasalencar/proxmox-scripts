# Proxmox Scripts

Repository of scripts to automate Proxmox server setup.

## UID Mapping Strategy (The '1000 Club')

To ensure seamless data access between the Proxmox host and multiple LXC containers without "Permission Denied" errors, this project uses a custom **UID/GID mapping strategy**.

### Why UID 1000?
In Proxmox and most Linux distributions, the first unprivileged user created is assigned **UID 1000**. By mapping container users to this ID, files created by a container appear as owned by the host user, and vice versa. This allows you to manage your media files via SMB/SFTP on the host while containers access them natively.

### Supported Scenarios:
1.  **Container running as Root (UID 0):**
    - **Example:** CasaOS.
    - **Mapping:** Container `0` -> Host `1000`.
    - **Usage:** Everything CasaOS or its Docker apps do is "seen" by the host as being done by your primary user.
2.  **Container running as Specific User (UID 105, etc.):**
    - **Example:** Jellyfin (runs as internal user `jellyfin`).
    - **Mapping:** Container `105` -> Host `1000`.
    - **Usage:** Jellyfin can read/write to your media folders as if it were your host user, while keeping system files isolated.

## Scripts Overview

### post-install/001-root-setup.sh
Run on Proxmox server as root. Runs tteck's post-install script, creates a user account with **UID 1000**, and authorizes the host to map this ID to LXC containers.

### post-install/002-enable-intel-iommu.sh
Run on Proxmox server as root. Enables IOMMU for PCIe passthrough (Intel processors).

### post-install/003-ssh-generate-key.sh
Run on your local computer. Generates an SSH key and configures passwordless authentication to the Proxmox server.

### storage-setup/001-create-datasets.sh
Run on Proxmox server as root. Creates the ZFS storage structure on the `tank` pool, organizes media folders, and sets correct permissions (**UID/GID 1000**) for synchronized access.

### storage-setup/002-bind-mount-datasets.sh
Run on Proxmox server as root. Maps host datasets to a specific LXC container using Bind Mounts. Maps `/tank/data` as default (`mp0`) and supports additional sub-datasets as optional arguments.

## Setup Order

### Step 1: On Proxmox Server (as root)

```bash
# Upload and run the root setup script
scp post-install/001-root-setup.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/001-root-setup.sh <your-username>
# Reboot when prompted
```

### Step 2: (Optional) Enable IOMMU for PCIe passthrough

```bash
scp post-install/002-enable-intel-iommu.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/002-enable-intel-iommu.sh
# Reboot when prompted
```

### Step 3: Storage Configuration

```bash
# Create ZFS datasets and set permissions
scp storage-setup/001-create-datasets.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/001-create-datasets.sh

# Bind datasets to a container (e.g., VMID 101 with media and memorias)
scp storage-setup/002-bind-mount-datasets.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/002-bind-mount-datasets.sh 101 media memorias
```

### Step 4: On Your Computer (as your user)

```bash
# Option A: Create config file (recommended for recurring use)
cp proxmox_config.example ~/.proxmox_config
# Edit ~/.proxmox_config and set your PROXMOX_SERVER_IP

# Option B: Pass IP as argument
./post-install/003-ssh-generate-key.sh <proxmox-ip>

# Or just run with config
./post-install/003-ssh-generate-key.sh
```

## Configuration

Edit `~/.proxmox_config` to customize:

```bash
PROXMOX_SERVER_IP="192.168.1.100"     # Your Proxmox server IP
PROXMOX_SSH_USER="lucas"               # SSH username
PROXMOX_SSH_KEY_PATH="$HOME/.ssh/proxmox"  # SSH key location
```
