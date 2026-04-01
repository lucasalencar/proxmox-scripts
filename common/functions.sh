#!/bin/bash

# Returns the container ID by its name (partial match, case-insensitive)
# Usage: get_container_id_by_name "name"
get_container_id_by_name() {
    local name="$1"
    if [ -z "$name" ]; then
        return 1
    fi
    pct list | grep -i "$name" | sort -n | tail -1 | awk '{print $1}'
}

# Configures ADVANCED UID/GID mapping for specific internal IDs to host 1000
# Usage: setup_lxc_advanced_mapping <container_id> <internal_uid> [internal_gid]
setup_lxc_advanced_mapping() {
    local id="$1"
    local int_uid="$2"
    local int_gid="${3:-$int_uid}" # Default GID to UID if not provided
    local conf_file="/etc/pve/lxc/${id}.conf"
    local host_id=1000

    if [ -z "$id" ] || [ -z "$int_uid" ]; then
        echo "Error: Container ID and Internal UID are required."
        return 1
    fi

    echo "Configuring mapping: Container (U:$int_uid, G:$int_gid) -> Host 1000"

    # Remove any existing idmap lines to avoid duplicates/conflicts
    sed -i '/lxc.idmap/d' "$conf_file"

    # --- UID Mapping (u) ---
    local u_range1=$int_uid
    local u_range2_start=$((int_uid + 1))
    local u_range2_count=$((65536 - int_uid - 1))

    # --- GID Mapping (g) ---
    local g_range1=$int_gid
    local g_range2_start=$((int_gid + 1))
    local g_range2_count=$((65536 - int_gid - 1))

    cat <<EOF >> "$conf_file"
lxc.idmap: u 0 100000 $u_range1
lxc.idmap: u $int_uid $host_id 1
lxc.idmap: u $u_range2_start $((100000 + u_range2_start)) $u_range2_count
lxc.idmap: g 0 100000 $g_range1
lxc.idmap: g $int_gid $host_id 1
lxc.idmap: g $g_range2_start $((100000 + g_range2_start)) $g_range2_count
EOF

    echo "Mapping injected into $conf_file."
}

# Fixes internal container permissions from the Host level using pct mount
# Usage: fix_lxc_internal_permissions <container_id> <path1> <path2> ...
fix_lxc_internal_permissions() {
    local id="$1"
    local host_uid=1000
    local host_gid=1000
    shift
    local paths=("$@")

    echo "Mounting container $id rootfs to fix permissions..."
    # pct mount returns the mount point path
    local mount_path=$(pct mount "$id" | awk '{print $NF}')

    if [ -z "$mount_path" ] || [ ! -d "$mount_path" ]; then
        echo "Error: Could not mount container $id rootfs."
        return 1
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
    pct unmount "$id"
}
