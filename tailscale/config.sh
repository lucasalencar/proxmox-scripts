#!/bin/bash
# Tailscale package identity — single source, sourced by install.sh and update.sh.
# Never executed directly.
# shellcheck disable=SC2034 # variables are consumed by the sourcing scripts

CONTAINER_NAME="tailscale-router"
REQUIRED_TAGS="tailscale,router,no-auto-proxy"
