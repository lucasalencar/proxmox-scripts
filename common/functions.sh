#!/bin/bash

# Returns the primary username from .primary_user file
get_primary_user() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local primary_user_file="$script_dir/../.primary_user"

    if [ ! -f "$primary_user_file" ]; then
        echo "Error: .primary_user file not found. Run 001-root-setup.sh first." >&2
        return 1
    fi

    cat "$primary_user_file"
}

# Returns the container ID by its name (partial match, case-insensitive)
# Usage: get_container_id_by_name "name"
get_container_id_by_name() {
    local name="$1"
    if [ -z "$name" ]; then
        return 1
    fi
    pct list | grep -i "$name" | sort -n | tail -1 | awk '{print $1}'
}

# Configures ZFS ACLs for specific users and enables inheritance
# Usage: setup_dataset_acls <dataset_name> <mount_path> <owner_uid> [extra_uids...]
setup_dataset_acls() {
    local dataset="$1"
    local path="$2"
    local owner_uid="$3"
    shift 3
    local extra_uids=("$@")

    echo "Enabling ZFS POSIX ACLs on $dataset..."
    zfs set acltype=posixacl "$dataset"
    zfs set xattr=sa "$dataset"

    echo "Applying ACLs to $path (Owner UID $owner_uid)..."
    # Clear existing ACLs
    setfacl -bnR "$path"

    # Define ACL string starting with owner and group
    local acl_str="u::rwx,g::rwx,o::-,u:$owner_uid:rwx"

    for uid in "${extra_uids[@]}"; do
        acl_str+=",u:$uid:rwx"
    done

    # Apply access ACLs
    setfacl -R -m "$acl_str" "$path"

    # Apply default ACLs (for inheritance)
    setfacl -R -d -m "$acl_str" "$path"

    # Ensure mask is correct
    setfacl -R -m m::rwx "$path"
    setfacl -R -d -m m::rwx "$path"

    echo "ACLs applied to $path (U:$owner_uid, Extra:[${extra_uids[*]}])"
}

# Appends a specific UID to existing ACLs of a path (both access and default)
# Usage: add_dataset_acl <path> <uid>
add_dataset_acl() {
    local path="$1"
    local uid="$2"

    echo "Appending ACL for UID $uid to $path..."
    # Access ACL
    setfacl -R -m "u:$uid:rwx" "$path"
    # Default ACL (for inheritance)
    setfacl -R -d -m "u:$uid:rwx" "$path"
    # Ensure mask is updated
    setfacl -R -m m::rwx "$path"
    setfacl -R -d -m m::rwx "$path"
}

# Fixes internal container permissions from the Host level
# Usage: fix_lxc_internal_permissions <container_id> <path1> <path2> ...
fix_lxc_internal_permissions() {
    local id="$1"
    local host_uid=1000
    local host_gid=1000
    shift
    local paths=("$@")

    echo "Ensuring container $id is fully stopped..."
    pct stop "$id" 2>/dev/null
    while [ "$(pct status "$id")" != "status: stopped" ]; do
        echo "Waiting for container $id to stop..."
        sleep 2
    done

    echo "Mounting container $id rootfs to fix permissions..."
    # Attempt to mount and capture the path
    local mount_output
    mount_output=$(pct mount "$id" 2>&1)
    local mount_path
    mount_path=$(echo "$mount_output" | grep -o '/[^ ]*rootfs' | head -1)

    if [ -z "$mount_path" ] || [ ! -d "$mount_path" ]; then
        # Fallback: check if it's already mounted
        mount_path="/var/lib/lxc/$id/rootfs"
        if [ ! -d "$mount_path" ]; then
            echo "Error: Could not determine mount path. Output: $mount_output"
            return 1
        fi
        echo "Container already mounted at $mount_path"
    else
        echo "Container mounted at $mount_path"
    fi

    for path in "${paths[@]}"; do
        local full_path="${mount_path}${path}"
        if [ -d "$full_path" ]; then
            echo "Fixing permissions for $full_path (Host UID $host_uid)..."
            chown -R "$host_uid":"$host_gid" "$full_path"
        else
            echo "Warning: Path $full_path not found inside container."
        fi
    done

    echo "Unmounting container $id..."
    pct unmount "$id" 2>/dev/null || true
}
