#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Checking for ARR-Stack container updates..."

# The ARR-Stack creates one LXC per app; update each that exists.
ALL_SLUGS=(prowlarr sonarr radarr lidarr readarr bazarr whisparr seerr qbittorrent sabnzbd)

found=0
for s in "${ALL_SLUGS[@]}"; do
    cid=$(get_container_id_by_name "$s")
    [ -z "$cid" ] && continue
    found=1

    log_info "Updating container for $s (ct $cid)..."
    pct exec "$cid" -- apt update
    pct exec "$cid" -- apt upgrade -y

    # Best-effort: upgrade the service package if installed via apt
    pct exec "$cid" -- apt install --only-upgrade "$s" -y 2>/dev/null || \
        log_warning "$s package upgrade skipped (not installed via apt or already latest)."
done

if [ "$found" -eq 0 ]; then
    log_error "No *arr containers found. Run arr/install.sh first."
    exit 1
fi

log_success "ARR-Stack update process complete!"
