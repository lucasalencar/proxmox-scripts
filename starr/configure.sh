#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

QBIT_USER="admin"
QBIT_PORT="8090"
QBIT_HOST=""
QBIT_PASS="${QBIT_PASS:-}"
PROWLARR_USER="${STARR_PROWLARR_USER:-admin}"
PROWLARR_PASS="${STARR_PROWLARR_PASS:-}"
SONARR_USER="${STARR_SONARR_USER:-admin}"
SONARR_PASS="${STARR_SONARR_PASS:-}"
RADARR_USER="${STARR_RADARR_USER:-admin}"
RADARR_PASS="${STARR_RADARR_PASS:-}"
BAZARR_USER="${STARR_BAZARR_USER:-admin}"
BAZARR_PASS="${STARR_BAZARR_PASS:-}"
AUTH_METHOD="forms"
SKIP_AUTH=0
SKIP_BAZARR=0
DRY_RUN=0

usage() {
    echo "Usage: bash starr/configure.sh --qbit-pass <password> [options]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --qbit-pass <pass>   qBittorrent admin password (or QBIT_PASS env, from qbittorrent install log)" >&2
    echo "  --qbit-user <user>   qBittorrent username (default: $QBIT_USER)" >&2
    echo "  --qbit-port <port>   qBittorrent WebUI port (default: $QBIT_PORT)" >&2
    echo "  --qbit-host <ip>     qBittorrent container IP (default: auto-discovered)" >&2
    echo "  --prowlarr-user <u>  Prowlarr login user (or STARR_PROWLARR_USER env, default: admin)" >&2
    echo "  --prowlarr-pass <p>  Prowlarr login password (or STARR_PROWLARR_PASS env, generated when absent)" >&2
    echo "  --sonarr-user <u>    Sonarr login user (or STARR_SONARR_USER env, default: admin)" >&2
    echo "  --sonarr-pass <p>    Sonarr login password (or STARR_SONARR_PASS env, generated when absent)" >&2
    echo "  --radarr-user <u>    Radarr login user (or STARR_RADARR_USER env, default: admin)" >&2
    echo "  --radarr-pass <p>    Radarr login password (or STARR_RADARR_PASS env, generated when absent)" >&2
    echo "  --bazarr-user <u>    Bazarr login user (or STARR_BAZARR_USER env, default: admin)" >&2
    echo "  --bazarr-pass <p>    Bazarr login password (or STARR_BAZARR_PASS env, generated when absent)" >&2
    echo "  --auth-method <m>    Servarr auth method: forms|basic (default: $AUTH_METHOD)" >&2
    echo "  --skip-auth          Skip per-app login configuration" >&2
    echo "  --skip-bazarr        Skip Bazarr Sonarr/Radarr linking" >&2
    echo "  --dry-run            Show planned actions without changing anything (services must still be up; password is not validated in this mode)" >&2
    echo "" >&2
    echo "Notes:" >&2
    echo "  Auth passwords travel to the container via a file secured to 0600" >&2
    echo "  inside the guest (never in argv); generated passwords are printed once in" >&2
    echo "  the final log so they can be saved in a password manager." >&2
    echo "  Re-running without explicit passwords generates new ones (rotation);" >&2
    echo "  pass them explicitly to keep the current logins." >&2
    echo "  Secrets already stored server-side read back masked, so changing a password" >&2
    echo "  requires deleting the resource first and re-running to recreate it." >&2
}

need_value() {
    local opt="$1" val="${2:-}"
    if [ -z "$val" ] || [[ "$val" == -* ]]; then
        log_error "Option $opt requires a value."
        usage
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --qbit-pass) need_value "$1" "${2:-}"; QBIT_PASS="$2"; shift 2 ;;
        --qbit-user) need_value "$1" "${2:-}"; QBIT_USER="$2"; shift 2 ;;
        --qbit-port) need_value "$1" "${2:-}"; QBIT_PORT="$2"; shift 2 ;;
        --qbit-host) need_value "$1" "${2:-}"; QBIT_HOST="$2"; shift 2 ;;
        --prowlarr-user) need_value "$1" "${2:-}"; PROWLARR_USER="$2"; shift 2 ;;
        --prowlarr-pass) need_value "$1" "${2:-}"; PROWLARR_PASS="$2"; shift 2 ;;
        --sonarr-user) need_value "$1" "${2:-}"; SONARR_USER="$2"; shift 2 ;;
        --sonarr-pass) need_value "$1" "${2:-}"; SONARR_PASS="$2"; shift 2 ;;
        --radarr-user) need_value "$1" "${2:-}"; RADARR_USER="$2"; shift 2 ;;
        --radarr-pass) need_value "$1" "${2:-}"; RADARR_PASS="$2"; shift 2 ;;
        --bazarr-user) need_value "$1" "${2:-}"; BAZARR_USER="$2"; shift 2 ;;
        --bazarr-pass) need_value "$1" "${2:-}"; BAZARR_PASS="$2"; shift 2 ;;
        --auth-method) need_value "$1" "${2:-}"; AUTH_METHOD="$2"; shift 2 ;;
        --skip-auth) SKIP_AUTH=1; shift ;;
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

case "${AUTH_METHOD,,}" in
    forms) AUTH_METHOD="forms" ;;
    basic)
        AUTH_METHOD="basic"
        log_warning "auth-method 'basic' is legacy and will be removed by Servarr; prefer 'forms'."
        ;;
    *)
        log_error "Invalid auth-method: '$AUTH_METHOD' (must be forms|basic)."
        usage
        exit 1
        ;;
