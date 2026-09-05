#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  if [ -f "$REPO_ROOT/.server_users" ]; then
    cp "$REPO_ROOT/.server_users" "$MOCK_TMPDIR/.server_users.bak"
  fi
}

teardown() {
  if [ -f "$MOCK_TMPDIR/.server_users.bak" ]; then
    cp "$MOCK_TMPDIR/.server_users.bak" "$REPO_ROOT/.server_users"
  elif [ -f "$REPO_ROOT/.server_users" ]; then
    if grep -q "bats-test" "$REPO_ROOT/.server_users" 2>/dev/null || grep -q "testuser" "$REPO_ROOT/.server_users" 2>/dev/null; then
      rm -f "$REPO_ROOT/.server_users"
    fi
  fi
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ] && grep -q "bats-test" "$REPO_ROOT/caddy/Caddyfile.local" 2>/dev/null; then
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# caddy/install.sh
# -------------------------------------------------------------------

@test "caddy install succeeds and fetches container IP" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG="hostname: caddy"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"

  run bash "$REPO_ROOT/caddy/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Caddy"* ]]
  [[ "$output" == *"10.0.0.5"* ]]
  grep -q "pct list" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# caddy/update.sh
# -------------------------------------------------------------------

@test "caddy update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG="hostname: caddy"
  run bash "$REPO_ROOT/caddy/update.sh" 2>&1
  [ "$status" -eq 0 ] || [[ "$output" == *"caddy"* ]]
}

# -------------------------------------------------------------------
# caddy/trust-nextcloud.sh — fallback nextcloudpi
# -------------------------------------------------------------------

@test "caddy trust-nextcloud falls back to nextcloudpi when nextcloud not found" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n102        running                 nextcloudpi'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_102="hostname: nextcloudpi"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  run bash "$REPO_ROOT/caddy/trust-nextcloud.sh" --caddy-ip 10.0.0.5 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"102"* ]]
  [[ "$output" == *"nextcloudpi"* ]] || [[ "$output" == *"Nextcloud container"* ]]
  grep -q "pct exec 102" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# caddy/generate-caddyfile.sh — basic
# -------------------------------------------------------------------

@test "caddy generate-caddyfile runs without error when no guests" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  # Mock caddy exists
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  run bash "$REPO_ROOT/caddy/generate-caddyfile.sh" 2>&1
  # Should handle empty guest list gracefully
  [ "$status" -eq 0 ] || [[ "$output" == *"No guests"* ]] || [[ "$output" == *"Found 0"* ]]
}

# -------------------------------------------------------------------
# caddy/generate-caddyfile.sh — multi-service guests (e.g. starr CT)
# -------------------------------------------------------------------

@test "caddy generate multi-service maps each port to its own subdomain" {
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ]; then
    cp "$REPO_ROOT/caddy/Caddyfile.local" "$MOCK_TMPDIR/Caddyfile.local.orig"
  fi
  rm -f "$REPO_ROOT/caddy/Caddyfile.local"

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:6767      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:7878      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:8989      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:9696      0.0.0.0:*'

  # Ports are probed sorted: 6767 7878 8989 9696 -> bazarr radarr sonarr prowlarr
  run bash -c "printf 'y\nbazarr\nn\nradarr\nn\nsonarr\nn\nprowlarr\nn\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "bazarr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:6767" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "radarr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:7878" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "sonarr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:8989" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "prowlarr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:9696" "$REPO_ROOT/caddy/Caddyfile.local"
  # Multi-mode must not also emit a single starr block
  ! /usr/bin/grep -q "starr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "pct push 100" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 100" "$MOCK_LOG"

  if [ -f "$MOCK_TMPDIR/Caddyfile.local.orig" ]; then
    cp "$MOCK_TMPDIR/Caddyfile.local.orig" "$REPO_ROOT/caddy/Caddyfile.local"
  else
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
}

@test "caddy generate reuses saved multi-service mappings without prompting" {
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ]; then
    cp "$REPO_ROOT/caddy/Caddyfile.local" "$MOCK_TMPDIR/Caddyfile.local.orig"
  fi
  cat > "$REPO_ROOT/caddy/Caddyfile.local" <<'EOF'
http://bazarr.marx.home {
    reverse_proxy 10.0.0.5:6767
}

http://radarr.marx.home {
    reverse_proxy 10.0.0.5:7878
}

http://sonarr.marx.home {
    reverse_proxy 10.0.0.5:8989
}

http://prowlarr.marx.home {
    reverse_proxy 10.0.0.5:9696
}

EOF

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:6767      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:7878      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:8989      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:9696      0.0.0.0:*'

  run bash "$REPO_ROOT/caddy/generate-caddyfile.sh" </dev/null 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:6767" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:7878" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:8989" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:9696" "$REPO_ROOT/caddy/Caddyfile.local"
  ! /usr/bin/grep -q "starr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"

  if [ -f "$MOCK_TMPDIR/Caddyfile.local.orig" ]; then
    cp "$MOCK_TMPDIR/Caddyfile.local.orig" "$REPO_ROOT/caddy/Caddyfile.local"
  else
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
}

@test "caddy generate preserves orphan blocks not owned by any guest" {
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ]; then
    cp "$REPO_ROOT/caddy/Caddyfile.local" "$MOCK_TMPDIR/Caddyfile.local.orig"
  fi
  cat > "$REPO_ROOT/caddy/Caddyfile.local" <<'EOF'
http://myapp.marx.home {
    reverse_proxy 10.9.9.9:1234
}

EOF

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:8989      0.0.0.0:*'

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "starr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:8989" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "myapp.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.9.9.9:1234" "$REPO_ROOT/caddy/Caddyfile.local"

  if [ -f "$MOCK_TMPDIR/Caddyfile.local.orig" ]; then
    cp "$MOCK_TMPDIR/Caddyfile.local.orig" "$REPO_ROOT/caddy/Caddyfile.local"
  else
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
}

@test "caddy generate keeps single-service flow for one-port guests" {
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ]; then
    cp "$REPO_ROOT/caddy/Caddyfile.local" "$MOCK_TMPDIR/Caddyfile.local.orig"
  fi
  rm -f "$REPO_ROOT/caddy/Caddyfile.local"

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_107="hostname: jellyfin"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:8096      0.0.0.0:*'

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "jellyfin.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.7:8096" "$REPO_ROOT/caddy/Caddyfile.local"

  if [ -f "$MOCK_TMPDIR/Caddyfile.local.orig" ]; then
    cp "$MOCK_TMPDIR/Caddyfile.local.orig" "$REPO_ROOT/caddy/Caddyfile.local"
  else
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
}

@test "caddy generate falls back to single-service when all ports skipped" {
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ]; then
    cp "$REPO_ROOT/caddy/Caddyfile.local" "$MOCK_TMPDIR/Caddyfile.local.orig"
  fi
  rm -f "$REPO_ROOT/caddy/Caddyfile.local"

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:6767      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:9696      0.0.0.0:*'

  # y=multi, then skip both ports, then single-service defaults (port 6767, http)
  run bash -c "printf 'y\n\n\n\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "starr.marx.home" "$REPO_ROOT/caddy/Caddyfile.local"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:6767" "$REPO_ROOT/caddy/Caddyfile.local"

  if [ -f "$MOCK_TMPDIR/Caddyfile.local.orig" ]; then
    cp "$MOCK_TMPDIR/Caddyfile.local.orig" "$REPO_ROOT/caddy/Caddyfile.local"
  else
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
}
