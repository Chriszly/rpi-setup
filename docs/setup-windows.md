# Setup guide - Windows host

This guide walks through the full workflow from a **Windows** host: prepare a
bootable SD card with `host/flash.ps1`, boot the Pi headless, then provision it
with `setup.sh`. Everything you are asked to run is idempotent, so re-running
is always safe.

For the equivalent guide on a Linux host, see [setup-linux.md](setup-linux.md).

## Prerequisites

- A Raspberry Pi (any model that runs Raspberry Pi OS 64-bit) and an SD card
  (plus a card reader for your PC).
- **Raspberry Pi Imager 2.x** - https://www.raspberrypi.com/software/. The flash
  script installs it automatically and keeps it up to date if it is missing or
  outdated (silently, admin required).
- **openssl** - bundled with Git for Windows. Only needed for the SSH/user
  setup step; skip it entirely with `-SkipCustomize`.
- An **elevated** PowerShell (the script flashes a raw disk).
- The image is downloaded automatically by the flash script - you do not need
  to download Raspberry Pi OS yourself.

## Step 1 - Get the repo

```powershell
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

The script writes the card via **Raspberry Pi Imager**. Run it from an
elevated PowerShell:

```powershell
.\host\flash.ps1
```

It asks you to:

1. Pick the target disk from the numbered list of removable drives.
2. Type `yes` when asked to confirm it will DESTROY all data on that disk.
3. Enter a username (1-32 lowercase letters, digits, `_` or `-`).
4. Enter a password twice (at least 8 characters, ASCII, no `:`).

Or pass everything up front:

```powershell
.\host\flash.ps1 -Disk 2 -UserName pi -Password 'change-me'
```

All switches:

| Switch              | Meaning                                                             |
|---------------------|---------------------------------------------------------------------|
| `-Image <path>`     | Flash a locally downloaded `.img` / `.img.xz` instead               |
| `-SkipDownload`     | Require a cached image in `host\downloads\` (no network)            |
| `-SkipCustomize`    | Skip SSH/user setup; boot to the on-screen first-run wizard         |
| `-SkipImagerInstall`| Don't auto-install/auto-update Raspberry Pi Imager; fail if missing |
| `-DownloadDir`      | Override the image download/cache folder (default `host\downloads\`)|
| `-Force`            | Skip the "type `yes` to DESTROY" prompt (unattended use with `-Disk`) |
| `-Hostname`         | Host name, e.g. `homepi` (reachable as `homepi.local`)              |
| `-WifiSsid`         | Wi-Fi network to join on first boot                                 |
| `-WifiPassword`     | Its password (prompted, hidden, if omitted; empty = open network)   |
| `-WifiCountry`      | Wi-Fi country code (regulatory domain); default `DE`                |
| `-SshPublicKeyFile` | SSH public key to authorize for the user, e.g. `$HOME\.ssh\id_ed25519.pub` |

### Optional: host name, Wi-Fi and SSH key

With `-Hostname`, `-WifiSsid` and `-SshPublicKeyFile` the Pi comes up on your
Wi-Fi under its own name and accepts your SSH key on the very first boot, with
no screen or network cable:

```powershell
.\host\flash.ps1 -Disk 2 -UserName pi -Hostname homepi -WifiSsid 'My WiFi' -SshPublicKeyFile $HOME\.ssh\id_ed25519.pub
ssh pi@homepi.local        # a few minutes later
```

Instead of switches you can set `FLASH_HOSTNAME`, `FLASH_WIFI_SSID`,
`FLASH_WIFI_PASSWORD`, `FLASH_WIFI_COUNTRY` and `FLASH_SSH_PUBKEY_FILE` as
environment variables (`$env:FLASH_HOSTNAME = 'homepi'`) or in
`config\rpi-setup.env` next to the scripts (see the `flash` section at the end
of `config\rpi-setup.env.example`; only the `FLASH_*` lines are read).
Switches win over the environment, which wins over the file. The Wi-Fi
password is never printed.

Everything is checked before the card is written: the host name (letters,
digits and `-`), the country (two letters), the Wi-Fi password (8-63
characters) and the key file (must be an OpenSSH public key, not the private
key). On a **Trixie** image the settings go into cloud-init's `user-data` and
`network-config` on the boot partition; on **Bookworm** (no cloud-init) into a
one-time `firstrun.sh` started from `cmdline.txt`, as Raspberry Pi Imager does
it, so the Pi reboots once on first boot. The login user and SSH are still set
up by `userconf.txt` and `ssh`, exactly as without these options.

If Raspberry Pi Imager is missing or outdated, the script downloads the latest
installer into `host\downloads\` and installs it silently before flashing. The
installer is cached by version (`imager_<version>.exe`), so a newer release is
fetched automatically; re-running also upgrades an already-installed Imager.
When the script installs or upgrades Imager, it is uninstalled again once the
run finishes - even if it failed - including any pre-existing installation it
replaced, leaving the host clean.

When finished it prints the SSH address and the commands to run on the Pi
(Step 4 and 5 below).

## Step 3 - First boot and SSH

1. Eject the SD card from the PC, insert it into the Pi, and power it on.
2. Wait 1-2 minutes for first boot.
3. Connect over SSH:

```bash
ssh <username>@raspberrypi.local     # or <hostname>.local if you set -Hostname
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
security warning and asks for confirmation when run interactively, unless
`PIHOLE_CONFIRM=yes`; it then installs without dialogs from the `PIHOLE_*`
settings. `tailscale` prints a login URL to open, unless `TAILSCALE_AUTHKEY`
is set in `config/rpi-setup.env`.

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