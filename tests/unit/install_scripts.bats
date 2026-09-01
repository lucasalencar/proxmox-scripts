#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export MOCK_BYPASS_ROOT=1
  # Ensure clean state for .server_users — backup if exists
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
  # realpath mock will return the input path; it is not under /tank/data, so should fail
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
# qbittorrent/install.sh
# -------------------------------------------------------------------

@test "qbittorrent install requires QBIT_PASS when non-interactive" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n104        running                 qbittorrent'
  export MOCK_PCT_CONFIG="hostname: qbittorrent"
  export MOCK_PCT_EXEC_ID_U_qbittorrent="1000"
  # Ensure no tty and no QBIT_PASS
  unset QBIT_PASS
  # Run with stdin not a tty
  run bash "$REPO_ROOT/qbittorrent/install.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"QBIT_PASS"* ]]
}

@test "qbittorrent install succeeds with QBIT_PASS env var" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n104        running                 qbittorrent'
  export MOCK_PCT_CONFIG="hostname: qbittorrent"
  export MOCK_PCT_EXEC_ID_U_qbittorrent="1000"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  export QBIT_PASS="supersecret123"

  run bash "$REPO_ROOT/qbittorrent/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qBittorrent installed"* ]]
  grep -q "python3" "$MOCK_LOG"
  grep -q "setfacl" "$MOCK_LOG"
  grep -q "pct set 104 -mp1 /tank/data/mediaserver,mp=/data" "$MOCK_LOG"
}

@test "qbittorrent install creates download category folders via mkdir" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n104        running                 qbittorrent'
  export MOCK_PCT_CONFIG="hostname: qbittorrent"
  export MOCK_PCT_EXEC_ID_U_qbittorrent="1000"
  export QBIT_PASS="testpass"

  run bash "$REPO_ROOT/qbittorrent/install.sh"
  [ "$status" -eq 0 ]
  grep -q "mkdir" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# storage-setup/001-create-datasets.sh basic check via functions
# -------------------------------------------------------------------

@test "storage-setup uses setup_dataset_acls with correct UIDs" {
  # This test verifies the helper used by storage-setup, not the full script (which requires zfs mount)
  # We test via direct function call that storage-setup would make
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; setup_dataset_acls "tank/data/mediaserver" "/tank/data/mediaserver" "1000" "100000"'
  [ "$status" -eq 0 ]
  grep -q "zfs set acltype=posixacl tank/data/mediaserver" "$MOCK_LOG"
  grep -q "chown -R 1000:1000 /tank/data/mediaserver" "$MOCK_LOG"
}
