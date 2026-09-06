#!/bin/bash
# Tailscale package identity and sizing — single source, sourced by
# install.sh and update.sh. Never executed directly.
# shellcheck disable=SC2034 # variables are consumed by the sourcing scripts

CONTAINER_NAME="tailscale-router"
# Exclusion tag comes from the canonical NO_AUTO_PROXY_TAG in
# common/functions.sh (fallback keeps this file usable standalone).
# REQUIRED_TAGS must stay comma-separated (ensure_guest_tags contract).
REQUIRED_TAGS="tailscale,router,${NO_AUTO_PROXY_TAG:-no-auto-proxy}"
CT_CORES=1
CT_MEMORY=512
CT_DISK=8
CT_SWAP=256
DEBIAN_VERSION="13"
