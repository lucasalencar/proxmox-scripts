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
        *) log_error "Usage: $0 [--vmid VMID] [--caddy-ip IP]"; exit 1 ;;
    esac
done

# --- Discover HA VM ---
if [ -z "$HA_VMID" ]; then
    HA_VMID=$(get_vm_id_by_name "haos")
fi
if [ -z "$HA_VMID" ] || ! qm status "$HA_VMID" &>/dev/null; then
    log_error "HA OS VM not found. Use --vmid or create the VM first."
    exit 1
fi
log_info "HA OS VM: $HA_VMID"

# --- Discover Caddy IP ---
if [ -z "$CADDY_IP" ]; then
    CADDY_ID=$(get_container_id_by_name "caddy")
    if [ -n "$CADDY_ID" ]; then
        CADDY_IP=$(get_container_ip "$CADDY_ID")
    fi
fi
if [ -z "$CADDY_IP" ]; then
    log_error "Could not determine Caddy IP. Use --caddy-ip or ensure Caddy container exists."
    exit 1
fi
log_info "Caddy IP: $CADDY_IP"

# --- Dependencies ---
if ! command -v guestfish &>/dev/null; then
    log_step "Installing libguestfs-tools..."
    apt-get install -y -qq libguestfs-tools 2>/dev/null || {
        apt-get update -qq && apt-get install -y -qq libguestfs-tools
    }
fi

if ! python3 -c "import yaml" &>/dev/null; then
    log_step "Installing python3-yaml..."
    apt-get install -y -qq python3-yaml
fi

# --- Stop VM gracefully ---
log_step "Shutting down VM $HA_VMID..."
if qm shutdown "$HA_VMID" --timeout 60 2>/dev/null; then
    for i in $(seq 1 30); do
        qm status "$HA_VMID" 2>/dev/null | grep -q "stopped" && break
        sleep 2
    done
fi
if qm status "$HA_VMID" 2>/dev/null | grep -q "running"; then
    log_step "Force stopping VM $HA_VMID..."
    qm stop "$HA_VMID"
fi
sleep 3

# --- Inject config via guestfish ---
TEMP_CONFIG="/tmp/ha-config-${HA_VMID}.yaml"
DISK_DEVICE="/dev/pve/vm-${HA_VMID}-disk-0"

log_step "Locating hassos-data partition..."
DATA_DEVICE=$(guestfish --ro -a "$DISK_DEVICE" run : findfs-label hassos-data 2>/dev/null)
if [ -z "$DATA_DEVICE" ]; then
    log_error "Could not find hassos-data partition on disk."
    exit 1
fi
log_info "Data partition: $DATA_DEVICE"

log_step "Reading current configuration..."
guestfish --rw -a "$DISK_DEVICE" <<GUESTFISH 2>/dev/null
run
mount $DATA_DEVICE /
download /supervisor/homeassistant/configuration.yaml $TEMP_CONFIG
GUESTFISH
READ_OK=$?
if [ $READ_OK -ne 0 ] || [ ! -s "$TEMP_CONFIG" ]; then
    log_info "No existing configuration.yaml found, starting fresh."
    echo "{}" > "$TEMP_CONFIG"
else
    BACKUP_DIR="/var/backups/haos-config"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/configuration.yaml.$(date +%Y%m%d-%H%M%S)"
    cp "$TEMP_CONFIG" "$BACKUP_FILE"
    log_info "Backup saved: $BACKUP_FILE"
fi

log_step "Merging proxy configuration..."
python3 -c "
import yaml

class PreservedTag:
    def __init__(self, tag, value):
        self.tag = tag
        self.value = value

def preserve_tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return PreservedTag('!' + suffix, value)

def tag_representer(dumper, data):
    v = data.value
    if isinstance(v, dict):
        return dumper.represent_mapping(data.tag, v)
    if isinstance(v, (list, tuple)):
        return dumper.represent_sequence(data.tag, v)
    return dumper.represent_scalar(data.tag, v, style='')

yaml.add_multi_constructor('!', preserve_tag, Loader=yaml.SafeLoader)
yaml.add_multi_representer(PreservedTag, tag_representer)

with open('$TEMP_CONFIG') as f:
    config = yaml.load(f, Loader=yaml.SafeLoader) or {}
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

log_step "Writing configuration back..."
guestfish --rw -a "$DISK_DEVICE" <<GUESTFISH
run
mount $DATA_DEVICE /
upload $TEMP_CONFIG /supervisor/homeassistant/configuration.yaml
GUESTFISH

rm -f "$TEMP_CONFIG"

# --- Start VM ---
log_step "Starting VM $HA_VMID..."
qm start "$HA_VMID"

echo ""
log_success "HA OS VM $HA_VMID configured to trust Caddy ($CADDY_IP)"
