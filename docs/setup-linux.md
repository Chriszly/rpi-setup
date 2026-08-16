# Setup guide - Linux host

This guide walks through the full workflow from a **Linux** host: prepare a
bootable SD card with `host/flash.sh`, boot the Pi headless, then provision it
with `setup.sh`. Everything you are asked to run is idempotent, so re-running
is always safe.

For the equivalent guide on a Windows host, see
[setup-windows.md](setup-windows.md).

## Prerequisites

- A Raspberry Pi (any model that runs Raspberry Pi OS 64-bit) and an SD card
  (plus a card reader for your machine).
- `curl`, `xz`, `dd`, `mount`, `openssl` and `partprobe` (from `parted`). On
  Raspberry Pi OS / Debian / Ubuntu:

  ```bash
  sudo apt-get update
  sudo apt-get install -y curl xz-utils coreutils mount openssl parted
  ```

- The image is downloaded automatically by the flash script - you do not need
  to download Raspberry Pi OS yourself.

## Step 1 - Get the repo

```bash
git clone https://github.com/Chriszly/rpi-setup.git
cd rpi-setup
```

### If the repository is private

Clone over HTTPS with your GitHub username and a **Personal Access Token**
(the token replaces the password; GitHub no longer accepts account passwords for
HTTPS):

```bash
git clone https://<USER>:<TOKEN>@github.com/Chriszly/rpi-setup.git
cd rpi-setup
```

Right after cloning, remove the credentials from the remote URL so pull/push do
not embed your token in `.git/config`:

```bash
git remote set-url origin https://github.com/Chriszly/rpi-setup.git
```

> Note: you only need to authenticate to *clone*; the setup scripts themselves
> run without credentials. The same command is used again on the Pi in
> Step 4. Passing the token inline puts it in your shell history - prefer a
> `read -s` prompt or a credential helper if that matters to you.

## Step 2 - Flash the SD card

The script writes the card directly with `dd`. Run it with `sudo`:

```bash
sudo ./host/flash.sh
```

It asks you to:

1. Pick the target disk from the listed candidates (a number, or a full
   `/dev/node` such as `/dev/sda`).
2. Type `yes` when asked to confirm it will DESTROY all data on that disk.
3. Enter a username and password (same rules as on Windows).

Or pass everything up front:

```bash
sudo ./host/flash.sh -d /dev/sda -u pi -p 'change-me'
```

All options:

| Option            | Meaning                                                        |
|-------------------|----------------------------------------------------------------|
| `-d DEVICE`       | SD card device node (e.g. `/dev/sda`); prompts if omitted      |
| `-i IMAGE`        | Flash a locally downloaded `.img` / `.img.xz` instead          |
| `-u USER`, `-p PASS` | Username/password for the Pi user (prompted if omitted)     |
| `-k`              | Skip SSH/user setup; boot to the on-screen first-run wizard    |
| `-l`              | List candidate disks and exit                                  |

When finished it prints the SSH address and the commands to run on the Pi
(Step 4 and 5 below).

## Step 3 - First boot and SSH

1. Eject the SD card from the host, insert it into the Pi, and power it on.
2. Wait 1-2 minutes for first boot.
3. Connect over SSH:

```bash
ssh <username>@raspberrypi.local
```

If `raspberrypi.local` does not resolve, find the Pi's IP address from your
router's DHCP client list and use `ssh <username>@<ip>` instead.

## Step 4 - Provision the Pi

On the Pi:

```bash
git clone https://github.com/Chriszly/rpi-setup.git
cd rpi-setup
sudo bash setup.sh
```

If the repository is private, clone with your credentials as in Step 1, then
drop the credentials from the remote right after:

```bash
git clone https://<USER>:<TOKEN>@github.com/Chriszly/rpi-setup.git
cd rpi-setup
git remote set-url origin https://github.com/Chriszly/rpi-setup.git
sudo bash setup.sh
```

Without arguments it shows the interactive menu: enter task numbers
(comma/space separated), `all`, or nothing to quit. You can also run tasks
directly by name, in any order:

```bash
sudo bash setup.sh base
```

List available tasks without changing anything:

```bash
sudo bash setup.sh --list
```

### Recommended order

`base` first (OS update, firmware, SSH, essentials), then `docker`, then the
tasks that depend on Docker:

```bash
sudo bash setup.sh base
sudo bash setup.sh docker netalertx teamspeak
```

`pihole` and `tailscale` run their official installers. `pihole` prints a
security warning and prompts for confirmation when run interactively; in
non-interactive runs it installs directly. `tailscale` stays interactive -
follow the on-screen prompts.

## Task rundown

| Task         | What it does                                                        | Notes                                                    |
|--------------|---------------------------------------------------------------------|----------------------------------------------------------|
| `base`       | OS update, EEPROM firmware, SSH enable, essential tools, fail2ban   | Run this first. The EEPROM update needs a reboot to apply.|
| `docker`     | Docker Engine, buildx and Compose (via apt)                         | Adds your user to the `docker` group - re-login to use it|
| `tailscale`  | Tailscale WireGuard VPN (official installer)                        | Interactive: run `tailscale up` and open the auth URL   |
| `pihole`     | Pi-hole ad blocker (official installer)                             | Confirms before installing (skips prompt in non-interactive runs). Admin UI at `http://<hostname>/admin` |
| `samba`      | Simple read-write NAS share for the current user                    | Prompts for an SMB password. Share at `\\<hostname>\nas-share` |
| `web`        | nginx serving a "Raspberry Pi" index page                           | Open `http://<hostname>`                                |
| `monitoring` | Netdata real-time dashboard                                         | Dashboard at `http://<hostname>:19999`                  |
| `netalertx`  | NetAlertX LAN device presence tracker (Docker)                      | Needs `docker`. Dashboard at `http://<ip>:20211`        |
| `teamspeak`  | TeamSpeak 6 voice server (Docker)                                   | Needs `docker`. Voice `:9987`, file `:30033`, web `:10080` |

After each task completes, check the `[+] Complete: <task>` lines.

## Common pitfalls

- Run with `sudo`, **not** `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`; running as `root` directly breaks that.
- After `setup.sh docker`, the `docker` group membership only applies after you
  log out and back in (reconnect your SSH session).
- `netalertx` and `teamspeak` fail fast if Docker + the Compose plugin are
  missing - run `sudo bash setup.sh docker` first.
- Re-running any task is safe. The scripts are idempotent.