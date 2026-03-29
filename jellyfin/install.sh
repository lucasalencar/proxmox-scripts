#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting Jellyfin installation via LXC container..."

# Execute the Proxmox community script for Jellyfin
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/jellyfin.sh)"

# Use shared function to identify the container ID
container_id=$(get_container_id_by_name "jellyfin")

# Check if we successfully identified the container ID
if [ -z "$container_id" ]; then
    echo "Error: Could not find a container named 'jellyfin'."
    echo "Please ensure the installation completed successfully."
    exit 1
fi

echo "Identified Container ID: $container_id"

# Examples of bind mounts for Jellyfin (adjust paths as needed)
# echo "Setting up mount: /tank/data/media -> /DATA/Media (mp1)"
# pct set "$container_id" -mp1 /tank/data/media,mp=/DATA/Media

echo "Configuration completed for container $container_id."
