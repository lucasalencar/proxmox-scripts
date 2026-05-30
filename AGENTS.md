# Proxmox scripts AI rules

---

## NON-NEGOTIABLE

### 1. Destructive commands safety (root/sudo)

**Root/sudo:** NEVER run destructive commands (`rm`, `mv`, `cp` overwrite, `dd`, `chmod`, `chown`, package install/remove, config writes, service restarts, etc.) without **explicitly describing the command and getting user approval first**. Exception: creating new dirs/files that are part of the project being scaffolded.

**Non-root user:** no restriction — proceed with normal caution.

### 2. OS check before any command

- **macOS:** not on Proxmox — provide exact commands for the user to run manually.
- **Linux:** likely on Proxmox — execute commands directly.

---

## MEDIUM PRIORITY

### 3. User context validation

Add a guard at the top of every script:
- **Root-only scripts:** use `require_root`
- **User-only scripts:** use `require_non_root`

### 4. Language

All code and docs in English.

### 5. Test-Driven Development (TDD)

Use TDD (Red-Green-Refactor) for elaborate code projects (Python/Go libs, CLI tools, business logic). Bash scripts are exempt.

### 6. Caddy compatibility check

Every new **package**, **container**, or **VM** must be checked for Caddy (Reverse Proxy) compatibility before deploy. Identify ports/protocols used and create/update Caddy config accordingly.

### 7. Package install/update symmetry

Every package with an `install.sh` must also have an `update.sh`.

---

## LOW PRIORITY

### 8. Implementation patterns

- Source `common/functions.sh` and use its helpers.
- For root-only scripts acting on behalf of the primary user, use `get_primary_user` / `get_primary_user_home` and `su -c "..." "$TARGET_USER"`.

### 9. Learnings file — read

At the start of every session, read `LEARNINGS.md` at the repository root. It contains past learnings, common model mistakes, and solutions. Apply them to avoid repeating errors.

### 10. Learnings file — write

During a session, append any non-obvious fix, recurring pitfall, or design decision worth remembering to `LEARNINGS.md`. Write entries that are generic and actionable so future sessions benefit. Use simple bullet points:

```markdown
- **Title:** What was learned — brief explanation and the resolution.
```
