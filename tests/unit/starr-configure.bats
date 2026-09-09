#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  # Real interpreter: mock python3 swallows exit codes (|| echo mock_hash),
  # so compile/self-test/JSON checks must bypass $PATH mocks.
  export REAL_PYTHON3="/usr/bin/python3"
  unset MOCK_PYTHON_OUTPUT
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# starr/configure.sh — host orchestrator
# -------------------------------------------------------------------

@test "starr configure fails when starr container not found" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass secret 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find container 'starr'"* ]]
}

@test "starr configure fails without qbit password" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  unset QBIT_PASS

  run bash "$REPO_ROOT/starr/configure.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing qBittorrent password"* ]]
}

@test "starr configure accepts password via QBIT_PASS env" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"
  export QBIT_PASS="env-secret"

  run bash "$REPO_ROOT/starr/configure.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 105.*container/configure.py" "$MOCK_LOG"
  /usr/bin/grep -q -- "--qbit-pass-stdin" "$MOCK_LOG"
  # Secrets must never appear in logs or stdout, on either credential path
  ! /usr/bin/grep -q "env-secret" "$MOCK_LOG"
  [[ "$output" != *"env-secret"* ]]
}

@test "starr configure pushes configure.py and runs it with discovered qbit host" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --qbit-user admin 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 105.*container/configure.py" "$MOCK_LOG"
  /usr/bin/grep -q "python3 /root/starr-configure.py" "$MOCK_LOG"
  /usr/bin/grep -q -- "--qbit-pass-stdin" "$MOCK_LOG"
  /usr/bin/grep -q -- "--qbit-user admin" "$MOCK_LOG"
  /usr/bin/grep -q -- "--qbit-port 8090" "$MOCK_LOG"
  /usr/bin/grep -q "192.168.31.86" "$MOCK_LOG"
  # Secrets must never appear on stdout
  [[ "$output" != *"s3cret"* ]]
}

@test "starr configure fails fast on option without value" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "starr configure fails on unknown option and invalid port" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'

  run bash "$REPO_ROOT/starr/configure.sh" --bogus --qbit-pass secret 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass secret --qbit-port abc 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"between 1 and 65535"* ]]

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass secret --qbit-port 0 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"between 1 and 65535"* ]]
}

@test "starr configure fails when qbittorrent container not found" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr'

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass secret 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find container 'qbittorrent'"* ]]
}

@test "starr configure forwards skip-bazarr and dry-run to in-container script" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --skip-bazarr --dry-run 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "python3 /root/starr-configure.py.*--skip-bazarr" "$MOCK_LOG"
  /usr/bin/grep -q "python3 /root/starr-configure.py.*--dry-run" "$MOCK_LOG"
  /usr/bin/grep -q -- "--qbit-pass-stdin" "$MOCK_LOG"
  ! /usr/bin/grep -q "s3cret" "$MOCK_LOG"
  [[ "$output" != *"s3cret"* ]]
}

@test "starr configure respects --qbit-host override" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --qbit-host 10.9.9.9 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "10.9.9.9" "$MOCK_LOG"
}

@test "starr configure selects exact container names" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 starr-backup\n107        running                 qbittorrent\n108        running                 qbittorrent-test'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 105.*configure.py" "$MOCK_LOG"
  ! /usr/bin/grep -q "pct push 106.*configure.py" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 107.*hostname -I" "$MOCK_LOG"
  ! /usr/bin/grep -q "pct exec 108.*hostname -I" "$MOCK_LOG"
}

@test "starr configure fails when push fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"
  export MOCK_PCT_PUSH_FAIL=1

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret 2>&1
  [ "$status" -ne 0 ]
}

@test "starr configure forwards per-app auth and skips when requested" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret \
    --sonarr-user svc-sonarr --sonarr-pass 'SonarrPw1!' \
    --radarr-user svc-radarr --radarr-pass 'RadarrPw1!' \
    --prowlarr-user svc-prowlarr --prowlarr-pass 'ProwlarrPw1!' \
    --bazarr-user svc-bazarr --bazarr-pass 'BazarrPw1!' 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--auth-file" "$MOCK_LOG"
  /usr/bin/grep -q -- "--auth-method forms" "$MOCK_LOG"
  # Auth secrets travel via pushed file, never in argv/logs or qbit stdout
  ! /usr/bin/grep -q "SonarrPw1!" "$MOCK_LOG"
  ! /usr/bin/grep -q "RadarrPw1!" "$MOCK_LOG"
  [[ "$output" != *"s3cret"* ]]

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --skip-auth 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "--skip-auth" "$MOCK_LOG"
}

@test "starr configure generates missing auth passwords and logs them for the password manager" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"
  unset STARR_SONARR_PASS STARR_RADARR_PASS STARR_PROWLARR_PASS STARR_BAZARR_PASS

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret 2>&1
  [ "$status" -eq 0 ]
  # Generated password is logged so the operator can save it in a password manager
  [[ "$output" == *"mockBase64Pass123"* ]]
  # ...but never leaks into the pct mock log (argv)
  ! /usr/bin/grep -q "mockBase64Pass123" "$MOCK_LOG"
  [[ "$output" != *"s3cret"* ]]
}

@test "starr configure accepts auth via env and rejects bad auth method" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n105        running                 starr\n106        running                 qbittorrent'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.86"
  export STARR_SONARR_PASS="env-sonarr-secret"

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret 2>&1
  [ "$status" -eq 0 ]
  ! /usr/bin/grep -q "env-sonarr-secret" "$MOCK_LOG"
  unset STARR_SONARR_PASS

  run bash "$REPO_ROOT/starr/configure.sh" --qbit-pass s3cret --auth-method digest 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"auth-method"* ]]
}

# -------------------------------------------------------------------
# starr/container/test_configure.py — python unit tests (unittest)
# -------------------------------------------------------------------

@test "starr container configure.py compiles and unit tests pass" {
  run "$REAL_PYTHON3" -m py_compile "$REPO_ROOT/starr/container/configure.py"
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" -m py_compile "$REPO_ROOT/starr/container/test_configure.py"
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" "$REPO_ROOT/starr/container/test_configure.py"
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------
# tests/fixtures/starr — research snapshots stay valid JSON
# -------------------------------------------------------------------

@test "starr fixtures are valid JSON matching research shapes" {
  run "$REAL_PYTHON3" -c "import json,glob; [json.load(open(f)) for f in glob.glob('$REPO_ROOT/tests/fixtures/starr/*.json')]"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q 'SonarrSettings' "$REPO_ROOT/tests/fixtures/starr/prowlarr-sonarr-schema-excerpt.json"
  /usr/bin/grep -q 'RadarrSettings' "$REPO_ROOT/tests/fixtures/starr/prowlarr-radarr-schema-excerpt.json"
  /usr/bin/grep -q 'QBittorrentSettings' "$REPO_ROOT/tests/fixtures/starr/sonarr-qbittorrent-schema-excerpt.json"
  /usr/bin/grep -q 'movieCategory' "$REPO_ROOT/tests/fixtures/starr/radarr-qbittorrent-schema-excerpt.json"
  /usr/bin/grep -q '<ApiKey>' "$REPO_ROOT/tests/fixtures/starr/config-xml-sample.xml"
  run "$REAL_PYTHON3" -c "import xml.etree.ElementTree as ET; ET.parse('$REPO_ROOT/tests/fixtures/starr/config-xml-sample.xml')"
  [ "$status" -eq 0 ]
}
