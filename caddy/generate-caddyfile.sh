#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

CHECK=$'\u2713'
ARROW=$'\u2192'

LOCAL_CADDYFILE="$SCRIPT_DIR/Caddyfile.local"
CADDY_CONTAINER_NAME="caddy"
DOMAIN="marx.home"

log_step "Caddyfile Generator for *.$DOMAIN"
echo ""

# --- Verify Caddy container exists ---
CADDY_ID=$(get_container_id_by_name "$CADDY_CONTAINER_NAME")
if [ -z "$CADDY_ID" ]; then
    log_error "Caddy container not found. Run install.sh first."
    exit 1
fi

pct start "$CADDY_ID" 2>/dev/null || true

CADDY_IP=$(get_container_ip "$CADDY_ID")
log_info "Caddy container: $CADDY_ID (IP: ${CADDY_IP:-unknown})"
echo ""

# --- Load existing port mappings from Caddyfile.local ---
declare -A PORT_MAP
declare -A TLS_MAP
declare -A IP_MAP

if [ -f "$LOCAL_CADDYFILE" ]; then
    log_info "Loading existing configuration from $LOCAL_CADDYFILE..."
    while IFS= read -r line; do
        if [[ $line =~ http://([^.]+)\.$DOMAIN[[:space:]]*\{ ]]; then
            current_name="${BASH_REMATCH[1]}"
            TLS_MAP["$current_name"]="http"
        elif [[ $line =~ ([^.]+)\.$DOMAIN[[:space:]]*\{ ]]; then
            current_name="${BASH_REMATCH[1]}"
            TLS_MAP["$current_name"]="https"
        elif [[ $line =~ reverse_proxy[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
            if [ -n "${current_name:-}" ]; then
                IP_MAP["$current_name"]="${BASH_REMATCH[1]}"
                PORT_MAP["$current_name"]="${BASH_REMATCH[2]}"
                current_name=""
            fi
        fi
    done < "$LOCAL_CADDYFILE"

    if [ ${#PORT_MAP[@]} -gt 0 ] || [ ${#TLS_MAP[@]} -gt 0 ]; then
        log_info "  Found ${#PORT_MAP[@]} saved port mapping(s) and ${#TLS_MAP[@]} TLS setting(s)"
    fi
    echo ""
fi

# Subdomains present before this run (used to detect unmanaged/orphan blocks)
SAVED_NAMES=("${!PORT_MAP[@]}")

# Final entries to write: parallel indexed arrays (order = generation order)
FINAL_NAMES=()
FINAL_IPS=()

# Records one output entry (creates or updates the subdomain mapping)
add_entry() {
    local entry_name="$1"
    local entry_ip="$2"
    local entry_port="$3"
    PORT_MAP["$entry_name"]="$entry_port"
    IP_MAP["$entry_name"]="$entry_ip"
    local existing
    for existing in "${FINAL_NAMES[@]:-}"; do
        [ "$existing" = "$entry_name" ] && return 0
    done
    FINAL_NAMES+=("$entry_name")
    FINAL_IPS+=("$entry_ip")
}

# Prints saved subdomains (one per line) whose saved IP matches <ip>,
# excluding <exclude>. Used to re-attach multi-service blocks to their guest.
saved_services_for_ip() {
    local wanted_ip="$1"
    local exclude="$2"
    local s
    for s in "${SAVED_NAMES[@]:-}"; do
        [ -z "$s" ] && continue
        [ "$s" = "$exclude" ] && continue
        if [ "${IP_MAP[$s]:-}" = "$wanted_ip" ]; then
            echo "$s"
        fi
    done
}

# Suggests an unmanaged subdomain for <port> when exactly one saved block
# uses that port (helps re-attach blocks after a guest IP change)
suggest_subdomain_for_port() {
    local wanted_port="$1"
    local match=""
    local count=0
    local s
    for s in "${SAVED_NAMES[@]:-}"; do
        [ -z "$s" ] && continue
        if [ "${PORT_MAP[$s]:-}" = "$wanted_port" ]; then
            match="$s"
            count=$((count + 1))
        fi
    done
    if [ "$count" -eq 1 ]; then
        echo "$match"
    fi
}

# Prompts for the TLS mode of <subdomain> (default from saved or https for
# nextcloud*, http otherwise) and stores it in TLS_MAP
prompt_tls() {
    local tls_name="$1"
    if [ -n "${TLS_MAP[$tls_name]:-}" ]; then
        log_info "  $CHECK $tls_name $ARROW saved TLS: $([ "${TLS_MAP[$tls_name]}" = "https" ] && echo "HTTPS (tls internal)" || echo "HTTP")"
        return 0
    fi
    local default_tls="http"
    [[ "$tls_name" == nextcloud* ]] && default_tls="https"
    local tls_choice=""
    read -p "  HTTPS (tls internal) for $tls_name.$DOMAIN? [Y/n] (default: $([ "$default_tls" = "https" ] && echo "Y" || echo "n")): " tls_choice
    case "${tls_choice,,}" in
        y|yes) TLS_MAP["$tls_name"]="https" ;;
        n|no)  TLS_MAP["$tls_name"]="http" ;;
        "")    TLS_MAP["$tls_name"]="$default_tls" ;;
        *)     TLS_MAP["$tls_name"]="$default_tls" ;;
    esac
}

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

    name=$(qm config "$vmid" 2>/dev/null | grep -oP '(?:hostname|name):\s*\K\S+')
    [ -z "$name" ] && continue
    [ "$name" = "$CADDY_CONTAINER_NAME" ] && continue

    if [ -n "${GUEST_IPS[$name]:-}" ]; then
        log_warning "  Skipping VM $vmid ($name) — name already used by another guest"
        continue
    fi

    json=$(qm guest exec "$vmid" -- hostname -I 2>/dev/null)
    ip=$(echo "$json" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        json=$(qm guest exec "$vmid" -- ip -4 addr show 2>/dev/null)
        ip=$(echo "$json" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -1)
    fi
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
    log_warning "No guests found to configure."
    exit 0
fi

log_info "Found $TOTAL guest(s) to configure:"
for i in $(seq 0 $((TOTAL - 1))); do
    type_label="[${GUEST_TYPES[$i]}]"
    log_info "  $type_label ${GUEST_IDS[$i]}: ${GUEST_NAMES[$i]} (${GUEST_IPS[${GUEST_NAMES[$i]}]})"
done
echo ""

# --- Determine entries for each guest (single- or multi-service) ---
for i in $(seq 0 $((TOTAL - 1))); do
    name="${GUEST_NAMES[$i]}"
    gid="${GUEST_IDS[$i]}"
    type="${GUEST_TYPES[$i]}"
    ip="${GUEST_IPS[$name]}"

    # Previously saved blocks owned by this guest (matched by saved IP)
    saved_services=$(saved_services_for_ip "$ip" "$name")

    if [ -n "$saved_services" ]; then
        log_info "  $CHECK $name $ARROW saved multi-service:"
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            log_info "    $CHECK $svc.$DOMAIN $ARROW $ip:${PORT_MAP[$svc]}"
            add_entry "$svc" "$ip" "${PORT_MAP[$svc]}"
        done <<< "$saved_services"
        if [ -n "${PORT_MAP[$name]:-}" ]; then
            log_info "  $CHECK $name $ARROW saved port ${PORT_MAP[$name]}"
            add_entry "$name" "$ip" "${PORT_MAP[$name]}"
            prompt_tls "$name"
        fi
        continue
    fi

    if [ -n "${PORT_MAP[$name]:-}" ]; then
        log_info "  $CHECK $name $ARROW saved port ${PORT_MAP[$name]}"
        add_entry "$name" "$ip" "${PORT_MAP[$name]}"
        prompt_tls "$name"
        continue
    fi

    listening_ports=""
    if [ "$type" = "ct" ]; then
        if pct status "$gid" 2>/dev/null | grep -q "running"; then
            listening_ports=$(pct exec "$gid" -- ss -tlnp 2>/dev/null | tail -n +2 | awk '{n=split($4, a, ":"); print a[n]}' | sort -n | uniq)
        fi
    else
        if qm status "$gid" 2>/dev/null | grep -q "running"; then
            output=$(qm guest exec "$gid" -- ss -tlnp 2>/dev/null)
            listening_ports=$(echo "$output" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | tail -n +2 | awk '{n=split($4, a, ":"); print a[n]}' | sort -n | uniq)
        fi
    fi

    port_count=0
    if [ -n "$listening_ports" ]; then
        port_count=$(echo "$listening_ports" | wc -l | tr -d ' ')
        log_info "  Detected ports for $name: $(echo "$listening_ports" | tr '\n' ' ')"
    fi

    # Guests listening on several ports can expose one subdomain per service
    multi="n"
    if [ "$port_count" -gt 1 ]; then
        read -p "  Does $name host multiple services (one subdomain per port)? [y/N]: " multi_choice
        case "${multi_choice,,}" in
            y|yes) multi="y" ;;
        esac
    fi

    if [ "$multi" = "y" ]; then
        # NOTE: for-loop (not while+herestring) so inner reads use the user's stdin
        # shellcheck disable=SC2086
        for svc_port in $listening_ports; do
            [ -z "$svc_port" ] && continue
            suggestion=$(suggest_subdomain_for_port "$svc_port")
            if [ -n "$suggestion" ]; then
                read -p "  Subdomain for $name port $svc_port ($ip) [default: $suggestion]: " svc_name
                svc_name="${svc_name:-$suggestion}"
            else
                read -p "  Subdomain for $name port $svc_port ($ip) [empty to skip]: " svc_name
            fi
            svc_name=$(echo "$svc_name" | tr -d '[:space:]' | cut -d. -f1)
            [ -z "$svc_name" ] && continue
            prompt_tls "$svc_name"
            add_entry "$svc_name" "$ip" "$svc_port"
            log_info "  $CHECK $svc_name.$DOMAIN $ARROW $ip:$svc_port"
        done
        # Fall back to single-service when every port was skipped
        still_empty="y"
        for existing in "${FINAL_NAMES[@]:-}"; do
            [ -z "$existing" ] && continue
            if [ "${IP_MAP[$existing]:-}" = "$ip" ]; then
                still_empty="n"
                break
            fi
        done
        if [ "$still_empty" = "y" ]; then
            log_warning "  No subdomain given for $name — falling back to single-service"
            multi="n"
        else
            continue
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

    read -p "  Port for $name.$DOMAIN ($ip) [default: $suggested]: " user_port
    port="${user_port:-$suggested}"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_warning "  Invalid port '$port' — using $suggested"
        port="$suggested"
    fi

    add_entry "$name" "$ip" "$port"
    prompt_tls "$name"
done

echo ""
log_step "Writing $LOCAL_CADDYFILE"
echo ""

# --- Generate Caddyfile (guest entries first, unmanaged blocks preserved) ---
{
    idx=0
    for entry in "${FINAL_NAMES[@]}"; do
        entry_ip="${FINAL_IPS[$idx]}"
        entry_port="${PORT_MAP[$entry]}"
        if [ "${TLS_MAP[$entry]:-http}" = "https" ]; then
            echo "$entry.$DOMAIN {"
            echo "    tls internal"
        else
            echo "http://$entry.$DOMAIN {"
        fi
        echo "    reverse_proxy $entry_ip:$entry_port"
        echo "}"
        echo ""
        idx=$((idx + 1))
    done
    for saved in "${SAVED_NAMES[@]:-}"; do
        [ -z "$saved" ] && continue
        is_final="n"
        for entry in "${FINAL_NAMES[@]}"; do
            if [ "$entry" = "$saved" ]; then
                is_final="y"
                break
            fi
        done
        if [ "$is_final" = "n" ]; then
            log_warning "  Preserving unmanaged block $saved.$DOMAIN (${IP_MAP[$saved]:-unknown}:${PORT_MAP[$saved]:-unknown})" >&2
            if [ "${TLS_MAP[$saved]:-http}" = "https" ]; then
                echo "$saved.$DOMAIN {"
                echo "    tls internal"
            else
                echo "http://$saved.$DOMAIN {"
            fi
            echo "    reverse_proxy ${IP_MAP[$saved]}:${PORT_MAP[$saved]}"
            echo "}"
            echo ""
        fi
    done
} > "$LOCAL_CADDYFILE"

cat "$LOCAL_CADDYFILE"

# --- Push to Caddy container and reload ---
log_step "Pushing to Caddy container ($CADDY_ID)..."
pct push "$CADDY_ID" "$LOCAL_CADDYFILE" /etc/caddy/Caddyfile

log_step "Reloading Caddy..."
pct exec "$CADDY_ID" -- systemctl reload caddy

# --- If any Nextcloud guest is configured, run trust-nextcloud.sh ---
for i in $(seq 0 $((TOTAL - 1))); do
    name="${GUEST_NAMES[$i]}"
    if [[ "$name" == nextcloud* ]]; then
        echo ""
        log_step "Configuring Nextcloud ($name) to trust Caddy..."
        "$SCRIPT_DIR/trust-nextcloud.sh" --container "${GUEST_IDS[$i]}" --domain "$DOMAIN"
    fi
done

echo ""
log_success "Caddy reloaded with latest configuration."
echo ""
log_info "Next step: run ./container-annotate/annotate.sh to update container/VM descriptions with access links."
if [ -n "$CADDY_IP" ]; then
    log_info "If not already set, add a wildcard DNS record: *.$DOMAIN $ARROW $CADDY_IP"
fi
