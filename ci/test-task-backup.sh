#!/usr/bin/env bash
# test-task-backup.sh - unit tests for tasks/backup.sh: which paths go into
# the archive, retention pruning, the generated script and setting checks.
# Everything runs in temporary folders; nothing on the system is touched.
#
# Run: bash ci/test-task-backup.sh
# ROOT comes from test-helpers.sh (SC2153 mistakes it for $root).
# shellcheck disable=SC2016,SC2153
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/backup.sh"

tmp="$TMP"

assert_contains "backup registers its task" "backup|" "${TASKS[*]}"

# --- backup_run_paths ---------------------------------------------------------
r="$tmp/root"
mkdir -p "$r/opt/netalertx/data" "$r/opt/teamspeak/data" "$r/opt/other" \
         "$r/etc/pihole" "$r/etc/samba" "$r/var/lib/rpi-setup/uids" \
         "$r/etc/ssh/sshd_config.d" "$r/home/pi/nas-share" "$r/srv/repo/config/local" "$r/srv/repo/config/tasks"
touch "$r/opt/netalertx/docker-compose.yml" "$r/opt/teamspeak/docker-compose.yml" \
      "$r/home/pi/nas-share/big.iso" "$r/srv/repo/config/rpi-setup.env" "$r/srv/repo/config/tasks/web.env"
printf '[global]\n   workgroup = WORKGROUP\n[nas-share]\n   # Managed by rpi-setup (SAMBA_* settings); re-run "setup.sh samba" to change.\n   path = /home/pi/nas-share\n   read only = no\n[other]\n   path = /srv/other\n' \
    >"$r/etc/samba/smb.conf"

paths() { BK_ROOT="$r" BK_INCLUDE_SHARE="$1" BK_CONFIG_PATHS=("/srv/repo/config/rpi-setup.env" "/srv/repo/config/local" "/missing/config"); backup_run_paths | xargs; }
assert_eq "backup_run_paths picks what exists (no share)" \
    "opt/netalertx opt/teamspeak etc/pihole etc/samba/smb.conf var/lib/rpi-setup etc/ssh/sshd_config.d srv/repo/config/rpi-setup.env srv/repo/config/local" \
    "$(paths no)"
assert_contains "backup_run_paths adds the rpi-setup share when asked" \
    "srv/repo/config/local home/pi/nas-share" "$(paths yes)"
assert_lacks "backup_run_paths leaves the checkout's tracked config files out" "config/tasks" "$(paths no)"
assert_lacks "backup_run_paths skips shares rpi-setup does not manage" "srv/other" "$(paths yes)"
assert_lacks "backup_run_paths skips /opt folders without a compose file" "opt/other" "$(paths no)"
assert_eq "backup_run_shares reads the managed share's path" "home/pi/nas-share" \
    "$(backup_run_shares "$r/etc/samba/smb.conf")"
install -d "$r/opt/samba" "$r/srv/container-share"
printf 'services:\n  samba:\n    volumes:\n      - type: bind\n        source: /opt/samba/data\n        target: /data\n      - type: bind\n        source: /srv/container-share\n        target: /samba/share\n' \
    >"$r/opt/samba/docker-compose.yml"
assert_eq "backup_run_container_share reads the Samba container's share" "srv/container-share" \
    "$(backup_run_container_share "$r/opt/samba/docker-compose.yml")"
assert_contains "backup_run_paths adds the Samba container's share when asked" "srv/container-share" "$(paths yes)"
assert_lacks "backup_run_paths leaves the container share out unless asked" "container-share" "$(paths no)"
mv "$r/opt/samba/docker-compose.yml" "$r/opt/samba/docker-compose.yml.disabled"
assert_contains "backup_run_paths keeps a task switched back to native" "opt/samba" "$(paths no)"
assert_lacks "backup_run_paths skips the share of a disabled Samba container" "container-share" "$(paths yes)"
rm -rf "$r/opt/samba" "$r/srv/container-share"
assert_eq "backup_run_shares tolerates a missing smb.conf" "" "$(backup_run_shares "$tmp/nope.conf")"
assert_eq "backup_run_paths on an empty system prints nothing" "" \
    "$(mkdir -p "$tmp/empty"; BK_ROOT="$tmp/empty" BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run_paths)"

# --- backup_run_prune ---------------------------------------------------------
d="$tmp/prune dir"  # a space in the folder must not split paths
mkdir -p "$d"
for i in 01 02 03 04 05 06 07 08 09 10; do touch "$d/rpi-setup-backup-202609${i}-030000.tar.gz"; done
touch "$d/.rpi-setup-backup-20260911-030000.tar.gz.partial" "$d/notes.txt"
backup_run_prune "$d" 3
assert_eq "backup_run_prune keeps the newest N archives" \
    "notes.txt rpi-setup-backup-20260908-030000.tar.gz rpi-setup-backup-20260909-030000.tar.gz rpi-setup-backup-20260910-030000.tar.gz" \
    "$(find "$d" -mindepth 1 -printf '%f\n' | sort | xargs)"
