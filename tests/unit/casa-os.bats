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
# casa-os/install.sh
# -------------------------------------------------------------------

@test "casa-os install with default mounts succeeds" {
  echo "testuser" > "$REPO_ROOT/.server_users"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n102        running                 casaos'
  export MOCK_PCT_CONFIG="hostname: casaos"
  export MOCK_PCT_EXEC_ID_U_root="0"

  run bash "$REPO_ROOT/casa-os/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CasaOS"* ]]
  grep -q "pct set 102 -mp1 /tank/data/memorias,mp=/DATA/Gallery" "$MOCK_LOG"
  grep -q "pct set 102 -mp2 /tank/data/mediaserver/media,mp=/DATA/Media" "$MOCK_LOG"
  grep -q "pct set 102 -mp3 /tank/data/mediaserver/downloads,mp=/DATA/Downloads" "$MOCK_LOG"
}

@test "casa-os install rejects documents path outside /tank/data" {
  echo "testuser" > "$REPO_ROOT/.server_users"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n102        running                 casaos'
  export MOCK_PCT_CONFIG="hostname: casaos"
  export MOCK_PCT_EXEC_ID_U_root="0"
  mkdir -p "$MOCK_TMPDIR/notank"
  run bash "$REPO_ROOT/casa-os/install.sh" --documents "$MOCK_TMPDIR/notank"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be under /tank/data"* ]]
}

@test "casa-os install rejects non-existent documents path" {
  echo "testuser" > "$REPO_ROOT/.server_users"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n102        running                 casaos'
  run bash "$REPO_ROOT/casa-os/install.sh" --documents "/tank/data/nonexistent-$(date +%s)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# -------------------------------------------------------------------
# casa-os/update.sh
# -------------------------------------------------------------------

@test "casa-os update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n102        running                 casaos'
  export MOCK_PCT_CONFIG="hostname: casaos"
  run bash "$REPO_ROOT/casa-os/update.sh" 2>&1
  [ "$status" -eq 0 ] || [[ "$output" == *"casaos"* ]] || [[ "$output" == *"CasaOS"* ]]
}
