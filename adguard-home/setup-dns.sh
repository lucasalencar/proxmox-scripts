#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

ADGUARD_PORT="80"
DOMAIN_SUFFIX="marx.home"

adguard_id=$(get_container_id_by_name "adguard")
if [ -z "$adguard_id" ]; then
  echo "Error: AdGuard container not found."
  exit 1
fi
ADGUARD_IP=$(get_container_ip "$adguard_id")
echo "AdGuard Home container IP: $ADGUARD_IP"

caddy_id=$(get_container_id_by_name "caddy")
if [ -z "$caddy_id" ]; then
  echo "Error: Caddy container not found. Install Caddy first."
  exit 1
fi
CADDY_IP=$(get_container_ip "$caddy_id")
echo "Caddy container IP: $CADDY_IP"

login() {
  local username password
  read -rp "AdGuard Home username: " username
  read -rsp "AdGuard Home password: " password
  echo
  login_http=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${ADGUARD_IP}:${ADGUARD_PORT}/control/login" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$username\", \"password\": \"$password\"}" \
    -c /tmp/adguard_cookies.txt)
  if [ "$login_http" != "200" ]; then
    echo "Error: Login failed (HTTP $login_http). Check username/password."
    exit 1
  fi
}

add_rewrite() {
  local domain="$1"
  local ip="$2"
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${ADGUARD_IP}:${ADGUARD_PORT}/control/rewrite/add" \
    -H "Content-Type: application/json" \
    -b /tmp/adguard_cookies.txt \
    -d "{\"domain\": \"$domain\", \"answer\": \"$ip\"}")
  echo "$http_code"
}

login

# Wildcard: all *.marx.home domains pointed to Caddy
code=$(add_rewrite "*.${DOMAIN_SUFFIX}" "$CADDY_IP")
if [ "$code" = "200" ]; then
  echo "OK  *.${DOMAIN_SUFFIX} -> $CADDY_IP"
else
  echo "ERR *.${DOMAIN_SUFFIX} -> $CADDY_IP (HTTP $code)"
fi

# Explicit rewrite for AdGuard to remain accessible independently
code=$(add_rewrite "adguard.${DOMAIN_SUFFIX}" "$ADGUARD_IP")
if [ "$code" = "200" ]; then
  echo "OK  adguard.${DOMAIN_SUFFIX} -> $ADGUARD_IP"
else
  echo "ERR adguard.${DOMAIN_SUFFIX} -> $ADGUARD_IP (HTTP $code)"
fi
