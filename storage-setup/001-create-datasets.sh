#!/bin/bash
# This script automates the creation of the storage structure on the ZFS Pool 'tank'.
# It creates the main datasets for media and memories, organizes subfolders,
# and sets up permissions (UID 100000) so Proxmox containers (LXC) can
# read and write to files natively, ensuring performance and isolation.

# Datasets controlled by ZFS
zfs create tank/data # Main
zfs create tank/data/media # Movies and Series
zfs create tank/data/memorias # Personal photos and videos

# Create media organization folders
mkdir -p /tank/data/media/filmes /tank/data/media/series

# Setup dir permissions
chown -R 100000:100000 /tank/data # Change ownership to default containers user
chmod -R 775 /tank/data

# List all created datasets
zfs list
