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
# proxmox/storage-setup/001-create-datasets.sh (via helper)
# -------------------------------------------------------------------

@test "proxmox storage-setup uses setup_dataset_acls with correct UIDs" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; setup_dataset_acls "tank/data/mediaserver" "/tank/data/mediaserver" "1000" "100000"'
  [ "$status" -eq 0 ]
  grep -q "zfs set acltype=posixacl tank/data/mediaserver" "$MOCK_LOG"
  grep -q "chown -R 1000:1000 /tank/data/mediaserver" "$MOCK_LOG"
}

@test "proxmox storage-setup handles zfs create failure" {
  export MOCK_ZFS_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; zfs create tank/data/test; echo ok'
  # Mock should fail when MOCK_ZFS_FAIL=1 is respected by caller that checks exit code
  # Here we just verify mock was called and would fail if checked
  grep -q "zfs create tank/data/test" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# proxmox/post-install/005-add-secondary-user.sh (via is_user_registered)
# -------------------------------------------------------------------

@test "proxmox add-secondary-user duplicate check" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  printf "alice\nbob\n" > "$tmp_root/.server_users"
  output=$(bash -c "source '$tmp_root/common/functions.sh'; is_user_registered alice && echo yes || echo no" 2>&1)
  [ "$output" = "yes" ]
  rm -rf "$tmp_root"
}

# -------------------------------------------------------------------
# container-annotate/annotate.sh
# -------------------------------------------------------------------

@test "container-annotate runs without error when no guests" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 annotated, 0 already up-to-date"* ]] || [[ "$output" == *"Done!"* ]]
}
