#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

ADGUARD_PORT="80"
UPSTREAM_DNS=(
  "https://security.cloudflare-dns.com/dns-query"
)

container_id=$(get_container_id_by_name "adguard")
if [ -z "$container_id" ]; then
  echo "Error: AdGuard container not found."
  exit 1
fi
ADGUARD_IP=$(get_container_ip "$container_id")

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

upstream_json=$(printf '%s\n' "${UPSTREAM_DNS[@]}" | jq -R . | jq -s .)
payload=$(jq -n --argjson upstream "$upstream_json" \
  '{upstream_dns: $upstream, upstream_dns_file: ""}')

http_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://${ADGUARD_IP}:${ADGUARD_PORT}/control/dns_config" \
  -H "Content-Type: application/json" \
  -b /tmp/adguard_cookies.txt \
  -d "$payload")

if [ "$http_code" = "200" ]; then
  echo "Upstream DNS configured:"
  printf '  %s\n' "${UPSTREAM_DNS[@]}"
else
  echo "Error: HTTP $http_code"
fi
