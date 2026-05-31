#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

echo "Starting Nextcloud installation/configuration via LXC container..."

NEXTCLOUD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/nextcloudpi.sh)"'
container_id=$(ensure_container_installed "nextcloud" "$NEXTCLOUD_INSTALL_CMD") || exit 1

echo ""
echo "Installation complete. Nextcloud is running in container $container_id."
echo ""
echo "Next steps:"
echo "  1. Run ./caddy/generate-caddyfile.sh to configure reverse proxy"
echo "  2. Run ./caddy/trust-nextcloud.sh to trust Caddy integration"
echo "  3. Run ./nextcloud/sync-users.sh to create server users in Nextcloud"
