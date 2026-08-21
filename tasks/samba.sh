#!/usr/bin/env bash
# Task: samba - simple password-protected NAS share via the crazymax/samba image.
set -euo pipefail

TASKS+=("samba|Samba NAS share (container, SMB :445, per-user password)")

run_samba() {
  require_docker

  local dir=/opt/samba
  local name=samba
  local ip=""

  if compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "Samba is already running: \\\\${ip:-<pi-ip>}\\nas-share"
    return
  fi

  # Free port 445 in case native smbd from an older run is still active.
  if systemctl is-active --quiet smbd 2>/dev/null; then
    info 'Disabling native smbd so the container can bind port 445'
    systemctl disable --now smbd >/dev/null 2>&1 || true
  fi

  local u uid_num gid_num sdir
  u="$(real_user)"
  if [[ "$u" == "root" ]]; then
    warn 'Recommend running via sudo as normal user'
  fi
  uid_num="$(id -u "$u")"
  gid_num="$(id -g "$u")"
  sdir="/home/${u}/nas-share"
  mkdir -p "$sdir"
  chown "$uid_num:$gid_num" "$sdir"

  install -m 0755 -d "$dir/data"

  local pw pw2
  if [[ -n "${SAMBA_PASSWORD:-}" ]]; then
    pw="${SAMBA_PASSWORD}"
  else
    read -rsp "Samba password for ${u}: " pw; echo
    read -rsp 'Repeat password: ' pw2; echo
    [[ -n "$pw" ]] && [[ "$pw" == "$pw2" ]] || die 'Passwords empty or do not match'
  fi
  local pwfile="$dir/samba_password"
  printf '%s' "$pw" >"$pwfile"
  chmod 600 "$pwfile"

  cat >"$dir/data/config.yml" <<EOF
auth:
  - user: ${u}
    group: ${u}
    uid: ${uid_num}
    gid: ${gid_num}
    password_file: /run/secrets/samba_password
global:
  - "server min protocol = SMB2"
share:
  - name: nas-share
    path: /samba/nas-share
    browsable: yes
    readonly: no
    guestok: no
    validusers: ${u}
EOF

  cat >"$dir/docker-compose.yml" <<EOF
services:
  samba:
    image: "crazymax/samba:latest"
    container_name: $name
    network_mode: host
    restart: unless-stopped
    pids_limit: 256
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - type: bind
        source: $dir/data
        target: /data
      - type: bind
        source: $dir/samba_password
        target: /run/secrets/samba_password
        read_only: true
      - type: bind
        source: $sdir
        target: /samba/nas-share
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
EOF

  say 'Starting Samba container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  say "Share ready: \\\\${ip:-<pi-ip>}\\nas-share (user ${u})"
}
