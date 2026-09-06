#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[tailscale-provision] $*"; }

log "Installing base dependencies..."
apt-get update
apt-get install -y ca-certificates curl gnupg

log "Installing Tailscale from the official repository..."
curl -fsSL https://tailscale.com/install.sh | sh

log "Enabling IP forwarding for subnet routing..."
cat >/etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf

log "Enabling tailscaled..."
systemctl enable --now tailscaled

if systemctl is-active --quiet tailscaled; then
    log "tailscaled: active"
else
    log "ERROR: tailscaled is not active"
    exit 1
fi

log "Provision complete. Next: run 'tailscale up' to log in (manual step, never automated with credentials)."