backup_run_prune "$d" 5
assert_eq "backup_run_prune keeps everything when under the limit" "4" "$(find "$d" -type f | wc -l | xargs)"

# --- backup_run (end to end in temp folders) ----------------------------------
dest="$tmp/dest"
printf 'SAMBA_PASSWORD=x\n' >"$r/var/lib/rpi-setup/secret.env"
out="$(BK_ROOT="$r" BK_DEST="$dest" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run 2>/dev/null)"
assert_contains "backup_run prints the archive path" "$dest/rpi-setup-backup-" "$out"
assert_eq "backup_run archive is private (0600)" "600" "$(stat -c %a "$out")"
assert_eq "backup_run destination is private (0700)" "700" "$(stat -c %a "$dest")"
listing="$(tar -tzf "$out")"
assert_contains "archive holds rpi-setup state" "var/lib/rpi-setup/secret.env" "$listing"
assert_contains "archive holds compose folders" "opt/teamspeak/docker-compose.yml" "$listing"
assert_lacks "archive leaves the share out by default" "nas-share" "$listing"
# Destination inside the backed-up tree is never archived into itself.
inner="$r/var/lib/rpi-setup/backups"
out2="$(BK_ROOT="$r" BK_DEST="$inner" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run 2>/dev/null)"
if tar -tzf "$out2" | grep -q 'rpi-setup/backups'; then fail "backup_run must exclude its own destination"; else pass "backup_run excludes its own destination"; fi

# --- backup_run refuses a destination whose disk is not there ----------------
fsid="$(backup_run_fs_id "$tmp")"
assert_ok "backup_run_fs_id finds something" test -n "$fsid"
assert_eq "backup_run_fs_id of a folder not created yet is its parent's" "$fsid" "$(backup_run_fs_id "$tmp/not/yet/there")"
run_with_id() { (BK_ROOT="$r" BK_DEST="$tmp/dest-id" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_FS_ID="$1" BK_CONFIG_PATHS=(); backup_run) 2>&1; }
out="$(run_with_id "other-disk" || true)"
assert_contains "another file system than at setup is refused" "is the backup disk mounted?" "$out"
assert_ok "and nothing is written under the mount point" test ! -e "$tmp/dest-id"
assert_ok "the recorded file system is accepted" eval 'run_with_id "$fsid" >/dev/null'
assert_ok "an empty BK_FS_ID (an older script) is not checked" eval 'run_with_id "" >/dev/null'

# --- chmod that fails (FAT, exFAT) does not stop the backup -------------------
chmod() { return 1; }
out="$( (BK_ROOT="$r" BK_DEST="$tmp/dest-fat" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run) 2>&1)"
unset -f chmod
assert_contains "a failed chmod warns about FAT" "cannot make $tmp/dest-fat root-only (a FAT or exFAT disk?)" "$out"
assert_contains "and the archive is still written" "$tmp/dest-fat/rpi-setup-backup-" "$out"

# --- SQLite databases are archived from a sqlite3 .backup copy ----------------
printf 'live\n' >"$r/etc/pihole/gravity.db"
printf 'wal\n' >"$r/etc/pihole/gravity.db-wal"
printf 'live\n' >"$r/etc/pihole/pihole-FTL.db"
sqlite3() { local f="${2#.backup }"; f="${f#\'}"; f="${f%\'}"; printf 'copy\n' >"$f"; }
out="$(BK_ROOT="$r" BK_DEST="$tmp/dest-db" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run 2>/dev/null)"
assert_eq "each database is in the archive once" "1" "$(tar -tzf "$out" | grep -cx 'etc/pihole/gravity.db')"
assert_eq "and it is the sqlite3 copy" "copy" "$(tar -xzOf "$out" etc/pihole/gravity.db)"
assert_eq "so is the FTL database" "copy" "$(tar -xzOf "$out" etc/pihole/pihole-FTL.db)"
assert_lacks "the live journal is left out" "gravity.db-wal" "$(tar -tzf "$out")"
assert_eq "the rest of /etc/pihole is still there" "1" "$(tar -tzf "$out" | grep -cx 'etc/pihole/')"
sqlite3() { return 1; }
out="$( (BK_ROOT="$r" BK_DEST="$tmp/dest-db2" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run) 2>&1)"
assert_contains "a failed copy is reported" "could not copy etc/pihole/gravity.db; archiving the file as it is" "$out"
assert_eq "and the file goes in as it is" "live" "$(tar -xzOf "$(tail -n1 <<<"$out")" etc/pihole/gravity.db)"
unset -f sqlite3
if ! command -v sqlite3 >/dev/null 2>&1 && ! command -v pihole-FTL >/dev/null 2>&1; then
    out="$(BK_ROOT="$r" BK_DEST="$tmp/dest-db3" BK_KEEP=2 BK_INCLUDE_SHARE=no BK_CONFIG_PATHS=(); backup_run 2>/dev/null)"
    assert_eq "without sqlite3 the file goes in as it is" "live" "$(tar -xzOf "$out" etc/pihole/gravity.db)"
