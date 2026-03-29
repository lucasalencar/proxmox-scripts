#!/bin/bash

echo "Install CasaOS using LXC container"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/casaos.sh)"

echo "Setting up mount: /tank/data/memorias -> /Gallery (mp0)"
pct set "$container_id" -mp1 /tank/data/memorias,mp=/DATA/Gallery

echo "Setting up mount: /tank/data/media -> /Media (mp1)"
pct set "$container_id" -mp2 /tank/data/media,mp=/DATA/Media
