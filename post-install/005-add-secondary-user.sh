#!/bin/bash

# Check if secondary username is provided
if [ -z "$1" ]; then
    echo "Error: You must provide a username for the secondary user."
    echo "Usage: $0 <username>"
    exit 1
fi

SECONDARY_USER=$1

if [[ "$(whoami)" != "root" ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Load helper functions
source "$(dirname "$0")/../common/functions.sh"

# Load primary user
PRIMARY_USER=$(get_primary_user) || exit 1

echo "Setting up secondary user '$SECONDARY_USER' (Primary: $PRIMARY_USER)..."

# 1. Create user with next available UID
if id "$SECONDARY_USER" &>/dev/null; then
    echo "User $SECONDARY_USER already exists."
    SECONDARY_UID=$(id -u "$SECONDARY_USER")
else
    echo "Creating user $SECONDARY_USER..."
    # adduser will automatically pick the next UID >= 1001
    adduser --shell /usr/sbin/nologin --disabled-password --gecos "" "$SECONDARY_USER"
    SECONDARY_UID=$(id -u "$SECONDARY_USER")
fi

# 2. Grant access to shared datasets using ACLs
# This ensures the secondary user can read/write shared data
# without needing complex group permissions.
echo "Granting $SECONDARY_USER (UID $SECONDARY_UID) access to shared datasets..."
add_dataset_acl "/tank/data/media" "$SECONDARY_UID"
add_dataset_acl "/tank/data/memorias" "$SECONDARY_UID"

echo ""
echo "Secondary user setup complete! Access granted to media and memories datasets."
echo "Note: If a private dataset is needed for $SECONDARY_USER, run:"
echo "  ./storage-setup/create-user-dataset.sh $SECONDARY_USER"
