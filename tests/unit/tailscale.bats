#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export PVE_LXC_CONF_DIR="$MOCK_TMPDIR/lxc"
  mkdir -p "$PVE_LXC_CONF_DIR"
  export MOCK_PVESM_STATUS=$'local             dir     active\nlocal-lvm         lvmthin active'
  export MOCK_IP_LINK_SHOW=$'2: vmbr0: <BROADCAST>'
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  export MOCK_PVESH_NEXTID="106"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.6"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# tailscale/install.sh — container creation + TUN passthrough + provision
# -------------------------------------------------------------------

@test "tailscale install creates new container, applies TUN passthrough and provisions" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_PCT_CONFIG="hostname: test"

  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -eq 0 ]
  # Should have created a minimal router LXC
  /usr/bin/grep -q "pct create 106" "$MOCK_LOG"
  /usr/bin/grep -q -- "--hostname tailscale-router" "$MOCK_LOG"
  # TUN passthrough must be written to the LXC config
  /usr/bin/grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$PVE_LXC_CONF_DIR/106.conf"
  /usr/bin/grep -q "lxc.mount.entry: /dev/net/tun" "$PVE_LXC_CONF_DIR/106.conf"
  # Container must be restarted so the TUN device appears
  /usr/bin/grep -q "pct stop 106" "$MOCK_LOG"
  /usr/bin/grep -q "pct start 106" "$MOCK_LOG"
  # Should have pushed and executed the provision script
  /usr/bin/grep -q "pct push 106.*container/provision.sh" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 106 -- bash /tmp/provision.sh" "$MOCK_LOG"
  # Must point at manual login, never print a token
  [[ "$output" == *"tailscale up"* ]]
  ! /usr/bin/grep -qi "token" "$MOCK_LOG"
}

@test "tailscale install reuses existing container and skips TUN when already present" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG=$'hostname: tailscale-router\nlxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'

  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -eq 0 ]
  ! /usr/bin/grep -q "pct create" "$MOCK_LOG"
  # No config file write when passthrough already present
  [ ! -f "$PVE_LXC_CONF_DIR/106.conf" ]
  /usr/bin/grep -q "pct push 106.*provision.sh" "$MOCK_LOG"
  [[ "$output" == *"reusing"* ]] || [[ "$output" == *"Found existing"* ]]
}

@test "tailscale install adds missing TUN passthrough to existing container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "lxc.cgroup2.devices.allow" "$PVE_LXC_CONF_DIR/106.conf"
  /usr/bin/grep -q "lxc.mount.entry: /dev/net/tun" "$PVE_LXC_CONF_DIR/106.conf"
  /usr/bin/grep -q "pct stop 106" "$MOCK_LOG"
  /usr/bin/grep -q "pct start 106" "$MOCK_LOG"
}

@test "tailscale install is idempotent for TUN entries" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -eq 0 ]
  # Entries come from the same mock, so conf must still hold exactly one copy of each line
  [ "$(/usr/bin/grep -c "lxc.cgroup2.devices.allow" "$PVE_LXC_CONF_DIR/106.conf")" -eq 1 ]
  [ "$(/usr/bin/grep -c "lxc.mount.entry: /dev/net/tun" "$PVE_LXC_CONF_DIR/106.conf")" -eq 1 ]
}

@test "tailscale install fails when container creation fails" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_PCT_CONFIG="hostname: test"
  export MOCK_PCT_FAIL=1

  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -ne 0 ]
}

@test "tailscale install fails when provision push fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG=$'hostname: tailscale-router\nlxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'
  export MOCK_PCT_PUSH_FAIL=1

  run bash "$REPO_ROOT/tailscale/install.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to provision Tailscale"* ]] || [[ "$output" == *"Failed to push"* ]] || [[ "$output" == *"Failed to execute"* ]]
}

# -------------------------------------------------------------------
# tailscale/update.sh — pushes upgrade script
# -------------------------------------------------------------------

@test "tailscale update pushes upgrade script and succeeds" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/update.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 106.*container/upgrade.sh" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 106 -- bash /tmp/upgrade.sh" "$MOCK_LOG"
}

@test "tailscale update fails when container not found" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"

  run bash "$REPO_ROOT/tailscale/update.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find container"* ]]
}

@test "tailscale update fails when upgrade push fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG="hostname: tailscale-router"
  export MOCK_PCT_PUSH_FAIL=1

  run bash "$REPO_ROOT/tailscale/update.sh" 2>&1
  [ "$status" -ne 0 ]
}

@test "tailscale update fails when upgrade exec fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n106        running                 tailscale-router'
  export MOCK_PCT_CONFIG="hostname: tailscale-router"
  export MOCK_PCT_EXEC_FAIL=1

  run bash "$REPO_ROOT/tailscale/update.sh" 2>&1
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# tailscale/container scripts — isolated unit (no pct)
# -------------------------------------------------------------------

@test "tailscale container provision.sh installs tailscale and enables forwarding" {
  /usr/bin/grep -q "tailscale" "$REPO_ROOT/tailscale/container/provision.sh"
  /usr/bin/grep -q "ip_forward" "$REPO_ROOT/tailscale/container/provision.sh"
  /usr/bin/grep -q "systemctl enable" "$REPO_ROOT/tailscale/container/provision.sh"
  # Signed apt repo, never pipe-to-shell
  /usr/bin/grep -q "noarmor.gpg" "$REPO_ROOT/tailscale/container/provision.sh"
  ! /usr/bin/grep -q "| sh" "$REPO_ROOT/tailscale/container/provision.sh"
  # Provision must not auto-login or embed credentials
  ! /usr/bin/grep -qi "authkey\|auth-key\|token" "$REPO_ROOT/tailscale/container/provision.sh"
  run bash -n "$REPO_ROOT/tailscale/container/provision.sh"
  [ "$status" -eq 0 ]
}

@test "tailscale container upgrade.sh refreshes package and checks service" {
  /usr/bin/grep -q "only-upgrade" "$REPO_ROOT/tailscale/container/upgrade.sh"
  /usr/bin/grep -q "is-active" "$REPO_ROOT/tailscale/container/upgrade.sh"
  /usr/bin/grep -q "ip_forward" "$REPO_ROOT/tailscale/container/upgrade.sh"
  # Upgrade must refresh, never reinstall from scratch
  ! /usr/bin/grep -q "| sh" "$REPO_ROOT/tailscale/container/upgrade.sh"
  run bash -n "$REPO_ROOT/tailscale/container/upgrade.sh"
  [ "$status" -eq 0 ]
}

@test "tailscale container provision and upgrade are distinct entrypoints" {
  run bash -c 'diff -q "$REPO_ROOT/tailscale/container/provision.sh" "$REPO_ROOT/tailscale/container/upgrade.sh" && echo same || echo diff'
  [[ "$output" == *"diff"* ]]
}

# -------------------------------------------------------------------
# tailscale/README.md — usage docs
# -------------------------------------------------------------------

@test "tailscale README documents install and update commands" {
  /usr/bin/grep -q "tailscale/install.sh" "$REPO_ROOT/tailscale/README.md"
  /usr/bin/grep -q "tailscale/update.sh" "$REPO_ROOT/tailscale/README.md"
}
