#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Starting Caddy installation/configuration via LXC container..."

CADDY_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/caddy.sh)"'
container_id=$(ensure_container_installed "caddy" "$CADDY_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

pct start "$container_id"
wait_container_ready "$container_id" || { log_error "Container not ready"; exit 1; }

CADDY_IP=$(get_container_ip "$container_id")
log_info "Caddy container IP: $CADDY_IP"

log_success "Installation completed for Caddy (ID: $container_id, IP: $CADDY_IP)."
log_info "Update AdGuard DNS wildcard *.marx.home to point to $CADDY_IP"
