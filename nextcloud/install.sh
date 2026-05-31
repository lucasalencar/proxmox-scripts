#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

echo "Starting Nextcloud installation/configuration via LXC container..."

NEXTCLOUD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/nextcloudpi.sh)"'
container_id=$(ensure_container_installed "nextcloud" "$NEXTCLOUD_INSTALL_CMD") || exit 1

echo "Waiting for container to finish first-boot setup..."
for i in $(seq 1 30); do
    if pct exec "$container_id" -- systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'; then
        break
    fi
    sleep 2
done

echo "Disabling ncp-activation Apache site (first-run wizard)..."
pct exec "$container_id" -- a2dissite ncp-activation 2>/dev/null
pct exec "$container_id" -- systemctl reload apache2 2>/dev/null

ADMIN_USER="ncp"
ADMIN_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c 20)
echo "Setting admin user '$ADMIN_USER' password..."
pct exec "$container_id" -- bash -c \
    "OC_PASS='$ADMIN_PASS' sudo -E -u www-data php /var/www/nextcloud/occ user:resetpassword --password-from-env '$ADMIN_USER'" 2>/dev/null

echo ""
echo "Installation complete. Nextcloud is running in container $container_id."
echo ""
echo "──────────────────────────────────────────────────────"
echo "  Admin credentials:"
echo "    User:     $ADMIN_USER"
echo "    Password: $ADMIN_PASS"
echo "──────────────────────────────────────────────────────"
echo ""
echo "Next steps:"
echo "  1. Run ./caddy/generate-caddyfile.sh to configure reverse proxy"
echo "  2. Run ./caddy/trust-nextcloud.sh to trust Caddy integration"
echo "  3. Run ./nextcloud/sync-users.sh to create server users in Nextcloud"
