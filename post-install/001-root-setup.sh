#!/bin/bash

if [[ "$(whoami)" != "root" ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Post install script from community
bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/misc/post-pve-install.sh)"

apt update

# Create user for ssh access
adduser lucas

# Grant sudo powers
apt install sudo vim -y
usermod -aG sudo lucas

echo "Run ssh-generate-key.sh on your personal computer to setup SSH keys"
