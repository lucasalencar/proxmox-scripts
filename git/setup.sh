#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_non_root

echo "Configuring git repository with primary user's identity..."

PRIMARY_USER=$(get_primary_user) || exit 1
PRIMARY_HOME=$(get_primary_user_home) || exit 1

GITCONFIG="$PRIMARY_HOME/.gitconfig"
if [ ! -f "$GITCONFIG" ]; then
    echo "Error: $GITCONFIG not found for user $PRIMARY_USER." >&2
    exit 1
fi

GIT_NAME=$(git config -f "$GITCONFIG" user.name)
GIT_EMAIL=$(git config -f "$GITCONFIG" user.email)
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    echo "Error: user.name or user.email not found in $GITCONFIG." >&2
    exit 1
fi

git config --local user.name "$GIT_NAME"
git config --local user.email "$GIT_EMAIL"
echo "Set user.name = $GIT_NAME"
echo "Set user.email = $GIT_EMAIL"

SSH_KEY=$(ls "$PRIMARY_HOME/.ssh"/id_* 2>/dev/null | grep -v '\.pub$' | head -1)
if [ -n "$SSH_KEY" ]; then
    git config --local core.sshCommand "ssh -i $SSH_KEY"
    echo "Set core.sshCommand = ssh -i $SSH_KEY"
else
    echo "Warning: No private SSH key found in $PRIMARY_HOME/.ssh/. Skipping core.sshCommand."
fi

echo "Git setup complete for this repository."
