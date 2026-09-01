#!/usr/bin/env bash
# Helper to setup mock PATH and temp dirs for each test
# Usage: source this file in setup()

setup_mocks() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  # Also ensure sleep mock is used
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
}

teardown_mocks() {
  if [ -n "${MOCK_TMPDIR:-}" ] && [ -d "$MOCK_TMPDIR" ]; then
    rm -rf "$MOCK_TMPDIR"
  fi
}

# Helper to create a temp repo root with .server_users layout for get_* user tests
# Creates a copy of functions.sh in a temp location where ../.server_users resolves correctly
create_temp_functions_root() {
  local users_content="$1"
  local tmp_root
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$BATS_TEST_DIRNAME/../../common/functions.sh" "$tmp_root/common/functions.sh"
  echo -e "$users_content" > "$tmp_root/.server_users"
  echo "$tmp_root"
}
