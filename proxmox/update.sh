#!/usr/bin/env bash

# Script to update Proxmox VE
# Updates repositories and installed packages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

log_step "Starting Proxmox VE update"

require_root

log_step "Updating package list..."
apt-get update

log_step "Updating installed packages..."
apt-get dist-upgrade -y

log_step "Cleaning up unnecessary packages..."
apt-get autoremove -y
apt-get autoclean

log_success "Update completed successfully!"
