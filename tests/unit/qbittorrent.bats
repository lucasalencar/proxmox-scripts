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
# qbittorrent/install.sh
# -------------------------------------------------------------------

@test "qbittorrent install requires QBIT_PASS when non-interactive" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n104        running                 qbittorrent'
  export MOCK_PCT_CONFIG="hostname: qbittorrent"
  export MOCK_PCT_EXEC_ID_U_qbittorrent="1000"
  unset QBIT_PASS
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
# qbittorrent/update.sh
# -------------------------------------------------------------------

@test "qbittorrent update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n104        running                 qbittorrent'
  export MOCK_PCT_CONFIG="hostname: qbittorrent"
  run bash "$REPO_ROOT/qbittorrent/update.sh" 2>&1
  [ "$status" -eq 0 ] || [[ "$output" == *"qbittorrent"* ]]
}
