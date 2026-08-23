#!/bin/bash

# Check if username is provided as an argument
if [ -z "$1" ]; then
    log_error "You must provide a username as an argument."
    log_error "Usage: $0 <username>"
    exit 1
fi

SSH_USER=$1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

# Post install script from community
# https://community-scripts.org/scripts/post-pve-install
log_step "Running Proxmox Post-Install Script..."
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"

log_step "Updating system packages..."
apt update

# Create user for ssh access if it doesn't exist (Targeting UID 1000)
if id "$SSH_USER" &>/dev/null; then
    log_info "User $SSH_USER already exists."
    CURRENT_UID=$(id -u "$SSH_USER")
    if [ "$CURRENT_UID" != "1000" ]; then
        log_warning "User $SSH_USER exists but has UID $CURRENT_UID instead of 1000."
    fi
else
    log_step "Creating user $SSH_USER with UID 1000..."
    adduser --uid 1000 "$SSH_USER"
fi

# Save primary user for other scripts
log_step "Persisting primary user '$SSH_USER' to .server_users..."
echo "$SSH_USER" > "$(dirname "$0")/../.server_users"

# Rename GID 1000 to 'familia' for shared access
CURRENT_GROUP_NAME=$(getent group 1000 | cut -d: -f1)
if [ -n "$CURRENT_GROUP_NAME" ] && [ "$CURRENT_GROUP_NAME" != "familia" ]; then
    log_step "Renaming group 1000 ('$CURRENT_GROUP_NAME') to 'familia'..."
    groupmod -n familia "$CURRENT_GROUP_NAME"
elif [ -z "$CURRENT_GROUP_NAME" ]; then
    log_step "Group 1000 not found. Creating 'familia' group with GID 1000..."
    groupadd --gid 1000 familia
fi

# Grant sudo powers and ACL support
log_step "Installing sudo, vim and acl..."
apt install sudo vim acl -y
log_step "Adding $SSH_USER to sudo group..."
usermod -aG sudo "$SSH_USER"

# Configure SubUID/SubGID mapping for LXC UID Mapping (UID 1000)
log_step "Configuring SubUID/SubGID mapping for UID 1000..."
if ! grep -q "root:1000:1" /etc/subuid; then
    echo "root:1000:1" >> /etc/subuid
fi
if ! grep -q "root:1000:1" /etc/subgid; then
    echo "root:1000:1" >> /etc/subgid
fi

echo ""
log_success "Setup complete!"
log_info "User '$SSH_USER' is now set as the primary data owner (UID 1000)."
log_info "Proxmox is authorized to map this UID for LXC containers."
log_info "Now run 'ssh-generate-key.sh' on your personal computer to setup SSH keys for: $SSH_USER"
