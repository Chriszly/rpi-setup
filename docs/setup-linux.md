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

Started without options it asks for every value in turn (Enter keeps the
default shown in brackets):

1. Hostname for the Pi (default `raspberrypi`).
2. Wi-Fi network name, or Enter for a network cable only. With a Wi-Fi name
   it also asks for the Wi-Fi password (hidden) and country (default `DE`).
3. Your PC's SSH public key, so you can log in to the Pi without a password
   (default: the key found in your `~/.ssh`, `none` to skip).
4. A username and password (same rules as on Windows).
5. The target disk, from the listed candidates with size, model and bus (a
   number, or a full `/dev/node` such as `/dev/sda`).
6. `yes` to confirm it will DESTROY all data on that disk.

Then it downloads and checks the image and writes the card without asking
anything else. It also creates a new SSH key for the Pi to use with GitHub,
without asking (`-g no` turns it off), and prints its public key at the end
to add on GitHub. A value passed as an option, an environment variable or in
`config/rpi-setup.env` is not asked for.

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
| `-n HOSTNAME`     | Host name, e.g. `homepi` (reachable as `homepi.local`)         |
| `-s SSID`         | Wi-Fi network to join on first boot                            |
| `-w PASSWORD`     | Its password (prompted, hidden, if omitted; empty = open network) |
| `-c COUNTRY`      | Wi-Fi country code (regulatory domain); default `DE`           |
| `-a KEYFILE`      | SSH public key to authorize for the user, e.g. `~/.ssh/id_ed25519.pub` |
| `-g yes`/`no`     | New SSH key for the Pi to use with GitHub, printed at the end (default `yes`) |

### Optional: host name, Wi-Fi and SSH key

With `-n`, `-s` and `-a` the Pi comes up on your Wi-Fi under its own name and
accepts your SSH key on the very first boot, with no screen or network cable:

```bash
sudo ./host/flash.sh -d /dev/sda -u pi -n homepi -s 'My WiFi' -a ~/.ssh/id_ed25519.pub
ssh pi@homepi.local        # a few minutes later
```

Instead of flags you can set `FLASH_HOSTNAME`, `FLASH_WIFI_SSID`,
`FLASH_WIFI_PASSWORD`, `FLASH_WIFI_COUNTRY`, `FLASH_SSH_PUBKEY_FILE` and
`FLASH_GITHUB_KEY` in the
environment (`sudo FLASH_HOSTNAME=homepi ./host/flash.sh`, since `sudo` drops
other variables) or in `config/rpi-setup.env` next to the scripts (see the
`flash` section at the end of `config/rpi-setup.env.example`; only the
`FLASH_*` lines are read). Flags win over the environment, which wins over the
file. The Wi-Fi password is never printed; prefer the hidden prompt or the
private (`chmod 600`) settings file over `-w`, which ends up in your shell
history.

Everything is checked before the card is written: the host name (letters,
digits and `-`), the country (two letters), the Wi-Fi password (8-63
characters) and the key file (must be an OpenSSH public key, not the private
key). How it reaches the Pi depends on the image:

- **Trixie** (the current release): `user-data` and `network-config` for
  cloud-init on the boot partition.
- **Bookworm** (no cloud-init): a one-time `firstrun.sh`, started from
  `cmdline.txt` as Raspberry Pi Imager does it. The Pi reboots once on first
  boot, then removes the script.

The login user and SSH are still set up by `userconf.txt` and `ssh`, exactly as
without these options. The key is stored in `/etc/ssh/authorized_keys/<user>`
(and read by sshd in addition to `~/.ssh/authorized_keys`).

When finished it prints the SSH address and the commands to run on the Pi
(Step 4 and 5 below).

## Step 3 - First boot and SSH

1. Eject the SD card from the host, insert it into the Pi, and power it on.
2. Wait 1-2 minutes for first boot.
3. Connect over SSH:

```bash
ssh <username>@raspberrypi.local     # or <hostname>.local if you set -n
```

If `raspberrypi.local` does not resolve, find the Pi's IP address from your
router's DHCP client list and use `ssh <username>@<ip>` instead.

## Step 4 - Provision the Pi

On the Pi:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Chriszly/rpi-setup.git
cd rpi-setup
bash setup.sh --init-config     # creates config/rpi-setup.env
nano config/rpi-setup.env       # passwords, ports, host name, ... (all optional)
sudo bash setup.sh
```

`config/rpi-setup.env` holds every setting of every task, with its default and
a short explanation (see the [README](../README.md#settings)). It is ignored by
git, so passwords stay on the Pi. Settings you leave empty get their default;
empty passwords are generated and printed on the first install.

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
security warning and installs without dialogs from the `PIHOLE_*`
settings. `tailscale` prints a login URL to open, unless
`TAILSCALE_AUTHKEY` is set in `config/rpi-setup.env`.

## Task rundown

The [task table in the README](../README.md#tasks) lists every task, and each
task has its own page under [docs/tasks/](tasks/) with all its settings, what
it installs and how to reach it. After a run, check the `[+] Complete: <task>`
lines and the summary at the end.

## Common pitfalls

- Run with `sudo`, **not** `root`. The `docker` and `samba` tasks pick up your
  normal user through `SUDO_USER`; running as `root` directly breaks that.
- After `setup.sh docker`, the `docker` group membership only applies after you
  log out and back in (reconnect your SSH session).
- `netalertx` and `teamspeak` need Docker; `setup.sh` adds the `docker` task
  to the run by itself when Docker is not installed yet.
- Re-running any task is safe. The scripts are idempotent.