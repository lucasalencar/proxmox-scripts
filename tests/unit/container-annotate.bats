#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_STATUS="status: running"
  mkdir -p "$MOCK_TMPDIR/pve/lxc"
  export PVE_BASE="$MOCK_TMPDIR/pve"
  export CADDYFILE="$MOCK_TMPDIR/Caddyfile.test"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

write_lxc_conf() {
  local cid="$1"
  local hostname="$2"
  cat > "$MOCK_TMPDIR/pve/lxc/${cid}.conf" <<EOF
arch: amd64
cores: 2
hostname: $hostname
memory: 1024
EOF
}

# -------------------------------------------------------------------
# container-annotate/annotate.sh — single-service guests (regression)
# -------------------------------------------------------------------

@test "annotate links single-service guest to its subdomain and direct ip" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_107="hostname: jellyfin"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  cat > "$CADDYFILE" <<'EOF'
http://jellyfin.marx.home {
    reverse_proxy 10.0.0.7:8096
}
EOF
  write_lxc_conf "107" "jellyfin"

  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "proxmox-annotate" "$MOCK_TMPDIR/pve/lxc/107.conf"
  /usr/bin/grep -q "http://jellyfin.marx.home" "$MOCK_TMPDIR/pve/lxc/107.conf"
  /usr/bin/grep -q "http://10.0.0.7:8096" "$MOCK_TMPDIR/pve/lxc/107.conf"
}

# -------------------------------------------------------------------
# container-annotate/annotate.sh — multi-service guests (e.g. starr)
# -------------------------------------------------------------------

@test "annotate links multi-service guest once per service subdomain" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  cat > "$CADDYFILE" <<'EOF'
bazarr.marx.home {
    tls internal
    reverse_proxy 10.0.0.5:6767
}

radarr.marx.home {
    tls internal
    reverse_proxy 10.0.0.5:7878
}

sonarr.marx.home {
    tls internal
    reverse_proxy 10.0.0.5:8989
}

prowlarr.marx.home {
    tls internal
    reverse_proxy 10.0.0.5:9696
}
EOF
  write_lxc_conf "105" "starr"

  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "https://bazarr.marx.home" "$MOCK_TMPDIR/pve/lxc/105.conf"
  /usr/bin/grep -q "https://radarr.marx.home" "$MOCK_TMPDIR/pve/lxc/105.conf"
  /usr/bin/grep -q "https://sonarr.marx.home" "$MOCK_TMPDIR/pve/lxc/105.conf"
  /usr/bin/grep -q "https://prowlarr.marx.home" "$MOCK_TMPDIR/pve/lxc/105.conf"
  /usr/bin/grep -q "http://10.0.0.5:6767" "$MOCK_TMPDIR/pve/lxc/105.conf"
  /usr/bin/grep -q "http://10.0.0.5:9696" "$MOCK_TMPDIR/pve/lxc/105.conf"
  # No single starr block exists — annotation must not invent one
  ! /usr/bin/grep -q "starr.marx.home" "$MOCK_TMPDIR/pve/lxc/105.conf"
}

@test "annotate falls back to plain ip link when guest has no caddy block" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_107="hostname: jellyfin"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  rm -f "$CADDYFILE"
  write_lxc_conf "107" "jellyfin"

  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "http://10.0.0.7" "$MOCK_TMPDIR/pve/lxc/107.conf"
  ! /usr/bin/grep -q "marx.home" "$MOCK_TMPDIR/pve/lxc/107.conf"
}

@test "annotate skips guests that are already annotated" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_107="hostname: jellyfin"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  cat > "$CADDYFILE" <<'EOF'
http://jellyfin.marx.home {
    reverse_proxy 10.0.0.7:8096
}
EOF
  write_lxc_conf "107" "jellyfin"

  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  before=$(md5sum "$MOCK_TMPDIR/pve/lxc/107.conf" | awk '{print $1}')
  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"already annotated"* ]]
  after=$(md5sum "$MOCK_TMPDIR/pve/lxc/107.conf" | awk '{print $1}')
  [ "$before" = "$after" ]
}
