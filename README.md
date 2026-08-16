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
| `pihole`     | Pi-hole ad blocker (official installer)                          |
| `samba`      | Simple read-write NAS share for the current user                 |
| `web`        | nginx serving a "Raspberry Pi" index page                        |
| `monitoring` | Netdata real-time dashboard on port 19999                        |
| `netalertx`  | NetAlertX LAN device presence tracker on port 20211              |
| `teamspeak`  | TeamSpeak 6 voice server (voice :9987, file :30033, web :10080) |

Tasks are plain bash scripts inside `tasks/` - add your own by dropping in a
file that appends to `TASKS` and defines a `run_<name>` function. See
`tasks/base.sh` for the pattern.

## Documentation

- [Setup guide - Windows host](docs/setup-windows.md) - flash an SD card with
  `host/flash.ps1` and provision the Pi, step by step.
- [Setup guide - Linux host](docs/setup-linux.md) - flash an SD card with
  `host/flash.sh` and provision the Pi, step by step.
- [CI testing](docs/ci-testing.md) - how the GitHub Actions test environment
  works, its limitations, and how to bump the pinned image.

## Notes

- Scripts are written to be idempotent: re-running is safe.
- Run with `sudo`, not `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`.
- `pihole` and `tailscale` run their official installers. `pihole` prints a
  security warning and prompts for confirmation when run interactively; in
  non-interactive runs it installs directly. `tailscale` stays interactive -
  follow the on-screen prompts.
- `netalertx` requires Docker: run it via `sudo bash setup.sh docker netalertx`.
  It auto-detects your LAN subnet and interface and serves a device-presence
  dashboard at `http://<pi-ip>:20211`. The detected `SCAN_SUBNETS` can be
  corrected in the UI under Settings > Subnets & Rules.
- `teamspeak` requires Docker: run it via `sudo bash setup.sh docker teamspeak`.
  It runs the official TeamSpeak 6 server (native arm64 since beta 9). On first
  start the ServerAdmin privilege key is printed to the console - save it, it is
  only shown once and is needed to log in from the TS6 client at `<pi-ip>:9987`.
- Diagnostics stay minimal on purpose; check exit codes of the completed
  `[+] Complete: <task>` lines.