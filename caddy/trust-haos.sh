#!/bin/bash
#
# trust-haos.sh — Configures HA OS to trust Caddy as reverse proxy
#
# Usage:
#   ./trust-haos.sh                    # auto-detect VM and Caddy
#   ./trust-haos.sh --vmid 100         # explicit VM
#   ./trust-haos.sh --caddy-ip X.X.X.X # custom Caddy IP (no container)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

# --- Parse args ---
HA_VMID=""
CADDY_IP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid)    HA_VMID="$2"; shift 2 ;;
        --caddy-ip) CADDY_IP="$2"; shift 2 ;;
        *) echo "Usage: $0 [--vmid VMID] [--caddy-ip IP]"; exit 1 ;;
    esac
done

# --- Discover HA VM ---
if [ -z "$HA_VMID" ]; then
    HA_VMID=$(get_vm_id_by_name "haos")
fi
if [ -z "$HA_VMID" ] || ! qm status "$HA_VMID" &>/dev/null; then
    echo "Error: HA OS VM not found. Use --vmid or create the VM first."
    exit 1
fi
echo "HA OS VM: $HA_VMID"

# --- Discover Caddy IP ---
if [ -z "$CADDY_IP" ]; then
    CADDY_ID=$(get_container_id_by_name "caddy")
    if [ -n "$CADDY_ID" ]; then
        CADDY_IP=$(get_container_ip "$CADDY_ID")
    fi
fi
if [ -z "$CADDY_IP" ]; then
    echo "Error: Could not determine Caddy IP. Use --caddy-ip or ensure Caddy container exists."
    exit 1
fi
echo "Caddy IP: $CADDY_IP"

# --- Dependencies ---
if ! command -v guestfish &>/dev/null; then
    echo "Installing libguestfs-tools..."
    apt-get install -y -qq libguestfs-tools 2>/dev/null || {
        apt-get update -qq && apt-get install -y -qq libguestfs-tools
    }
fi

if ! python3 -c "import yaml" &>/dev/null; then
    echo "Installing python3-yaml..."
    apt-get install -y -qq python3-yaml
fi

# --- Stop VM ---
echo "Stopping VM $HA_VMID..."
qm stop "$HA_VMID"

# --- Inject config via guestfish ---
TEMP_CONFIG="/tmp/ha-config-${HA_VMID}.yaml"
DISK_DEVICE="/dev/pve/vm-${HA_VMID}-disk-0"

echo "Reading current configuration..."
guestfish --add "$DISK_DEVICE" -i \
    download /supervisor/homeassistant/configuration.yaml "$TEMP_CONFIG" 2>/dev/null || {
    echo "No existing configuration.yaml, starting fresh."
    echo "{}" > "$TEMP_CONFIG"
}

echo "Merging proxy configuration..."
python3 -c "
import yaml
with open('$TEMP_CONFIG') as f:
    config = yaml.safe_load(f) or {}
if 'http' not in config:
    config['http'] = {}
config['http']['use_x_forwarded_for'] = True
proxies = config['http'].setdefault('trusted_proxies', [])
caddy_ip = '$CADDY_IP'
if caddy_ip not in proxies:
    proxies.append(caddy_ip)
with open('$TEMP_CONFIG', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
"

echo "Writing configuration back..."
guestfish --add "$DISK_DEVICE" -i \
    upload "$TEMP_CONFIG" /supervisor/homeassistant/configuration.yaml

rm -f "$TEMP_CONFIG"

# --- Start VM ---
echo "Starting VM $HA_VMID..."
qm start "$HA_VMID"

echo ""
echo "Done! HA OS VM $HA_VMID configured to trust Caddy ($CADDY_IP)"
