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

## Fresh OS on an SD card

Both scripts prepare a bootable SD card for a **headless Raspberry Pi 5** (8GB):
they download the latest **Raspberry Pi OS Lite (64-bit, arm64)** image, verify
its SHA-256, write it to the card, and pre-configure first boot (SSH enabled +
a login user).

### Windows host — `host/flash.ps1`

Requirements:

- **Raspberry Pi Imager 2.x** - https://www.raspberrypi.com/software/
- **openssl** - bundled with Git for Windows (skipped with `-SkipCustomize`)
- An elevated PowerShell (the script flashes a raw disk)

```powershell
.\host\flash.ps1
```

It will ask for the target disk, username and password. Or pass everything up front:

```powershell
.\host\flash.ps1 -Disk 2 -UserName pi -Password 'change-me'
```

Other useful switches:

| Switch          | Meaning                                                        |
|-----------------|----------------------------------------------------------------|
| `-Image <path>` | Flash a locally downloaded `.img` / `.img.xz` instead          |
| `-SkipDownload` | Require a cached image in `.\downloads\` (no network)          |
| `-SkipCustomize`| Skip SSH/user setup; boot to the on-screen first-run wizard    |
| `-DownloadDir`  | Override the image download/cache folder (default `downloads/`)|

### Linux host — `host/flash.sh`

Requires `curl`, `xz`, `dd`, `mount`, `openssl` and `partprobe` (from `parted`).
Uses `dd` directly, so no Raspberry Pi Imager needed.

```bash
sudo ./host/flash.sh
```

It will ask for the target disk, username and password. Or pass everything up front:

```bash
sudo ./host/flash.sh -d /dev/sda -u pi -p 'change-me'
```

| Option            | Meaning                                                        |
|-------------------|----------------------------------------------------------------|
| `-d DEVICE`       | SD card device node (e.g. `/dev/sda`); prompts if omitted      |
| `-i IMAGE`        | Flash a locally downloaded `.img` / `.img.xz` instead          |
| `-u USER`, `-p PASS` | Username/password for the Pi user (prompted if omitted)     |
| `-k`              | Skip SSH/user setup; boot to the on-screen first-run wizard    |
| `-l`              | List candidate disks and exit                                  |

Both scripts cache the image in `downloads/` (git-ignored) and re-verify it each run.

After flashing, put the card in the Pi, power it on, wait 1-2 minutes, then:

```bash
ssh <username>@raspberrypi.local
git clone https://github.com/Chriszly/rpi-setup.git
cd rpi-setup && sudo bash setup.sh
```

Notes:

- The script writes an empty `ssh` file and a `userconf.txt` file to the `bootfs`
  partition; the OS creates the account and deletes both on first boot. A user is
  required because Raspberry Pi OS ships with no default account.
- Enabling SSH alone is not enough to log in: Raspberry Pi OS ships with no
  default user, so the script always asks for a username/password too.
- The downloaded image is cached in `downloads/` (git-ignored) and re-verified
  on every run.

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
| `netalertx`  | NetAlertX LAN device presence tracker on port 20211              |
| `teamspeak`  | TeamSpeak 6 voice server (voice :9987, file :30033, web :10080) |

Tasks are plain bash scripts inside `tasks/` - add your own by dropping in a
file that appends to `TASKS` and defines a `run_<name>` function. See
`tasks/base.sh` for the pattern.

## Notes

- Scripts are written to be idempotent: re-running is safe.
- Run with `sudo`, not `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`.
- `pihole` and `tailscale` run their official installers and remain
  interactive - follow the on-screen prompts.
- `netalertx` requires Docker: run it via `sudo bash setup.sh docker netalertx`.
  It auto-detects your LAN subnet and interface and serves a device-presence
  dashboard at `http://<pi-ip>:20211`.
- `teamspeak` requires Docker: run it via `sudo bash setup.sh docker teamspeak`.
  It runs the official TeamSpeak 6 server (native arm64 since beta 9). On first
  start the ServerAdmin privilege key is printed to the console - save it, it is
  only shown once and is needed to log in from the TS6 client at `<pi-ip>:9987`.
- Diagnostics stay minimal on purpose; check exit codes of the completed
  `[+] Complete: <task>` lines.