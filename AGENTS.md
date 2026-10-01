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
4. For Docker-dependent tasks, source `lib/containers.sh` and call `container_require_docker` (it runs the `docker` task when Docker is missing)
5. For container tasks use `container_dir`, `container_pull` and `container_up` from `lib/containers.sh` (`container_up` waits until the container stays up and rolls back otherwise)
6. Use `assign_uid <service>` for a stable per-service UID/GID (persisted under `/var/lib/rpi-setup/uids/`) so re-runs keep the same owner and services never collide
7. Keep a fixed UID where the upstream image requires one - e.g. `teamspeak` runs as `9987` and ignores `PUID`/`PGID`, so its data dir must stay owned by `9987`
8. Every setting a task reads is named `<TASK>_...` (e.g. `SAMBA_PASSWORD`) and must be listed in `config/tasks/<name>.env` (names only) and in `config/rpi-setup.env.example` (with default and a comment); `ci/test-setup.sh` checks that all three agree. Read settings as `${NAME:-default}` or `: "${NAME:=default}"` (an empty value means default), validate them before changing anything (`setting_on`, `require_port`, ...), and never prompt: generate a missing password with `gen_secret`, print it and store it with `save_secret`
9. Document the task in `docs/tasks/<name>.md` (every setting with its default, what it installs, how to reach it, dependencies and pitfalls) and link it from the README's task table; `ci/test-setup.sh` checks that every setting is on the page and that the README links it

## Security Guidelines

- Never hardcode secrets, passwords, or tokens
- Warn users before `curl ... | bash` patterns (see `tasks/pihole.sh`)
- Validate all user inputs
- Use `openssl passwd -6` for password hashing
- Drop unnecessary capabilities in Docker containers

## Testing Requirements

Before submitting changes:
- Run `bash -n <file>.sh` on all modified shell scripts
- Run the unit tests: `bash ci/test-lib.sh` and `bash ci/test-setup.sh` (with `sudo` on Linux to include the root-only cases); add cases for new helpers
- Run affected task(s) on actual Raspberry Pi: `sudo bash setup.sh <task>`
- Verify idempotency: re-run the same task
- Check `shellcheck` passes with `.shellcheckrc` config

## PR Requirements

Fill in `.github/PULL_REQUEST_TEMPLATE.md` (checked by the PR Template Validation workflow).

## Architecture Notes

- `setup.sh` loads all `tasks/*.sh` and presents interactive menu
- `setup.sh` splits `config/rpi-setup.env` into `config/local/<task>.env` (`split_config`) and loads each task's file (`load_task_config`) right before running it; both files are git-ignored
- `lib/common.sh` provides all shared helpers
- `host/flash.sh` (Linux) and `host/flash.ps1` (Windows) create bootable SD cards
- Tasks are independent; `base` runs first when picked, and a task that needs Docker installs it itself (`container_require_docker`)
- Docker containers use host networking where needed (`network_mode: host`)

## Common Pitfalls to Avoid

- Don't hardcode fallback versions/dates - fail with actionable error instead
- Don't forget `systemctl enable --now` for services
