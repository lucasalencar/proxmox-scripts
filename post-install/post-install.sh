#!/bin/bash

apt update

# Create user for ssh access
adduser lucas

# Grant sudo powers
apt install sudo vim -y
usermod -aG sudo lucas

echo "Run ssh-generate-key.sh on your personal computer to setup SSH keys"
