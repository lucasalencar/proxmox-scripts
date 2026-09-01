#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[starr-install] $*"; }

log "Updating OS and installing base dependencies..."
apt update
apt upgrade -y
apt install -y curl sqlite3 libicu-dev jq unzip ca-certificates gnupg python3 python3-venv python3-pip libssl-dev

# Detect arch for Servarr assets
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64) SERVARR_ARCH="x64" ;;
    arm64|aarch64) SERVARR_ARCH="arm64" ;;
    *) SERVARR_ARCH="x64"; log "Unknown arch $ARCH, defaulting to x64" ;;
esac
log "Detected arch: $ARCH -> Servarr arch: $SERVARR_ARCH"

# Helper: fetch latest release asset from GitHub and deploy to /opt/<app>
fetch_and_deploy() {
    local app_name="$1"      # e.g. Prowlarr
    local repo="$2"          # e.g. Prowlarr/Prowlarr
    local target="$3"        # e.g. /opt/Prowlarr
    local pattern="$4"       # e.g. Prowlarr.master*linux-core-x64.tar.gz
    local data_dir="$5"      # e.g. /var/lib/prowlarr (optional)

    log "Fetching $app_name from $repo (pattern: $pattern)..."
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url")
    local tag=$(echo "$json" | jq -r ".tag_name // empty")
    if [ -z "$tag" ]; then
        log "ERROR: Could not get tag for $repo"
        return 1
    fi
    log "  Latest tag: $tag"

    local asset_url=$(echo "$json" | jq -r --arg pat "$pattern" '.assets[] | select(.name | test($pat)) | .browser_download_url' | head -1)
    # Fallback: try glob match with case
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        # Try alternative: list names and case-match
        local avail=$(echo "$json" | jq -r ".assets[].name" | tr "\n" " ")
        log "  No asset matched pattern $pattern. Available: $avail"
        # Try without arch suffix for debugging
        asset_url=$(echo "$json" | jq -r ".assets[].browser_download_url" | head -1)
    fi
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        log "ERROR: No asset found for $app_name"
        return 1
    fi
    log "  Asset URL: $asset_url"

    local tmpdir=$(mktemp -d)
    local archive="$tmpdir/archive"
    curl -fsSL -o "$archive" "$asset_url"

    mkdir -p "$target"
    # Clear target if exists (preserve mount points - none here)
    if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
        log "  Clearing $target (CLEAN_INSTALL)"
        find "$target" -mindepth 1 -delete 2>/dev/null || rm -rf "${target:?}/"* 2>/dev/null || true
    fi

    local filename=$(basename "$asset_url")
    mkdir -p "$tmpdir/extract"
    if [[ "$filename" == *.zip ]]; then
        unzip -q "$archive" -d "$tmpdir/extract"
        # bazarr.zip contains files directly or in subdir
        if [ $(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ] && [ -d "$(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | head -1)" ]; then
            cp -r "$(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | head -1)"/* "$target/"
        else
            cp -r "$tmpdir/extract"/* "$target/"
        fi
    else
        tar --no-same-owner -xzf "$archive" -C "$tmpdir/extract" 2>/dev/null || tar --no-same-owner -xf "$archive" -C "$tmpdir/extract"
        local top=$(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | head -1)
        if [ -d "$top" ] && [ $(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]; then
            cp -r "$top"/* "$target/"
        else
            cp -r "$tmpdir/extract"/* "$target/"
        fi
    fi
    chmod 775 "$target"
    rm -rf "$tmpdir"

    if [ -n "$data_dir" ]; then
        mkdir -p "$data_dir"
        chmod 775 "$data_dir" "$target"
    fi
    echo "$tag" > "$HOME/.$(echo "$app_name" | tr "[:upper:]" "[:lower:]")"
    log "  Deployed $app_name $tag to $target"
}

# Prowlarr
if [ ! -f /etc/systemd/system/prowlarr.service ]; then
    fetch_and_deploy "Prowlarr" "Prowlarr/Prowlarr" "/opt/Prowlarr" "Prowlarr.master.*linux-core-${SERVARR_ARCH}.tar.gz" "/var/lib/prowlarr"
    cat >/etc/systemd/system/prowlarr.service <<EOF
[Unit]
Description=Prowlarr Daemon
After=syslog.target network.target

[Service]
UMask=0002
Type=simple
ExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data=/var/lib/prowlarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now prowlarr
    log "Prowlarr installed and started"
else
    log "Prowlarr already installed — skipping"
fi

# Sonarr
if [ ! -f /etc/systemd/system/sonarr.service ]; then
    fetch_and_deploy "Sonarr" "Sonarr/Sonarr" "/opt/Sonarr" "Sonarr.main.*.linux-${SERVARR_ARCH}.tar.gz" "/var/lib/sonarr"
    mkdir -p /var/lib/sonarr
    chmod 775 /var/lib/sonarr
    cat >/etc/systemd/system/sonarr.service <<EOF
[Unit]
Description=Sonarr Daemon
After=syslog.target network.target

[Service]
Type=simple
ExecStart=/opt/Sonarr/Sonarr -nobrowser -data=/var/lib/sonarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sonarr
    log "Sonarr installed and started"
else
    log "Sonarr already installed — skipping"
fi

# Radarr
if [ ! -f /etc/systemd/system/radarr.service ]; then
    fetch_and_deploy "Radarr" "Radarr/Radarr" "/opt/Radarr" "Radarr.master.*linux-core-${SERVARR_ARCH}.tar.gz" "/var/lib/radarr"
    mkdir -p /var/lib/radarr
    chmod 775 /var/lib/radarr /opt/Radarr
    cat >/etc/systemd/system/radarr.service <<EOF
[Unit]
Description=Radarr Daemon
After=syslog.target network.target

[Service]
UMask=0002
Type=simple
ExecStart=/opt/Radarr/Radarr -nobrowser -data=/var/lib/radarr/
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now radarr
    log "Radarr installed and started"
else
    log "Radarr already installed — skipping"
fi

# Bazarr
if [ ! -f /etc/systemd/system/bazarr.service ]; then
    fetch_and_deploy "bazarr" "morpheus65535/bazarr" "/opt/bazarr" "bazarr.zip" "/var/lib/bazarr"
    mkdir -p /var/lib/bazarr
    chmod 775 /opt/bazarr /var/lib/bazarr
    # Remove problematic Pillow flag if present
    sed -i.bak "s/--only-binary=Pillow//g" /opt/bazarr/requirements.txt 2>/dev/null || true
    # Create venv
    if [ ! -d /opt/bazarr/venv ]; then
        python3 -m venv /opt/bazarr/venv
    fi
    /opt/bazarr/venv/bin/pip install --upgrade pip
    /opt/bazarr/venv/bin/pip install -r /opt/bazarr/requirements.txt
    /opt/bazarr/venv/bin/pip install psycopg2-binary 2>/dev/null || true

    cat >/etc/systemd/system/bazarr.service <<EOF
[Unit]
Description=Bazarr Daemon
After=syslog.target network.target

[Service]
WorkingDirectory=/opt/bazarr/
UMask=0002
Restart=on-failure
RestartSec=5
Type=simple
ExecStart=/opt/bazarr/venv/bin/python3 /opt/bazarr/bazarr.py -c /var/lib/bazarr
KillSignal=SIGINT
TimeoutStopSec=20
SyslogIdentifier=bazarr

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now bazarr
    log "Bazarr installed and started"
else
    log "Bazarr already installed — skipping"
fi

log "All Starr apps installed. Checking services..."
systemctl is-active --quiet prowlarr && log "  prowlarr: active" || log "  prowlarr: not active"
systemctl is-active --quiet sonarr && log "  sonarr: active" || log "  sonarr: not active"
systemctl is-active --quiet radarr && log "  radarr: active" || log "  radarr: not active"
systemctl is-active --quiet bazarr && log "  bazarr: active" || log "  bazarr: not active"
