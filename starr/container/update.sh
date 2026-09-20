#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[starr-update] $*"; }

# Dependencies of starr/container/configure.py (migrates CTs provisioned before ruamel)
log "Ensuring configure dependencies..."
apt install -y python3-ruamel.yaml

# Trigger a Servarr app self-update: flag + restart, the app pulls itself on start
# Usage: trigger_update <service> <target> <data_dir>
trigger_update() {
    local service="$1"
    local target="$2"
    local data_dir="$3"

    if [ ! -d "$target" ] && [ ! -d "$data_dir" ]; then
        log "$service not installed — skipping"
        return 0
    fi

    log "Triggering $service self-update..."
    touch "$data_dir/update_required"
    if ! systemctl restart "$service" 2>/dev/null; then
        systemctl start "$service"
    fi

    local attempt=1
    while [ "$attempt" -le 30 ]; do
        if systemctl is-active --quiet "$service"; then
            log "  $service: active"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    log "  $service: not active after restart"
    return 1
}

trigger_update "prowlarr" "/opt/Prowlarr" "/var/lib/prowlarr"
trigger_update "sonarr" "/opt/Sonarr" "/var/lib/sonarr"
trigger_update "radarr" "/opt/Radarr" "/var/lib/radarr"

# Bazarr: refresh venv (no Servarr self-update here) and restart
if [ -d /opt/bazarr ] || [ -d /var/lib/bazarr ]; then
    log "Refreshing bazarr venv..."
    sed -i.bak "s/--only-binary=Pillow//g" /opt/bazarr/requirements.txt 2>/dev/null || true
    if [ ! -d /opt/bazarr/venv ]; then
        python3 -m venv /opt/bazarr/venv
    fi
    /opt/bazarr/venv/bin/pip install --upgrade pip -q
    /opt/bazarr/venv/bin/pip install -r /opt/bazarr/requirements.txt -q
    /opt/bazarr/venv/bin/pip install psycopg2-binary -q 2>/dev/null || true
    # Fix service ExecStart if needed
    if grep -q "ExecStart=/usr/bin/python3" /etc/systemd/system/bazarr.service 2>/dev/null; then
        sed -i "s|ExecStart=/usr/bin/python3 /opt/bazarr/bazarr.py|ExecStart=/opt/bazarr/venv/bin/python3 /opt/bazarr/bazarr.py|g" /etc/systemd/system/bazarr.service
        systemctl daemon-reload
    fi
    if ! systemctl restart bazarr 2>/dev/null; then
        systemctl start bazarr
    fi
    if systemctl is-active --quiet bazarr; then
        log "  bazarr: active"
    else
        log "  bazarr: not active after restart"
    fi
else
    log "bazarr not installed — skipping"
fi

# FlareSolverr has no self-update: stage the latest prebuilt release, validate it,
# then swap it into place so a failed download never empties /opt
if [ -f /etc/systemd/system/flaresolverr.service ]; then
    log "Refreshing FlareSolverr..."
    fs_tmpdir=$(mktemp -d)
    fs_stage="$fs_tmpdir/stage"
    mkdir -p "$fs_stage"
    refreshed=0
    if curl -fsSL -o "$fs_tmpdir/flaresolverr.tar.gz" \
        "https://github.com/FlareSolverr/FlareSolverr/releases/latest/download/flaresolverr_linux_x64.tar.gz" \
        && tar --no-same-owner -tzf "$fs_tmpdir/flaresolverr.tar.gz" >/dev/null \
        && tar --no-same-owner -xzf "$fs_tmpdir/flaresolverr.tar.gz" -C "$fs_stage" --strip-components=1 \
        && [ -x "$fs_stage/flaresolverr" ]; then
        systemctl stop flaresolverr 2>/dev/null || true
        find /opt/flaresolverr -mindepth 1 -delete 2>/dev/null || rm -rf /opt/flaresolverr/* 2>/dev/null || true
        mkdir -p /opt/flaresolverr
        cp -r "$fs_stage"/. /opt/flaresolverr/
        chmod 755 /opt/flaresolverr/flaresolverr
        if ! systemctl restart flaresolverr 2>/dev/null; then
            systemctl start flaresolverr
        fi
        refreshed=1
    else
        log "  failed to fetch a valid FlareSolverr release — keeping the installed version"
    fi
    rm -rf "$fs_tmpdir"
    if systemctl is-active --quiet flaresolverr; then
        log "  flaresolverr: active"
    elif [ "$refreshed" -eq 1 ]; then
        log "  flaresolverr: not active after restart"
    else
        log "  flaresolverr: untouched (still on the previous version)"
    fi
else
    log "flaresolverr not installed — skipping"
fi

log "Update check complete. Service status:"
systemctl is-active --quiet prowlarr && log "  prowlarr: active" || log "  prowlarr: inactive"
systemctl is-active --quiet sonarr && log "  sonarr: active" || log "  sonarr: inactive"
systemctl is-active --quiet radarr && log "  radarr: active" || log "  radarr: inactive"
systemctl is-active --quiet bazarr && log "  bazarr: active" || log "  bazarr: inactive"
systemctl is-active --quiet flaresolverr && log "  flaresolverr: active" || log "  flaresolverr: inactive"
