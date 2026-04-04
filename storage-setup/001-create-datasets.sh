#!/bin/bash
# This script automates the creation of the storage structure on the ZFS Pool 'tank'.
# It creates the main datasets for media and memories, organizes subfolders,
# and sets up permissions (UID/GID 1000) for both host user and LXC containers.

echo "Creating ZFS datasets (tank/data, media, memorias, documents)..."
zfs create tank/data
zfs create tank/data/media
zfs create tank/data/memorias
zfs create tank/data/documents

# Ensure all datasets are mounted before applying permissions
zfs mount -a

# Useful commands to get zfs dataset config
# - Current recordsize (disk page size): `zfs get recordsize tank/data/memorias`
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
mkdir -p /tank/data/media/Filmes /tank/data/media/Series

echo "Setting up directory permissions (UID/GID 1000 for '1000 Club')..."
# Permissions must be applied AFTER datasets are mounted to persist across mountpoints
chown -R 1000:1000 /tank/data
chmod -R 770 /tank/data

echo "Storage setup complete. Current datasets:"
zfs list -o name,mountpoint,referenced
