#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[starr-update] $*"; }

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

log "Update check complete. Service status:"
systemctl is-active --quiet prowlarr && log "  prowlarr: active" || log "  prowlarr: inactive"
systemctl is-active --quiet sonarr && log "  sonarr: active" || log "  sonarr: inactive"
systemctl is-active --quiet radarr && log "  radarr: active" || log "  radarr: inactive"
systemctl is-active --quiet bazarr && log "  bazarr: active" || log "  bazarr: inactive"
