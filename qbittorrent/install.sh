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
mkdir -p /tank/data/mediaserver/downloads/{series,movies,music,shows}
mkdir -p /tank/data/mediaserver/media/{Movies,Series,Music,Shows}

# 3. Apply bind mount (stops, sets, restarts, and waits for ready)
log_step "Mounting /tank/data/mediaserver -> /data"
apply_mounts "$container_id" /tank/data/mediaserver /data

# 4. Discover host UID of qBittorrent user
host_uid=$(get_host_uid "$container_id" qbittorrent) || {
    log_warning "User 'qbittorrent' not found, falling back to root"
    host_uid=$(get_host_uid "$container_id" root) || exit 1
}

log_info "Host UID: $host_uid"

# 5. Apply ACLs on mediaserver dataset
log_step "Granting UID $host_uid access to mediaserver..."
add_dataset_acl "/tank/data/mediaserver" "$host_uid"

# 6. Set WebUI admin password (always auto-generated)
QBIT_USER="admin"
log_step "Generating random password for '$QBIT_USER'..."
OUTPUT=$(python3 "$SCRIPT_DIR/set_password.py" --container "$container_id" --user "$QBIT_USER")
QBIT_PASS=$(echo "$OUTPUT" | awk '{print $1}')
QBIT_HASH=$(echo "$OUTPUT" | awk '{print $2}')
if [ -z "$QBIT_PASS" ] || [ -z "$QBIT_HASH" ]; then
    log_error "Failed to generate qBittorrent password via helper (output: $OUTPUT)"
    exit 1
fi
log_success "Admin password generated for '$QBIT_USER'"
if [ -z "$QBIT_HASH" ]; then
    log_warning "Failed to update qBittorrent password via helper"
else
    wait_container_ready "$container_id" || log_warning "Container may not be fully ready after password update"
    log_success "Admin password updated for '$QBIT_USER'"
fi

# 7. Get container IP
container_ip=$(get_container_ip "$container_id")

if [ -n "$container_ip" ]; then
    log_success "qBittorrent installed! Web UI: http://${container_ip}:8090"
else
    log_success "qBittorrent installed!"
    log_warning "Could not determine container IP. Check with: pct exec $container_id -- hostname -I"
fi

if [ -n "$QBIT_PASS" ] && [ -n "$QBIT_HASH" ]; then
    echo ""
    log_success "──────────────────────────────────────────────────────"
    log_success "  Admin credentials:"
    log_success "    User:     $QBIT_USER"
    log_success "    Password: $QBIT_PASS"
    log_success "──────────────────────────────────────────────────────"
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
log_info "    - shows  → /data/downloads/shows"
log_info "  Connection > Listening Port: TCP 6881"
log_info "  BitTorrent > Privacy > Encryption: Allow encryption"
