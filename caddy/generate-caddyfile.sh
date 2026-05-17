#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

CHECK=$'\u2713'
ARROW=$'\u2192'

LOCAL_CADDYFILE="$SCRIPT_DIR/Caddyfile.local"
CADDY_CONTAINER_NAME="caddy"
DOMAIN="marx.home"

echo "=== Caddyfile Generator for *.$DOMAIN ==="
echo ""

# --- Verify Caddy container exists ---
CADDY_ID=$(get_container_id_by_name "$CADDY_CONTAINER_NAME")
if [ -z "$CADDY_ID" ]; then
    echo "Error: Caddy container not found. Run install.sh first."
    exit 1
fi

pct start "$CADDY_ID" 2>/dev/null || true

CADDY_IP=$(get_container_ip "$CADDY_ID")
echo "Caddy container: $CADDY_ID (IP: ${CADDY_IP:-unknown})"
echo ""

# --- Load existing port mappings from Caddyfile.local ---
declare -A PORT_MAP

if [ -f "$LOCAL_CADDYFILE" ]; then
    echo "Loading existing configuration from $LOCAL_CADDYFILE..."
    while IFS= read -r line; do
        if [[ $line =~ http://([^.]+)\.$DOMAIN[[:space:]]*\{ ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ $line =~ reverse_proxy[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
            if [ -n "${current_name:-}" ]; then
                PORT_MAP["$current_name"]="${BASH_REMATCH[2]}"
                current_name=""
            fi
        fi
    done < "$LOCAL_CADDYFILE"

    if [ ${#PORT_MAP[@]} -gt 0 ]; then
        echo "  Found ${#PORT_MAP[@]} saved mapping(s)"
    fi
    echo ""
fi

# --- Collect all guests (containers + VMs, excluding caddy itself) ---
GUEST_IDS=()
GUEST_NAMES=()
GUEST_TYPES=()
declare -A GUEST_IPS

# --- Collect containers (LXC) ---
while IFS= read -r cid; do
    cid="${cid// /}"
    [ -z "$cid" ] && continue

    name=$(pct config "$cid" 2>/dev/null | grep -oP 'hostname:\s*\K\S+')
    [ -z "$name" ] && continue
    [ "$name" = "$CADDY_CONTAINER_NAME" ] && continue

    ip=$(get_container_ip "$cid")
    [ -z "$ip" ] && continue

    GUEST_IDS+=("$cid")
    GUEST_NAMES+=("$name")
    GUEST_TYPES+=("ct")
    GUEST_IPS["$name"]="$ip"
done < <(pct list | tail -n +2 | awk '{print $1}' | sort -n)

# --- Collect VMs (QEMU) ---
while IFS= read -r vmid; do
    vmid="${vmid// /}"
    [ -z "$vmid" ] && continue

    name=$(qm config "$vmid" 2>/dev/null | grep -oP 'hostname:\s*\K\S+')
    [ -z "$name" ] && continue
    [ "$name" = "$CADDY_CONTAINER_NAME" ] && continue

    if [ -n "${GUEST_IPS[$name]:-}" ]; then
        echo "  Skipping VM $vmid ($name) — name already used by another guest"
        continue
    fi

    ip=$(qm guest exec "$vmid" -- hostname -I 2>/dev/null | grep -oP '"out":"\K[^"\\]+' | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ipconfig\d:\s*ip=\K[^/]+' | head -1)
    fi
    [ -z "$ip" ] && continue

    GUEST_IDS+=("$vmid")
    GUEST_NAMES+=("$name")
    GUEST_TYPES+=("vm")
    GUEST_IPS["$name"]="$ip"
done < <(qm list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n)

TOTAL=${#GUEST_NAMES[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "No guests found to configure."
    exit 0
fi

echo "Found $TOTAL guest(s) to configure:"
for i in $(seq 0 $((TOTAL - 1))); do
    type_label="[${GUEST_TYPES[$i]}]"
    echo "  $type_label ${GUEST_IDS[$i]}: ${GUEST_NAMES[$i]} (${GUEST_IPS[${GUEST_NAMES[$i]}]})"
done
echo ""

# --- Determine port for each guest ---
for i in $(seq 0 $((TOTAL - 1))); do
    name="${GUEST_NAMES[$i]}"
    gid="${GUEST_IDS[$i]}"
    type="${GUEST_TYPES[$i]}"
    ip="${GUEST_IPS[$name]}"

    if [ -n "${PORT_MAP[$name]:-}" ]; then
        port="${PORT_MAP[$name]}"
        echo "  $CHECK $name $ARROW saved port $port"
    else
        listening_ports=""
        if [ "$type" = "ct" ]; then
            if pct status "$gid" 2>/dev/null | grep -q "running"; then
                listening_ports=$(pct exec "$gid" -- ss -tlnp 2>/dev/null | tail -n +2 | awk '{n=split($4, a, ":"); print a[n]}' | sort -n | uniq)
            fi
        else
            if qm status "$gid" 2>/dev/null | grep -q "running"; then
                output=$(qm guest exec "$gid" -- ss -tlnp 2>/dev/null)
                listening_ports=$(echo "$output" | grep -oP '"out":"\K[^"\\]+' | tail -n +2 | awk '{n=split($4, a, ":"); print a[n]}' | sort -n | uniq)
            fi
        fi

        suggested="80"
        if [ -n "$listening_ports" ]; then
            for p in 80 443; do
                if echo "$listening_ports" | grep -qx "$p" 2>/dev/null; then
                    suggested="$p"
                    break
                fi
            done
            if [ "$suggested" = "80" ] && ! echo "$listening_ports" | grep -qx "80" 2>/dev/null; then
                suggested=$(echo "$listening_ports" | head -1)
            fi
        fi

        if [ -n "$listening_ports" ]; then
            echo "  Detected ports for $name: $(echo "$listening_ports" | tr '\n' ' ')"
        fi

        read -p "  Port for $name.$DOMAIN ($ip) [default: $suggested]: " user_port
        port="${user_port:-$suggested}"
    fi

    PORT_MAP["$name"]="$port"
done

echo ""
echo "--- Writing $LOCAL_CADDYFILE ---"
echo ""

# --- Generate Caddyfile ---
{
    for i in $(seq 0 $((TOTAL - 1))); do
        name="${GUEST_NAMES[$i]}"
        ip="${GUEST_IPS[$name]}"
        port="${PORT_MAP[$name]}"
        echo "http://$name.$DOMAIN {"
        echo "    reverse_proxy $ip:$port"
        echo "}"
        echo ""
    done
} > "$LOCAL_CADDYFILE"

cat "$LOCAL_CADDYFILE"

# --- Push to Caddy container and reload ---
echo "Pushing to Caddy container ($CADDY_ID)..."
pct push "$CADDY_ID" "$LOCAL_CADDYFILE" /etc/caddy/Caddyfile

echo "Reloading Caddy..."
pct exec "$CADDY_ID" -- systemctl reload caddy

echo ""
echo "Done! Caddy reloaded with latest configuration."
if [ -n "$CADDY_IP" ]; then
    echo "If not already set, add a wildcard DNS record: *.$DOMAIN $ARROW $CADDY_IP"
fi
