.PHONY: test test-python test-verbose lint

# Default Proxmox mock bin is in tests/helpers/mocks — no real host is touched.
test: test-python
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats tests/unit

test-python:
	@python3 caddy/test_generate_caddyfile_core.py

test-verbose:
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats --verbose-run tests/unit

lint:
	@shellcheck common/*.sh */*.sh */*/*.sh 2>&1 | head -100
	@python3 -m py_compile caddy/generate_caddyfile_core.py caddy/test_generate_caddyfile_core.py
	@echo "shellcheck done"
