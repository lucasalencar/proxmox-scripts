#!/usr/bin/env bash
# Shared helper for mock log handling
mock_log() {
  local name="$1"
  shift
  local LOG_FILE="${MOCK_LOG:-${BATS_TMPDIR:-/tmp}/${name}.log}"
  /bin/mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "$name $*" >> "$LOG_FILE"
}
