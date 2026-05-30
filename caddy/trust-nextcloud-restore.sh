#!/bin/bash
#
# trust-nextcloud-restore.sh — Restores Nextcloud config.php from backup
#
# Usage:
#   ./trust-nextcloud-restore.sh                        # restore latest backup
#   ./trust-nextcloud-restore.sh --list                 # list available backups
#   ./trust-nextcloud-restore.sh --backup FILE          # restore specific backup
#   ./trust-nextcloud-restore.sh --container CONTAINER  # explicit container

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

BACKUP_DIR="/var/backups/nextcloud-config"
NC_CONTAINER=""
RESTORE_FILE=""
MODE="restore"

while [ $# -gt 0 ]; do
    case "$1" in
        --container) NC_CONTAINER="$2"; shift 2 ;;
        --backup)    RESTORE_FILE="$2"; shift 2 ;;
        --list)      MODE="list"; shift ;;
        *) echo "Usage: $0 [--container ID] [--backup FILE] [--list]"; exit 1 ;;
    esac
done

# --- Discover Nextcloud container ---
if [ -z "$NC_CONTAINER" ]; then
    NC_CONTAINER=$(get_container_id_by_name "nextcloud")
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

# --- List mode ---
if [ "$MODE" = "list" ]; then
    echo "Available backups inside container $NC_CONTAINER ($BACKUP_DIR):"
    pct exec "$NC_CONTAINER" -- ls -1t "$BACKUP_DIR"/config.php.* 2>/dev/null || \
        echo "  (no backups found)"
    exit 0
fi

# --- Ensure backup dir exists ---
pct exec "$NC_CONTAINER" -- mkdir -p "$BACKUP_DIR" 2>/dev/null

# --- Resolve backup file ---
if [ -z "$RESTORE_FILE" ]; then
    RESTORE_FILE=$(pct exec "$NC_CONTAINER" -- ls -t "$BACKUP_DIR"/config.php.* 2>/dev/null | head -1 | tr -d '\r')
    if [ -z "$RESTORE_FILE" ]; then
        echo "Error: No backups found in $BACKUP_DIR inside container $NC_CONTAINER."
        echo "Run trust-nextcloud.sh first to create a backup."
        exit 1
    fi
    echo "Using latest backup: $RESTORE_FILE"
else
    echo "Using specified backup: $RESTORE_FILE"
fi

# --- Verify backup exists inside container ---
if ! pct exec "$NC_CONTAINER" -- test -f "$RESTORE_FILE" 2>/dev/null; then
    echo "Error: Backup file not found inside container: $RESTORE_FILE"
    exit 1
fi

# --- Backup current config before restoring (safety net) ---
CURRENT_BACKUP="$BACKUP_DIR/config.php.pre-restore.$(date +%Y%m%d-%H%M%S)"
pct exec "$NC_CONTAINER" -- cp /var/www/nextcloud/config/config.php "$CURRENT_BACKUP" 2>/dev/null
echo "Current config backed up: $CURRENT_BACKUP"

# --- Restore ---
echo "Restoring config.php from backup..."
pct exec "$NC_CONTAINER" -- cp "$RESTORE_FILE" /var/www/nextcloud/config/config.php

if [ $? -ne 0 ]; then
    echo "Error: Failed to restore config.php."
    exit 1
fi

# --- Fix permissions ---
pct exec "$NC_CONTAINER" -- chown www-data:www-data /var/www/nextcloud/config/config.php
pct exec "$NC_CONTAINER" -- chmod 640 /var/www/nextcloud/config/config.php

echo ""
echo "Done! Nextcloud ($NC_CONTAINER) config.php restored from backup."
echo "  Restored: $RESTORE_FILE"
echo ""
echo "To verify: pct exec $NC_CONTAINER -- sudo -u www-data php /var/www/nextcloud/occ config:list"
