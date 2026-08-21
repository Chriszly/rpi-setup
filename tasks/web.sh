#!/usr/bin/env bash
# Task: web - nginx web server (official Docker image) serving a simple index page.
set -euo pipefail

TASKS+=("web|Lite web server (nginx container on :80)")

run_web() {
  require_docker

  local dir=/opt/web
  local name=web
  local ip=""

  if compose_is_up "$name"; then
    ip="$(pi_ip)" || true
    say "Web server is already running: http://${ip:-<pi-ip>}/"
    return
  fi

  # Free port 80 in case a native nginx from an older run is still active.
  if systemctl is-active --quiet nginx 2>/dev/null; then
    info 'Disabling native nginx so the container can bind port 80'
    systemctl disable --now nginx >/dev/null 2>&1 || true
  fi

  local uid
  uid="$(assign_uid web)"
  ensure_container_dir "$dir" "$uid"

  cat >"$dir/data/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Raspberry Pi</title></head>
<body>
  <h1>Raspberry Pi</h1>
  <p>Provisioned by <a href="https://github.com/Chriszly/rpi-setup">rpi-setup</a>.</p>
</body>
</html>
HTML

  cat >"$dir/docker-compose.yml" <<EOF
services:
  web:
    image: "nginx:stable-alpine"
    container_name: $name
    restart: unless-stopped
    read_only: true
    pids_limit: 128
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - NET_BIND_SERVICE
    tmpfs:
      - "/var/cache/nginx:uid=101,gid=101,rw,noexec,nosuid,nodev"
      - "/var/run:uid=101,gid=101,rw,noexec,nosuid,nodev"
    ports:
      - "80:80/tcp"
    volumes:
      - type: bind
        source: $dir/data/index.html
        target: /usr/share/nginx/html/index.html
        read_only: true
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
EOF

  say 'Starting nginx container'
  compose_up "$dir"

  ip="$(pi_ip)" || true
  say "Web server running: http://${ip:-<pi-ip>}/"
}
