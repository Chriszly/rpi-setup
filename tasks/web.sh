#!/usr/bin/env bash
# Task: web - nginx web server serving a simple index page.
# Settings: WEB_* in config/rpi-setup.env (names in config/tasks/web.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("web|Lite web server (nginx with a default page, :80 or :8080)")

run_web() {
  : "${WEB_TITLE:=Raspberry Pi}" "${WEB_DOCKER:=no}"
  if setting_on WEB_DOCKER; then run_web_container; return; fi
  container_leave web
  local site=/etc/nginx/sites-available/default owner="" want="${WEB_PORT:-}" cur
  [[ -z "$want" ]] || require_port WEB_PORT
  [[ "$WEB_TITLE" != *[\<\>\&]* ]] || die "WEB_TITLE cannot contain <, > or & (got '$WEB_TITLE')"

  if ! apt_installed nginx; then
    owner="$(port_owner 80)" || owner=""
    if [[ -n "$owner" ]]; then
      # Something else (usually Pi-hole's web UI) holds port 80. nginx's
      # postinst would fail to start on it and abort the install, so keep the
      # service down during install and move the default site elsewhere.
      [[ -n "$want" ]] || want=8080
      info "Port 80 is used by '$owner'; nginx will listen on $want instead"
      local own_policy=0
      if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
        chmod 0755 /usr/sbin/policy-rc.d
        own_policy=1
      fi
      local rc=0
      apt_install nginx || rc=$?
      [[ $own_policy -eq 0 ]] || rm -f /usr/sbin/policy-rc.d
      [[ $rc -eq 0 ]] || die 'nginx install failed'
    else
      apt_install nginx
    fi
  fi

  cur="$(nginx_site_port "$site")"
  if [[ -n "$want" && -n "$cur" && "$want" != "$cur" ]]; then
    owner="$(port_owner "$want")" || owner=""
    if [[ -n "$owner" && "$owner" != nginx ]]; then
      die "WEB_PORT=$want is already used by '$owner'; pick another port"
    fi
    nginx_move_port "$site" "$cur" "$want"
    info "nginx moved from port $cur to $want"
  fi

  web_index_page /var/www/html/index.html

  nginx -t -q || die "nginx configuration test failed; check $site"
  systemctl enable --now nginx
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  local port url ip=""
  port="$(nginx_site_port "$site")"
  ip="$(pi_ip)" || true
  url="http://${ip:-$(hostname)}"
  [[ -z "$port" || "$port" == 80 ]] || url="$url:$port"
  say "nginx running - open $url in your browser"
}

# The page is (re)written while it is ours or missing; a page you put there
# yourself is never overwritten.
web_index_page() {
  local f="$1"
  if [[ -f "$f" ]] && ! grep -q 'rpi-setup' "$f"; then
    info "$f is your own page; leaving it alone"
    return
  fi
  cat <<HTML | write_if_changed "$f" 0644 || true
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>${WEB_TITLE}</title></head>
<body>
  <h1>${WEB_TITLE}</h1>
  <p>Provisioned by <a href="https://github.com/Chriszly/rpi-setup">rpi-setup</a>.</p>
</body>
</html>
HTML
}

# The IPv4 port of the default site's first "listen" line, e.g. "80".
nginx_site_port() {
  sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)([[:space:];]).*/\1/p' "$1" 2>/dev/null | head -n1
}

# Change the IPv4 and IPv6 "listen <from>" lines of an nginx site to <to>.
nginx_move_port() {
  local site="$1" from="$2" to="$3"
  sed -Ei "s/^([[:space:]]*listen[[:space:]]+(\\[::\\]:)?)${from}([[:space:];])/\\1${to}\\3/" "$site"
}

