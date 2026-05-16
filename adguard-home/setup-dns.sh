#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

ADGUARD_PORT="3000"
DOMAIN_SUFFIX="marx.home"

container_id=$(get_container_id_by_name "adguard")
if [ -z "$container_id" ]; then
  echo "Error: AdGuard container not found."
  exit 1
fi
ADGUARD_IP=$(get_container_ip "$container_id")
echo "AdGuard Home container IP: $ADGUARD_IP"

# Services: name -> IP final octet
declare -A SERVICES=(
  [casaos]=136
  [jellyfin]=181
  [adguard]=22
  [ha]=282
)

login() {
  local password
  read -rsp "AdGuard Home password: " password
  echo
  curl -s -X POST "http://${ADGUARD_IP}:${ADGUARD_PORT}/control/login" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"admin\", \"password\": \"$password\"}" \
    -c /tmp/adguard_cookies.txt > /dev/null
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

for service in "${!SERVICES[@]}"; do
  domain="${service}.${DOMAIN_SUFFIX}"
  ip="192.168.31.${SERVICES[$service]}"
  code=$(add_rewrite "$domain" "$ip")
  if [ "$code" = "200" ]; then
    echo "OK  $domain -> $ip"
  else
    echo "ERR $domain -> $ip (HTTP $code)"
  fi
done
