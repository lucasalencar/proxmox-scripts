#!/bin/bash

# Datasets controlled by ZFS
zfs create tank/data # Main
zfs create tank/data/media # Movies and Series
zfs create tank/data/memorias # Personal photos and videos

# Create media organization folders
mkdir -p /tank/data/media/filmes /tank/data/media/series

# Setup dir permissions
chown -R 100000:100000 /tank/data # Change ownership to default containers user
chmod -R 775 /tank/data


# List of all datastes created
zfs list
