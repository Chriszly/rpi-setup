#!/usr/bin/env bash
# Task: samba - a simple password-protected NAS share for the current user.
set -euo pipefail

TASKS+=("samba|Samba NAS share (read-write, per-user password)")

run_samba() {
  apt_install samba

  local u dir home
  u="$(real_user)"
  if [[ "$u" == "root" ]]; then warn 'Recommend running via sudo as normal user'; fi
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || die "Could not find the home directory of '$u'"
  dir="${home}/nas-share"
  install -d -m 0755 -o "$u" -g "$(id -gn "$u")" "$dir"

  local conf=/etc/samba/smb.conf
  local added=0
  if ! grep -q '^\[nas-share\]' "$conf"; then
    cat >> "$conf" <<EOF
[nas-share]
   comment = Raspberry Pi share
   path = ${dir}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${u}
EOF
    added=1
    say "Added [nas-share] section to ${conf}"
  else
    say 'smb.conf already contains the nas-share share'
  fi

  local pw pw2
  if [[ -z "${SAMBA_PASSWORD:-}" ]] && pdbedit -L -u "$u" >/dev/null 2>&1; then
    say "Samba user '${u}' already exists; keeping its password (set SAMBA_PASSWORD to change it)"
  else
    if [[ -n "${SAMBA_PASSWORD:-}" ]]; then
      pw="${SAMBA_PASSWORD}"
    else
      [[ -t 0 ]] || die 'No terminal to ask for the Samba password; set SAMBA_PASSWORD=... and re-run'
      read -rsp "Samba password for ${u}: " pw; echo
      read -rsp 'Repeat password: ' pw2; echo
      [[ -n "$pw" && "$pw" == "$pw2" ]] || die 'Passwords empty or do not match'
    fi
    (echo "$pw"; echo "$pw" ) | smbpasswd -s -a "$u"
  fi

  systemctl enable --now smbd
  if [[ $added -eq 1 ]]; then
    testparm -s "$conf" >/dev/null 2>&1 || die 'smb.conf failed testparm validation'
    systemctl is-active --quiet smbd && systemctl restart smbd
  fi
  say "Share ready: \\\\$(hostname)\\nas-share (user ${u})"
}