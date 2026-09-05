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

# -------------------------------------------------------------------
# starr/container/configure.py — in-container logic (stdlib only)
# -------------------------------------------------------------------

@test "starr container configure.py compiles and self-test passes" {
  run "$REAL_PYTHON3" -m py_compile "$REPO_ROOT/starr/container/configure.py"
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" "$REPO_ROOT/starr/container/configure.py" --self-test
  [ "$status" -eq 0 ]
}

@test "starr container configure.py builders only emit fields known by research fixtures" {
  run "$REAL_PYTHON3" "$REPO_ROOT/starr/container/configure.py" --dump-desired --qbit-host 1.2.3.4
  [ "$status" -eq 0 ]
  run "$REAL_PYTHON3" -c "
import json, sys
dump = json.loads('''$output''')
pairs = [('prowlarr_sonarr', 'prowlarr-sonarr-schema-excerpt.json'),
         ('prowlarr_radarr', 'prowlarr-radarr-schema-excerpt.json'),
         ('download_sonarr', 'sonarr-qbittorrent-schema-excerpt.json'),
         ('download_radarr', 'radarr-qbittorrent-schema-excerpt.json')]
errors = []
for builder_key, fixture_name in pairs:
    built = {f['name'] for f in dump[builder_key]['fields']}
    known = {f['name'] for f in json.load(open('$REPO_ROOT/tests/fixtures/starr/' + fixture_name))['fields']}
    unknown = built - known
    missing = known - built
    if unknown:
        errors.append('%s emits unknown fields %s' % (builder_key, sorted(unknown)))
    if missing:
        errors.append('%s omits schema fields %s' % (builder_key, sorted(missing)))
for builder_key, fixture_name in pairs[:2]:
    expected = {f['name']: f.get('value') for f in json.load(open('$REPO_ROOT/tests/fixtures/starr/' + fixture_name))['fields']}
    actual = {f['name']: f.get('value') for f in dump[builder_key]['fields']}
    for name, value in expected.items():
        if name == 'apiKey':
            continue
        if actual.get(name) != value:
            errors.append('%s has %s=%r, expected %r' % (builder_key, name, actual.get(name), value))
if errors:
    print('\n'.join(errors))
    sys.exit(1)
"
  [ "$status" -eq 0 ]
}

@test "starr container configure.py validates qbit port range" {
  run "$REAL_PYTHON3" "$REPO_ROOT/starr/container/configure.py" --dump-desired --qbit-port 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"between 1 and 65535"* ]]

  run "$REAL_PYTHON3" "$REPO_ROOT/starr/container/configure.py" --dump-desired --qbit-port 65536
  [ "$status" -ne 0 ]
  [[ "$output" == *"between 1 and 65535"* ]]
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
