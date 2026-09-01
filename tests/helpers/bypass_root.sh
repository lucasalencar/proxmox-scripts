#!/usr/bin/env bash
# Test-only override for require_root / require_non_root
# Sourced via BASH_ENV so that `bash install.sh` subprocesses inherit the bypass
# without touching production code.
require_root() { return 0; }
require_non_root() { return 0; }
