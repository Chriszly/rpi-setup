# rpi-setup

An easy way to provision a Raspberry Pi for different tasks. Pick a few tasks,
run one script, done. Designed for **Raspberry Pi OS Lite, 64-bit** (Trixie,
which the flash scripts write, or Bookworm).

## Quick start

1. **Flash an SD card** from your PC. It downloads the latest Raspberry Pi OS
   Lite, verifies it, writes it, and pre-creates your login user with SSH on:
   - Linux: `sudo ./host/flash.sh` ([guide](docs/setup-linux.md))
   - Windows, elevated PowerShell: `.\host\flash.ps1` ([guide](docs/setup-windows.md))
2. **Boot the Pi** with the card, wait 1-2 minutes, then
   `ssh <user>@raspberrypi.local` (or the Pi's IP from your router).
3. **Provision it** on the Pi:

   ```bash
   sudo apt-get update && sudo apt-get install -y git
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
bash setup.sh --list
```

Run `base` first and reboot once afterwards (`sudo reboot`) so kernel and
firmware updates take effect.

## Tasks

| Task         | What you get                                                        | Asks you for                         |
|--------------|---------------------------------------------------------------------|--------------------------------------|
| `base`       | OS update, EEPROM firmware, SSH kept on, essential tools, fail2ban  | nothing                              |
| `docker`     | Docker Engine, buildx and Compose (apt)                             | nothing                              |
| `tailscale`  | Tailscale WireGuard VPN (official installer)                        | a login URL to open, or `TAILSCALE_AUTHKEY` |
| `pihole`     | Pi-hole ad blocker, admin UI at `http://<pi>/admin`                 | "yes" to the install, then Pi-hole's own dialogs |
| `samba`      | Read-write NAS share `\\<pi>\nas-share` for your user              | an SMB password (first run only), or `SAMBA_PASSWORD` |
| `web`        | nginx with a "Raspberry Pi" page on `http://<pi>` (`:8080` if Pi-hole already uses port 80) | nothing |
| `monitoring` | Netdata dashboard on `http://<pi>:19999`                            | nothing                              |
| `netalertx`  | NetAlertX LAN device presence tracker on `http://<pi>:20211`        | nothing (needs `docker`)             |
| `teamspeak`  | TeamSpeak 6 server (voice :9987, file :30033, web query :10080)     | nothing (needs `docker`)             |

Each task prints the address to open when it finishes. Tasks are plain bash
scripts inside `tasks/` - add your own by dropping in a file that appends to
`TASKS` and defines a `run_<name>` function. See `tasks/base.sh` for the pattern.

### Unattended runs

Every prompt has an environment variable, so a whole setup can run from a
script (`sudo -E` keeps the variables):

```bash
export SAMBA_PASSWORD='...' PIHOLE_CONFIRM=yes TAILSCALE_AUTHKEY='tskey-...'
sudo -E bash setup.sh base docker samba tailscale netalertx
```

Pi-hole's own installer still shows its dialogs, so run `pihole` from a
terminal.

## Documentation

- [Setup guide - Windows host](docs/setup-windows.md) - flash an SD card with
  `host/flash.ps1` and provision the Pi, step by step.
- [Setup guide - Linux host](docs/setup-linux.md) - flash an SD card with
  `host/flash.sh` and provision the Pi, step by step.
- [CI testing](docs/ci-testing.md) - how the GitHub Actions test environment
  works, its limitations, and how to bump the pinned images.

## Notes

- Re-running any task is safe: finished work is detected and skipped, and
  `samba` keeps the password you set the first time.
- Run with `sudo`, not as `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`. After `docker`, log out and back in to use
  `docker` without `sudo`.
- `pihole` and `tailscale` run their official installers (`curl | sh`); both
  print a warning first, and `pihole` asks you to type `yes`. Set the Pi-hole
  admin password afterwards with `sudo pihole setpassword`.
- `pihole` and `web` can run together: whichever comes second moves to port
  8080, and the task prints the address it ended up on.
- `netalertx` requires Docker: run it via `sudo bash setup.sh docker netalertx`.
  It auto-detects your LAN subnet and interface. The detected `SCAN_SUBNETS`
  can be corrected in the UI under Settings > Subnets & Rules. First discovery
  takes 5-10 minutes.
- `teamspeak` requires Docker: run it via `sudo bash setup.sh docker teamspeak`.
  On first start the ServerAdmin privilege key is printed to the console - save
  it, it is only shown once and is needed to log in from the TS6 client at
  `<pi-ip>:9987` (later: `docker logs teamspeak`).
- Check the `[+] Complete: <task>` lines at the end of a run; a task that
  could not finish prints `[!]` or `[x]` lines explaining why.

## Acknowledgements

This project does not redistribute any third-party software. It only downloads
and installs software from its official source at runtime, and pulls official
Docker images when a task needs them:

- [Raspberry Pi OS](https://www.raspberrypi.com/software/) - OS image downloaded
  and verified by `host/flash.sh` / `host/flash.ps1`
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) - used by
  `host/flash.ps1` to write SD cards
- [Pi-hole](https://pi-hole.net/) - official installer (`tasks/pihole.sh`)
- [Tailscale](https://tailscale.com/) - official install script
  (`tasks/tailscale.sh`)
- [Docker Engine](https://www.docker.com/) - installed from Docker's apt
  repository (`tasks/docker.sh`)
- [Netdata](https://www.netdata.cloud/) - apt package (`tasks/monitoring.sh`)
- [nginx](https://nginx.org/) - apt package (`tasks/web.sh`)
- [Samba](https://www.samba.org/) - apt package (`tasks/samba.sh`)
- [fail2ban](https://www.fail2ban.org/) - apt package (`tasks/base.sh`)
- [NetAlertX](https://github.com/aitrix/NetAlertX) - official Docker image
  (`ghcr.io/netalertx/netalertx`, `tasks/netalertx.sh`)
- [TeamSpeak 6](https://teamspeak.com/) - official Docker image
  (`teamspeaksystems/teamspeak6-server`, `tasks/teamspeak.sh`)

Raspberry Pi, Raspberry Pi OS, and Raspberry Pi Imager are trademarks of
Raspberry Pi Ltd. All other product names are trademarks of their respective
owners. Their use here is descriptive and does not imply endorsement.