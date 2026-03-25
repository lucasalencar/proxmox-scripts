#!/bin/bash
# Generates an Ed25519 SSH key and copies it to the specified server
# for passwordless authentication.

KEY_PATH="$HOME/.ssh/proxmox"

server_ip=$1

if [[ -z "$server_ip" ]]; then
  echo "Usage: $0 <server_ip>"
  exit 1
fi

ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""
ssh-copy-id -i "$KEY_PATH" "lucas@$server_ip"
