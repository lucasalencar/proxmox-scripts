#!/usr/bin/env bats

# Unit tests for PVE LXC provisioning helpers (common/functions.sh)
# Uses mock bin in tests/helpers/mocks — no real Proxmox host touched.

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# get_pve_template_storage
# -------------------------------------------------------------------

@test "get_pve_template_storage returns local" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_template_storage'
  [ "$status" -eq 0 ]
  [ "$output" = "local" ]
}

# -------------------------------------------------------------------
# get_pve_rootfs_storage
# -------------------------------------------------------------------

@test "get_pve_rootfs_storage returns local-lvm when present" {
  export MOCK_PVESM_STATUS=$'local             dir     active\nlocal-lvm         lvmthin active'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_rootfs_storage'
  [ "$status" -eq 0 ]
  [ "$output" = "local-lvm" ]
  /usr/bin/grep -q "pvesm status" "$MOCK_LOG"
}

@test "get_pve_rootfs_storage returns local when local-lvm absent" {
  export MOCK_PVESM_STATUS=$'local             dir     active'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_rootfs_storage'
  [ "$status" -eq 0 ]
  [ "$output" = "local" ]
}

@test "get_pve_rootfs_storage returns local on pvesm failure" {
  export MOCK_PVESM_STATUS=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_rootfs_storage'
  [ "$status" -eq 0 ]
  [ "$output" = "local" ]
}

# -------------------------------------------------------------------
# detect_pve_bridge
# -------------------------------------------------------------------

@test "detect_pve_bridge returns detected vmbr" {
  export MOCK_IP_LINK_SHOW=$'1: lo: <LOOPBACK>\n2: vmbr0: <BROADCAST>\n3: vmbr1: <BROADCAST>'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; detect_pve_bridge'
  [ "$status" -eq 0 ]
  [ "$output" = "vmbr0" ]
  /usr/bin/grep -q "ip -o link show" "$MOCK_LOG"
}

@test "detect_pve_bridge picks first vmbr when multiple" {
  export MOCK_IP_LINK_SHOW=$'2: vmbr1: <BROADCAST>\n3: vmbr2: <BROADCAST>'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; detect_pve_bridge'
  [ "$status" -eq 0 ]
  [ "$output" = "vmbr1" ]
}

@test "detect_pve_bridge falls back to vmbr0 when no vmbr found" {
  export MOCK_IP_LINK_SHOW=$'1: lo: <LOOPBACK>\n2: eth0: <BROADCAST>'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; detect_pve_bridge'
  [ "$status" -eq 0 ]
  [ "$output" = "vmbr0" ]
}

@test "detect_pve_bridge falls back on ip failure" {
  export MOCK_IP_LINK_SHOW=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; detect_pve_bridge'
  [ "$status" -eq 0 ]
  [ "$output" = "vmbr0" ]
}

# -------------------------------------------------------------------
# get_pve_next_id
# -------------------------------------------------------------------

@test "get_pve_next_id returns id from pvesh" {
  export MOCK_PVESH_NEXTID="105"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_next_id'
  [ "$status" -eq 0 ]
  [ "$output" = "105" ]
  /usr/bin/grep -q "pvesh get /cluster/nextid" "$MOCK_LOG"
}

@test "get_pve_next_id fails when pvesh returns empty" {
  export MOCK_PVESH_NEXTID=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_next_id'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to get next CTID"* ]]
}

@test "get_pve_next_id fails when pvesh exits non-zero" {
  export MOCK_PVESH_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; get_pve_next_id'
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# ensure_debian_template
# -------------------------------------------------------------------

@test "ensure_debian_template finds template via system section and skips download when present" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"; echo "STDOUT:$output"'
  # Actually test via direct capture: template should be printed to stdout, logs to stderr
  # Re-run with proper capture
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"); echo "$tmpl"'
  [ "$status" -eq 0 ]
  [ "$output" = "debian-13-standard_13.0-1_amd64.tar.zst" ]
  /usr/bin/grep -q "Template: debian-13-standard" "$MOCK_TMPDIR/stderr.log"
  /usr/bin/grep -q "already present" "$MOCK_TMPDIR/stderr.log"
  # Should not have called download
  ! /usr/bin/grep -q "pveam download" "$MOCK_LOG"
}

