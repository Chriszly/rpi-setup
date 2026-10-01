# rpi-setup

An easy way to provision a Raspberry Pi for different tasks. Pick a few tasks,
run one script, done. Designed for **Raspberry Pi OS Lite, 64-bit** (Trixie,
which the flash scripts write, or Bookworm).

## Quick start

1. **Flash an SD card** from your PC. It downloads the latest Raspberry Pi OS
   Lite, verifies it, writes it, and pre-creates your login user with SSH on:
   - Linux: `sudo ./host/flash.sh` ([guide](docs/setup-linux.md))
   - Windows, elevated PowerShell: `.\host\flash.ps1` ([guide](docs/setup-windows.md))

   Optionally it also sets the host name, Wi-Fi and your SSH public key, so the
   Pi comes up on your network without a screen or cable, e.g.
   `sudo ./host/flash.sh -n homepi -s 'My WiFi' -a ~/.ssh/id_ed25519.pub`
   (Windows: `-Hostname`, `-WifiSsid`, `-SshPublicKeyFile`); see the guides.
2. **Boot the Pi** with the card, wait 1-2 minutes, then
   `ssh <user>@raspberrypi.local` (or the Pi's IP from your router).
3. **Fill in your settings** on the Pi (passwords, ports, host name, ...):

   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/Chriszly/rpi-setup.git
   cd rpi-setup
   bash setup.sh --init-config      # creates config/rpi-setup.env
   nano config/rpi-setup.env        # every setting is optional
   ```

4. **Provision it**:

   ```bash
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

| Task         | What you get                                                        | Settings you will most likely set |
|--------------|---------------------------------------------------------------------|-----------------------------------|
| `base`       | OS update, EEPROM firmware, SSH kept on, essential tools, fail2ban  | `BASE_HOSTNAME`, `BASE_TIMEZONE`, Pi 5: `BASE_PCIE_GEN3` |
| `docker`     | Docker Engine, buildx and Compose (apt), log rotation               | none needed |
| `network`    | Fixed LAN address for the Pi (static IPv4 via NetworkManager), or tips to reserve it | `NETWORK_STATIC_IP` (e.g. `192.168.1.10/24`) |
| `tailscale`  | Tailscale WireGuard VPN (official installer)                        | `TAILSCALE_AUTHKEY` (else it prints a login URL) |
| `pihole`     | Pi-hole ad blocker, admin UI at `http://<pi>/admin`, unattended     | `PIHOLE_PASSWORD`, `PIHOLE_CONFIRM=yes`, `PIHOLE_DNS` |
| `samba`      | Read-write NAS share `\\<pi>\nas-share` for your user              | `SAMBA_PASSWORD` |
| `backup`     | Nightly archive of container data, Pi-hole, Samba, SSH and rpi-setup settings (systemd timer, keeps 7) | `BACKUP_DEST` (a USB disk) |
| `web`        | nginx with a start page on `http://<pi>` (`:8080` if Pi-hole already uses port 80) | `WEB_PORT`, `WEB_TITLE` |
| `monitoring` | Netdata dashboard on `http://<pi>:19999`                            | `MONITORING_PORT` |
| `netalertx`  | NetAlertX LAN device presence tracker on `http://<pi>:20211`        | `NETALERTX_PASSWORD` (empty = generated), `NETALERTX_LOGIN` (needs `docker`) |
| `teamspeak`  | TeamSpeak 6 server (voice :9987, file :30033, web query :10080)     | `TEAMSPEAK_QUERY_ADMIN_PASSWORD` (needs `docker`, 64-bit OS) |
| `firewall`   | nftables firewall: SSH and the installed services' ports open, the rest dropped (run it last, re-run after adding a task) | `FIREWALL_ALLOW_FROM`, `FIREWALL_EXTRA_PORTS` |

Each task prints the address to open when it finishes. Tasks are plain bash
scripts inside `tasks/` - add your own by dropping in a file that appends to
`TASKS` and defines a `run_<name>` function. See `tasks/base.sh` for the pattern.

## Settings

Everything a task can be told in advance lives in **one file**,
`config/rpi-setup.env`. [`config/rpi-setup.env.example`](config/rpi-setup.env.example)
lists every setting with its default and a one-line explanation, grouped by
task; `bash setup.sh --init-config` copies it for you (private, mode 600).
The format is one `NAME=value` per line:

```bash
BASE_HOSTNAME=homepi
BASE_TIMEZONE=Europe/Berlin
SAMBA_PASSWORD='my secret #1'   # quote values with " #" or spaces at the ends
PIHOLE_CONFIRM=yes
TAILSCALE_AUTHKEY=tskey-auth-...
```

- Leave a value empty, or delete the line, to get the default.
- Each name starts with its task's name (`SAMBA_...` belongs to `samba`); an
  unknown name stops the run before anything changes, so typos are caught.
- `config/rpi-setup.env` and everything generated from it are ignored by git:
  your passwords never end up in a commit.
- Before running tasks, `setup.sh` splits the file into one file per task,
  `config/local/<task>.env`. [`config/tasks/<task>.env`](config/tasks) lists
  the names each task reads. Run the split on its own with
  `bash config/split.sh` (or `bash setup.sh --split-config`) to check it.
- A variable on the command line wins over the file:
  `sudo SAMBA_PASSWORD=other bash setup.sh samba`.
- `RPI_SETUP_CONFIG_DIR=/some/folder` reads `rpi-setup.env` from another
  folder, e.g. one kept outside the git checkout.

With the settings filled in, a whole setup runs unattended:
`sudo bash setup.sh base docker samba pihole tailscale netalertx`. Passwords
you leave empty (`SAMBA_PASSWORD`, `PIHOLE_PASSWORD`) are generated on the
first install, printed once and saved (root-only) in
`/var/lib/rpi-setup/secrets/<task>.env`. Re-running a task applies changed
settings: ports, the share, fail2ban, the Netdata bind and the containers are
rewritten; Pi-hole's DNS, interface and logging are only used at install
(change them in its web UI afterwards).

## Raspberry Pi 5

The Pi 5 (and Pi 500 / CM5) needs Raspberry Pi OS **Bookworm or newer**; the
flash scripts write the current release, and `base` stops with an explanation
on an older one. Use the **64-bit** Lite image: `teamspeak`'s Docker image is
64-bit only and says so if the OS is 32-bit. Pi 5 only settings in `base`:

- `BASE_PCIE_GEN3=yes` runs the PCIe slot at Gen 3 for an NVMe HAT
  (roughly twice the speed; not officially certified).
- `BASE_PI5_4K_KERNEL=yes` boots the 4K-page kernel instead of the Pi 5's
  default 16K-page one, only if some program or container crashes with
  page-size or jemalloc errors.

Both go into a marked block at the end of `/boot/firmware/config.txt` and
apply after a reboot; switching them back to `no` removes the block again.

## Updating

Re-running a task does not update a container that is already running. To
bring an installed Pi up to date, run `sudo bash update.sh`: it upgrades the
OS packages, pulls new images for rpi-setup's containers (`/opt/<task>`) and
recreates the ones that changed, runs `pihole -up` if Pi-hole is installed and
`rpi-eeprom-update -a` on a Pi. Steps for things that are not installed are
skipped, a failed step does not stop the others, and it tells you when a reboot
is recommended. Options: `--dry-run` (only print the commands), `--no-apt`,
`--no-containers`.

## Documentation

- [Raspberry Pi 5 test checklist](docs/pi5-test-checklist.md) - one full test
  run on real hardware, checked with `sudo bash check.sh`, and what to report.
- [Setup guide - Windows host](docs/setup-windows.md) - flash an SD card with
  `host/flash.ps1` and provision the Pi, step by step.
- [Setup guide - Linux host](docs/setup-linux.md) - flash an SD card with
  `host/flash.sh` and provision the Pi, step by step.
- [CI testing](docs/ci-testing.md) - how the GitHub Actions test environment
  works, its limitations, and how to bump the pinned images.

## Notes

- Re-running any task is safe: finished work is detected and skipped, and
  `samba` keeps its password unless you set a new `SAMBA_PASSWORD`.
- Run with `sudo`, not as `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`. After `docker`, log out and back in to use
  `docker` without `sudo`.
- `pihole` and `tailscale` run their official installers (`curl | sh`); both
  print a warning first, and `pihole` asks you to type `yes` unless
  `PIHOLE_CONFIRM=yes`. Pi-hole installs without its dialogs using the
  `PIHOLE_*` settings; set `PIHOLE_UNATTENDED=no` to get the dialogs.
- `pihole` and `web` can run together: whichever comes second moves to port
  8080, and the task prints the address it ended up on.
- `netalertx` requires Docker: run it via `sudo bash setup.sh docker netalertx`.
  It auto-detects your LAN subnet and interface, or scans
  `NETALERTX_SCAN_SUBNETS`. First discovery
  takes 5-10 minutes.
- `teamspeak` requires Docker: run it via `sudo bash setup.sh docker teamspeak`.
  On first start the ServerAdmin privilege key is printed to the console - save
  it, it is only shown once and is needed to log in from the TS6 client at
  `<pi-ip>:9987` (later: `docker logs teamspeak`).
- A run ends with a summary: each task with `ok`, `failed` or `skipped`, and a
  reboot hint when one is needed. A failed task does not stop the others, but
  tasks that need it are skipped and `setup.sh` exits non-zero. `base` always
  runs first, and `docker` is added automatically (before the tasks that need
  it) when you pick `netalertx` or `teamspeak` without Docker installed. The
  whole output is appended to `/var/log/rpi-setup.log` (readable by root only,
  as it holds generated passwords).

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
- [Netdata](https://www.netdata.cloud/) - apt package, or Netdata's own apt
  repository on releases that no longer ship it (`tasks/monitoring.sh`)
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