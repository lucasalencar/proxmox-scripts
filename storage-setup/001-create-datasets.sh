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

# Ensure all datasets are mounted before applying permissions
zfs mount -a

# Useful commands to get zfs dataset config
# - Current recordsize (disk page size): `zfs get recordsize tank/data/memorias`
# - Current atime (write last access timestamp): zfs get atime /tank/data/memorias

echo "Setting up ZFS optimization properties..."
zfs set recordsize=1M tank/data/media
zfs set atime=off tank/data/media
zfs set recordsize=1M tank/data/memorias
zfs set atime=off tank/data/memorias

echo "Creating media organization folders..."
mkdir -p /tank/data/media/Movies /tank/data/media/Series /tank/data/media/Music

echo "Configuring ZFS ACLs..."

# 1. ROOT (/tank/data): Grant NON-RECURSIVE access so containers can traverse to subfolders.
# We also set Default ACLs so any NEW folder created here inherits these base permissions.
echo "Configuring root traverse permissions and defaults on /tank/data..."
zfs set acltype=posixacl tank/data
zfs set xattr=sa tank/data

chown "$PRIMARY_USER":1000 /tank/data
chmod 2771 /tank/data # 1 at the end allows others to traverse (search)

# Define base permissions string
# u::rwx,g::rwx,o::x -> Owner/Group full, others traverse
# u:1000:rwx,u:100000:rwx -> Host and Container root full access
local root_acl="u::rwx,g::rwx,o::x,u:1000:rwx,u:100000:rwx"

setfacl -b /tank/data # Clear all
setfacl -m "$root_acl" /tank/data
setfacl -d -m "$root_acl" /tank/data # Set as default for inheritance

# 2. SHARED DATA: Apply RECURSIVE access for Media and Memorias

echo "Applying full recursive ACLs to shared datasets..."
setup_dataset_acls tank/data/media /tank/data/media 1000 100000
setup_dataset_acls tank/data/memorias /tank/data/memorias 1000 100000

# 3. PRIVATE DATA: Create/Secure primary user dataset
# This script applies strict ACLs/Permissions only for the user.
echo "Creating/Securing primary user dataset: $PRIMARY_USER..."
"$(dirname "$0")/create-user-dataset.sh" "$PRIMARY_USER"

echo "Storage setup complete. Current datasets:"
zfs list -o name,mountpoint,referenced
