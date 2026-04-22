#!/bin/bash

echo "Starting Nextcloud installation/configuration via LXC container..."

NEXTCLOUD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/nextcloudpi.sh)"'
container_id=$(ensure_container_installed "nextcloud" "$NEXTCLOUD_INSTALL_CMD") || exit 1
