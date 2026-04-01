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

# 2. Execute update inside the container
echo "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt upgrade -y

# 3. Specifically update Jellyfin and its FFmpeg components
echo "Ensuring Jellyfin packages are up to date..."
pct exec "$container_id" -- apt install --only-upgrade jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg7 -y

# 4. RE-VERIFY UID/GID Mapping and Permissions
# This ensures that any new files or changes from the update still follow the '1000 Club' strategy.
echo "Re-applying UID/GID mapping and fixing internal permissions..."

internal_uid=$(pct exec "$container_id" -- id -u jellyfin)
internal_gid=$(pct exec "$container_id" -- id -g jellyfin)

if [ -n "$internal_uid" ] && [ -n "$internal_gid" ]; then
    setup_lxc_advanced_mapping "$container_id" "$internal_uid" "$internal_gid"

    echo "Stopping container $container_id to ensure permissions are synchronized..."
    pct stop "$container_id"

    fix_lxc_internal_permissions "$container_id" \
        "/var/lib/jellyfin" \
        "/etc/jellyfin" \
        "/var/log/jellyfin" \
        "/var/cache/jellyfin"

    echo "Starting container $container_id with updated packages and correct mapping..."
    pct start "$container_id"
fi

echo "Jellyfin update and synchronization process complete!"
