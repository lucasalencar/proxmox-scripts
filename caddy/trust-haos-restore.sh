#!/bin/bash
#
# trust-haos-restore.sh — Restores HA OS configuration.yaml from backup
#
# Usage:
#   ./trust-haos-restore.sh                     # restore latest backup
#   ./trust-haos-restore.sh --list              # list available backups
#   ./trust-haos-restore.sh --backup FILE       # restore specific backup
#   ./trust-haos-restore.sh --vmid VMID         # explicit VM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

BACKUP_DIR="/var/backups/haos-config"
HA_VMID=""
RESTORE_FILE=""
MODE="restore"

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid)    HA_VMID="$2"; shift 2 ;;
        --backup)  RESTORE_FILE="$2"; shift 2 ;;
        --list)    MODE="list"; shift ;;
        *) echo "Usage: $0 [--vmid VMID] [--backup FILE] [--list]"; exit 1 ;;
    esac
done

# --- List mode ---
if [ "$MODE" = "list" ]; then
    echo "Available backups in $BACKUP_DIR:"
    if ! ls -1t "$BACKUP_DIR"/configuration.yaml.* 2>/dev/null; then
        echo "  (no backups found)"
    fi
    exit 0
fi

# --- Discover HA VM ---
if [ -z "$HA_VMID" ]; then
    HA_VMID=$(get_vm_id_by_name "haos")
fi
if [ -z "$HA_VMID" ] || ! qm status "$HA_VMID" &>/dev/null; then
    echo "Error: HA OS VM not found. Use --vmid or create the VM first."
    exit 1
fi
echo "HA OS VM: $HA_VMID"

# --- Resolve backup file ---
if [ -z "$RESTORE_FILE" ]; then
    RESTORE_FILE=$(ls -t "$BACKUP_DIR"/configuration.yaml.* 2>/dev/null | head -1)
    if [ -z "$RESTORE_FILE" ]; then
        echo "Error: No backups found in $BACKUP_DIR"
        exit 1
    fi
    echo "Using latest backup: $RESTORE_FILE"
else
    echo "Using specified backup: $RESTORE_FILE"
fi

if [ ! -f "$RESTORE_FILE" ]; then
    echo "Error: Backup file not found: $RESTORE_FILE"
    exit 1
fi

# --- Dependencies ---
if ! command -v guestfish &>/dev/null; then
    echo "Installing libguestfs-tools..."
    apt-get install -y -qq libguestfs-tools 2>/dev/null || {
        apt-get update -qq && apt-get install -y -qq libguestfs-tools
    }
fi

# --- Stop VM gracefully ---
echo "Shutting down VM $HA_VMID..."
if qm shutdown "$HA_VMID" --timeout 60 2>/dev/null; then
    for i in $(seq 1 30); do
        qm status "$HA_VMID" 2>/dev/null | grep -q "stopped" && break
        sleep 2
    done
fi
if qm status "$HA_VMID" 2>/dev/null | grep -q "running"; then
    echo "Force stopping VM $HA_VMID..."
    qm stop "$HA_VMID"
fi
sleep 3

# --- Restore config via guestfish ---
DISK_DEVICE="/dev/pve/vm-${HA_VMID}-disk-0"

echo "Locating hassos-data partition..."
DATA_DEVICE=$(guestfish --ro -a "$DISK_DEVICE" run : findfs-label hassos-data 2>/dev/null)
if [ -z "$DATA_DEVICE" ]; then
    echo "Error: Could not find hassos-data partition on disk."
    exit 1
fi
echo "Data partition: $DATA_DEVICE"

echo "Restoring configuration.yaml from backup..."
guestfish --rw -a "$DISK_DEVICE" <<GUESTFISH
run
mount $DATA_DEVICE /
upload $RESTORE_FILE /supervisor/homeassistant/configuration.yaml
GUESTFISH

if [ $? -ne 0 ]; then
    echo "Error: Failed to write backup to disk."
    exit 1
fi

# --- Start VM ---
echo "Starting VM $HA_VMID..."
qm start "$HA_VMID"

echo ""
echo "Done! HA OS VM $HA_VMID restored from backup."
