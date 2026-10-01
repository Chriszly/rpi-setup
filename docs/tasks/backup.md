# backup - nightly backup

Archives everything rpi-setup created every night, so a dead SD card is not
the end: container data, Pi-hole, Samba, SSH, nginx and Netdata settings,
rpi-setup's own state (UIDs, generated passwords) and its config.

```bash
sudo bash setup.sh backup
```

The task installs a systemd timer and makes a first backup straight away.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `BACKUP_DEST` | `/var/backups/rpi-setup` | Folder for the archives. Use a USB disk, e.g. `/mnt/usb/rpi-setup`: a copy on the SD card dies with the SD card (the task warns). System folders such as `/etc` or `/var` are refused. |
| `BACKUP_KEEP` | `7` | Number of archives to keep (1-999); older ones are deleted. |
| `BACKUP_TIME` | `03:00` | When to run, as a systemd `OnCalendar` time, e.g. `03:00` or `'Sun 04:30'`. A run missed while the Pi was off happens at the next boot. |
| `BACKUP_INCLUDE_SHARE` | `no` | `yes` also backs up the files in the Samba share (can be big). |

## What is backed up

Whatever exists of: `/opt/<task>/` for every rpi-setup container (compose
file and data), `/etc/pihole`, `/etc/samba/smb.conf`,
`/var/lib/samba/private` (Samba passwords), `/var/lib/rpi-setup`,
`/etc/nginx/sites-available`, `/etc/netdata`, `/etc/ssh/sshd_config.d`, the
rpi-setup `config/` folder, and with `BACKUP_INCLUDE_SHARE=yes` the share
folder (also when Samba runs in its container). Netdata's metrics cache in a
container (`/opt/monitoring/cache`) is left out; it is large and rebuilt on
its own.

## What it installs

- `/usr/local/sbin/rpi-setup-backup`, the backup script (root only).
- `rpi-setup-backup.service` and `rpi-setup-backup.timer`.
- Archives `rpi-setup-backup-YYYYMMDD-HHMMSS.tar.gz` in `BACKUP_DEST`, mode
  0600 because they hold passwords.

## Using it

```bash
sudo /usr/local/sbin/rpi-setup-backup           # back up now
systemctl list-timers rpi-setup-backup.timer    # next run
sudo tar -tzf <archive>                         # list an archive
sudo tar -xzpf <archive> -C /                   # restore on a fresh install
```

To restore a new Pi: flash it, clone rpi-setup, extract the archive, then run
the tasks again (`sudo bash setup.sh ...`); they pick up the restored settings
and data. Copy the archives off the Pi now and then.

Turn the timer off with `sudo systemctl disable --now rpi-setup-backup.timer`.