@test "ensure_debian_template downloads when not present" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"); echo "$tmpl"'
  [ "$status" -eq 0 ]
  [ "$output" = "debian-13-standard_13.0-1_amd64.tar.zst" ]
  /usr/bin/grep -q "Downloading template" "$MOCK_TMPDIR/stderr.log"
  /usr/bin/grep -q "pveam download local debian-13-standard" "$MOCK_LOG"
}

@test "ensure_debian_template falls back to generic debian search" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=""
  export MOCK_PVEAM_AVAILABLE=$'system debian-13_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13_13.0-1_amd64.tar.zst"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"); echo "$tmpl"'
  [ "$status" -eq 0 ]
  [ "$output" = "debian-13_13.0-1_amd64.tar.zst" ]
}

@test "ensure_debian_template fails when no template found" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=""
  export MOCK_PVEAM_AVAILABLE=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"'
  [ "$status" -ne 0 ]
  /usr/bin/grep -q "Could not find Debian 13 template" "$MOCK_TMPDIR/stderr.log"
}

@test "ensure_debian_template fails when download fails" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST=""
  export MOCK_PVEAM_DOWNLOAD_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"'
  [ "$status" -ne 0 ]
  /usr/bin/grep -q "Failed to download template" "$MOCK_TMPDIR/stderr.log"
}

@test "ensure_debian_template stdout is clean (logs to stderr)" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 13 local 2>"$MOCK_TMPDIR/stderr.log"); echo "TEMPLATE:$tmpl"; cat "$MOCK_TMPDIR/stderr.log" | /usr/bin/grep -q "Template:" && echo "LOGGED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEMPLATE:debian-13-standard"* ]]
  [[ "$output" == *"LOGGED"* ]]
  # Ensure stdout capture does not contain log prefix
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 13 local 2>/dev/null); echo "$tmpl"'
  [[ "$output" != *"Template:"* ]]
  [[ "$output" == "debian-13-standard_13.0-1_amd64.tar.zst" ]]
}

@test "ensure_debian_template uses default storage and version" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  # Call without args => should default to 13 and local
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 2>"$MOCK_TMPDIR/stderr.log"); echo "$tmpl"'
  [ "$status" -eq 0 ]
  [ "$output" = "debian-13-standard_13.0-1_amd64.tar.zst" ]
}

@test "ensure_debian_template handles version param" {
  export MOCK_PVEAM_AVAILABLE_SYSTEM=""
  export MOCK_PVEAM_AVAILABLE=$'system debian-12-standard_12.7-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; tmpl=$(ensure_debian_template 12 local 2>"$MOCK_TMPDIR/stderr.log"); echo "$tmpl"'
  [ "$status" -eq 0 ]
  [ "$output" = "debian-12-standard_12.7-1_amd64.tar.zst" ]
}

# -------------------------------------------------------------------
# create_lxc_container
# -------------------------------------------------------------------

@test "create_lxc_container succeeds with required args and defaults" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local debian-13-standard_13.0-1_amd64.tar.zst local-lvm vmbr0'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct create 105 local:vztmpl/debian-13-standard" "$MOCK_LOG"
  /usr/bin/grep -q -- "--hostname starr" "$MOCK_LOG"
  /usr/bin/grep -q -- "--cores 2" "$MOCK_LOG"
  /usr/bin/grep -q -- "--memory 2048" "$MOCK_LOG"
  /usr/bin/grep -q -- "--rootfs local-lvm:20" "$MOCK_LOG"
  /usr/bin/grep -q -- "--swap 512" "$MOCK_LOG"
  /usr/bin/grep -q "pct start 105" "$MOCK_LOG"
}

@test "create_lxc_container succeeds with custom resources and tags" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local debian-13-standard_13.0-1_amd64.tar.zst local-lvm vmbr0 4 4096 20 512 "starr,arr,media" "Starr CT"'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--cores 4" "$MOCK_LOG"
  /usr/bin/grep -q -- "--memory 4096" "$MOCK_LOG"
  /usr/bin/grep -q -- "--rootfs local-lvm:20" "$MOCK_LOG"
  /usr/bin/grep -q -- "--tags starr,arr,media" "$MOCK_LOG"
  /usr/bin/grep -q -- "--description Starr CT" "$MOCK_LOG"
  /usr/bin/grep -q 'bridge=vmbr0' "$MOCK_LOG"
}

