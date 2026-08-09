#!/usr/bin/env bash
# Task: samba - a simple password-protected NAS share for the current user.
set -euo pipefail

TASKS+=("samba|Samba NAS share (read-write, per-user password)")

run_samba() {
  apt_install samba

  local u dir
  u="$(real_user)"
  [[ "$u" == "root" ]] && { warn 'Recommend running via sudo as normal user'; u="root"; }
  dir="/home/${u}/nas-share"
  mkdir -p "$dir"
  chown "$u:$u" "$dir"

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
  read -rsp "Samba password for ${u}: " pw; echo
  read -rsp 'Repeat password: ' pw2; echo
  [[ -n "$pw" ]] && [[ "$pw" == "$pw2" ]] || die 'Passwords empty or do not match'
  (echo "$pw"; echo "$pw" ) | smbpasswd -s -a "$u"

  systemctl enable --now smbd
  if [[ $added -eq 1 ]]; then
    testparm -s "$conf" >/dev/null 2>&1 || die 'smb.conf failed testparm validation'
    systemctl is-active --quiet smbd && systemctl restart smbd
  fi
  say "Share ready: \\\\$(hostname)\\nas-share (user ${u})"
}