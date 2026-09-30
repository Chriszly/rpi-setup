#!/usr/bin/env bash
# Task: pihole - network-wide ad blocking via the official installer.
# Settings: PIHOLE_* in config/rpi-setup.env (names in config/tasks/pihole.env).
set -euo pipefail

TASKS+=("pihole|Pi-hole ad blocker (official installer, unattended by default)")

run_pihole() {
  : "${PIHOLE_UNATTENDED:=yes}" "${PIHOLE_DNS:=1.1.1.1,1.0.0.1}" "${PIHOLE_QUERY_LOGGING:=yes}"
  setting_on PIHOLE_UNATTENDED || true
  setting_on PIHOLE_QUERY_LOGGING || true
  [[ -z "${PIHOLE_WEB_PORT:-}" ]] || require_port PIHOLE_WEB_PORT
  local -a dns=()
  pihole_dns_list dns

  if command -v pihole >/dev/null 2>&1; then
    say "Pi-hole is already installed (run 'pihole -d' to debug)"
    pihole_apply_web_port
    if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
      pihole setpassword "$PIHOLE_PASSWORD" >/dev/null
      say 'Set the web admin password from PIHOLE_PASSWORD'
    fi
    say "Web admin: $(pihole_admin_url)"
    return
  fi
  warn 'The Pi-hole installer uses "curl ... | bash" which has security implications.'
  warn 'Review the script at https://install.pi-hole.net before proceeding.'
  if [[ "${PIHOLE_CONFIRM:-}" != "yes" ]] && [[ -t 0 ]]; then
    local ans=""
    read -r -p 'Type "yes" to continue, anything else to skip (PIHOLE_CONFIRM=yes skips this question): ' ans ||
      { warn 'Skipped Pi-hole install.'; return; }
    [[ "$ans" == "yes" ]] || { warn 'Skipped Pi-hole install.'; return; }
  fi

  if in_container; then
    warn 'Pi-hole needs port 53 and is not supported in container environments; skipping'
    return
  fi

  if setting_on PIHOLE_UNATTENDED; then
    pihole_preseed "${dns[@]}"
    info 'Running the official Pi-hole installer unattended (settings from config/rpi-setup.env)'
    curl -fsSL https://install.pi-hole.net | bash /dev/stdin --unattended
  else
    info 'Running the official Pi-hole installer - follow its on-screen prompts'
    curl -fsSL https://install.pi-hole.net | bash
  fi

  if ! command -v pihole >/dev/null 2>&1; then
    warn 'Pi-hole installer did not complete'
    return
  fi
  pihole_apply_web_port

  local pw="${PIHOLE_PASSWORD:-}"
  if [[ -z "$pw" ]]; then
    pw="$(gen_secret 16)"
    save_secret pihole PIHOLE_PASSWORD "$pw"
    say "Generated web admin password: $pw"
    info 'Saved in /var/lib/rpi-setup/secrets/pihole.env; set PIHOLE_PASSWORD to choose your own.'
  fi
  pihole setpassword "$pw" >/dev/null
  say "Pi-hole installed - web admin: $(pihole_admin_url)"
}

# Split PIHOLE_DNS ("1.1.1.1,1.0.0.1", commas or spaces) into array $1.
pihole_dns_list() {
  local -n _dns_list="$1"
  local _dns
  read -r -a _dns_list <<<"${PIHOLE_DNS//,/ }"
  [[ ${#_dns_list[@]} -gt 0 ]] || die 'PIHOLE_DNS needs at least one upstream DNS server'
  for _dns in "${_dns_list[@]}"; do
    # An IPv4/IPv6 address, optionally with Pi-hole's "#port" suffix.
    [[ "$_dns" =~ ^[0-9a-fA-F.:]+(#[0-9]{1,5})?$ ]] || die "PIHOLE_DNS: '$_dns' is not an IP address"
  done
}

# A pihole.toml before installing makes the installer run without dialogs
# ("unattended" needs an existing config); Pi-hole fills in everything else.
pihole_preseed() {
  local iface="${PIHOLE_INTERFACE:-}" ups="" d log=false port="${PIHOLE_WEB_PORT:-}"
  if [[ -z "$iface" ]]; then
    iface="$(default_iface)" || die 'Could not detect the network interface; set PIHOLE_INTERFACE (e.g. eth0)'
  fi
  [[ -d "/sys/class/net/$iface" ]] || die "PIHOLE_INTERFACE: no network interface '$iface' on this Pi"
  for d in "$@"; do ups+="${ups:+, }\"$d\""; done
  if setting_on PIHOLE_QUERY_LOGGING; then log=true; fi
  if [[ -z "$port" ]] && port_owner 80 >/dev/null; then port=8080; fi

  install -m 0755 -d /etc/pihole
  {
    echo '# Pre-seeded by rpi-setup (tasks/pihole.sh); Pi-hole manages this file from here on.'
    echo '[dns]'
    echo "  upstreams = [ $ups ]"
    echo "  interface = \"$iface\""
    echo "  queryLogging = $log"
    if [[ -n "$port" ]]; then
      echo '[webserver]'
      echo "  port = \"${port}o,[::]:${port}o\""
    fi
  } >/etc/pihole/pihole.toml
  info "Pre-seeded /etc/pihole/pihole.toml (interface $iface, upstream DNS ${*})"
}

# Move the admin UI to PIHOLE_WEB_PORT if it is set and differs.
pihole_apply_web_port() {
  local want="${PIHOLE_WEB_PORT:-}" cur owner
  [[ -n "$want" ]] || return 0
  cur="$(pihole_web_port)"
  [[ "$cur" != "$want" ]] || return 0
  owner="$(port_owner "$want")" || owner=""
  if [[ -n "$owner" && "$owner" != pihole-FTL ]]; then
    die "PIHOLE_WEB_PORT=$want is already used by '$owner'; pick another port"
  fi
  pihole-FTL --config webserver.port "${want}o,[::]:${want}o" >/dev/null
  systemctl restart pihole-FTL || true
  say "Pi-hole web admin moved to port $want"
}

# First port of Pi-hole v6's admin UI (served by pihole-FTL).
pihole_web_port() {
  pihole-FTL --config webserver.port 2>/dev/null | cut -d, -f1 | tr -cd '0-9' || true
}

# Pi-hole v6 serves its admin UI from pihole-FTL, on port 80 unless another
# web server (e.g. the "web" task's nginx) holds it, then on 8080.
pihole_admin_url() {
  local port=""
  port="$(pihole_web_port)"
  if [[ -z "$port" || "$port" == 80 ]]; then
    printf 'http://%s/admin\n' "$(hostname)"
  else
    printf 'http://%s:%s/admin\n' "$(hostname)" "$port"
  fi
}
