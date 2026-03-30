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

# Configures ADVANCED UID/GID mapping for specific internal ID to host 1000
# Usage: setup_lxc_advanced_mapping <container_id> <internal_id>
setup_lxc_advanced_mapping() {
    local id="$1"
    local int_id="$2"
    local conf_file="/etc/pve/lxc/${id}.conf"
    local host_id=1000

    if [ -z "$id" ] || [ -z "$int_id" ]; then
        echo "Error: Container ID and Internal UID are required."
        return 1
    fi

    echo "Configuring mapping: Container UID $int_id -> Host UID $host_id"

    # Remove any existing idmap lines to avoid duplicates/conflicts
    sed -i '/lxc.idmap/d' "$conf_file"

    # Calculate ranges
    local range1=$int_id
    local range2_start=$((int_id + 1))
    local range2_count=$((65536 - int_id - 1))

    cat <<EOF >> "$conf_file"
# UID Mapping: Container $int_id -> Host $host_id
lxc.idmap: u 0 100000 $range1
lxc.idmap: g 0 100000 $range1
lxc.idmap: u $int_id $host_id 1
lxc.idmap: g $int_id $host_id 1
lxc.idmap: u $range2_start $((100000 + range2_start)) $range2_count
lxc.idmap: g $range2_start $((100000 + range2_start)) $range2_count
EOF

    echo "Mapping injected into $conf_file."
}
