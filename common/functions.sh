#!/bin/bash

# ANSI color codes (empty when not a TTY, so piped output stays clean)
if [ -t 1 ]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_RED="\033[31m"
    COLOR_GREEN="\033[32m"
    COLOR_YELLOW="\033[33m"
    COLOR_CYAN="\033[36m"
    COLOR_MAGENTA="\033[35m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_MAGENTA=""
fi

# Prints a highlighted step header (bold cyan)
# Usage: log_step "Starting update of nextcloud"
log_step() {
    echo -e "${COLOR_BOLD}${COLOR_CYAN}🚀 $*${COLOR_RESET}"
}

# Prints an informational message (cyan)
# Usage: log_info "Path: ./nextcloud"
log_info() {
    echo -e "${COLOR_CYAN}ℹ️  $*${COLOR_RESET}"
}

# Prints a success message (bold green)
# Usage: log_success "Update completed"
log_success() {
    echo -e "${COLOR_BOLD}${COLOR_GREEN}✅ $*${COLOR_RESET}"
}

# Prints a warning message (bold yellow)
# Usage: log_warning "Script not found"
log_warning() {
    echo -e "${COLOR_BOLD}${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"
}

# Prints an error message (bold red, to stderr)
# Usage: log_error "Update failed"
log_error() {
    echo -e "${COLOR_BOLD}${COLOR_RED}❌ $*${COLOR_RESET}" >&2
}

# Exits with error if not running as root
if ! declare -F require_root >/dev/null 2>&1; then
require_root() {
    if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root." >&2
        exit 1
    fi
}
fi

# Exits with error if running as root
if ! declare -F require_non_root >/dev/null 2>&1; then
require_non_root() {
    if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
        return 0
    fi
    if [[ $EUID -eq 0 ]]; then
        echo "Error: This script must NOT be run as root. Run it as your regular user." >&2
        exit 1
    fi
}
fi

# Returns the primary username from .server_users file (first user in the list)
get_primary_user() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local users_file="$script_dir/../.server_users"

    if [ ! -f "$users_file" ]; then
        echo "Error: .server_users file not found. Run 001-root-setup.sh first." >&2
        return 1
    fi

    head -n 1 "$users_file"
}

# Returns all registered server usernames from .server_users file
# Usage: for user in $(get_all_users); do echo "$user"; done
get_all_users() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local users_file="$script_dir/../.server_users"

    if [ ! -f "$users_file" ]; then
        echo "Error: .server_users file not found. Run 001-root-setup.sh first." >&2
        return 1
    fi

    cat "$users_file"
}

# Checks if a username is already registered in .server_users
# Usage: if is_user_registered "lucas"; then echo "exists"; fi
is_user_registered() {
    local username="$1"
    [ -z "$username" ] && return 1

    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local users_file="$script_dir/../.server_users"

    if [ ! -f "$users_file" ]; then
        return 1
    fi

    grep -Fqx -- "$username" "$users_file"
}

# Adds a username to the end of .server_users if not already registered
# Usage: add_user_to_server "jacque" || exit 1
add_user_to_server() {
    local username="$1"
    [ -z "$username" ] && return 1

    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local users_file="$script_dir/../.server_users"

    if [ ! -f "$users_file" ]; then
        echo "Error: .server_users file not found. Run 001-root-setup.sh first." >&2
        return 1
    fi

    if is_user_registered "$username"; then
        echo "User '$username' is already registered."
        return 0
    fi

    echo "$username" >> "$users_file"
    echo "User '$username' added to .server_users."
}

# Returns the home directory of the primary user.
# Usage: TARGET_HOME=$(get_primary_user_home)
get_primary_user_home() {
    local user
    user=$(get_primary_user) || return 1
    getent passwd "$user" | cut -d: -f6
}

