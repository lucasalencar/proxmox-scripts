#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Checking for Jellyfin container updates..."

# 1. Identify the container ID
container_id=$(get_container_id_by_name "jellyfin")

if [ -z "$container_id" ]; then
    echo "Error: Could not find container 'jellyfin'."
    exit 1
fi

echo "Identified Container ID: $container_id"

# 2. Execute the Proxmox community script (It will detect the installation and offer to update)
echo "Running community update script..."
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/jellyfin.sh)"

# 3. RE-VERIFY UID/GID Mapping and Permissions
# Sometimes updates can reset internal configurations or add new paths.
# We ensure the '1000 Club' synchronization remains active.

echo "Re-applying UID/GID mapping and fixing internal permissions..."

# Discover internal UID/GID again (just in case they changed during update)
internal_uid=$(pct exec "$container_id" -- id -u jellyfin)
internal_gid=$(pct exec "$container_id" -- id -g jellyfin)

if [ -n "$internal_uid" ] && [ -n "$internal_gid" ]; then
    # Ensure mapping is still in .conf
    setup_lxc_advanced_mapping "$container_id" "$internal_uid" "$internal_gid"

    # Stop, fix permissions on host level, and start again
    echo "Restarting and fixing permissions for container $container_id..."
    pct stop "$container_id"

    fix_lxc_internal_permissions "$container_id" \
        "/var/lib/jellyfin" \
        "/etc/jellyfin" \
        "/var/log/jellyfin" \
        "/var/cache/jellyfin"

    pct start "$container_id"
fi

echo "Jellyfin update and synchronization process complete!"
