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

# 2. DISCOVER internal UID of the 'jellyfin' user
internal_uid=$(pct exec "$container_id" -- id -u jellyfin)

if [ -z "$internal_uid" ]; then
    echo "Error: Could not find user 'jellyfin' inside container."
    exit 1
fi

# 3. CONFIGURE Advanced UID Mapping (Container ID -> Host 1000)
setup_lxc_advanced_mapping "$container_id" "$internal_uid"

# 4. Perform bind mounts
echo "Setting up mount: /tank/data/media -> /DATA/Media (mp1)"
pct set "$container_id" -mp1 /tank/data/media,mp=/DATA/Media

echo "Setting up mount: /tank/data/memorias -> /DATA/Gallery (mp2)"
pct set "$container_id" -mp2 /tank/data/memorias,mp=/DATA/Gallery

# 5. Restart container to apply the new mapping configuration
echo "Restarting container $container_id to apply UID mapping..."
pct stop "$container_id" && pct start "$container_id"

echo "Installation and UID Mapping completed for Jellyfin (ID: $container_id)."
