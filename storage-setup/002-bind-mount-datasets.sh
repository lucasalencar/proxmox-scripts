#!/bin/bash

# Usage: ./002-bind-mount-datasets.sh <vmid> [subfolder1] [subfolder2] ...
# Example: ./002-bind-mount-datasets.sh 101 memorias filmes

if [ -z "$1" ]; then
    echo "Usage: $0 <vmid> [subfolder1] [subfolder2] ..."
    exit 1
fi

container_id=$1
shift # Remove vmid from the list of arguments

# 1. Default mount: Always map /tank/data to /DATA/tank as mp0
echo "Setting up default mount: /tank/data -> /DATA/tank (mp0)"
pct set "$container_id" -mp0 /tank/data,mp=/DATA/tank

# 2. Dynamic mounts for additional sub-datasets
# Start from mp1 since mp0 is taken
mp_index=1

for folder in "$@"; do
    echo "Setting up additional mount: /tank/data/$folder -> /DATA/tank/$folder (mp$mp_index)"

    # Check if the dataset/folder exists on host to avoid errors (optional but safer)
    if [ ! -d "/tank/data/$folder" ]; then
        echo "Warning: Host path /tank/data/$folder does not exist. The container might fail to start if not created later."
    fi

    pct set "$container_id" "-mp$mp_index" "/tank/data/$folder,mp=/DATA/tank/$folder"

    ((mp_index++))
done

echo "Configuration for LXC $container_id updated."
