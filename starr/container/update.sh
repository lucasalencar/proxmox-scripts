#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[starr-update] $*"; }

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64) SERVARR_ARCH="x64" ;;
    arm64|aarch64) SERVARR_ARCH="arm64" ;;
    *) SERVARR_ARCH="x64" ;;
esac

update_app() {
    local app_name="$1"
    local repo="$2"
    local target="$3"
    local pattern="$4"
    local service="$5"
    local data_dir="$6"

    if [ ! -d "$target" ] && [ ! -d "$data_dir" ]; then
        log "$app_name not installed — skipping"
        return 0
    fi

    local app_lc=$(echo "$app_name" | tr "[:upper:]" "[:lower:]")
    local version_file="$HOME/.${app_lc}"
    local current=""
    [ -f "$version_file" ] && current=$(cat "$version_file")

    log "Checking $app_name (current: ${current:-unknown})..."
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url")
    local tag=$(echo "$json" | jq -r ".tag_name // empty")
    if [ -z "$tag" ]; then
        log "  Failed to fetch tag for $repo"
        return 0
    fi
    if [ "$current" = "$tag" ]; then
        log "  $app_name already up-to-date ($tag)"
        return 0
    fi

    log "  Updating $app_name $current -> $tag"
    systemctl stop "$service" 2>/dev/null || true

    local asset_url=$(echo "$json" | jq -r --arg pat "$pattern" '.assets[] | select(.name | test($pat)) | .browser_download_url' | head -1)
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        log "  No asset for pattern $pattern — trying first asset"
        asset_url=$(echo "$json" | jq -r ".assets[].browser_download_url" | head -1)
    fi
    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        log "  ERROR: no asset found"
        systemctl start "$service" 2>/dev/null || true
        return 1
    fi

    local tmpdir=$(mktemp -d)
    local archive="$tmpdir/archive"
    curl -fsSL -o "$archive" "$asset_url"

    # CLEAN_INSTALL
    if [ -d "$target" ]; then
        find "$target" -mindepth 1 -delete 2>/dev/null || rm -rf "${target:?}/"* 2>/dev/null || true
    fi
    mkdir -p "$target"
    mkdir -p "$tmpdir/extract"
    local filename=$(basename "$asset_url")
    if [[ "$filename" == *.zip ]]; then
        unzip -q "$archive" -d "$tmpdir/extract"
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
    [ -n "$data_dir" ] && mkdir -p "$data_dir" && chmod 775 "$data_dir" "$target"
    echo "$tag" > "$version_file"
    rm -rf "$tmpdir"

    # Bazarr venv refresh
    if [ "$service" = "bazarr" ]; then
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
    fi

    systemctl start "$service"
    log "  $app_name updated to $tag and restarted"
}

update_app "Prowlarr" "Prowlarr/Prowlarr" "/opt/Prowlarr" "Prowlarr.master.*linux-core-${SERVARR_ARCH}.tar.gz" "prowlarr" "/var/lib/prowlarr"
update_app "Sonarr" "Sonarr/Sonarr" "/opt/Sonarr" "Sonarr.main.*.linux-${SERVARR_ARCH}.tar.gz" "sonarr" "/var/lib/sonarr"
update_app "Radarr" "Radarr/Radarr" "/opt/Radarr" "Radarr.master.*linux-core-${SERVARR_ARCH}.tar.gz" "radarr" "/var/lib/radarr"
update_app "bazarr" "morpheus65535/bazarr" "/opt/bazarr" "bazarr.zip" "bazarr" "/var/lib/bazarr"

log "Update check complete. Service status:"
systemctl is-active --quiet prowlarr && log "  prowlarr: active" || log "  prowlarr: inactive"
systemctl is-active --quiet sonarr && log "  sonarr: active" || log "  sonarr: inactive"
systemctl is-active --quiet radarr && log "  radarr: active" || log "  radarr: inactive"
systemctl is-active --quiet bazarr && log "  bazarr: active" || log "  bazarr: inactive"
