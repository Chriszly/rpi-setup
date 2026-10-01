#!/usr/bin/env bash
# Task: samba - a simple password-protected NAS share for one user.
# Settings: SAMBA_* in config/rpi-setup.env (names in config/tasks/samba.env).
set -euo pipefail

TASKS+=("samba|Samba NAS share (read-write, per-user password)")

run_samba() {
  : "${SAMBA_SHARE_NAME:=nas-share}" "${SAMBA_READ_ONLY:=no}"
  local u="${SAMBA_USER:-}" dir="${SAMBA_SHARE_PATH:-}" share="$SAMBA_SHARE_NAME" home ro=no
  if setting_on SAMBA_READ_ONLY; then ro=yes; fi
  [[ "$share" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] ||
    die "SAMBA_SHARE_NAME must be letters, digits, '.', '_' or '-' (got '$share')"
  [[ "${share,,}" != global && "${share,,}" != homes && "${share,,}" != printers ]] ||
    die "SAMBA_SHARE_NAME '$share' is reserved by Samba; pick another name"

  [[ -n "$u" ]] || u="$(real_user)"
  if [[ "$u" == "root" ]]; then warn 'Recommend running via sudo as a normal user, or set SAMBA_USER'; fi
  id "$u" >/dev/null 2>&1 || die "SAMBA_USER: there is no Linux user '$u' on this Pi"
  home="$(getent passwd "$u" | cut -d: -f6)"
  if [[ -z "$dir" ]]; then
    [[ -n "$home" && -d "$home" ]] || die "Could not find the home directory of '$u'; set SAMBA_SHARE_PATH"
    dir="${home}/${share}"
  fi
  [[ "$dir" == /* ]] || die "SAMBA_SHARE_PATH must be an absolute path (got '$dir')"

  apt_install samba
  if [[ ! -d "$dir" ]]; then
    install -d -m 0755 -o "$u" -g "$(id -gn "$u")" "$dir"
    say "Created $dir"
  fi

  local conf=/etc/samba/smb.conf changed=0
  if samba_share_section "$conf" "$share" "$dir" "$u" "$ro"; then
    changed=1
    say "Wrote the [$share] share to ${conf}"
  else
    say "smb.conf already has the [$share] share as configured"
  fi
  testparm -s "$conf" >/dev/null 2>&1 || die 'smb.conf failed testparm validation'

  local pw
  if [[ -z "${SAMBA_PASSWORD:-}" ]] && pdbedit -L -u "$u" >/dev/null 2>&1; then
    say "Samba user '${u}' already exists; keeping its password (set SAMBA_PASSWORD to change it)"
  else
    pw="${SAMBA_PASSWORD:-}"
    if [[ -z "$pw" ]]; then
      pw="$(gen_secret 16)"
      save_secret samba SAMBA_PASSWORD "$pw"
      say "Generated Samba password for ${u}: $pw"
      info 'Saved in /var/lib/rpi-setup/secrets/samba.env; set SAMBA_PASSWORD to choose your own.'
    fi
    printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$u" >/dev/null
    smbpasswd -e "$u" >/dev/null
  fi

  systemctl enable --now smbd
  if [[ $changed -eq 1 ]] && systemctl is-active --quiet smbd; then
    systemctl reload smbd 2>/dev/null || systemctl restart smbd
  fi
  say "Share ready: \\\\$(hostname)\\${share} (user ${u}$([[ $ro == yes ]] && echo ', read-only'))"
}

# Replace the [$2] section of smb.conf $1 (up to the next section) with the
# share rpi-setup manages, or append it. Returns 0 if the file changed.
samba_share_section() {
  local conf="$1" share="$2" dir="$3" u="$4" ro="$5" body
  body="$(printf '[%s]\n   # Managed by rpi-setup (SAMBA_* settings); re-run "setup.sh samba" to change.\n   comment = Raspberry Pi share\n   path = %s\n   browseable = yes\n   read only = %s\n   guest ok = no\n   valid users = %s\n' \
    "$share" "$dir" "$ro" "$u")"
  SAMBA_BODY="$body" awk -v sec="$share" '
    BEGIN { body = ENVIRON["SAMBA_BODY"] }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name)
      if (tolower(name) == tolower(sec)) { print body; skip = 1; done = 1; next }
      skip = 0
    }
    !skip { print }
    END { if (!done) print body }' "$conf" | write_if_changed "$conf"
}
