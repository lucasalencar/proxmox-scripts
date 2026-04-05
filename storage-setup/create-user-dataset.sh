#!/bin/bash

# Check if username is provided
if [ -z "$1" ]; then
    echo "Error: You must provide a username."
    echo "Usage: $0 <username>"
    exit 1
fi

TARGET_USER=$1

if [[ "$(whoami)" != "root" ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Ensure user exists
if ! id "$TARGET_USER" &>/dev/null; then
    echo "Error: User $TARGET_USER does not exist."
    exit 1
fi

# Check if dataset already exists to avoid errors
if zfs list "tank/data/$TARGET_USER" &>/dev/null; then
    echo "Dataset tank/data/$TARGET_USER already exists. Skipping creation."
else
    echo "Creating private ZFS dataset for '$TARGET_USER' (tank/data/$TARGET_USER)..."
    zfs create "tank/data/$TARGET_USER"
fi

# Ensure it's mounted
zfs mount "tank/data/$TARGET_USER" 2>/dev/null || true

# Apply ownership and private permissions
echo "Applying private permissions (Owner:$TARGET_USER, Group:1000, Perms:700) to /tank/data/$TARGET_USER..."
chown "$TARGET_USER":1000 "/tank/data/$TARGET_USER"
chmod 700 "/tank/data/$TARGET_USER"

echo "Private ZFS dataset for $TARGET_USER setup complete!"
