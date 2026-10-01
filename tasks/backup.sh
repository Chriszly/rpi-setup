#!/usr/bin/env bash
# Task: backup - nightly archive of everything rpi-setup created, so a failed
# SD card is not the end: container data, Pi-hole, Samba, SSH, nginx, Netdata
# settings, rpi-setup's own state (UIDs, generated passwords) and its config.
# Settings: BACKUP_* in config/rpi-setup.env (names in config/tasks/backup.env).
set -euo pipefail

TASKS+=("backup|Nightly backup of rpi-setup's data and settings (systemd timer)")

RPI_BACKUP_SCRIPT=/usr/local/sbin/rpi-setup-backup
RPI_BACKUP_UNIT=rpi-setup-backup

run_backup() {
  : "${BACKUP_DEST:=/var/backups/rpi-setup}" "${BACKUP_KEEP:=7}" "${BACKUP_TIME:=03:00}" "${BACKUP_INCLUDE_SHARE:=no}"
  backup_check_settings
  local share=no
  if setting_on BACKUP_INCLUDE_SHARE; then share=yes; fi

  if backup_on_root_disk "$BACKUP_DEST"; then
    warn "BACKUP_DEST ($BACKUP_DEST) is on the same disk as the system, so a failed SD card takes the backups with it."
    warn 'Mount a USB disk (e.g. at /mnt/usb) and set BACKUP_DEST=/mnt/usb/rpi-setup, then copy the archives off the Pi now and then.'
  fi

  local cfg=() d
  for d in "$RPI_SETUP_ROOT/config" "$(config_dir)"; do
    [[ -d "$d" ]] && cfg+=("$(cd "$d" && pwd -P)")
  done

  install -m 0755 -d "$(dirname "$RPI_BACKUP_SCRIPT")"
  if backup_script "$BACKUP_DEST" "$BACKUP_KEEP" "$share" "${cfg[@]}" | write_if_changed "$RPI_BACKUP_SCRIPT" 0700; then
    say "Wrote $RPI_BACKUP_SCRIPT"
  fi

  local units=0
  printf '%s\n' \
    '[Unit]' \
    'Description=rpi-setup backup (tasks/backup.sh)' \
    'After=local-fs.target docker.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=$RPI_BACKUP_SCRIPT" \
    'Nice=10' \
    'IOSchedulingClass=idle' |
    write_if_changed "/etc/systemd/system/$RPI_BACKUP_UNIT.service" && units=1
  printf '%s\n' \
    '[Unit]' \
    'Description=Nightly rpi-setup backup' \
    '' \
    '[Timer]' \
    "OnCalendar=$BACKUP_TIME" \
    'Persistent=true' \
    'RandomizedDelaySec=5min' \
    '' \
    '[Install]' \
    'WantedBy=timers.target' |
    write_if_changed "/etc/systemd/system/$RPI_BACKUP_UNIT.timer" && units=1
  if [[ $units -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart "$RPI_BACKUP_UNIT.timer" 2>/dev/null || true
  fi
  systemctl enable --now "$RPI_BACKUP_UNIT.timer"
  say "Backup timer active: $BACKUP_TIME (keeps the newest $BACKUP_KEEP archives in $BACKUP_DEST)"

  info 'Making a first backup now'
  local archive
  archive="$("$RPI_BACKUP_SCRIPT" | tail -n1)" || die "The backup failed; run $RPI_BACKUP_SCRIPT to see why"
  say "Backup written: $archive"
  info "Restore on a fresh install: sudo tar -xzpf $archive -C / (list it first with: tar -tzf $archive)"
}

# Dies naming the setting if a BACKUP_* value is unusable.
backup_check_settings() {
  local dest="${BACKUP_DEST:-}" keep="${BACKUP_KEEP:-}" when="${BACKUP_TIME:-}"
  [[ "$dest" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "BACKUP_DEST must be an absolute path of letters, digits, '.', '_', '-' and '/' (got '$dest')"
  [[ "$dest" != *"/../"* && "$dest" != *"/.." ]] || die "BACKUP_DEST cannot contain '..' (got '$dest')"
  case "${dest%/}" in
    ''|/etc|/usr|/bin|/sbin|/lib|/boot|/boot/firmware|/proc|/sys|/dev|/run|/tmp|/var|/var/lib|/opt|/home)
      die "BACKUP_DEST cannot be a system folder like $dest; use e.g. /var/backups/rpi-setup or /mnt/usb/rpi-setup" ;;
  esac
  if [[ ! "$keep" =~ ^[0-9]{1,3}$ ]] || (( 10#$keep < 1 )); then
    die "BACKUP_KEEP must be a number of archives between 1 and 999 (got '$keep')"
  fi
  [[ -n "$when" && "$when" =~ ^[A-Za-z0-9:*,./~\ -]+$ ]] ||
    die "BACKUP_TIME must be a systemd OnCalendar time such as 03:00 or 'Sun 04:30' (got '$when')"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "$when" >/dev/null 2>&1 ||
      die "BACKUP_TIME '$when' is not a valid systemd calendar time (check: systemd-analyze calendar '$when')"
  fi
  setting_on BACKUP_INCLUDE_SHARE || true
}

# True if path $1 (or its nearest existing parent) is on the same disk as /.
backup_on_root_disk() {
  local p="$1"
  while [[ ! -e "$p" && "$p" != / ]]; do p="$(dirname "$p")"; done
  [[ "$(backup_disk_of "$p")" == "$(backup_disk_of /)" ]]
}

# The whole disk that holds path $1 (e.g. mmcblk0 for /dev/mmcblk0p2), or its
# file system source when lsblk cannot tell.
backup_disk_of() {
  local src pk
  src="$(findmnt -no SOURCE -T "$1" 2>/dev/null | head -n1)" || src=""
  [[ -n "$src" ]] || { stat -c 'dev:%d' "$1"; return; }
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)" || pk=""
  printf '%s\n' "${pk:-$src}"
}

# Print the standalone backup script: its settings, then the backup_run_*
# functions below (so the unit tests exercise the very code that runs nightly).
backup_script() {
  local dest="$1" keep="$2" share="$3"
  shift 3
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/backup.sh). Change the BACKUP_* settings and\n'
  printf '# re-run "sudo bash setup.sh backup" instead of editing this file.\n'
  printf 'set -euo pipefail\n'
  printf 'BK_ROOT=/\n'
  printf 'BK_DEST=%q\n' "$dest"
  printf 'BK_KEEP=%q\n' "$keep"
  printf 'BK_INCLUDE_SHARE=%q\n' "$share"
  printf 'BK_CONFIG_DIRS=('
  printf ' %q' "$@"
  printf ' )\n'
  declare -f backup_run_paths backup_run_shares backup_run_prune backup_run
  printf 'backup_run\n'
}

# --- Code of the backup script (uses only BK_* variables and plain tools) ---

# Paths to archive, relative to $BK_ROOT, one per line: what exists of the
# files and folders rpi-setup's tasks create.
backup_run_paths() {
  local root="${BK_ROOT%/}" p d
  {
    for d in "$root"/opt/*/; do
      [[ -f "$d/docker-compose.yml" ]] && printf '%s\n' "${d#"$root"/}"
    done
    for p in etc/pihole etc/samba/smb.conf var/lib/samba/private var/lib/rpi-setup \
             etc/nginx/sites-available etc/netdata etc/ssh/sshd_config.d; do
      printf '%s\n' "$p"
    done
    for p in "${BK_CONFIG_DIRS[@]}"; do
      [[ -n "$p" ]] && printf '%s\n' "${p#/}"
    done
    if [[ "${BK_INCLUDE_SHARE:-no}" == yes ]]; then
      backup_run_shares "$root/etc/samba/smb.conf"
    fi
  } | while IFS= read -r p; do
    p="${p%/}"
    [[ -n "$p" && ( -e "$root/$p" || -L "$root/$p" ) ]] && printf '%s\n' "$p"
  done | awk '!seen[$0]++'
}

# Folders of the shares the samba task manages in smb.conf $1 (no leading /).
backup_run_shares() {
  [[ -f "$1" ]] || return 0
  awk '
    /^[[:space:]]*\[.*\][[:space:]]*$/ { if (ours && path != "") print path; ours = 0; path = ""; next }
    /Managed by rpi-setup/ { ours = 1 }
    /^[[:space:]]*path[[:space:]]*=/ { path = $0; sub(/^[^=]*=[[:space:]]*/, "", path); sub(/[[:space:]]+$/, "", path) }
    END { if (ours && path != "") print path }' "$1" | sed 's|^/||'
}

# Delete all but the newest $2 archives in folder $1, and leftovers of an
# interrupted run. Archive names sort by date, so the newest are the last.
backup_run_prune() {
  local dir="$1" keep="$2" f n=0 total
  rm -f "$dir"/.rpi-setup-backup-*.partial
  total="$(find "$dir" -maxdepth 1 -type f -name 'rpi-setup-backup-*.tar.gz' | wc -l)"
  while IFS= read -r f; do
    (( n < total - keep )) || break
    rm -f "$f"
    n=$((n + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name 'rpi-setup-backup-*.tar.gz' | sort)
}

# Make one dated archive (mode 0600: it holds passwords) in $BK_DEST, prune
# old ones and print the new archive's path as the last line.
backup_run() {
  local root="${BK_ROOT:-/}" name tmp rc=0 dest_rel
  local -a paths exclude=()
  mapfile -t paths < <(backup_run_paths)
  [[ ${#paths[@]} -gt 0 ]] || { echo 'rpi-setup-backup: nothing to back up' >&2; return 1; }
  umask 077
  mkdir -p "$BK_DEST"
  chmod 0700 "$BK_DEST"
  name="rpi-setup-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tmp="$BK_DEST/.$name.partial"
  dest_rel="$(cd "$BK_DEST" && pwd -P)"
  dest_rel="${dest_rel#"$(cd "$root" && pwd -P)"}"
  dest_rel="${dest_rel#/}"
  [[ -z "$dest_rel" ]] || exclude=(--exclude="$dest_rel")
  printf 'rpi-setup-backup: %s\n' "${paths[@]}" >&2
  # Exit status 1 only means a file changed while it was read (a live
  # container writing); anything else is a real failure.
  tar -C "$root" --warning=no-file-changed "${exclude[@]}" -czpf "$tmp" -- "${paths[@]}" || rc=$?
  if (( rc > 1 )); then
    rm -f "$tmp"
    echo "rpi-setup-backup: tar failed (exit $rc)" >&2
    return 1
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$BK_DEST/$name"
  backup_run_prune "$BK_DEST" "$BK_KEEP"
  printf '%s\n' "$BK_DEST/$name"
}
