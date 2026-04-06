#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting Jellyfin installation/configuration via LXC container..."

# 1. Ensure Jellyfin is installed
JELLYFIN_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/jellyfin.sh)"'
container_id=$(ensure_container_installed "jellyfin" "$JELLYFIN_INSTALL_CMD") || exit 1

echo "Identified Container ID: $container_id"
# 2. DISCOVER internal UID of the 'jellyfin' user
internal_uid=$(pct exec "$container_id" -- id -u jellyfin)

if [ -z "$internal_uid" ]; then
    echo "Error: Could not find user 'jellyfin' inside container."
    exit 1
fi

# Calculate corresponding host UID
host_jellyfin_uid=$((internal_uid + 100000))

echo "Jellyfin internal UID: $internal_uid -> Host UID: $host_jellyfin_uid"

# 3. APPLY Specific ACLs for Jellyfin UID on Host
# Grant access to media and memories datasets
add_dataset_acl "/tank/data/media" "$host_jellyfin_uid"
add_dataset_acl "/tank/data/memorias" "$host_jellyfin_uid"

# 4. Perform bind mounts
echo "Setting up mount: /tank/data/media -> /DATA/Media (mp1)"
pct set "$container_id" -mp1 /tank/data/media,mp=/DATA/Media

echo "Setting up mount: /tank/data/memorias -> /DATA/Gallery (mp2)"
pct set "$container_id" -mp2 /tank/data/memorias,mp=/DATA/Gallery

# 5. Restart container to ensure mounts are active
echo "Restarting container $container_id..."
pct stop "$container_id" && pct start "$container_id"

echo "Installation and ACL setup completed for Jellyfin (ID: $container_id)."
