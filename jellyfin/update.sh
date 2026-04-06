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

echo "Jellyfin update and synchronization process complete!"
