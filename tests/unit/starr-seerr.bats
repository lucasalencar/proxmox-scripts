#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export MOCK_PVESM_STATUS=$'local             dir     active\nlocal-lvm         lvmthin active'
  export MOCK_IP_LINK_SHOW=$'2: vmbr0: <BROADCAST>'
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  export MOCK_PVESH_NEXTID="105"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: starr"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# Seerr provision (same starr CT, port 5055)
# -------------------------------------------------------------------

@test "starr container provision.sh installs Seerr from seerr-team/seerr on Node 22" {
  /usr/bin/grep -q "seerr-team/seerr" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "/opt/seerr" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "5055" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "22" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "systemctl enable --now seerr" "$REPO_ROOT/starr/container/provision.sh"
  run bash -n "$REPO_ROOT/starr/container/provision.sh"
  [ "$status" -eq 0 ]
}

@test "starr container provision.sh installs Seerr idempotently" {
  /usr/bin/grep -q "seerr.service" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "Seerr already installed" "$REPO_ROOT/starr/container/provision.sh"
  run bash -n "$REPO_ROOT/starr/container/provision.sh"
  [ "$status" -eq 0 ]
}

@test "starr container update.sh refreshes Seerr" {
  /usr/bin/grep -q "/opt/seerr" "$REPO_ROOT/starr/container/update.sh"
  /usr/bin/grep -q "seerr" "$REPO_ROOT/starr/container/update.sh"
  /usr/bin/grep -q "already current" "$REPO_ROOT/starr/container/update.sh"
  /usr/bin/grep -q "systemctl restart seerr" "$REPO_ROOT/starr/container/update.sh"
  run bash -n "$REPO_ROOT/starr/container/update.sh"
  [ "$status" -eq 0 ]
}

@test "starr container provision.sh guards pnpm and rate-limits Seerr restarts" {
  /usr/bin/grep -q "pnpm could not be installed" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "RestartSec=5" "$REPO_ROOT/starr/container/provision.sh"
  /usr/bin/grep -q "SyslogIdentifier=seerr" "$REPO_ROOT/starr/container/provision.sh"
  run bash -n "$REPO_ROOT/starr/container/provision.sh"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------
# Host install/update advertise Seerr
# -------------------------------------------------------------------

@test "starr install.sh advertises Seerr on 5055" {
  /usr/bin/grep -q "5055" "$REPO_ROOT/starr/install.sh"
  /usr/bin/grep -qi "seerr" "$REPO_ROOT/starr/install.sh"
  run bash -n "$REPO_ROOT/starr/install.sh"
  [ "$status" -eq 0 ]
}

@test "starr update.sh reports Seerr access" {
  /usr/bin/grep -q "5055" "$REPO_ROOT/starr/update.sh"
  run bash -n "$REPO_ROOT/starr/update.sh"
  [ "$status" -eq 0 ]
}

@test "starr README documents Seerr port, Caddy entry and Sonarr/Radarr/Jellyfin links" {
  /usr/bin/grep -q "5055" "$REPO_ROOT/starr/README.md"
  /usr/bin/grep -qi "seerr" "$REPO_ROOT/starr/README.md"
  /usr/bin/grep -qi "jellyfin" "$REPO_ROOT/starr/README.md"
  /usr/bin/grep -qi "sonarr" "$REPO_ROOT/starr/README.md"
  /usr/bin/grep -qi "radarr" "$REPO_ROOT/starr/README.md"
}

# -------------------------------------------------------------------
# configure.sh host — Seerr flags, Jellyfin discovery, Seerr-only run
# -------------------------------------------------------------------

@test "starr configure documents Seerr opt-out and Jellyfin options" {
  run bash "$REPO_ROOT/starr/configure.sh" --help 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"--skip-seerr"* ]]
  [[ "$output" == *"--jellyfin-host"* ]]
  [[ "$output" == *"--jellyfin-port"* ]]
  [[ "$output" == *"--jellyfin-api-key"* ]]
}

@test "starr configure forwards --skip-seerr to in-container script" {
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"
  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --skip-seerr 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--skip-seerr" "$MOCK_LOG"
}

@test "starr configure discovers jellyfin IP and never logs its api key" {
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.99"
  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --jellyfin-api-key 'jelly-secret-1' 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "192.168.31.99" "$MOCK_LOG"
  /usr/bin/grep -q -- "--jellyfin-host" "$MOCK_LOG"
  /usr/bin/grep -q -- "--jellyfin-port 8096" "$MOCK_LOG"
  ! /usr/bin/grep -q "jelly-secret-1" "$MOCK_LOG"
  [[ "$output" != *"jelly-secret-1"* ]]
}

@test "starr configure accepts jellyfin key via env and respects host override" {
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.99"
  export JELLYFIN_API_KEY="env-jelly-secret"
  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --jellyfin-host 10.9.9.9 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "10.9.9.9" "$MOCK_LOG"
  ! /usr/bin/grep -q "env-jelly-secret" "$MOCK_LOG"
  [[ "$output" != *"env-jelly-secret"* ]]
  unset JELLYFIN_API_KEY
}

@test "starr configure runs Seerr-only without touching other services" {
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.99"
  export JELLYFIN_API_KEY="jelly-secret-2"
  run bash "$REPO_ROOT/starr/configure.sh" --skip-qbit --skip-auth --skip-bazarr --skip-flaresolverr 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--skip-qbit" "$MOCK_LOG"
  /usr/bin/grep -q -- "--skip-auth" "$MOCK_LOG"
  /usr/bin/grep -q -- "--skip-bazarr" "$MOCK_LOG"
  /usr/bin/grep -q -- "--skip-flaresolverr" "$MOCK_LOG"
  ! /usr/bin/grep -q -- "--skip-seerr" "$MOCK_LOG"
  ! /usr/bin/grep -q "jelly-secret-2" "$MOCK_LOG"
  [[ "$output" != *"jelly-secret-2"* ]]
  unset JELLYFIN_API_KEY
}
