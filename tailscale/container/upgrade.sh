#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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

log "Upgrade complete. Login state and routes are preserved (no re-registration needed)."
