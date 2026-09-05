#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

usage() {
    echo "Usage: bash starr/configure.sh --qbit-pass <password> [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --qbit-pass <pass>   qBittorrent admin password (or QBIT_PASS env, from qbittorrent install log)" >&2
    echo "  --qbit-user <user>   qBittorrent username (default: admin)" >&2
    echo "  --qbit-port <port>   qBittorrent WebUI port (default: 8090)" >&2
    echo "  --qbit-host <ip>     qBittorrent container IP (default: auto-discovered)" >&2
    echo "  --skip-bazarr        Skip Bazarr Sonarr/Radarr linking" >&2
    echo "  --dry-run            Show planned actions without changing anything (services must still be up)" >&2
}

need_value() {
    local opt="$1" val="${2:-}"
    if [ -z "$val" ] || [[ "$val" == -* ]]; then
        log_error "Option $opt requires a value."
        usage
        exit 1
    fi
}

QBIT_USER="admin"
QBIT_PORT="8090"
QBIT_HOST=""
QBIT_PASS="${QBIT_PASS:-}"
SKIP_BAZARR=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --qbit-pass) need_value "$1" "${2:-}"; QBIT_PASS="$2"; shift 2 ;;
        --qbit-user) need_value "$1" "${2:-}"; QBIT_USER="$2"; shift 2 ;;
        --qbit-port) need_value "$1" "${2:-}"; QBIT_PORT="$2"; shift 2 ;;
        --qbit-host) need_value "$1" "${2:-}"; QBIT_HOST="$2"; shift 2 ;;
        --skip-bazarr) SKIP_BAZARR=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [ -z "$QBIT_PASS" ]; then
    log_error "Missing qBittorrent password. Pass --qbit-pass or set QBIT_PASS (see qbittorrent install log)."
    usage
    exit 1
fi

if ! [[ "$QBIT_PORT" =~ ^[0-9]+$ ]] || (( 10#$QBIT_PORT < 1 || 10#$QBIT_PORT > 65535 )); then
    log_error "Invalid qBittorrent port: '$QBIT_PORT' (must be between 1 and 65535)."
    exit 1
fi

find_exact_container_id() {
    local name="$1"
    local ids
    ids=$(pct list | awk -v target="$name" 'NR > 1 && $NF == target { print $1 }')
    if [ -z "$ids" ]; then
        return 1
    fi
    if [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" -ne 1 ]; then
        log_error "Multiple containers have the exact name '$name'; refusing to choose one."
        return 1
    fi
    printf '%s\n' "$ids"
}

starr_id=$(find_exact_container_id "starr")
if [ -z "$starr_id" ]; then
    log_error "Could not find container 'starr'. Run install.sh first."
    exit 1
fi

if [ -z "$QBIT_HOST" ]; then
    qbit_id=$(find_exact_container_id "qbittorrent")
    if [ -z "$qbit_id" ]; then
        log_error "Could not find container 'qbittorrent'. Run qbittorrent/install.sh first, or pass --qbit-host."
        exit 1
    fi
    QBIT_HOST=$(get_container_ip "$qbit_id")
    if [ -z "$QBIT_HOST" ]; then
        log_error "Could not determine qBittorrent container IP. Pass --qbit-host explicitly."
        exit 1
    fi
fi

log_step "Configuring Starr integrations (container $starr_id, qBittorrent at $QBIT_HOST:$QBIT_PORT)..."
wait_container_ready "$starr_id" || exit 1

REMOTE="/root/starr-configure.py"
if ! pct push "$starr_id" "$SCRIPT_DIR/container/configure.py" "$REMOTE"; then
    log_error "Failed to push configure.py to container $starr_id"
    exit 1
fi

extra_args=()
[ "$SKIP_BAZARR" -eq 1 ] && extra_args+=(--skip-bazarr)
[ "$DRY_RUN" -eq 1 ] && extra_args+=(--dry-run)

printf '%s\n' "$QBIT_PASS" | pct exec "$starr_id" -- python3 "$REMOTE" \
    --qbit-host "$QBIT_HOST" --qbit-user "$QBIT_USER" \
    --qbit-pass-stdin --qbit-port "$QBIT_PORT" "${extra_args[@]}"
pct_status=${PIPESTATUS[1]}
if [ "$pct_status" -ne 0 ]; then
    log_error "Starr configure failed inside container $starr_id"
    exit 1
fi

log_success "Starr integrations configured!"
log_info "Verify: Prowlarr Settings -> Apps, Sonarr/Radarr Settings -> Download Clients -> Test,"
log_info "  Bazarr Settings -> Sonarr/Radarr -> Test connection."
