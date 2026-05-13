#!/bin/bash

DOTFILES_DIR="$HOME/.dotfiles"

echo "Updating dotfiles..."
git -C "$DOTFILES_DIR" pull

echo "Updating TPM..."
git -C "$HOME/.tmux/plugins/tpm" pull

echo "Updating tmux plugins..."
"$HOME/.tmux/plugins/tpm/scripts/update_plugins.sh"

echo "Reloading tmux config..."
tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true

echo "Update complete."
