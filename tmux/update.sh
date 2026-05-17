#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

TARGET_USER=$(get_primary_user) || exit 1
TARGET_HOME=$(get_primary_user_home)

DOTFILES_DIR="$TARGET_HOME/.dotfiles"

echo "Updating dotfiles..."
su -c "git -C '$DOTFILES_DIR' pull" "$TARGET_USER"

echo "Updating TPM..."
su -c "git -C '$TARGET_HOME/.tmux/plugins/tpm' pull" "$TARGET_USER"

echo "Updating tmux plugins..."
su -c "'$TARGET_HOME/.tmux/plugins/tpm/scripts/update_plugin.sh'" "$TARGET_USER"

echo "Reloading tmux config..."
tmux source-file "$TARGET_HOME/.tmux.conf" 2>/dev/null || true

echo "Update complete."
