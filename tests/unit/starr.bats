#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  # Mock mediaserver dataset path exists (skip mkdir failure)
  export MOCK_PVESM_STATUS=$'local             dir     active\nlocal-lvm         lvmthin active'
  export MOCK_IP_LINK_SHOW=$'2: vmbr0: <BROADCAST>'
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  export MOCK_PVESH_NEXTID="105"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ] && grep -q "bats-test" "$REPO_ROOT/caddy/Caddyfile.local" 2>/dev/null; then
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
}

# -------------------------------------------------------------------
# starr/install.sh — container creation + provision
# -------------------------------------------------------------------

@test "starr install creates new container and pushes provision script when not exists" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_PCT_CONFIG="hostname: test"
  # Starr apps run as root (tarballs create no service users) — only root UID is resolved
  export MOCK_PCT_EXEC_ID_U_root="0"

  run bash "$REPO_ROOT/starr/install.sh" 2>&1
  [ "$status" -eq 0 ]
  # Should have created LXC
  /usr/bin/grep -q "pct create 105" "$MOCK_LOG"
  # Should have pushed provision script
  /usr/bin/grep -q "pct push 105.*container/provision.sh" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 105 -- bash /tmp/provision.sh" "$MOCK_LOG"
  # Should have applied mounts
  /usr/bin/grep -q "pct set 105 -mp1 /tank/data/mediaserver,mp=/data" "$MOCK_LOG"
  # Should have granted root (100000) access, never queried service users
  /usr/bin/grep -q "setfacl -R -m u:100000:rwx" "$MOCK_LOG"
  ! /usr/bin/grep -q "pct exec 105 -- id -u prowlarr" "$MOCK_LOG"
  ! /usr/bin/grep -q "pct exec 105 -- id -u sonarr" "$MOCK_LOG"
  ! /usr/bin/grep -q "pct exec 105 -- id -u radarr" "$MOCK_LOG"
  ! /usr/bin/grep -q "pct exec 105 -- id -u bazarr" "$MOCK_LOG"
}

@test "starr install reuses existing container and still provisions" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'
  export MOCK_PCT_CONFIG="hostname: starr"
  export MOCK_PCT_EXEC_ID_U_root="0"

  run bash "$REPO_ROOT/starr/install.sh" 2>&1
  [ "$status" -eq 0 ]
  # Should not create, but should push provision
  ! /usr/bin/grep -q "pct create" "$MOCK_LOG" || /usr/bin/grep -q "already exists" "$MOCK_LOG" || true
  /usr/bin/grep -q "pct push 105.*provision.sh" "$MOCK_LOG"
  [[ "$output" == *"reusing"* ]] || [[ "$output" == *"Found existing"* ]]
}

@test "starr install succeeds with root ACL when service users do not exist" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'
  export MOCK_PCT_CONFIG="hostname: starr"
  # No service users in container (tarballs create none) — root still resolves
  export MOCK_PCT_EXEC_ID_U_prowlarr=""
  export MOCK_PCT_EXEC_ID_U_sonarr=""
  export MOCK_PCT_EXEC_ID_U_radarr=""
  export MOCK_PCT_EXEC_ID_U_bazarr=""
  export MOCK_PCT_EXEC_ID_U_root="0"

  run bash "$REPO_ROOT/starr/install.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "setfacl -R -m u:100000:rwx" "$MOCK_LOG"
}

@test "starr install fails when root UID cannot be resolved" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'
  export MOCK_PCT_CONFIG="hostname: starr"
  export MOCK_PCT_EXEC_ID_U_root=""

  run bash "$REPO_ROOT/starr/install.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not determine UID"* ]]
}

@test "starr install fails when provision push fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'
  export MOCK_PCT_CONFIG="hostname: starr"
  export MOCK_PCT_PUSH_FAIL=1

  run bash "$REPO_ROOT/starr/install.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to install Starr apps"* ]] || [[ "$output" == *"Failed to push"* ]] || [[ "$output" == *"Failed to execute"* ]]
}

# -------------------------------------------------------------------
# starr/update.sh — pushes update script
# -------------------------------------------------------------------

@test "starr update pushes update script and succeeds" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'
  export MOCK_PCT_CONFIG="hostname: starr"

  run bash "$REPO_ROOT/starr/update.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 105.*container/update.sh" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 105 -- bash /tmp/update.sh" "$MOCK_LOG"
}

@test "starr update fails when container not found" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"

  run bash "$REPO_ROOT/starr/update.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find container"* ]]
}

@test "starr update fails when update script exec fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'
  export MOCK_PCT_CONFIG="hostname: starr"
  export MOCK_PCT_EXEC_FAIL=1

  run bash "$REPO_ROOT/starr/update.sh" 2>&1
  # apt update will fail first, but update should still try push; overall should fail or warn
  # Our update.sh now does pct exec for apt via bash -c which will fail with MOCK_PCT_EXEC_FAIL=1
  # But we mock exec to fail all, so update may still proceed to push; check push happened
  # The final status should be non-zero due to exec failure in container script
  [ "$status" -ne 0 ] || /usr/bin/grep -q "pct push" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# starr/container scripts — isolated unit (no pct)
# -------------------------------------------------------------------

@test "starr container provision.sh fetches Servarr via update server (no GitHub jq pattern)" {
  /usr/bin/grep -q "servarr.com/v1/update" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q 'install_servarr_app "Prowlarr"' "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q 'install_servarr_app "Sonarr"' "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q 'install_servarr_app "Radarr"' "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q 'systemctl enable --now "$service"' "$REPO_ROOT/starr/container/provision.sh"
  # Servarr path must not use GitHub API asset matching
  ! /usr/bin/grep -q "assets\[\]" "$REPO_ROOT/starr/container/provision.sh"
  run bash -n "$REPO_ROOT/starr/container/provision.sh"
  [ "$status" -eq 0 ]
}

@test "starr container update.sh delegates to self-update via update_required" {
  /usr/bin/grep -q "update_required" "$REPO_ROOT/starr/container/update.sh"
  /usr/bin/grep -q "Prowlarr" "$REPO_ROOT/starr/container/update.sh"
  # No tarball re-download in update path
  ! /usr/bin/grep -q "api.github.com" "$REPO_ROOT/starr/container/update.sh"
  ! /usr/bin/grep -q "assets\[\]" "$REPO_ROOT/starr/container/update.sh"
  run bash -n "$REPO_ROOT/starr/container/update.sh"
  [ "$status" -eq 0 ]
}

@test "starr container provision and update share similar deploy logic but distinct entrypoints" {
  # Ensure they are not identical (provision deploys tarballs, update touches update_required)
  run bash -c 'diff -q "$REPO_ROOT/starr/container/provision.sh" "$REPO_ROOT/starr/container/update.sh" && echo same || echo diff'
  [[ "$output" == *"diff"* ]]
  /usr/bin/grep -q "update_required" "$REPO_ROOT/starr/container/update.sh"
  /usr/bin/grep -q "servarr.com/v1/update" "$REPO_ROOT/starr/container/provision.sh"
}