# Ensures a container is installed, running a command if it's missing.
# Returns the container ID.
# Usage: ensure_container_installed "name" "install_command"
ensure_container_installed() {
    local name="$1"
    local install_cmd="$2"
    local container_id

    container_id=$(get_container_id_by_name "$name")

    if [ -z "$container_id" ]; then
        echo "$name container not found. Running installation..." >&2
        bash -c "$install_cmd"

        # Get ID again after installation
        container_id=$(get_container_id_by_name "$name")
    else
        echo "$name container already exists (ID: $container_id). Skipping installation." >&2
    fi

    if [ -z "$container_id" ]; then
        echo "Error: Could not find or create container '$name'." >&2
        return 1
    fi

    echo "$container_id"
}

# Waits until a container responds to pct exec commands.
# Usage: wait_container_ready <container_id> [max_attempts] [sleep_seconds]
# Returns 0 if ready, 1 if timed out.
wait_container_ready() {
    local container_id="$1"
    local max_attempts="${2:-15}"
    local sleep_seconds="${3:-2}"
    local attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        if pct exec "$container_id" -- true 2>/dev/null; then
            return 0
        fi
        sleep "$sleep_seconds"
        attempt=$((attempt + 1))
    done

    log_error "Container $container_id not responsive after $((max_attempts * sleep_seconds))s"
    return 1
}

# Returns the VM ID by its name (partial match, case-insensitive)
# Usage: get_vm_id_by_name "name"
get_vm_id_by_name() {
    local name="$1"
    [ -z "$name" ] && return 1
    qm list 2>/dev/null | awk -v p="$name" '
        NR>1 && index(tolower($2), tolower(p)) { print $1; exit }
    '
}

