# base - system baseline

Brings a fresh Raspberry Pi OS up to date and makes it a safe, headless
server: OS and firmware updates, SSH kept on, a few everyday tools, fail2ban
against SSH password guessing, daily security updates, a smaller system
journal and optional Pi 5 boot options.

```bash
sudo bash setup.sh base
sudo reboot        # once, so kernel and firmware updates take effect
```

Run it first on a new Pi. When you pick several tasks, `setup.sh` always runs
`base` before the others. It needs no other task.

## Settings

Set them in `config/rpi-setup.env` ([how settings work](../../README.md#settings)).
Every setting is optional; an empty value means the default.

| Setting | Default | Meaning |
|---------|---------|---------|
| `BASE_UPGRADE` | `yes` | Run `apt-get upgrade`. Skipped in containers and CI. |
| `BASE_EEPROM_UPDATE` | `yes` | Update the bootloader EEPROM (`rpi-eeprom-update -a`); applies after a reboot. |
| `BASE_HOSTNAME` | keep current | New host name, e.g. `homepi`, then reachable as `homepi.local` (after a reboot). Letters, digits and `-`, at most 63 characters. |
| `BASE_TIMEZONE` | keep current | Time zone such as `Europe/Berlin` (list: `timedatectl list-timezones`). |
| `BASE_EXTRA_PACKAGES` | none | More apt packages, separated by spaces or commas, e.g. `rsync jq`. |
| `BASE_FAIL2BAN_MAXRETRY` | `5` | Failed SSH logins before fail2ban bans the address. |
| `BASE_FAIL2BAN_BANTIME` | `1h` | How long a ban lasts: `600`, `10m`, `1h`, `1d`, or `-1` for forever. |
| `BASE_AUTO_UPDATES` | `yes` | Install security updates every day (unattended-upgrades, Debian security archive only). |
| `BASE_AUTO_REBOOT` | `no` | Reboot on its own when an automatic update needs it. |
| `BASE_AUTO_REBOOT_TIME` | `03:30` | Time of that reboot, `HH:MM`. |
| `BASE_SSH_PASSWORD_AUTH` | `yes` | `no` allows SSH key login only. The task refuses unless your user already has an SSH key set up (`~/.ssh/authorized_keys`, or the key from the flash scripts), so you cannot lock yourself out. |
| `BASE_JOURNAL_MAX_SIZE` | `100M` | Disk space the system journal may use (`50M`, `1G`, ...); `no` keeps the journald default. |
| `BASE_PCIE_GEN3` | `no` | Pi 5 only: run the PCIe slot at Gen 3 for an NVMe HAT (about twice the speed, not officially certified). |
| `BASE_PI5_4K_KERNEL` | `no` | Pi 5 only: boot the 4K-page kernel instead of the default 16K-page one. Only needed when a program or container crashes with page-size or jemalloc errors. |

## What it installs and changes

- Packages: `ca-certificates curl gnupg git unzip vim htop tmux fail2ban
  python3-systemd`, `unattended-upgrades` (with `BASE_AUTO_UPDATES=yes`) and
  your `BASE_EXTRA_PACKAGES`.
- SSH is switched on (`raspi-config nonint do_ssh 0`).
- `/etc/ssh/sshd_config.d/10-rpi-setup.conf`: root login over SSH is always
  off; password login off with `BASE_SSH_PASSWORD_AUTH=no`. The file is checked
  with `sshd -t` and rolled back if sshd rejects it.
- `/etc/fail2ban/jail.local`: the SSH jail (reads the journal). A `jail.local`
  you wrote yourself is left alone.
- `/etc/apt/apt.conf.d/20auto-upgrades` and
  `52rpi-setup-unattended-upgrades`: daily security updates.
- `/etc/systemd/journald.conf.d/10-rpi-setup.conf`: the journal size limit.
- `fstrim.timer` is enabled (weekly TRIM for the SD card).
- Pi 5 options go into a marked block at the end of
  `/boot/firmware/config.txt`; setting both back to `no` removes the block.

## Changing and turning things off

Change a setting and run `sudo bash setup.sh base` again; files rpi-setup
wrote are rewritten. `BASE_AUTO_UPDATES=no` switches off only what this task
switched on. To go back to password login, set `BASE_SSH_PASSWORD_AUTH=yes`
and re-run.

## Good to know

- A Raspberry Pi 5 needs Raspberry Pi OS Bookworm or newer; `base` stops with
  an explanation on an older one. It also warns when a Pi 5 runs a 32-bit OS
  (the `teamspeak` task needs 64-bit).
- On 32-bit Raspberry Pi OS there is no separate security archive, so automatic
  security updates find nothing; the task warns about it.
- Kernel and firmware come from Raspberry Pi's own archive, not the security
  archive. Keep them current with `sudo bash update.sh` or a `base` re-run.
- `BASE_SSH_PASSWORD_AUTH=no` accepts a key in any file sshd reads for your
  user: `~/.ssh/authorized_keys`, or `/etc/ssh/authorized_keys/<user>` where
  the flash scripts put the key from `-a`. Without one, add it from your PC
  with `ssh-copy-id <user>@<pi>`.
- Check fail2ban with `sudo fail2ban-client status sshd`.
