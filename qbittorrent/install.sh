#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Starting qBittorrent installation/configuration..."

# 1. Install container via community script
INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/qbittorrent.sh)"'
container_id=$(ensure_container_installed "qbittorrent" "$INSTALL_CMD") || exit 1

log_info "Container ID: $container_id"

# 2. Create download category folders (idempotent)
log_step "Ensuring download category folders exist..."
mkdir -p /tank/data/downloads/{series,movies,music}

# 3. Discover internal UID of qBittorrent user
internal_uid=$(pct exec "$container_id" -- id -u qbittorrent 2>/dev/null)
if [ -z "$internal_uid" ]; then
    log_warning "User 'qbittorrent' not found, falling back to root"
    internal_uid=$(pct exec "$container_id" -- id -u root)
fi
host_uid=$((internal_uid + 100000))

log_info "Internal UID: $internal_uid -> Host UID: $host_uid"

# 4. Apply ACLs on downloads and media datasets
log_step "Granting UID $host_uid access to downloads and media..."
add_dataset_acl "/tank/data/downloads" "$host_uid"
add_dataset_acl "/tank/data/media" "$host_uid"

# 5. Mount /tank/data as /data (single mount for hardlink support)
log_step "Mounting /tank/data -> /data (mp1)"
pct stop "$container_id" 2>/dev/null
pct set "$container_id" -mp1 /tank/data,mp=/data
pct start "$container_id"

# 6. Print access info
container_ip=$(get_container_ip "$container_id")

log_success "qBittorrent installed! Web UI: http://${container_ip}:8090"
