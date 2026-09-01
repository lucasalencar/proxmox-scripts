#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

log_step "Starting Jellyfin installation/configuration via LXC container..."

# 1. Ensure Jellyfin is installed
JELLYFIN_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/jellyfin.sh)"'
container_id=$(ensure_container_installed "jellyfin" "$JELLYFIN_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

# 2. DISCOVER host UID of the 'jellyfin' user
host_jellyfin_uid=$(get_host_uid "$container_id" jellyfin) || exit 1

log_info "Jellyfin host UID: $host_jellyfin_uid"

# 3. APPLY Specific ACLs for Jellyfin UID on Host
add_dataset_acl "/tank/data/mediaserver/media" "$host_jellyfin_uid"
add_dataset_acl "/tank/data/memorias" "$host_jellyfin_uid"

# 4. Perform bind mounts (stops, sets, restarts, and waits for ready)
apply_mounts "$container_id" \
    /tank/data/mediaserver/media /DATA/Media \
    /tank/data/memorias /DATA/Gallery

log_success "Installation and ACL setup completed for Jellyfin (ID: $container_id)."
