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

Click a task for its page: every setting with its default, what it installs,
how to reach it and what to watch out for.

| Task | What you get | Settings you will most likely set |
|------|--------------|-----------------------------------|
| [`base`](docs/tasks/base.md) | OS update, EEPROM firmware, SSH kept on, essential tools, fail2ban, daily security updates, optional key-only SSH, journal size limit | `BASE_HOSTNAME`, `BASE_TIMEZONE`, Pi 5: `BASE_PCIE_GEN3` |
| [`docker`](docs/tasks/docker.md) | Docker Engine, buildx and Compose (apt), log rotation | none needed |
| [`network`](docs/tasks/network.md) | Fixed LAN address for the Pi (static IPv4 via NetworkManager), or tips to reserve it | `NETWORK_STATIC_IP` (e.g. `192.168.1.10/24`) |
| [`tailscale`](docs/tasks/tailscale.md) | Tailscale WireGuard VPN (official installer) | `TAILSCALE_AUTHKEY` (else it prints a login URL) |
| [`pihole`](docs/tasks/pihole.md) | Pi-hole ad blocker, admin UI at `http://<pi>/admin`, unattended | `PIHOLE_CONFIRM=yes`, `PIHOLE_PASSWORD`, `PIHOLE_DNS` |
| [`samba`](docs/tasks/samba.md) | Read-write NAS share `\\<pi>\nas-share` for your user | `SAMBA_PASSWORD` |
| [`backup`](docs/tasks/backup.md) | Nightly archive of container data, Pi-hole, Samba, SSH and rpi-setup settings (systemd timer, keeps 7) | `BACKUP_DEST` (a USB disk) |
| [`web`](docs/tasks/web.md) | nginx with a start page on `http://<pi>` (`:8080` if Pi-hole already uses port 80) | `WEB_PORT`, `WEB_TITLE` |
| [`monitoring`](docs/tasks/monitoring.md) | Netdata dashboard on `http://<pi>:19999` | `MONITORING_PORT` |
| [`netalertx`](docs/tasks/netalertx.md) | NetAlertX LAN device tracker on `http://<pi>:20211`, with a login (needs `docker`) | `NETALERTX_PASSWORD` (empty = generated) |
| [`teamspeak`](docs/tasks/teamspeak.md) | TeamSpeak 6 server, voice `:9987`, file `:30033`, web query `:10080` (needs `docker`, 64-bit OS) | `TEAMSPEAK_QUERY_ADMIN_PASSWORD` |
| [`firewall`](docs/tasks/firewall.md) | nftables firewall: SSH and the installed services' ports open, the rest dropped (run it last, re-run after adding a task) | `FIREWALL_ALLOW_FROM`, `FIREWALL_EXTRA_PORTS` |

The SD card settings of the flash scripts (`FLASH_*`) have their own page:
[flash](docs/tasks/flash.md).

How a run works:

- `base` runs first when you pick it, and a task's dependency runs before it.
  `netalertx` and `teamspeak` need `docker`; it is added to the run
  automatically when Docker is not installed.
- A failed task does not stop the others, but the tasks that need it are
  skipped and `setup.sh` exits non-zero.
- The run ends with a summary (`ok`, `failed` or `skipped` per task) and a
  reboot hint when one is needed. The whole output is appended to
  `/var/log/rpi-setup.log` (root only, as it holds generated passwords).
- Each task prints the address to open when it finishes.

Tasks are plain bash scripts in `tasks/`. Add your own by dropping in a file
that appends to `TASKS` and defines a `run_<name>` function; see
`tasks/base.sh` for the pattern and [AGENTS.md](AGENTS.md) for the conventions.

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
you leave empty (`SAMBA_PASSWORD`, `PIHOLE_PASSWORD`, `NETALERTX_PASSWORD`)
are generated on the first install, printed once and saved (root-only) in
`/var/lib/rpi-setup/secrets/<task>.env`. Re-running a task applies changed
settings: ports, the share, fail2ban, the Netdata bind and the containers are
rewritten; Pi-hole's DNS, interface and logging are only used at install
(change them in its web UI afterwards).

## Running a task in Docker