esac

# Generate a login password when absent (logged once at the end for the password manager)
gen_auth_pass() {
    local generated
    generated=$(openssl rand -base64 18 2>/dev/null | tr -d '\n') || generated=""
    if [ -z "$generated" ]; then
        log_error "Failed to generate an auth password (openssl unavailable)."
        exit 1
    fi
    printf '%s' "$generated"
}

if [ "$SKIP_AUTH" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        # Planning only: placeholder forces "would_update" without minting real secrets
        [ -z "$PROWLARR_PASS" ] && PROWLARR_PASS="dry-run-placeholder"
        [ -z "$SONARR_PASS" ] && SONARR_PASS="dry-run-placeholder"
        [ -z "$RADARR_PASS" ] && RADARR_PASS="dry-run-placeholder"
        [ -z "$BAZARR_PASS" ] && BAZARR_PASS="dry-run-placeholder"
    else
        [ -z "$PROWLARR_PASS" ] && PROWLARR_PASS="$(gen_auth_pass)"
        [ -z "$SONARR_PASS" ] && SONARR_PASS="$(gen_auth_pass)"
        [ -z "$RADARR_PASS" ] && RADARR_PASS="$(gen_auth_pass)"
        [ -z "$BAZARR_PASS" ] && BAZARR_PASS="$(gen_auth_pass)"
    fi
fi

starr_id=$(get_exact_container_id_by_name "starr")
if [ -z "$starr_id" ]; then
    log_error "Could not find container 'starr'. Run install.sh first."
    exit 1
fi

if [ -z "$QBIT_HOST" ]; then
    qbit_id=$(get_exact_container_id_by_name "qbittorrent")
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

REMOTE="/root/starr-configure-$$.py"
if ! pct push "$starr_id" "$SCRIPT_DIR/container/configure.py" "$REMOTE"; then
    log_error "Failed to push configure.py to container $starr_id"
    exit 1
fi

extra_args=()
[ "$SKIP_AUTH" -eq 1 ] && extra_args+=(--skip-auth)
[ "$SKIP_AUTH" -eq 0 ] && extra_args+=(--auth-method "$AUTH_METHOD")
[ "$SKIP_BAZARR" -eq 1 ] && extra_args+=(--skip-bazarr)
[ "$DRY_RUN" -eq 1 ] && extra_args+=(--dry-run)

AUTH_REMOTE="/root/starr-auth-$$.env"
AUTH_LOCAL=""
cleanup_auth() {
    [ -n "$AUTH_LOCAL" ] && rm -f "$AUTH_LOCAL"
}
trap cleanup_auth EXIT
if [ "$SKIP_AUTH" -eq 0 ]; then
    AUTH_LOCAL="$(mktemp)" || { log_error "Failed to create temp auth file."; exit 1; }
    chmod 600 "$AUTH_LOCAL"
    # Line-based KEY=VALUE; values never appear in argv (pct log captures args only)
    {
        printf 'prowlarr_user=%s\n' "$PROWLARR_USER"
        printf 'prowlarr_pass=%s\n' "$PROWLARR_PASS"
        printf 'sonarr_user=%s\n' "$SONARR_USER"
        printf 'sonarr_pass=%s\n' "$SONARR_PASS"
        printf 'radarr_user=%s\n' "$RADARR_USER"
        printf 'radarr_pass=%s\n' "$RADARR_PASS"
        printf 'bazarr_user=%s\n' "$BAZARR_USER"
        printf 'bazarr_pass=%s\n' "$BAZARR_PASS"
    } > "$AUTH_LOCAL"
    if ! pct push "$starr_id" "$AUTH_LOCAL" "$AUTH_REMOTE"; then
        log_error "Failed to push auth file to container $starr_id"
        exit 1
    fi
    # pct push does not preserve the source mode; enforce it inside the guest
    if ! pct exec "$starr_id" -- chmod 600 "$AUTH_REMOTE"; then
        log_error "Failed to secure auth file inside container $starr_id"
        exit 1
    fi
    extra_args+=(--auth-file "$AUTH_REMOTE")
fi

printf '%s\n' "$QBIT_PASS" | pct exec "$starr_id" -- python3 "$REMOTE" \
    --qbit-host "$QBIT_HOST" --qbit-user "$QBIT_USER" \
    --qbit-pass-stdin --qbit-port "$QBIT_PORT" "${extra_args[@]}"
pct_status=${PIPESTATUS[1]}
# Remove remote secrets regardless of outcome
[ "$SKIP_AUTH" -eq 0 ] && pct exec "$starr_id" -- rm -f "$AUTH_REMOTE" "$REMOTE" >/dev/null 2>&1 || true
if [ "$pct_status" -ne 0 ]; then
    log_error "Starr configure failed inside container $starr_id"
    exit 1
fi

log_success "Starr integrations configured!"
if [ "$SKIP_AUTH" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    log_success "Starr logins configured (save these in your password manager):"
    log_success "  Prowlarr: user='$PROWLARR_USER' pass='$PROWLARR_PASS'"
    log_success "  Sonarr:   user='$SONARR_USER' pass='$SONARR_PASS'"
    log_success "  Radarr:   user='$RADARR_USER' pass='$RADARR_PASS'"
    log_success "  Bazarr:   user='$BAZARR_USER' pass='$BAZARR_PASS'"
fi
log_info "Verify: Prowlarr Settings -> Apps, Sonarr/Radarr Settings -> Download Clients -> Test,"
log_info "  Bazarr Settings -> Sonarr/Radarr -> Test connection."
