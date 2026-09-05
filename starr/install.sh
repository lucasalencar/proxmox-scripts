#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Starting Starr stack installation (Prowlarr + Sonarr + Radarr + Bazarr) — single LXC..."

# --- 1. Create / find container ---
container_id=$(get_container_id_by_name "starr")

if [ -z "$container_id" ]; then
    # Single CT runs 4 apps — resources are shared
    CT_CORES=4
    CT_MEMORY=4096
    CT_DISK=20
    CT_SWAP=512
    log_step "Container 'starr' not found — creating new Debian 13 LXC (${CT_CORES} cores / ${CT_MEMORY} MB / ${CT_DISK}GB)..."

    CTID=$(get_pve_next_id) || exit 1
    log_info "Using CTID: $CTID"

    TEMPLATE_STORAGE=$(get_pve_template_storage)
    ROOTFS_STORAGE=$(get_pve_rootfs_storage)
    log_info "Template storage: $TEMPLATE_STORAGE | RootFS storage: $ROOTFS_STORAGE"

    BRIDGE=$(detect_pve_bridge)
    log_info "Network bridge: $BRIDGE"

    TEMPLATE=$(ensure_debian_template "13" "$TEMPLATE_STORAGE") || exit 1
    TEMPLATE_FILE=$(basename "$TEMPLATE")

    if ! create_lxc_container "$CTID" "starr" "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" "$ROOTFS_STORAGE" "$BRIDGE" "$CT_CORES" "$CT_MEMORY" "$CT_DISK" "$CT_SWAP" "starr,arr,media" "Starr single CT: Prowlarr (9696), Sonarr (8989), Radarr (7878), Bazarr (6767). Managed by proxmox-scripts/starr."; then
        log_error "Failed to create starr LXC"
        exit 1
    fi

    container_id="$CTID"
    log_success "Created container starr (ID: $container_id)"
else
    log_info "Found existing starr container (ID: $container_id) — reusing"
fi

# --- 2. Ensure media folders ---
log_step "Ensuring download/media folders..."
mkdir -p /tank/data/mediaserver/downloads/{series,movies,music,shows}
mkdir -p /tank/data/mediaserver/media/{Movies,Series,Music,Shows}

# --- 3. Bind mount single dataset for hardlinks ---
log_step "Mounting /tank/data/mediaserver -> /data (single dataset for hardlinks/instant moves)"
apply_mounts "$container_id" /tank/data/mediaserver /data

# --- 4. Install stack inside container ---
log_step "Installing Starr apps inside container $container_id (this may take several minutes)..."

if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/provision.sh"; then
    log_error "Failed to install Starr apps inside container $container_id"
    exit 1
fi

log_success "Starr apps installed inside container $container_id"

# --- 5. ACLs for each service user ---
log_step "Configuring ACLs for Starr service users..."
for svc in prowlarr sonarr radarr bazarr; do
    host_uid=$(get_host_uid "$container_id" "$svc" 2>/dev/null)
    if [ -z "$host_uid" ]; then
        log_error "Could not determine UID for '$svc' inside container $container_id — aborting"
        exit 1
    fi
    log_info "Granting UID $host_uid ($svc) access to mediaserver..."
    add_dataset_acl "/tank/data/mediaserver" "$host_uid"
done

# Ensure container root (100000) can traverse
add_dataset_acl "/tank/data/mediaserver" "100000" 2>/dev/null || true

# --- 6. Caddy hints ---
container_ip=$(get_container_ip "$container_id")
if [ -n "$container_ip" ]; then
    log_success "Starr stack ready! Container IP: $container_ip"
    echo ""
    log_success "──────────────────────────────────────────────────────"
    log_success "  Prowlarr: http://${container_ip}:9696"
    log_success "  Sonarr:   http://${container_ip}:8989"
    log_success "  Radarr:   http://${container_ip}:7878"
    log_success "  Bazarr:   http://${container_ip}:6767"
    log_success "──────────────────────────────────────────────────────"
    echo ""
    log_info "Next steps (TRaSH Guides):"
    log_info "  1. Generate Caddy entries for each app (single CT needs multi-port):"
    log_info "     prowlarr.marx.home -> ${container_ip}:9696"
    log_info "     sonarr.marx.home   -> ${container_ip}:8989"
    log_info "     radarr.marx.home   -> ${container_ip}:7878"
    log_info "     bazarr.marx.home   -> ${container_ip}:6767"
    log_info "     Run: bash caddy/generate-caddyfile.sh and answer 4 times for 'starr' when prompted for ports."
    echo ""
    log_info "  2. Configure qBittorrent categories to match (already done via qbittorrent/install.sh:40):"
    log_info "     Sonarr -> Category 'series' -> /data/downloads/series"
    log_info "     Radarr -> Category 'movies' -> /data/downloads/movies"
    log_info "  3. In Sonarr/Radarr: Settings -> Media Management -> Root Folder = /data/media/{Series,Movies}"
    log_info "  4. In Prowlarr: Settings -> Apps -> Add Sonarr/Radarr (use http://localhost:8989 / 7878 inside CT)"
    log_info "  5. Follow https://trash-guides.info/Radarr/Radarr-Quality-Settings-File-Size/ and"
    log_info "     https://trash-guides.info/Sonarr/Sonarr-Quality-Settings-File-Size/"
else
    log_success "Starr stack installed (container $container_id) — could not determine IP, check: pct exec $container_id -- hostname -I"
fi

echo ""
log_info "Update later with: bash starr/update.sh"
