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

# 3. DISCOVER internal UID of the root user (who runs CasaOS)
internal_uid=$(pct exec "$container_id" -- id -u root)
host_casaos_uid=$((internal_uid + 100000))
log_info "CasaOS internal UID: $internal_uid -> Host UID: $host_casaos_uid"

# 4. APPLY ACLs for CasaOS on the mounted datasets
log_step "Granting CasaOS (UID $host_casaos_uid) access to datasets..."
add_dataset_acl "/tank/data/media" "$host_casaos_uid"
add_dataset_acl "/tank/data/memorias" "$host_casaos_uid"
add_dataset_acl "/tank/data/downloads" "$host_casaos_uid"

# 4.1 Also grant ACLs for Docker default user (PUID=1000) inside CasaOS
host_docker_uid=$((host_casaos_uid + 1000))
log_step "Granting Docker default user (host UID $host_docker_uid) access to datasets..."
add_dataset_acl "/tank/data/downloads" "$host_docker_uid"
add_dataset_acl "/tank/data/media" "$host_docker_uid"

# 5. Perform bind mounts
mounts=(
    /tank/data/memorias /DATA/Gallery
    /tank/data/media /DATA/Media
    /tank/data/downloads /DATA/Downloads
)
if [ -n "$DOCUMENTS_SOURCE" ]; then
    add_dataset_acl "$DOCUMENTS_SOURCE" "$host_casaos_uid"
    mounts+=("$DOCUMENTS_SOURCE" /DATA/Documents)
fi

apply_mounts "$container_id" "${mounts[@]}"

echo ""
log_success "Installation and Bind Mounts completed for CasaOS (ID: $container_id)."
