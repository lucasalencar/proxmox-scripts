#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

ADGUARD_PORT="3000"
UPSTREAM_DNS=(
  "https://dns.cloudflare.com/dns-query"
  "tls://9.9.9.9"
)

container_id=$(get_container_id_by_name "adguard")
if [ -z "$container_id" ]; then
  echo "Error: AdGuard container not found."
  exit 1
fi
ADGUARD_IP=$(get_container_ip "$container_id")

read -rsp "AdGuard Home password: " password
echo

curl -s -X POST "http://${ADGUARD_IP}:${ADGUARD_PORT}/control/login" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"admin\", \"password\": \"$password\"}" \
  -c /tmp/adguard_cookies.txt > /dev/null

upstream_json=$(printf '%s\n' "${UPSTREAM_DNS[@]}" | jq -R . | jq -s .)
payload=$(jq -n --argjson upstream "$upstream_json" \
  '{upstream_dns: $upstream, upstream_dns_file: ""}')

http_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "http://${ADGUARD_IP}:${ADGUARD_PORT}/control/dns_config" \
  -H "Content-Type: application/json" \
  -b /tmp/adguard_cookies.txt \
  -d "$payload")

if [ "$http_code" = "200" ]; then
  echo "Upstream DNS configured:"
  printf '  %s\n' "${UPSTREAM_DNS[@]}"
else
  echo "Error: HTTP $http_code"
fi
