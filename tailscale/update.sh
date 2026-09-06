#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"
source "$SCRIPT_DIR/config.sh"

require_root

log_step "Checking for Tailscale updates..."

container_id=$(get_container_id_by_exact_name "$CONTAINER_NAME")

if [ -z "$container_id" ]; then
    log_error "Could not find container '$CONTAINER_NAME'. Run install.sh first."
    exit 1
fi
if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
    log_error "Refusing to operate on unexpected container ID '$container_id'"
    exit 1
fi

log_info "Container ID: $container_id"

log_step "Reconciling required tags..."
if ! ensure_guest_tags "ct" "$container_id" "$REQUIRED_TAGS"; then
    log_error "Failed to apply required tags ($REQUIRED_TAGS) on $container_id"
    exit 1
fi

log_step "Upgrading Tailscale inside container $container_id..."
if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/upgrade.sh"; then
    log_error "Tailscale upgrade failed inside container $container_id"
    exit 1
fi

log_success "Tailscale update complete!"
