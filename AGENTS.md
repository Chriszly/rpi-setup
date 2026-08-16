# AGENTS.md - Instructions for AI Agents

This file provides guidance for AI agents (Claude, GPT, Copilot, etc.) working on the rpi-setup project.

## Project Overview

rpi-setup is a collection of bash/PowerShell scripts to provision Raspberry Pis for various tasks (Docker, Pi-hole, Tailscale, Samba, monitoring, etc.). The main entry point is `setup.sh` which loads tasks from `tasks/*.sh`.

## Code Style & Conventions

### Bash Scripts
- Use `#!/usr/bin/env bash` shebang
- Always `set -euo pipefail` at the top
- Use functions from `lib/common.sh` (`say`, `info`, `warn`, `die`, `apt_install`, etc.)
- Follow existing task pattern: append to `TASKS` array, define `run_<name>()` function
- Keep scripts idempotent (safe to re-run)

### PowerShell Scripts
- Use `#!/usr/bin/env pwsh` shebang
- `#Requires -Version 5.1`
- Use approved verbs (`Write-Step`, `Write-Info`, `Write-Warn`, `Fail`)
- Prefer `Test-Path -LiteralPath` over `Test-Path`

### Common Patterns
- `info` for progress, `say` for success, `warn` for non-fatal issues, `die` for fatal errors
- Use `hr` for visual separators
- Use `real_user()` to get the sudo-invoking user
- Use `is_pi()` to detect Raspberry Pi hardware
- Use `apt_update()` / `apt_install()` for package management (caches apt update for 1 hour)

## Task Development

When adding a new task:
1. Create `tasks/<name>.sh` following the pattern in `tasks/base.sh`
2. Add `TASKS+=("<name>|<description>")`
3. Define `run_<name>()` function
4. Use `require_docker` helper for Docker-dependent tasks
5. Use `ensure_container_dir` and `compose_up` for container tasks
6. Use `assign_uid <service>` for a stable per-service UID/GID (persisted under `/var/lib/rpi-setup/uids/`) so re-runs keep the same owner and services never collide
7. Keep a fixed UID where the upstream image requires one - e.g. `teamspeak` runs as `9987` and ignores `PUID`/`PGID`, so its data dir must stay owned by `9987`

## Security Guidelines

- Never hardcode secrets, passwords, or tokens
- Warn users before `curl ... | bash` patterns (see `tasks/pihole.sh`)
- Validate all user inputs
- Use `openssl passwd -6` for password hashing
- Drop unnecessary capabilities in Docker containers

## Testing Requirements

Before submitting changes:
- Run `bash -n <file>.sh` on all modified shell scripts
- Run affected task(s) on actual Raspberry Pi: `sudo bash setup.sh <task>`
- Verify idempotency: re-run the same task
- Check `shellcheck` passes with `.shellcheckrc` config

## PR Requirements

All PRs must include:
- Completed PR template sections: Summary, Type of change, Checklist, Testing
- Clear, concise commit messages
- No secrets or personal info
- Updated README if task list/options/behavior changed

## Architecture Notes

- `setup.sh` loads all `tasks/*.sh` and presents interactive menu
- `lib/common.sh` provides all shared helpers
- `host/flash.sh` (Linux) and `host/flash.ps1` (Windows) create bootable SD cards
- Tasks are independent but can declare dependencies (e.g., `netalertx` requires `docker`)
- Docker containers use host networking where needed (`network_mode: host`)

## Common Pitfalls to Avoid

- Don't assume specific UIDs/GIDs - use `assign_uid <service>` (except where the image needs a fixed one, like `teamspeak`)
- Don't skip `apt_update()` before `apt_install()`
- Don't use `curl | bash` without warning
- Don't hardcode fallback versions/dates - fail with actionable error instead
- Don't forget `systemctl enable --now` for services