Tasks with a `<TASK>_DOCKER` setting in `config/rpi-setup.env.example` (for
example `WEB_DOCKER`) can run their service in its own Docker container
instead of installing it with apt. Set it to `yes` and run the task again:

- Docker is installed first if it is missing (the `docker` task's settings apply).
- The container's compose file and data live in `/opt/<task>/`, which is what
  you back up. `<TASK>_IMAGE` picks the image; pin a tag to control updates.
- On a Pi that already runs the native service, its data is copied over once
  and the native service is stopped (its packages stay). If the container
  does not stay up, the native service is started again.
- Setting it back to `no` stops the container and starts the native service.

Tasks that can do this: [`web`](docs/tasks/web.md#run-it-in-docker),
[`monitoring`](docs/tasks/monitoring.md#run-it-in-docker),
[`pihole`](docs/tasks/pihole.md#run-it-in-docker),
[`samba`](docs/tasks/samba.md#run-it-in-docker) and
[`tailscale`](docs/tasks/tailscale.md#run-it-in-docker) (native recommended).
`netalertx` and `teamspeak` always run in Docker; `base`, `docker`, `network`,
`backup` and `firewall` always run natively. The `firewall` task does not
detect these containers yet: open their ports with `FIREWALL_EXTRA_PORTS`.

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

## Keeping it running

### Health check

`sudo bash check.sh` checks the Pi without changing anything: board, OS
and firmware, power and temperature (under-voltage, throttling), disk space,
LAN address and SSH, and for every task that looks installed whether its
service or container runs and its port answers. It prints one
`OK`, `WARN` or `FAIL` line per check and exits 1 if anything failed. No
password or key is printed.

### Updating

Re-running a task does not update a container that is already running. To
bring an installed Pi up to date, run `sudo bash update.sh`: it upgrades the
OS packages, pulls new images for rpi-setup's containers (`/opt/<task>`) and
recreates the ones that changed, runs `pihole -up` if Pi-hole is installed and
`rpi-eeprom-update -a` on a Pi. Steps for things that are not installed are
skipped, a failed step does not stop the others, and it tells you when a reboot
is recommended. Options: `--dry-run` (only print the commands), `--no-apt`,
`--no-containers`.

## Documentation

- Task pages: [base](docs/tasks/base.md), [docker](docs/tasks/docker.md),
  [network](docs/tasks/network.md), [tailscale](docs/tasks/tailscale.md),
  [pihole](docs/tasks/pihole.md), [samba](docs/tasks/samba.md),
  [backup](docs/tasks/backup.md), [web](docs/tasks/web.md),
  [monitoring](docs/tasks/monitoring.md), [netalertx](docs/tasks/netalertx.md),
  [teamspeak](docs/tasks/teamspeak.md), [firewall](docs/tasks/firewall.md),
  and the SD card settings in [flash](docs/tasks/flash.md).
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
  changed settings are applied.
- Run with `sudo` from your normal user, not as `root`. The `docker` and
  `samba` tasks pick up your user through `SUDO_USER`. After `docker`, log out
  and back in to use `docker` without `sudo`.
- `pihole` and `tailscale` run their official installers (`curl | sh`); both
  print a warning first, and `pihole` asks you to type `yes` unless
  `PIHOLE_CONFIRM=yes`.
- `network` changes the Pi's address: over SSH the session drops, so run it
  alone or last.
- Check the `[+] Complete: <task>` lines and the summary at the end of a run;
  a task that could not finish prints `[!]` or `[x]` lines explaining why.

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
- [nftables](https://netfilter.org/projects/nftables/) - apt package
  (`tasks/firewall.sh`)
- [NetAlertX](https://github.com/netalertx/NetAlertX) - official Docker image
  (`ghcr.io/netalertx/netalertx`, `tasks/netalertx.sh`)
- [TeamSpeak 6](https://teamspeak.com/) - official Docker image
  (`teamspeaksystems/teamspeak6-server`, `tasks/teamspeak.sh`)

Raspberry Pi, Raspberry Pi OS, and Raspberry Pi Imager are trademarks of
Raspberry Pi Ltd. All other product names are trademarks of their respective
owners. Their use here is descriptive and does not imply endorsement.