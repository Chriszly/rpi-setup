#!/usr/bin/env bash
# Task: web - nginx web server serving a simple index page.
set -euo pipefail

TASKS+=("web|Lite web server (nginx with a default page)")

run_web() {
  apt_install nginx
  systemctl enable --now nginx

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

  say "nginx running - open http://$(hostname) in your browser"
}