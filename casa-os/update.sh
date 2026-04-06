#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Checking for CasaOS container updates..."

# 1. Identify the container ID
container_id=$(get_container_id_by_name "casaos")

if [ -z "$container_id" ]; then
    echo "Error: Could not find container 'casaos'."
    exit 1
fi

echo "Identified Container ID: $container_id"

# 2. Execute update inside the container
echo "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt upgrade -y

# 3. Specifically update CasaOS components if needed
# CasaOS usually updates via its own script or via apt if installed that way.
# The community script installs it via the official installer which uses a mix.
# But running the official update script is safer for CasaOS.
echo "Running CasaOS update script..."
pct exec "$container_id" -- bash -c "curl -fsSL https://get.casaos.io/update | bash"

echo "CasaOS update and synchronization process complete!"
