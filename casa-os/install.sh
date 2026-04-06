#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting CasaOS installation/configuration via LXC container..."

# 1. Ensure CasaOS is installed
CASAOS_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/casaos.sh)"'
container_id=$(ensure_container_installed "casaos" "$CASAOS_INSTALL_CMD") || exit 1

echo "Identified Container ID: $container_id"
# 2. DISCOVER Primary User for reference
PRIMARY_USER=$(get_primary_user) || exit 1
echo "Primary User reference: $PRIMARY_USER"

# 3. DISCOVER internal UID of the root user (or whoever runs CasaOS)
# Although usually 0, we discover it dynamically for consistency.
internal_uid=$(pct exec "$container_id" -- id -u root)
host_casaos_uid=$((internal_uid + 100000))

echo "CasaOS internal UID: $internal_uid -> Host UID: $host_casaos_uid"

# 4. APPLY ACLs for CasaOS on the mounted datasets
# This ensures CasaOS has full access to shared and private folders
echo "Granting CasaOS (UID $host_casaos_uid) access to datasets..."
add_dataset_acl "/tank/data/media" "$host_casaos_uid"
add_dataset_acl "/tank/data/memorias" "$host_casaos_uid"
add_dataset_acl "/tank/data/$PRIMARY_USER" "$host_casaos_uid"

# 5. Perform bind mounts
# As CasaOS runs as root inside the container (UID 100000 on host),
# it will have full access because we gave UID 100000 access to /tank/data via ACLs.
echo "Setting up mount: /tank/data/memorias -> /DATA/Gallery (mp1)"
pct set "$container_id" -mp1 /tank/data/memorias,mp=/DATA/Gallery

echo "Setting up mount: /tank/data/media -> /DATA/Media (mp2)"
pct set "$container_id" -mp2 /tank/data/media,mp=/DATA/Media

echo "Setting up mount: /tank/data/$PRIMARY_USER -> /DATA/Documents (mp3)"
pct set "$container_id" -mp3 "/tank/data/$PRIMARY_USER,mp=/DATA/Documents"

echo "Installation and Bind Mounts completed for CasaOS (ID: $container_id)."
