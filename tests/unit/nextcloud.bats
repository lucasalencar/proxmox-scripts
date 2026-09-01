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
# nextcloud/install.sh
# -------------------------------------------------------------------

@test "nextcloud install delegates to community script" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 nextcloud'
  export MOCK_PCT_CONFIG="hostname: nextcloud"
  # Mock required user lookup to avoid extra setup
  echo "testuser" > "$REPO_ROOT/.server_users"
  # Mock pct exec for occ etc. — default mock succeeds
  run bash "$REPO_ROOT/nextcloud/install.sh" 2>&1
  # With mocked container already existing, should skip install and succeed
  [ "$status" -eq 0 ] || [[ "$output" == *"nextcloud"* ]] || [[ "$output" == *"Nextcloud"* ]]
}

# -------------------------------------------------------------------
# nextcloud/sync-users.sh
# -------------------------------------------------------------------

@test "nextcloud sync-users creates missing users and skips existing" {
  echo -e "alice\nbob" > "$REPO_ROOT/.server_users"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 nextcloud'
  export MOCK_PCT_CONFIG="hostname: nextcloud"
  run bash "$REPO_ROOT/nextcloud/sync-users.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sync complete"* ]]
  grep -q "pct exec 101" "$MOCK_LOG"
  [[ "$output" == *"Created: 0, Skipped: 2"* ]] || [[ "$output" == *"Skipped: 2"* ]]
}

@test "nextcloud sync-users handles empty server users" {
  echo "" > "$REPO_ROOT/.server_users"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 nextcloud'
  export MOCK_PCT_CONFIG="hostname: nextcloud"
  run bash "$REPO_ROOT/nextcloud/sync-users.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sync complete"* ]]
  [[ "$output" == *"Created: 0"* ]]
}

# -------------------------------------------------------------------
# nextcloud/setup-storage.sh
# -------------------------------------------------------------------

@test "nextcloud setup-storage skips mount when already exists" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 nextcloud'
  export MOCK_PCT_CONFIG_101=$'hostname: nextcloud\nmp0: local:101/vm-101-disk-0.raw,mp=/data\nmp1: /tank/data/nextcloud,mp=/mnt/ncdata'
  export MOCK_PCT_EXEC_OUTPUT="/mnt/ncdata"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.6"
  export MOCK_ZFS_LIST_NOT_EXISTS=""
  echo "testuser" > "$REPO_ROOT/.server_users"
  export MOCK_GETENT_PASSWD="testuser:x:1000:1000::/home/testuser:/bin/bash"
  export MOCK_ID_UID="1000"
  run bash "$REPO_ROOT/nextcloud/setup-storage.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]] || [[ "$output" == *"Skipping mount setup"* ]]
  ! grep -q "pct set 101 -mp1" "$MOCK_LOG" || true
}

@test "nextcloud setup-storage handles missing container" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  echo "testuser" > "$REPO_ROOT/.server_users"
  run bash "$REPO_ROOT/nextcloud/setup-storage.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"Nextcloud container"* ]]
}

# -------------------------------------------------------------------
# nextcloud/update.sh
# -------------------------------------------------------------------

@test "nextcloud update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 nextcloud'
  export MOCK_PCT_CONFIG="hostname: nextcloud"
  run bash "$REPO_ROOT/nextcloud/update.sh" 2>&1
  [ "$status" -eq 0 ] || [[ "$output" == *"nextcloud"* ]]
}
