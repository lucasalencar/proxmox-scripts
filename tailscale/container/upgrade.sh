#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Test hook: TUN device to verify (production: /dev/net/tun).
TUN_DEV="${TAILSCALE_TUN_DEV:-/dev/net/tun}"

log() { echo "[tailscale-upgrade] $*"; }

log "Refreshing Tailscale package..."
apt-get update
apt-get install --only-upgrade -y tailscale

if systemctl is-active --quiet tailscaled; then
    log "Restarting tailscaled..."
    systemctl restart tailscaled
else
    log "tailscaled inactive — starting..."
    systemctl start tailscaled
fi

if ! systemctl is-active --quiet tailscaled; then
    log "tailscaled: not active after upgrade"
    exit 1
fi
log "tailscaled: active"

if [ ! -c "$TUN_DEV" ]; then
    log "ERROR: $TUN_DEV is missing — TUN passthrough was lost (backup restore or manual edit)."
    log "Fix the LXC config and restart the container, then re-run this script."
    exit 1
fi
log "TUN device: present"

if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ] \
    || [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" != "1" ]; then
    log "ERROR: IP forwarding is disabled — subnet routing is broken."
    log "Re-run tailscale/container/provision.sh inside this container to restore it."
    exit 1
fi
log "IP forwarding: enabled (IPv4 + IPv6)"

log "Upgrade complete. Login state and routes are preserved (no re-registration needed)."
