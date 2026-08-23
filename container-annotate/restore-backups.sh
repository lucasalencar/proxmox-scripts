#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

RESTORED=0

log_step "Restoring config backups"
echo ""

backups=()
for dir in "/etc/pve/lxc" "/etc/pve/qemu-server"; do
    for bak in "$dir"/*.conf.bak; do
        [ -f "$bak" ] || continue
        backups+=("$bak")
    done
done

if [ ${#backups[@]} -eq 0 ]; then
    log_info "No backup files found (*.conf.bak in /etc/pve/lxc or /etc/pve/qemu-server)."
    exit 0
fi

log_info "Found ${#backups[@]} backup(s):"
for bak in "${backups[@]}"; do
    orig="${bak%.bak}"
    echo "  $orig  <-  $(basename "$bak")"
done

echo ""
read -p "Restore all ${#backups[@]} config(s) from backup? (y/N) " confirm

if [[ ! "$confirm" =~ ^[yY] ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
for bak in "${backups[@]}"; do
    orig="${bak%.bak}"
    cp "$bak" "$orig"
    echo "  $CHECK Restored: $(basename "$orig")"
    ((RESTORED++))
done

echo ""
log_success "Done! $RESTORED config file(s) restored."
log_info "Note: The .bak files were kept in place."
