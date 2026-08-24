#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

DATASET="tank/data/nextcloud"
MOUNT_PATH="/tank/data/nextcloud"

log_step "Starting Nextcloud storage setup..."
echo ""

container_id=$(get_container_id_by_name "nextcloud")
if [ -z "$container_id" ]; then
    log_error "Nextcloud container not found. Run install.sh first."
    exit 1
fi
log_info "Found Nextcloud container (ID: $container_id)"

log_step "Discovering Nextcloud data directory..."
data_dir=$(pct exec "$container_id" -- grep "'datadirectory'" /var/www/nextcloud/config/config.php 2>/dev/null | grep -oP "=>\s*'\K[^']+")
if [ -z "$data_dir" ]; then
        log_info "Could not read from config.php, checking common paths..."
    for candidate in /mnt/ncdata /var/www/nextcloud/data; do
        if pct exec "$container_id" -- test -d "$candidate" 2>/dev/null; then
            data_dir="$candidate"
            break
        fi
    done
fi
if [ -z "$data_dir" ]; then
    log_error "Could not determine Nextcloud data directory."
    exit 1
fi
log_info "Data directory: $data_dir"

log_step "Discovering www-data UID..."
wwwdata_internal_uid=$(pct exec "$container_id" -- id -u www-data)
if [ -z "$wwwdata_internal_uid" ]; then
    log_error "Could not find www-data user inside container."
    exit 1
fi
host_wwwdata_uid=$((wwwdata_internal_uid + 100000))
log_info "www-data internal UID: $wwwdata_internal_uid -> Host UID: $host_wwwdata_uid"

CONTAINER_ROOT_UID=100000
log_info "Container root maps to host UID: $CONTAINER_ROOT_UID"

if zfs list "$DATASET" &>/dev/null; then
    log_info "Dataset $DATASET already exists."
else
    log_step "Creating ZFS dataset $DATASET..."
    zfs create "$DATASET"
fi
zfs mount "$DATASET" 2>/dev/null || true

PRIMARY_USER=$(get_primary_user) || exit 1
PRIMARY_UID=$(id -u "$PRIMARY_USER")
log_step "Applying ACLs for www-data (UID $host_wwwdata_uid), container root (UID $CONTAINER_ROOT_UID), and $PRIMARY_USER (UID $PRIMARY_UID)..."

echo "# Nextcloud data directory" > "$MOUNT_PATH/.ncdata"

setup_dataset_acls "$DATASET" "$MOUNT_PATH" "$host_wwwdata_uid" "$PRIMARY_UID"
add_dataset_acl "$MOUNT_PATH" "$CONTAINER_ROOT_UID"

if pct config "$container_id" | grep -qP "^mp\d+:\s*[^,]+,\s*mp=$data_dir$"; then
    log_info "Bind mount for $data_dir already exists in container config. Skipping mount setup."
else
    log_step "Stopping Apache inside container..."
    pct exec "$container_id" -- systemctl stop apache2 2>/dev/null || true

    # Find next available mount index
    mp_idx=1
    while pct config "$container_id" 2>/dev/null | grep -qP "^mp${mp_idx}:"; do
        mp_idx=$((mp_idx + 1))
    done

    log_step "Setting up bind mount (mp${mp_idx}): $MOUNT_PATH -> $data_dir"
    apply_mounts "$container_id" "$MOUNT_PATH,mp=$data_dir" "$mp_idx"
fi

log_step "Ensuring temporary directory exists..."
pct exec "$container_id" -- mkdir -p "${data_dir}/tmp" 2>/dev/null || true

log_step "Waiting for Apache to start..."
for i in $(seq 1 30); do
    if pct exec "$container_id" -- systemctl is-active --quiet apache2 2>/dev/null; then
        log_success "Apache is running."
        break
    fi
    sleep 2
done

log_step "Rebuilding file cache..."
pct exec "$container_id" -- sudo -u www-data php /var/www/nextcloud/occ files:scan --all 2>/dev/null || true

echo ""
log_success "Storage setup complete. Nextcloud data directory ($data_dir) is now on $DATASET (HDD)."
