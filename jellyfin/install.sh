#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting Jellyfin installation via LXC container..."

# 1. Install via Community Script
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/jellyfin.sh)"

container_id=$(get_container_id_by_name "jellyfin")

if [ -z "$container_id" ]; then
    echo "Error: Could not find container 'jellyfin'."
    exit 1
fi

echo "Identified Container ID: $container_id"

# 2. DISCOVER internal UID and GID of the 'jellyfin' user
internal_uid=$(pct exec "$container_id" -- id -u jellyfin)
internal_gid=$(pct exec "$container_id" -- id -g jellyfin)

if [ -z "$internal_uid" ] || [ -z "$internal_gid" ]; then
    echo "Error: Could not find user 'jellyfin' inside container."
    exit 1
fi

# 3. CONFIGURE Advanced UID/GID Mapping (Host Level)
setup_lxc_advanced_mapping "$container_id" "$internal_uid" "$internal_gid"

# 4. FIX Internal Permissions (from Host Level using pct mount)
echo "Stopping container $container_id to fix permissions..."
pct stop "$container_id"

fix_lxc_internal_permissions "$container_id" \
    "/var/lib/jellyfin" \
    "/etc/jellyfin" \
    "/var/log/jellyfin" \
    "/var/cache/jellyfin"

# 5. Perform bind mounts
echo "Setting up mount: /tank/data/media -> /DATA/Media (mp1)"
pct set "$container_id" -mp1 /tank/data/media,mp=/DATA/Media

echo "Setting up mount: /tank/data/memorias -> /DATA/Gallery (mp2)"
pct set "$container_id" -mp2 /tank/data/memorias,mp=/DATA/Gallery

# 6. Restart container to apply the new mapping configuration
echo "Starting container $container_id with correct UID/GID mapping..."
pct start "$container_id"

echo "Installation and UID/GID Mapping completed for Jellyfin (ID: $container_id)."
