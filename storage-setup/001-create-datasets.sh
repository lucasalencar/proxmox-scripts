#!/bin/bash
# This script automates the creation of the storage structure on the ZFS Pool 'tank'.
# It creates the main datasets for media and memories, organizes subfolders,
# and sets up permissions (UID/GID 1000) for both host user and LXC containers.
# Load helper functions
source "$(dirname "$0")/../common/functions.sh"

# Load primary user
PRIMARY_USER=$(get_primary_user) || exit 1

echo "Creating main ZFS datasets (tank/data, media, memorias, documents)..."
zfs create tank/data
zfs create tank/data/media
zfs create tank/data/memorias
zfs create tank/data/documents

# Call generic user dataset creation script for primary user
echo "Creating primary user dataset: $PRIMARY_USER..."
"$(dirname "$0")/create-user-dataset.sh" "$PRIMARY_USER"

# Ensure all datasets are mounted before applying permissions
zfs mount -a

# Useful commands to get zfs dataset config                                                                                                             │
# - Current recordsize (disk page size): `zfs get recordsize tank/data/memorias`                                                                        │
# - Current atime (write last access timestamp): zfs get atime /tank/data/memorias

echo "Setting up media ZFS dataset"
zfs set recordsize=1M tank/data/media # Good for big files (less reads)
zfs set atime=off tank/data/media # Good for disks health (less unnecessary writes)

echo "Setting up memorias ZFS dataset"
zfs set recordsize=1M tank/data/memorias
zfs set atime=off tank/data/memorias

echo "Setting up documents ZFS dataset"
zfs set atime=off tank/data/documents

echo "Creating media organization folders..."
mkdir -p /tank/data/media/Movies /tank/data/media/Series /tank/data/media/Music

echo "Setting up base directory permissions (Primary:$PRIMARY_USER, Group:1000)..."
# Permissions must be applied AFTER datasets are mounted to persist across mountpoints
# Setgid (2770) ensures that new files inherit the group 1000
chown -R "$PRIMARY_USER":1000 /tank/data
chmod -R 2770 /tank/data

# Ensure primary user's private dataset has 700 (re-applying to be safe)
chmod 700 "/tank/data/$PRIMARY_USER"

echo "Storage setup complete. Current datasets:"
zfs list -o name,mountpoint,referenced
