#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_non_root

TARGET_USER="$USER"
TARGET_HOME="$HOME"

echo "Target user: $TARGET_USER ($TARGET_HOME)"
read -r -p "Continue? (y/N): " response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Install opencode for the current user
curl -fsSL https://opencode.ai/install | bash

# Create symlink for system-wide access
sudo mkdir -p /usr/local/bin
sudo ln -sf "$TARGET_HOME/.opencode/bin/opencode" /usr/local/bin/opencode

echo ""
echo "Installation complete!"
