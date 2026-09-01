#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

DOCUMENTS_SOURCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--documents)
            DOCUMENTS_SOURCE="$2"
            shift 2
            ;;
        -h|--help)
            log_error "Usage: $0 [-d|--documents <host_path>]"
            echo ""
            echo "Options:"
            echo "  -d, --documents <path>  Mount a host path as /DATA/Documents (e.g., /tank/data/lucas)"
            echo "                          Default: skip"
            exit 0
            ;;
        *)
            log_error "Usage: $0 [-d|--documents <host_path>]"
            exit 1
            ;;
    esac
done

log_step "Starting CasaOS installation/configuration via LXC container..."

# 1. ENSURE CasaOS is installed
CASAOS_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/casaos.sh)"'
container_id=$(ensure_container_installed "casaos" "$CASAOS_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

# 2. DISCOVER Primary User for reference
PRIMARY_USER=$(get_primary_user) || exit 1
log_info "Primary User reference: $PRIMARY_USER"

# 3. DISCOVER host UID of the root user (who runs CasaOS)
host_casaos_uid=$(get_host_uid "$container_id" root) || exit 1
log_info "CasaOS host UID: $host_casaos_uid"

# 4. APPLY ACLs for CasaOS on the mounted datasets
log_step "Granting CasaOS (UID $host_casaos_uid) access to datasets..."
add_dataset_acl "/tank/data/mediaserver" "$host_casaos_uid"
add_dataset_acl "/tank/data/memorias" "$host_casaos_uid"

# 4.1 Grant ACLs for Docker default user (PUID=1000) inside CasaOS
host_docker_uid=$((host_casaos_uid + 1000))
log_step "Granting Docker default user (host UID $host_docker_uid) access to mediaserver..."
add_dataset_acl "/tank/data/mediaserver" "$host_docker_uid"

# 5. Perform bind mounts
mounts=(
    /tank/data/memorias /DATA/Gallery
    /tank/data/mediaserver/media /DATA/Media
    /tank/data/mediaserver/downloads /DATA/Downloads
)
if [ -n "$DOCUMENTS_SOURCE" ]; then
    if [ ! -d "$DOCUMENTS_SOURCE" ]; then
        log_error "Documents source does not exist or is not a directory: $DOCUMENTS_SOURCE"
        exit 1
    fi
    real_docs=$(realpath -m "$DOCUMENTS_SOURCE" 2>/dev/null || echo "$DOCUMENTS_SOURCE")
    case "$real_docs" in
        /tank/data/*) ;;
        *)
            log_error "Documents source must be under /tank/data (got $real_docs)"
            exit 1
            ;;
    esac
    if [ "$real_docs" = "/tank/data" ]; then
        log_error "Refusing to mount /tank/data itself"
        exit 1
    fi
    add_dataset_acl "$DOCUMENTS_SOURCE" "$host_casaos_uid"
    mounts+=("$DOCUMENTS_SOURCE" /DATA/Documents)
fi

apply_mounts "$container_id" "${mounts[@]}"

echo ""
log_success "Installation and Bind Mounts completed for CasaOS (ID: $container_id)."
