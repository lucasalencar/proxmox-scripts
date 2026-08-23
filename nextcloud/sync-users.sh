#!/bin/bash

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

log_step "Syncing server users to Nextcloud container..."

container_id=$(get_container_id_by_name "nextcloud")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'nextcloud'."
    exit 1
fi

log_info "Identified Container ID: $container_id"

# Get all registered server users
users=$(get_all_users) || exit 1

created=0
skipped=0

for username in $users; do
    # Check if user already exists in Nextcloud
    if pct exec "$container_id" -- sudo -u www-data php /var/www/nextcloud/occ user:info "$username" &>/dev/null; then
        log_info "User '$username' already exists in Nextcloud. Skipping."
        skipped=$((skipped + 1))
        continue
    fi

    display_name="${username^}"

    log_step "Creating Nextcloud user '$username' (display: '$display_name')..."

    password=$(openssl rand -base64 12)

    pct exec "$container_id" -- sudo -u www-data env "NC_PASS=$password" php /var/www/nextcloud/occ user:add \
        --display-name="$display_name" \
        --password-from-env \
        "$username"
    rc=$?

    if [ $rc -eq 0 ]; then
        log_success "User '$username' created successfully. Temporary password: $password"
        created=$((created + 1))
    else
        log_error "Failed to create user '$username'."
    fi
done

echo ""
log_success "Sync complete! Created: $created, Skipped: $skipped"
