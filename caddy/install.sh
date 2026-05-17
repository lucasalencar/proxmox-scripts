#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

echo "Starting Caddy installation/configuration via LXC container..."

CADDY_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/caddy.sh)"'
container_id=$(ensure_container_installed "caddy" "$CADDY_INSTALL_CMD") || exit 1

echo "Identified Container ID: $container_id"

pct start "$container_id"

echo "Waiting for container IP..."
for i in $(seq 1 15); do
  CADDY_IP=$(get_container_ip "$container_id")
  [ -n "$CADDY_IP" ] && break
  sleep 2
done

if [ -z "$CADDY_IP" ]; then
  echo "Error: Could not get Caddy container IP after 30 seconds."
  exit 1
fi
echo "Caddy container IP: $CADDY_IP"

echo "Waiting for Caddy service..."
for i in $(seq 1 15); do
  if pct exec "$container_id" -- systemctl is-active caddy >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

pct push "$container_id" "$SCRIPT_DIR/Caddyfile" /etc/caddy/Caddyfile
pct exec "$container_id" -- systemctl reload caddy

echo "Installation completed for Caddy (ID: $container_id, IP: $CADDY_IP)."
echo "Update AdGuard DNS wildcard *.marx.home to point to $CADDY_IP"
