#!/bin/bash
#
# trust-nextcloud.sh — Configures Nextcloud to trust Caddy as reverse proxy
#
# Adds the Caddy domain to Nextcloud trusted_domains, sets the Caddy IP
# as a trusted proxy, and forces HTTPS protocol detection.
#
# Usage:
#   ./trust-nextcloud.sh                                   # auto-detect container + Caddy
#   ./trust-nextcloud.sh --container CONTAINER_ID          # explicit container
#   ./trust-nextcloud.sh --domain marx.home                # parent domain (default: marx.home)
#   ./trust-nextcloud.sh --caddy-ip X.X.X.X                # explicit Caddy IP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

# --- Defaults ---
DOMAIN="marx.home"
NC_CONTAINER=""
CADDY_IP=""

# --- Parse args ---
while [ $# -gt 0 ]; do
    case "$1" in
        --container) NC_CONTAINER="$2"; shift 2 ;;
        --domain)    DOMAIN="$2"; shift 2 ;;
        --caddy-ip)  CADDY_IP="$2"; shift 2 ;;
        *) echo "Usage: $0 [--container ID] [--domain FQDN] [--caddy-ip IP]"; exit 1 ;;
    esac
done

# --- Discover Nextcloud container ---
if [ -z "$NC_CONTAINER" ]; then
    NC_CONTAINER=$(get_container_id_by_name "nextcloud")
    if [ -z "$NC_CONTAINER" ]; then
        NC_CONTAINER=$(get_container_id_by_name "nextcloudpi")
    fi
fi
if [ -z "$NC_CONTAINER" ] || ! pct status "$NC_CONTAINER" &>/dev/null; then
    echo "Error: Nextcloud container not found. Use --container or install Nextcloud first."
    exit 1
fi
if ! pct status "$NC_CONTAINER" 2>/dev/null | grep -q "running"; then
    echo "Starting Nextcloud container $NC_CONTAINER..."
    pct start "$NC_CONTAINER"
    sleep 5
fi
echo "Nextcloud container: $NC_CONTAINER"

# --- Determine subdomain ---
NC_HOSTNAME=$(pct config "$NC_CONTAINER" 2>/dev/null | grep -oP 'hostname:\s*\K\S+')
NC_DOMAIN="${NC_HOSTNAME:-nextcloud}.$DOMAIN"
echo "Target domain: $NC_DOMAIN"

# --- Discover Caddy IP ---
if [ -z "$CADDY_IP" ]; then
    CADDY_ID=$(get_container_id_by_name "caddy")
    if [ -n "$CADDY_ID" ]; then
        CADDY_IP=$(get_container_ip "$CADDY_ID")
    fi
fi
if [ -z "$CADDY_IP" ]; then
    echo "Warning: Could not determine Caddy IP. Set --caddy-ip or ensure Caddy container exists."
    echo "Skipping trusted_proxies and overwriteprotocol config."
fi

# --- Remove Apache HTTP->HTTPS redirect (conflicts with Caddy reverse proxy) ---
echo "Removing Apache HTTP-to-HTTPS redirect rule (port 80)..."
APACHE_CONF="/etc/apache2/sites-available/000-default.conf"
pct exec "$NC_CONTAINER" -- sed -i '/RewriteCond %{HTTPS} !=on/,/RewriteRule/d' "$APACHE_CONF" 2>/dev/null
pct exec "$NC_CONTAINER" -- apache2ctl configtest 2>/dev/null && \
    pct exec "$NC_CONTAINER" -- systemctl reload apache2 2>/dev/null
echo ""

# --- Backup current config.php ---
BACKUP_DIR="/var/backups/nextcloud-config"
echo "Backing up config.php..."
pct exec "$NC_CONTAINER" -- mkdir -p "$BACKUP_DIR" 2>/dev/null
BACKUP_FILE="$BACKUP_DIR/config.php.$(date +%Y%m%d-%H%M%S)"
pct exec "$NC_CONTAINER" -- cp /var/www/nextcloud/config/config.php "$BACKUP_FILE"
echo "Backup saved: $BACKUP_FILE (inside container $NC_CONTAINER)"

echo ""

# --- Detect occ --index support (removed in Nextcloud 30+) ---
if pct exec "$NC_CONTAINER" -- sudo -u www-data php /var/www/nextcloud/occ \
    config:system:set --help 2>/dev/null | grep -q -- "--index"; then
    INDEX_ARG="--index 50"
else
    INDEX_ARG="50"
fi

# --- Add trusted domain ---
echo "Adding $NC_DOMAIN to Nextcloud trusted_domains..."
pct exec "$NC_CONTAINER" -- sudo -u www-data php /var/www/nextcloud/occ \
    config:system:set trusted_domains $INDEX_ARG --value="$NC_DOMAIN" 2>&1 || {
    echo "Error: Failed to add trusted domain. Check container $NC_CONTAINER."
    exit 1
}

# --- Add trusted proxy and overwriteprotocol ---
if [ -n "$CADDY_IP" ]; then
    echo "Adding Caddy IP $CADDY_IP as trusted proxy..."
    pct exec "$NC_CONTAINER" -- sudo -u www-data php /var/www/nextcloud/occ \
        config:system:set trusted_proxies $INDEX_ARG --value="$CADDY_IP" 2>&1

    echo "Setting overwriteprotocol to https..."
    pct exec "$NC_CONTAINER" -- sudo -u www-data php /var/www/nextcloud/occ \
        config:system:set overwriteprotocol --value="https" 2>&1
fi

echo ""
echo "Done! Nextcloud ($NC_CONTAINER) configured to trust Caddy."
echo "  Domain:         $NC_DOMAIN"
echo "  Trusted proxies:${CADDY_IP:+ $CADDY_IP}${CADDY_IP:- (not set)}"
echo ""
echo "You can now run: caddy/generate-caddyfile.sh"
