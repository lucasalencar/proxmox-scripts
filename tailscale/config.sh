#!/bin/bash
# Tailscale package identity and sizing — single source, sourced by
# install.sh and update.sh. Never executed directly.
# shellcheck disable=SC2034 # variables are consumed by the sourcing scripts

CONTAINER_NAME="tailscale-router"
REQUIRED_TAGS="tailscale,router,no-auto-proxy"
CT_CORES=1
CT_MEMORY=512
CT_DISK=8
CT_SWAP=256
DEBIAN_VERSION="13"
