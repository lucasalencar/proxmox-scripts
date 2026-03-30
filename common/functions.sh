#!/bin/bash

# Returns the container ID by its name (partial match, case-insensitive)
# Usage: get_container_id_by_name "name"
get_container_id_by_name() {
    local name="$1"
    if [ -z "$name" ]; then
        return 1
    fi
    # Search in pct list, sort by ID and take the highest one if multiple exist
    pct list | grep -i "$name" | sort -n | tail -1 | awk '{print $1}'
}

# Configures UID/GID mapping for UID 1000 synchronization ('1000 Club')
# Usage: setup_lxc_uid_mapping <container_id>
setup_lxc_uid_mapping() {
    local container_id="$1"
    local conf_file="/etc/pve/lxc/${container_id}.conf"

    if [ -z "$container_id" ]; then
        echo "Error: Container ID is required for UID mapping."
        return 1
    fi

    if [ ! -f "$conf_file" ]; then
        echo "Error: Configuration file $conf_file not found."
        return 1
    fi

    if ! grep -q "lxc.idmap" "$conf_file"; then
        echo "Injecting UID/GID mapping into $conf_file..."
        cat <<EOF >> "$conf_file"

# UID Mapping for User 1000
lxc.idmap: u 0 100000 1000
lxc.idmap: g 0 100000 1000
lxc.idmap: u 1000 1000 1
lxc.idmap: g 1000 1000 1
lxc.idmap: u 1001 101001 64535
lxc.idmap: g 1001 101001 64535
EOF
        echo "UID mapping configured for container $container_id."
        return 0
    else
        echo "UID mapping already exists for container $container_id."
        return 0
    fi
}
