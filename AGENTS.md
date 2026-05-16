# Proxmox scripts AI rules

---

## NON-NEGOTIABLE

### 1. Destructive commands safety (root/sudo)

When running as **root** or with **sudo**: you MUST NEVER execute any
destructive/modifying commands (e.g. `rm`, `mv`, `cp` overwriting, `dd`,
`chmod`, `chown`, package install/remove, config file writes, service
restarts, etc.) without first **explicitly describing the command and
getting the user's explicit approval**. The sole exception is creating new
directories and writing new files that are clearly part of the project
being scaffolded.

When running as a **non-root user** (regular user): this restriction does
not apply — proceed with normal caution.

### 2. OS check before any command

Before running any command, check the current machine's OS:

- If **macOS**: your session is NOT on the Proxmox machine. Any commands
  targeted to the Proxmox environment must be sent to the user to execute
  manually. Provide the exact commands the user should run.
- If **Linux**: you are likely running directly on the Proxmox server.
  You may execute Proxmox/ve commands and any other necessary commands
  directly.

---

## MEDIUM PRIORITY

### 3. User context validation

Always determine who should run a script and add a guard at the top:

- **Root-only scripts** (system config, package installs, container setup):
  use `require_root`
- **User-only scripts** (dotfiles, user-level tooling like opencode):
  use `require_non_root`

### 4. Language

All code and documentation must be written in English.

---

## LOW PRIORITY

### 5. Implementation patterns

- Source `common/functions.sh` and use the provided helpers.
- For root-only scripts that need to act on behalf of the primary user, use
  `get_primary_user` / `get_primary_user_home` and `su -c "..." "$TARGET_USER"`.
