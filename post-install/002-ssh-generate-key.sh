#!/bin/bash
# Generates an Ed25519 SSH key and copies it to the specified server
# for passwordless authentication.

# Prevent running as root - this script is meant for local machine setup
if [[ "$(whoami)" == "root" ]]; then
  echo "Error: This script must not be run as root"
  echo "You probably want to run this one on your personal computer"
  exit 1
fi

# Path where the SSH key will be stored
KEY_PATH="$HOME/.ssh/proxmox"

# Get server IP from command line argument
server_ip=$1
ssh_host="lucas@$server_ip"

# Validate that server IP was provided
if [[ -z "$server_ip" ]]; then
  echo "Usage: $0 <server_ip>"
  exit 1
fi

# Generate Ed25519 SSH key with empty passphrase
ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""

# Copy the public key to the remote server
ssh-copy-id -i "$KEY_PATH" "$ssh_host"

# Display instructions for securing the server
echo
echo "=============================================="
echo "  IMPORTANT: After connecting to the server,  "
echo "  disable root SSH login with the following: "
echo "=============================================="
echo
echo "  sudo sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config"
echo "  sudo systemctl restart sshd"
echo
echo "=============================================="
echo

# Test the connection to the remote server
ssh -i "$KEY_PATH" "$ssh_host"
