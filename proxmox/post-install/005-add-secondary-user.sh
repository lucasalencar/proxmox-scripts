#!/bin/bash

# Check if secondary username is provided
if [ -z "$1" ]; then
    log_error "You must provide a username for the secondary user."
    log_error "Usage: $0 <username>"
    exit 1
fi

SECONDARY_USER=$1

require_root

# Load helper functions
source "$(dirname "$0")/../common/functions.sh"

# Load primary user
PRIMARY_USER=$(get_primary_user) || exit 1

log_step "Setting up secondary user '$SECONDARY_USER' (Primary: $PRIMARY_USER)..."

# 1. Create user with next available UID
if id "$SECONDARY_USER" &>/dev/null; then
    log_info "User $SECONDARY_USER already exists."
    SECONDARY_UID=$(id -u "$SECONDARY_USER")
else
    log_step "Creating user $SECONDARY_USER..."
    # adduser will automatically pick the next UID >= 1001
    adduser --shell /usr/sbin/nologin --disabled-password --gecos "" "$SECONDARY_USER"
    SECONDARY_UID=$(id -u "$SECONDARY_USER")
fi

# 2. Grant access to shared datasets using ACLs
# This ensures the secondary user can read/write shared data
# without needing complex group permissions.
log_step "Granting $SECONDARY_USER (UID $SECONDARY_UID) access to shared datasets..."
add_dataset_acl "/tank/data/media" "$SECONDARY_UID"
add_dataset_acl "/tank/data/memorias" "$SECONDARY_UID"

echo ""
log_success "Secondary user setup complete! Access granted to media and memories datasets."
log_info "Note: If a private dataset is needed for $SECONDARY_USER, run:"
log_info "  ./storage-setup/create-user-dataset.sh $SECONDARY_USER"

# 3. Register user in .server_users
add_user_to_server "$SECONDARY_USER"
