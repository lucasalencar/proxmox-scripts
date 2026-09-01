.PHONY: test test-verbose lint

# Default Proxmox mock bin is in tests/helpers/mocks — no real host is touched.
test:
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats tests/unit

test-verbose:
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats --verbose-run tests/unit

lint:
	@shellcheck common/*.sh */*.sh */*/*.sh 2>&1 | head -100
	@echo "shellcheck done"
