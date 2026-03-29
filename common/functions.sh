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
