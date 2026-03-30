#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting CasaOS installation via LXC container..."

# 1. Install via Community Script
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/casaos.sh)"

container_id=$(get_container_id_by_name "casaos")

if [ -z "$container_id" ]; then
    echo "Error: Could not find container 'casaos'."
    exit 1
fi

echo "Identified Container ID: $container_id"

# 2. CONFIGURE mapping for CasaOS Root (UID 0) to Host User (UID 1000)
# Since CasaOS handles apps as root, mapping UID 0 is the key.
setup_lxc_advanced_mapping "$container_id" 0

# 3. Perform bind mounts
echo "Setting up mount: /tank/data/memorias -> /DATA/Gallery (mp1)"
pct set "$container_id" -mp1 /tank/data/memorias,mp=/DATA/Gallery

echo "Setting up mount: /tank/data/media -> /DATA/Media (mp2)"
pct set "$container_id" -mp2 /tank/data/media,mp=/DATA/Media

# 4. Restart container to apply the new mapping configuration
echo "Restarting container $container_id to apply UID mapping..."
pct stop "$container_id" && pct start "$container_id"

echo "Installation and UID Mapping completed for CasaOS (ID: $container_id)."
