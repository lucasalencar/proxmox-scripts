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

Use TDD (Red-Green-Refactor) when implementing new scripts or features in the repository, including Bash scripts. For elaborate code projects (Python/Go libs, CLI tools, business logic) TDD is mandatory. When adding or refactoring Bash scripts, write bats tests first (Red) using the mock bin in `tests/helpers/mocks`.

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

During a session, append any non-obvious fix, recurring pitfall, or design decision worth remembering to `LEARNINGS.md`. Write entries that are **generic and actionable** so future sessions benefit. Use simple bullet points:

```markdown
- **Title:** What was learned — brief explanation and the resolution.
```

Do **not** duplicate rules already explicitly stated in `AGENTS.md` as learnings — only capture knowledge that goes beyond these rules.

**Keep learnings generalizable** — they should describe patterns, behaviors, or pitfalls that could apply to multiple scripts or contexts, not specific fixes applied to a particular script. For example, prefer "Proxmox `pct exec` does not support `--env`; use `env KEY=val` inside the container command instead" over "Fixed sync-users.sh by using env instead of --env".

### 11. Code comments — keep concise and sparse

Code comments should describe **what** is being done, not **why**. Keep them short and avoid long-winded rationale. Put the reasoning in docs, PR descriptions, or `LEARNINGS.md` instead. This applies to `*.sh` and source files; `docs/*.md` may keep why-explanations for user understanding.

- Add a comment only when truly necessary — prefer self-explanatory code and helper names.
- Before adding a comment, check if it should be a log instead (`log_step`, `log_info`, `log_success`, etc.) to give the user runtime visibility.

### 12. CI must be green after every push

After every `git push` (new branch, PR update, or any remote push), wait for GitHub Actions CI to finish and ensure it is green before considering the task done.

- Use `gh run list --branch <branch>`, `gh pr checks`, or `gh run watch <run-id>` to monitor.
- If CI fails, fix the failure immediately with a follow-up commit/push — never leave a pushed branch with red CI.
- This applies even when the user did not explicitly ask to check CI.
