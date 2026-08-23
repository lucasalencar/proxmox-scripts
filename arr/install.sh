#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Starting ARR-Stack installation/configuration..."

# The ARR-Stack community script (community-scripts/ProxmoxVED, beta) creates
# ONE LXC per selected app (prowlarr, sonarr, radarr, lidarr, readarr, bazarr,
# whisparr, seerr, qbittorrent, sabnzbd), wires them together via their HTTP
# APIs, then writes /root/arr-stack-summary.txt on the PVE host.
ARR_STACK_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/tools/arr-stack.sh)"'

# All app slugs the installer can create
ALL_SLUGS=(prowlarr sonarr radarr lidarr readarr bazarr whisparr seerr qbittorrent sabnzbd)

MEDIA_DATASET="/tank/data/media"
DOWNLOADS_DATASET="/tank/data/downloads"

# Run the installer only if no *arr container already exists (avoid duplicates)
already=0
for s in "${ALL_SLUGS[@]}"; do
    if [ -n "$(get_container_id_by_name "$s")" ]; then
        already=1
        break
    fi
done

if [ "$already" -eq 0 ]; then
    log_info "No existing *arr containers found. Launching interactive ARR-Stack installer..."
    log_warning "The installer is interactive (whiptail): pick apps, network, IPs and the qBittorrent password."
    bash -c "$ARR_STACK_INSTALL_CMD"
else
    log_warning "Existing *arr containers detected — skipping installer to avoid duplicates."
fi

# Discover created containers and collect the host UIDs that need dataset access
host_uids=()
for s in "${ALL_SLUGS[@]}"; do
    cid=$(get_container_id_by_name "$s")
    [ -z "$cid" ] && continue

    # The service user inside the container usually shares the slug name
    internal_uid=$(pct exec "$cid" -- id -u "$s" 2>/dev/null)
    if [ -n "$internal_uid" ]; then
        host_uid=$((internal_uid + 100000))
        log_info "$s (ct $cid) internal UID $internal_uid -> host UID $host_uid"
        if [[ ! " ${host_uids[*]} " =~ " $host_uid " ]]; then
            host_uids+=("$host_uid")
        fi
    else
        log_warning "Could not resolve internal UID for user '$s' in ct $cid."
    fi
done

if [ ${#host_uids[@]} -eq 0 ]; then
    log_error "No *arr service users found in any container. Aborting ACL/mount setup."
    exit 1
fi

# Apply ACLs once per unique host UID on each existing dataset
for ds in "$MEDIA_DATASET" "$DOWNLOADS_DATASET"; do
    if [ ! -d "$ds" ]; then
        log_warning "Dataset $ds not found on host; skipping its ACLs."
        continue
    fi
    for uid in "${host_uids[@]}"; do
        add_dataset_acl "$ds" "$uid"
    done
done

# Bind mounts per container (stop -> set -> start)
for s in "${ALL_SLUGS[@]}"; do
    cid=$(get_container_id_by_name "$s")
    [ -z "$cid" ] && continue

    needs_media=0
    needs_dl=0
    case "$s" in
        sonarr|radarr|lidarr|readarr|bazarr|whisparr) needs_media=1; needs_dl=1 ;;
        qbittorrent|sabnzbd) needs_dl=1 ;;
        *) needs_media=0; needs_dl=0 ;;
    esac

    pct stop "$cid" 2>/dev/null

    mp=1
    if [ "$needs_media" -eq 1 ] && [ -d "$MEDIA_DATASET" ]; then
        log_step "ct $cid ($s): mount $MEDIA_DATASET -> /DATA/Media (mp$mp)"
        pct set "$cid" -mp$mp "$MEDIA_DATASET,mp=/DATA/Media"
        mp=$((mp + 1))
    fi
    if [ "$needs_dl" -eq 1 ] && [ -d "$DOWNLOADS_DATASET" ]; then
        log_step "ct $cid ($s): mount $DOWNLOADS_DATASET -> /DATA/Downloads (mp$mp)"
        pct set "$cid" -mp$mp "$DOWNLOADS_DATASET,mp=/DATA/Downloads"
    fi

    pct start "$cid" 2>/dev/null
done

log_success "ARR-Stack install + ACL/mount wiring complete."
log_info "Review /root/arr-stack-summary.txt on the PVE host for URLs, API keys and credentials."
log_info "Manual steps still required:"
log_info " - Prowlarr: add indexers"
log_info " - Sonarr/Radarr/Lidarr: set root folder (/DATA/Media) + quality profile"
