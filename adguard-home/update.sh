#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

log_step "Checking for AdGuard Home container updates..."

container_id=$(get_container_id_by_name "adguard")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'adguard'."
    exit 1
fi

log_info "Identified Container ID: $container_id"

log_step "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt upgrade -y

log_success "AdGuard Home update process complete!"
