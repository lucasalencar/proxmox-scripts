#!/bin/bash

# Check if username is provided as an argument
if [ -z "$1" ]; then
    echo "Error: You must provide a username as an argument."
    echo "Usage: $0 <username>"
    exit 1
fi

SSH_USER=$1

if [[ "$(whoami)" != "root" ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Post install script from community
# https://community-scripts.org/scripts/post-pve-install
echo "Running Proxmox Post-Install Script..."
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"

echo "Updating system packages..."
apt update

# Create user for ssh access if it doesn't exist (Targeting UID 1000)
if id "$SSH_USER" &>/dev/null; then
    echo "User $SSH_USER already exists."
    CURRENT_UID=$(id -u "$SSH_USER")
    if [ "$CURRENT_UID" != "1000" ]; then
        echo "Warning: User $SSH_USER exists but has UID $CURRENT_UID instead of 1000."
    fi
else
    echo "Creating user $SSH_USER with UID 1000..."
    adduser --uid 1000 "$SSH_USER"
fi

# Grant sudo powers
echo "Installing sudo and vim..."
apt install sudo vim -y
echo "Adding $SSH_USER to sudo group..."
usermod -aG sudo "$SSH_USER"

# Configure SubUID/SubGID mapping for LXC UID Mapping (UID 1000)
echo "Configuring SubUID/SubGID mapping for UID 1000..."
if ! grep -q "root:1000:1" /etc/subuid; then
    echo "root:1000:1" >> /etc/subuid
fi
if ! grep -q "root:1000:1" /etc/subgid; then
    echo "root:1000:1" >> /etc/subgid
fi

echo ""
echo "Setup complete!"
echo "User '$SSH_USER' is now set as the primary data owner (UID 1000)."
echo "Proxmox is authorized to map this UID for LXC containers."
echo "Now run 'ssh-generate-key.sh' on your personal computer to setup SSH keys for: $SSH_USER"
