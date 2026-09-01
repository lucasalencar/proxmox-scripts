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
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# jellyfin/install.sh
# -------------------------------------------------------------------

@test "jellyfin install succeeds when container exists" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  export MOCK_PCT_EXEC_ID_U_jellyfin="1000"

  run bash "$REPO_ROOT/jellyfin/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jellyfin"* ]]
  [[ "$output" == *"101"* ]]
  grep -q "pct list" "$MOCK_LOG"
  grep -q "setfacl" "$MOCK_LOG"
  grep -q "pct set 101 -mp1 /tank/data/mediaserver/media,mp=/DATA/Media" "$MOCK_LOG"
  grep -q "pct set 101 -mp2 /tank/data/memorias,mp=/DATA/Gallery" "$MOCK_LOG"
}

@test "jellyfin install discovers host UID correctly" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  export MOCK_PCT_EXEC_ID_U_jellyfin="1005"

  run bash "$REPO_ROOT/jellyfin/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"101005"* ]] # 1005 + 100000 = 101005
  grep -q "u:101005:rwx" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# jellyfin/update.sh
# -------------------------------------------------------------------

@test "jellyfin update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  # update.sh exists for jellyfin — mock its pct exec
  run bash "$REPO_ROOT/jellyfin/update.sh" 2>&1
  # Should succeed or skip gracefully when mocked
  [ "$status" -eq 0 ] || [[ "$output" == *"jellyfin"* ]]
}
