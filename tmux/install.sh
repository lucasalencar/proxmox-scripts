#!/bin/bash

GIT_REPO_URL="git@github.com:lucasalencar/dotfiles.git"
DOTFILES_DIR="$HOME/.dotfiles"

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
grep -qxF 'export DOTFILES_ROOT="$HOME/.dotfiles"' "$HOME/.bashrc" 2>/dev/null || \
  echo 'export DOTFILES_ROOT="$HOME/.dotfiles"' >> "$HOME/.bashrc"

export DOTFILES_ROOT="$HOME/.dotfiles"

echo "Symlinking dotfiles with stow..."
cd "$DOTFILES_DIR" && stow tmux

echo "Installing Tmux Plugin Manager (TPM)..."
if [ -d "$HOME/.tmux/plugins/tpm" ]; then
  echo "TPM already installed. Updating..."
  git -C "$HOME/.tmux/plugins/tpm" pull
else
  git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
fi

echo "Installing tmux plugins..."
"$HOME/.tmux/plugins/tpm/scripts/install_plugins.sh"

echo ""
echo "Setup complete! Start tmux with: tmux"
echo "To install plugins inside tmux, press prefix + I (Shift+i)"
