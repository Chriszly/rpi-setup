# backup - nightly backup

Archives everything rpi-setup created every night, so a dead SD card is not
the end: container data, Pi-hole, Samba, SSH and nginx settings,
rpi-setup's own state (UIDs, generated passwords) and its config.

```bash
sudo bash setup.sh backup
```

The task installs a systemd timer and makes a first backup straight away.

## Settings

| Setting | Default | Meaning |
|---------|---------|---------|
| `BACKUP_DEST` | `/var/backups/rpi-setup` | Folder for the archives. Use a USB disk, e.g. `/mnt/usb/rpi-setup`: a copy on the SD card dies with the SD card (the task warns). Mount the disk through `/etc/fstab` so it is there at 03:00; a run refuses to write while it is not (below). System folders such as `/etc` or `/var` are refused. |
| `BACKUP_KEEP` | `7` | Number of archives to keep (1-999); older ones are deleted. |
| `BACKUP_TIME` | `03:00` | When to run, as a systemd `OnCalendar` time, e.g. `03:00` or `'Sun 04:30'`. A run missed while the Pi was off happens at the next boot. |
| `BACKUP_INCLUDE_SHARE` | `no` | `yes` also backs up the files in the Samba share (can be big). |

## What is backed up

Whatever exists of: `/opt/<task>/` for every rpi-setup container (compose
file and data), `/etc/pihole`, `/etc/samba/smb.conf`,
`/var/lib/samba/private` (Samba passwords), `/var/lib/rpi-setup`,
`/etc/nginx/sites-available`, `/etc/ssh/sshd_config.d`, your settings
(`config/rpi-setup.env` and `config/local/` in the checkout, or all of
`/etc/rpi-setup` after `setup.sh --move-config`; the tracked files of
`config/` come with the clone and are left out), and with
`BACKUP_INCLUDE_SHARE=yes` the share folder (also when Samba runs in its
container).

Pi-hole's databases (`gravity.db`, `pihole-FTL.db`, native or in
`/opt/pihole/etc-pihole`) are copied with `sqlite3 .backup` (or the sqlite3
shell built into `pihole-FTL`) before they go into the archive, so a
database Pi-hole is writing at that moment is not torn. Without either tool
the files are archived as they are. Other containers' databases (NetAlertX,
Den-Watcher) are archived as files: a copy taken while the container writes
can be inconsistent, so for a restore prefer the archive of a night the
service was quiet, or stop the container before running the backup by hand.

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

## Good to know

- **The backup disk must be mounted.** The task records which file system
  `BACKUP_DEST` is on; a run that finds another one there (the USB disk is
  unplugged or not mounted) stops with "is the backup disk mounted?" instead
  of filling the SD card under the mount point. The service unit also waits
  for the mount (`RequiresMountsFor=`) when it is in `/etc/fstab`. After
  moving the archives to another disk on purpose, re-run `setup.sh backup`.
- **FAT and exFAT disks** cannot store file modes, so the archives (they
  hold passwords) are only as private as the mount options make them; the
  backup warns and goes on. Mount such a disk with `umask=077`, or format it
  as ext4.
