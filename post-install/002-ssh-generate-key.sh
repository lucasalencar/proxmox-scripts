#!/bin/bash
# Generates an Ed25519 SSH key and copies it to the specified server
# for passwordless authentication.

# Prevent running as root - this script is meant for local machine setup
if [[ "$(whoami)" == "root" ]]; then
  echo "Error: This script must not be run as root"
  echo "You probably want to run this one on your personal computer"
  exit 1
fi

# Load configuration from file if exists
CONFIG_FILE="$HOME/.proxmox_config"
if [[ -f "$CONFIG_FILE" ]]; then
  # Source config file (variables become available)
  source "$CONFIG_FILE"
  echo "Loaded configuration from $CONFIG_FILE"
fi

# Path where the SSH key will be stored (configurable via PROXMOX_SSH_KEY_PATH in config)
KEY_PATH="${PROXMOX_SSH_KEY_PATH:-$HOME/.ssh/proxmox}"

# Get server IP with precedence: 1) Command-line arg > 2) Config file > 3) Error
server_ip="${1:-$PROXMOX_SERVER_IP}"
ssh_user="${PROXMOX_SSH_USER:-lucas}"
ssh_host="${ssh_user}@${server_ip}"

# Validate that server IP was provided (either via config or argument)
if [[ -z "$server_ip" ]]; then
  echo "Error: Proxmox server IP not specified."
  echo "Either:"
  echo "  1. Set PROXMOX_SERVER_IP in $CONFIG_FILE, OR"
  echo "  2. Provide IP as command-line argument: $0 <server_ip>"
  exit 1
fi

# Generate Ed25519 SSH key with empty passphrase
ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""

# Copy the public key to the remote server
ssh-copy-id -i "$KEY_PATH" "$ssh_host"

# Add SSH config entries if not already present
# This allows 'ssh proxmox' to connect automatically
if ! grep -q "IdentityFile $KEY_PATH" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config << 'EOF'

Host proxmox
    HostName SERVER_IP
    User lucas
    IdentityFile KEY_PATH
EOF
  sed -i '' "s|SERVER_IP|$server_ip|g; s|KEY_PATH|$KEY_PATH|g" ~/.ssh/config
  echo "SSH config updated at ~/.ssh/config"
fi

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
ssh proxmox
