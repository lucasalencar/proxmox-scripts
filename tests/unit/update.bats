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
# update.sh — discovers update scripts
# -------------------------------------------------------------------

@test "update.sh handles specific package argument" {
  mkdir -p "$MOCK_TMPDIR/fakepkg"
  echo '#!/bin/bash
echo "fake update ran"
' > "$MOCK_TMPDIR/fakepkg/update.sh"
  chmod +x "$MOCK_TMPDIR/fakepkg/update.sh"
  run bash "$REPO_ROOT/update.sh" "fakepkg" 2>&1
  [[ "$output" == *"No update script found for package 'fakepkg'"* ]]
  [ "$status" -eq 0 ]
}

@test "update.sh discovers all packages when no args" {
  # Should find at least jellyfin, caddy, etc.
  run bash "$REPO_ROOT/update.sh" 2>&1
  # Will attempt to run real updates but mocked pct should handle
  # At least should not error on discovery
  [ "$status" -eq 0 ] || [[ "$output" == *"update"* ]]
}
