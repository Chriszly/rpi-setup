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
| `tailscale`  | Tailscale WireGuard VPN (official container, browser login)      |
| `pihole`     | Pi-hole ad blocker (container, DNS :53, web UI :8080)            |
| `samba`      | Simple read-write NAS share (container, SMB :445)                |
| `web`        | nginx serving a "Raspberry Pi" index page (container, :80)       |
| `monitoring` | Netdata real-time dashboard on port 19999 (container)            |
| `netalertx`  | NetAlertX LAN device presence tracker on port 20211              |
| `teamspeak`  | TeamSpeak 6 voice server (voice :9987, file :30033, web :10080) |

Everything except `base` runs in Docker. Container tasks install Docker
automatically when it is missing - there is no need to run the `docker` task
first (though `sudo bash setup.sh all` does so anyway, since `docker` sorts
early in the task list).

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
- Container state lives under `/opt/<task>` with compose files and bind-mounted
  data directories; each service gets a stable UID via
  `/var/lib/rpi-setup/uids/`.
- If a native service from an older rpi-setup version is still running (nginx,
  netdata, smbd, pihole-FTL, tailscaled), the matching task disables it so the
  container can take over its port.
- `tailscale` runs the official container and prints a login URL from the logs -
  open it in a browser to approve the device. It requires `/dev/net/tun`
  (`sudo modprobe tun`). Re-running the task shows the login status.
- `pihole` serves DNS on :53 and the web admin UI on :8080. A random web UI
  password is generated once and stored in `/opt/pihole/webpassword` (mode
  0600); set `PIHOLE_PASSWORD` before running to choose your own.
- `samba` shares `/home/<user>/nas-share` over SMB :445 with your username.
  Set `SAMBA_PASSWORD` to skip the interactive prompt.
- `netalertx` auto-detects your LAN subnet and interface and serves a
  device-presence dashboard at `http://<pi-ip>:20211`. The detected
  `SCAN_SUBNETS` can be corrected in the UI under Settings > Subnets & Rules.
- `teamspeak` runs the official TeamSpeak 6 server (native arm64 since beta 9).
  On first start the ServerAdmin privilege key is printed to the console - save
  it, it is only shown once and is needed to log in from the TS6 client at
  `<pi-ip>:9987`.
- Diagnostics stay minimal on purpose; check exit codes of the completed
  `[+] Complete: <task>` lines.

## Acknowledgements

This project does not redistribute any third-party software. It only downloads
and installs software from its official source at runtime, and pulls official
Docker images when a task needs them:

- [Raspberry Pi OS](https://www.raspberrypi.com/software/) - OS image downloaded
  and verified by `host/flash.sh` / `host/flash.ps1`
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) - used by
  `host/flash.ps1` to write SD cards
- [Docker Engine](https://www.docker.com/) - installed from Docker's apt
  repository (`tasks/docker.sh`)
- [Pi-hole](https://pi-hole.net/) - official Docker image (`pihole/pihole`,
  `tasks/pihole.sh`)
- [Tailscale](https://tailscale.com/) - official Docker image
  (`ghcr.io/tailscale/tailscale`, `tasks/tailscale.sh`)
- [Netdata](https://www.netdata.cloud/) - official Docker image
  (`netdata/netdata`, `tasks/monitoring.sh`)
- [nginx](https://nginx.org/) - official Docker image (`nginx:stable-alpine`,
  `tasks/web.sh`)
- [Samba](https://www.samba.org/) - community Docker image built on Alpine
  (`crazymax/samba`, `tasks/samba.sh`)
- [fail2ban](https://www.fail2ban.org/) - apt package (`tasks/base.sh`)
- [NetAlertX](https://github.com/aitrix/NetAlertX) - official Docker image
  (`ghcr.io/netalertx/netalertx`, `tasks/netalertx.sh`)
- [TeamSpeak 6](https://teamspeak.com/) - official Docker image
  (`teamspeaksystems/teamspeak6-server`, `tasks/teamspeak.sh`)

Raspberry Pi, Raspberry Pi OS, and Raspberry Pi Imager are trademarks of
Raspberry Pi Ltd. All other product names are trademarks of their respective
owners. Their use here is descriptive and does not imply endorsement.