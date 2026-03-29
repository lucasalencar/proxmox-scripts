#!/bin/bash
# This script automates the creation of the storage structure on the ZFS Pool 'tank'.
# It creates the main datasets for media and memories, organizes subfolders,
# and sets up permissions (UID 100000) so Proxmox containers (LXC) can
# read and write to files natively, ensuring performance and isolation.

echo "Creating ZFS datasets (tank/data, media, memorias)..."
zfs create tank/data # Main
zfs create tank/data/media # Movies and Series
zfs create tank/data/memorias # Personal photos and videos

echo "Creating media organization folders..."
mkdir -p /tank/data/media/filmes /tank/data/media/series

echo "Setting up directory permissions (UID 100000 for LXC)..."
chown -R 100000:100000 /tank/data
chmod -R 775 /tank/data

echo "Storage setup complete. Current datasets:"
zfs list
