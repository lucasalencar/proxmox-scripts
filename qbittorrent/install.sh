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

# 3. Apply bind mount (stops, sets, restarts, and waits for ready)
log_step "Mounting /tank/data -> /data"
apply_mounts "$container_id" "/tank/data,/data"

# 4. Discover internal UID of qBittorrent user
internal_uid=$(pct exec "$container_id" -- id -u qbittorrent 2>/dev/null)
if [ -z "$internal_uid" ]; then
    log_warning "User 'qbittorrent' not found, falling back to root"
    internal_uid=$(pct exec "$container_id" -- id -u root)
fi
host_uid=$((internal_uid + 100000))

log_info "Internal UID: $internal_uid -> Host UID: $host_uid"

# 5. Apply ACLs on downloads and media datasets
log_step "Granting UID $host_uid access to downloads and media..."
add_dataset_acl "/tank/data/downloads" "$host_uid"
add_dataset_acl "/tank/data/media" "$host_uid"

# 6. Get container IP
container_ip=$(get_container_ip "$container_id")

if [ -n "$container_ip" ]; then
    log_success "qBittorrent installed! Web UI: http://${container_ip}:8090"
else
    log_success "qBittorrent installed!"
    log_warning "Could not determine container IP. Check with: pct exec $container_id -- hostname -I"
fi

echo ""
log_info "Post-install steps (follow TRaSH Guides):"
log_info "  Downloads > Saving Management:"
log_info "    - Default Save Path: /data/downloads"
log_info "    - Torrent Management Mode: Automatic"
log_info "  Categories:"
log_info "    - series → /data/downloads/series"
log_info "    - movies → /data/downloads/movies"
log_info "    - music  → /data/downloads/music"
log_info "  Connection > Listening Port: TCP 6881"
log_info "  BitTorrent > Privacy > Encryption: Allow encryption"
