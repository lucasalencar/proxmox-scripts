#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting CasaOS installation via LXC container..."

# Execute the Proxmox community script for CasaOS
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/casaos.sh)"

# Use shared function to identify the container ID
container_id=$(get_container_id_by_name "casaos")

# Check if we successfully identified the container ID
if [ -z "$container_id" ]; then
    echo "Error: Could not find a container named 'casaos'."
    echo "Please ensure the installation completed successfully."
    exit 1
fi

echo "Identified Container ID: $container_id"

# Perform bind mounts
echo "Setting up mount: /tank/data/memorias -> /DATA/Gallery (mp1)"
pct set "$container_id" -mp1 /tank/data/memorias,mp=/DATA/Gallery

echo "Setting up mount: /tank/data/media -> /DATA/Media (mp2)"
pct set "$container_id" -mp2 /tank/data/media,mp=/DATA/Media

echo "Setting up mount: /tank/data/documents -> /DATA/Documents (mp3)"
pct set "$container_id" -mp3 /tank/data/documents,mp=/DATA/Documents


echo "Configuration completed for container $container_id."