# Returns the primary IP of a VM via guest agent (fallback ipconfig from config)
# Usage: vm_ip=$(get_vm_ip <vmid>)
get_vm_ip() {
    local vmid="$1"
    local ip
    ip=$(qm guest exec "$vmid" -- hostname -I 2>/dev/null | jq -r '.["out-data"] // .["out"] // empty' | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ipconfig\d:\s*ip=\K[^/]+' | head -1)
    fi
    echo "$ip"
}

# Returns the primary IP of a container by its ID.
# Waits for the container to be ready before fetching the IP.
# Usage: container_ip=$(get_container_ip <container_id>)
get_container_ip() {
    local container_id="$1"
    local ip

    wait_container_ready "$container_id" || return 1

    ip=$(pct exec "$container_id" -- hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(pct config "$container_id" | grep -oP 'ip=\K[^\s/]+' | grep -v '^dhcp$')
    fi

    echo "$ip"
}

# Stops a container, applies all bind mounts, and restarts it.
# The container is guaranteed to be ready when this function returns.
# Usage: apply_mounts [--start-index N] <container_id> <host_path> <container_path> [host_path container_path] ...
# Example: apply_mounts 106 /tank/data /data /tank/data/media /DATA/Media
# Example: apply_mounts --start-index 5 106 /tank/data /data
apply_mounts() {
    local mp_index=1

    # Parse optional --start-index flag (before container_id)
    if [[ "$1" == "--start-index" ]]; then
        if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
            log_error "apply_mounts: --start-index requires numeric value"
            return 1
        fi
        mp_index="$2"
        shift 2
    fi

    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "apply_mounts: missing container_id"
        return 1
    fi
    shift

    # Also handle --start-index after container_id
    if [[ "$1" == "--start-index" ]]; then
        if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
            log_error "apply_mounts: --start-index requires numeric value"
            return 1
        fi
        mp_index="$2"
        shift 2
    fi

    # Deprecated trailing numeric without flag — warn but do not consume as index
    if [ $(( $# % 2 )) -ne 0 ] && [[ "${!#}" =~ ^[0-9]+$ ]]; then
        log_warning "apply_mounts: trailing numeric '${!#}' ignored — use --start-index N instead"
    fi

    log_step "Stopping container $container_id..."
    pct stop "$container_id" 2>/dev/null

    # Warn if an odd number of path arguments were passed
    if [ $(( $# % 2 )) -ne 0 ]; then
        log_warning "apply_mounts received an odd number of path arguments; the last one will be ignored."
    fi

    while [ $# -ge 2 ]; do
        local host_path="$1"
        local container_path="$2"
        shift 2

        # Check if this index is already in use
        local existing
        existing=$(pct config "$container_id" 2>/dev/null | grep -oP "^mp${mp_index}:\s*\K[^,]+")
        if [ -n "$existing" ]; then
            log_warning "mp${mp_index} already in use ($existing)"
            read -r -p "Overwrite mp${mp_index}? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_error "Mount aborted by user — skipping apply_mounts"
                pct start "$container_id"
                wait_container_ready "$container_id"
                return 1
            fi
        fi

        log_info "Setting mp${mp_index}: ${host_path} -> ${container_path}"
        if ! pct set "$container_id" "-mp${mp_index}" "${host_path},mp=${container_path}"; then
            log_error "Failed to set mp${mp_index} (${host_path} -> ${container_path})"
            pct start "$container_id"
            wait_container_ready "$container_id"
            return 1
        fi
        mp_index=$((mp_index + 1))
    done

    log_step "Starting container $container_id..."
    pct start "$container_id"
    wait_container_ready "$container_id"
}

# Returns the container ID by its name (partial match, case-insensitive)
# Usage: get_container_id_by_name "name"
get_container_id_by_name() {
    local name="$1"
    if [ -z "$name" ]; then
        return 1
    fi
    pct list | grep -F -i -- "$name" | sort -n | tail -1 | awk '{print $1}'
}

# Configures ZFS ACLs for specific users and enables inheritance
# Usage: setup_dataset_acls <dataset_name> <mount_path> <owner_uid> [extra_uids...]
setup_dataset_acls() {
    local dataset="$1"
    local path="$2"
    local owner_uid="$3"
    shift 3
    local extra_uids=("$@")

    echo "Enabling ZFS POSIX ACLs on $dataset..."
    zfs set acltype=posixacl "$dataset"
    zfs set xattr=sa "$dataset"

    echo "Setting ownership to $owner_uid and applying ACLs to $path..."
    chown -R "$owner_uid":1000 "$path"
    chmod 2770 "$path"

    # Clear existing ACLs

    setfacl -bnR "$path"

    # Define ACL string starting with owner and group
    local acl_str="u::rwx,g::rwx,o::-,u:$owner_uid:rwx"

    for uid in "${extra_uids[@]}"; do
        acl_str+=",u:$uid:rwx"
    done

    # Apply access ACLs
    setfacl -R -m "$acl_str" "$path"

    # Apply default ACLs (for inheritance)
    setfacl -R -d -m "$acl_str" "$path"

    # Ensure mask is correct
    setfacl -R -m m::rwx "$path"
    setfacl -R -d -m m::rwx "$path"

    echo "ACLs applied to $path (U:$owner_uid, Extra:[${extra_uids[*]}])"
}

# Appends a specific UID to existing ACLs of a path (both access and default)
# Usage: add_dataset_acl <path> <uid>
add_dataset_acl() {
    local path="$1"
    local uid="$2"

    if [ -z "$uid" ] || ! [[ "$uid" =~ ^[0-9]+$ ]]; then
        log_error "add_dataset_acl: invalid uid '$uid'"
        return 1
    fi

    # Fast path: skip the recursive walk when the entry is already present.
    # setfacl -R over large datasets is slow; default ACLs cover new files.
    local current_acls
    if current_acls=$(getfacl "$path" 2>/dev/null); then
        if echo "$current_acls" | grep -q "^user:$uid:rwx$" \
            && echo "$current_acls" | grep -q "^default:user:$uid:rwx$"; then
            log_info "ACL for UID $uid already present on $path — skipping"
            return 0
        fi
    fi

    echo "Appending ACL for UID $uid to $path..."
    # Access ACL
    setfacl -R -m "u:$uid:rwx" "$path"
    # Default ACL (for inheritance)
    setfacl -R -d -m "u:$uid:rwx" "$path"
    # Ensure mask is updated
    setfacl -R -m m::rwx "$path"
    setfacl -R -d -m m::rwx "$path"
}

# Returns the host UID for a user inside a container (container UID + 100000)
# Usage: host_uid=$(get_host_uid <container_id> <username>) || exit 1
get_host_uid() {
    local container_id="$1"
    local username="$2"
    local uid
    uid=$(pct exec "$container_id" -- id -u "$username" 2>/dev/null)
    if [ -z "$uid" ] || ! [[ "$uid" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine UID for user '$username' inside container $container_id"
        return 1
    fi
    echo $((uid + 100000))
}

# --- PVE LXC provisioning helpers (reusable for any custom Debian LXC) ---

# Returns template storage name (default: local)
# Usage: storage=$(get_pve_template_storage)
get_pve_template_storage() {
    echo "local"
}

# Returns rootfs storage name (local-lvm if present, else local)
# Usage: storage=$(get_pve_rootfs_storage)
get_pve_rootfs_storage() {
    if pvesm status 2>/dev/null | grep -q "local-lvm"; then
        echo "local-lvm"
    else
        echo "local"
    fi
}

# Returns the default network bridge (auto-detected or vmbr0)
# Usage: bridge=$(detect_pve_bridge)
detect_pve_bridge() {
    local detected
    detected=$(ip -o link show 2>/dev/null | grep -o "vmbr[0-9]*" | head -1)
    if [ -n "$detected" ]; then
        echo "$detected"
    else
        echo "vmbr0"
    fi
}

# Returns the next available CTID from Proxmox
# Usage: ctid=$(get_pve_next_id) || exit 1
get_pve_next_id() {
    local ctid
    ctid=$(pvesh get /cluster/nextid 2>/dev/null)
    if [ -z "$ctid" ]; then
        log_error "Failed to get next CTID from pvesh"
        return 1
    fi
    echo "$ctid"
}

# Returns the host template arch (amd64/arm64) for pveam template selection.
# Test hook: MOCK_HOST_ARCH overrides detection.
# Usage: arch=$(get_host_template_arch)
get_host_template_arch() {
    if [ -n "${MOCK_HOST_ARCH:-}" ]; then
        echo "$MOCK_HOST_ARCH"
        return 0
    fi
    local dpkg_arch
    if dpkg_arch=$(dpkg --print-architecture 2>/dev/null) && [ -n "$dpkg_arch" ]; then
        case "$dpkg_arch" in
            amd64|x86_64) echo "amd64"; return 0 ;;
            arm64|aarch64) echo "arm64"; return 0 ;;
            *) echo "$dpkg_arch"; return 0 ;;
        esac
    fi
    local uname_m
    uname_m=$(uname -m 2>/dev/null || true)
    case "$uname_m" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        "") return 1 ;;
        *) echo "$uname_m" ;;
    esac
}

# Ensures a Debian template is present on the given storage.
# Prints the template name (e.g. debian-13-standard_13.0-1_amd64.tar.zst) to stdout.
# Logs go to stderr so command substitution stays clean.
# Usage: template=$(ensure_debian_template 13 [storage]) || exit 1
ensure_debian_template() {
    local version="${1:-13}"
    local storage="${2:-$(get_pve_template_storage)}"
    local template=""

    pveam update >/dev/null 2>&1 || true

    local arch
    arch=$(get_host_template_arch 2>/dev/null || true)

    local available
    available=$(pveam available --section system 2>/dev/null || true)

    if [ -n "$arch" ]; then
        template=$(echo "$available" | grep -E "debian-${version}-standard" | grep -F "$arch" | awk '{print $2}' | sort -V | tail -1)
    fi
    if [ -z "$template" ]; then
        template=$(echo "$available" | grep -E "debian-${version}-standard" | awk '{print $2}' | sort -V | tail -1)
    fi
    if [ -z "$template" ]; then
        local available_all
        available_all=$(pveam available 2>/dev/null || true)
        if [ -n "$arch" ]; then
            template=$(echo "$available_all" | grep -E "debian-${version}" | grep -F "$arch" | awk '{print $2}' | sort -V | tail -1)
        fi
        if [ -z "$template" ]; then
            template=$(echo "$available_all" | grep -E "debian-${version}" | awk '{print $2}' | sort -V | tail -1)
        fi
    fi
    if [ -z "$template" ]; then
        log_error "Could not find Debian ${version} template via pveam available" >&2
        return 1
    fi

    local template_file
    template_file=$(basename "$template")
    log_info "Template: $template" >&2

    if ! pveam list "$storage" 2>/dev/null | grep -q "$template_file"; then
        log_step "Downloading template $template to $storage..." >&2
        if ! pveam download "$storage" "$template" >&2; then
            log_error "Failed to download template $template" >&2
            return 1
        fi
    else
        log_info "Template $template_file already present" >&2
    fi

    echo "$template"
}

# Creates a Debian LXC with opinionated defaults (unprivileged, nesting, DHCP).
# Starts the container and waits until ready.
# Usage: create_lxc_container <ctid> <hostname> <template_storage> <template_file> <rootfs_storage> <bridge> [cores] [memory] [disk_gb] [swap] [tags] [description]
create_lxc_container() {
    local ctid="$1"
    local hostname="$2"
    local template_storage="$3"
    local template_file="$4"
    local rootfs_storage="$5"
    local bridge="$6"
    local cores="${7:-2}"
    local memory="${8:-2048}"
    local disk="${9:-20}"
    local swap="${10:-512}"
    local tags="${11:-}"
    local description="${12:-}"

    if [ -z "$ctid" ] || [ -z "$hostname" ] || [ -z "$template_storage" ] || [ -z "$template_file" ] || [ -z "$rootfs_storage" ] || [ -z "$bridge" ]; then
        log_error "create_lxc_container: missing required argument (ctid/hostname/template_storage/template_file/rootfs_storage/bridge)"
        return 1
    fi

    local create_args=(
        "$ctid" "${template_storage}:vztmpl/${template_file}"
        --hostname "$hostname"
        --cores "$cores"
        --memory "$memory"
        --swap "$swap"
        --rootfs "${rootfs_storage}:${disk}"
        --unprivileged 1
        --features nesting=1,keyctl=1
        --net0 "name=eth0,bridge=${bridge},ip=dhcp,firewall=1"
        --ostype debian
        --onboot 1
    )
    if [ -n "$tags" ]; then
        create_args+=(--tags "$tags")
    fi
    if [ -n "$description" ]; then
        create_args+=(--description "$description")
    fi

    log_step "Creating LXC $ctid ($hostname)..."
    if ! pct create "${create_args[@]}"; then
        log_error "pct create failed for $hostname ($ctid)"
        return 1
    fi

    log_info "Starting container $ctid..."
    pct start "$ctid"
    if ! wait_container_ready "$ctid" 60 2; then
        log_error "Container $ctid not ready after creation"
        return 1
    fi
}

# Pushes a host script into a container and executes it via bash.
# Usage: exec_script_in_container <container_id> <host_script_path> [args...]
exec_script_in_container() {
    local container_id="$1"
    local host_script="$2"
    shift 2 || true

    if [ -z "$container_id" ] || [ -z "$host_script" ]; then
        log_error "exec_script_in_container: missing container_id or host_script"
        return 1
    fi
    if [ ! -f "$host_script" ]; then
        log_error "exec_script_in_container: host script not found: $host_script"
        return 1
    fi

    local remote_path="/tmp/$(basename "$host_script")"
    if ! pct push "$container_id" "$host_script" "$remote_path" 2>/dev/null; then
        log_error "Failed to push $host_script to $container_id:$remote_path"
        return 1
    fi
    if ! pct exec "$container_id" -- bash "$remote_path" "$@"; then
        log_error "Failed to execute $remote_path in container $container_id"
        return 1
    fi
}
