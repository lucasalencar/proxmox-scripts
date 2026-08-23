#!/bin/bash

# Root update script for Proxmox Scripts
# This script finds and executes all update.sh scripts in subdirectories.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/functions.sh"
require_root

echo "Starting global update from $SCRIPT_DIR..."

# Find update scripts based on arguments or discovery
if [ $# -gt 0 ]; then
    echo "Updating specific packages: $@"
    UPDATE_SCRIPTS=""
    for pkg in "$@"; do
        # Clean trailing slashes if any
        pkg_clean="${pkg%/}"
        if [ -f "./$pkg_clean/update.sh" ]; then
            UPDATE_SCRIPTS="$UPDATE_SCRIPTS ./$pkg_clean/update.sh"
        else
            log_warning "No update script found for package '$pkg_clean' (./$pkg_clean/update.sh not found)."
        fi
    done
else
    echo "No packages specified. Discovering all update scripts..."
    # Find all update.sh files in subdirectories (excluding root script)
    UPDATE_SCRIPTS=$(find . -mindepth 2 -name "update.sh" | sort)
fi

if [ -z "$UPDATE_SCRIPTS" ]; then
    log_warning "No update scripts to execute."
    exit 0
fi

for script in $UPDATE_SCRIPTS; do
    script_abs_path=$(realpath "$script")
    script_dir=$(dirname "$script_abs_path")
    script_name=$(basename "$script_dir")

    echo ""
    log_step "Executing update for: $script_name"
    log_info "Path: $script"

    # Execute the script in its own directory
    (cd "$script_dir" && bash "./update.sh") || log_error "Update failed for $script_name. Continuing with others..."
done

echo ""
log_success "All update processes completed!"
