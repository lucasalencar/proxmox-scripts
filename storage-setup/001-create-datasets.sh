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

echo "Setting up media ZFS dataset"
zfs set recordsize=1M tank/data/media # set recordsize to 1M to optimize disk storage performance

echo "Setting up memorias ZFS dataset"
# Command to get current recordsize: `zfs get recordsize tank/data/memorias`
zfs set recordsize=1M tank/data/memorias # set recordsize to 1M to optimize disk storage performance
# Command to get current atime: zfs get atime /tank/data/memorias
zfs set atime=off tank/data/memorias # turn off to avoid updating metadata of file access

echo "Creating media organization folders..."
mkdir -p /tank/data/media/Filmes /tank/data/media/Series

echo "Setting up directory permissions (UID/GID 1000 for '1000 Club')..."
# Permissions must be applied AFTER datasets are mounted to persist across mountpoints
chown -R 1000:1000 /tank/data
chmod -R 770 /tank/data

echo "Storage setup complete. Current datasets:"
zfs list -o name,mountpoint,referenced
