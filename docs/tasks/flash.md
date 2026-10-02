# flash - SD card first-boot settings

Not a task on the Pi: these settings are read by the flash scripts on the PC
that writes the SD card, `host/flash.sh` (Linux) and `host/flash.ps1`
(Windows). Step-by-step guides: [Linux](../setup-linux.md),
[Windows](../setup-windows.md).

The scripts download the latest Raspberry Pi OS Lite (64-bit), verify its
checksum, write it and create your login user with SSH on. With the settings
below the Pi also comes up under its own name, on your Wi-Fi and with your SSH
key, so it needs no screen or network cable on first boot.

## Settings

Each one can be a flag, an environment variable or a line in
`config/rpi-setup.env` next to the scripts (remove the `#` in front of the
`FLASH_*` lines there; nothing else in that file is read by the flashers).
Flags win over the environment, which wins over the file. Any setting none
of them gives is asked for when the script starts (Enter keeps the default,
an empty Wi-Fi name means a network cable), so the scripts also run with no
flags at all. Without a terminal to ask on, unset settings stay off and the
card is written with user and SSH only.

| Setting | Linux flag | Windows parameter | Default | Meaning |
|---------|-----------|-------------------|---------|---------|
| `FLASH_HOSTNAME` | `-n` | `-Hostname` | `raspberrypi` | Host name, e.g. `homepi` (reachable as `homepi.local`). |
| `FLASH_WIFI_SSID` | `-s` | `-WifiSsid` | no Wi-Fi | Wi-Fi network to join on first boot. |
| `FLASH_WIFI_PASSWORD` | `-w` | `-WifiPassword` | asked, hidden | Its password, 8-63 characters. |
| `FLASH_WIFI_COUNTRY` | `-c` | `-WifiCountry` | `DE` | Wi-Fi country code (regulatory domain). |
| `FLASH_SSH_PUBKEY_FILE` | `-a` | `-SshPublicKeyFile` | password login only | Your SSH **public** key, e.g. `~/.ssh/id_ed25519.pub`. |
| `FLASH_GITHUB_KEY` | `-g` | `-GitHubKey` | asked (Enter = `yes`); `no` without a terminal | `yes` creates a new SSH key for the Pi to use with GitHub and prints its public key at the end, to add at github.com/settings/keys. |

The other options (disk, image, user, password, skipping the user setup) are
flags only; see the guides.

## Good to know

- `sudo` drops environment variables: use `sudo FLASH_HOSTNAME=homepi ./host/flash.sh`.
- Prefer the hidden prompt or the settings file over `-w`, which ends up in
  your shell history.
- On Trixie images the settings are written as cloud-init files, on Bookworm
  as a one-time `firstrun.sh` (the Pi reboots once on first boot).
- The Pi's GitHub key (`FLASH_GITHUB_KEY=yes`) is created on the PC in a
  temporary folder, copied to the card and deleted from the PC, so only the
  card and then the Pi have it. Until the first boot it sits on the card's
  boot partition as `rpi-setup-github-key`; a one-shot service then moves it
  to `~/.ssh/id_ed25519_github` of the login user (mode 600, owned by the
  user), deletes it from the boot partition and adds a `github.com` entry to
  `~/.ssh/config`, so `git clone git@github.com:...` works on the Pi. Add the
  printed public key to your account (Settings > SSH and GPG keys) or as a
  deploy key of one repository.
- The SSH key is stored in `/etc/ssh/authorized_keys/<user>` (read by sshd
  in addition to `~/.ssh/authorized_keys`). It is enough for the `base`
  task's `BASE_SSH_PASSWORD_AUTH=no`.
