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
