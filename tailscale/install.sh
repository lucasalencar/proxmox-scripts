#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

CONTAINER_NAME="tailscale-router"
REQUIRED_TAGS="tailscale,router,no-auto-proxy"
CT_CORES=1
CT_MEMORY=512
CT_DISK=8
CT_SWAP=256

# Test hook: LXC config dir (production: /etc/pve/lxc)
LXC_CONF_DIR="${PVE_LXC_CONF_DIR:-/etc/pve/lxc}"

# TUN device passthrough, same entries as community-scripts add-tailscale-lxc.sh
TUN_CGROUP="lxc.cgroup2.devices.allow: c 10:200 rwm"
TUN_MOUNT="lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"

# Reports whether an LXC config line is already present (live config or conf file).
# Usage: tun_entry_present <line> <conf_file> <live_config>
tun_entry_present() {
    local line="$1"
    local conf="$2"
    local live="$3"

    echo "$live" | grep -qF "$line" && return 0
    [ -f "$conf" ] && grep -qF "$line" "$conf"
}

log_step "Starting Tailscale subnet router installation (dedicated LXC)..."

# --- 1. Create / find container (exact name match, never a similar guest) ---
container_id=$(get_container_id_by_exact_name "$CONTAINER_NAME")

if [ -z "$container_id" ]; then
    log_step "Container '$CONTAINER_NAME' not found — creating new Debian 13 LXC (${CT_CORES} core / ${CT_MEMORY} MB / ${CT_DISK}GB)..."

    CTID=$(get_pve_next_id) || exit 1
    log_info "Using CTID: $CTID"

    TEMPLATE_STORAGE=$(get_pve_template_storage)
    ROOTFS_STORAGE=$(get_pve_rootfs_storage)
    log_info "Template storage: $TEMPLATE_STORAGE | RootFS storage: $ROOTFS_STORAGE"

    BRIDGE=$(detect_pve_bridge)
    log_info "Network bridge: $BRIDGE"

    TEMPLATE=$(ensure_debian_template "13" "$TEMPLATE_STORAGE") || exit 1
    TEMPLATE_FILE=$(basename "$TEMPLATE")

    if ! create_lxc_container "$CTID" "$CONTAINER_NAME" "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" "$ROOTFS_STORAGE" "$BRIDGE" "$CT_CORES" "$CT_MEMORY" "$CT_DISK" "$CT_SWAP" "$REQUIRED_TAGS" "Tailscale subnet router. Managed by proxmox-scripts/tailscale."; then
        log_error "Failed to create $CONTAINER_NAME LXC"
        exit 1
    fi

    container_id="$CTID"
    log_success "Created container $CONTAINER_NAME (ID: $container_id)"
else
    log_info "Found existing $CONTAINER_NAME container (ID: $container_id) — reusing"
fi

# --- 2. Refuse non-Debian guests (provision.sh only supports apt) ---
if ! pct exec "$container_id" -- test -f /etc/debian_version 2>/dev/null; then
    log_error "Container $container_id is not Debian-based — refusing to provision"
    exit 1
fi

# --- 3. TUN passthrough for /dev/net/tun (required, LXC lacks it by default) ---
conf_file="$LXC_CONF_DIR/${container_id}.conf"
tun_changed="n"
current_config=$(pct config "$container_id" 2>/dev/null || true)

for tun_entry in "$TUN_CGROUP" "$TUN_MOUNT"; do
    if ! tun_entry_present "$tun_entry" "$conf_file" "$current_config"; then
        [ "$tun_changed" = "n" ] && log_step "Adding TUN device passthrough to LXC config..."
        echo "$tun_entry" >> "$conf_file"
        tun_changed="y"
    fi
done

if [ "$tun_changed" = "y" ]; then
    log_step "Restarting container $container_id so /dev/net/tun appears..."
    pct stop "$container_id" 2>/dev/null || true
    pct start "$container_id"
    wait_container_ready "$container_id" || { log_error "Container $container_id not ready after TUN restart"; exit 1; }
else
    log_info "TUN passthrough already present — skipping restart"
    pct start "$container_id" 2>/dev/null || true
    wait_container_ready "$container_id" || { log_error "Container $container_id not ready"; exit 1; }
fi

# --- 4. Tags (reconcile each required tag, never overwrite existing ones) ---
missing_tags=""
for required_tag in tailscale router no-auto-proxy; do
    if ! guest_has_tag "ct" "$container_id" "$required_tag"; then
        missing_tags="${missing_tags:+$missing_tags,}$required_tag"
    fi
done
if [ -n "$missing_tags" ]; then
    current_tags=$(pct config "$container_id" 2>/dev/null | awk -F': ' '/^[Tt]ags:/ {print $2}')
    normalized=$(echo "$current_tags" | tr ';' ',' | tr -d ' ' | sed 's/,,*/,/g; s/^,//; s/,$//')
    pct set "$container_id" --tags "${normalized:+$normalized,}$missing_tags" 2>/dev/null || log_warning "Could not set tags on $container_id"
fi

# --- 5. Install Tailscale inside container ---
log_step "Installing Tailscale inside container $container_id..."

if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/provision.sh"; then
    log_error "Failed to provision Tailscale inside container $container_id"
    exit 1
fi

log_success "Tailscale installed inside container $container_id"

# --- 6. Manual next steps (login is never automated) ---
container_ip=$(get_container_ip "$container_id")
if [ -n "$container_ip" ]; then
    log_success "Tailscale router ready! Container IP: $container_ip"
else
    log_success "Tailscale router installed (container $container_id)"
fi

echo ""
log_info "Next steps (see docs/tailscale-plan.md):"
log_info "  1. Log in: pct exec $container_id -- tailscale up"
log_info "  2. Advertise LAN: pct exec $container_id -- tailscale set --advertise-routes=<LAN-CIDR>"
log_info "  3. Approve the route in the Tailscale admin console"
echo ""
log_info "Update later with: bash tailscale/update.sh"
