# Proxmox Scripts

Repository of scripts to automate Proxmox server setup.

## Scripts Overview

### post-install/001-root-setup.sh
Run on Proxmox server as root. Runs tteck's post-install script, then creates a user account with sudo privileges for SSH access.

### post-install/002-enable-intel-iommu.sh
Run on Proxmox server as root. Enables IOMMU for PCIe passthrough (Intel processors).

### post-install/003-ssh-generate-key.sh
Run on your local computer. Generates an SSH key and configures passwordless authentication to the Proxmox server.

### storage-setup/001-create-datasets.sh
Run on Proxmox server as root. Creates the ZFS storage structure on the `tank` pool, organizes media folders, and sets correct permissions (UID 100000) for unprivileged LXC containers.

### storage-setup/002-bind-mount-datasets.sh
Run on Proxmox server as root. Maps host datasets to a specific LXC container using Bind Mounts. Maps `/tank/data` as default (`mp0`) and supports additional sub-datasets as optional arguments.

## Setup Order

### Step 1: On Proxmox Server (as root)

```bash
# Upload and run the root setup script
scp post-install/001-root-setup.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/001-root-setup.sh
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
