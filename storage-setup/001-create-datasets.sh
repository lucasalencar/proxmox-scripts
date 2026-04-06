#!/bin/bash
# This script automates the creation of the storage structure on the ZFS Pool 'tank'.
# It creates the main datasets for media and memories, organizes subfolders,
# and sets up permissions (UID/GID 1000) for both host user and LXC containers.

source "$(dirname "$0")/../common/functions.sh"

# Load primary user
PRIMARY_USER=$(get_primary_user) || exit 1

echo "Creating main ZFS datasets (tank/data, media, memorias)..."
zfs create tank/data
zfs create tank/data/media
zfs create tank/data/memorias

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

echo "Setting up ZFS ACLs for shared data (/tank/data)..."
# Apply ACLs to the root of /tank/data for Host User (1000) and LXC Containers (100000)
# Use owner UID 1000 and add 100000 as extra authorized user
setup_dataset_acls tank/data /tank/data 1000 100000

# Ensure primary user's private dataset has 700 (re-applying to be safe)
# (In create-user-dataset.sh we will also update to use ACLs)
chmod 700 "/tank/data/$PRIMARY_USER"

echo "Storage setup complete. Current datasets:"
zfs list -o name,mountpoint,referenced
