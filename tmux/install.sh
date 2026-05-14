#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

GIT_REPO_URL="https://github.com/lucasalencar/dotfiles.git"

TARGET_USER=$(get_primary_user) || exit 1
TARGET_HOME=$(get_primary_user_home)
DOTFILES_DIR="$TARGET_HOME/.dotfiles"

echo "Installing tmux and dependencies..."
apt install tmux fzf bat stow -y

echo "Cloning dotfiles repository..."
if [ -d "$DOTFILES_DIR" ]; then
  echo "dotfiles already cloned. Pulling latest..."
  git -C "$DOTFILES_DIR" pull
else
  git clone "$GIT_REPO_URL" "$DOTFILES_DIR"
fi

echo "Setting up DOTFILES_ROOT in .bashrc..."
grep -qxF 'export DOTFILES_ROOT="$DOTFILES_DIR"' "$TARGET_HOME/.bashrc" 2>/dev/null || \
  echo "export DOTFILES_ROOT=\"$DOTFILES_DIR\"" >> "$TARGET_HOME/.bashrc"

echo "Adding TERM fallback for Ghostty/Alacritty terminals..."
grep -qxF 'infocmp "$TERM"' "$TARGET_HOME/.bashrc" 2>/dev/null || \
  cat >> "$TARGET_HOME/.bashrc" << 'EOF'

# Fallback if terminal type is missing from terminfo (e.g. xterm-ghostty on Linux)
if [ -n "$TERM" ] && ! infocmp "$TERM" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi
EOF

export DOTFILES_ROOT="$DOTFILES_DIR"

echo "Symlinking dotfiles with stow..."
cd "$DOTFILES_DIR"
stow tmux

echo "Installing Tmux Plugin Manager (TPM)..."
if [ -d "$TARGET_HOME/.tmux/plugins/tpm" ]; then
  echo "TPM already installed. Updating..."
  git -C "$TARGET_HOME/.tmux/plugins/tpm" pull
else
  git clone https://github.com/tmux-plugins/tpm "$TARGET_HOME/.tmux/plugins/tpm"
fi

echo "Installing tmux plugins..."
"$TARGET_HOME/.tmux/plugins/tpm/scripts/install_plugins.sh"

echo "Setting ownership to $TARGET_USER..."
chown -R "$TARGET_USER:" "$DOTFILES_DIR"
chown -R "$TARGET_USER:" "$TARGET_HOME/.tmux"

echo ""
echo "Setup complete! Start tmux with: tmux"
echo "To install plugins inside tmux, press prefix + I (Shift+i)"
