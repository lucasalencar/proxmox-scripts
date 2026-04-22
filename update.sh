#!/bin/bash

# Root update script for Proxmox Scripts
# This script finds and executes all update.sh scripts in subdirectories.

set -e

# Check if the script is running as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Starting global update from $ROOT_DIR..."

# Find all update.sh files in subdirectories
# Exclude the root script itself if it has the same name
UPDATE_SCRIPTS=$(find . -mindepth 2 -name "update.sh" | sort)

if [ -z "$UPDATE_SCRIPTS" ]; then
    echo "No update scripts found in subdirectories."
    exit 0
fi

for script in $UPDATE_SCRIPTS; do
    script_abs_path=$(realpath "$script")
    script_dir=$(dirname "$script_abs_path")
    script_name=$(basename "$script_dir")

    echo "------------------------------------------"
    echo "Executing update for: $script_name"
    echo "Path: $script"
    echo "------------------------------------------"

    # Execute the script in its own directory
    (cd "$script_dir" && bash "./update.sh") || echo "Error updating $script_name. Continuing with others..."

    echo ""
done

echo "------------------------------------------"
echo "All update processes completed!"
echo "------------------------------------------"
