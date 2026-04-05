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

# Rename GID 1000 to 'familia' for shared access (Lazy migration)
CURRENT_GROUP_NAME=$(getent group 1000 | cut -d: -f1)
if [ "$CURRENT_GROUP_NAME" != "familia" ]; then
    echo "First secondary user detected. Renaming group 1000 ('$CURRENT_GROUP_NAME') to 'familia'..."
    groupmod -n familia "$CURRENT_GROUP_NAME"
fi

# Create user with UID 1001
if id "$SECONDARY_USER" &>/dev/null; then
    echo "User $SECONDARY_USER already exists."
else
    echo "Creating user $SECONDARY_USER with UID 1001..."
    adduser --uid 1001 --shell /usr/sbin/nologin --disabled-password --gecos "" "$SECONDARY_USER"
fi

# Ensure user is in 'familia' group (GID 1000)
echo "Adding $SECONDARY_USER to group 'familia'..."
usermod -aG familia "$SECONDARY_USER"

echo "Secondary user setup complete!"
