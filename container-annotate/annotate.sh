#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

DOMAIN="marx.home"
CADDYFILE="${CADDYFILE:-$SCRIPT_DIR/../caddy/Caddyfile.local}"
PVE_BASE="${PVE_BASE:-/etc/pve}"
CHECK=$'\u2713'
ARROW=$'\u2192'
UPDATED=0
SKIPPED=0

get_vm_ip() {
    local vmid="$1"
    local ip

    json=$(qm guest exec "$vmid" -- hostname -I 2>/dev/null)
    ip=$(echo "$json" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        json=$(qm guest exec "$vmid" -- ip -4 addr show 2>/dev/null)
        ip=$(echo "$json" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -1)
    fi
    if [ -z "$ip" ]; then
        ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ipconfig\d:\s*ip=\K[^/]+' | head -1)
    fi

    echo "$ip"
}

annotate_guest() {
    local config_file="$1"
    local name="$2"
    local ip="$3"

    # Check if already annotated
    if grep -q "proxmox-annotate" "$config_file"; then
        echo "  $ARROW $name — already annotated"
        ((SKIPPED++))
        return
    fi

    if [ -f "${config_file}.bak" ]; then
        if [ "$OVERWRITE" != "yes" ]; then
            read -p "  Backup already exists for $name. Overwrite? (y/N) " confirm < /dev/tty
            if [[ "$confirm" =~ ^[yY] ]]; then
                cp "$config_file" "${config_file}.bak"
            fi
        else
            cp "$config_file" "${config_file}.bak"
        fi
    else
        cp "$config_file" "${config_file}.bak"
    fi

    # Read all lines, filter out description: field
    lines=()
    in_desc=false
    while IFS= read -r line; do
        if [[ $line =~ ^description: ]]; then
            in_desc=true
            continue
        elif $in_desc && [[ $line =~ ^[[:space:]] ]]; then
            continue
        else
            in_desc=false
        fi
        lines+=("$line")
    done < "$config_file"

    # Find where # comments end (first non-comment, non-empty line)
    insert_idx=0
    for i in "${!lines[@]}"; do
        line="${lines[$i]}"
        if [[ $line =~ ^# ]] || [ -z "$line" ]; then
            insert_idx=$((i + 1))
        else
            break
        fi
    done

    # Build HTML with clickable links (one pair per matching Caddy block)
    html_lines=("# <!-- proxmox-annotate -->")
    html_lines+=("# <div align='center' style='margin-top: 10px;'>")
    matches=()
    for idx in "${!CADDY_NAMES[@]}"; do
        if [ "${CADDY_NAMES[$idx]}" = "$name" ] || [ "${CADDY_IPS[$idx]}" = "$ip" ]; then
            matches+=("$idx")
        fi
    done

    if [ ${#matches[@]} -gt 0 ]; then
        for idx in "${matches[@]}"; do
            svc="${CADDY_NAMES[$idx]}"
            svc_port="${CADDY_PORTS[$idx]}"
            proto="http"
            [ "${CADDY_TLS[$idx]}" = "1" ] && proto="https"
            url="$proto://$svc.$DOMAIN"
            html_lines+=("#   <p style='margin: 8px 0;'>")
            html_lines+=("#     <a href='$url' target='_blank' rel='noopener noreferrer' style='font-size: 14px; color: #00617f; text-decoration: none;'>$url</a>")
            html_lines+=("#   </p>")
            html_lines+=("#   <p style='margin: 4px 0;'>")
            html_lines+=("#     <a href='http://$ip:$svc_port' target='_blank' rel='noopener noreferrer' style='font-size: 14px; color: #777; text-decoration: none;'>http://$ip:$svc_port</a>")
            html_lines+=("#   </p>")
        done
    else
        html_lines+=("#   <p style='margin: 8px 0;'>")
        html_lines+=("#     <a href='http://$ip' target='_blank' rel='noopener noreferrer' style='font-size: 14px; color: #00617f; text-decoration: none;'>http://$ip</a>")
        html_lines+=("#   </p>")
    fi

    html_lines+=("# </div>")
    html_lines+=("#")

    result=("${lines[@]:0:insert_idx}" "${html_lines[@]}" "${lines[@]:insert_idx}")
    printf '%s\n' "${result[@]}" > "$config_file"

    if [ ${#matches[@]} -gt 0 ]; then
        descs=()
        for idx in "${matches[@]}"; do
            descs+=("${CADDY_NAMES[$idx]}")
        done
        echo "  $CHECK $name (${#matches[@]} link(s): $(IFS=,; echo "${descs[*]}"))"
    else
        echo "  $CHECK $name (http://$ip)"
    fi
    ((UPDATED++))
}

log_step "Annotating guest descriptions"
echo ""

# Build subdomain -> endpoint map from Caddyfile (order-preserving:
# multi-service guests own several blocks pointing at the same IP)
CADDY_NAMES=()
CADDY_IPS=()
CADDY_PORTS=()
CADDY_TLS=()

if [ -f "$CADDYFILE" ]; then
    while IFS= read -r line; do
        if [[ $line =~ ^(http://)?([^.]+)\.$DOMAIN[[:space:]]*\{ ]]; then
            current_name="${BASH_REMATCH[2]}"
            current_tls=$([ -z "${BASH_REMATCH[1]}" ] && echo 1 || echo 0)
        elif [[ $line =~ reverse_proxy[[:space:]]+(https?://)?([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
            if [ -n "${current_name:-}" ]; then
                CADDY_NAMES+=("$current_name")
                CADDY_TLS+=("$current_tls")
                CADDY_IPS+=("${BASH_REMATCH[2]}")
                CADDY_PORTS+=("${BASH_REMATCH[3]}")
                current_name=""
            fi
        fi
    done < "$CADDYFILE"
fi

# ── LXC containers ──
while IFS= read -r cid; do
    cid="${cid// /}"
    [ -z "$cid" ] && continue

    config_file="$PVE_BASE/lxc/${cid}.conf"
    [ -f "$config_file" ] || continue

    name=$(pct config "$cid" 2>/dev/null | grep -oP 'hostname:\s*\K\S+')
    [ -z "$name" ] && continue

    [ "$name" = "caddy" ] && continue

    ip=$(get_container_ip "$cid")
    [ -z "$ip" ] && continue

    annotate_guest "$config_file" "$name" "$ip"

done < <(pct list | tail -n +2 | awk '{print $1}' | sort -n)

# ── QEMU VMs ──
while IFS= read -r vmid; do
    vmid="${vmid// /}"
    [ -z "$vmid" ] && continue

    config_file="$PVE_BASE/qemu-server/${vmid}.conf"
    [ -f "$config_file" ] || continue

    name=$(qm config "$vmid" 2>/dev/null | grep -oP '(?:hostname|name):\s*\K\S+')
    [ -z "$name" ] && continue

    ip=$(get_vm_ip "$vmid")
    [ -z "$ip" ] && continue

    annotate_guest "$config_file" "$name" "$ip"

done < <(qm list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n)

echo ""
log_success "Done! $UPDATED annotated, $SKIPPED already up-to-date."
