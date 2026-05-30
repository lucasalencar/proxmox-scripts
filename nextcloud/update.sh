#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Checking for Nextcloud container updates..."

container_id=$(get_container_id_by_name "nextcloud")

if [ -z "$container_id" ]; then
    echo "Error: Could not find container 'nextcloud'."
    exit 1
fi

echo "Identified Container ID: $container_id"

echo "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt upgrade -y

echo "Running NextcloudPi update..."
pct exec "$container_id" -- bash -c "ncp-update 2>/dev/null || sudo -u www-data php /var/www/nextcloud/occ upgrade 2>/dev/null || echo 'Automatic update not available; use ncp-config for manual update.'"

echo "Nextcloud update process complete!"
