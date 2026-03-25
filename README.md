# Proxmox Scripts

Repository of scripts to automate Proxmox server setup.

## Scripts Overview

### post-install/001-create-user.sh
Run on Proxmox server as root. Creates a user account with sudo privileges for SSH access.

### post-install/002-ssh-generate-key.sh
Run on your local computer. Generates an SSH key and configures passwordless authentication to the Proxmox server.

## Setup Order

### Step 1: On Proxmox Server (as root)

```bash
# Upload and run the create user script
scp 001-create-user.sh root@<proxmox-ip>:/tmp/
ssh root@<proxmox-ip>
bash /tmp/001-create-user.sh
```

### Step 2: On Your Computer (as your user)

```bash
# Option A: Create config file (recommended for recurring use)
cp proxmox_config.example ~/.proxmox_config
# Edit ~/.proxmox_config and set your PROXMOX_SERVER_IP

# Option B: Pass IP as argument
./post-install/002-ssh-generate-key.sh <proxmox-ip>

# Or just run with config
./post-install/002-ssh-generate-key.sh
```

## Configuration

Edit `~/.proxmox_config` to customize:

```bash
PROXMOX_SERVER_IP="192.168.1.100"     # Your Proxmox server IP
PROXMOX_SSH_USER="lucas"               # SSH username
PROXMOX_SSH_KEY_PATH="$HOME/.ssh/proxmox"  # SSH key location
```
