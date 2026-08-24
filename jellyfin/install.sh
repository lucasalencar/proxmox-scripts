#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

log_step "Starting Jellyfin installation/configuration via LXC container..."

# 1. Ensure Jellyfin is installed
JELLYFIN_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/jellyfin.sh)"'
container_id=$(ensure_container_installed "jellyfin" "$JELLYFIN_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

# 2. DISCOVER internal UID of the 'jellyfin' user
internal_uid=$(pct exec "$container_id" -- id -u jellyfin)

if [ -z "$internal_uid" ]; then
    log_error "Could not find user 'jellyfin' inside container."
    exit 1
fi

# Calculate corresponding host UID
host_jellyfin_uid=$((internal_uid + 100000))

log_info "Jellyfin internal UID: $internal_uid -> Host UID: $host_jellyfin_uid"

# 3. APPLY Specific ACLs for Jellyfin UID on Host
add_dataset_acl "/tank/data/media" "$host_jellyfin_uid"
add_dataset_acl "/tank/data/memorias" "$host_jellyfin_uid"

# 4. Perform bind mounts (stops, sets, restarts, and waits for ready)
apply_mounts "$container_id" \
    /tank/data/media /DATA/Media \
    /tank/data/memorias /DATA/Gallery

log_success "Installation and ACL setup completed for Jellyfin (ID: $container_id)."
