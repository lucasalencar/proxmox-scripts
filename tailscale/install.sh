#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"
source "$SCRIPT_DIR/config.sh"

require_root

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

# Ensures TUN passthrough lines exist, restarting the container when changed.
# Usage: apply_tun_passthrough <container_id> || exit 1
apply_tun_passthrough() {
    local id="$1"
    local conf="$LXC_CONF_DIR/${id}.conf"
    local live
    live=$(pct config "$id" 2>/dev/null || true)

    local changed="n" entry
    for entry in "$TUN_CGROUP" "$TUN_MOUNT"; do
        if ! tun_entry_present "$entry" "$conf" "$live"; then
            [ "$changed" = "n" ] && log_step "Adding TUN device passthrough to LXC config..."
            echo "$entry" >> "$conf"
            changed="y"
        fi
    done

    if [ "$changed" = "y" ]; then
        log_step "Restarting container $id so /dev/net/tun appears..."
        pct stop "$id" 2>/dev/null || true
        pct start "$id"
    else
        log_info "TUN passthrough already present — skipping restart"
        pct start "$id" 2>/dev/null || true
    fi
    wait_container_ready "$id" || { log_error "Container $id not ready"; return 1; }
}

log_step "Starting Tailscale subnet router installation (dedicated LXC)..."

# --- 1. Create / find container (exact name match, never a similar guest) ---
container_id=$(get_container_id_by_exact_name "$CONTAINER_NAME")
if [ -n "$container_id" ] && ! is_valid_guest_id "$container_id"; then
    log_error "Refusing to operate on unexpected container ID '$container_id'"
    exit 1
fi

if [ -z "$container_id" ]; then
    log_step "Container '$CONTAINER_NAME' not found — creating new Debian $DEBIAN_VERSION LXC (${CT_CORES} core / ${CT_MEMORY} MB / ${CT_DISK}GB)..."

    CTID=$(get_pve_next_id) || exit 1
    if ! is_valid_guest_id "$CTID"; then
        log_error "Refusing to operate on unexpected CTID '$CTID'"
        exit 1
    fi
    log_info "Using CTID: $CTID"

    TEMPLATE_STORAGE=$(get_pve_template_storage)
    ROOTFS_STORAGE=$(get_pve_rootfs_storage)
    log_info "Template storage: $TEMPLATE_STORAGE | RootFS storage: $ROOTFS_STORAGE"

    BRIDGE=$(detect_pve_bridge)
    log_info "Network bridge: $BRIDGE"

    TEMPLATE=$(ensure_debian_template "$DEBIAN_VERSION" "$TEMPLATE_STORAGE") || exit 1
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

# --- 2. Ensure running before any guest operation ---
pct start "$container_id" 2>/dev/null || true
wait_container_ready "$container_id" || { log_error "Container $container_id not ready"; exit 1; }

# --- 3. Refuse non-Debian guests (provision.sh only supports apt) ---
if ! pct exec "$container_id" -- test -f /etc/debian_version 2>/dev/null; then
    log_error "Container $container_id is not Debian-based — refusing to provision"
    exit 1
fi

# --- 4. TUN passthrough for /dev/net/tun (required, LXC lacks it by default) ---
apply_tun_passthrough "$container_id" || exit 1

# --- 5. Tags (reconcile each required tag; abort when protection is missing) ---
if ! ensure_guest_tags "ct" "$container_id" "$REQUIRED_TAGS"; then
    log_error "Failed to apply required tags ($REQUIRED_TAGS) on $container_id — refusing to continue without no-auto-proxy protection"
    exit 1
fi

# --- 6. Install Tailscale inside container ---
log_step "Installing Tailscale inside container $container_id..."

if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/provision.sh"; then
    log_error "Failed to provision Tailscale inside container $container_id"
    exit 1
fi

log_success "Tailscale installed inside container $container_id"

# --- 7. Manual next steps (login is never automated) ---
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
