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

# Create user for ssh access if it doesn't exist
if id "$SSH_USER" &>/dev/null; then
    echo "User $SSH_USER already exists."
else
    echo "Creating user $SSH_USER..."
    adduser "$SSH_USER"
fi

# Grant sudo powers
echo "Installing sudo and vim..."
apt install sudo vim -y
echo "Adding $SSH_USER to sudo group..."
usermod -aG sudo "$SSH_USER"

# Register group to manage container data (UID 100000)
if ! getent group lxc-data > /dev/null; then
    echo "Creating lxc-data group (GID 100000)..."
    groupadd -g 100000 lxc-data
fi

echo "Adding $SSH_USER to lxc-data group..."
usermod -aG lxc-data "$SSH_USER"

echo ""
echo "Setup complete!"
echo "Now run 'ssh-generate-key.sh' on your personal computer to setup SSH keys for: $SSH_USER"
