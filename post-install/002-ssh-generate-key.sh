#!/bin/bash
# Generates an Ed25519 SSH key and copies it to the specified server
# for passwordless authentication.

if [[ "$(whoami)" == "root" ]]; then
  echo "Error: This script must not be run as root"
  echo "You probably want to run this one on your personal computer"
  exit 1
fi

KEY_PATH="$HOME/.ssh/proxmox"

server_ip=$1
ssh_host="lucas@$server_ip"

if [[ -z "$server_ip" ]]; then
  echo "Usage: $0 <server_ip>"
  exit 1
fi

ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""
ssh-copy-id -i "$KEY_PATH" "$ssh_host"

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

ssh -i "$KEY_PATH" "$ssh_host"
