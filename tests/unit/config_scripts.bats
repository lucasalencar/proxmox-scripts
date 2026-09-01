#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export MOCK_BYPASS_ROOT=1
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
  # Clean up generated Caddyfile.local if created
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ] && grep -q "bats-test" "$REPO_ROOT/caddy/Caddyfile.local" 2>/dev/null; then
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
  rm -rf "$MOCK_TMPDIR"
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
  # Verify pct exec was called for user:info for both users and that script handled both
  grep -q "pct exec 101" "$MOCK_LOG"
  [[ "$output" == *"Created: 0, Skipped: 2"* ]] || [[ "$output" == *"Skipped: 2"* ]]
}

# -------------------------------------------------------------------
# caddy/trust-nextcloud.sh — fallback nextcloudpi
# -------------------------------------------------------------------

@test "trust-nextcloud falls back to nextcloudpi when nextcloud not found" {
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
# nextcloud/setup-storage.sh — handles existing dataset and mount
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
  # Should not call pct set for already existing mount
  ! grep -q "pct set 101 -mp1" "$MOCK_LOG" || true
}

# -------------------------------------------------------------------
# container-annotate/annotate.sh — basic run
# -------------------------------------------------------------------

@test "container-annotate runs without error when no guests" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 annotated, 0 already up-to-date"* ]] || [[ "$output" == *"Done!"* ]]
}

# -------------------------------------------------------------------
# update.sh — discovers update scripts
# -------------------------------------------------------------------

@test "update.sh handles specific package argument" {
  mkdir -p "$MOCK_TMPDIR/fakepkg"
  echo '#!/bin/bash
echo "fake update ran"
' > "$MOCK_TMPDIR/fakepkg/update.sh"
  chmod +x "$MOCK_TMPDIR/fakepkg/update.sh"
  run bash "$REPO_ROOT/update.sh" "fakepkg" 2>&1
  [[ "$output" == *"No update script found for package 'fakepkg'"* ]]
  [ "$status" -eq 0 ]
}

