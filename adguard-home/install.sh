#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Starting AdGuard Home installation/configuration via LXC container..."

ADGUARD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/adguard.sh)"'
container_id=$(ensure_container_installed "adguard" "$ADGUARD_INSTALL_CMD") || exit 1

echo "Identified Container ID: $container_id"

pct start "$container_id"

echo "Installation completed for AdGuard Home (ID: $container_id)."
