#!/usr/bin/env bash

# Script to update Proxmox VE
# Updates repositories and installed packages

set -e

echo "=== Starting Proxmox VE update ==="

# Check if the script is running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

echo "Updating package list..."
apt-get update

echo "Updating installed packages..."
apt-get dist-upgrade -y

echo "Cleaning up unnecessary packages..."
apt-get autoremove -y
apt-get autoclean

echo "=== Update completed successfully! ==="
