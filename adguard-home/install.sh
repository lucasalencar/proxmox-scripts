#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

log_step "Installing jq on Proxmox host..."
apt install -y jq

log_step "Starting AdGuard Home installation/configuration via LXC container..."

ADGUARD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/adguard.sh)"'
container_id=$(ensure_container_installed "adguard" "$ADGUARD_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

pct start "$container_id"

log_success "Installation completed for AdGuard Home (ID: $container_id)."

echo ""
log_step "Running upstream DNS setup..."
bash "$SCRIPT_DIR/setup-upstream.sh"

echo ""
log_step "Running DNS rewrite setup..."
bash "$SCRIPT_DIR/setup-dns.sh"
