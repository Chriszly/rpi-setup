# rpi-setup

An easy way to provision a Raspberry Pi for different tasks. Pick a few tasks,
run one script, done. Designed for **Raspberry Pi OS** (64-bit, Bookworm or later).

## Quick start

```bash
git clone https://github.com/Chriszly/rpi-setup.git
cd rpi-setup
sudo bash setup.sh
```

An interactive menu lets you pick tasks (by number, `all`, or nothing to quit).
You can also skip the menu and run tasks directly by name:

```bash
sudo bash setup.sh base docker
```

List available tasks without changing anything:

```bash
sudo bash setup.sh --list
```

## Tasks

| Task         | Description                                                      |
|--------------|------------------------------------------------------------------|
| `base`       | OS update, EEPROM firmware, SSH enable, essential tools, fail2ban |
| `docker`     | Docker Engine, buildx and Compose (apt)                          |
| `tailscale`  | Tailscale WireGuard VPN (official installer, `tailscale up`)     |
| `pihole`     | Pi-hole ad blocker (official installer, interactive)             |
| `samba`      | Simple read-write NAS share for the current user                 |
| `web`        | nginx serving a "Raspberry Pi" index page                        |
| `monitoring` | Netdata real-time dashboard on port 19999                        |

Tasks are plain bash scripts inside `tasks/` - add your own by dropping in a
file that appends to `TASKS` and defines a `run_<name>` function. See
`tasks/base.sh` for the pattern.

## Notes

- Scripts are written to be idempotent: re-running is safe.
- Run with `sudo`, not `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`.
- `pihole` and `tailscale` run their official installers and remain
  interactive - follow the on-screen prompts.
- Diagnostics stay minimal on purpose; check exit codes of the completed
  `[+] Complete: <task>` lines.