else
    skip "sqlite3 or pihole-FTL is installed here"
fi

# --- the service unit waits for the backup disk's mount -----------------------
assert_contains "the unit requires the destination's mount" "RequiresMountsFor=/mnt/usb/rpi-setup" "$(backup_unit_file /mnt/usb/rpi-setup)"

# --- backup_script: the generated standalone script ---------------------------
script="$tmp/rpi-setup-backup"
backup_script /mnt/usb/rpi-setup 5 yes '' /srv/repo/config/rpi-setup.env /srv/repo/config/local >"$script"
assert_ok "generated script is valid bash" bash -n "$script"
assert_contains "generated script carries BK_DEST" "BK_DEST=/mnt/usb/rpi-setup" "$(cat "$script")"
assert_contains "generated script carries BK_KEEP" "BK_KEEP=5" "$(cat "$script")"
assert_contains "generated script carries the file system id" "BK_FS_ID=1234-ABCD" \
    "$(backup_script /mnt/usb/rpi-setup 5 yes 1234-ABCD /etc/rpi-setup)"
assert_contains "generated script carries the settings paths" "BK_CONFIG_PATHS=( /srv/repo/config/rpi-setup.env /srv/repo/config/local )" "$(cat "$script")"
assert_contains "generated script runs a backup" "backup_run" "$(tail -n1 "$script")"
sed -i "s|^BK_ROOT=/\$|BK_ROOT=$r|; s|^BK_DEST=.*|BK_DEST=$tmp/dest3|" "$script"
out3="$(bash "$script" 2>/dev/null | tail -n1)"
assert_contains "generated script makes an archive with the share" "home/pi/nas-share/big.iso" "$(tar -tzf "$out3")"

# --- backup_check_settings ----------------------------------------------------
check() { BACKUP_DEST="$1" BACKUP_KEEP="$2" BACKUP_TIME="$3" BACKUP_INCLUDE_SHARE="$4" backup_check_settings; }
assert_ok    "defaults are valid"               check /var/backups/rpi-setup 7 03:00 no
assert_ok    "a USB mount and weekly time pass" check /mnt/usb/rpi-setup 30 'Sun 04:30' yes
assert_fails "relative BACKUP_DEST fails"       check backups 7 03:00 no
assert_fails "BACKUP_DEST / fails"              check / 7 03:00 no
assert_fails "BACKUP_DEST /etc fails"           check /etc 7 03:00 no
assert_fails "BACKUP_DEST with .. fails"        check /mnt/../etc 7 03:00 no
assert_fails "BACKUP_DEST with a space fails"   check '/mnt/my disk' 7 03:00 no
assert_fails "BACKUP_KEEP 0 fails"              check /mnt/usb 0 03:00 no
assert_fails "BACKUP_KEEP text fails"           check /mnt/usb seven 03:00 no
assert_fails "BACKUP_KEEP empty fails"          check /mnt/usb '' 03:00 no
assert_fails "BACKUP_TIME empty fails"          check /mnt/usb 7 '' no
assert_fails "BACKUP_TIME with a newline fails" check /mnt/usb 7 $'03:00\nExecStart=/bin/sh' no
assert_fails "BACKUP_TIME with ; fails"         check /mnt/usb 7 '03:00;x' no
assert_fails "BACKUP_INCLUDE_SHARE typo fails"  check /mnt/usb 7 03:00 maybe
if command -v systemd-analyze >/dev/null 2>&1; then
    assert_fails "BACKUP_TIME nonsense fails systemd-analyze" check /mnt/usb 7 'Blursday 99:99' no
else
    skip "systemd-analyze not installed"
fi

# --- backup_on_root_disk (findmnt/lsblk stubbed) ------------------------------
# shellcheck disable=SC2329  # the stubs are called by backup_disk_of
findmnt() { case "$4" in /mnt*) echo /dev/sda1 ;; *) echo /dev/mmcblk0p2 ;; esac; }
# shellcheck disable=SC2329
lsblk() { case "$3" in /dev/sda1) echo sda ;; *) echo mmcblk0 ;; esac; }
assert_ok    "a folder on the SD card is on the root disk" backup_on_root_disk /var/backups/rpi-setup
assert_fails "a USB disk is not the root disk"             backup_on_root_disk /mnt/usb/rpi-setup
unset -f findmnt lsblk

finish_tests
