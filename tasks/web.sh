#!/usr/bin/env bash
# Task: web - nginx web server serving a simple index page.
set -euo pipefail

TASKS+=("web|Lite web server (nginx with a default page, :80 or :8080)")

run_web() {
  local site=/etc/nginx/sites-available/default owner=""

  if ! apt_installed nginx; then
    owner="$(port_owner 80)" || owner=""
    if [[ -n "$owner" ]]; then
      # Something else (usually Pi-hole's web UI) holds port 80. nginx's
      # postinst would fail to start on it and abort the install, so keep the
      # service down during install and move the default site to 8080.
      info "Port 80 is used by '$owner'; nginx will listen on 8080 instead"
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
      nginx_move_port "$site" 80 8080
    else
      apt_install nginx
    fi
  fi

  cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Raspberry Pi</title></head>
<body>
  <h1>Raspberry Pi</h1>
  <p>Provisioned by <a href="https://github.com/Chriszly/rpi-setup">rpi-setup</a>.</p>
</body>
</html>
HTML

  nginx -t -q || die "nginx configuration test failed; check $site"
  systemctl enable --now nginx

  local port=80 url ip=""
  if grep -Eq '^[[:space:]]*listen[[:space:]]+(\[::\]:)?8080[[:space:];]' "$site" 2>/dev/null; then port=8080; fi
  ip="$(pi_ip)" || true
  url="http://${ip:-$(hostname)}"
  [[ "$port" == 80 ]] || url="$url:$port"
  say "nginx running - open $url in your browser"
}

# Change the IPv4 and IPv6 "listen <from>" lines of an nginx site to <to>.
nginx_move_port() {
  local site="$1" from="$2" to="$3"
  sed -Ei "s/^([[:space:]]*listen[[:space:]]+(\\[::\\]:)?)${from}([[:space:];])/\\1${to}\\3/" "$site"
}