@test "create_lxc_container uses custom disk and swap" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 200 test local tmpl.tar.zst local vmbr0 2 1024 50 1024'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--rootfs local:50" "$MOCK_LOG"
  /usr/bin/grep -q -- "--swap 1024" "$MOCK_LOG"
}

@test "create_lxc_container fails when missing required args" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container "" starr local tmpl.tar.zst local vmbr0'
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required argument"* ]]

  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 "" local tmpl.tar.zst local vmbr0'
  [ "$status" -ne 0 ]

  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr "" tmpl.tar.zst local vmbr0'
  [ "$status" -ne 0 ]

  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local "" local vmbr0'
  [ "$status" -ne 0 ]

  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local tmpl.tar.zst "" vmbr0'
  [ "$status" -ne 0 ]

  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local tmpl.tar.zst local ""'
  [ "$status" -ne 0 ]
}

@test "create_lxc_container fails when pct create fails" {
  export MOCK_PCT_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local tmpl.tar.zst local vmbr0'
  [ "$status" -ne 0 ]
  [[ "$output" == *"pct create failed"* ]]
}

@test "create_lxc_container fails when wait_container_ready times out" {
  export MOCK_PCT_EXEC_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local tmpl.tar.zst local vmbr0'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ready"* ]] || [[ "$output" == *"not responsive"* ]]
}

@test "create_lxc_container creates unprivileged with nesting and correct net0" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local tmpl.tar.zst local vmbr0'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--unprivileged 1" "$MOCK_LOG"
  /usr/bin/grep -q -- "--features nesting=1,keyctl=1" "$MOCK_LOG"
  /usr/bin/grep -q -- 'name=eth0,bridge=vmbr0,ip=dhcp,firewall=1' "$MOCK_LOG"
  /usr/bin/grep -q -- "--ostype debian" "$MOCK_LOG"
  /usr/bin/grep -q -- "--onboot 1" "$MOCK_LOG"
}

@test "create_lxc_container omits tags and description when empty" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; create_lxc_container 105 starr local tmpl.tar.zst local vmbr0 2 2048 20 512 "" ""'
  [ "$status" -eq 0 ]
  ! /usr/bin/grep -q -- "--tags" "$MOCK_LOG"
  ! /usr/bin/grep -q -- "--description" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# exec_script_in_container
# -------------------------------------------------------------------

@test "exec_script_in_container pushes and executes script" {
  tmp_script=$(mktemp)
  echo '#!/bin/bash
echo hello' > "$tmp_script"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; exec_script_in_container 101 "'$tmp_script'"'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 101 $tmp_script" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 101 -- bash /tmp/$(basename $tmp_script)" "$MOCK_LOG"
  rm -f "$tmp_script"
}

@test "exec_script_in_container passes args to remote script" {
  tmp_script=$(mktemp)
  echo '#!/bin/bash' > "$tmp_script"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; exec_script_in_container 101 "'$tmp_script'" arg1 arg2'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct exec 101 -- bash /tmp/$(basename $tmp_script) arg1 arg2" "$MOCK_LOG"
  rm -f "$tmp_script"
}

@test "exec_script_in_container fails when missing container_id" {
  tmp_script=$(mktemp)
  echo '#!/bin/bash' > "$tmp_script"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; exec_script_in_container "" "'$tmp_script'"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing container_id"* ]]
  rm -f "$tmp_script"
}

@test "exec_script_in_container fails when host script not found" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; exec_script_in_container 101 /nonexistent/script.sh'
  [ "$status" -ne 0 ]
  [[ "$output" == *"host script not found"* ]]
}

@test "exec_script_in_container fails when pct push fails" {
  tmp_script=$(mktemp)
  echo '#!/bin/bash' > "$tmp_script"
  export MOCK_PCT_PUSH_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; exec_script_in_container 101 "'$tmp_script'"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to push"* ]]
  rm -f "$tmp_script"
}

@test "exec_script_in_container fails when pct exec fails" {
  tmp_script=$(mktemp)
  echo '#!/bin/bash' > "$tmp_script"
  export MOCK_PCT_EXEC_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; exec_script_in_container 101 "'$tmp_script'"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to execute"* ]]
  rm -f "$tmp_script"
}
