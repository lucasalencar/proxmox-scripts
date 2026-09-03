#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[starr-install] $*"; }

log "Updating OS and installing base dependencies..."
apt update
apt upgrade -y
apt install -y curl sqlite3 libicu-dev unzip ca-certificates gnupg python3 python3-venv python3-pip libssl-dev

# Detect arch for Servarr download URLs (same mapping as upstream install scripts)
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64) SERVARR_ARCH="x64" ;;
    arm64|aarch64) SERVARR_ARCH="arm64" ;;
    armhf|armv7l|armv6l|arm) SERVARR_ARCH="arm" ;;
    *) log "ERROR: unsupported arch $ARCH"; exit 1 ;;
esac
log "Detected arch: $ARCH -> Servarr arch: $SERVARR_ARCH"

# Symlink system SQLite when glibc is too old for the bundled one (borrowed from upstream)
ensure_sqlite_compat() {
    local target="$1"
    local glibc_version glibc_major glibc_minor
    glibc_version=$(ldd --version 2>/dev/null | awk '/ldd/{print $NF}' | head -1)
    glibc_major=$(echo "$glibc_version" | cut -d. -f1)
    glibc_minor=$(echo "$glibc_version" | cut -d. -f2)
    if [ -n "$glibc_major" ] && { [ "$glibc_major" -lt 2 ] || { [ "$glibc_major" -eq 2 ] && [ "${glibc_minor:-0}" -lt 38 ]; }; }; then
        log "  glibc $glibc_version < 2.38, linking system SQLite..."
        mv "$target/libe_sqlite3.so" "$target/libe_sqlite3.so.backup" 2>/dev/null || true
        local system_sqlite="/usr/lib/x86_64-linux-gnu/libsqlite3.so.0"
        case "$ARCH" in
            arm64|aarch64) system_sqlite="/usr/lib/aarch64-linux-gnu/libsqlite3.so.0" ;;
            armhf|armv7l|armv6l|arm) system_sqlite="/usr/lib/arm-linux-gnueabihf/libsqlite3.so.0" ;;
        esac
        if [ -f "$system_sqlite" ]; then
            ln -s "$system_sqlite" "$target/libe_sqlite3.so"
        else
            log "  WARNING: system SQLite not found at $system_sqlite"
        fi
    fi
}

# Fetch a Servarr app tarball from its official update server and deploy to /opt/<app>
# Usage: fetch_servarr <AppName> <download_url> <target> <data_dir>
fetch_servarr() {
    local app_name="$1"      # e.g. Prowlarr
    local dl_url="$2"        # e.g. https://prowlarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=x64
    local target="$3"        # e.g. /opt/Prowlarr
    local data_dir="$4"      # e.g. /var/lib/prowlarr

    log "Fetching $app_name..."
    log "  URL: $dl_url"

    local tmpdir=$(mktemp -d)
    local archive="$tmpdir/archive.tar.gz"
    curl -fsSL -o "$archive" "$dl_url"

    mkdir -p "$target"
    if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
        log "  Clearing $target (CLEAN_INSTALL)"
        find "$target" -mindepth 1 -delete 2>/dev/null || rm -rf "${target:?}/"* 2>/dev/null || true
    fi

    mkdir -p "$tmpdir/extract"
    tar --no-same-owner -xzf "$archive" -C "$tmpdir/extract" 2>/dev/null || tar --no-same-owner -xf "$archive" -C "$tmpdir/extract"
    local top=$(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | head -1)
    if [ -d "$top" ] && [ $(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]; then
        cp -r "$top"/* "$target/"
    else
        cp -r "$tmpdir/extract"/* "$target/"
    fi
    chmod 775 "$target"
    rm -rf "$tmpdir"

    ensure_sqlite_compat "$target"

    mkdir -p "$data_dir"
    chmod 775 "$data_dir" "$target"
    # Let the app self-update on first start in case the tarball is stale
    touch "$data_dir/update_required"
    log "  Deployed $app_name to $target"
}

# Fetch Bazarr zip from its latest GitHub release and deploy to /opt/bazarr
fetch_bazarr() {
    local target="$1"        # e.g. /opt/bazarr
    local data_dir="$2"      # e.g. /var/lib/bazarr
    local dl_url="https://github.com/morpheus65535/bazarr/releases/latest/download/bazarr.zip"

    log "Fetching bazarr..."
    log "  URL: $dl_url"

    local tmpdir=$(mktemp -d)
    local archive="$tmpdir/archive.zip"
    curl -fsSL -o "$archive" "$dl_url"

    mkdir -p "$target"
    if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
        log "  Clearing $target (CLEAN_INSTALL)"
        find "$target" -mindepth 1 -delete 2>/dev/null || rm -rf "${target:?}/"* 2>/dev/null || true
    fi

    mkdir -p "$tmpdir/extract"
    unzip -q "$archive" -d "$tmpdir/extract"
    if [ $(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ] && [ -d "$(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | head -1)" ]; then
        cp -r "$(find "$tmpdir/extract" -mindepth 1 -maxdepth 1 | head -1)"/* "$target/"
    else
        cp -r "$tmpdir/extract"/* "$target/"
    fi
    chmod 775 "$target"
    rm -rf "$tmpdir"

    mkdir -p "$data_dir"
    chmod 775 "$data_dir" "$target"
    log "  Deployed bazarr to $target"
}

# Prowlarr
if [ ! -f /etc/systemd/system/prowlarr.service ]; then
    fetch_servarr "Prowlarr" "https://prowlarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${SERVARR_ARCH}" "/opt/Prowlarr" "/var/lib/prowlarr"
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
    fetch_servarr "Sonarr" "https://services.sonarr.tv/v1/download/main/latest?version=4&os=linux&arch=${SERVARR_ARCH}" "/opt/Sonarr" "/var/lib/sonarr"
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
    fetch_servarr "Radarr" "https://radarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${SERVARR_ARCH}" "/opt/Radarr" "/var/lib/radarr"
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
    fetch_bazarr "/opt/bazarr" "/var/lib/bazarr"
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
