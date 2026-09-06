#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Checking for Tailscale updates..."

container_id=$(get_container_id_by_name "tailscale-router")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'tailscale-router'. Run install.sh first."
    exit 1
fi

log_info "Container ID: $container_id"

log_step "Upgrading Tailscale inside container $container_id..."
if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/upgrade.sh"; then
    log_error "Tailscale upgrade failed inside container $container_id"
    exit 1
fi

log_success "Tailscale update complete!"
