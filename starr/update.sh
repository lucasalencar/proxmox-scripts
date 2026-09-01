#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Checking for Starr stack updates..."

container_id=$(get_container_id_by_name "starr")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'starr'. Run install.sh first."
    exit 1
fi

log_info "Container ID: $container_id"

# Update OS packages first
log_step "Running apt update && apt upgrade inside container $container_id..."
pct exec "$container_id" -- bash -c 'apt update && apt upgrade -y'

# Per-app GH release update
log_step "Checking Starr app releases (Prowlarr, Sonarr, Radarr, Bazarr)..."
if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/update.sh"; then
    log_error "Starr update failed inside container $container_id"
    exit 1
fi

log_success "Starr stack update complete!"

container_ip=$(get_container_ip "$container_id" 2>/dev/null || echo "")
if [ -n "$container_ip" ]; then
    log_info "Access:"
    log_info "  Prowlarr: http://${container_ip}:9696"
    log_info "  Sonarr:   http://${container_ip}:8989"
    log_info "  Radarr:   http://${container_ip}:7878"
    log_info "  Bazarr:   http://${container_ip}:6767"
fi
