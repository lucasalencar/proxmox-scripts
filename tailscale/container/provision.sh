#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Test hooks: SYSROOT prefixes every filesystem path below (production: empty),
# TUN_DEV points at the TUN device to verify (production: /dev/net/tun).
SYSROOT="${TAILSCALE_SYSROOT:-}"
TUN_DEV="${TAILSCALE_TUN_DEV:-/dev/net/tun}"
KEYRING="$SYSROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
SOURCES_LIST="$SYSROOT/etc/apt/sources.list.d/tailscale.list"
SYSCTL_CONF="$SYSROOT/etc/sysctl.d/99-tailscale.conf"

log() { echo "[tailscale-provision] $*"; }

log "Installing base dependencies..."
apt-get update
apt-get install -y ca-certificates curl gnupg

log "Adding the official Tailscale apt repository (signed)..."
. "${SYSROOT}/etc/os-release"
mkdir -p "$(dirname "$KEYRING")" "$(dirname "$SOURCES_LIST")" "$(dirname "$SYSCTL_CONF")"
curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.noarmor.gpg" -o "$KEYRING"
curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.tailscale-keyring.list" -o "$SOURCES_LIST"

log "Installing Tailscale..."
apt-get update
apt-get install -y tailscale

log "Enabling IP forwarding for subnet routing..."
cat >"$SYSCTL_CONF" <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p "$SYSCTL_CONF"

log "Enabling tailscaled..."
systemctl enable --now tailscaled

if ! systemctl is-active --quiet tailscaled; then
    log "ERROR: tailscaled is not active"
    exit 1
fi
log "tailscaled: active"

if [ ! -c "$TUN_DEV" ]; then
    log "ERROR: $TUN_DEV is missing — TUN passthrough was not applied."
    log "Fix the LXC config and restart the container, then re-run this script."
    exit 1
fi
log "TUN device: present"

if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    log "ERROR: IPv4 forwarding is disabled — subnet routing would be broken."
    exit 1
fi
log "IPv4 forwarding: enabled"

log "Provision complete. Next: run 'tailscale up' to log in (manual step, never automated with credentials)."
