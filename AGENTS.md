# Proxmox scripts AI rules

- All code and documentation must be written in English.
- Before running any command, check the current machine's OS:
  - If **macOS**: your session is NOT on the Proxmox machine. Any commands
    targeted to the Proxmox environment must be sent to the user to execute
    manually. Provide the exact commands the user should run.
  - If **Linux**: you are likely running directly on the Proxmox server.
    You may execute Proxmox/ve commands and any other necessary commands
    directly.

# User context validation

Always determine who should run a script and add a guard at the top:

Source `common/functions.sh` and use the provided helpers:

- **Root-only scripts** (system config, package installs, container setup):
  use `require_root`
- **User-only scripts** (dotfiles, user-level tooling like opencode):
  use `require_non_root`

For root-only scripts that need to act on behalf of the primary user, use
`get_primary_user` / `get_primary_user_home` and `su -c "..." "$TARGET_USER"`.
