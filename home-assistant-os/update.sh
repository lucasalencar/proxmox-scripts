#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

echo "Checking for Home Assistant OS VM updates..."

vm_id=$(get_vm_id_by_name "haos")

if [ -z "$vm_id" ]; then
    echo "Error: Could not find VM 'haos'."
    exit 1
fi

echo "Identified VM ID: $vm_id"

vm_status=$(qm status "$vm_id" | awk '{print $2}')
if [ "$vm_status" != "running" ]; then
    echo "VM $vm_id is not running. Start it to apply updates."
    exit 0
fi

echo "Attempting Home Assistant OS update via guest agent..."
qm guest exec "$vm_id" -- ha core update 2>/dev/null || echo "Could not run 'ha core update' via guest agent."
qm guest exec "$vm_id" -- ha supervisor update 2>/dev/null || echo "Could not run 'ha supervisor update' via guest agent."

echo "Home Assistant OS update process complete!"