# WEB_DOCKER=yes: nginx in its own container (host network), serving
# /opt/web/html with the site config from /opt/web/conf. A native nginx is
# stopped and its /var/www/html copied over once.
run_web_container() {
  : "${WEB_IMAGE:=nginx:stable-alpine}"
  local dir name=web port="${WEB_PORT:-}" owner="" changed=0 native=/etc/nginx/sites-available/default
  [[ -z "$port" ]] || require_port WEB_PORT
  require_image_ref WEB_IMAGE
  [[ "$WEB_TITLE" != *[\<\>\&]* ]] || die "WEB_TITLE cannot contain <, > or & (got '$WEB_TITLE')"
  container_require_64bit WEB_DOCKER
  container_require_docker
  dir="$(container_dir web)"

  # Port: WEB_PORT, else the one used so far (container or native nginx),
  # else 80, or 8080 when something other than nginx (Pi-hole) holds 80.
  if [[ -z "$port" ]]; then
    port="$(nginx_site_port "$dir/conf/default.conf")"
    [[ -n "$port" ]] || port="$(nginx_site_port "$native")"
    if [[ -z "$port" ]]; then
      port=80
      owner="$(port_owner 80)" || owner=""
      [[ -z "$owner" || "$owner" == nginx ]] || port=8080
    fi
  fi
  owner="$(port_owner "$port")" || owner=""
  [[ -z "$owner" || "$owner" == nginx ]] ||
    die "Port $port is already used by '$owner'; set WEB_PORT to a free port"

  install -m 0755 -d "$dir" "$dir/conf" "$dir/html"
  if web_container_compose "$dir" "$name" | write_if_changed "$dir/docker-compose.yml" 0644; then changed=1; fi
  if web_container_site "$port" | write_if_changed "$dir/conf/default.conf" 0644; then changed=1; fi
  container_pull "$dir"

  container_copy_once "$dir" /var/www/html "$dir/html" || true
  web_index_page "$dir/html/index.html"
  local extra=""
  if [[ -d /etc/nginx/sites-enabled ]]; then
    extra="$(find /etc/nginx/sites-enabled -mindepth 1 ! -name default -printf '%f ' 2>/dev/null)" || extra=""
  fi
  [[ -z "$extra" ]] || warn "Native nginx sites not carried over: ${extra}(add them to $dir/conf)"
  container_stop_native "$dir" nginx

  # The site config is a bind mount; nginx reads it at start.
  if [[ $changed -eq 1 && -n "$(container_state "$name")" ]]; then
    docker compose -f "$dir/docker-compose.yml" up -d --force-recreate >/dev/null
  fi
  container_up "$dir" "$name"

  local url ip=""
  ip="$(pi_ip)" || true
  url="http://${ip:-$(hostname)}"
  [[ "$port" == 80 ]] || url="$url:$port"
  say "nginx container running - open $url in your browser (files in $dir/html)"
}

# nginx site for the container, listening on port $1 (IPv6 too where the
# host has it; nginx will not start on a missing address family).
web_container_site() {
  local v6=""
  [[ ! -s /proc/net/if_inet6 ]] || v6="    listen [::]:$1;"
  cat <<EOF
# Managed by rpi-setup (tasks/web.sh, WEB_* settings).
server {
    listen $1;
${v6}
    server_name _;
    root /usr/share/nginx/html;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# Compose file of the web container in folder $1, container name $2.
web_container_compose() {
  local dir="$1" name="$2"
  echo 'services:'
  echo '  web:'
  container_service_head "$name" "$WEB_IMAGE" CHOWN SETUID SETGID NET_BIND_SERVICE
  cat <<EOF
    network_mode: host
    read_only: true
    tmpfs:
      - /var/cache/nginx
      - /run
      - /tmp
    environment:
      NGINX_ENTRYPOINT_QUIET_LOGS: "1"
    volumes:
      - type: bind
        source: $dir/html
        target: /usr/share/nginx/html
        read_only: true
      - type: bind
        source: $dir/conf
        target: /etc/nginx/conf.d
        read_only: true
EOF
}
