#!/usr/bin/env bash

# Script to update Proxmox VE
# Updates repositories and installed packages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "=== Starting Proxmox VE update ==="

require_root

echo "Updating package list..."
apt-get update

echo "Updating installed packages..."
apt-get dist-upgrade -y

echo "Cleaning up unnecessary packages..."
apt-get autoremove -y
apt-get autoclean

echo "=== Update completed successfully! ==="
