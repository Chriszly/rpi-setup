#!/usr/bin/env bash
# Task: web - nginx web server serving a simple index page.
# Settings: WEB_* in config/rpi-setup.env (names in config/tasks/web.env).
set -euo pipefail

TASKS+=("web|Lite web server (nginx with a default page, :80 or :8080)")

run_web() {
  : "${WEB_TITLE:=Raspberry Pi}"
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
